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
//     - x is re-derived to keep the window horizontally centered on the
//       status-item button's screen-space midX — the exact anchor point
//       AppKit itself uses for positioningRect, so this performs the same
//       centering math AppKit only does at show()-time, just applied live.
//     - y is re-derived to keep the window's TOP edge (touching the arrow,
//       since preferredEdge = .minY) fixed; only the bottom edge moves as
//       height changes.
//     - animate: false + a single setFrame() call = one atomic WindowServer
//       commit. No intermediate state, no visible jump.
//
//   ❌ A PRIOR ATTEMPT closed and re-showed the popover on width change.
//      This technically re-centered the arrow correctly, but destroying and
//      recreating the NSWindow is a two-step WindowServer operation — even
//      with animates=false, the old window's disappearance and the new
//      window's appearance at a different x render as separate frames,
//      producing a visible lateral jump. DO NOT reintroduce close()+show()
//      as the width-change strategy.
//
//   ❌ AN EVEN EARLIER ATTEMPT re-assigned positioningRect without changing
//      the frame directly — this was dead code (positioningRect is derived
//      only from button.bounds, which never changes, so "reassigning" it
//      never actually moved anything).
//
//   ⚠️  CRITICAL GOTCHA — SIZE OBSERVATION: DO NOT try to observe the hosted
//      SwiftUI content's size from the AppKit side (NSView KVO on `frame`,
//      or NSView.frameDidChangeNotification) — both were tried and both
//      silently failed to fire reliably for NSHostingController's root view
//      inside a popover. INSTEAD: capture size directly from SwiftUI via an
//      internal GeometryReader wrapping rootView (see setupPopover() below),
//      reporting through onChange straight into applyContentSize().
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
        let midX = bounds.midX
        return NSRect(x: midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
    }

    /// Returns the button's horizontal center in screen coordinates — the
    /// same anchor point AppKit itself centers the popover arrow on.
    private func buttonCenterXInScreen(_ button: NSStatusBarButton) -> CGFloat? {
        guard let buttonWindow = button.window else { return nil }
        let localMidRect = NSRect(x: button.bounds.midX - 0.5, y: button.bounds.minY, width: 1, height: 1)
        let windowRect = button.convert(localMidRect, to: nil)
        let screenRect = buttonWindow.convertToScreen(windowRect)
        return screenRect.midX
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
    /// Sets contentSize (required so AppKit's own layout stays consistent),
    /// then immediately re-derives and applies the window's frame directly
    /// so the box stays centered on the button with zero visible jump — see
    /// ARROW CENTERING note at top of file.
    private func applyContentSize(_ preferred: CGSize) {
        guard let button = statusItem.button else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        let currentSize = popover.contentSize
        let widthChanged = abs(currentSize.width - preferred.width) > 1
        let heightChanged = abs(currentSize.height - preferred.height) > 1
        guard widthChanged || heightChanged else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        guard popover.isShown, let window = hostingController.view.window else {
            popover.contentSize = preferred
            mbkLog("PopoverController", "applyContentSize — popover not shown, recorded (\(preferred.width),\(preferred.height))")
            return
        }

        mbkLog("PopoverController",
               "applyContentSize — size changed (\(currentSize.width),\(currentSize.height))→"
               + "(\(preferred.width),\(preferred.height)), resizing in place")
        popover.contentSize = preferred

        guard let anchorX = buttonCenterXInScreen(button) else { return }
        var frame = window.frame
        let topY = frame.maxY
        frame.size = preferred
        frame.origin.x = anchorX - preferred.width / 2
        frame.origin.y = topY - preferred.height
        window.setFrame(frame, display: true, animate: false)
        mbkLog("PopoverController",
               "applyContentSize — window frame set to \(frame), anchorX=\(anchorX)")
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
