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
//   FIX (current): capture the popover window's anchor point once in
//   popoverWillShow, then reposition absolutely on every applyContentSize:
//     - anchorPoint.x = popoverWindow.frame.midX   (horizontal center)
//     - anchorPoint.y = popoverWindow.frame.maxY   (top edge, touches menu bar)
//     - origin.x      = anchorPoint.x - popoverWindow.frame.width / 2
//     - origin.y      = anchorPoint.y - popoverWindow.frame.height
//   Both frame dimensions are read after setting contentSize so they reflect
//   the new window size. No delta tracking, no chrome constant, no ordering
//   dependency on when window.frame is read.
//
//   WHY CAPTURE IN popoverWillShow AND NOT ON EVERY CALL:
//   buttonWindow.frame.minY drifts when macOS auto-hides the menu bar.
//   Capturing once at open time locks the anchor to the correct position
//   for the entire session, regardless of menu bar visibility changes.
//
//   ❌ PRIOR ATTEMPT: delta-based origin correction (dw/dh + oldFrame).
//      Required reading window.frame before mutating contentSize — any
//      refactoring that moved lines around broke the timing.
//
//   ❌ EARLIER ATTEMPT: absolute positioning from buttonWindow.frame on
//      every resize. buttonWindow.frame.minY drifts when the menu bar
//      auto-hides, causing the popover to jump to the hidden menu bar Y.
//
//   ❌ EARLIER ATTEMPT: re-queried button screen coords on every resize.
//      button.minY is NOT stable across sessions.
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
    /// Minimum width the popover will shrink to.
    private let minWidth: CGFloat
    /// Maximum width the popover will grow to. Content wider than this truncates.
    private let maxWidth: CGFloat
    /// Maximum height the popover will grow to. Content taller than this is scrollable.
    private let maxHeight: CGFloat

    // MARK: - Session hooks

    /// Called in openPopover() before popover.show(). Use to restore session state
    /// (e.g. active route, open sheets) so the popover respawns into the correct hierarchy.
    public var onWillShow: (() -> Void)?

    /// Called at the end of popoverDidClose, after all cleanup. Use to snapshot
    /// session state so it can be restored on the next open.
    /// Only fires on normal close (no overlay active). For force-close, use onWillForceClose.
    public var onDidClose: (() -> Void)?

    /// Called inside forceClose(), BEFORE the overlay gate is cleared and BEFORE
    /// the popover closes. Use to snapshot session state when an overlay (sheet,
    /// picker) is active at close time — at this point isSheetPresented is still
    /// true and route is still the correct value.
    public var onWillForceClose: (() -> Void)?

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    private var isSetUp = false
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    /// Screen-space anchor captured once in popoverWillShow:
    ///   x = window.frame.midX  — horizontal center, keeps arrow centered
    ///   y = window.frame.maxY  — top edge touching the menu bar, stable
    ///                            even if the menu bar auto-hides mid-session
    /// Reset to nil on close so it is re-captured on the next open.
    private var anchorPoint: NSPoint?

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

        onWillShow?()
        mbkLog("PopoverController", "onWillShow fired")

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

    /// Bypasses the overlay gate to force-close the popover together with any active overlay.
    /// Fires onWillForceClose BEFORE clearing the gate or closing, so the host app can
    /// snapshot state while isSheetPresented and route are still correct.
    /// Removes any child sheet windows first so performClose is not swallowed by AppKit
    /// when the sheet window holds focus.
    private func forceClose() {
        mbkLog("PopoverController", "forceClose — snapshotting before teardown")
        onWillForceClose?()
        overlayGate.hasActiveOverlay = false
        // Remove child sheet windows before closing the popover.
        // When the sheet is a child window and holds focus, performClose on the
        // popover is swallowed by AppKit. Detaching and hiding the child first
        // returns focus to the popover window so performClose proceeds normally.
        if let popoverWindow = hostingController.view.window {
            for child in (popoverWindow.childWindows ?? []) {
                mbkLog("PopoverController", "forceClose — removing child window")
                popoverWindow.removeChildWindow(child)
                child.orderOut(nil)
            }
        }
        popover.performClose(nil)
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

    /// Applies a new preferred content size, clamped to [minWidth, maxWidth] × maxHeight,
    /// then repositions the window absolutely using the anchor captured in popoverWillShow.
    ///
    /// Origin is derived from anchorPoint (stable for the session) and the post-mutation
    /// window frame dimensions — no delta tracking, no chrome constant.
    private func applyContentSize(_ preferred: CGSize) {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else { return }

        // Threshold > 1 (not > 0) to ignore sub-pixel size noise SwiftUI emits
        // during layout passes where the content hasn't meaningfully changed.
        guard abs(popover.contentSize.width - clamped.width) > 1
           || abs(popover.contentSize.height - clamped.height) > 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        guard popover.isShown,
              let window = hostingController.view.window,
              let anchor = anchorPoint else {
            popover.contentSize = clamped
            mbkLog("PopoverController", "applyContentSize — not shown, recorded (\(clamped.width),\(clamped.height))")
            return
        }

        mbkLog("PopoverController",
               "applyContentSize — (\(popover.contentSize.width),\(popover.contentSize.height))→"
               + "(\(clamped.width),\(clamped.height))")

        popover.contentSize = clamped

        // Read window frame after setting contentSize — dimensions now reflect new size.
        let newOrigin = NSPoint(
            x: anchor.x - window.frame.width / 2,
            y: anchor.y - window.frame.height
        )
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
                if overlayGate.hasActiveOverlay {
                    mbkLog("PopoverController", "workspace observer — overlay active, force-closing")
                    forceClose()
                } else {
                    mbkLog("PopoverController", "workspace observer — other app active, closing")
                    popover.performClose(nil)
                }
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
                guard let self else { return }
                if overlayGate.hasActiveOverlay {
                    mbkLog("PopoverController", "event monitor — overlay active, force-closing")
                    forceClose()
                } else {
                    popover.performClose(nil)
                }
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
        guard let window = hostingController.view.window else { return }
        anchorPoint = NSPoint(x: window.frame.midX, y: window.frame.maxY)
        mbkLog("PopoverController", "popoverWillShow — anchor=\(anchorPoint!)")
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
        anchorPoint = nil
        overlayGate.hasActiveOverlay = false
        mbkLog("PopoverController", "overlay gate reset on close")
        onDidClose?()
        mbkLog("PopoverController", "onDidClose fired")
    }
}
