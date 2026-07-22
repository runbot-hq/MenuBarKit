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
// ARROW CENTERING — re-anchor via show() on every resize:
//   On first open, show() is called with a 1pt positioningRect centred at
//   button.bounds.midX. AppKit places the arrow correctly from the start.
//
//   On resize (applyContentSize), contentSize is always written first.
//   Then show() is called again with the same positioningRect — UNLESS the
//   menu bar is hidden (auto-hide), in which case show() is skipped to avoid
//   a side-jump. contentSize is still written even when the menu bar is
//   hidden, so the content is correctly sized when the menu bar reappears.
//
//   ❌ Do NOT skip the contentSize write when isMenuBarHidden. The popover
//   is still on screen; stale dimensions break AppKit's internal geometry
//   and can cause an unexpected close on the next resize.
//
//   ❌ Do NOT use setFrameOrigin to correct the arrow after a contentSize
//   write. popover.contentSize and pw.frame.width are not guaranteed to be
//   in sync when the KVO callback fires — AppKit may have auto-resized the
//   window while contentSize still reports the previous value. Any chrome /
//   delta math built on those values produces wrong geometry.
//
//   ❌ Do NOT call show() before writing contentSize — AppKit sizes the
//   window at show() time. Wrong contentSize = wrong initial placement.
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
//   the side-jump), preferredContentSize never changes.
//   view.frame IS updated live by SwiftUI on every layout pass.
//   We read fittingSize (not view.frame.size) — fittingSize is the
//   fully-settled ideal size; view.frame fires on intermediate passes.
//
// SIDE-JUMP UNDER AUTO-HIDE MENUBAR:
//   isMenuBarHidden = screenH < 0 || buttonY >= screenH
//   show() re-anchor is skipped when true. contentSize write is NOT skipped.

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

    /// Returns the 1pt-wide positioningRect centred at button.bounds.midX.
    /// Used both for initial show() and for re-anchor on resize.
    private func centerRect(for button: NSButton) -> NSRect {
        let midX = button.bounds.midX
        return NSRect(x: midX - 0.5, y: button.bounds.minY,
                      width: 1, height: button.bounds.height)
    }

    /// Opens the popover, pre-sizing to fittingSize so AppKit places the
    /// arrow correctly from the start.
    ///
    /// ❌ Do NOT call show() before writing contentSize — AppKit sizes the
    /// window at show() time using whatever contentSize is set.
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
    /// a side-jump. Manual KVO on view.frame drives contentSize instead.
    ///
    /// animates = false — required so the re-anchor show() call in
    /// applyContentSize is instantaneous with no visible transition.
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

    /// Writes the new contentSize, then re-anchors the arrow by calling
    /// show() again — unless the menu bar is currently hidden (auto-hide),
    /// in which case show() is skipped to avoid a side-jump.
    ///
    /// contentSize is ALWAYS written, even when the menu bar is hidden.
    /// Skipping the write causes stale dimensions that break AppKit geometry
    /// and can trigger an unexpected close on the next resize.
    ///
    /// With animates=false, show() on an already-shown popover is
    /// instantaneous — AppKit recomputes arrow position from scratch using
    /// the new contentSize without closing or flashing the window.
    ///
    /// ❌ Do NOT use setFrameOrigin to correct the arrow. popover.contentSize
    /// and pw.frame.width are not in sync when this fires — AppKit may have
    /// auto-resized the window while contentSize still holds the previous
    /// value. Any chrome/delta math on those values is wrong.
    private func applyContentSize(_ preferred: NSSize) {
        guard popover.isShown else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        let currentSize = popover.contentSize
        guard abs(currentSize.width - preferred.width) > 1
                || abs(currentSize.height - preferred.height) > 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }
        guard let button = statusItem.button,
              let buttonWin = button.window else {
            mbkLog("PopoverController", "applyContentSize — no button/window, skipping")
            return
        }
        let buttonY = buttonWin.frame.origin.y
        let screenH = buttonWin.screen?.frame.height ?? -1
        let isMenuBarHidden = screenH < 0 || buttonY >= screenH

        mbkLog("PopoverController",
               "applyContentSize — WRITING (\(preferred.width),\(preferred.height)) "
               + "delta=(\(preferred.width - currentSize.width),\(preferred.height - currentSize.height)) "
               + "isMenuBarHidden=\(isMenuBarHidden)")
        popover.contentSize = preferred

        if isMenuBarHidden {
            // show() would produce a side-jump while the menu bar is hidden.
            // Skip the re-anchor — arrow centering will correct itself on
            // the next openPopover() call when the menu bar is visible again.
            mbkLog("PopoverController", "applyContentSize — skip re-anchor: isMenuBarHidden")
            return
        }

        // Re-anchor: show() recomputes the arrow from the new contentSize
        // and the positioningRect. With animates=false: instantaneous.
        mbkLog("PopoverController", "applyContentSize — re-anchoring arrow via show()")
        popover.show(relativeTo: centerRect(for: button), of: button, preferredEdge: .minY)
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
