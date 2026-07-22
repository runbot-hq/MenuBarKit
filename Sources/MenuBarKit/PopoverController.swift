// PopoverController.swift
// MenuBarKit
//
// Owns the full NSPopover + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// RESPONSIBILITIES:
//   - Create and show/hide the NSPopover
//   - Manage the NSStatusItem button highlight
//   - Install/remove the outside-click NSEvent monitor
//   - Install/remove the NSWorkspace app-switch observer
//   - Implement popoverShouldClose via the MBKOverlayGate
//   - Reset the overlay gate in popoverDidClose (safety net)
//
// STAY-OPEN-WHILE-SHEET-ACTIVE — deliberate trade-off:
//   When a sheet (or file picker) is live, MBKPopoverController keeps the
//   popover open on app-switch and outside-click instead of hiding it.
//   popoverShouldClose returns false (via overlayGate.hasActiveOverlay), and
//   the workspace observer skips performClose while any overlay is active.
//
//   This is the simpler behaviour: the user's mental model is "sheet is
//   blocking, nothing else happens until I dismiss it." No hide-and-restore
//   cycle to reason about.
//
//   The alternative — hide the popover window without closing it so the sheet
//   NSWindow survives, then restore on reopen — is more AppKit-native but
//   significantly more complex. Some users may prefer it (popover disappears
//   on app-switch as they expect, even with a sheet open). If you want to
//   implement this, see `preservedSheetWindowHide`,
//   `hidePopoverWindowsPreservingSheets()`, and
//   `restorePopoverWindowsPreservingSheetsIfNeeded()` in the
//   `PopoverLifecycleCoordinator.swift` reference implementation. That approach requires:
//     1. Hiding the NSPopover backing window (not performClose) when the
//        workspace observer fires and a sheet is active.
//     2. Tracking a `preservedSheetWindowHide` flag.
//     3. Restoring (un-hiding) the popover window on the next openPopover() call
//        when the flag is set, rather than calling popover.show().
//
// USAGE:
//   1. Create a MBKPopoverController with your root SwiftUI view and an
//      MBKOverlayGate instance.
//   2. Call `setup()` from applicationDidFinishLaunching — see setup() doc
//      comment for the strict ordering requirement.
//
// DISMISS GATE CONTRACT:
//   popoverShouldClose reads overlayGate.hasActiveOverlay. MBKAnchoredSheet
//   and mbkOpenFilePicker manage the gate automatically — the host app never
//   needs to touch it directly.
//
// OUTSIDE-CLICK MONITOR:
//   Started when the popover opens, stopped when it closes. Never leaks a
//   persistent global listener.
//
// WORKSPACE OBSERVER — why queue: nil + Task { @MainActor } (not queue: .main):
//   The production PopoverLifecycleCoordinator uses queue: .main +
//   MainActor.assumeIsolated. That pattern is a runtime assertion, not a
//   compile-time guarantee, and violates Swift 6's actor-isolation rules (P4).
//   queue: nil delivers on the poster's thread; Task { @MainActor } is then
//   the Swift 6-correct hop to the main actor — compiler-enforced, not
//   asserted. The asymmetry with the production coordinator is intentional
//   and correct. The production coordinator should be updated to match.
//
// WORKSPACE OBSERVER — performClose on already-closed popover:
//   If the workspace observer Task is still enqueued when popoverDidClose fires
//   (e.g. user Command-Tabs and popoverDidClose has already run by the time the
//   Task hops to MainActor), performClose(nil) is called on a closed popover.
//   NSPopover.performClose on a closed popover is documented as a no-op, so
//   this is safe. The guard self.popover.isShown at the top of the Task body
//   makes the intent explicit — it is not defensive cargo-culting.
//
// IMPLICIT-UNWRAPPED OPTIONALS (statusItem, popover, hostingController):
//   These three properties use ! (IUO) because they are assigned in setup(),
//   not in init(). This is the standard setup()-pattern for AppKit types that
//   require a post-init configuration step. They are safe because setup() must
//   be called from applicationDidFinishLaunching before any user interaction
//   is possible — the app's own main thread cannot reach togglePopover() before
//   that point.
//
//   If you are writing a unit test that calls togglePopover() without first
//   calling setup(), it WILL crash on the ! unwrap. Call setup() first, or
//   restructure to init-time wiring before extracting this into a fully
//   testable library.
//
//   ❌ Do NOT replace these with optionals without also replacing setup() with
//   an init parameter — partial initialisation with optionals silently turns
//   programming errors into runtime nil returns that are harder to diagnose
//   than a clean crash.
//
// nonisolated(unsafe) — WHY eventMonitor AND workspaceObserver USE IT:
//   Both properties hold opaque tokens returned by AppKit APIs:
//     - eventMonitor: Any? from NSEvent.addGlobalMonitorForEvents
//     - workspaceObserver: NSObjectProtocol? from NSNotificationCenter.addObserver
//   Neither token type is Sendable, so the Swift 6 compiler rejects them as
//   @MainActor stored properties used in deinit (which is nonisolated per SE-0327).
//
//   nonisolated(unsafe) is the correct annotation because:
//     1. Every live read/write of both properties is @MainActor-isolated
//        (setupWorkspaceObserver, startEventMonitor, stopEventMonitor, deinit).
//     2. deinit runs only after the last strong reference drops. In normal app
//        lifetime, MBKPopoverController is created once in applicationDidFinishLaunching
//        and outlives all concurrent work — no concurrent access is possible.
//
//   LIMITATION: if MBKPopoverController is ever used with a SHORTER lifetime
//   (torn down and recreated, or held by a scoped owner), the singleton-lifetime
//   assumption no longer holds. In that case, replace the two tokens with a
//   proper teardown method that is guaranteed to be called on the main actor
//   before release, and remove nonisolated(unsafe).
//
//   ❌ Do NOT add @unchecked Sendable to these token types as a workaround —
//   that would suppress the warning without providing any actual safety.
//
// deinit TEARDOWN — thread-safety of NSWorkspace vs NSEvent removal:
//   deinit calls both NSWorkspace.shared.notificationCenter.removeObserver
//   and NSEvent.removeMonitor. NSEvent.removeMonitor is documented as
//   thread-safe. NSWorkspace.shared.notificationCenter.removeObserver is NOT
//   documented with the same guarantee.
//
//   This is safe here because of the singleton-lifetime assumption above:
//   MBKPopoverController is never released while concurrent work is in flight,
//   so deinit always runs after all @MainActor work has completed. If the
//   singleton assumption is ever violated, move both removals into an explicit
//   @MainActor teardown() method called before release.
//
//   This is an info-only note — not a current bug. Do not add a spurious
//   Task { @MainActor } wrapper around the deinit removals; that would be
//   a use-after-free (self is already deallocated when the Task runs).
//
// ARROW CENTERING — positioningRect at button midX:
//   NSPopover.show(relativeTo:of:preferredEdge:) anchors the arrow to the
//   midX of the positioningRect. Passing button.bounds makes the arrow point
//   at the button center, but AppKit then shifts the popover leftward to keep
//   it on-screen — so the arrow appears off-center relative to the popover body.
//
//   Fix: pass a 1pt-wide rect centered on button.bounds.midX as the
//   positioningRect. AppKit still points the arrow at the button, but now
//   "the button" is a 1pt slice at the center, so the popover is centered
//   under the button and the arrow appears at the top-center of the popover.
//
// SIDE-JUMP UNDER AUTO-HIDE MENUBAR (HIDDEN STATE) — fix/side-jump-autohide:
//   When macOS auto-hide menubar is hidden the Dock pushes the NSStatusItem
//   button window off the top edge: buttonWin.frame.origin.y >= screen.frame.height.
//   In this state ANY contentSize write causes AppKit to re-run full anchor
//   geometry against the off-screen button position, collapsing the popover
//   x-origin to 0 (side-jump).
//
//   Root cause: with sizingOptions = .preferredContentSize, AppKit writes
//   contentSize automatically on every SwiftUI layout change. With sizingOptions
//   empty, preferredContentSize is never recomputed and KVO on it never fires.
//
//   Correct approach: observe hostingController.view \/.frame via KVO.
//   The hosting view frame IS updated live by SwiftUI on every layout pass
//   regardless of sizingOptions. Apply the isMenuBarHidden guard before
//   writing popover.contentSize.
//
//   CORRECT isMenuBarHidden signal:
//     screenH < 0 || buttonY >= screenH
//
//   screenH < 0 means button.window.screen returned nil — which itself signals
//   the button window has been slid off-screen by the Dock (screen association dropped).
//   buttonY >= screenH is the normal case where screen is still associated but
//   the window origin is at or beyond the screen height.
//
//   WRONG signals (do not use):
//     button.window.screen == nil alone  ← misses the buttonY >= screenH case
//     buttonScreen != nil && buttonY >= screenH  ← misses the screen==nil case
//       (screen CAN go nil; when it does screenH=-1, the && short-circuits to
//        false and the guard fails — side-jump happens)
//
//   Observed values:
//     Hidden:  buttonY=982, screenH=982  OR  buttonY=-1, screenH=-1 (screen nil)
//     Visible: buttonY=949, screenH=982
//
//   See runbot-hq/run-bot#2239.

