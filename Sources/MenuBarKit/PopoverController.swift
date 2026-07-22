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
//   FIX (current): after every contentSize change, directly compute and set
//   the popover window's frame via window.setFrame(_, display:, animate:):
//     - anchorX: button's screen-space midX — same point AppKit centers on.
//     - topY: button's screen-space minY — the bottom edge of the button,
//       which is the stable point AppKit touches the arrow to. Using this
//       instead of window.frame.maxY avoids drift caused by AppKit silently
//       repositioning the window when contentSize is mutated.
//     - Both anchors are captured BEFORE contentSize is mutated.
//     - animate: false + single setFrame() = one atomic WindowServer commit,
//       no intermediate state, no jump.
//
//   ❌ A PRIOR ATTEMPT used `let topY = window.frame.maxY` AFTER setting
//      popover.contentSize. AppKit silently repositions the window when
//      contentSize changes, so frame.maxY was already stale by the time
//      we read it — the window drifted ~33pt upward on every resize cycle.
//
//   ❌ AN EARLIER ATTEMPT closed and re-showed the popover on width change.
//      Even with animates=false, destroying/recreating the NSWindow is two
//      separate WindowServer frames — visible lateral jump. Do not reuse.
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

    /// Returns the button's anchor in screen coordinates:
    ///   - midX: horizontal center the popover arrow points to.
    ///   - minY: bottom edge of the button — the Y the popover top touches.
    /// Both values are stable (the button never moves) and must be captured
    /// BEFORE mutating popover.contentSize to avoid AppKit reposition drift.
    private func buttonScreenAnchor(_ button: NSStatusBarButton) -> (midX: CGFloat, minY: CGFloat)? {
        guard let buttonWindow = button.window else { return nil }
        let localRect = NSRect(x: button.bounds.minX, y: button.bounds.minY,
                               width: button.bounds.width, height: button.bounds.height)
        let windowRect = button.convert(localRect, to: nil)
        let screenRect = buttonWindow.convertToScreen(windowRect)
        return (midX: screenRect.midX, minY: screenRect.minY)
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
    /// Captures the stable button screen anchor FIRST (before any contentSize
    /// mutation that would cause AppKit to silently reposition the window),
    /// then sets contentSize, then overwrites the window frame in one atomic
    /// setFrame() call — no close/reopen, no jump, no drift.
    private func applyContentSize(_ preferred: CGSize) {
        guard let button = statusItem.button else { return }
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

        // ⚠️ Capture anchor BEFORE mutating contentSize — AppKit repositions
        // the window as a side-effect of that mutation, making frame.maxY stale.
        guard let anchor = buttonScreenAnchor(button) else { return }

        mbkLog("PopoverController",
               "applyContentSize — (\(currentSize.width),\(currentSize.height))→"
               + "(\(preferred.width),\(preferred.height)) anchor=(\(anchor.midX),\(anchor.minY))")

        popover.contentSize = preferred

        var frame = window.frame
        frame.size = preferred
        frame.origin.x = anchor.midX - preferred.width / 2
        // anchor.minY is the button's bottom edge in screen coords.
        // The popover top edge sits flush at that Y (arrow gap is inside
        // the popover's own chrome), so origin.y = anchor.minY - height.
        frame.origin.y = anchor.minY - preferred.height
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
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
