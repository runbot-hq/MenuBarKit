// PopoverController.swift
// MenuBarKit
//
// Owns the full NSPopover + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// RESPONSIBILITIES:
//   - Create and show/hide the NSPopover
//   - Manage the NSStatusItem button highlight
//   - Install/remove the outside-click NSEvent monitor
//   - Install/remove the NSWorkspace app-switch observer
//   - Implement popoverShouldClose via the MBKOverlayGate
//   - Reset the overlay gate in popoverDidClose (safety net)
//
// ARROW CENTERING — nuclear close+reopen on resize:
//   On first open, show() creates the NSPopoverFrame at the correct size
//   and position from scratch. Arrow is correct by construction.
//
//   On resize (applyContentSize):
//     1. Set isResizing = true.
//     2. popover.close() — destroys the NSPopoverFrame window entirely.
//        Bypasses popoverShouldClose (close() never calls it).
//        popoverDidClose fires but isResizing gates out all teardown.
//     3. Set popover.contentSize = preferred.
//     4. popover.show() — creates a FRESH NSPopoverFrame at exactly the
//        correct size and anchor. No intermediate wrong-position window
//        ever exists. No jump. Arrow correct by construction.
//     5. Set isResizing = false.
//
//   ❌ Do NOT use show() on an already-shown popover to re-anchor.
//   AppKit moves the existing NSPopoverFrame window via the window server.
//   The position change is submitted to the compositor asynchronously —
//   alphaValue tricks cannot hide it because the CA transaction and the
//   window server move are on separate threads from the alpha write.
//
//   ❌ Do NOT use setFrameOrigin. Moves the chrome, not the arrow.
//
//   ❌ Do NOT call performClose() for the silent resize close.
//   performClose() calls popoverShouldClose, which may return false when
//   the overlay gate is active, blocking the resize entirely.
//
//   ❌ Do NOT call popover.close() from outside applyContentSize without
//   setting isResizing = true first. popoverDidClose will tear down the
//   event monitor and reset the overlay gate.
//
// STAY-OPEN-WHILE-SHEET-ACTIVE — deliberate trade-off:
//   When a sheet (or file picker) is live, MBKPopoverController keeps the
//   popover open on app-switch and outside-click.
//   popoverShouldClose returns false (via overlayGate.hasActiveOverlay).
//
// DISMISS GATE CONTRACT:
//   MBKAnchoredSheet and mbkOpenFilePicker manage the gate automatically.
//
// OUTSIDE-CLICK MONITOR:
//   Started when the popover opens, stopped when it closes.
//   Unaffected by resize close+reopen (isResizing gates stopEventMonitor).
//
// WORKSPACE OBSERVER — why queue: nil + Task { @MainActor }:
//   queue: nil delivers on the poster's thread; Task { @MainActor } is the
//   Swift 6-correct hop to the main actor.
//
// IMPLICIT-UNWRAPPED OPTIONALS (statusItem, popover, hostingController):
//   Assigned in setup(), not init(). setup() must be called from
//   applicationDidFinishLaunching before any user interaction.
//   ❌ Do NOT replace with optionals without restructuring to init-time wiring.
//
// nonisolated(unsafe) — eventMonitor AND workspaceObserver:
//   Both hold non-Sendable AppKit tokens. Every live read/write is
//   @MainActor-isolated.
//   ❌ Do NOT add @unchecked Sendable as a workaround.
//
// deinit TEARDOWN:
//   ❌ Do NOT wrap removals in Task { @MainActor } — use-after-free.
//
// SIZE OBSERVATION — why observe view.frame and read fittingSize:
//   preferredContentSize is only recomputed when sizingOptions includes
//   .preferredContentSize. With sizingOptions empty (required to prevent
//   AppKit from auto-resizing the window), preferredContentSize never
//   changes. view.frame IS updated live by SwiftUI on every layout pass.
//   We read fittingSize (not view.frame.size) — fittingSize is the
//   fully-settled ideal size; view.frame fires on intermediate passes.

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
    /// True while applyContentSize is executing a silent close+reopen.
    /// Gates popoverDidClose and popoverWillShow so teardown and
    /// highlight changes are suppressed during the invisible resize.
    private var isResizing = false
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

    /// Returns the 1pt-wide positioningRect centred at button.bounds.midX.
    private func centerRect(for button: NSButton) -> NSRect {
        let midX = button.bounds.midX
        return NSRect(x: midX - 0.5, y: button.bounds.minY,
                      width: 1, height: button.bounds.height)
    }

    /// Opens the popover, pre-sizing to fittingSize so the fresh NSPopoverFrame
    /// is created at the correct dimensions and arrow position from the start.
    ///
    /// ❌ Do NOT call show() before writing contentSize.
    private func openPopover() {
        guard let button = statusItem.button else { return }
        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            popover.contentSize = fitting
            mbkLog("PopoverController", "openPopover — pre-sized to (\(fitting.width),\(fitting.height))")
        }
        popover.show(relativeTo: centerRect(for: button), of: button, preferredEdge: .minY)
        // ❌ DO NOT replace with NSApp.activate() (no-arg) — causes flicker.
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    /// sizingOptions is intentionally empty — .preferredContentSize causes
    /// AppKit to auto-resize the window, fighting our manual contentSize writes.
    ///
    /// animates=false — required so close() and show() in applyContentSize
    /// are instantaneous. Any animation would make the blank frame visible.
    /// ❌ Do NOT set animates=true.
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

    /// Resizes the popover by closing it and reopening it at the new size.
    ///
    /// This is the only approach that guarantees zero visible jump and a
    /// correctly placed arrow. Any technique that mutates an already-shown
    /// popover window (setFrameOrigin, show() re-call, alphaValue tricks)
    /// races the window server compositor and produces a visible artifact.
    ///
    /// close() destroys the NSPopoverFrame. show() creates a new one at
    /// exactly the right geometry. The window never exists at a wrong position.
    private func applyContentSize(_ preferred: NSSize) {
        guard popover.isShown else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        let currentSize = popover.contentSize
        guard abs(currentSize.width - preferred.width) > 1
                || abs(currentSize.height - preferred.height) > 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }
        guard let button = statusItem.button else {
            mbkLog("PopoverController", "applyContentSize — no button, skipping")
            return
        }

        mbkLog("PopoverController",
               "applyContentSize — WRITING (\(preferred.width),\(preferred.height)) "
               + "delta=(\(preferred.width - currentSize.width),\(preferred.height - currentSize.height))")

        isResizing = true
        popover.close()                        // destroys NSPopoverFrame; popoverDidClose fires but is gated
        popover.contentSize = preferred        // set size before show() so the new frame is created correctly
        popover.show(relativeTo: centerRect(for: button), of: button, preferredEdge: .minY)
        isResizing = false

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
        // Skip highlight change during silent resize — button stays highlighted throughout.
        guard !isResizing else { return }
        setButtonHighlight(true)
    }

    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // close() never calls this; only performClose() does.
        // This is only reached for real user-initiated dismissals.
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose blocked=\(block)")
        return !block
    }

    public func popoverDidClose(_ notification: Notification) {
        // During a silent resize close, skip all teardown.
        // The event monitor, overlay gate, and button highlight must
        // remain intact — the popover is immediately reopened.
        guard !isResizing else {
            mbkLog("PopoverController", "popoverDidClose — resize in progress, skipping teardown")
            return
        }
        mbkLog("PopoverController", "popoverDidClose")
        setButtonHighlight(false)
        stopEventMonitor()
        overlayGate.hasActiveOverlay = false
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
