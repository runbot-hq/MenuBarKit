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
//   hasActiveOverlay is set TRUE only after addChildWindow succeeds — not
//   optimistically in onChange. This eliminates two failure modes:
//
//     1. Session restore: onChange fires with newValue==true before SwiftUI
//        has presented a sheet window. The observer registers, no window ever
//        becomes key, cancel() is called on dismiss, gate was never set true.
//        No stuck gate, file picker unblocked.
//
//     2. No Task hop needed: because the gate is set inside the notification
//        callback (which fires when the window actually exists), there is no
//        race between observer registration and window appearance.
//        addChildWindow and gate-arm happen atomically in the same callback.
//
//   hasActiveOverlay is set FALSE synchronously in onChange(newValue==false)
//   as before — dismiss always clears the gate regardless of whether
//   addChildWindow was ever called.
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
//   cancel() removes the observer and sets cancelled = true. Gate is never
//   set true if addChildWindow was never called, so cancel() needs no gate op.
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
/// Arms overlayGate.hasActiveOverlay ONLY after addChildWindow succeeds.
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
                    window.styleMask.contains(.borderless)
                else { return }
                self.removeObserver()
                mbkLog("AnchoredSheet[\(self.label)]", "addChildWindow — windowNumber=\(window.windowNumber)")
                self.popoverWindow.addChildWindow(window, ordered: .above)
                // Arm the gate AFTER addChildWindow — not before.
                self.overlayGate.hasActiveOverlay = true
                mbkLog("AnchoredSheet[\(self.label)]", "hasActiveOverlay=true")
            }
        }
    }

    /// Aborts the wait. Gate is untouched — it was never set true if this is called
    /// before addChildWindow fired.
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
                    // Do NOT set hasActiveOverlay here — set it only after
                    // addChildWindow succeeds inside MBKSheetAnchorTask.
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
