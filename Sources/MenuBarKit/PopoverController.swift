// PopoverController.swift
// MenuBarKit

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
    private var isReanchoring = false
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

        // Pre-size to fittingSize so AppKit places the window at the correct
        // width and computes the arrow at the correct offset immediately on
        // show().
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

    /// Re-anchors the popover at the new content size by closing and
    /// immediately reshowing it (with animation disabled), rather than
    /// mutating contentSize/frame on the already-shown window.
    ///
    /// WHY NEITHER IN-PLACE APPROACH WORKS:
    ///   - Manually calling setFrameOrigin() after writing contentSize moves
    ///     the *window*, but the arrow's internal offset (distance from the
    ///     window's left edge to the arrow tip) is computed once, during the
    ///     original show() layout pass, and is never recalculated afterward.
    ///     The window ends up centered on the button, but the arrow tip
    ///     stays at whatever offset AppKit computed for the FIRST width —
    ///     producing visible drift whenever a later width differs from the
    ///     first one shown.
    ///   - Re-assigning positioningRect on an already-shown popover does
    ///     force AppKit to recompute the arrow correctly, but it does so via
    ///     an async re-layout that visibly SNAPS the window to its new
    ///     position (a well-known AppKit quirk) — trading arrow drift for an
    ///     equally visible side-jump.
    ///
    /// WHY CLOSE + RESHOW WORKS:
    ///   show(relativeTo:of:preferredEdge:) always performs a full, fresh
    ///   AppKit layout pass — window frame and arrow tip are computed
    ///   together from positioningRect and contentSize, exactly as on first
    ///   open. Since popover.animates = false, close+reshow is visually
    ///   instantaneous (no flicker), and this guarantees the window and
    ///   arrow are always consistent, regardless of how the width changes
    ///   between views.
    private func applyContentSize(_ preferred: NSSize) {
        guard popover.isShown else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        let currentSize = popover.contentSize
        guard let button = statusItem.button,
              let buttonWin = button.window else {
            mbkLog("PopoverController", "applyContentSize — no button/window, skipping")
            return
        }
        // Skip only when the status item's button is genuinely off-screen
        // (e.g. auto-hidden menu bar).
        if let screen = buttonWin.screen, !screen.frame.contains(buttonWin.frame.origin) {
            mbkLog("PopoverController", "applyContentSize — button off-screen, skipping")
            return
        }
        guard abs(currentSize.width - preferred.width) > 1
                || abs(currentSize.height - preferred.height) > 1 else { return }

        // Don't close/reshow while an overlay (sheet/alert) is active —
        // performClose() would tear down the overlay-gate state and any
        // anchored child window relationships. In that case just resize in
        // place; the arrow may be briefly off until the next resize after
        // the overlay clears.
        guard !overlayGate.hasActiveOverlay else {
            mbkLog("PopoverController", "applyContentSize — overlay active, resizing in place only")
            popover.contentSize = preferred
            return
        }

        mbkLog("PopoverController",
               "applyContentSize — writing (\(preferred.width),\(preferred.height)) "
               + "prev=(\(currentSize.width),\(currentSize.height))")
        popover.contentSize = preferred

        // Close and immediately reshow so AppKit redoes the full frame +
        // arrow layout pass together at the new size. animates = false
        // makes this imperceptible to the user. Suppress the delegate's
        // side effects (highlight/eventMonitor/overlayGate reset) around
        // this internal close+reshow since it isn't a user-driven dismiss.
        isReanchoring = true
        popover.performClose(nil)
        let midX = button.bounds.midX
        let centerRect = NSRect(x: midX - 0.5, y: button.bounds.minY,
                                width: 1, height: button.bounds.height)
        popover.show(relativeTo: centerRect, of: button, preferredEdge: .minY)
        isReanchoring = false
        mbkLog("PopoverController", "applyContentSize — re-shown at new size, arrow re-centered")
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
        guard !isReanchoring else { return }
        setButtonHighlight(true)
    }

    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose blocked=\(block)")
        return !block
    }

    public func popoverDidClose(_ notification: Notification) {
        guard !isReanchoring else {
            mbkLog("PopoverController", "popoverDidClose — internal re-anchor close, skipping teardown")
            return
        }
        mbkLog("PopoverController", "popoverDidClose")
        setButtonHighlight(false)
        stopEventMonitor()
        overlayGate.hasActiveOverlay = false
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
