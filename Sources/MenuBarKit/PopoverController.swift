// PopoverController.swift
// MenuBarKit
//
// Owns the full NSPopover + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// ARROW CENTERING:
//   Height-only changes are updated in place via contentSize — AppKit
//   correctly grows/shrinks height from the anchored edge without needing to
//   recompute horizontal centering, so this direction just works.
//
//   WIDTH changes are NOT safe to apply in place. NSPopover only centers its
//   box around positioningRect ONCE, at show() time. Mutating contentSize.width
//   (or re-assigning positioningRect) on an already-visible popover does NOT
//   re-trigger that centering — the box just grows/shrinks from a fixed edge,
//   desyncing visibly from the arrow.
//
//   FIX: when a width change is detected, close the popover and call show()
//   again fresh (mirroring openPopover()'s exact call shape) rather than
//   mutating contentSize in place. popover.animates = false makes this
//   invisible to the user — no flicker.
//
//   ⚠️  CRITICAL GOTCHA — SIZE OBSERVATION: NSView implements MANUAL KVO for
//      `frame`, gated behind `postsFrameChangedNotifications` (defaults to
//      false). Swift's `.observe(\.frame)` SILENTLY NO-OPS without it — no
//      crash, no warning, the closure simply never runs. This bit us for two
//      full commits: our width-reshow logic was 100% correct but dead code,
//      because the observer that was supposed to call it never fired even
//      once. ALWAYS set `postsFrameChangedNotifications = true` and use
//      NotificationCenter + `NSView.frameDidChangeNotification` to observe
//      NSView frame changes — never rely on KVO `.observe(\.frame)` for this.
//
//   ❌ NEVER call pw.setFrameOrigin() / mutate the popover window's frame
//      directly to "correct" its x position. AppKit computes the arrow's
//      position from positioningRect/anchor at show()-time only.
//
//   ⚠️  NEVER call show() without confirming button.bounds is non-zero
//      first (see positioningRect(for:) below). A degenerate zero-size rect
//      makes show() silently fail — no crash, no popover, nothing.

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
    private var isSetUp = false
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?
    nonisolated(unsafe) private var frameChangeObserver: NSObjectProtocol?

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

        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            popover.contentSize = fitting
            mbkLog("PopoverController", "openPopover — pre-sized to (\(fitting.width),\(fitting.height))")
        }

        guard let rect = positioningRect(for: button) else { return }
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
    }

    /// Returns a fresh positioningRect derived from the button's CURRENT
    /// bounds, or nil if those bounds are degenerate (zero width/height).
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

    /// Observes the hosting view's frame via NotificationCenter, NOT KVO.
    /// See the CRITICAL GOTCHA note at the top of this file: NSView's `frame`
    /// KVO is manual and gated behind postsFrameChangedNotifications, which
    /// defaults to false. Without explicitly enabling it, `.observe(\.frame)`
    /// silently never fires. This was the root cause of every prior failure.
    private func setupSizeObserver() {
        let view = hostingController.view
        view.postsFrameChangedNotifications = true
        frameChangeObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: view,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let settled = self.hostingController.view.fittingSize
                self.applyContentSize(settled)
            }
        }
    }

    /// Applies a new preferred content size.
    ///
    /// Height-only changes are written directly to contentSize — AppKit
    /// handles that correctly on an already-visible popover.
    ///
    /// Width changes require a full close+reshow (see ARROW CENTERING note
    /// at top of file) because NSPopover never re-centers its box around
    /// positioningRect except at show() time. animates=false makes this
    /// invisible to the user.
    private func applyContentSize(_ preferred: NSSize) {
        guard popover.isShown, let button = statusItem.button else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        let currentSize = popover.contentSize
        let widthChanged = abs(currentSize.width - preferred.width) > 1
        let heightChanged = abs(currentSize.height - preferred.height) > 1
        guard widthChanged || heightChanged else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        if widthChanged {
            mbkLog("PopoverController",
                   "applyContentSize — width changed (\(currentSize.width)→\(preferred.width)), "
                   + "re-showing popover for correct centering")
            popover.contentSize = preferred
            guard let rect = positioningRect(for: button) else { return }
            popover.performClose(nil)
            popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
            mbkLog("PopoverController", "applyContentSize — re-shown at (\(preferred.width),\(preferred.height))")
        } else {
            mbkLog("PopoverController",
                   "applyContentSize — height-only change, writing (\(preferred.width),\(preferred.height)) "
                   + "prev=(\(currentSize.width),\(currentSize.height))")
            popover.contentSize = preferred
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
        if let observer = frameChangeObserver {
            NotificationCenter.default.removeObserver(observer)
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
