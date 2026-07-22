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
//   on an already-visible popover does NOT re-trigger that centering — the
//   box just grows/shrinks from a fixed edge, desyncing visibly from the
//   arrow.
//
//   FIX: when a width change is detected, close the popover and call show()
//   again fresh (mirroring openPopover()'s exact call shape). popover.animates
//   = false makes this invisible to the user — no flicker.
//
//   ⚠️  CRITICAL GOTCHA — SIZE OBSERVATION: DO NOT try to observe the hosted
//      SwiftUI content's size from the AppKit side. Two separate approaches
//      were tried and BOTH silently failed to ever fire in practice:
//        1. hostingController.view.observe(\.frame) — NSView's `frame` uses
//           manual KVO gated behind postsFrameChangedNotifications, which
//           defaults to false.
//        2. NotificationCenter + NSView.frameDidChangeNotification, even
//           after explicitly setting postsFrameChangedNotifications = true.
//      Root cause of #2 not fully isolated, but suspect NSHostingController
//      manages its root view's frame through a path that doesn't consistently
//      post this notification for programmatic (non-user-drag) resizes.
//
//      INSTEAD: capture size directly from SwiftUI via an internal
//      GeometryReader wrapping rootView, reporting through onChange — see
//      wrappedRootView below. SwiftUI always knows its own size accurately
//      (confirmed reliable via the example app's own debug GeometryReader
//      logging on every test run). Route that size straight into
//      applyContentSize() with no AppKit observation layer in between.
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
    private let symbolName: String
    private let contentSize: NSSize

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
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
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.contentSize = contentSize
        // Deferred: wrappedRootView needs `self` for the onChange callback,
        // so it's built in setupPopover() once `self` is fully initialized.
        self.pendingRootView = AnyView(rootView)
    }

    private var pendingRootView: AnyView

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
        // Wrap the caller's root view in a GeometryReader that reports size
        // changes straight to applyContentSize() — see CRITICAL GOTCHA note
        // at the top of this file for why we no longer try to observe size
        // from the AppKit/NSView side.
        let wrapped = pendingRootView
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size) { _, newSize in
                            applyContentSize(newSize)
                        }
                        .onAppear {
                            applyContentSize(geo.size)
                        }
                }
            )
        hostingController = NSHostingController(rootView: AnyView(wrapped))
        hostingController.sizingOptions = []
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = contentSize
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    /// Applies a new preferred content size, called directly from the
    /// SwiftUI GeometryReader wrapping the root view (see setupPopover()).
    ///
    /// Height-only changes are written directly to contentSize — AppKit
    /// handles that correctly on an already-visible popover.
    ///
    /// Width changes require a full close+reshow (see ARROW CENTERING note
    /// at top of file) because NSPopover never re-centers its box around
    /// positioningRect except at show() time. animates=false makes this
    /// invisible to the user.
    private func applyContentSize(_ preferred: CGSize) {
        guard let button = statusItem.button else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        let currentSize = popover.contentSize
        let widthChanged = abs(currentSize.width - preferred.width) > 1
        let heightChanged = abs(currentSize.height - preferred.height) > 1
        guard widthChanged || heightChanged else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        guard popover.isShown else {
            // Popover not visible yet (e.g. first layout pass before show()).
            // Just record the size for the next openPopover() pre-size read.
            popover.contentSize = preferred
            mbkLog("PopoverController", "applyContentSize — popover not shown, recorded (\(preferred.width),\(preferred.height))")
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
