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
// NOTIFICATION CLOSURE ISOLATION:
//   The observer is registered from @MainActor. NotificationCenter delivers
//   with queue: .main, so the callback is already on the main thread.
//   MainActor.assumeIsolated asserts this synchronously — no Task, no
//   continuation, no isolation boundary crossing. Notification stays entirely
//   within the nonisolated closure and is never sent anywhere.
//
// CANCELLATION PATH:
//   cancel() removes the observer and calls addChildWindow with nil guard.
//   Safe to call after the window has already been found (observer already removed).
//
// WHY Item: Identifiable & Equatable (not just Identifiable):
//   onChange(of:) requires Equatable so SwiftUI can diff old vs new values.
//   MBKAnchoredSheetItemModifier uses onChange to observe the full item so it
//   can re-anchor on non-nil→non-nil identity swaps, which requires Equatable.

import AppKit
import SwiftUI

// MARK: - Anchor task

/// Observes NSWindow.didBecomeKeyNotification and wires the first matching
/// borderless window as a child of `popoverWindow`.
/// Call `cancel()` if the sheet is dismissed before its window appeared.
@MainActor
final class MBKSheetAnchorTask {
    private let popoverWindow: NSWindow
    private let label: String
    private var observer: NSObjectProtocol?

    init(popoverWindow: NSWindow, label: String) {
        self.popoverWindow = popoverWindow
        self.label = label
    }

    func start() {
        // Capture only value types / identities in the closure to avoid
        // sending non-Sendable reference types across isolation boundaries.
        // The closure is nonisolated; MainActor.assumeIsolated is used to
        // assert the main-thread guarantee that queue: .main provides.
        let popoverWindow = self.popoverWindow
        let label = self.label
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees we are on the main thread.
            // MainActor.assumeIsolated asserts this without any isolation crossing.
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let window = NSApp.windows.first(where: {
                    $0 !== popoverWindow && $0.styleMask.contains(.borderless) && $0.isKeyWindow
                }) else { return }
                self.finish(anchoring: window)
            }
            _ = label // silence capture warning
        }
    }

    func cancel() {
        removeObserver()
        mbkLog("AnchoredSheet[\(label)]", "anchor cancelled")
    }

    private func finish(anchoring window: NSWindow) {
        removeObserver()
        mbkLog("AnchoredSheet[\(label)]", "addChildWindow")
        popoverWindow.addChildWindow(window, ordered: .above)
    }

    private func removeObserver() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}

// MARK: - Module-level factory

@MainActor
func mbkWaitAndAnchorSheetWindow(
    popoverWindow: NSWindow,
    label: String
) -> MBKSheetAnchorTask {
    let task = MBKSheetAnchorTask(popoverWindow: popoverWindow, label: label)
    task.start()
    return task
}

// MARK: - View extension

/// View extension providing `mbkSheet` modifiers for popover-anchored sheet presentation.
/// Reads `MBKOverlayGate` from the SwiftUI environment — inject once at the root
/// via `.environment(overlayGate)`; no `overlayGate:` parameter needed at call sites.
public extension View {

    /// Presents a sheet anchored as a child of the popover window.
    /// Reads `MBKOverlayGate` from the environment automatically.
    func mbkSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(MBKAnchoredSheetModifier(isPresented: isPresented, sheetContent: content))
    }

    /// Presents a sheet anchored as a child of the popover window, driven by an optional item.
    /// Reads `MBKOverlayGate` from the environment automatically.
    /// `Item` must conform to `Identifiable & Equatable` — see file header.
    func mbkSheet<Item: Identifiable & Equatable, SheetContent: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        modifier(MBKAnchoredSheetItemModifier(item: item, sheetContent: content))
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
                overlayGate.hasActiveOverlay = newValue
                if newValue {
                    Task { @MainActor in
                        guard let popoverWindow = NSApp.windows.first(where: {
                            $0.styleMask.contains(.nonactivatingPanel)
                        }) else {
                            mbkLog("AnchoredSheet", "no nonactivatingPanel window — sheet will not be anchored")
                            return
                        }
                        anchorTask = mbkWaitAndAnchorSheetWindow(popoverWindow: popoverWindow, label: "isPresented")
                    }
                } else {
                    anchorTask?.cancel()
                    anchorTask = nil
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
                        anchorTask = mbkWaitAndAnchorSheetWindow(popoverWindow: popoverWindow, label: "item")
                    }
                } else {
                    anchorTask?.cancel()
                    anchorTask = nil
                }
            }
    }
}
