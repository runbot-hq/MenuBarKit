// PopoverController.swift
// MenuBarKit
//
// NUCLEAR OPTION: NSPopover is gone. After three consecutive attempts to
// eliminate a visible side-jump on resize (setFrameOrigin correction,
// positioningRect reassignment, close+reshow with NSDisableScreenUpdates,
// close+reshow with NSAnimationContext) all failed or introduced a new
// side-jump, the conclusion is that NSPopover's internal arrow/frame
// layout is a black box we cannot fully synchronize with our own resize
// timing — every fix could only ever mask one specific interaction with
// AppKit's private relayout, never the underlying window-server race.
//
// This file now backs MBKPopoverController with a plain custom NSPanel
// that we fully own:
//   - We set the window's frame directly, in one call, every time.
//   - We draw our own arrow (MBKArrowView) at an x-position we compute
//     ourselves from the button's screen frame — no positioningRect, no
//     NSPopover-internal recomputation, nothing hidden.
//   - Resize is a single setFrame(_:display:) call. There is no
//     close+reshow cycle, so there is no possible intermediate frame for
//     the window server to flush.
// This removes the entire class of bug rather than patching around it.

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let rootView: AnyView
    private let symbolName: String
    private let initialContentSize: NSSize

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var arrowView: MBKArrowView!
    private var hostingView: NSHostingView<AnyView>!
    private var sizeObservation: NSKeyValueObservation?
    private var isSetUp = false
    private var isShown = false
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    private let arrowHeight: CGFloat = 10

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
        self.initialContentSize = contentSize
    }

    // MARK: - Setup

    public func setup() {
        precondition(!isSetUp, "MBKPopoverController.setup() called more than once.")
        isSetUp = true
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupWindow()
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
        if isShown {
            closeWindow()
        } else {
            openWindow()
        }
    }

    // MARK: - Window setup

    private func setupWindow() {
        hostingView = NSHostingView(rootView: rootView)
        arrowView = MBKArrowView()

        // Use NSPanel with .nonactivatingPanel styleMask, NOT plain
        // .borderless NSWindow. AnchoredSheet.swift locates "the popover
        // window" by searching NSApp.windows for
        // styleMask.contains(.nonactivatingPanel) — that discriminator
        // must keep matching this window or sheet-anchoring (mbkSheet)
        // breaks silently for every consumer of this package.
        let win = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.level = .popUpMenu
        win.hasShadow = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.collectionBehavior = [.transient, .ignoresCycle]
        win.hidesOnDeactivate = false
        win.becomesKeyOnlyIfNeeded = true

        arrowView.frame = NSRect(origin: .zero, size: win.frame.size)
        arrowView.autoresizingMask = [.width, .height]
        win.contentView = arrowView

        hostingView.frame = arrowView.bodyRect
        hostingView.autoresizingMask = [.width, .height]
        arrowView.addSubview(hostingView)

        window = win
        setupSizeObserver()
    }

    // MARK: - Frame computation

    /// Computes the window frame + arrow x so that the arrow always points
    /// at the status item button's horizontal center, for a given content
    /// size. This is the ONLY place window geometry is calculated — one
    /// function, one call site per open/resize, no AppKit black box.
    private func computeFrame(for contentSize: NSSize) -> (frame: NSRect, arrowX: CGFloat)? {
        guard let button = statusItem.button, let buttonWindow = button.window else { return nil }
        let buttonScreenFrame = buttonWindow.convertToScreen(button.frame)
        let buttonMidX = buttonScreenFrame.midX

        let totalHeight = contentSize.height + arrowHeight
        let totalWidth = contentSize.width

        var originX = buttonMidX - totalWidth / 2
        let originY = buttonScreenFrame.minY - totalHeight

        guard let screen = buttonWindow.screen ?? NSScreen.main else { return nil }
        let minX = screen.visibleFrame.minX + 4
        let maxX = screen.visibleFrame.maxX - totalWidth - 4
        originX = min(max(originX, minX), maxX)

        let frame = NSRect(x: originX, y: originY, width: totalWidth, height: totalHeight)
        let arrowX = buttonMidX - originX
        return (frame, arrowX)
    }

    // MARK: - Open / close

    private func openWindow() {
        guard let button = statusItem.button else { return }
        let fitting = hostingView.fittingSize
        let size = (fitting.width > 0 && fitting.height > 0) ? fitting : initialContentSize

        guard let (frame, arrowX) = computeFrame(for: size) else { return }

        arrowView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.frame = arrowView.bodyRect
        arrowView.arrowXInWindow = arrowX

        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        button.isHighlighted = true

        isShown = true
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "openWindow — sized to (\(size.width),\(size.height))")
        startEventMonitor()
    }

    private func closeWindow() {
        guard isShown else { return }
        window.orderOut(nil)
        statusItem.button?.isHighlighted = false
        isShown = false
        stopEventMonitor()
        overlayGate.hasActiveOverlay = false
        mbkLog("PopoverController", "windowDidClose")
        mbkLog("PopoverController", "overlay gate reset on close")
    }

    // MARK: - Size observer

    private func setupSizeObserver() {
        sizeObservation = hostingView.observe(\.frame, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyContentSize(self.hostingView.fittingSize)
            }
        }
    }

    /// Resizes and re-centers the window on the button in a SINGLE
    /// setFrame(_:display:) call. There is no close/reshow, no
    /// contentSize/positioningRect indirection, and therefore no
    /// intermediate frame the window server could ever flush separately.
    /// Arrow position is written directly to arrowView.arrowXInWindow —
    /// no AppKit-internal arrow recomputation exists to race against.
    private func applyContentSize(_ preferred: NSSize) {
        guard isShown else { return }
        guard preferred.width > 0, preferred.height > 0 else { return }
        guard let buttonWin = statusItem.button?.window else {
            mbkLog("PopoverController", "applyContentSize — no button window, skipping")
            return
        }
        if let screen = buttonWin.screen, !screen.frame.contains(buttonWin.frame.origin) {
            mbkLog("PopoverController", "applyContentSize — button off-screen, skipping")
            return
        }

        let currentSize = NSSize(width: window.frame.width, height: window.frame.height - arrowHeight)
        guard abs(currentSize.width - preferred.width) > 1
                || abs(currentSize.height - preferred.height) > 1 else { return }

        guard let (frame, arrowX) = computeFrame(for: preferred) else { return }

        mbkLog("PopoverController",
               "applyContentSize — writing (\(preferred.width),\(preferred.height)) "
               + "prev=(\(currentSize.width),\(currentSize.height))")

        arrowView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.frame = arrowView.bodyRect
        arrowView.arrowXInWindow = arrowX
        window.setFrame(frame, display: true)

        mbkLog("PopoverController", "applyContentSize — resized in place, arrow re-centered, no close/reshow")
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
                guard let self, self.isShown else { return }
                guard activated != NSRunningApplication.current else {
                    mbkLog("PopoverController", "workspace observer — self-activation, ignoring")
                    return
                }
                guard !overlayGate.hasActiveOverlay else {
                    mbkLog("PopoverController", "workspace observer — overlay active, keeping window open")
                    return
                }
                mbkLog("PopoverController", "workspace observer — other app active, closing")
                self.closeWindow()
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
                guard let self, !self.overlayGate.hasActiveOverlay else { return }
                self.closeWindow()
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
