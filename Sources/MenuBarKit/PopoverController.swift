// PopoverController.swift
// MenuBarKit
//
// Owns the full NSPopover + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// ARROW CENTERING:
//   show(relativeTo:of:preferredEdge:) with a 1pt rect at button.bounds.midX
//   is the ONLY reliable way to center the arrow. All manual setFrameOrigin
//   approaches fail because the NSPopover chrome is asymmetric and AppKit
//   re-flows the window position after contentSize changes.
//
//   On resize (applyContentSize):
//     1. Write contentSize.
//     2. Dismiss with close() (no animation, no delegate side-effects).
//     3. Re-show with show() using the same centerRect.
//   popover.animates = false means no flicker.
//
// SIDE-JUMP UNDER AUTO-HIDE MENUBAR:
//   buttonY > screenH (strictly) = hidden. buttonY == screenH = visible.
//   Skipped writes stored in pendingContentSize, drained with forceReanchor.

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

    /// Prevents popoverDidClose side-effects during a programmatic close+reopen cycle.
    private var isReopening = false
    /// Size skipped during a menubar-hidden transient; drained on next visible call.
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

    /// Calls show() with a 1pt rect at button midX. This is the canonical
    /// anchor call — AppKit centers the arrow over this rect reliably.
    private func showPopoverAnchored(to button: NSStatusBarButton) {
        let midX = button.bounds.midX
        let centerRect = NSRect(x: midX - 0.5, y: button.bounds.minY,
                                width: 1, height: button.bounds.height)
        popover.show(relativeTo: centerRect, of: button, preferredEdge: .minY)
        mbkLog("PopoverController", "showPopoverAnchored — midX=\(midX)")
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

    /// Writes a new contentSize and re-anchors the arrow by closing and
    /// reopening the popover. This is the only reliable way to make AppKit
    /// re-center the arrow — manual window repositioning is unreliable.
    private func applyContentSize(_ preferred: NSSize) {
        guard popover.isShown else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        guard let button = statusItem.button,
              let buttonWin = button.window else {
            mbkLog("PopoverController", "applyContentSize — no button/window, skipping")
            return
        }

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
               "applyContentSize — REOPEN (\(preferred.width),\(preferred.height)) "
               + "forceReanchor=\(forceReanchor) "
               + "delta=(\(preferred.width - currentSize.width),\(preferred.height - currentSize.height))")

        // Write the new size.
        popover.contentSize = preferred

        // Close without triggering popoverDidClose side-effects, then reshow.
        // animates=false means this is invisible to the user.
        isReopening = true
        popover.close()
        isReopening = false
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
        // During a reopen cycle, always allow the close.
        if isReopening { return true }
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose blocked=\(block)")
        return !block
    }

    public func popoverDidClose(_ notification: Notification) {
        // Skip side-effects during a programmatic close+reopen cycle.
        guard !isReopening else {
            mbkLog("PopoverController", "popoverDidClose — reopen in progress, skipping side-effects")
            return
        }
        mbkLog("PopoverController", "popoverDidClose")
        setButtonHighlight(false)
        stopEventMonitor()
        overlayGate.hasActiveOverlay = false
        pendingContentSize = nil
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
