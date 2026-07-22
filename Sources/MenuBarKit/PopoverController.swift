// PopoverController.swift
// MenuBarKit
//
// Owns the full NSPopover + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// ARROW CENTERING:
//   Both contentSize.width AND height are allowed to vary per-view. The rule
//   that keeps the arrow correctly anchored through every resize:
//
//     After every contentSize write (in applyContentSize()), re-derive
//     positioningRect from the button's CURRENT bounds and re-assign it to
//     the popover. positioningRect is AppKit's own anchor INPUT, expressed in
//     the status-item button's local coordinate space — NOT the window frame.
//     Re-assigning it forces AppKit to fully redo its internal arrow+window-
//     position computation together, from a single source of truth, so the
//     arrow and the box can never disagree about where they are.
//
//   ❌ NEVER call pw.setFrameOrigin() / mutate the popover window's frame
//      directly to "correct" its x position after a contentSize change.
//      AppKit computes the arrow's position from positioningRect/anchor at
//      the time contentSize is set, NOT from wherever the window frame ends
//      up afterward. Manually moving the window after the write creates two
//      disagreeing authorities and they inevitably desync — this is the
//      original bug.
//
//   ❌ NEVER read buttonWin.frame / screen.frame to compute an absolute x
//      position. Those values go transiently invalid during menu-bar
//      auto-hide slide transitions. positioningRect is in button-local
//      coordinates and never touches this data.
//
//   ⚠️  NEVER re-assign positioningRect (or call show()) without first
//      confirming button.bounds is non-zero via canComputePositioningRect().
//      A prior attempt at this fix skipped that guard and broke show()
//      entirely — clicking the status item produced no popover at all,
//      because a zero-size button (read before its first layout pass
//      completed) produced a degenerate zero-size positioningRect.
//
//   popover.animates = false — prevents animation from showing an
//   intermediate, not-yet-anchor-corrected position.

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

        // Pre-size to fittingSize before show() so AppKit places the window
        // at the correct size immediately, avoiding a visible post-show jump.
        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            popover.contentSize = fitting
            mbkLog("PopoverController", "openPopover — pre-sized to (\(fitting.width),\(fitting.height))")
        }

        // Build the anchor rect as a LOCAL value and pass it directly to
        // show() — do NOT round-trip through popover.positioningRect here.
        // At first-show time the status item may not have completed its
        // very first AppKit layout pass, and reading button.bounds back off
        // popover.positioningRect after an intermediate assignment adds a
        // needless extra read of state that isn't guaranteed settled yet.
        // This mirrors the exact call shape that is known to work reliably.
        let midX = button.bounds.midX
        let centerRect = NSRect(x: midX - 0.5, y: button.bounds.minY,
                                width: 1, height: button.bounds.height)
        popover.show(relativeTo: centerRect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
    }

    /// Returns a fresh positioningRect derived from the button's CURRENT
    /// bounds, or nil if those bounds are degenerate (zero width/height).
    /// A zero-size rect must never be written into popover.positioningRect —
    /// that silently breaks AppKit's internal show()/anchor machinery.
    private func positioningRect(for button: NSStatusBarButton) -> NSRect? {
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            mbkLog("PopoverController", "positioningRect — skipped: button.bounds is degenerate \(bounds)")
            return nil
        }
        let midX = bounds.midX
        return NSRect(x: midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    private func setupPopover() {
        hostingController = NSHostingController(rootView: rootView)
        // MUST be []. Leaving this at the macOS default (.preferredContentSize)
        // makes AppKit auto-write contentSize from the SwiftUI view's live
        // intrinsic size on every layout pass — a second, competing write path
        // that races our own applyContentSize() call below.
        hostingController.sizingOptions = []
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

    /// Writes a new contentSize (both width AND height allowed to vary) and
    /// then re-assigns positioningRect — guarded against degenerate button
    /// bounds — so AppKit fully redoes its own arrow+window-position
    /// computation against the new size. This is the only operation that
    /// should ever influence the popover's on-screen x position. Never
    /// follow this with a manual setFrameOrigin() call.
    private func applyContentSize(_ preferred: NSSize) {
        guard popover.isShown, let button = statusItem.button else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        let currentSize = popover.contentSize
        guard abs(currentSize.width - preferred.width) > 1
                || abs(currentSize.height - preferred.height) > 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        mbkLog("PopoverController",
               "applyContentSize — writing (\(preferred.width),\(preferred.height)) "
               + "prev=(\(currentSize.width),\(currentSize.height))")
        popover.contentSize = preferred

        // Only re-assign positioningRect if the button currently reports
        // valid (non-zero) bounds. By this point in the popover's lifecycle
        // the button has already been laid out at least once (it was used
        // to show() the popover originally), so this should always succeed
        // in practice — but the guard costs nothing and eliminates the
        // exact failure mode that broke the previous attempt.
        if let rect = positioningRect(for: button) {
            popover.positioningRect = rect
        }
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
