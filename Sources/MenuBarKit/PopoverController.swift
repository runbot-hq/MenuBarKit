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
//   anchorX is captured ONCE at open time: button.midX in screen coords.
//   On every resize, frame is recomputed from anchorX + new size:
//     frame.origin.x = anchorX - size.width / 2
//     frame.origin.y = buttonScreenMinY - size.height
//   anchorX is never re-read from the button while the panel is open.
//   This avoids the menu-bar auto-hide instability (button screen-Y
//   changes between open/close cycles on auto-hide displays).
//
// WHY NOT NSPopover:
//   NSPopover.contentSize re-anchors the popover window on every write
//   while shown. There is no clean way to compensate for this — delta
//   math + setFrameOrigin fights AppKit and produces side-jumps on any
//   intermediate layout frame (e.g. SwiftUI emitting width before height
//   on a route transition). NSPanel.setFrame() has no such constraint.
//
// VISUAL CHROME:
//   NSPanel(.borderless) has no chrome. We add an NSVisualEffectView
//   with .popover material as the panel's contentView, then embed
//   the NSHostingController view inside it. This reproduces the standard
//   macOS popover glass background + corner radius without NSPopover.
//
// ROUNDED CORNERS — WHY CAShapeLayer MASK, NOT masksToBounds:
//   layer.cornerRadius + masksToBounds works before a sheet opens, but
//   calling addChildWindow(_:ordered:) on the panel causes macOS to switch
//   the window to a security compositing mode. In that mode, the window
//   server composites the panel directly and masksToBounds is no longer
//   honoured — the corners go square while the sheet is open.
//
//   A CAShapeLayer mask is applied by Core Animation, upstream of the
//   window compositor, so it is unaffected by addChildWindow. The mask
//   path is updated in applyContentSize on every resize so the corners
//   always match the current panel size.
//
// SHEETS / OVERLAY GATE:
//   MBKAnchoredSheet renders as an overlay inside the same NSHostingController.
//   MBKOverlayGate blocks panel close while an overlay is active.
//   Neither depends on NSPopover — both work identically with NSPanel.

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let symbolName: String
    private let initialSize: NSSize

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hostingController: NSHostingController<AnyView>!
    private var sizeObservation: NSKeyValueObservation?
    private var isSetUp = false
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    /// X midpoint of the status button in screen coordinates, captured at open time.
    private var anchorX: CGFloat = 0
    /// Bottom edge of the status button in screen coordinates, captured at open time.
    private var anchorY: CGFloat = 0

    /// The CAShapeLayer mask applied to the visual effect view for rounded corners.
    /// Stored so applyContentSize can update its path on every resize.
    private var cornerMaskLayer: CAShapeLayer?

    /// Corner radius applied via CAShapeLayer mask. Must match the visual effect
    /// view's expected radius. See ROUNDED CORNERS in the file header.
    private let cornerRadius: CGFloat = 10

    // MARK: - Init

    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle",
        contentSize: NSSize = NSSize(width: 320, height: 300)
    ) {
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.initialSize = contentSize
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
        anchorX = buttonRectOnScreen.midX
        anchorY = buttonRectOnScreen.minY
        mbkLog("PopoverController", "openPanel — anchor=(\(anchorX),\(anchorY))")

        let size = panel.frame.size
        let origin = NSPoint(
            x: anchorX - size.width / 2,
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
        statusItem.button?.isHighlighted = on
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

        // NSVisualEffectView provides the standard macOS popover glass background.
        // Rounded corners are applied via a CAShapeLayer mask (see ROUNDED CORNERS
        // in the file header) — NOT via cornerRadius + masksToBounds, which is
        // dropped by the window server when addChildWindow() is called.
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true

        // Apply initial rounded-corner mask for the initialSize.
        let maskLayer = CAShapeLayer()
        maskLayer.path = CGPath(
            roundedRect: CGRect(origin: .zero, size: initialSize),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        visualEffect.layer?.mask = maskLayer
        cornerMaskLayer = maskLayer

        // Embed the SwiftUI hosting view inside the visual effect view.
        let contentView = hostingController.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])

        panel.contentView = visualEffect
        mbkLog("PopoverController", "setupPanel — initialSize=(\(initialSize.width),\(initialSize.height))")
    }

    /// Applies a new content size from SwiftUI's preferredContentSize KVO.
    /// Recomputes the full panel frame from anchorX/anchorY — no delta math.
    /// Also updates the CAShapeLayer corner mask to match the new size.
    private func applyContentSize(_ preferred: CGSize) {
        guard preferred.width > 0, preferred.height > 0 else {
            mbkLog("PopoverController", "applyContentSize — skipped: degenerate (\(preferred.width),\(preferred.height))")
            return
        }
        let currentSize = panel.frame.size
        guard abs(currentSize.width  - preferred.width)  >= 1
           || abs(currentSize.height - preferred.height) >= 1 else {
            mbkLog("PopoverController", "applyContentSize — no-op: size unchanged")
            return
        }

        // Update the corner mask path to match the new size.
        // CAShapeLayer.path is not implicitly animated — assign directly.
        cornerMaskLayer?.path = CGPath(
            roundedRect: CGRect(origin: .zero, size: preferred),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        guard panel.isVisible else {
            panel.setContentSize(preferred)
            mbkLog("PopoverController", "applyContentSize — not visible, pre-sized to (\(preferred.width),\(preferred.height))")
            return
        }

        let newOrigin = NSPoint(
            x: round(anchorX - preferred.width / 2),
            y: round(anchorY - preferred.height)
        )
        let newFrame = NSRect(origin: newOrigin, size: preferred)
        mbkLog("PopoverController",
               "applyContentSize — (\(currentSize.width),\(currentSize.height))"
               + "→(\(preferred.width),\(preferred.height)) origin=(\(newOrigin.x),\(newOrigin.y))")
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
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
