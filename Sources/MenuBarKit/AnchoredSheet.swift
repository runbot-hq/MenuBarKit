// AnchoredSheet.swift
// MenuBarKit
//
// PROBLEM:
//   SwiftUI's .sheet() creates a plain borderless NSWindow with no parent.
//   macOS treats it as a peer of the popover window, so:
//     - The sheet hides when the user clicks away from the app.
//     - The popover can be closed by an outside-click while the sheet is open.
//
// SOLUTION:
//   After SwiftUI presents the sheet, observe NSWindow.didBecomeKeyNotification.
//   When a borderless window that is not the popover window becomes key, wire it
//   as a child of the popover window via addChildWindow(_:ordered:).
//
// GATE:
//   MBKOverlayGate is read from the SwiftUI environment (@Environment).
//   The host app injects it once at the root view via .environment(overlayGate).
//   No overlayGate: parameter is needed at each call site.
//
// SHEET WINDOW DISCRIMINATOR — why .borderless && not popoverWindow:
//   The sheet window is matched by: not the popover window and borderless styleMask.
//   isKeyWindow is implicit — we receive the notification only when the window
//   becomes key. The popover window is .nonactivatingPanel (not .borderless),
//   so excluding it by identity is sufficient.
//
// WHY NO withCheckedContinuation:
//   withCheckedContinuation suspends the calling Task off @MainActor, making
//   the resume closure nonisolated/Sendable. Every @MainActor access inside it
//   (styleMask, finish()) becomes an async hop — addChildWindow fires one
//   runloop cycle too late, after the outside-click event monitor fires.
//   Direct observer registration on @MainActor + MainActor.assumeIsolated
//   in the callback keeps everything synchronous on the main thread.
//
// WHY notification.object IS EXTRACTED BEFORE assumeIsolated:
//   The NotificationCenter closure parameter `notification` is typed as
//   non-Sendable. Capturing it inside the assumeIsolated closure would cross
//   an isolation boundary with a non-Sendable value, triggering SE-0430
//   sending diagnostics. Extracting `notification.object as? NSWindow` before
//   the assumeIsolated call captures only the NSWindow pointer, which AppKit
//   guarantees is main-thread-safe for identity checks.
//
// CANCELLATION PATH:
//   cancel() removes the observer and sets cancelled = true, preventing a
//   late-firing callback from calling addChildWindow after dismiss.
//
// DISMISS-SAFETY:
//   Gate is cleared in onChange(false) synchronously. addChildWindow removal
//   is handled by AppKit automatically when the child window closes.
//
// WHY Item: Identifiable & Equatable (not just Identifiable):
//   onChange(of:) requires Equatable so SwiftUI can diff old vs new values.
//   MBKAnchoredSheetItemModifier uses onChange to observe the full item so it
//   can re-anchor on non-nil→non-nil identity swaps, which requires Equatable.

import AppKit
import SwiftUI

// MARK: - Module-level anchor helper

/// Observes NSWindow.didBecomeKeyNotification and wires the first matching
/// borderless window as a child of `popoverWindow` via addChildWindow.
/// Returns a cancellable token — call `cancel()` if the sheet is dismissed
/// before its window appeared.
@MainActor
func mbkWaitAndAnchorSheetWindow(
    popoverWindow: NSWindow,
    label: String
) -> MBKSheetAnchorTask {
    let task = MBKSheetAnchorTask(popoverWindow: popoverWindow, label: label)
    task.start()
    return task
}

/// Cancellable token returned by `mbkWaitAndAnchorSheetWindow`.
///
/// Registers an NSWindow.didBecomeKeyNotification observer directly on
/// @MainActor (queue: .main) and calls addChildWindow synchronously inside
/// the callback via MainActor.assumeIsolated — no Task suspension, no async
/// hop, no Sendable closure crossing an actor boundary.
@MainActor
final class MBKSheetAnchorTask {
    private let popoverWindow: NSWindow
    private let label: String
    private var observer: NSObjectProtocol?
    private var cancelled = false

