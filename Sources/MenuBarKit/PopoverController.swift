// PopoverController.swift
// MenuBarKit

import AppKit
import SwiftUI

/// Manages the full NSPopover and NSStatusItem lifecycle for a macOS menu-bar app.
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

        let btnBounds   = button.bounds
        let btnFrame    = button.frame
        let btnWinFrame = button.window?.frame ?? .zero
        let fitting     = hostingController.view.fittingSize
        mbkLog("PopoverController",
               "COORDS openPopover — "
               + "button.bounds=\(btnBounds) "
               + "button.frame=\(btnFrame) "
               + "button.window.frame=\(btnWinFrame) "
               + "fittingSize=(\(fitting.width),\(fitting.height)) "
               + "popover.contentSize=(\(popover.contentSize.width),\(popover.contentSize.height))")

        if fitting.width > 0, fitting.height > 0 {
            popover.contentSize = fitting
            mbkLog("PopoverController", "COORDS openPopover — pre-sized to (\(fitting.width),\(fitting.height))")
        }

        let midX = button.bounds.midX
        let centerRect = NSRect(x: midX - 0.5, y: button.bounds.minY,
                                width: 1, height: button.bounds.height)
        mbkLog("PopoverController", "COORDS openPopover — centerRect=\(centerRect)")
        popover.show(relativeTo: centerRect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)

        if let pw = popover.contentViewController?.view.window {
            let screenMidXViaFrame  = btnWinFrame.minX + btnFrame.midX
            let screenMidXViaBounds = btnWinFrame.minX + btnBounds.midX
            mbkLog("PopoverController",
                   "COORDS openPopover — after show() "
                   + "popoverWindow=\(pw.frame) popoverMidX=\(pw.frame.midX) "
                   + "screenMidXViaFrame=\(screenMidXViaFrame) "
                   + "screenMidXViaBounds=\(screenMidXViaBounds)")
        }

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
        popover.animates = true
        popover.behavior = .applicationDefined
        popover.delegate = self
        setupSizeObserver()
    }

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

    private func applyContentSize(_ preferred: NSSize) {
        guard popover.isShown else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        let currentSize = popover.contentSize
        guard let button = statusItem.button,
              let buttonWin = button.window else {
            mbkLog("PopoverController", "applyContentSize — no button/window/screen, skipping")
            return
        }
        let buttonY  = buttonWin.frame.origin.y
        let screenH  = buttonWin.screen?.frame.height ?? -1
        let isMenuBarHidden = screenH < 0 || buttonY >= screenH
        mbkLog("PopoverController",
               "applyContentSize — "
               + "preferred=(\(preferred.width),\(preferred.height)) "
               + "current=(\(currentSize.width),\(currentSize.height)) "
               + "buttonY=\(buttonY) screenH=\(screenH) isMenuBarHidden=\(isMenuBarHidden)")
        guard !isMenuBarHidden else { return }
        guard abs(currentSize.width - preferred.width) > 1
                || abs(currentSize.height - preferred.height) > 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        // Log BEFORE
        if let pw = popover.contentViewController?.view.window {
            mbkLog("PopoverController",
                   "COORDS applyContentSize BEFORE write — "
                   + "popoverWindow=\(pw.frame) popoverMidX=\(pw.frame.midX) "
                   + "button.bounds=\(button.bounds) button.frame=\(button.frame) "
                   + "buttonWin.frame=\(buttonWin.frame) "
                   + "screenMidXViaFrame=\(buttonWin.frame.minX + button.frame.midX) "
                   + "screenMidXViaBounds=\(buttonWin.frame.minX + button.bounds.midX)")
        }

        mbkLog("PopoverController",
               "applyContentSize — WRITING (\(preferred.width),\(preferred.height)) "
               + "delta=(\(preferred.width - currentSize.width),\(preferred.height - currentSize.height))")
        popover.contentSize = preferred

        // Log AFTER and reposition
        if let pw = popover.contentViewController?.view.window,
           let screen = buttonWin.screen {
            let winW  = pw.frame.width
            let sMidViaFrame  = buttonWin.frame.minX + button.frame.midX
            let sMidViaBounds = buttonWin.frame.minX + button.bounds.midX
            let idealViaFrame  = sMidViaFrame  - winW / 2
            let idealViaBounds = sMidViaBounds - winW / 2
            let clampViaFrame  = max(screen.visibleFrame.minX, min(idealViaFrame,  screen.visibleFrame.maxX - winW))
            let clampViaBounds = max(screen.visibleFrame.minX, min(idealViaBounds, screen.visibleFrame.maxX - winW))
            let curX = pw.frame.origin.x
            mbkLog("PopoverController",
                   "COORDS applyContentSize AFTER write — "
                   + "popoverWindow=\(pw.frame) popoverMidX=\(pw.frame.midX) winW=\(winW) "
                   + "sMidViaFrame=\(sMidViaFrame) idealViaFrame=\(idealViaFrame) clampViaFrame=\(clampViaFrame) driftViaFrame=\(curX - clampViaFrame) "
                   + "sMidViaBounds=\(sMidViaBounds) idealViaBounds=\(idealViaBounds) clampViaBounds=\(clampViaBounds) driftViaBounds=\(curX - clampViaBounds)")

            let clampedX = clampViaFrame
            if abs(curX - clampedX) > 1 {
                mbkLog("PopoverController", "COORDS applyContentSize — repositioning x \(curX) → \(clampedX)")
                pw.setFrameOrigin(NSPoint(x: clampedX, y: pw.frame.origin.y))
            } else {
                mbkLog("PopoverController", "COORDS applyContentSize — x already correct (\(curX)), no reposition")
            }
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
