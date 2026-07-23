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
// ROUNDED CORNERS — WHY maskImage, NOT cornerRadius/masksToBounds/CAShapeLayer:
//   Three approaches were tried and rejected:
//
//   1. layer.cornerRadius + masksToBounds:
//      Works before a sheet opens. addChildWindow() causes macOS to switch
//      the window to a security compositing mode — masksToBounds is no
//      longer honoured and corners go square while the sheet is open.
//
//   2. CAShapeLayer on layer.mask:
//      Clips the view's pixel content but NOT the NSVisualEffectView blur
//      region. The blur/vibrancy composites outside the mask boundary,
//      producing square blur edges regardless of the mask shape.
//
//   3. NSVisualEffectView.maskImage with capInsets (CORRECT):
//      maskImage is the Apple-documented API for rounding NSVisualEffectView.
//      It is applied by the view's own compositor, upstream of both Core
//      Animation and the window server, so it correctly clips the blur
//      region AND survives addChildWindow. capInsets make the image
//      stretch correctly at any size without regenerating it.
//      See: developer.apple.com/documentation/appkit/nsvisualeffectview/maskimage
//
// CORNER RADIUS VALUE:
//   12pt matches the native NSPopover corner radius (consistent across
//   Sonoma / Sequoia / Tahoe for popovers). Tahoe's larger radii apply
//   to regular app windows, not to popovers / menu-bar panels.
//
// SIZE CLAMPING:
//   applyContentSize clamps preferredContentSize to [minWidth, maxWidth] x maxHeight.
//   Content wider than maxWidth is clipped by lineLimit(1) + truncation in SwiftUI.
//   Content taller than maxHeight is scrollable inside the ScrollView.
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
    /// Minimum width the panel will shrink to.
    private let minWidth: CGFloat
    /// Maximum width the panel will grow to. SwiftUI content truncates beyond this.
    private let maxWidth: CGFloat
    /// Maximum height the panel will grow to. Content taller than this scrolls.
    private let maxHeight: CGFloat

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

    /// Corner radius matching native NSPopover (12pt).
    /// See CORNER RADIUS VALUE in the file header.
    private let cornerRadius: CGFloat = 12

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
        // Rounded corners via maskImage — see ROUNDED CORNERS in the file header.
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.maskImage = roundedMaskImage(radius: cornerRadius)

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

    /// Builds the mask image used by NSVisualEffectView.maskImage.
    /// The image is a minimal (2*radius+1) square with a filled rounded rect.
    /// capInsets allow it to stretch to any panel size without regeneration.
    /// See ROUNDED CORNERS in the file header.
    private func roundedMaskImage(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// Clamps a size within [minWidth, maxWidth] x [1, maxHeight].
    private func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width:  min(max(size.width,  minWidth), maxWidth),
            height: min(max(size.height, 1),        maxHeight)
        )
    }

    /// Applies a new content size from SwiftUI's preferredContentSize KVO.
    /// Clamps to [minWidth, maxWidth] x maxHeight, then recomputes the full
    /// panel frame from anchorX/anchorY — no delta math.
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
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
