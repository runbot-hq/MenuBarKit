// PopoverController.swift
import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    private let overlayGate: MBKOverlayGate
    private let symbolName: String
    private let initialSize: NSSize
    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hostingController: NSHostingController<AnyView>!
    private var sizeObservation: NSKeyValueObservation?
    private var isSetUp = false
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    private var anchorX: CGFloat = 0
    private var anchorY: CGFloat = 0

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

    public func setup() {
        precondition(!isSetUp)
        isSetUp = true
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanel()
        setupWorkspaceObserver()
        mbkLog("PopoverController", "setup complete")
    }

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
        let origin = NSPoint(x: max(clampedX, screen.visibleFrame.minX), y: anchorY - size.height)
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        statusItem.button?.highlight(true)
        startEventMonitor()
    }

    private func closePanel() {
        guard !overlayGate.hasActiveOverlay else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        stopEventMonitor()
        overlayGate.hasActiveOverlay = false
    }

    private func setupPanel() {
        hostingController = NSHostingController(rootView: pendingRootView)
        hostingController.sizingOptions = .preferredContentSize

        sizeObservation = hostingController.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
            guard let self, let newSize = change.newValue else { return }
            Task { @MainActor [weak self] in self?.applyContentSize(newSize) }
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

        let glassView = NSGlassEffectView(frame: NSRect(origin: .zero, size: initialSize))
        glassView.material = .clear
        glassView.cornerRadius = 12
        glassView.autoresizingMask = [.width, .height]

        let hostingView = hostingController.view
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        glassView.contentView = hostingView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: glassView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
        ])

        panel.contentView = glassView

        mbkLog("PopoverController", "setup complete")
    }

    private func clamp(_ size: CGSize) -> CGSize {
        CGSize(width: min(max(size.width, minWidth), maxWidth), height: min(max(size.height, 1), maxHeight))
    }

    private func applyContentSize(_ preferred: CGSize) {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else { return }
        let currentSize = panel.frame.size
        guard abs(currentSize.width - clamped.width) >= 1 || abs(currentSize.height - clamped.height) >= 1 else { return }
        guard panel.isVisible else { panel.setContentSize(clamped); return }
        let newOrigin = NSPoint(x: round(anchorX - clamped.width / 2), y: round(anchorY - clamped.height))
        panel.setFrame(NSRect(origin: newOrigin, size: clamped), display: true, animate: false)
    }

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible else { return }
                guard activated != NSRunningApplication.current else { return }
                guard !self.overlayGate.hasActiveOverlay else { return }
                self.closePanel()
            }
        }
    }

    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
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
        if let o = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
    }
}
