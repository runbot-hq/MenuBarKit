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
//   On resize (applyContentSize), AppKit may pre-resize the window BEFORE
//   our contentSize write fires, shifting x incorrectly. We correct x both
//   BEFORE and AFTER the write using:
//
//     buttonMidXOnScreen = buttonWin.frame.minX + button.frame.midX
//     idealX             = buttonMidXOnScreen - popoverWindow.frame.width / 2
//     clampedX           = clamped to screen.visibleFrame
//
//   popover.animates = false — prevents animation from showing the wrong
//   pre-correction position.
//
// SIDE-JUMP UNDER AUTO-HIDE MENUBAR:
//   isMenuBarHidden = screenH < 0 || buttonY >= screenH
//   Skips applyContentSize entirely when true.

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

    /// Writes a new contentSize to the popover and ensures the window x is
    /// correct both before and after the write.
    ///
    /// AppKit may pre-resize the popover window (e.g. auto-layout pass) before
    /// this method fires, leaving x wrong. We correct x before the write so
    /// there is no frame where the window is at the wrong position.
    private func applyContentSize(_ preferred: NSSize) {
        guard popover.isShown else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        let currentSize = popover.contentSize
        guard let button = statusItem.button,
              let buttonWin = button.window else {
            mbkLog("PopoverController", "applyContentSize — no button/window, skipping")
            return
        }
        let buttonY = buttonWin.frame.origin.y
        let screenH = buttonWin.screen?.frame.height ?? -1
        let isMenuBarHidden = screenH < 0 || buttonY >= screenH
        mbkLog("PopoverController",
               "applyContentSize — preferred=(\(preferred.width),\(preferred.height)) "
               + "current=(\(currentSize.width),\(currentSize.height)) "
               + "buttonY=\(buttonY) screenH=\(screenH) isMenuBarHidden=\(isMenuBarHidden)")
        guard !isMenuBarHidden else { return }
        guard abs(currentSize.width - preferred.width) > 1
                || abs(currentSize.height - preferred.height) > 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        guard let screen = buttonWin.screen,
              let pw = popover.contentViewController?.view.window else {
            popover.contentSize = preferred
            mbkLog("PopoverController", "applyContentSize — written (no screen for reposition)")
            return
        }

        let buttonMidX = buttonWin.frame.minX + button.frame.midX

        // Correct x BEFORE write — AppKit may have pre-resized the window
        // leaving it at the wrong x already.
        let preWinW = pw.frame.width
        let preIdealX = buttonMidX - preWinW / 2
        let preClampedX = max(screen.visibleFrame.minX, min(preIdealX, screen.visibleFrame.maxX - preWinW))
        if abs(pw.frame.origin.x - preClampedX) > 1 {
            mbkLog("PopoverController",
                   "applyContentSize — pre-write reposition x \(pw.frame.origin.x) → \(preClampedX) "
                   + "(buttonMidX=\(buttonMidX) winW=\(preWinW))")
            pw.setFrameOrigin(NSPoint(x: preClampedX, y: pw.frame.origin.y))
        }

        mbkLog("PopoverController",
               "applyContentSize — WRITING (\(preferred.width),\(preferred.height)) "
               + "delta=(\(preferred.width - currentSize.width),\(preferred.height - currentSize.height))")
        popover.contentSize = preferred

        // Correct x AFTER write — the contentSize write may shift x again.
        let postWinW = pw.frame.width
        let postIdealX = buttonMidX - postWinW / 2
        let postClampedX = max(screen.visibleFrame.minX, min(postIdealX, screen.visibleFrame.maxX - postWinW))
        if abs(pw.frame.origin.x - postClampedX) > 1 {
            mbkLog("PopoverController",
                   "applyContentSize — post-write reposition x \(pw.frame.origin.x) → \(postClampedX) "
                   + "(buttonMidX=\(buttonMidX) winW=\(postWinW))")
            pw.setFrameOrigin(NSPoint(x: postClampedX, y: pw.frame.origin.y))
        }

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
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
