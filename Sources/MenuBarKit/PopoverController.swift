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
//   is used so AppKit anchors the arrow to the button center.
//
//   On resize (applyContentSize):
//     1. Write contentSize.
//     2. Read pw.frame.width — this is the actual window width including
//        NSPopover chrome (shadow + border), NOT equal to contentSize.width.
//     3. Compute targetX = buttonMidX - windowW / 2, clamped to visibleFrame.
//     4. Call setFrameOrigin with targetX.
//
//   Steps 1-4 happen back-to-back in the same runloop cycle.
//   popover.animates = false ensures setFrameOrigin is instantaneous.
//
// SIDE-JUMP UNDER AUTO-HIDE MENUBAR:
//   Signal: buttonY >= screenH (Dock pushes NSStatusItem window off top edge).
//   Observed values: buttonY=982 screenH=982 when hidden.
//
//   buttonWin.screen can transiently return nil while the menubar is hiding.
//   We fall back to NSScreen.main rather than treating nil as "hidden".
//   Only skip the contentSize write when we have a real screenH and
//   buttonY >= screenH. If there is genuinely no screen, use
//   CGFloat.infinity so the write always goes through.

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

        // Pre-size to fittingSize before show() so AppKit places window at
        // correct width from the start.
        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            popover.contentSize = fitting
            mbkLog("PopoverController", "openPopover — pre-sized to (\(fitting.width),\(fitting.height))")
        }

        let midX = button.bounds.midX
        let centerRect = NSRect(x: midX - 0.5, y: button.bounds.minY,
                                width: 1, height: button.bounds.height)
        popover.show(relativeTo: centerRect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
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

    /// Writes a new contentSize to the popover and corrects the window x so
    /// the arrow stays centered over the status item button.
    ///
    /// Order matters:
    ///   1. Write `popover.contentSize = preferred`
    ///   2. Read `pw.frame.width` — now reflects actual window width including
    ///      NSPopover chrome (shadow + border). Using this, NOT preferred.width,
    ///      is correct: the chrome adds a constant offset and centering on
    ///      preferred.width would consistently place the window off-center.
    ///   3. Compute targetX = buttonMidX - windowW / 2, clamped.
    ///   4. Call `pw.setFrameOrigin(targetX)` in the same runloop cycle.
    ///
    /// Skips the write when the auto-hide menubar is hidden (buttonY >= screenH).
    /// Falls back to NSScreen.main when buttonWin.screen is transiently nil.
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
        let buttonY = buttonWin.frame.origin.y
        let resolvedScreen = buttonWin.screen ?? NSScreen.main
        let screenH = resolvedScreen?.frame.height ?? CGFloat.infinity
        let isMenuBarHidden = buttonY >= screenH
        let screenSource = buttonWin.screen != nil ? "buttonWin" : "NSScreen.main"
        mbkLog("PopoverController",
               "applyContentSize — preferred=(\(preferred.width),\(preferred.height)) "
               + "buttonY=\(buttonY) screenH=\(screenH) isMenuBarHidden=\(isMenuBarHidden) "
               + "screenSource=\(screenSource)")
        guard !isMenuBarHidden else {
            mbkLog("PopoverController", "applyContentSize — SKIP: menubar hidden (buttonY=\(buttonY) >= screenH=\(screenH))")
            return
        }

        let currentSize = popover.contentSize
        guard abs(currentSize.width - preferred.width) > 1
                || abs(currentSize.height - preferred.height) > 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        guard let screen = resolvedScreen,
              let pw = popover.contentViewController?.view.window else {
            popover.contentSize = preferred
            mbkLog("PopoverController", "applyContentSize — written (no screen for reposition)")
            return
        }

        let buttonMidX = buttonWin.frame.minX + button.frame.midX

        mbkLog("PopoverController",
               "applyContentSize — WRITING (\(preferred.width),\(preferred.height)) "
               + "buttonMidX=\(buttonMidX) "
               + "delta=(\(preferred.width - currentSize.width),\(preferred.height - currentSize.height))")

        // Step 1: write contentSize.
        popover.contentSize = preferred

        // Step 2: read pw.frame.width AFTER the write — this is the actual
        // window width including NSPopover chrome (shadow + border).
        // ❌ Do NOT use preferred.width: it does not include chrome and will
        // place the window consistently off-center by half the chrome width.
        let windowW = pw.frame.width
        let targetX = max(
            screen.visibleFrame.minX,
            min(buttonMidX - windowW / 2,
                screen.visibleFrame.maxX - windowW)
        )

        // Step 3: reposition. Same runloop cycle as the contentSize write.
        pw.setFrameOrigin(NSPoint(x: targetX, y: pw.frame.origin.y))

        mbkLog("PopoverController",
               "applyContentSize — done windowW=\(windowW) targetX=\(targetX) "
               + "popoverWin=(\(pw.frame.origin.x),\(pw.frame.origin.y),\(pw.frame.width),\(pw.frame.height))")
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
