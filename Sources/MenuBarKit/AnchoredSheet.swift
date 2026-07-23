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
//   rather than to SwiftUI's binding state.
//
// GATE:
//   MBKOverlayGate is read from the SwiftUI environment (@Environment).
//   The host app injects it once at the root view via .environment(overlayGate).
//   No overlayGate: parameter is needed at each call site.
//
// NOTIFICATION CLOSURE ISOLATION:
//   NotificationCenter delivers callbacks on a Sendable (nonisolated) closure.
//   Accessing @MainActor-isolated state (NSWindow.styleMask, MBKSheetAnchorTask.finish)
//   requires hopping back to the main actor via Task { @MainActor in }.
//   The hop is safe: the notification is always posted on the main queue (.main),
//   so the Task body runs almost immediately with no observable latency.
//
// CANCELLATION PATH:
//   If the sheet binding flips back to false before the window becomes key,
//   the caller calls cancel() which resumes the continuation with nil and
//   removes the observer. This prevents the continuation from leaking.
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

/// Waits for a borderless NSWindow (other than `popoverWindow`) to become key,
/// then wires it as a child of `popoverWindow`.
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
                self.continuation = cont
                // Capture only the identity of popoverWindow so the Sendable
                // closure does not close over any @MainActor state.
                let popoverWindow = self.popoverWindow
                self.observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    // NotificationCenter delivers on a Sendable closure.
                    // Hop to @MainActor to access NSWindow.styleMask and finish().
                    Task { @MainActor [weak self] in
                        guard
                            let self,
                            let window = notification.object as? NSWindow,
                            window !== popoverWindow,
                            window.styleMask.contains(.borderless)
                        else { return }
                        self.finish(with: window)
                    }
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
