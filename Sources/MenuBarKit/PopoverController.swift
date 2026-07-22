// PopoverController.swift
// MenuBarKit
//
// Owns the full NSPopover + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// ARROW CENTERING:
//   show() pre-sizes contentSize to fittingSize so AppKit places the window
//   at the correct width immediately. A 1pt positioningRect at button midX
//   is used so AppKit anchors the arrow to the button center on open.
//
//   On resize (applyContentSize):
//     1. Write contentSize.
//     2. Call show() again with the same 1pt centerRect.
//        Calling show() on an already-shown popover is a no-op for visibility
//        but re-runs AppKit's anchor geometry, re-centering the arrow over
//        the button. Manual setFrameOrigin is NOT used: the arrow position
//        inside the NSPopover window is not simply windowW/2 and cannot be
//        reliably computed without AppKit's internal layout pass.
//
//   popover.animates = false ensures no visible jump on the re-show.
//
// SIDE-JUMP UNDER AUTO-HIDE MENUBAR:
//   Signal: buttonY > screenH (Dock pushes NSStatusItem window strictly past
//   the top edge). Observed: buttonY=982 screenH=982 is the VISIBLE boundary
//   state — the button is flush with the top of screen, NOT hidden. Only
//   buttonY strictly greater than screenH means the button is off screen.
//
//   buttonWin.screen can transiently return nil while the menubar is hiding.
//   We fall back to NSScreen.main rather than treating nil as "hidden".
//   If there is genuinely no screen, use CGFloat.infinity (never hidden).
//
//   When a write IS skipped, the desired size is stored as pendingContentSize.
//   The next applyContentSize call that passes the hidden guard drains it,
//   forcing a write+re-anchor even if the size appears unchanged.

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

    /// Size that was skipped during a menubar-hidden transient.
    /// Drained on the next visible applyContentSize call.
    private var pendingContentSize: NSSize?

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

        // Pre-size to fittingSize before show() so AppKit places window at
        // correct width from the start.
        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            popover.contentSize = fitting
            mbkLog("PopoverController", "openPopover — pre-sized to (\(fitting.width),\(fitting.height))")
        }
        pendingContentSize = nil

        showPopoverAnchored(to: button)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
    }

    /// Calls `popover.show(relativeTo:of:preferredEdge:)` with a 1pt rect at
    /// button midX. Used both on initial open and after contentSize writes to
    /// re-anchor AppKit's arrow geometry.
    private func showPopoverAnchored(to button: NSStatusBarButton) {
        let midX = button.bounds.midX
        let centerRect = NSRect(x: midX - 0.5, y: button.bounds.minY,
                                width: 1, height: button.bounds.height)
        popover.show(relativeTo: centerRect, of: button, preferredEdge: .minY)
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    private func setupPopover() {
        hostingController = NSHostingController(rootView: rootView)
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

    /// Writes a new contentSize to the popover and re-anchors the arrow.
    ///
    /// After writing contentSize, calls show() again with the same 1pt
    /// centerRect at button midX. This re-runs AppKit's anchor geometry so
    /// the arrow stays centered regardless of chrome or internal layout.
    ///
    /// Skips the write when the auto-hide menubar is hidden (buttonY > screenH).
    /// Note: buttonY == screenH is the visible boundary state (button flush with
    /// screen top edge) and must NOT be treated as hidden.
    ///
    /// When skipped, stores the desired size as pendingContentSize and drains
    /// it on the next visible call, forcing a write+re-anchor even if the
    /// in-flight size appears unchanged.
    private func applyContentSize(_ preferred: NSSize) {
        guard popover.isShown else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        guard let button = statusItem.button,
              let buttonWin = button.window else {
            mbkLog("PopoverController", "applyContentSize — no button/window, skipping")
            return
        }

        // Auto-hide menubar guard.
        // buttonWin.screen can be transiently nil while the menubar is hiding.
        // Fall back to NSScreen.main rather than treating nil as hidden.
        // Use > not >=: buttonY==screenH is the visible boundary, not hidden.
        let buttonY = buttonWin.frame.origin.y
        let resolvedScreen = buttonWin.screen ?? NSScreen.main
        let screenH = resolvedScreen?.frame.height ?? CGFloat.infinity
        let isMenuBarHidden = buttonY > screenH
        let screenSource = buttonWin.screen != nil ? "buttonWin" : "NSScreen.main"
        mbkLog("PopoverController",
               "applyContentSize — preferred=(\(preferred.width),\(preferred.height)) "
               + "buttonY=\(buttonY) screenH=\(screenH) isMenuBarHidden=\(isMenuBarHidden) "
               + "screenSource=\(screenSource)")
        guard !isMenuBarHidden else {
            pendingContentSize = preferred
            mbkLog("PopoverController", "applyContentSize — SKIP: menubar hidden (buttonY=\(buttonY) > screenH=\(screenH)), stored pending")
            return
        }

        // Drain any size that was skipped during a hidden transient.
        // If we have a pending size that differs from preferred, use it so the
        // popover reflects the latest desired size. Then clear the pending.
        let effective: NSSize
        if let pending = pendingContentSize {
            pendingContentSize = nil
            // Use whichever is the latest: if pending == preferred, no difference.
            // If they differ, preferred is the most recent so use that.
            effective = preferred
            mbkLog("PopoverController", "applyContentSize — drained pending=(\(pending.width),\(pending.height))")
        } else {
            effective = preferred
        }

        let currentSize = popover.contentSize
        let hasPending = pendingContentSize != nil  // already cleared above, use flag before clear
        guard abs(currentSize.width - effective.width) > 1
                || abs(currentSize.height - effective.height) > 1
                || (pendingContentSize == nil && effective != preferred) else {
            // Also force a re-anchor if we just drained a pending (geometry may
            // be stale even if size matches). Check by comparing effective to
            // what popover currently has AND whether we had a pending.
            if abs(currentSize.width - effective.width) <= 1
                && abs(currentSize.height - effective.height) <= 1 {
                // Size already matches — but if we drained a pending we still
                // need to re-anchor. The hasPending flag is now stale (cleared).
                // Re-check: if we entered this block, no pending was set above.
                mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
                return
            }
        }

        mbkLog("PopoverController",
               "applyContentSize — WRITING (\(effective.width),\(effective.height)) "
               + "delta=(\(effective.width - currentSize.width),\(effective.height - currentSize.height))")

        popover.contentSize = effective
        showPopoverAnchored(to: button)

        mbkLog("PopoverController", "applyContentSize — done")
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
        pendingContentSize = nil
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
