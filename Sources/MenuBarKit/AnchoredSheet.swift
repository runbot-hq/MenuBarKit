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
// GATE TIMING:
//   hasActiveOverlay is set TRUE optimistically in onChange(true) — before the
//   sheet window exists. This ensures popoverShouldClose is blocked the moment
//   isSheetPresented flips true, including during session restore where SwiftUI
//   fires onChange before creating the window.
//
//   cancel() explicitly clears the gate so a task cancelled before addChildWindow
//   never leaves hasActiveOverlay stuck true.
//
//   hasActiveOverlay is also cleared in onChange(false) for the normal dismiss
//   path, and in popoverDidClose as a safety net.
//
// WHY OPTIMISTIC GATING IS NOW SAFE:
//   The anchor observer has two guards that reject NSOpenPanel and any other
//   non-SwiftUI-sheet window:
//
//   1. window.styleMask == .borderless (exact equality, not .contains)
//      SwiftUI sheet windows have exactly .borderless and no other bits.
//      NSOpenPanel has .titled | .closable | .resizable even as a sheet modal.
//
//   2. !popoverWindow.sheets.contains(window)
//      NSOpenPanel presented via beginSheetModal(for: popoverWindow) appears
//      in popoverWindow.sheets. SwiftUI sheet windows added via addChildWindow
//      never appear in .sheets. This is the definitive discriminator.
//
//   These two guards make it safe to arm the gate early — the observer will
//   never misfire on a picker/alert and falsely anchor it as a sheet child.
//
// WHY NO withCheckedContinuation:
//   withCheckedContinuation suspends the calling Task off @MainActor, making
//   the resume closure nonisolated/Sendable. Every @MainActor access inside it
//   becomes an async hop — addChildWindow fires one runloop cycle too late.
//   Direct observer registration + MainActor.assumeIsolated keeps everything
//   synchronous on the main thread.
//
// WHY notification.object IS EXTRACTED BEFORE assumeIsolated:
//   The NotificationCenter closure parameter `notification` is non-Sendable.
//   Capturing it inside assumeIsolated crosses an isolation boundary (SE-0430).
//   Extracting `notification.object as? NSWindow` before the call captures
//   only the NSWindow pointer.
//
// CANCELLATION PATH:
//   cancel() removes the observer, sets cancelled=true, and clears the gate.
//   This handles the case where onChange(false) fires before the sheet window
//   ever appeared (e.g. SwiftUI initial reconcile diff on restore).
//
// DISMISS-SAFETY:
//   Gate is also cleared in onChange(false) synchronously. addChildWindow
//   removal is handled by AppKit automatically when the child window closes.
//
// WHY Item: Identifiable & Equatable (not just Identifiable):
//   onChange(of:) requires Equatable so SwiftUI can diff old vs new values.
//   MBKAnchoredSheetItemModifier uses onChange to observe the full item so it
//   can re-anchor on non-nil→non-nil identity swaps, which requires Equatable.

import AppKit
import SwiftUI

// MARK: - Module-level anchor helper

/// Observes NSWindow.didBecomeKeyNotification and wires the first matching
/// SwiftUI sheet window as a child of `popoverWindow` via addChildWindow.
/// The overlay gate is armed BEFORE this task starts (optimistically in onChange)
/// and is cleared by cancel() if the task is aborted before the window appears.
/// Returns a cancellable token — call `cancel()` if the sheet is dismissed
/// before its window appeared.
@MainActor
func mbkWaitAndAnchorSheetWindow(
    popoverWindow: NSWindow,
    overlayGate: MBKOverlayGate,
    label: String
) -> MBKSheetAnchorTask {
    let task = MBKSheetAnchorTask(popoverWindow: popoverWindow, overlayGate: overlayGate, label: label)
    task.start()
    return task
}

/// Cancellable token returned by `mbkWaitAndAnchorSheetWindow`.
@MainActor
final class MBKSheetAnchorTask {
    private let popoverWindow: NSWindow
    private let overlayGate: MBKOverlayGate
    private let label: String
    private var observer: NSObjectProtocol?
    private var cancelled = false

