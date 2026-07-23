// PopoverController.swift
// MenuBarKit

import AppKit
import SwiftUI

// MARK: - MBKPanel

/// NSPanel subclass that re-asserts NSGlassEffectView.cornerRadius after
/// addChildWindow/removeChildWindow. AppKit resets cornerRadius asynchronously
/// during the window-server compositing update that follows addChildWindow.
/// We dispatch the re-assertion to the next run-loop turn to win the race.
private final class MBKPanel: NSPanel {
    var glassView: NSGlassEffectView?
    var desiredCornerRadius: CGFloat = 20

    override func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode) {
        super.addChildWindow(childWin, ordered: place)
        // Dispatch to next run-loop turn: AppKit resets cornerRadius during
        // the compositing update that occurs after super returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.glassView?.cornerRadius = self.desiredCornerRadius
            mbkLog("MBKPanel", "addChildWindow async — re-asserted cornerRadius=\(self.desiredCornerRadius)")
        }
    }

    override func removeChildWindow(_ childWin: NSWindow) {
        super.removeChildWindow(childWin)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.glassView?.cornerRadius = self.desiredCornerRadius
            mbkLog("MBKPanel", "removeChildWindow async — re-asserted cornerRadius=\(self.desiredCornerRadius)")
        }
    }
}

// MARK: - MBKPopoverController

@MainActor
public final class MBKPopoverController: NSObject {

    private let overlayGate: MBKOverlayGate
    private let symbolName: String
    private let initialSize: NSSize
    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat

    private var statusItem: NSStatusItem!
    private var panel: MBKPanel!
    private var hostingController: NSHostingController<AnyView>!
    private var sizeObservation: NSKeyValueObservation?
    private var isSetUp = false
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    private var anchorX: CGFloat = 0
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
        panel.isVisible ? closePanel() : openPanel()
    }

    private func openPanel() {
        guard let button = statusItem.button,
              let screen = button.window?.screen ?? NSScreen.main else { return }
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = button.window?.convertToScreen(buttonRectInWindow)
            ?? NSRect(x: screen.frame.midX, y: screen.visibleFrame.maxY, width: 0, height: 0)
        anchorX = buttonRectOnScreen.minX
        anchorY = buttonRectOnScreen.minY
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
        startEventMonitor()
    }

    private func closePanel() {
        guard !overlayGate.hasActiveOverlay else { return }
        panel.orderOut(nil)
        setButtonHighlight(false)
        stopEventMonitor()
        overlayGate.hasActiveOverlay = false
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.highlight(on)
    }

    // MARK: - Panel setup

    private func setupPanel() {
        hostingController = NSHostingController(rootView: pendingRootView)
        hostingController.sizingOptions = .preferredContentSize

        sizeObservation = hostingController.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            guard let self, let newSize = change.newValue else { return }
            Task { @MainActor [weak self] in self?.applyContentSize(newSize) }
        }

        panel = MBKPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.desiredCornerRadius = cornerRadius

        let glassView = NSGlassEffectView()
        glassView.cornerRadius = cornerRadius
        glassView.style = .regular
        glassView.contentView = hostingController.view
        panel.contentView = glassView
        panel.glassView = glassView
    }

    private func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width:  min(max(size.width,  minWidth), maxWidth),
            height: min(max(size.height, 1),        maxHeight)
        )
    }

    private func applyContentSize(_ preferred: CGSize) {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else { return }
        let currentSize = panel.frame.size
        guard abs(currentSize.width  - clamped.width)  >= 1
           || abs(currentSize.height - clamped.height) >= 1 else { return }
        guard panel.isVisible else {
            panel.setContentSize(clamped)
            return
        }
        let newOrigin = NSPoint(
            x: round(anchorX - clamped.width / 2),
            y: round(anchorY - clamped.height)
        )
        panel.setFrame(NSRect(origin: newOrigin, size: clamped), display: true, animate: false)
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
                guard activated != NSRunningApplication.current else { return }
                guard !self.overlayGate.hasActiveOverlay else { return }
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
            Task { @MainActor [weak self] in self?.closePanel() }
        }
    }

    private func stopEventMonitor() {
        guard let monitor = eventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        eventMonitor = nil
    }

    deinit {
        sizeObservation?.invalidate()
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
