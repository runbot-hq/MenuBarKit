// PopoverController.swift
// MenuBarKit
//
// Arrow centering strategy
// ────────────────────────
// setFrameOrigin / contentSize alone fight AppKit's internal anchor stored
// at show() time. Every contentSize write causes AppKit to recompute x from
// that stale anchor, undoing any manual correction.
//
// The only API that atomically resets both size AND anchor is
//   show(relativeTo:of:preferredEdge:)
// Calling it on an already-visible popover repositions it instantly.
// We call it on every content-size change, passing the same 1pt centerRect
// built from button.bounds.midX so the arrow always lands on the button
// centre regardless of content width.
//
// show() also recalculates y. To avoid a vertical jump we capture y before
// the call and restore it immediately after.
//
// Sizing signal
// ─────────────
// .mbkReportSize() (GeometryReader + PreferenceKey) pushes sizes into
// MBKSizeRelay.subject. A 16 ms debounce collapses burst layout passes.

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

        let buttonY = buttonWin.frame.origin.y
        let screenH = buttonWin.screen?.frame.height ?? -1
        guard screenH < 0 || buttonY < screenH else {
            mbkLog("PopoverController", "reshowWithSize — menu bar hidden, skipping")
            return
        }

        let current = popover.contentSize
        guard abs(current.width - size.width) > 1 || abs(current.height - size.height) > 1 else { return }

        mbkLog("PopoverController",
               "reshowWithSize — (\(size.width),\(size.height)) prev=(\(current.width),\(current.height))")

        // Capture y before show() so we can restore it.
        // show() recalculates the full window position; x is correct (anchored
        // to button midX) but y may drift. We keep the y AppKit chose at the
        // original openPopover() call.
        let previousY = popover.contentViewController?.view.window?.frame.origin.y

        popover.contentSize = size
        popover.show(relativeTo: centerRect(for: button), of: button, preferredEdge: .minY)

        if let pw = popover.contentViewController?.view.window,
           let y = previousY {
            if pw.frame.origin.y != y {
                mbkLog("PopoverController", "reshowWithSize — restoring y \(pw.frame.origin.y) → \(y)")
                pw.setFrameOrigin(NSPoint(x: pw.frame.origin.x, y: y))
            }
        }
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
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
