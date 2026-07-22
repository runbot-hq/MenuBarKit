// PopoverController.swift
// MenuBarKit
//
// Owns the full NSPopover + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// ARROW CENTERING:
//   show() pre-sizes contentSize to fittingSize so AppKit places the window
//   at the correct width immediately. A 1pt positioningRect at button midX
//   is used so AppKit anchors the arrow to the button center.
//
//   On resize (applyContentSize), we compute:
//
//     buttonMidXOnScreen = buttonWin.frame.minX + button.frame.midX
//     targetX            = buttonMidXOnScreen - preferred.width / 2
//     clampedX           = clamped to screen.visibleFrame
//
//   We write contentSize and setFrameOrigin back-to-back in the same
//   runloop cycle. Using preferred.width (the final intended width) —
//   NOT pw.frame.width which is already stale after AppKit's internal
//   auto-layout resize pass — ensures the correction is always exact.
//
//   popover.animates = false — prevents animation from showing the wrong
//   pre-correction position.
//
// SIDE-JUMP UNDER AUTO-HIDE MENUBAR:
//   Signal: buttonY >= screenH (Dock pushes NSStatusItem window off top edge).
//   Observed values: buttonY=982 screenH=982 when hidden.
//
//   buttonWin.screen can transiently return nil while the menubar is hiding.
//   We fall back to NSScreen.main rather than treating nil as "hidden".
//   Only skip the contentSize write when we have a real screenH and
//   buttonY >= screenH. If there is genuinely no screen, use
//   CGFloat.infinity so the write always goes through.

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

        // Pre-size to fittingSize before show() so AppKit places window at
        // correct width from the start.
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

    /// Writes a new contentSize to the popover and corrects the window x so
    /// the arrow stays centered over the status item button.
    ///
    /// Uses `preferred.width` — the final intended width — to compute targetX.
    /// This is critical: by the time this method fires, `pw.frame.width` may
    /// already be stale (AppKit's internal layout pass can pre-resize it),
    /// making `pw.frame.width` unreliable as a width source for centering math.
    /// Using `preferred.width` is always correct regardless of AppKit timing.
    ///
    /// `contentSize` and `setFrameOrigin` are written back-to-back in the same
    /// runloop cycle (with `animates = false`) so there is no intermediate
    /// frame with a wrong x origin.
    ///
    /// Skips the write when the auto-hide menubar is hidden:
    ///   buttonY >= screenH  (Dock pushes NSStatusItem window off top edge)
    /// Falls back to NSScreen.main when buttonWin.screen is transiently nil.
    /// Uses CGFloat.infinity if no screen is available at all, so the write
    /// goes through rather than being skipped on a transient nil.
    private func applyContentSize(_ preferred: NSSize) {
        guard popover.isShown else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        guard let button = statusItem.button,
              let buttonWin = button.window else {
            mbkLog("PopoverController", "applyContentSize — no button/window, skipping")
            return
        }

        // Auto-hide menubar guard.
        // buttonWin.screen can be transiently nil while the menubar is hiding/
        // showing. Fall back to NSScreen.main rather than treating nil as hidden.
        // Only skip when we have a real screen and buttonY >= screenH.
        // If there is genuinely no screen, use .infinity so the write goes through.
        let buttonY = buttonWin.frame.origin.y
        let resolvedScreen = buttonWin.screen ?? NSScreen.main
        let screenH = resolvedScreen?.frame.height ?? CGFloat.infinity
        let isMenuBarHidden = buttonY >= screenH
        mbkLog("PopoverController",
               "applyContentSize — preferred=(\(preferred.width),\(preferred.height)) "
               + "buttonY=\(buttonY) screenH=\(screenH) isMenuBarHidden=\(isMenuBarHidden) "
               + "screenSource=\(buttonWin.screen != nil ? \"buttonWin\" : \"NSScreen.main\")")
        guard !isMenuBarHidden else {
            mbkLog("PopoverController", "applyContentSize — SKIP: menubar hidden (buttonY=\(buttonY) >= screenH=\(screenH))")
            return
        }

        let currentSize = popover.contentSize
        guard abs(currentSize.width - preferred.width) > 1
                || abs(currentSize.height - preferred.height) > 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        guard let screen = resolvedScreen,
              let pw = popover.contentViewController?.view.window else {
            popover.contentSize = preferred
            mbkLog("PopoverController", "applyContentSize — written (no screen for reposition)")
            return
        }

        // Compute targetX from preferred.width (the final intended width).
        // ❌ Do NOT use pw.frame.width here: AppKit's internal layout pass may
        // have pre-resized the window before this fires, making pw.frame.width
        // unreliable. preferred.width is always the correct value to center on.
        let buttonMidX = buttonWin.frame.minX + button.frame.midX
        let targetX = max(
            screen.visibleFrame.minX,
            min(buttonMidX - preferred.width / 2,
                screen.visibleFrame.maxX - preferred.width)
        )

        mbkLog("PopoverController",
               "applyContentSize — WRITING (\(preferred.width),\(preferred.height)) "
               + "targetX=\(targetX) buttonMidX=\(buttonMidX) "
               + "delta=(\(preferred.width - currentSize.width),\(preferred.height - currentSize.height))")

        // Write size then position atomically in the same runloop cycle.
        // animates=false ensures setFrameOrigin is instantaneous with no
        // intermediate frames at the wrong position.
        popover.contentSize = preferred
        pw.setFrameOrigin(NSPoint(x: targetX, y: pw.frame.origin.y))

        mbkLog("PopoverController",
               "applyContentSize — done popoverWin=(\(pw.frame.origin.x),\(pw.frame.origin.y),\(pw.frame.width),\(pw.frame.height))")
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
