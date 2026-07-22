// PopoverController.swift
// MenuBarKit
//
// Resize strategy (nuclear)
// ─────────────────────
// show() on a visible popover recalculates the full window position including
// arrow+chrome geometry we cannot reliably cancel. Every attempt to fix the
// drift post-show() has failed because the chrome height is opaque.
//
// Instead we bypass show() for resize entirely:
//
//   1. openPopover()  — show() as normal; AppKit places window correctly.
//      Capture topEdge = pw.frame.maxY and buttonMidXScreen from the button.
//
//   2. reshowWithSize()  — write contentSize only, then setFrame directly:
//        newWinW = pw.frame.width   (AppKit updated chrome width)
//        newWinH = pw.frame.height  (AppKit updated chrome height)
//        x = buttonMidXScreen - newWinW / 2
//        y = topEdge - newWinH
//      This is pixel-exact: arrow centred, top edge pinned, zero drift.

import AppKit
import Combine
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let rootView: AnyView
    private let symbolName: String
    private let initialContentSize: NSSize
    private let sizeRelay: MBKSizeRelay

    // MARK: - Anchor (captured after initial show)

    /// Screen x of the centre of the status item button.
    private var buttonMidXScreen: CGFloat = 0
    /// Top edge of the popover window (maxY). Fixed point just below menu bar.
    private var popoverTopEdge: CGFloat = 0

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    private var resizeSubscription: AnyCancellable?
    private var isSetUp = false
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    // MARK: - Init

    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        sizeRelay: MBKSizeRelay,
        symbolName: String = "menubar.rectangle",
        contentSize: NSSize = NSSize(width: 320, height: 300)
    ) {
        self.rootView = AnyView(rootView)
        self.overlayGate = overlayGate
        self.sizeRelay = sizeRelay
        self.symbolName = symbolName
        self.initialContentSize = contentSize
    }

    // MARK: - Setup

    public func setup() {
        precondition(!isSetUp, "MBKPopoverController.setup() called more than once.")
        isSetUp = true
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupSizeRelay()
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
        popover.show(relativeTo: centerRect(for: button), of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)

        // Capture anchor after show() so all geometry is final.
        if let pw = popover.contentViewController?.view.window,
           let buttonWin = button.window {
            popoverTopEdge = pw.frame.maxY
            // Convert button midX to screen coordinates.
            let buttonMidInWin = NSPoint(x: button.frame.midX, y: button.frame.midY)
            let buttonMidScreen = buttonWin.convertPoint(toScreen: buttonMidInWin)
            buttonMidXScreen = buttonMidScreen.x
            mbkLog("PopoverController",
                   "popover shown — topEdge=\(popoverTopEdge) buttonMidXScreen=\(buttonMidXScreen)")
        }
        startEventMonitor()
    }

    // MARK: - Popover setup

    private func setupPopover() {
        hostingController = NSHostingController(rootView: rootView)
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = initialContentSize
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    // MARK: - Size relay

    private func setupSizeRelay() {
        resizeSubscription = sizeRelay.subject
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] newSize in
                self?.reshowWithSize(newSize)
            }
    }

    private func reshowWithSize(_ size: NSSize) {
        guard popover.isShown else { return }
        guard size.width > 0, size.height > 0 else { return }
        guard let button = statusItem.button,
              let buttonWin = button.window else { return }

        let buttonY = buttonWin.frame.origin.y
        let screenH = buttonWin.screen?.frame.height ?? -1
        guard screenH < 0 || buttonY < screenH else {
            mbkLog("PopoverController", "reshowWithSize — menu bar hidden, skipping")
            return
        }

        let current = popover.contentSize
        guard abs(current.width - size.width) > 1 || abs(current.height - size.height) > 1 else { return }

        guard let pw = popover.contentViewController?.view.window else { return }
        guard popoverTopEdge > 0, buttonMidXScreen > 0 else { return }

        mbkLog("PopoverController",
               "reshowWithSize — (\(size.width),\(size.height)) prev=(\(current.width),\(current.height))")

        // Write the new content size. AppKit immediately resizes the window
        // chrome to match — pw.frame reflects the new total window size.
        popover.contentSize = size

        // Now compute the exact window origin from first principles.
        // pw.frame.width / .height are the final chrome-inclusive dimensions.
        let winW = pw.frame.width
        let winH = pw.frame.height
        let newX = buttonMidXScreen - winW / 2
        let newY = popoverTopEdge - winH

        mbkLog("PopoverController",
               "reshowWithSize — setFrame x=\(newX) y=\(newY) w=\(winW) h=\(winH)")
        pw.setFrameOrigin(NSPoint(x: newX, y: newY))
    }

    // MARK: - Helpers

    private func centerRect(for button: NSButton) -> NSRect {
        let midX = button.bounds.midX
        return NSRect(x: midX - 0.5, y: button.bounds.minY, width: 1, height: button.bounds.height)
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
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
        // Reset anchors so next open recaptures fresh geometry.
        buttonMidXScreen = 0
        popoverTopEdge = 0
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
