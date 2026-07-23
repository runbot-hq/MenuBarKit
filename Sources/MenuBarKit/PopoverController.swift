// PopoverController.swift
// MenuBarKit
//
// Owns the NSPanel + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific
// behaviour is injected via closures at configuration time.
//
// SIZING MODEL:
//   NSHostingController.sizingOptions = .preferredContentSize
//   SwiftUI reports its ideal size via preferredContentSize.
//   KVO fires applyContentSize on every layout pass that produces a new size.
//   applyContentSize calls panel.setFrame() — free resize, no re-anchor.
//
// POSITIONING MODEL:
//   On open: panel left edge aligns with the left edge of the status button,
//   clamped so the panel never overflows the screen's visible frame.
//   On resize: anchorX (button.minX in screen coords) + anchorY are
//   re-used to recompute origin from the new size.
//
// VISUAL CHROME:
//   NSGlassEffectView (macOS 26+, WWDC25 session 310) is used directly as
//   panel.contentView. This is the correct pattern — NSVisualEffectView must
//   NOT be used as a wrapper because it prevents NSGlassEffectView from showing
//   through (WWDC25 session 310 explicitly warns against this).
//
// ROUNDED CORNERS / addChildWindow:
//   NSGlassEffectView.cornerRadius is reset by AppKit when addChildWindow() is
//   called (compositing mode change). Fix: observe didAddChildWindowNotification
//   and didRemoveChildWindowNotification on the panel and immediately re-set
//   cornerRadius on the glassView after each event. This is the minimal,
//   non-invasive fix that doesn't require any VEV wrapper.
//
// SIZE CLAMPING:
//   applyContentSize clamps preferredContentSize to [minWidth, maxWidth] x maxHeight.
//
// SHEETS / OVERLAY GATE:
//   MBKAnchoredSheet anchors sheets as child windows of the panel.
//   MBKOverlayGate blocks panel close while an overlay is active.
//
// STATUS BUTTON HIGHLIGHT:
//   button.highlight(true/false) keeps the status icon selected while open.

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let symbolName: String
    private let initialSize: NSSize
    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var glassView: NSGlassEffectView!
    private var hostingController: NSHostingController<AnyView>!
    private var sizeObservation: NSKeyValueObservation?
    private var childWindowObservers: [NSObjectProtocol] = []
    private var isSetUp = false
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    /// Left edge of the status button in screen coordinates, captured at open time.
    private var anchorX: CGFloat = 0
    /// Bottom edge of the status button in screen coordinates, captured at open time.
    private var anchorY: CGFloat = 0

    private let cornerRadius: CGFloat = 20

    // MARK: - Init

    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle",
        contentSize: NSSize = NSSize(width: 320, height: 300),
        minWidth: CGFloat = 200,
        maxWidth: CGFloat = 600,
        maxHeight: CGFloat = 600
    ) {
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.initialSize = contentSize
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.pendingRootView = AnyView(rootView)
    }

    private var pendingRootView: AnyView

    // MARK: - Setup

    public func setup() {
        precondition(!isSetUp, "MBKPopoverController.setup() called more than once.")
        isSetUp = true
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanel()
        setupWorkspaceObserver()
        mbkLog("PopoverController", "setup complete")
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            mbkLog("PopoverController", "togglePanel — closing")
            closePanel()
        } else {
            mbkLog("PopoverController", "togglePanel — opening")
            openPanel()
        }
    }

    private func openPanel() {
        guard let button = statusItem.button,
              let screen = button.window?.screen ?? NSScreen.main else {
            mbkLog("PopoverController", "openPanel — aborted: no button or screen")
            return
        }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = button.window?.convertToScreen(buttonRectInWindow)
            ?? NSRect(x: screen.frame.midX, y: screen.visibleFrame.maxY, width: 0, height: 0)

        anchorX = buttonRectOnScreen.minX
        anchorY = buttonRectOnScreen.minY
        mbkLog("PopoverController", "openPanel — anchor=(\(anchorX),\(anchorY))")

        let size = panel.frame.size
        let clampedX = min(anchorX, screen.visibleFrame.maxX - size.width)
        let origin = NSPoint(
            x: max(clampedX, screen.visibleFrame.minX),
            y: anchorY - size.height
        )
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setButtonHighlight(true)
        mbkLog("PopoverController", "openPanel — frame=(\(panel.frame))")
        startEventMonitor()
    }

    private func closePanel() {
        guard !overlayGate.hasActiveOverlay else {
            mbkLog("PopoverController", "closePanel — blocked: overlay active")
            return
        }
        panel.orderOut(nil)
        setButtonHighlight(false)
        stopEventMonitor()
        overlayGate.hasActiveOverlay = false
        mbkLog("PopoverController", "closePanel — closed")
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.highlight(on)
    }

    // MARK: - Panel setup

    private func setupPanel() {
        hostingController = NSHostingController(rootView: pendingRootView)
        hostingController.sizingOptions = .preferredContentSize
        mbkLog("PopoverController", "setupPanel — sizingOptions=.preferredContentSize")

        sizeObservation = hostingController.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            guard let self, let newSize = change.newValue else { return }
            mbkLog("PopoverController", "KVO preferredContentSize → (\(newSize.width),\(newSize.height))")
            Task { @MainActor [weak self] in
                self?.applyContentSize(newSize)
            }
        }

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        // NSGlassEffectView directly as panel.contentView — correct Tahoe API.
        // No NSVisualEffectView wrapper: VEV prevents glass from showing through
        // (WWDC25 session 310). cornerRadius is re-asserted after addChildWindow
        // via notification observers (see setupChildWindowObservers).
        glassView = NSGlassEffectView()
        glassView.cornerRadius = cornerRadius
        glassView.style = .regular
        glassView.contentView = hostingController.view
        panel.contentView = glassView

        setupChildWindowObservers()
        mbkLog("PopoverController", "setupPanel — initialSize=(\(initialSize.width),\(initialSize.height))")
    }

    /// Re-asserts cornerRadius after addChildWindow/removeChildWindow resets it.
    private func setupChildWindowObservers() {
        let add = NotificationCenter.default.addObserver(
            forName: NSWindow.didAddChildWindowNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            mbkLog("PopoverController", "didAddChildWindow — re-asserting cornerRadius")
            self.glassView.cornerRadius = self.cornerRadius
        }
        let remove = NotificationCenter.default.addObserver(
            forName: NSWindow.didRemoveChildWindowNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            mbkLog("PopoverController", "didRemoveChildWindow — re-asserting cornerRadius")
            self.glassView.cornerRadius = self.cornerRadius
        }
        childWindowObservers = [add, remove]
    }

    private func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width:  min(max(size.width,  minWidth), maxWidth),
            height: min(max(size.height, 1),        maxHeight)
        )
    }

    private func applyContentSize(_ preferred: CGSize) {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else {
            mbkLog("PopoverController", "applyContentSize — skipped: degenerate after clamp")
            return
        }
        let currentSize = panel.frame.size
        guard abs(currentSize.width  - clamped.width)  >= 1
           || abs(currentSize.height - clamped.height) >= 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        guard panel.isVisible else {
            panel.setContentSize(clamped)
            mbkLog("PopoverController", "applyContentSize — not visible, pre-sized to (\(clamped.width),\(clamped.height))")
            return
        }

        let newOrigin = NSPoint(
            x: round(anchorX - clamped.width / 2),
            y: round(anchorY - clamped.height)
        )
        let newFrame = NSRect(origin: newOrigin, size: clamped)
        mbkLog("PopoverController",
               "applyContentSize — (\(currentSize.width),\(currentSize.height))"
               + "→(\(clamped.width),\(clamped.height)) origin=(\(newOrigin.x),\(newOrigin.y))")
        panel.setFrame(newFrame, display: true, animate: false)
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
                guard let self, self.panel.isVisible else { return }
                guard activated != NSRunningApplication.current else {
                    mbkLog("PopoverController", "workspace observer — self-activation, ignoring")
                    return
                }
                guard !self.overlayGate.hasActiveOverlay else {
                    mbkLog("PopoverController", "workspace observer — overlay active, keeping open")
                    return
                }
                mbkLog("PopoverController", "workspace observer — other app active, closing")
                self.closePanel()
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
                self?.closePanel()
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
        sizeObservation?.invalidate()
        for observer in childWindowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
