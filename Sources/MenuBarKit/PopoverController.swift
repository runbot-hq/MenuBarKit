// PopoverController.swift
// MenuBarKit
//
// Resize strategy
// ───────────────
// After the initial show() AppKit has finalised all geometry. We capture:
//   topEdge        — pw.frame.maxY  (constant: just below menu bar)
//   buttonMidXScreen — button centre in screen coords (constant per open)
//   chromeDelta    — pw.frame.size − contentSize (arrow+border, constant)
//
// On every subsequent resize we compute the new window rect purely from
// those captured values + the new contentSize, before writing anything:
//   winW = newContent.width  + chromeDelta.width
//   winH = newContent.height + chromeDelta.height
//   x    = buttonMidXScreen  - winW / 2
//   y    = topEdge           - winH
//
// Then: write contentSize, write setFrameOrigin.
// No show() call, no read-after-write race with AppKit layout.

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

    // MARK: - Captured anchor (set once per open, cleared on close)

    private var buttonMidXScreen: CGFloat = 0
    private var popoverTopEdge: CGFloat = 0
    /// pw.frame.size − popover.contentSize after initial show(). Constant.
    private var chromeDelta: NSSize = .zero

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

        // Capture anchor geometry. All values are final after show().
        if let pw = popover.contentViewController?.view.window,
           let buttonWin = button.window {
            popoverTopEdge = pw.frame.maxY
            let mid = NSPoint(x: button.frame.midX, y: button.frame.midY)
            buttonMidXScreen = buttonWin.convertPoint(toScreen: mid).x
            let cs = popover.contentSize
            chromeDelta = NSSize(
                width:  pw.frame.width  - cs.width,
                height: pw.frame.height - cs.height
            )
            mbkLog("PopoverController",
                   "anchor — topEdge=\(popoverTopEdge) midX=\(buttonMidXScreen) chrome=(\(chromeDelta.width),\(chromeDelta.height))")
        }
        mbkLog("PopoverController", "popover shown")
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
        guard popoverTopEdge > 0, buttonMidXScreen > 0, chromeDelta != .zero else { return }

        let buttonY = buttonWin.frame.origin.y
        let screenH = buttonWin.screen?.frame.height ?? -1
        guard screenH < 0 || buttonY < screenH else {
            mbkLog("PopoverController", "reshowWithSize — menu bar hidden, skipping")
            return
        }

        let current = popover.contentSize
        guard abs(current.width - size.width) > 1 || abs(current.height - size.height) > 1 else { return }

        // Compute new window rect BEFORE writing contentSize.
        // chromeDelta is constant, so:
        let winW = size.width  + chromeDelta.width
        let winH = size.height + chromeDelta.height
        let newX = buttonMidXScreen - winW / 2
        let newY = popoverTopEdge   - winH

        mbkLog("PopoverController",
               "reshowWithSize — content=(\(size.width),\(size.height)) win=(\(winW),\(winH)) x=\(newX) y=\(newY)")

        guard let pw = popover.contentViewController?.view.window else { return }
        popover.contentSize = size
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
        buttonMidXScreen = 0
        popoverTopEdge   = 0
        chromeDelta      = .zero
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
