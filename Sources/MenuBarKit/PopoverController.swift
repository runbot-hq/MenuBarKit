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
// STAY-OPEN-WHILE-SHEET-ACTIVE — deliberate trade-off:
//   When a sheet (or file picker) is live, MBKPopoverController keeps the
//   popover open on app-switch and outside-click instead of hiding it.
//   popoverShouldClose returns false (via overlayGate.hasActiveOverlay), and
//   the workspace observer skips performClose while any overlay is active.
//
//   This is the simpler behaviour: the user's mental model is "sheet is
//   blocking, nothing else happens until I dismiss it." No hide-and-restore
//   cycle to reason about.
//
// USAGE:
//   1. Create a MBKPopoverController with your root SwiftUI view and an
//      MBKOverlayGate instance.
//   2. Call `setup()` from applicationDidFinishLaunching — see setup() doc
//      comment for the strict ordering requirement.
//
// DISMISS GATE CONTRACT:
//   popoverShouldClose reads overlayGate.hasActiveOverlay. MBKAnchoredSheet
//   and mbkOpenFilePicker manage the gate automatically — the host app never
//   needs to touch it directly.
//
// OUTSIDE-CLICK MONITOR:
//   Started when the popover opens, stopped when it closes. Never leaks a
//   persistent global listener.
//
// WORKSPACE OBSERVER — why queue: nil + Task { @MainActor } (not queue: .main):
//   queue: nil delivers on the poster's thread; Task { @MainActor } is then
//   the Swift 6-correct hop to the main actor — compiler-enforced, not
//   asserted.
//
// WORKSPACE OBSERVER — performClose on already-closed popover:
//   NSPopover.performClose on a closed popover is a documented no-op.
//   The guard self.popover.isShown makes the intent explicit.
//
// IMPLICIT-UNWRAPPED OPTIONALS (statusItem, popover, hostingController):
//   Assigned in setup(), not init(). Safe because setup() must be called
//   from applicationDidFinishLaunching before any user interaction.
//   ❌ Do NOT replace with optionals without restructuring to init-time wiring.
//
// nonisolated(unsafe) — eventMonitor AND workspaceObserver:
//   Both hold non-Sendable AppKit tokens. Every live read/write is
//   @MainActor-isolated. Safe under singleton-lifetime assumption.
//   ❌ Do NOT add @unchecked Sendable as a workaround.
//
// deinit TEARDOWN:
//   Safe under singleton-lifetime assumption — deinit runs after all
//   @MainActor work completes. Do NOT wrap removals in Task { @MainActor }
//   — that would be use-after-free.
//
// ARROW CENTERING — 1pt positioningRect + re-open without animation on resize:
//   NSPopover.show(relativeTo:of:preferredEdge:) anchors the arrow to the
//   midX of the positioningRect and centers the popover body on that point.
//   Passing button.bounds causes AppKit to shift the popover leftward to
//   keep it on-screen, making the arrow appear off-center relative to the
//   popover body.
//
//   Open fix: pass a 1pt-wide rect at button.bounds.midX. AppKit centers
//   the popover on that point, arrow appears at top-center.
//
//   Resize fix: show() on an ALREADY-SHOWN NSPopover is a no-op — AppKit
//   ignores it and does not reposition. After writing contentSize, AppKit
//   re-runs anchor geometry using its INTERNALLY STORED positioningRect
//   (button.bounds), not our 1pt rect — arrow drifts off-center.
//
//   ❌ Do NOT call show() again after contentSize write — it is silently
//   ignored. The comment "show() on an already-shown popover is a silent
//   reposition" is WRONG and has been confirmed not to work.
//
//   Correct fix: close + re-open with animation disabled so AppKit re-runs
//   full anchor geometry from scratch using our centerRect.
//   popover.animates = false makes the close+open instantaneous (no flash).
//   Restore animates = true immediately after show() so future
//   open/close cycles animate normally.
//
//   During the close+open cycle, popoverShouldClose and popoverDidClose
//   fire. We guard against side-effects with isReanchoring:
//     - popoverShouldClose returns true (allow close) regardless of
//       overlayGate when isReanchoring.
//     - popoverDidClose skips highlight/monitor/gate cleanup when
//       isReanchoring.
//
//   centerRect(for:) is a shared helper used by openPopover() and
//   reanchorPopover().
//
// SIZE OBSERVATION — why observe view.frame and read fittingSize:
//   preferredContentSize on NSHostingController is only recomputed when
//   sizingOptions includes .preferredContentSize. With sizingOptions empty
//   (required to prevent the side-jump), preferredContentSize never changes
//   and KVO on it never fires.
//
//   The hosting view's frame IS updated live by SwiftUI on every layout pass
//   regardless of sizingOptions, making it the correct signal to observe.
//
//   However, view.frame fires during intermediate layout passes where the
//   frame may not yet be fully settled. Reading view.frame.size at that
//   moment gives a partially-settled value. Instead we read
//   hostingController.view.fittingSize inside the Task hop — fittingSize
//   asks AppKit for the view's ideal size given its current constraints and
//   is always the fully-settled value.
//
// SIDE-JUMP UNDER AUTO-HIDE MENUBAR (HIDDEN STATE) — fix/side-jump-autohide:
//   When macOS auto-hide menubar is hidden the Dock pushes the NSStatusItem
//   button window off the top edge: buttonWin.frame.origin.y >= screen.frame.height.
//   In this state ANY contentSize write causes AppKit to re-run full anchor
//   geometry against the off-screen button position, collapsing the popover
//   x-origin to 0 (side-jump).
//
//   CORRECT isMenuBarHidden signal:
//     screenH < 0 || buttonY >= screenH
//
//   screenH < 0 → button.window.screen == nil (button slid off-screen).
//   buttonY >= screenH → normal hidden case, screen still associated.
//
//   WRONG signals (do not use):
//     button.window.screen == nil alone  ← misses buttonY >= screenH case
//     buttonScreen != nil && buttonY >= screenH  ← misses screen==nil case
//
//   See runbot-hq/run-bot#2239.

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

    /// KVO token for `hostingController.view.frame`.
    /// See SIZE OBSERVATION in the file header.
    private var sizeObservation: NSKeyValueObservation?

    /// True while applyContentSize is executing a close+reopen cycle to
    /// re-anchor the popover. Guards popoverShouldClose and popoverDidClose
    /// against side-effects during the cycle. See ARROW CENTERING in file header.
    private var isReanchoring = false

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

    /// Shows the popover centered under the status-bar button.
    /// Uses a 1pt-wide positioningRect at button midX — see ARROW CENTERING in file header.
    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: centerRect(for: button), of: button, preferredEdge: .minY)
        // ❌ DO NOT replace with NSApp.activate() (no-arg, macOS 14+ form) —
        // causes popover window to flicker. ignoringOtherApps: true must stay.
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
    }

    /// Returns a 1pt-wide rect at the horizontal center of the button's bounds.
    /// Passed as positioningRect to show() so AppKit centers the popover and
    /// its arrow under the button. See ARROW CENTERING in file header.
    private func centerRect(for button: NSButton) -> NSRect {
        let midX = button.bounds.midX
        return NSRect(x: midX - 0.5, y: button.bounds.minY,
                      width: 1, height: button.bounds.height)
    }

    /// Closes and immediately re-opens the popover without animation so AppKit
    /// re-runs full anchor geometry using our 1pt centerRect.
    ///
    /// Called after writing contentSize when the popover is already shown.
    /// show() on an already-shown popover is a no-op; this is the only way
    /// to force AppKit to re-anchor. See ARROW CENTERING in file header.
    private func reanchorPopover() {
        guard let button = statusItem.button else { return }
        isReanchoring = true
        popover.animates = false
        popover.performClose(nil)
        popover.show(relativeTo: centerRect(for: button), of: button, preferredEdge: .minY)
        popover.animates = true
        isReanchoring = false
        mbkLog("PopoverController", "reanchorPopover — done")
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    /// ❌ Do NOT set sizingOptions = .preferredContentSize — causes side-jump.
    /// Manual KVO on view.frame + isMenuBarHidden guard is used instead.
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

    // MARK: - Hosting view frame observer

    private func setupSizeObserver() {
        sizeObservation = hostingController.view.observe(
            \.frame,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let settled = self.hostingController.view.fittingSize
                self.applyContentSize(settled)
            }
        }
    }

    /// Writes a new contentSize to the popover and re-anchors it so the arrow
    /// stays centered. Skipped when the auto-hide menubar is hidden.
    ///
    /// After writing contentSize, closes and re-opens the popover without
    /// animation to force AppKit to re-run anchor geometry with our centerRect.
    /// See ARROW CENTERING and SIDE-JUMP in file header.
    private func applyContentSize(_ preferred: NSSize) {
        guard popover.isShown else {
            mbkLog("PopoverController", "applyContentSize — popover not shown, skipping")
            return
        }
        guard preferred.width > 0, preferred.height > 0 else {
            mbkLog("PopoverController", "applyContentSize — zero size (\(preferred.width),\(preferred.height)), skipping")
            return
        }
        let currentSize = popover.contentSize
        let buttonWin = statusItem.button?.window
        let buttonWinFrame = buttonWin?.frame
        let buttonScreen = buttonWin?.screen
        let buttonY = buttonWinFrame?.origin.y ?? -1
        let screenH = buttonScreen?.frame.height ?? -1
        // fix/side-jump-autohide: screenH < 0 means screen==nil (button off-screen);
        // buttonY >= screenH is the normal hidden case. Both mean skip the write.
        // ❌ Do NOT use `buttonScreen != nil && buttonY >= screenH`.
        let isMenuBarHidden = screenH < 0 || buttonY >= screenH
        mbkLog("PopoverController",
               "applyContentSize — "
               + "preferred=(\(preferred.width),\(preferred.height)) "
               + "current=(\(currentSize.width),\(currentSize.height)) "
               + "buttonY=\(buttonY) screenH=\(screenH) "
               + "isMenuBarHidden=\(isMenuBarHidden)")
        guard !isMenuBarHidden else {
            mbkLog("PopoverController", "applyContentSize — SKIP: isMenuBarHidden=true")
            return
        }
        guard abs(currentSize.width - preferred.width) > 1
                || abs(currentSize.height - preferred.height) > 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }
        mbkLog("PopoverController",
               "applyContentSize — WRITING (\(preferred.width),\(preferred.height)) "
               + "delta=(\(preferred.width - currentSize.width),\(preferred.height - currentSize.height))")
        popover.contentSize = preferred
        // Close + re-open without animation to force AppKit to re-anchor.
        // ❌ Do NOT replace with show() — show() on an already-shown popover
        //    is a no-op. See ARROW CENTERING in file header.
        reanchorPopover()
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

    // MARK: - Deallocation

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
        // Allow close unconditionally during reanchoring — the popover is
        // immediately re-opened. See ARROW CENTERING in file header.
        if isReanchoring { return true }
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose blocked=\(block)")
        return !block
    }

    public func popoverDidClose(_ notification: Notification) {
        // Skip side-effects during reanchoring — popover is immediately re-opened.
        // See ARROW CENTERING in file header.
        if isReanchoring { return }
        mbkLog("PopoverController", "popoverDidClose")
        setButtonHighlight(false)
        stopEventMonitor()
        overlayGate.hasActiveOverlay = false
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
