// PopoverController.swift
// MenuBarKit
//
// Owns the full NSPopover + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// ARROW CENTERING:
//   NSPopover only centers its box around positioningRect ONCE, at show()
//   time. Mutating contentSize alone on an already-visible popover does NOT
//   re-trigger that centering — the box just grows/shrinks from a fixed
//   edge, desyncing visibly from the arrow.
//
//   FIX (current): after setting popover.contentSize, compensate for
//   AppKit's grow-from-edge default by shifting the window origin by the
//   size delta — NOT by recomputing origin from scratch:
//     - dx = (newWidth - oldWidth) / 2  → shift origin.x left by dx
//       so window.midX stays pinned to the same screen position.
//     - dy = newHeight - oldHeight      → shift origin.y down by dy
//       so window.maxY stays pinned (top edge stays touching the arrow).
//   This works entirely in window-frame space and never mixes content
//   size with chrome dimensions.
//
//   ❌ PRIOR ATTEMPT: set frame.size = contentSize, then recomputed
//      frame.origin.x = anchorX - contentSize.width / 2. Wrong because
//      anchorX = window.frame.midX includes chrome (shadow/border)
//      but contentSize does not — mixing the two spaces shifted the
//      window ~100pt left, placing it at the screen edge.
//
//   ❌ EARLIER ATTEMPT: re-queried button screen coords on every resize.
//      button.minY is NOT stable across sessions: macOS auto-hides the
//      menu bar, changing button screen-Y between open/close cycles.
//
//   ❌ EARLIEST ATTEMPT: close() + show() on width change.
//      Two WindowServer frames — visible lateral jump.
//
//   ⚠️  CRITICAL GOTCHA — SIZE OBSERVATION: observe from SwiftUI only.
//      NSView KVO / frameDidChangeNotification silently fail inside
//      NSPopover. Use GeometryReader + onChange (see setupPopover()).
//
//   ⚠️  NEVER call show() with a degenerate positioningRect.

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let symbolName: String
    private let contentSize: NSSize

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
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
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.contentSize = contentSize
        self.pendingRootView = AnyView(rootView)
    }

    private var pendingRootView: AnyView

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

        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            popover.contentSize = fitting
            mbkLog("PopoverController", "openPopover — pre-sized to (\(fitting.width),\(fitting.height))")
        }

        guard let rect = positioningRect(for: button) else { return }
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
    }

    /// Returns a fresh positioningRect derived from the button's CURRENT
    /// bounds, or nil if those bounds are degenerate (zero width/height).
    private func positioningRect(for button: NSStatusBarButton) -> NSRect? {
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            mbkLog("PopoverController", "positioningRect — skipped: button.bounds is degenerate \(bounds)")
            return nil
        }
        return NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    private func setupPopover() {
        let wrapped = pendingRootView
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size) { [weak self] _, newSize in
                            self?.applyContentSize(newSize)
                        }
                        .onAppear { [weak self] in
                            self?.applyContentSize(geo.size)
                        }
                }
            )
        hostingController = NSHostingController(rootView: AnyView(wrapped))
        hostingController.sizingOptions = []
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = contentSize
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    /// Applies a new preferred content size.
    ///
    /// Sets popover.contentSize, then corrects the window origin by the
    /// size delta so midX and maxY stay pinned — compensating for AppKit's
    /// default grow-from-bottom-left behaviour without mixing content and
    /// chrome coordinate spaces.
    private func applyContentSize(_ preferred: CGSize) {
        guard preferred.width > 0, preferred.height > 0 else { return }
        let currentSize = popover.contentSize
        guard abs(currentSize.width - preferred.width) > 1
           || abs(currentSize.height - preferred.height) > 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        guard popover.isShown, let window = hostingController.view.window else {
            popover.contentSize = preferred
            mbkLog("PopoverController", "applyContentSize — not shown, recorded (\(preferred.width),\(preferred.height))")
            return
        }

        // Capture current window origin BEFORE mutating contentSize.
        // AppKit repositions the window as a side-effect of contentSize change,
        // so we must read first, then write, then correct.
        let oldFrame = window.frame
        let dw = preferred.width - currentSize.width
        let dh = preferred.height - currentSize.height

        mbkLog("PopoverController",
               "applyContentSize — (\(currentSize.width),\(currentSize.height))→"
               + "(\(preferred.width),\(preferred.height)) dw=\(dw) dh=\(dh)")

        popover.contentSize = preferred

        // Shift origin to keep midX and maxY fixed:
        //   origin.x -= dw/2  → window grows/shrinks symmetrically around center
        //   origin.y -= dh    → window grows/shrinks downward, top edge stays put
        var newOrigin = oldFrame.origin
        newOrigin.x -= dw / 2
        newOrigin.y -= dh
        window.setFrameOrigin(newOrigin)
        mbkLog("PopoverController", "applyContentSize — origin set to \(newOrigin)")
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
