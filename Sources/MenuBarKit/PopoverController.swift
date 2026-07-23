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
//      contentSize is 600. The window.frame.height reflects the true rendered
//      height, not contentSize. Using popover.contentSize.height as the
//      "current" height for delta math therefore produces a wrong dh on the
//      next resize, shifting origin.y by the overflow amount (e.g. 37pt).
//      FIX: derive actualCurrentH from window.frame using the chrome constant
//      (chromeH = window.frame.height - popover.contentSize.height, measured
//      before any clamp overflow occurs), then dh = clamped.height - actualCurrentH.

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let symbolName: String
    private let contentSize: NSSize
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

    /// Cached chrome height (window.frame.height - popover.contentSize.height).
    /// Constant for the lifetime of the popover. Measured on first applyContentSize
    /// call where both window and contentSize are valid and no clamp overflow has
    /// occurred yet. Used to derive the true rendered content height from the window
    /// frame when contentSize may have been clamped.
    private var chromeHeight: CGFloat?

    // MARK: - Init

    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle",
        contentSize: NSSize = NSSize(width: 320, height: 300),
        minWidth: CGFloat = 200,
        maxWidth: CGFloat = 600,
        maxHeight: CGFloat = 600
    ) {
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.contentSize = contentSize
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
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
            popover.contentSize = clamp(fitting)
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

    /// Clamps a size within [minWidth, maxWidth] × [1, maxHeight].
    private func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minWidth), maxWidth),
            height: min(size.height, maxHeight)
        )
    }

    /// Applies a new preferred content size, clamped to [minWidth,maxWidth] x maxHeight.
    ///
    /// Sets popover.contentSize, then corrects the window origin by the
    /// size delta so midX and maxY stay pinned — compensating for AppKit's
    /// default grow-from-bottom-left behaviour without mixing content and
    /// chrome coordinate spaces.
    ///
    /// dh is computed from the actual window frame height (via chromeHeight),
    /// not from popover.contentSize, because fixedSize() can cause SwiftUI to
    /// render taller than contentSize when clamped — making contentSize an
    /// unreliable reference for the true current window height.
    private func applyContentSize(_ preferred: CGSize) {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else { return }
        let currentSize = popover.contentSize
        guard abs(currentSize.width - clamped.width) > 1
           || abs(currentSize.height - clamped.height) > 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        guard popover.isShown, let window = hostingController.view.window else {
            popover.contentSize = clamped
            mbkLog("PopoverController", "applyContentSize — not shown, recorded (\(clamped.width),\(clamped.height))")
            return
        }

        let oldFrame = window.frame

        // Measure chrome once — the constant offset between window.frame.height
        // and popover.contentSize.height. Valid only when there is no clamp overflow
        // yet (i.e. contentSize.height == actual rendered height). After that,
        // use it to derive the true current content height from the window frame.
        if chromeHeight == nil {
            chromeHeight = oldFrame.height - currentSize.height
            mbkLog("PopoverController", "applyContentSize — chromeHeight measured: \(chromeHeight!)")
        }
        let chrome = chromeHeight ?? 0
        let actualCurrentH = oldFrame.height - chrome

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
        chromeHeight = nil  // reset so it's re-measured on next open
        overlayGate.hasActiveOverlay = false
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
