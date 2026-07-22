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
//   forcing a write+re-anchor even if the size appears unchanged in-flight.

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

    /// Non-nil when a contentSize write was skipped during a menubar-hidden
    /// transient. Drained (and re-anchor forced) on the next visible call.
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
    /// Skips when auto-hide menubar is animating (buttonY > screenH).
    /// Note: buttonY == screenH is the VISIBLE boundary — do NOT skip it.
    ///
    /// When skipped, stores size as pendingContentSize. On the next visible
    /// call, drains it and forces a write+re-anchor even if the size appears
    /// unchanged (the popover geometry is stale from the skip).
    private func applyContentSize(_ preferred: NSSize) {
        guard popover.isShown else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        guard let button = statusItem.button,
              let buttonWin = button.window else {
            mbkLog("PopoverController", "applyContentSize — no button/window, skipping")
            return
        }

        // Auto-hide menubar guard.
        // Use > not >=: buttonY==screenH is visible (button flush with top edge).
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
            mbkLog("PopoverController", "applyContentSize — SKIP (menubar hidden), stored pending")
            return
        }

        // Drain any pending size from a skipped cycle.
        // forceReanchor=true bypasses the size-unchanged guard so the popover
        // geometry is corrected even if preferred already matches contentSize.
        let forceReanchor: Bool
        if let pending = pendingContentSize {
            pendingContentSize = nil
            forceReanchor = true
            mbkLog("PopoverController", "applyContentSize — drained pending=(\(pending.width),\(pending.height))")
        } else {
            forceReanchor = false
        }

        let currentSize = popover.contentSize
        let sizeChanged = abs(currentSize.width - preferred.width) > 1
                       || abs(currentSize.height - preferred.height) > 1
        guard sizeChanged || forceReanchor else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        mbkLog("PopoverController",
               "applyContentSize — WRITING (\(preferred.width),\(preferred.height)) "
               + "forceReanchor=\(forceReanchor) "
               + "delta=(\(preferred.width - currentSize.width),\(preferred.height - currentSize.height))")

        popover.contentSize = preferred
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
