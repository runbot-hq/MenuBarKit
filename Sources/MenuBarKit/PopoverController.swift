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
// USAGE:
//   1. Create a MBKPopoverController with your root SwiftUI view and an
//      MBKOverlayGate instance.
//   2. Call `setup()` from applicationDidFinishLaunching.
//
// DISMISS GATE CONTRACT:
//   popoverShouldClose reads overlayGate.hasActiveOverlay.
//
// OUTSIDE-CLICK MONITOR:
//   Started when the popover opens, stopped when it closes.
//
// WORKSPACE OBSERVER — why queue: nil + Task { @MainActor }:
//   queue: nil delivers on the poster's thread; Task { @MainActor } is the
//   Swift 6-correct hop to the main actor — compiler-enforced.
//
// IMPLICIT-UNWRAPPED OPTIONALS (statusItem, popover, hostingController):
//   Assigned in setup(), not init(). Safe because setup() is called from
//   applicationDidFinishLaunching before any user interaction.
//   ❌ Do NOT replace with optionals without restructuring to init-time wiring.
//
// nonisolated(unsafe) — eventMonitor AND workspaceObserver:
//   Both hold non-Sendable AppKit tokens. Every live access is @MainActor.
//   Safe under singleton-lifetime assumption.
//
// deinit TEARDOWN:
//   Do NOT wrap removals in Task { @MainActor } — use-after-free.
//
// ARROW CENTERING — direct window frame adjustment:
//   NSPopover.show(relativeTo:of:preferredEdge:) positions the popover so
//   the arrow points at the positioningRect, but then shifts the window
//   leftward to keep it on-screen. This makes the arrow appear off-center
//   relative to the popover body when the popover is wide.
//
//   show() on an already-shown popover is ignored by AppKit — it does NOT
//   reposition the window. So calling show() again after contentSize write
//   does nothing.
//
//   Correct fix: after show() (and after contentSize write), directly set
//   popover window frame.origin.x in screen coordinates so the window is
//   horizontally centered under the status bar button. The button midX in
//   screen coords is:
//     buttonMidXScreen = buttonWinFrame.origin.x + button.frame.midX
//   Then:
//     popoverWindow.origin.x = buttonMidXScreen - popoverWindow.frame.width / 2
//   Clamp to screen bounds so we never push off-screen.
//
//   After the initial show(), the window frame isn't final until after the
//   run loop tick, so we defer with DispatchQueue.main.async.
//   After a contentSize write the frame IS updated synchronously, so we
//   can center immediately.
//
// SIDE-JUMP UNDER AUTO-HIDE MENUBAR (HIDDEN STATE) — fix/side-jump-autohide:
//   When macOS auto-hide menubar is hidden the Dock pushes the NSStatusItem
//   button window off the top edge: buttonWin.frame.origin.y >= screen.frame.height.
//   In this state ANY contentSize write causes AppKit to collapse the popover
//   x-origin to 0 (side-jump).
//
//   Fix: observe hostingController.view \.frame (updated live by SwiftUI).
//   Guard the contentSize write with isMenuBarHidden. Skip when hidden.
//
//   CORRECT isMenuBarHidden signal: screenH < 0 || buttonY >= screenH
//   ❌ Do NOT use buttonScreen != nil && buttonY >= screenH.
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
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // ❌ DO NOT replace with NSApp.activate() (no-arg, macOS 14+ form) —
        // causes popover window to flicker. ignoringOtherApps: true must stay.
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
        // Defer centering by one run loop tick — the popover window frame is
        // not final until after show() returns and the run loop processes it.
        // See ARROW CENTERING in the file header.
        DispatchQueue.main.async { [weak self] in
            self?.centerPopoverWindow()
        }
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover window centering

    /// Centers the popover window horizontally under the status bar button
    /// by directly adjusting the window's screen-coordinate origin.
    ///
    /// show() shifts the popover leftward to keep it on-screen, making the
    /// arrow appear off-center. We correct this by computing where the popover
    /// window's left edge should be for perfect centering under the button,
    /// then clamping to screen bounds.
    ///
    /// See ARROW CENTERING in the file header.
    private func centerPopoverWindow() {
        guard let button = statusItem.button,
              let buttonWin = button.window,
              let popoverWin = popover.contentViewController?.view.window,
              let screen = buttonWin.screen ?? NSScreen.main else { return }

        // Button midX in screen coordinates.
        let buttonFrameInScreen = buttonWin.convertToScreen(button.convert(button.bounds, to: nil))
        let buttonMidX = buttonFrameInScreen.midX

        // Desired popover origin: centered under button, clamped to screen.
        let popW = popoverWin.frame.width
        let screenMinX = screen.visibleFrame.minX
        let screenMaxX = screen.visibleFrame.maxX
        let desiredX = (buttonMidX - popW / 2)
            .clamped(to: screenMinX...(screenMaxX - popW))

        var newFrame = popoverWin.frame
        newFrame.origin.x = desiredX
        popoverWin.setFrameOrigin(newFrame.origin)
        mbkLog("PopoverController", "centerPopoverWindow — buttonMidX=\(buttonMidX) popW=\(popW) desiredX=\(desiredX)")
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

    // MARK: - Hosting view frame observer

    private func setupSizeObserver() {
        sizeObservation = hostingController.view.observe(
            \.frame,
            options: [.new]
        ) { [weak self] view, _ in
            Task { @MainActor [weak self] in
                self?.applyPreferredContentSize(view.frame.size)
            }
        }
    }

    private func applyPreferredContentSize(_ preferred: NSSize) {
        guard popover.isShown else {
            mbkLog("PopoverController", "applyPreferredContentSize — popover not shown, skipping")
            return
        }
        guard preferred.width > 0, preferred.height > 0 else {
            mbkLog("PopoverController", "applyPreferredContentSize — zero size, skipping")
            return
        }
        let currentSize = popover.contentSize
        let buttonWin = statusItem.button?.window
        let buttonWinFrame = buttonWin?.frame
        let buttonScreen = buttonWin?.screen
        let buttonY = buttonWinFrame?.origin.y ?? -1
        let screenH = buttonScreen?.frame.height ?? -1
        let isMenuBarHidden = screenH < 0 || buttonY >= screenH
        mbkLog("PopoverController",
               "applyPreferredContentSize — "
               + "preferred=(\(preferred.width),\(preferred.height)) "
               + "current=(\(currentSize.width),\(currentSize.height)) "
               + "buttonY=\(buttonY) screenH=\(screenH) isMenuBarHidden=\(isMenuBarHidden)")
        guard !isMenuBarHidden else {
            mbkLog("PopoverController", "applyPreferredContentSize — SKIP: isMenuBarHidden=true")
            return
        }
        guard abs(currentSize.width - preferred.width) > 1
                || abs(currentSize.height - preferred.height) > 1 else {
            mbkLog("PopoverController", "applyPreferredContentSize — no-op: size unchanged")
            return
        }
        mbkLog("PopoverController",
               "applyPreferredContentSize — WRITING (\(preferred.width),\(preferred.height)) "
               + "delta=(\(preferred.width - currentSize.width),\(preferred.height - currentSize.height))")
        popover.contentSize = preferred
        // Re-center the window after the size write. The frame updates
        // synchronously so we can center immediately.
        centerPopoverWindow()
        mbkLog("PopoverController", "applyPreferredContentSize — done")
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

// MARK: - Comparable clamped helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
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
