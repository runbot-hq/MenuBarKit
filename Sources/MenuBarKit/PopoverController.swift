// PopoverController.swift
// MenuBarKit
//
// Owns the full NSPopover + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// ARROW CENTERING:
//   show() pre-sizes contentSize to (fixedWidth, fittingSize.height) so AppKit
//   places the window at the correct size immediately. A 1pt positioningRect
//   at button midX is used so AppKit anchors the arrow to the button center.
//
//   contentSize.width is NEVER changed again after openPopover(). Only height
//   is updated dynamically, in applyContentHeight(). This is intentional and
//   load bearing: NSPopover's arrow is computed from the positioningRect /
//   anchor at show()/contentSize-set time, not re-derived from wherever the
//   window frame ends up afterward. Manually correcting the window's x-origin
//   after a width change (the previous approach) fights AppKit's own anchor
//   math instead of cooperating with it, and the two inevitably desync — this
//   is what caused the arrow to drift off-center when navigating between
//   views of different widths. Keeping width constant means AppKit's own
//   positioningRect-based centering keeps the arrow correctly anchored on
//   every resize, with zero manual window-frame correction needed.
//
//   ❌ NEVER reintroduce manual setFrameOrigin() correction in a resize path
//      as a way to "fix" a width change. If a view genuinely needs a
//      different width, re-issue show() with a fresh positioningRect instead
//      of mutating contentSize.width in place.
//
//   hostingController.sizingOptions MUST stay []. Leaving it at the macOS
//   default (.preferredContentSize) makes AppKit auto-write contentSize from
//   the SwiftUI view's live intrinsic size on every layout pass — a second,
//   competing write path that races our own applyContentHeight() call and
//   reintroduces width flapping / arrow misalignment even though our code
//   never explicitly asked for it. This is NOT optional.
//
//   popover.animates = false — prevents animation from showing the wrong
//   pre-correction position.

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let rootView: AnyView
    private let symbolName: String
    private let contentSize: NSSize
    /// Width is pinned for the lifetime of the popover. Never read fittingSize.width
    /// or any dynamically-computed width back into contentSize after openPopover().
    private var fixedWidth: CGFloat

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    private var sizeObservation: NSKeyValueObservation?
    private var isSetUp = false
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    // MARK: - Init

    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle",
        contentSize: NSSize = NSSize(width: 320, height: 300)
    ) {
        self.rootView = AnyView(rootView)
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.contentSize = contentSize
        self.fixedWidth = contentSize.width
    }

    // MARK: - Setup

    public func setup() {
        precondition(!isSetUp, "MBKPopoverController.setup() called more than once.")
        isSetUp = true
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupWorkspaceObserver()
        mbkLog("PopoverController", "setup complete")
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }

        // Pre-size to (fixedWidth, fittingSize.height) before show() so AppKit
        // places the window at the correct size immediately. Width is ALWAYS
        // fixedWidth here — never fittingSize.width — so the arrow anchoring
        // stays valid for the lifetime of the popover.
        let fittingHeight = hostingController.view.fittingSize.height
        if fittingHeight > 0 {
            let size = NSSize(width: fixedWidth, height: fittingHeight)
            popover.contentSize = size
            mbkLog("PopoverController", "openPopover — pre-sized to (\(size.width),\(size.height))")
        }

        let midX = button.bounds.midX
        let centerRect = NSRect(x: midX - 0.5, y: button.bounds.minY,
                                width: 1, height: button.bounds.height)
        popover.show(relativeTo: centerRect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    private func setupPopover() {
        hostingController = NSHostingController(rootView: rootView)
        // MUST be []. See ARROW CENTERING note at top of file — leaving this at
        // the macOS default (.preferredContentSize) reintroduces a second,
        // competing contentSize writer that races applyContentHeight() and
        // causes width flapping / arrow misalignment on navigation.
        hostingController.sizingOptions = []
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = contentSize
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
        setupSizeObserver()
    }

    // MARK: - Size observer

    private func setupSizeObserver() {
        sizeObservation = hostingController.view.observe(
            \.frame, options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let settledHeight = self.hostingController.view.fittingSize.height
                self.applyContentHeight(settledHeight)
            }
        }
    }

    /// Writes a new contentSize to the popover using the pinned fixedWidth and
    /// the newly-measured height. Width is intentionally never read from
    /// fittingSize or passed in — see the ARROW CENTERING note at the top of
    /// this file for why. Because width never changes, AppKit's own
    /// positioningRect-based anchoring keeps the arrow correctly centered on
    /// every call with no manual window-frame correction required.
    private func applyContentHeight(_ preferredHeight: CGFloat) {
        guard popover.isShown else { return }
        guard preferredHeight > 0 else { return }
        let currentSize = popover.contentSize
        guard abs(currentSize.height - preferredHeight) > 1 else {
            mbkLog("PopoverController", "applyContentHeight — no-op: height unchanged")
            return
        }

        let size = NSSize(width: fixedWidth, height: preferredHeight)
        mbkLog("PopoverController",
               "applyContentHeight — writing (\(size.width),\(size.height)) "
               + "prev=(\(currentSize.width),\(currentSize.height))")
        popover.contentSize = size
    }

    // MARK: - Workspace observer

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                guard activated != NSRunningApplication.current else {
                    mbkLog("PopoverController", "workspace observer — self-activation, ignoring")
                    return
                }
                guard !overlayGate.hasActiveOverlay else {
                    mbkLog("PopoverController", "workspace observer — overlay active, keeping popover open")
                    return
                }
                mbkLog("PopoverController", "workspace observer — other app active, closing")
                self.popover.performClose(nil)
            }
        }
    }

    // MARK: - Event monitor

    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.popover.performClose(nil)
            }
        }
        mbkLog("PopoverController", "event monitor started")
    }

    private func stopEventMonitor() {
        guard let monitor = eventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        eventMonitor = nil
        mbkLog("PopoverController", "event monitor stopped")
    }

    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - NSPopoverDelegate

extension MBKPopoverController: NSPopoverDelegate {
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
    }

    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose blocked=\(block)")
        return !block
    }

    public func popoverDidClose(_ notification: Notification) {
        mbkLog("PopoverController", "popoverDidClose")
        setButtonHighlight(false)
        stopEventMonitor()
        overlayGate.hasActiveOverlay = false
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