import AppKit
import SwiftUI

/// Manages the full NSPopover and NSStatusItem lifecycle for a macOS menu-bar app.
/// Inject a root SwiftUI view and an MBKOverlayGate at init time, then call `setup()`
/// from `applicationDidFinishLaunching`.
@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    /// Overlay gate — read in popoverShouldClose and reset in popoverDidClose.
    private let overlayGate: MBKOverlayGate

    /// The root SwiftUI view hosted inside the popover.
    private let rootView: AnyView

    /// SF Symbol name for the status-bar icon.
    private let symbolName: String

    /// Initial popover content size.
    private let contentSize: NSSize

    // MARK: - Owned objects

    /// The status-bar item. Assigned in `setup()` — see IMPLICIT-UNWRAPPED OPTIONALS in the file header.
    private var statusItem: NSStatusItem!
    /// The managed NSPopover. Assigned in `setup()` — see IMPLICIT-UNWRAPPED OPTIONALS in the file header.
    private var popover: NSPopover!
    /// Hosts the root SwiftUI view. Assigned in `setup()` — see IMPLICIT-UNWRAPPED OPTIONALS in the file header.
    private var hostingController: NSHostingController<AnyView>!

    /// KVO token for `hostingController.view.frame`.
    /// We observe the hosting view frame — not preferredContentSize — because
    /// preferredContentSize is only recomputed when sizingOptions includes
    /// .preferredContentSize. With sizingOptions empty (required to prevent
    /// the side-jump), preferredContentSize never changes and KVO never fires.
    /// The hosting view frame IS updated live by SwiftUI on every layout pass.
    /// See SIDE-JUMP UNDER AUTO-HIDE MENUBAR in the file header.
    private var sizeObservation: NSKeyValueObservation?

    /// Guards against double-call of setup(). See setup() for rationale.
    private var isSetUp = false

    /// Global mouse-down event monitor token. nonisolated(unsafe) — see file header.
    nonisolated(unsafe) private var eventMonitor: Any?
    /// Workspace app-switch observer token. nonisolated(unsafe) — see file header.
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    // MARK: - Init

    /// Creates the controller with a root SwiftUI view and shared overlay gate.
    /// - Parameters:
    ///   - rootView: The root view displayed inside the popover.
    ///   - overlayGate: Shared gate; blocks dismiss while a sheet or picker is live.
    ///   - symbolName: SF Symbol name for the status-bar icon. Defaults to `"menubar.rectangle"`.
    ///   - contentSize: Initial popover content size. Defaults to 320×300.
    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle",
        contentSize: NSSize = NSSize(width: 320, height: 300)
    ) {
        self.rootView = AnyView(rootView)
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.contentSize = contentSize
    }

    // MARK: - Setup

    /// Wires the status item, popover, and observers.
    ///
    /// **Must be called from `applicationDidFinishLaunching` before any user
    /// interaction is possible.** Assigns the three IUO properties (`statusItem`,
    /// `popover`, `hostingController`). Any call to `togglePopover()` before
    /// `setup()` completes will crash on the `!` unwrap — this is intentional;
    /// a crash surfaces the ordering error immediately rather than silently
    /// producing a nil-op. See IMPLICIT-UNWRAPPED OPTIONALS in the file header.
    ///
    /// ❌ NEVER call `setup()` more than once. A `precondition` guards this at
    /// runtime. A second call would otherwise silently leak the old `NSStatusItem`
    /// and any installed observers without removing them.
    public func setup() {
        precondition(!isSetUp, "MBKPopoverController.setup() called more than once. See setup() doc comment.")
        isSetUp = true
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupWorkspaceObserver()
        mbkLog("PopoverController", "setup complete")
    }

    // MARK: - Status item

    /// Creates and configures the NSStatusItem and its button.
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    /// Toggles the popover open or closed when the status-bar button is clicked.
    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    /// Shows the popover anchored to the center of the status-bar button.
    ///
    /// We pass a 1pt-wide positioningRect at button.bounds.midX instead of
    /// button.bounds. This makes AppKit treat the button center as the anchor
    /// point, so the popover is horizontally centered under the button and the
    /// arrow appears at the top-center of the popover body regardless of width.
    /// See ARROW CENTERING in the file header.
    private func openPopover() {
        guard let button = statusItem.button else { return }
        let midX = button.bounds.midX
        let centerRect = NSRect(x: midX - 0.5, y: button.bounds.minY,
                                width: 1, height: button.bounds.height)
        popover.show(relativeTo: centerRect, of: button, preferredEdge: .minY)
        // ❌ DO NOT replace with NSApp.activate() (no-arg, the macOS 14+ form).
        // That call causes the popover window to flicker between active and
        // inactive chrome on every open — visually broken. Confirmed and
        // reverted in commit 7fe4caa. ignoringOtherApps: true must stay.
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
    }

    /// Sets the status-bar button highlight state.
    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    /// Creates and configures the NSPopover with the hosted SwiftUI root view.
    ///
    /// ❌ Do NOT set `hostingController.sizingOptions = .preferredContentSize`.
    /// That causes AppKit to write `popover.contentSize` automatically on every
    /// SwiftUI preferredContentSize change, including while the auto-hide menubar
    /// is hidden. Any contentSize write with the button off-screen causes a
    /// side-jump. Instead, a manual KVO observer in `setupSizeObserver()` observes
    /// the hosting view frame and guards the write on `isMenuBarHidden`.
    /// See SIDE-JUMP note in the file header.
    private func setupPopover() {
        hostingController = NSHostingController(rootView: rootView)
        // ❌ Do NOT restore sizingOptions = .preferredContentSize — see doc comment above.
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = contentSize
        popover.animates = true
        // .applicationDefined = we handle all dismiss logic ourselves.
        popover.behavior = .applicationDefined
        popover.delegate = self
        setupSizeObserver()
    }

    // MARK: - Hosting view frame observer

    /// Installs a KVO observer on `hostingController.view.frame`.
    ///
    /// We observe the hosting view frame — not `preferredContentSize` — because
    /// `preferredContentSize` is only recomputed when `sizingOptions` includes
    /// `.preferredContentSize`. With `sizingOptions` empty (required to prevent
    /// the side-jump), `preferredContentSize` never changes and KVO on it never fires.
    ///
    /// The hosting view frame IS updated live by SwiftUI on every layout pass,
    /// making it the correct source of truth for driving `popover.contentSize`.
    ///
    /// The same `isMenuBarHidden` guard is applied before writing `popover.contentSize`
    /// to prevent the side-jump. See SIDE-JUMP UNDER AUTO-HIDE MENUBAR in the file header.
    private func setupSizeObserver() {
        sizeObservation = hostingController.view.observe(
            \.frame,
            options: [.new]
        ) { [weak self] view, _ in
            Task { @MainActor [weak self] in
                self?.applyPreferredContentSize(view.frame.size)
            }
        }
    }

    /// Applies a new content size to the popover, guarding against side-jump
    /// when the auto-hide menubar is hidden.
    ///
    /// Called from the hosting view `frame` KVO observer.
    /// The write is skipped when `screenH < 0 || buttonY >= screenH`:
    ///   - `screenH < 0` means `button.window.screen` is nil — the button window
    ///     has been slid off the screen edge by the Dock (screen association dropped).
    ///   - `buttonY >= screenH` is the normal hidden case where screen is still
    ///     associated but the window origin is at or beyond screen height.
    /// Either condition means AppKit’s anchor geometry is invalid; skip the write.
    /// See SIDE-JUMP UNDER AUTO-HIDE MENUBAR in the file header.
    private func applyPreferredContentSize(_ preferred: NSSize) {
        guard popover.isShown else {
            mbkLog("PopoverController", "applyPreferredContentSize — popover not shown, skipping")
            return
        }
        guard preferred.width > 0, preferred.height > 0 else {
            mbkLog("PopoverController", "applyPreferredContentSize — zero size (\(preferred.width),\(preferred.height)), skipping")
            return
        }
        let currentSize = popover.contentSize
        let popoverWinFrame = popover.contentViewController?.view.window?.frame
        let buttonWin = statusItem.button?.window
        let buttonWinFrame = buttonWin?.frame
        let buttonScreen = buttonWin?.screen
        let buttonY = buttonWinFrame?.origin.y ?? -1
        let screenH = buttonScreen?.frame.height ?? -1
        // fix/side-jump-autohide: screenH < 0 means screen==nil (button off-screen);
        // buttonY >= screenH is the normal hidden case. Both mean skip the write.
        // ❌ Do NOT use `buttonScreen != nil && buttonY >= screenH` — that expression
        //    evaluates false when screen is nil, allowing the write and causing side-jump.
        let isMenuBarHidden = screenH < 0 || buttonY >= screenH
        mbkLog("PopoverController",
               "applyPreferredContentSize — "
               + "preferred=(\(preferred.width),\(preferred.height)) "
               + "current=(\(currentSize.width),\(currentSize.height)) "
               + "popoverWin=\(String(describing: popoverWinFrame)) "
               + "buttonWin=\(String(describing: buttonWinFrame)) "
               + "buttonScreen=\(String(describing: buttonScreen?.frame)) "
               + "buttonY=\(buttonY) screenH=\(screenH) "
               + "isMenuBarHidden=\(isMenuBarHidden)")
        guard !isMenuBarHidden else {
            mbkLog("PopoverController",
                   "applyPreferredContentSize — SKIP: isMenuBarHidden=true "
                   + "(screenH=\(screenH) buttonY=\(buttonY))")
            return
        }
        guard abs(currentSize.width - preferred.width) > 1
                || abs(currentSize.height - preferred.height) > 1 else {
            mbkLog("PopoverController", "applyPreferredContentSize — no-op: size unchanged (delta within 1pt)")
            return
        }
        mbkLog("PopoverController",
               "applyPreferredContentSize — WRITING contentSize=(\(preferred.width),\(preferred.height)) "
               + "delta=(\(preferred.width - currentSize.width),\(preferred.height - currentSize.height)) "
               + "popoverWin=\(String(describing: popoverWinFrame))")
        popover.contentSize = preferred
        let postWriteFrame = popover.contentViewController?.view.window?.frame
        mbkLog("PopoverController",
               "applyPreferredContentSize — contentSize written "
               + "popoverWin.post=\(String(describing: postWriteFrame))")
    }

    // MARK: - Workspace observer

    /// Installs the NSWorkspace app-switch observer that closes the popover on app switch.
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

    /// Installs a global mouse-down monitor that closes the popover on outside clicks.
    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.popover.performClose(nil)
            }
        }
        mbkLog("PopoverController", "event monitor started")
    }

    /// Removes the global mouse-down monitor installed by `startEventMonitor()`.
    private func stopEventMonitor() {
        guard let monitor = eventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        eventMonitor = nil
        mbkLog("PopoverController", "event monitor stopped")
    }

    // MARK: - Deallocation

    // See deinit TEARDOWN in the file header for thread-safety rationale.
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

/// `NSPopoverDelegate` conformance — show/close lifecycle and dismiss gating.
extension MBKPopoverController: NSPopoverDelegate {
    /// Highlights the status-bar button when the popover is about to appear.
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
    }

    /// Blocks dismiss while any overlay (sheet or file picker) is active.
    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose blocked=\(block)")
        return !block
    }

    /// Cleans up after popover close: removes highlight, stops monitor, resets gate.
    public func popoverDidClose(_ notification: Notification) {
        mbkLog("PopoverController", "popoverDidClose")
        setButtonHighlight(false)
        stopEventMonitor()
        // Safety net — reset gate on close regardless of how we got here.
        overlayGate.hasActiveOverlay = false
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
