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
//   FIX (current): snapshot the popover window's frame immediately after
//   show() returns (the only moment AppKit has placed it correctly and
//   nothing else has mutated it yet). Store:
//     - sessionAnchorX: window.frame.midX  — horizontal center
//     - sessionAnchorY: window.frame.maxY  — top edge (arrow attachment)
//   On every subsequent applyContentSize() call during the same open
//   session, set contentSize then overwrite the window frame using those
//   two cached values as the fixed anchor. Clear both in popoverDidClose().
//
//   ❌ A PRIOR ATTEMPT re-queried button screen coordinates on every resize.
//      button.minY is NOT stable across open/close cycles: macOS auto-hides
//      the menu bar, sliding the status bar window off-screen and back, so
//      the button's screen-Y legitimately changes between sessions.
//      Confirmed in logs: anchor.minY = 951.5 on first open, 984.5 on
//      second — causing the popover to drift ~33pt upward each cycle.
//
//   ❌ AN EARLIER ATTEMPT closed and re-showed the popover on width change.
//      Even with animates=false, destroy+recreate NSWindow is two separate
//      WindowServer frames — visible lateral jump. Do not reuse.
//
//   ⚠️  CRITICAL GOTCHA — SIZE OBSERVATION: DO NOT observe size from AppKit.
//      NSView KVO on `frame` and NSView.frameDidChangeNotification both
//      silently failed for NSHostingController's root view inside a popover.
//      Capture size from SwiftUI via GeometryReader + onChange instead —
//      see setupPopover() below.
//
//   ⚠️  NEVER call show() without confirming button.bounds is non-zero
//      first. A degenerate zero-size positioningRect makes show() silently
//      fail — no crash, no popover.

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

    /// Anchor snapshot taken immediately after show() returns.
    /// sessionAnchorX = window.frame.midX  (horizontal center)
    /// sessionAnchorY = window.frame.maxY  (top edge — arrow attachment point)
    /// Both are nil while the popover is closed; cleared in popoverDidClose().
    private var sessionAnchorX: CGFloat?
    private var sessionAnchorY: CGFloat?

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

        // Snapshot the anchor immediately after show() — this is the only
        // moment where AppKit has placed the window correctly and nothing
        // has mutated it yet. These values are reused for all resize calls
        // during this open session.
        if let window = hostingController.view.window {
            sessionAnchorX = window.frame.midX
            sessionAnchorY = window.frame.maxY
            mbkLog("PopoverController", "popover shown — anchor=(\(sessionAnchorX!),\(sessionAnchorY!))")
        } else {
            mbkLog("PopoverController", "popover shown")
        }
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

    /// Applies a new preferred content size, called directly from the
    /// SwiftUI GeometryReader wrapping the root view (see setupPopover()).
    ///
    /// Uses the session anchor snapshot (taken at show() time) to keep the
    /// window perfectly centered and top-pinned on every resize — no drift,
    /// no close/reopen, no jump.
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

        guard let anchorX = sessionAnchorX, let anchorY = sessionAnchorY else {
            // Anchor not yet set (shouldn't happen if show() ran first, but be safe).
            popover.contentSize = preferred
            mbkLog("PopoverController", "applyContentSize — no anchor yet, recorded (\(preferred.width),\(preferred.height))")
            return
        }

        mbkLog("PopoverController",
               "applyContentSize — (\(currentSize.width),\(currentSize.height))→"
               + "(\(preferred.width),\(preferred.height)) anchor=(\(anchorX),\(anchorY))")

        popover.contentSize = preferred

        var frame = window.frame
        frame.size = preferred
        frame.origin.x = anchorX - preferred.width / 2
        frame.origin.y = anchorY - preferred.height
        window.setFrame(frame, display: true, animate: false)
        mbkLog("PopoverController", "applyContentSize — frame=\(frame)")
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
        sessionAnchorX = nil
        sessionAnchorY = nil
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
