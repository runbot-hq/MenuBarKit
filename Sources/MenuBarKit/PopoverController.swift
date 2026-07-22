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
// ARROW CENTERING — 1pt positioningRect at open + origin.x pin + snap:
//   show() is called ONCE per open with a 1pt-wide positioningRect at
//   button.bounds.midX. AppKit centers the popover body on that point so the
//   arrow appears at top-center.
//
//   ❌ Do NOT call show() again after contentSize writes. show() on an
//   already-shown popover re-anchors the window, causing lateral jumps
//   (especially near screen edges where AppKit clamps).
//
//   On contentSize writes, AppKit re-runs anchor geometry and may shift the
//   popover window's x-origin (screen-edge clamping, or side-jump when the
//   auto-hide menubar is hidden). Fix: after show(), pin
//   `pinnedPopoverOriginX = popoverWindow.frame.origin.x`. Install a KVO
//   observer on popoverWindow.frame (windowFrameObservation). Whenever x
//   drifts by more than 1pt, call setFrameOrigin to snap it back.
//
//   pinnedPopoverOriginX and windowFrameObservation are cleared in
//   popoverDidClose so they don't outlive the session.
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
//   We read view.fittingSize inside the Task hop — not view.frame.size —
//   because view.frame fires during intermediate layout passes. fittingSize
//   is always the fully-settled ideal size.
//
// SIDE-JUMP UNDER AUTO-HIDE MENUBAR (HIDDEN STATE) — fix/side-jump-autohide:
//   When macOS auto-hide menubar is hidden the Dock pushes the NSStatusItem
//   button window off the top edge: buttonWin.frame.origin.y >= screen.frame.height.
//   In this state ANY contentSize write causes AppKit to collapse the popover
//   x-origin to 0 (side-jump). The origin.x snap in windowFrameObservation
//   corrects this. The isMenuBarHidden guard in applyContentSize is kept as
//   an additional defence to avoid unnecessary writes.
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

    // MARK: - Arrow centering (fix/arrow-center)

    /// x-origin of the popover window captured immediately after show().
    /// windowFrameObservation snaps x back to this value whenever AppKit drifts
    /// it (screen-edge clamping on contentSize write, or side-jump).
    /// Cleared in popoverDidClose. See ARROW CENTERING in file header.
    private var pinnedPopoverOriginX: CGFloat?

    /// KVO token for the popover window's frame.
    /// Snaps origin.x back to pinnedPopoverOriginX on any drift > 1pt.
    /// Installed in openPopover(), cleared in popoverDidClose.
    /// ❌ Do NOT nil before popoverDidClose — removes the snap guard.
    private var windowFrameObservation: NSKeyValueObservation?

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
    ///
    /// show() is called ONCE per open with a 1pt-wide positioningRect at
    /// button.bounds.midX so AppKit places the popover centered on that point.
    /// After show(), pins origin.x and installs the frame-snap KVO observer.
    ///
    /// ❌ Do NOT call show() again on resize — see ARROW CENTERING in file header.
    private func openPopover() {
        guard let button = statusItem.button else { return }
        let midX = button.bounds.midX
        let centerRect = NSRect(x: midX - 0.5, y: button.bounds.minY,
                                width: 1, height: button.bounds.height)
        popover.show(relativeTo: centerRect, of: button, preferredEdge: .minY)
        // Pin x and install snap immediately after show().
        if let popoverWindow = popover.contentViewController?.view.window {
            let pinnedX = popoverWindow.frame.origin.x
            pinnedPopoverOriginX = pinnedX
            installWindowFrameSnap(on: popoverWindow, pinnedX: pinnedX)
            mbkLog("PopoverController", "openPopover — pinnedX=\(pinnedX)")
        }
        // ❌ DO NOT replace with NSApp.activate() (no-arg, macOS 14+ form) —
        // causes popover window to flicker. ignoringOtherApps: true must stay.
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
    }

    /// Installs a KVO observer on `popoverWindow.frame` that snaps origin.x
    /// back to `pinnedX` whenever AppKit drifts it by more than 1pt.
    /// This corrects screen-edge clamping after contentSize writes and the
    /// auto-hide side-jump collapse. See ARROW CENTERING in file header.
    private func installWindowFrameSnap(on popoverWindow: NSWindow, pinnedX: CGFloat) {
        windowFrameObservation = popoverWindow.observe(\.frame, options: [.new]) { [weak self] win, change in
            guard let newFrame = change.newValue else { return }
            Task { @MainActor [weak self, win] in
                guard let self, let px = self.pinnedPopoverOriginX else { return }
                guard abs(newFrame.origin.x - px) > 1 else { return }
                mbkLog("PopoverController",
                       "windowFrameSnap — x drifted \(newFrame.origin.x) → snapping to \(px)")
                var corrected = newFrame
                corrected.origin.x = px
                win.setFrameOrigin(corrected.origin)
            }
        }
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    /// ❌ Do NOT set sizingOptions = .preferredContentSize — causes side-jump.
    /// Manual KVO on view.frame + isMenuBarHidden guard is used instead.
    private func setupPopover() {
        hostingController = NSHostingController(rootView: rootView)
        // ❌ Do NOT restore sizingOptions = .preferredContentSize — see file header.
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = contentSize
        popover.animates = true
        popover.behavior = .applicationDefined
        popover.delegate = self
        setupSizeObserver()
    }

    // MARK: - Hosting view frame observer

    /// Observes `hostingController.view.frame` to drive `popover.contentSize`.
    ///
    /// We observe view.frame (not preferredContentSize) because preferredContentSize
    /// is only recomputed when sizingOptions includes .preferredContentSize — which
    /// we cannot use (causes side-jump). view.frame is updated live by SwiftUI.
    ///
    /// We read view.fittingSize inside the Task hop, not view.frame.size, because
    /// view.frame fires during intermediate layout passes. fittingSize is always
    /// the fully-settled ideal size. See SIZE OBSERVATION in file header.
    private func setupSizeObserver() {
        sizeObservation = hostingController.view.observe(
            \.frame,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Read fittingSize, not the KVO new value — see SIZE OBSERVATION.
                let settled = self.hostingController.view.fittingSize
                self.applyContentSize(settled)
            }
        }
    }

    /// Writes a new contentSize to the popover.
    /// Skipped when the auto-hide menubar is hidden (additional defence;
    /// origin.x snap in windowFrameObservation handles any drift).
    ///
    /// ❌ Do NOT call show() here after writing contentSize — see ARROW CENTERING.
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
        // ❌ Do NOT call show() here — see ARROW CENTERING in file header.
        // origin.x is corrected by windowFrameObservation snap if AppKit drifts it.
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
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose blocked=\(block)")
        return !block
    }

    public func popoverDidClose(_ notification: Notification) {
        mbkLog("PopoverController", "popoverDidClose")
        setButtonHighlight(false)
        stopEventMonitor()
        overlayGate.hasActiveOverlay = false
        // Clear arrow-centering state — see ARROW CENTERING in file header.
        windowFrameObservation = nil
        pinnedPopoverOriginX = nil
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
