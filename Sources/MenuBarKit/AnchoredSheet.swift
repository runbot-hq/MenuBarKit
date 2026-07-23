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
//   This ties the gate and anchoring to the actual AppKit window lifecycle
//   rather than to SwiftUI's binding state, eliminating both the GCD hop and
//   the DISMISS-SAFETY GAP from the spike.
//
// SHEET WINDOW DISCRIMINATOR — why .borderless && not popoverWindow:
//   The sheet window is matched by: not the popover window and borderless styleMask.
//   isKeyWindow is NOT used here — we receive the notification only when the window
//   becomes key, so the check is implicit. The popover window is .nonactivatingPanel
//   (not .borderless), so excluding it by identity is sufficient.
//
//   An earlier version used `contentViewController is NSHostingController<AnyView>`
//   as a stronger discriminator but SwiftUI's internal sheet window does NOT use
//   that exact generic specialisation. Do not re-attempt without verifying the
//   concrete NSHostingController generic type on the target OS version.
//
// CANCELLATION PATH — early sheet dismiss before window becomes key:
//   waitForSheetWindow() stores the continuation in a nonisolated(unsafe) var.
//   If the sheet binding flips back to false before the window becomes key,
//   the caller cancels via cancelWait() which resumes the continuation with nil
//   and removes the observer. This prevents the continuation from leaking.
//
// DISMISS-SAFETY:
//   Gate is cleared in onChange(false) synchronously. addChildWindow removal is
//   handled by AppKit automatically when the child window closes — no manual
//   removeChildWindow call is needed on the dismiss path.
//
// WHY Item: Identifiable & Equatable (not just Identifiable):
//   onChange(of:) requires Equatable so SwiftUI can diff old vs new values.
//   Optional<Item> conditionally conforms to Equatable only when Item is Equatable.
//   SwiftUI's own .sheet(item:) only requires Identifiable because it doesn't diff.
//   MBKAnchoredSheetItemModifier uses onChange to observe the full item so it
//   can re-anchor on non-nil→non-nil identity swaps, which requires Equatable.

import AppKit
import SwiftUI

// MARK: - Module-level anchor helper

/// Waits for a borderless NSWindow (other than `popoverWindow`) to become key,
/// then wires it as a child of `popoverWindow`. Returns the anchored window,
/// or `nil` if cancelled before the window appeared.
///
/// Cancellation: call `cancel()` on the returned token to abort the wait and
/// resume the continuation cleanly. Safe to call even after the window has
/// already been found.
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
/// Call `cancel()` if the sheet is dismissed before its window became key.
@MainActor
final class MBKSheetAnchorTask {
    private let popoverWindow: NSWindow
    private let label: String
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<NSWindow?, Never>?
    private var task: Task<Void, Never>?

    init(popoverWindow: NSWindow, label: String) {
        self.popoverWindow = popoverWindow
        self.label = label
    }

    func start() {
        task = Task { [weak self] in
            guard let self else { return }
            let window = await withCheckedContinuation { (cont: CheckedContinuation<NSWindow?, Never>) in
                // Store continuation so cancel() can resume it.
                self.continuation = cont
                self.observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    guard let self else { return }
                    guard
                        let window = notification.object as? NSWindow,
                        window !== self.popoverWindow,
                        window.styleMask.contains(.borderless)
                    else { return }
                    self.finish(with: window)
                }
            }
            guard let window else {
                mbkLog("AnchoredSheet[\(self.label)]", "anchor cancelled — sheet dismissed before window became key")
                return
            }
            mbkLog("AnchoredSheet[\(self.label)]", "addChildWindow")
            self.popoverWindow.addChildWindow(window, ordered: .above)
        }
    }

    /// Aborts the wait. Safe to call after the window has already been found (no-op).
    func cancel() {
        finish(with: nil)
    }

    private func finish(with window: NSWindow?) {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        continuation?.resume(returning: window)
        continuation = nil
    }
}

// MARK: - View extension

/// View extension providing `mbkSheet` modifiers for popover-anchored sheet presentation.
public extension View {

    /// Presents a sheet anchored as a child of the popover window so it
    /// survives outside-clicks and stays visible when the popover loses focus.
    ///
    /// Manages `overlayGate.hasActiveOverlay` automatically.
    func mbkSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        overlayGate: MBKOverlayGate,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(MBKAnchoredSheetModifier(
            isPresented: isPresented,
            overlayGate: overlayGate,
            sheetContent: content
        ))
    }

    /// Presents a sheet anchored as a child of the popover window, driven by
    /// an optional item binding — matching SwiftUI's `.sheet(item:)` API shape.
    ///
    /// The sheet is presented when `item` becomes non-nil and dismissed when it
    /// returns to nil. `overlayGate.hasActiveOverlay` is managed automatically.
    ///
    /// `Item` must conform to both `Identifiable` and `Equatable` — see
    /// WHY Item: Identifiable & Equatable in the file header.
    func mbkSheet<Item: Identifiable & Equatable, SheetContent: View>(
        item: Binding<Item?>,
        overlayGate: MBKOverlayGate,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        modifier(MBKAnchoredSheetItemModifier(
            item: item,
            overlayGate: overlayGate,
            sheetContent: content
        ))
    }
}

// MARK: - isPresented variant

/// ViewModifier that anchors a SwiftUI sheet as a child window of the popover
/// and manages `MBKOverlayGate` for the sheet's lifetime.
public struct MBKAnchoredSheetModifier<SheetContent: View>: ViewModifier {
    @Binding public var isPresented: Bool
    public let overlayGate: MBKOverlayGate
    public let sheetContent: () -> SheetContent

    @State private var anchorTask: MBKSheetAnchorTask?

    public func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, content: sheetContent)
            .onChange(of: isPresented) { _, newValue in
                overlayGate.hasActiveOverlay = newValue
                if newValue {
                    Task { @MainActor in
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
                    }
                } else {
                    // Cancel in case the sheet was dismissed before its window became key.
                    anchorTask?.cancel()
                    anchorTask = nil
                }
            }
    }
}

// MARK: - item variant

/// ViewModifier that anchors a SwiftUI `.sheet(item:)` as a child window of the
/// popover and manages `MBKOverlayGate` for the sheet's lifetime.
///
/// `Item` must conform to `Identifiable & Equatable` — see file header.
///
/// Uses `onChange(of: item)` rather than `onChange(of: item != nil)` so anchoring
/// fires on every identity change, including non-nil→non-nil swaps.
public struct MBKAnchoredSheetItemModifier<Item: Identifiable & Equatable, SheetContent: View>: ViewModifier {
    @Binding public var item: Item?
    public let overlayGate: MBKOverlayGate
    public let sheetContent: (Item) -> SheetContent

    @State private var anchorTask: MBKSheetAnchorTask?

    public func body(content: Content) -> some View {
        content
            .sheet(item: $item, content: sheetContent)
            .onChange(of: item) { _, newValue in
                let isPresented = newValue != nil
                overlayGate.hasActiveOverlay = isPresented
                if isPresented {
                    Task { @MainActor in
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
                    }
                } else {
                    anchorTask?.cancel()
                    anchorTask = nil
                }
            }
    }
}
