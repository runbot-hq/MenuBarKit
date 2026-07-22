// PopoverController.swift
// MenuBarKit
//
// NUCLEAR REWRITE (v2) — SIZE IS NOW EXPLICIT DATA, NEVER INFERRED.
//
// History of failed size-inference approaches, all abandoned in this file:
//   1. NSPopover.contentSize + preferredContentSize (original implementation):
//      close+reshow cycles caused a visible side-jump on resize.
//   2. NSHostingView.fittingSize + frame KVO: broke completely when the
//      hosted content contained a GeometryReader (used for diagnostic
//      logging in RootView) — GeometryReader has no intrinsic size, so
//      fittingSize just echoed back whatever frame it was already given.
//   3. .mbkReportSize() using a PreferenceKey + GeometryReader background:
//      same root problem in a different shape — once WE started fixing
//      hostingView.frame ourselves (to fix approach #2's fallout),
//      GeometryReader's background measured OUR imposed frame and echoed
//      it back, so it could never detect a real content change. Also
//      independently broken by SwiftUI firing the PreferenceKey's
//      .zero defaultValue before real layout, poisoning cached state.
//
//   Every one of these failed for the same underlying reason: asking
//   AppKit or SwiftUI to MEASURE arbitrary hosted content and report back
//   an "intrinsic" size is fundamentally unreliable once any GeometryReader,
//   externally-imposed frame, or lazy layout pass is anywhere in the tree.
//   There is no successful measurement-based fix — the contract is broken
//   by design for those view types.
//
// THE FIX: MBKPopoverController no longer tries to measure anything.
//   Callers explicitly declare their own desired size via
//   `setContentSize(_:)`. There is no fittingSize, no KVO, no
//   PreferenceKey, no GeometryReader in this file's implementation at
//   all. The example app calls `popoverController.setContentSize(...)`
//   whenever its route changes, from an explicit lookup table
//   (Route.contentSize) — see RootView.swift / AppState.swift. Size is
//   100% caller-declared data, not inferred by watching layout.

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

    /// Explicitly sets the popover's content size and resizes/repositions
    /// the window immediately if it is currently shown. This is the ONLY
    /// way content size changes — there is no measurement of the hosted
    /// SwiftUI content anywhere in this class. Callers own the decision
    /// of what size their content needs, because only the caller's view
    /// code can know that reliably (see file header for why measurement
    /// approaches were abandoned).
    public func setContentSize(_ size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard abs(currentContentSize.width - size.width) > 0.5
                || abs(currentContentSize.height - size.height) > 0.5 else { return }

        currentContentSize = size
        mbkLog("PopoverController", "setContentSize — (\(size.width),\(size.height))")

        guard isShown, let (frame, arrowX) = computeFrame(for: size) else { return }
        layout(frame: frame, arrowX: arrowX, contentSize: size)
        mbkLog("PopoverController", "setContentSize — applied while shown, no close/reshow")
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
        arrowView.autoresizingMask = [.width, .height]

        // Use NSPanel with .nonactivatingPanel styleMask, NOT plain
        // .borderless NSWindow. AnchoredSheet.swift locates "the popover
        // window" by searching NSApp.windows for
        // styleMask.contains(.nonactivatingPanel) — that discriminator
        // must keep matching this window or sheet-anchoring (mbkSheet)
        // breaks silently for every consumer of this package.
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

    /// Applies a window frame + arrow position, and lays out arrowView /
    /// hostingView to match `contentSize` exactly — the caller-declared
    /// size, never a measured one.
    private func layout(frame: NSRect, arrowX: CGFloat, contentSize: NSSize) {
        arrowView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height)
        arrowView.arrowXInWindow = arrowX
        window.setFrame(frame, display: true)
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
