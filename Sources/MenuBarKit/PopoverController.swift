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
//
//   ⚠️  CLAMP + fixedSize() GOTCHA:
//      When maxHeight clamps contentSize but the root view has .fixedSize(),
//      SwiftUI renders at its full intrinsic height (e.g. 637) even though
//      contentSize is 600. window.frame.height reflects the true rendered
//      height. Using popover.contentSize.height as the delta reference
//      therefore produces a wrong dh, shifting origin.y by the overflow.
//      FIX: measure chromeHeight once in popoverWillShow (before any clamp
//      overflow), then derive actualCurrentH = window.frame.height - chrome
//      for all subsequent delta calculations.

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let symbolName: String
    /// Minimum width the popover will shrink to.
    private let minWidth: CGFloat
    /// Maximum width the popover will grow to. Content wider than this truncates.
    private let maxWidth: CGFloat
    /// Maximum height the popover will grow to. Content taller than this is scrollable.
    private let maxHeight: CGFloat

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    private var isSetUp = false
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    /// Constant offset between window.frame.height and popover.contentSize.height
    /// (AppKit chrome: shadow + border). Measured once in popoverWillShow before
    /// any clamp overflow can occur, then used to derive the true rendered content
    /// height from window.frame on every subsequent applyContentSize call.
    /// Reset to nil on close so it is re-measured on the next open.
    private var chromeHeight: CGFloat?

    // MARK: - Init

    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle",
        minWidth: CGFloat = 200,
        maxWidth: CGFloat = 600,
        maxHeight: CGFloat = 600
    ) {
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.rootView = AnyView(rootView)
    }

    private let rootView: AnyView

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
            popover.contentSize = clamp(fitting)
            mbkLog("PopoverController", "openPopover — pre-sized to (\(fitting.width),\(fitting.height))")
        }

        guard let rect = positioningRect(for: button) else { return }
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
    }

    /// Returns a positioningRect centered on the button, or nil if bounds are degenerate.
    private func positioningRect(for button: NSStatusBarButton) -> NSRect? {
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            mbkLog("PopoverController", "positioningRect — skipped: degenerate bounds \(bounds)")
            return nil
        }
        return NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    private func setupPopover() {
        let wrapped = rootView
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
        // Safe non-degenerate placeholder — overwritten by fittingSize in openPopover()
        // before show() is called, so this value is never visible to the user.
        popover.contentSize = NSSize(width: minWidth, height: 100)
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    /// Clamps a size within [minWidth, maxWidth] × [1, maxHeight].
    private func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minWidth), maxWidth),
            height: min(size.height, maxHeight)
        )
    }

    /// Applies a new preferred content size, clamped to [minWidth, maxWidth] × maxHeight.
    ///
    /// Sets popover.contentSize then corrects window origin by the size delta so
    /// midX and maxY stay pinned under the menu bar arrow.
    ///
    /// Uses chromeHeight (measured in popoverWillShow) to derive the true rendered
    /// content height from window.frame, avoiding the stale-contentSize Y-drift bug
    /// that occurs when fixedSize() overflows a clamped contentSize.
    private func applyContentSize(_ preferred: CGSize) {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else { return }

        let currentSize = popover.contentSize
        let chrome = chromeHeight ?? 0
        let actualCurrentH = popover.isShown
            ? (hostingController.view.window?.frame.height ?? currentSize.height) - chrome
            : currentSize.height

        // No-op guard uses actualCurrentH so a clamped overflow doesn't cause
        // a false-positive skip on the next resize.
        guard abs(currentSize.width - clamped.width) > 1
           || abs(actualCurrentH - clamped.height) > 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        guard popover.isShown, let window = hostingController.view.window else {
            popover.contentSize = clamped
            mbkLog("PopoverController", "applyContentSize — not shown, recorded (\(clamped.width),\(clamped.height))")
            return
        }

        let oldFrame = window.frame
        let dw = clamped.width - currentSize.width
        let dh = clamped.height - actualCurrentH

        mbkLog("PopoverController",
               "applyContentSize — (\(currentSize.width),\(currentSize.height))→"
               + "(\(clamped.width),\(clamped.height)) actualCurrentH=\(actualCurrentH) dw=\(dw) dh=\(dh)")

        popover.contentSize = clamped

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
        // Measure chrome before any content size change or clamp overflow.
        // window is guaranteed to exist at this point.
        if let window = hostingController.view.window {
            chromeHeight = window.frame.height - popover.contentSize.height
            mbkLog("PopoverController", "popoverWillShow — chromeHeight=\(chromeHeight!)")
        }
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
        chromeHeight = nil
        overlayGate.hasActiveOverlay = false
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
