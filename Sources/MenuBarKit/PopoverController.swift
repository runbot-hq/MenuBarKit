// PopoverController.swift
// MenuBarKit
//
// Owns the full NSPopover + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// ARROW CENTERING:
//   Height-only changes are updated in place via contentSize — AppKit
//   correctly grows/shrinks height from the anchored edge without needing to
//   recompute horizontal centering, so this direction just works.
//
//   WIDTH changes are NOT safe to apply in place. NSPopover only centers its
//   box around positioningRect ONCE, at show() time. Mutating contentSize.width
//   (or re-assigning positioningRect) on an already-visible popover does NOT
//   re-trigger that centering — the box just grows/shrinks from a fixed edge,
//   desyncing visibly from the arrow. Also note: positioningRect is derived
//   purely from button.bounds, which never changes between calls, so
//   "re-assigning" it to an already-shown popover is a no-op regardless of
//   the new contentSize — it was never going to move anything.
//
//   FIX: when a width change is detected, close the popover and call show()
//   again fresh (mirroring openPopover()'s exact call shape) rather than
//   mutating contentSize in place. A fresh show() re-triggers AppKit's own
//   anchor-centering math against the new size. popover.animates = false
//   makes this invisible to the user — no flicker, no visible close/reopen.
//
//   ❌ NEVER call pw.setFrameOrigin() / mutate the popover window's frame
//      directly to "correct" its x position. AppKit computes the arrow's
//      position from positioningRect/anchor at show()-time only. Manually
//      moving the window afterward creates two disagreeing authorities.
//
//   ❌ NEVER read buttonWin.frame / screen.frame for manual correction —
//      those values go transiently invalid during menu-bar auto-hide slides.
//
//   ⚠️  NEVER call show() without confirming button.bounds is non-zero
//      first (see positioningRect(for:) below). A degenerate zero-size rect
//      makes show() silently fail — no crash, no popover, nothing.

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let rootView: AnyView
    private let symbolName: String
    private let contentSize: NSSize

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

        // Pre-size to fittingSize before show() so AppKit places the window
        // at the correct size immediately, avoiding a visible post-show jump.
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
    /// A zero-size rect must never be passed to show() — that silently
    /// breaks AppKit's internal anchor machinery.
    private func positioningRect(for button: NSStatusBarButton) -> NSRect? {
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            mbkLog("PopoverController", "positioningRect — skipped: button.bounds is degenerate \(bounds)")
            return nil
        }
        let midX = bounds.midX
        return NSRect(x: midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    private func setupPopover() {
        hostingController = NSHostingController(rootView: rootView)
        // MUST be []. Leaving this at the macOS default (.preferredContentSize)
        // makes AppKit auto-write contentSize from the SwiftUI view's live
        // intrinsic size on every layout pass — a second, competing write path
        // that races our own applyContentSize() call below.
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
                let settled = self.hostingController.view.fittingSize
                self.applyContentSize(settled)
            }
        }
    }

    /// Applies a new preferred content size.
    ///
    /// Height-only changes are written directly to contentSize — AppKit
    /// handles that correctly on an already-visible popover.
    ///
    /// Width changes require a full close+reshow (see ARROW CENTERING note
    /// at top of file) because NSPopover never re-centers its box around
    /// positioningRect except at show() time. animates=false makes this
    /// invisible to the user.
    private func applyContentSize(_ preferred: NSSize) {
        guard popover.isShown, let button = statusItem.button else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        let currentSize = popover.contentSize
        let widthChanged = abs(currentSize.width - preferred.width) > 1
        let heightChanged = abs(currentSize.height - preferred.height) > 1
        guard widthChanged || heightChanged else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        if widthChanged {
            mbkLog("PopoverController",
                   "applyContentSize — width changed (\(currentSize.width)→\(preferred.width)), "
                   + "re-showing popover for correct centering")
            popover.contentSize = preferred
            guard let rect = positioningRect(for: button) else { return }
            popover.performClose(nil)
            popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
            mbkLog("PopoverController", "applyContentSize — re-shown at (\(preferred.width),\(preferred.height))")
        } else {
            mbkLog("PopoverController",
                   "applyContentSize — height-only change, writing (\(preferred.width),\(preferred.height)) "
                   + "prev=(\(currentSize.width),\(currentSize.height))")
            popover.contentSize = preferred
        }
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