    init(popoverWindow: NSWindow, label: String) {
        self.popoverWindow = popoverWindow
        self.label = label
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract object before assumeIsolated — notification itself is
            // non-Sendable and must not be captured across the isolation boundary.
            let candidate = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, !self.cancelled else { return }
                guard
                    let window = candidate,
                    window !== self.popoverWindow,
                    window.styleMask.contains(.borderless)
                else { return }
                self.removeObserver()
                mbkLog("AnchoredSheet[\(self.label)]", "addChildWindow — windowNumber=\(window.windowNumber)")
                self.popoverWindow.addChildWindow(window, ordered: .above)
            }
        }
    }

    /// Aborts the wait. Safe to call after the window has already been anchored (no-op).
    func cancel() {
        cancelled = true
        removeObserver()
        mbkLog("AnchoredSheet[\(label)]", "anchor cancelled")
    }

    private func removeObserver() {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
        }
    }
}

// MARK: - View extension

/// View extension providing `mbkSheet` modifiers for popover-anchored sheet presentation.
/// Reads `MBKOverlayGate` from the SwiftUI environment — inject it at the root view
/// via `.environment(overlayGate)` and no `overlayGate:` parameter is needed at call sites.
public extension View {

    /// Presents a sheet anchored as a child of the popover window so it
    /// survives outside-clicks and stays visible when the popover loses focus.
    /// Reads `MBKOverlayGate` from the environment automatically.
    func mbkSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(MBKAnchoredSheetModifier(
            isPresented: isPresented,
            sheetContent: content
        ))
    }

    /// Presents a sheet anchored as a child of the popover window, driven by
    /// an optional item binding — matching SwiftUI's `.sheet(item:)` API shape.
    /// Reads `MBKOverlayGate` from the environment automatically.
    /// `Item` must conform to both `Identifiable` and `Equatable` — see file header.
    func mbkSheet<Item: Identifiable & Equatable, SheetContent: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        modifier(MBKAnchoredSheetItemModifier(
            item: item,
            sheetContent: content
        ))
    }
}

// MARK: - isPresented variant

/// ViewModifier that anchors a SwiftUI sheet as a child window of the popover
/// and manages `MBKOverlayGate` (read from environment) for the sheet's lifetime.
public struct MBKAnchoredSheetModifier<SheetContent: View>: ViewModifier {
    @Binding public var isPresented: Bool
    public let sheetContent: () -> SheetContent

    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var anchorTask: MBKSheetAnchorTask?

    public func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, content: sheetContent)
            .onChange(of: isPresented) { _, newValue in
                overlayGate.hasActiveOverlay = newValue
                if newValue {
                    guard let popoverWindow = NSApp.windows.first(where: {
                        $0.styleMask.contains(.nonactivatingPanel)
                    }) else {
                        mbkLog("AnchoredSheet", "no nonactivatingPanel window — sheet will not be anchored")
                        return
                    }
                    anchorTask = mbkWaitAndAnchorSheetWindow(
                        popoverWindow: popoverWindow,
                        label: "isPresented"
                    )
                } else {
                    anchorTask?.cancel()
                    anchorTask = nil
                }
            }
    }
}

// MARK: - item variant

/// ViewModifier that anchors a SwiftUI `.sheet(item:)` as a child window of the
/// popover and manages `MBKOverlayGate` (read from environment) for the sheet's lifetime.
/// `Item` must conform to `Identifiable & Equatable` — see file header.
public struct MBKAnchoredSheetItemModifier<Item: Identifiable & Equatable, SheetContent: View>: ViewModifier {
    @Binding public var item: Item?
    public let sheetContent: (Item) -> SheetContent

    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var anchorTask: MBKSheetAnchorTask?

    public func body(content: Content) -> some View {
        content
            .sheet(item: $item, content: sheetContent)
            .onChange(of: item) { _, newValue in
                let isPresented = newValue != nil
                overlayGate.hasActiveOverlay = isPresented
                if isPresented {
                    guard let popoverWindow = NSApp.windows.first(where: {
                        $0.styleMask.contains(.nonactivatingPanel)
                    }) else {
                        mbkLog("AnchoredSheet[item]", "no nonactivatingPanel window — sheet will not be anchored")
                        return
                    }
                    anchorTask = mbkWaitAndAnchorSheetWindow(
                        popoverWindow: popoverWindow,
                        label: "item"
                    )
                } else {
                    anchorTask?.cancel()
                    anchorTask = nil
                }
            }
    }
}
