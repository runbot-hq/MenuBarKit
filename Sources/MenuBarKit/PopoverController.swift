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
// ARROW CENTERING — show() under alphaValue=0 on resize:
//   On first open, show() places the arrow correctly from the start.
//
//   On resize (applyContentSize):
//     1. Write contentSize.
//     2. Set pw.alphaValue = 0  (hide the window for the reposition).
//     3. Call show() — re-anchors the arrow from scratch using the new
//        contentSize and the positioningRect. With animates=false this is
//        synchronous; the window is fully repositioned before we return.
//     4. Restore pw.alphaValue = 1.
//
//   The arrow tip is baked in at show() time relative to the positioningRect.
//   setFrameOrigin moves the chrome window but cannot move the arrow —
//   arrow and window decouple after any setFrameOrigin call.
//
//   alphaValue=0 suppresses the visible side-jump that show() would
//   otherwise produce. With animates=false the re-anchor is instantaneous
//   and the alpha restore happens in the same runloop cycle — no flicker.
//
//   ❌ Do NOT use setFrameOrigin to correct arrow position. It moves the
//   window frame but leaves the arrow tip at its original screen position.
//
//   ❌ Do NOT call show() without first setting alphaValue=0. The window
//   will visibly jump to the new position before snapping back.
//
//   ❌ Do NOT call show() before writing contentSize — AppKit sizes the
//   window at show() time. Wrong contentSize = wrong placement.
//
//   ❌ Do NOT set animates=true. The alpha trick only works because show()
//   is synchronous when animates=false.
//
//   ❌ Do NOT add an isMenuBarHidden guard. buttonWin.frame.origin.y drifts
//   after large resizes and misfires even with the menu bar fully visible.
//   The guard was only needed to suppress the side-jump from show() — the
//   alphaValue=0 bracket already does that. No guard needed.
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
    /// Used both for the initial show() and for the re-anchor on resize.
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
    /// animates=false — required so show() in applyContentSize is
    /// synchronous, making the alphaValue=0 guard effective.
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

    /// Resizes the popover and re-anchors the arrow via show().
    ///
    /// The arrow tip is baked in at show() time. setFrameOrigin cannot
    /// move it — it only moves the chrome window, leaving the arrow
    /// misaligned. show() must be called again to re-anchor.
    ///
    /// The visible side-jump that show() would produce is suppressed by
    /// setting pw.alphaValue=0 before the call and restoring it after.
    /// With animates=false, show() is synchronous — the window is fully
    /// repositioned before alphaValue is restored in the same runloop cycle.
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
              let pw = popover.contentViewController?.view.window else {
            mbkLog("PopoverController", "applyContentSize — no button/window, skipping")
            return
        }

        mbkLog("PopoverController",
               "applyContentSize — WRITING (\(preferred.width),\(preferred.height)) "
               + "delta=(\(preferred.width - currentSize.width),\(preferred.height - currentSize.height))")

        // Step 1: write contentSize so show() uses the correct size.
        popover.contentSize = preferred

        // Step 2: hide, re-anchor, restore — all synchronous (animates=false).
        pw.alphaValue = 0
        popover.show(relativeTo: centerRect(for: button), of: button, preferredEdge: .minY)
        pw.alphaValue = 1

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