    init(popoverWindow: NSWindow, overlayGate: MBKOverlayGate, label: String) {
        self.popoverWindow = popoverWindow
        self.overlayGate = overlayGate
        self.label = label
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let candidate = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, !self.cancelled else { return }
                guard
                    let window = candidate,
                    window !== self.popoverWindow,
                    // Exact match — SwiftUI sheet windows have only .borderless.
                    // NSOpenPanel has .titled | .closable | .resizable even as a sheet modal.
                    window.styleMask == .borderless,
                    // Definitive discriminator: NSOpenPanel attached via beginSheetModal
                    // appears in popoverWindow.sheets; SwiftUI sheet windows do not.
                    !self.popoverWindow.sheets.contains(window)
                else { return }
                self.removeObserver()
                mbkLog("AnchoredSheet[\(self.label)]", "addChildWindow — windowNumber=\(window.windowNumber)")
                self.popoverWindow.addChildWindow(window, ordered: .above)
                // Gate was already armed in onChange(true) before this task started.
                mbkLog("AnchoredSheet[\(self.label)]", "hasActiveOverlay=true (already armed)")
            }
        }
    }

    /// Aborts the wait and clears the overlay gate.
    /// Called when onChange(false) fires before the window ever appeared.
    func cancel() {
        cancelled = true
        removeObserver()
        overlayGate.hasActiveOverlay = false
        mbkLog("AnchoredSheet[\(label)]", "anchor cancelled — gate cleared")
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

public struct MBKAnchoredSheetModifier<SheetContent: View>: ViewModifier {
    @Binding public var isPresented: Bool
    public let sheetContent: () -> SheetContent

    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var anchorTask: MBKSheetAnchorTask?

    public func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, content: sheetContent)
            .onChange(of: isPresented) { _, newValue in
                if newValue {
                    // Arm gate immediately — blocks popoverShouldClose before
                    // the sheet window exists. cancel() will clear it if needed.
                    overlayGate.hasActiveOverlay = true
                    guard let popoverWindow = NSApp.windows.first(where: {
                        $0.styleMask.contains(.nonactivatingPanel)
                    }) else {
                        mbkLog("AnchoredSheet", "no nonactivatingPanel window — sheet will not be anchored")
                        return
                    }
                    anchorTask = mbkWaitAndAnchorSheetWindow(
                        popoverWindow: popoverWindow,
                        overlayGate: overlayGate,
                        label: "isPresented"
                    )
                } else {
                    anchorTask?.cancel()
                    anchorTask = nil
                    overlayGate.hasActiveOverlay = false
                }
            }
    }
}

// MARK: - item variant

public struct MBKAnchoredSheetItemModifier<Item: Identifiable & Equatable, SheetContent: View>: ViewModifier {
    @Binding public var item: Item?
    public let sheetContent: (Item) -> SheetContent

    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var anchorTask: MBKSheetAnchorTask?

    public func body(content: Content) -> some View {
        content
            .sheet(item: $item, content: sheetContent)
            .onChange(of: item) { _, newValue in
                if newValue != nil {
                    // Arm gate immediately — blocks popoverShouldClose before
                    // the sheet window exists. cancel() will clear it if needed.
                    overlayGate.hasActiveOverlay = true
                    guard let popoverWindow = NSApp.windows.first(where: {
                        $0.styleMask.contains(.nonactivatingPanel)
                    }) else {
                        mbkLog("AnchoredSheet[item]", "no nonactivatingPanel window — sheet will not be anchored")
                        return
                    }
                    anchorTask = mbkWaitAndAnchorSheetWindow(
                        popoverWindow: popoverWindow,
                        overlayGate: overlayGate,
                        label: "item"
                    )
                } else {
                    anchorTask?.cancel()
                    anchorTask = nil
                    overlayGate.hasActiveOverlay = false
                }
            }
    }
}
