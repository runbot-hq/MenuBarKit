// PopoverController.swift
// MenuBarKit
//
// Owns the full NSPopover + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// ARROW CENTERING ON RESIZE (applyContentSize):
//
//   show() on an already-shown popover does NOT re-run AppKit's anchor
//   geometry — the arrow stays wherever it was when the popover first opened.
//   Manual repositioning via setFrameOrigin is required.
//
//   The arrow tip is always at the horizontal center of the content view, not
//   the center of the window. The window is wider than the content view by the
//   chrome (shadow + border). The chrome left inset is measured live:
//
//     chromeLeft = contentView.frame.minX  (content view origin in window coords
//                                           equals the left chrome width because
//                                           pw.frame.origin is the window origin)
//
//   Desired window origin X so that arrow (= content center) is over buttonMidX:
//
//     targetX = buttonMidX - (preferred.width / 2 + chromeLeft)
//
//   chromeLeft is measured after writing contentSize while the window is still
//   on screen. It is stable (~13pt on all tested macOS versions).
//
//   A cached chromeLeft is stored after the first successful measurement and
//   reused on subsequent calls, avoiding a stale-frame race on rapid resizes.
//
// SIDE-JUMP UNDER AUTO-HIDE MENUBAR:
//   Signal: buttonY > screenH (button strictly off top of screen).
//   buttonY == screenH is the VISIBLE boundary — button flush with screen top.
//
//   buttonWin.screen can transiently return nil while the menubar is hiding.
//   Fall back to NSScreen.main. If no screen at all, use CGFloat.infinity.
//
//   When a write is skipped, the size is stored as pendingContentSize and
//   drained (with forceReanchor=true) on the next visible call.

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

    /// Cached left chrome inset (window.minX → contentView.minX).
    /// Measured once from the live window; stable across resize.
    private var cachedChromeLeft: CGFloat?

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
        // Reset chrome cache on each open so it is measured fresh from the
        // new window AppKit creates.
        cachedChromeLeft = nil

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

    /// Writes a new contentSize and repositions the window so the arrow stays
    /// centered over the status item button.
    ///
    /// Positioning math:
    ///   chromeLeft = content view's minX inside the popover window (= left shadow/border width)
    ///   arrow is at content center = pw.minX + chromeLeft + preferred.width/2
    ///   to put arrow over buttonMidX:  targetX = buttonMidX - chromeLeft - preferred.width/2
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

        guard let pw = popover.contentViewController?.view.window,
              let screen = resolvedScreen else {
            popover.contentSize = preferred
            mbkLog("PopoverController", "applyContentSize — written (no screen/window for reposition)")
            return
        }

        // Measure chrome left inset from the live window before resizing.
        // contentViewController.view is the content view; its frame origin
        // in window coordinates equals the left chrome width.
        let chromeLeft: CGFloat
        if let cached = cachedChromeLeft {
            chromeLeft = cached
        } else {
            let contentViewMinX = popover.contentViewController!.view.frame.minX
            chromeLeft = contentViewMinX
            cachedChromeLeft = chromeLeft
            mbkLog("PopoverController", "applyContentSize — measured chromeLeft=\(chromeLeft)")
        }

        let buttonMidX = buttonWin.frame.minX + button.frame.midX

        mbkLog("PopoverController",
               "applyContentSize — WRITING (\(preferred.width),\(preferred.height)) "
               + "forceReanchor=\(forceReanchor) buttonMidX=\(buttonMidX) chromeLeft=\(chromeLeft) "
               + "delta=(\(preferred.width - currentSize.width),\(preferred.height - currentSize.height))")

        popover.contentSize = preferred

        // Arrow is at content view center in screen space.
        // targetX places the window so that center lands on buttonMidX.
        let targetX = max(
            screen.visibleFrame.minX,
            min(buttonMidX - chromeLeft - preferred.width / 2,
                screen.visibleFrame.maxX - pw.frame.width)
        )
        pw.setFrameOrigin(NSPoint(x: targetX, y: pw.frame.origin.y))

        mbkLog("PopoverController",
               "applyContentSize — done targetX=\(targetX) "
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
        pendingContentSize = nil
        cachedChromeLeft = nil
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
