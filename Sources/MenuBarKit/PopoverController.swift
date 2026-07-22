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
// ARROW CENTERING — set contentSize before show(), then reposition on resize:
//   show() is called ONCE per open with a 1pt-wide positioningRect at
//   button.bounds.midX.
//
//   BEFORE calling show(), popover.contentSize is set to
//   hostingController.view.fittingSize (if non-zero). This ensures AppKit
//   places the window with the correct width from the start so the arrow
//   is centered immediately.
//
//   ❌ Do NOT call show() before writing contentSize — AppKit places the
//   window based on whatever contentSize is set at show() time. If it is
//   the init default (320x300) and the real content is narrower, the window
//   will be offset and applyContentSize will fight to correct it.
//
//   ❌ Do NOT call show() again after contentSize writes — re-anchors and jumps.
//
//   On subsequent resize (e.g. navigating to a wider/taller view),
//   applyContentSize writes the new contentSize and repositions the window
//   using the WINDOW width (content + chrome), not content width.
//   See ARROW CENTERING — reposition in applyContentSize below.
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
//   In this state ANY contentSize write (and the setFrameOrigin that follows)
//   would use invalid geometry. The isMenuBarHidden guard skips the entire
//   block when hidden.
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
    /// Sets contentSize to fittingSize BEFORE show() so AppKit places the
    /// window at the correct width from the start — arrow centered immediately.
    /// See ARROW CENTERING in file header.
    ///
    /// ❌ Do NOT call show() before writing contentSize.
    /// ❌ Do NOT call show() again on resize — re-anchors and jumps.
    private func openPopover() {
        guard let button = statusItem.button else { return }

        // Set the correct contentSize BEFORE show() so AppKit places the
        // window at the right width. fittingSize is available synchronously
        // because the hosting controller's view has already done its first
        // layout pass by the time the user clicks the status bar button.
        // ❌ Do NOT skip this — the init default (320x300) will mis-place the window.
        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            mbkLog("PopoverController", "openPopover — pre-sizing to fittingSize=(\(fitting.width),\(fitting.height))")
            popover.contentSize = fitting
        }

        let midX = button.bounds.midX
        let centerRect = NSRect(x: midX - 0.5, y: button.bounds.minY,
                                width: 1, height: button.bounds.height)
        popover.show(relativeTo: centerRect, of: button, preferredEdge: .minY)
        // ❌ DO NOT replace with NSApp.activate() (no-arg, macOS 14+ form) —
        // causes popover window to flicker. ignoringOtherApps: true must stay.
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
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

    /// Writes a new contentSize to the popover, then repositions the popover
    /// window so the arrow stays centered under the status-bar button.
    ///
    /// Uses popoverWindow.frame.width (full window width including chrome) after
    /// the contentSize write — NOT preferred.width (content only).
    /// See ARROW CENTERING in file header.
    ///
    /// Skipped entirely when the auto-hide menubar is hidden.
    /// See SIDE-JUMP in file header.
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
        guard let button = statusItem.button,
              let buttonWin = button.window else {
            mbkLog("PopoverController", "applyContentSize — no button/window, skipping")
            return
        }
        let buttonY = buttonWin.frame.origin.y
        let screenH = buttonWin.screen?.frame.height ?? -1
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

        // Reposition window so arrow stays centered under the button.
        // Use popoverWindow.frame.width (window including chrome), NOT preferred.width.
        // button.frame.midX is in button-window coords; add buttonWin.frame.minX
        // to get the screen x coordinate.
        // ❌ Do NOT use preferred.width / 2 — see ARROW CENTERING in file header.
        if let popoverWindow = popover.contentViewController?.view.window,
           let screen = buttonWin.screen {
            let windowWidth = popoverWindow.frame.width
            let buttonMidX = buttonWin.frame.minX + button.frame.midX
            let idealX = buttonMidX - windowWidth / 2
            let clampedX = max(screen.visibleFrame.minX,
                               min(idealX, screen.visibleFrame.maxX - windowWidth))
            let currentX = popoverWindow.frame.origin.x
            if abs(currentX - clampedX) > 1 {
                mbkLog("PopoverController",
                       "applyContentSize — reposition x \(currentX) → \(clampedX) "
                       + "(buttonMidX=\(buttonMidX) windowWidth=\(windowWidth))")
                popoverWindow.setFrameOrigin(NSPoint(x: clampedX, y: popoverWindow.frame.origin.y))
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
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
