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
//   hasActiveOverlay is set TRUE only after addChildWindow succeeds inside the
//   notification callback — never optimistically in onChange. This eliminates
//   the stuck-gate failure mode where onChange(true) fires during SwiftUI's
//   initial render or session restore, no sheet window ever appears, and
//   nothing clears the gate.
//
//   hasActiveOverlay is set FALSE synchronously in onChange(false) —
//   unconditionally, regardless of whether addChildWindow was ever called.
//   cancel() does NOT touch the gate for the same reason: if cancel() is
//   called before addChildWindow fired, the gate was never set true.
//
// ANCHOR OBSERVER DISCRIMINATORS:
//   Two guards in the observer reject NSOpenPanel and other non-sheet windows:
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
//   These guards make the stale anchor observer registered during session
//   restore harmless: it waits forever but can never misfire on picker/alert.
//
// SESSION RESTORE:
//   When isSheetPresented is restored via onDidShow, onChange(true) fires and
//   registers an anchor observer. SwiftUI does not re-present the sheet window
//   automatically, so the observer waits indefinitely. This is safe because:
//     - The gate is never armed (addChildWindow never fires)
//     - The discriminators ensure picker/alert cannot satisfy the observer
//     - The observer is cancelled and cleaned up when the user opens and then
//       dismisses the sheet (onChange(false) -> cancel())
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
// WHY Item: Identifiable & Equatable (not just Identifiable):
//   onChange(of:) requires Equatable so SwiftUI can diff old vs new values.
//   MBKAnchoredSheetItemModifier uses onChange to observe the full item so it
//   can re-anchor on non-nil→non-nil identity swaps, which requires Equatable.

import AppKit
import SwiftUI

// MARK: - Module-level anchor helper

/// Observes NSWindow.didBecomeKeyNotification and wires the first matching
/// SwiftUI sheet window as a child of `popoverWindow` via addChildWindow.
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
                // Arm gate AFTER addChildWindow — never before.
                self.overlayGate.hasActiveOverlay = true
                mbkLog("AnchoredSheet[\(self.label)]", "hasActiveOverlay=true")
            }
        }
    }

    /// Aborts the wait. Gate is not touched — if addChildWindow never fired,
    /// the gate was never set true so there is nothing to clear.
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
                mbkLog("AnchoredSheet[isPresented]", "onChange — newValue=\(newValue)")
                if newValue {
                    guard let popoverWindow = NSApp.windows.first(where: {
                        $0.styleMask.contains(.nonactivatingPanel)
                    }) else {
                        mbkLog("AnchoredSheet[isPresented]", "no nonactivatingPanel window — aborting")
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
                    mbkLog("AnchoredSheet[isPresented]", "hasActiveOverlay=false")
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
                mbkLog("AnchoredSheet[item]", "onChange — newValue=\(newValue != nil ? "some" : "nil")")
                if newValue != nil {
                    guard let popoverWindow = NSApp.windows.first(where: {
                        $0.styleMask.contains(.nonactivatingPanel)
                    }) else {
                        mbkLog("AnchoredSheet[item]", "no nonactivatingPanel window — aborting")
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
                    mbkLog("AnchoredSheet[item]", "hasActiveOverlay=false")
                }
            }
    }
}
