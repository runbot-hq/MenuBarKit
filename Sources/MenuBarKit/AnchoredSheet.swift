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
//   After SwiftUI presents the sheet, poll NSApp.windows one runloop later
//   via DispatchQueue.main.async to find the new sheet window and wire it
//   as a child of the popover window via addChildWindow(_:ordered:).
//
// WHY DispatchQueue.main.async (not NSWindow.didBecomeKeyNotification):
//   On session restore, onChange(true) fires and the sheet window is created
//   by SwiftUI in the same runloop turn. By the time a notification observer
//   is registered, didBecomeKeyNotification has already fired and the window
//   is missed. DispatchQueue.main.async polls one runloop later and catches
//   the window regardless of registration timing.
//
// SHEET WINDOW DISCRIMINATORS:
//   Two predicates identify the SwiftUI sheet window and reject NSOpenPanel:
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
// GATE TIMING:
//   hasActiveOverlay is set TRUE only after addChildWindow succeeds.
//   Never set in onChange — avoids stuck gate if poll finds no window.
//   Set FALSE unconditionally in onChange(false) — always clears on dismiss.
//
// CANCELLATION:
//   cancel() sets a flag. The DispatchQueue.main.async closure checks it
//   before anchoring — if the sheet was dismissed before the poll fires,
//   no child window is created and the gate stays false.
//
// WHY Item: Identifiable & Equatable (not just Identifiable):
//   onChange(of:) requires Equatable so SwiftUI can diff old vs new values.

import AppKit
import SwiftUI

// MARK: - Module-level anchor helper

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

@MainActor
final class MBKSheetAnchorTask {
    private let popoverWindow: NSWindow
    private let overlayGate: MBKOverlayGate
    private let label: String
    private var cancelled = false

    init(popoverWindow: NSWindow, overlayGate: MBKOverlayGate, label: String) {
        self.popoverWindow = popoverWindow
        self.overlayGate = overlayGate
        self.label = label
    }

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.cancelled else { return }
            let pw = self.popoverWindow
            // Log all candidate windows so we can see what's being matched/rejected
            let candidates = NSApp.windows.filter { $0 !== pw }
            for w in candidates {
                mbkLog("AnchoredSheet[\(self.label)]", "candidate windowNumber=\(w.windowNumber) styleMask=\(w.styleMask.rawValue) inSheets=\(pw.sheets.contains(w))")
            }
            guard let sheetWindow = candidates.first(where: {
                $0.styleMask == .borderless &&
                !pw.sheets.contains($0)
            }) else {
                mbkLog("AnchoredSheet[\(self.label)]", "poll — no matching window found")
                return
            }
            mbkLog("AnchoredSheet[\(self.label)]", "addChildWindow — windowNumber=\(sheetWindow.windowNumber)")
            pw.addChildWindow(sheetWindow, ordered: .above)
            self.overlayGate.hasActiveOverlay = true
            mbkLog("AnchoredSheet[\(self.label)]", "hasActiveOverlay=true")
        }
    }

    func cancel() {
        cancelled = true
        mbkLog("AnchoredSheet[\(label)]", "anchor cancelled")
    }
}

// MARK: - View extension

public extension View {
    func mbkSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(MBKAnchoredSheetModifier(isPresented: isPresented, sheetContent: content))
    }

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
