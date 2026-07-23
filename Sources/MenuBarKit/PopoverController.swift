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
// ┌─────────────────────────────────────────────────────────────────────────┐
// │  !! DO NOT TOUCH — ROUNDED CORNER SYSTEM !!                            │
// │                                                                         │
// │  Rounded corners survive addChildWindow() ONLY because of the exact     │
// │  two-layer structure below. Every other approach was tried and failed.   │
// │  Do NOT change the view hierarchy, maskImage setup, or                  │
// │  roundedMaskImage() without reading the full history below.             │
// │                                                                         │
// │  WHAT BREAKS CORNERS (do not re-introduce these):                       │
// │    • NSVisualEffectView.cornerRadius / masksToBounds                    │
// │    • CAShapeLayer mask on any layer                                      │
// │    • NSGlassEffectView.cornerRadius alone                               │
// │    • NSGlassEffectView.clipsToBounds                                    │
// │    • Any async re-assertion of cornerRadius after addChildWindow()       │
// │    • Removing the outer NSVisualEffectView clipView                      │
// │    • Making NSGlassEffectView the direct panel.contentView               │
// │    • Subclassing NSPanel to override addChildWindow/removeChildWindow    │
// │    • maskImage on NSGlassEffectView — it has NO maskImage property       │
// │      (NSGlassEffectView does NOT inherit NSVisualEffectView)             │
// │                                                                         │
// │  WHAT KEEPS CORNERS ALIVE (do not remove or alter):                     │
// │    • clipView (NSVisualEffectView) as panel.contentView                  │
// │    • clipView.maskImage = roundedMaskImage(radius: cornerRadius)         │
// │    • roundedMaskImage() using NSBezierPath + capInsets + .stretch        │
// │    • NSGlassEffectView pinned inside clipView via Auto Layout            │
// └─────────────────────────────────────────────────────────────────────────┘
//
// VISUAL CHROME — TWO-LAYER APPROACH:
//   NSPanel(.borderless) has no chrome. We use two nested views:
//
//   1. Outer — NSVisualEffectView (clipView)
//      Set as panel.contentView. Its ONLY job is maskImage corner clipping.
//      maskImage is applied by the window server compositor, not Core Animation,
//      so it survives addChildWindow() when a sheet opens. Nothing else does.
//      material = .windowBackground so it contributes no visible material of
//      its own — NSGlassEffectView below provides all the visible chrome.
//
//   2. Inner — NSGlassEffectView
//      Pinned to fill clipView. Provides the Tahoe liquid-glass material.
//      hostingController.view is assigned to its contentView property.
//
// ROUNDED CORNERS — HISTORY:
//   Approaches tried and rejected (ALL regress to rect corners on sheet open):
//   1. NSVisualEffectView.cornerRadius / masksToBounds  → reset by addChildWindow()
//   2. CAShapeLayer mask                                → clips pixels, not blur compositor
//   3. NSGlassEffectView.cornerRadius alone             → reset by addChildWindow()
//   4. NSGlassEffectView.clipsToBounds                  → reset by addChildWindow()
//   5. NSPanel subclass overriding addChildWindow()     → AppKit resets again async after super
//   6. DispatchQueue.main.async re-assertion            → still a race, still regresses
//   7. NSVisualEffectView.maskImage wrapping NSGlassEffectView — WORKS. (current approach)
//   8. maskImage on NSGlassEffectView directly          → COMPILE ERROR: NSGlassEffectView
//      does NOT inherit NSVisualEffectView and has no maskImage property.
//
// CORNER RADIUS VALUE:
//   20pt matches system status-bar panels (Weather, etc.) on macOS 26.
//
// SIZE CLAMPING:
//   applyContentSize clamps preferredContentSize to [minWidth, maxWidth] x maxHeight.
//
// SHEETS / OVERLAY GATE:
//   MBKAnchoredSheet renders as an overlay inside the same NSHostingController.
//   MBKOverlayGate blocks panel close while an overlay is active.
//
// STATUS BUTTON HIGHLIGHT:
//   button.highlight(true/false) is the correct API for keeping the status
//   item visually selected while the panel is open. isHighlighted drops when
//   the panel takes key status; highlight() does not.

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
    private var hostingController: NSHostingController<AnyView>!
    private var sizeObservation: NSKeyValueObservation?
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

        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // !! DO NOT TOUCH THIS BLOCK — ROUNDED CORNERS DEPEND ON IT ENTIRELY !!
        //
        // clipView is an NSVisualEffectView whose ONLY role is to hold maskImage.
        // maskImage is the sole clipping technique that survives addChildWindow()
        // when a sheet is presented. Every other approach was tried and failed —
        // see ROUNDED CORNERS — HISTORY in the file header.
        //
        // Rules:
        //   • clipView MUST be panel.contentView — do not add any wrapper above it.
        //   • clipView.maskImage MUST be set to roundedMaskImage() — do not remove it.
        //   • Do NOT set cornerRadius, masksToBounds, or wantsLayer=false on clipView.
        //   • Do NOT replace clipView with any other view type.
        //   • Do NOT make NSGlassEffectView the direct panel.contentView.
        //   • NSGlassEffectView has NO maskImage property — do not attempt to set one.
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        let clipView = NSVisualEffectView()
        clipView.material = .windowBackground
        clipView.blendingMode = .behindWindow
        clipView.state = .active
        clipView.wantsLayer = true
        clipView.maskImage = roundedMaskImage(radius: cornerRadius) // ← DO NOT REMOVE

        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // !! DO NOT TOUCH THIS BLOCK — LIQUID GLASS MATERIAL !!              !!
        //
        // NSGlassEffectView provides the Tahoe liquid-glass material.
        // It MUST be a subview of clipView (not panel.contentView directly).
        // hostingController.view MUST be assigned via .contentView (not addSubview).
        // Do NOT set cornerRadius or clipsToBounds on glassView — both are reset
        // by addChildWindow(). Corner clipping is handled by clipView.maskImage.
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        let glassView = NSGlassEffectView()
        glassView.style = .regular
        glassView.contentView = hostingController.view  // ← .contentView, NOT addSubview
        glassView.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(glassView)
        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: clipView.topAnchor),
            glassView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            glassView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
        ])

        panel.contentView = clipView  // ← clipView MUST be panel.contentView
        mbkLog("PopoverController", "setupPanel — initialSize=(\(initialSize.width),\(initialSize.height))")
    }

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // !! DO NOT TOUCH — roundedMaskImage() !!                               !!
    //
    // Produces the maskImage that keeps corners rounded through addChildWindow().
    // capInsets + .stretch let it scale to any panel size without regenerating.
    // Do not change the drawing, capInsets, or resizingMode.
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
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
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
