// PopoverController.swift
// MenuBarKit
//
// *** TEST BRANCH: test/intrinsic-content-size-kvo ***
// This is an EXPERIMENT, not a replacement for the working implementation
// on fix/popover-arrow-centering. If this doesn't pan out, this branch
// gets deleted and nothing here ships.
//
// WHAT'S DIFFERENT FROM THE WORKING VERSION:
//   The working version (fix/popover-arrow-centering) makes size 100%
//   caller-declared via setContentSize(_:) + Route.contentSize. That
//   works but requires hand-maintaining a size table that can drift out
//   of sync with each view's actual .frame(width:).
//
//   This experiment tries NSHostingView.sizingOptions = [.intrinsicContentSize]
//   plus KVO on hostingView.intrinsicContentSize, instead of a manual
//   table. This is NOT the same mechanism as the fittingSize/GeometryReader
//   attempts from earlier tonight:
//     - fittingSize / GeometryReader both ask "given the frame you
//       currently have, what size do you report" — circular once we set
//       that frame ourselves.
//     - .intrinsicContentSize with sizingOptions enabled makes
//       NSHostingView run SwiftUI's real layout solver to compute the
//       content's ideal size, independent of the view's current .frame.
//       It's the same AppKit contract as any other view with an
//       intrinsic content size (like NSTextField) — Apple added this
//       specifically so NSHostingView could report a real size to
//       Auto-Layout-driven or manually-driven AppKit containers.
//
//   IF THIS IS ALSO CIRCULAR IN PRACTICE (i.e. intrinsicContentSize just
//   echoes back frame.size once we start setting the frame ourselves),
//   that will show up immediately in the logs below as a size that never
//   changes on route switch. That's the acceptance test for this
//   experiment — if it fails, revert to Route.contentSize.

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let symbolName: String
    private let rootView: AnyView

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var arrowView: MBKArrowView!
    private var hostingView: NSHostingView<AnyView>!
    private var isSetUp = false
    private var isShown = false
    private var currentContentSize: NSSize
    private var intrinsicSizeObservation: NSKeyValueObservation?
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
        self.currentContentSize = contentSize
    }

    // MARK: - Public API

    /// Manual override, retained for compatibility with existing callers
    /// (e.g. AppDelegate's initial contentSize:). Once intrinsicContentSize
    /// KVO fires for real, that becomes the source of truth for as long as
    /// this experiment is active.
    public func setContentSize(_ size: NSSize) {
        applySize(size, source: "setContentSize (manual)")
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

        // *** THE EXPERIMENT ***
        // Ask NSHostingView to compute and report its intrinsicContentSize
        // from SwiftUI's real layout solver, rather than deriving size from
        // whatever frame we happen to have assigned it.
        hostingView.sizingOptions = [.intrinsicContentSize]

        arrowView = MBKArrowView()
        arrowView.autoresizingMask = [.width, .height]

        let win = NSPanel(
            contentRect: NSRect(origin: .zero, size: currentContentSize),
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
        win.contentView = arrowView

        hostingView.frame = NSRect(origin: .zero, size: currentContentSize)
        arrowView.addSubview(hostingView)

        window = win

        // KVO on intrinsicContentSize — NOT on .frame. This is the
        // distinguishing test: does intrinsicContentSize actually change
        // independently of the frame we impose in applySize()?
        intrinsicSizeObservation = hostingView.observe(\.intrinsicContentSize, options: [.new]) { [weak self] _, change in
            guard let self, let newValue = change.newValue else { return }
            mbkLog("PopoverController", "KVO intrinsicContentSize fired — (\(newValue.width),\(newValue.height))")
            guard newValue.width > 0, newValue.height > 0,
                  newValue.width.isFinite, newValue.height.isFinite else {
                mbkLog("PopoverController", "KVO intrinsicContentSize — ignoring invalid/placeholder value")
                return
            }
            self.applySize(newValue, source: "KVO intrinsicContentSize")
        }
    }

    // MARK: - Frame computation

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

    private func layout(frame: NSRect, arrowX: CGFloat, contentSize: NSSize) {
        arrowView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height)
        arrowView.arrowXInWindow = arrowX
        window.setFrame(frame, display: true)
    }

    private func applySize(_ size: NSSize, source: String) {
        guard size.width > 0, size.height > 0 else { return }
        guard abs(currentContentSize.width - size.width) > 0.5
                || abs(currentContentSize.height - size.height) > 0.5 else { return }

        currentContentSize = size
        mbkLog("PopoverController", "applySize [\(source)] — (\(size.width),\(size.height))")

        guard isShown, let (frame, arrowX) = computeFrame(for: size) else { return }
        layout(frame: frame, arrowX: arrowX, contentSize: size)
        mbkLog("PopoverController", "applySize [\(source)] — applied while shown, no close/reshow")
    }

    // MARK: - Open / close

    private func openWindow() {
        guard statusItem.button != nil else { return }

        guard let (frame, arrowX) = computeFrame(for: currentContentSize) else { return }
        layout(frame: frame, arrowX: arrowX, contentSize: currentContentSize)

        window.orderFrontRegardless()
        statusItem.button?.isHighlighted = true

        isShown = true
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "openWindow — sized to (\(currentContentSize.width),\(currentContentSize.height))")
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
