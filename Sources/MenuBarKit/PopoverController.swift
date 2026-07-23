// PopoverController.swift
// MenuBarKit
//
// Owns the full NSPopover + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// ARROW CENTERING:
//   NSPopover only centers its box around positioningRect ONCE, at show()
//   time. Mutating contentSize alone on an already-visible popover does NOT
//   re-trigger that centering — the box just grows/shrinks from a fixed
//   edge, desyncing visibly from the arrow.
//
//   FIX (current): capture the popover window's anchor point once in
//   popoverWillShow, then reposition absolutely on every applyContentSize:
//     - anchorPoint.x = popoverWindow.frame.midX   (horizontal center)
//     - anchorPoint.y = popoverWindow.frame.maxY   (top edge, touches menu bar)
//     - origin.x      = anchorPoint.x - popoverWindow.frame.width / 2
//     - origin.y      = anchorPoint.y - popoverWindow.frame.height
//   Both frame dimensions are read after setting contentSize so they reflect
//   the new window size. No delta tracking, no chrome constant, no ordering
//   dependency on when window.frame is read.
//
//   WHY CAPTURE IN popoverWillShow AND NOT ON EVERY CALL:
//   buttonWindow.frame.minY drifts when macOS auto-hides the menu bar.
//   Capturing once at open time locks the anchor to the correct position
//   for the entire session, regardless of menu bar visibility changes.
//
// FORCE-CLOSE vs BLOCK:
//   The overlay gate (hasActiveOverlay) covers three overlay types:
//     1. Sheet       — child window of the popover window.
//     2. File picker — NSOpenPanel, NOT a child window.
//     3. Alert       — system modal, NOT a child window.
//
//   Outside-click (event monitor):
//     Sheet overlays (child windows) → force-close (snapshot + remove child + close).
//     Picker/alert overlays → ignore outside click (user is in a system panel).
//     Detected by checking popoverWindow.childWindows.
//
//   Workspace switch (workspace observer):
//     Any active overlay blocks close. A workspace switch while a picker
//     or alert is open should not close the popover.
//
// SESSION RESPAWN — onWillShow vs onDidShow:
//   onWillShow fires before popover.show(). Safe for restoring route (no
//   gate side effects). NOT safe for isSheetPresented — AnchoredSheet.onChange
//   arms the gate and tries to anchor a sheet window before one exists.
//
//   onDidShow fires via Task { @MainActor } after popover.show(), giving
//   SwiftUI one render cycle to settle. Use this for isSheetPresented and
//   any other state that has overlay gate side effects.

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let symbolName: String
    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat

    // MARK: - Session hooks

    public var onWillShow: (() -> Void)?
    public var onDidShow: (() -> Void)?
    public var onDidClose: (() -> Void)?
    public var onWillForceClose: (() -> Void)?

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    private var isSetUp = false
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    private var anchorPoint: NSPoint?

    // MARK: - Init

    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle",
        minWidth: CGFloat = 200,
        maxWidth: CGFloat = 600,
        maxHeight: CGFloat = 600
    ) {
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.rootView = AnyView(rootView)
    }

    private let rootView: AnyView

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

        onWillShow?()
        mbkLog("PopoverController", "onWillShow fired")

        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            popover.contentSize = clamp(fitting)
        }

        guard let rect = positioningRect(for: button) else { return }
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()

        Task { @MainActor in
            self.onDidShow?()
            mbkLog("PopoverController", "onDidShow fired")
        }
    }

    // MARK: - Window identity helpers

    /// The popover's NSWindow as seen by the hosting controller's view.
    private var hostingWindow: NSWindow? {
        hostingController.view.window
    }

    /// The nonactivating panel window found via NSApp.windows — this is what
    /// MBKSheetAnchorTask uses when calling addChildWindow.
    private var panelWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.nonactivatingPanel) }
    }

    /// True if the sheet child window has been attached.
    /// Uses panelWindow (same lookup as MBKSheetAnchorTask) so both sides
    /// see the same NSWindow instance.
    private var hasSheetChildWindow: Bool {
        let hw = hostingWindow
        let pw = panelWindow
        let hwChildren = hw?.childWindows ?? []
        let pwChildren = pw?.childWindows ?? []
        let same = hw === pw
        mbkLog("PopoverController",
               "hasSheetChildWindow — hostingWindow=\(hw.map { "\($0.windowNumber)" } ?? "nil") "
               + "panelWindow=\(pw.map { "\($0.windowNumber)" } ?? "nil") "
               + "same=\(same) "
               + "hwChildren=\(hwChildren.count) pwChildren=\(pwChildren.count)")
        return !pwChildren.isEmpty
    }

    private func forceClose() {
        mbkLog("PopoverController", "forceClose — snapshotting before teardown")
        onWillForceClose?()
        overlayGate.hasActiveOverlay = false
        if let pw = panelWindow {
            for child in (pw.childWindows ?? []) {
                mbkLog("PopoverController", "forceClose — removing child window \(child.windowNumber)")
                pw.removeChildWindow(child)
                child.orderOut(nil)
            }
        }
        popover.performClose(nil)
    }

    private func positioningRect(for button: NSStatusBarButton) -> NSRect? {
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            mbkLog("PopoverController", "positioningRect — skipped: degenerate bounds \(bounds)")
            return nil
        }
        return NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    private func setupPopover() {
        let wrapped = rootView
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size) { [weak self] _, newSize in
                            self?.applyContentSize(newSize)
                        }
                        .onAppear { [weak self] in
                            self?.applyContentSize(geo.size)
                        }
                }
            )
        hostingController = NSHostingController(rootView: AnyView(wrapped))
        hostingController.sizingOptions = []
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: minWidth, height: 100)
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    private func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minWidth), maxWidth),
            height: min(size.height, maxHeight)
        )
    }

    private func applyContentSize(_ preferred: CGSize) {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else { return }

        guard abs(popover.contentSize.width - clamped.width) > 1
           || abs(popover.contentSize.height - clamped.height) > 1 else {
            return
        }

        guard popover.isShown,
              let window = hostingController.view.window,
              let anchor = anchorPoint else {
            popover.contentSize = clamped
            mbkLog("PopoverController", "applyContentSize — not shown, recorded (\(clamped.width),\(clamped.height))")
            return
        }

        mbkLog("PopoverController",
               "applyContentSize — (\(popover.contentSize.width),\(popover.contentSize.height))→"
               + "(\(clamped.width),\(clamped.height))")

        popover.contentSize = clamped

        let newOrigin = NSPoint(
            x: anchor.x - window.frame.width / 2,
            y: anchor.y - window.frame.height
        )
        window.setFrameOrigin(newOrigin)
        mbkLog("PopoverController", "applyContentSize — origin set to \(newOrigin)")
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
                guard let self else { return }
                if overlayGate.hasActiveOverlay {
                    if hasSheetChildWindow {
                        mbkLog("PopoverController", "event monitor — sheet overlay, force-closing")
                        forceClose()
                    } else {
                        mbkLog("PopoverController", "event monitor — picker/alert overlay, ignoring outside click")
                    }
                } else {
                    popover.performClose(nil)
                }
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
        guard let window = hostingController.view.window else { return }
        anchorPoint = NSPoint(x: window.frame.midX, y: window.frame.maxY)
        mbkLog("PopoverController", "popoverWillShow — anchor=\(anchorPoint!)")
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
        anchorPoint = nil
        overlayGate.hasActiveOverlay = false
        mbkLog("PopoverController", "overlay gate reset on close")
        onDidClose?()
        mbkLog("PopoverController", "onDidClose fired")
    }
}
