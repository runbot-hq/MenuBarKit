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
//   After SwiftUI presents the sheet, poll NSApp.windows two runloop turns
//   later to find the new sheet window and wire it as a child of the popover
//   window via addChildWindow(_:ordered:).
//
// WHY TWO HOPS (matching d7e8596):
//   Hop 1 — Task { @MainActor } in onChange:
//     Crosses the actor isolation boundary. Does NOT guarantee the NSWindow
//     exists yet — SwiftUI has not rendered the sheet in this turn.
//
//   Hop 2 — DispatchQueue.main.async inside MBKSheetAnchorTask.start():
//     Drains one more run-loop turn. By this point SwiftUI has created the
//     sheet NSWindow and it appears in NSApp.windows.
//
//   Collapsing to one hop (DispatchQueue only, no Task) loses the second
//   drain and the sheet window is not yet in NSApp.windows on restore.
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
//   cancel() sets a flag checked in both hops. If the sheet is dismissed
//   before the poll fires, no child window is created and gate stays false.

import AppKit
import SwiftUI

// MARK: - Anchor task

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
        mbkLog("AnchoredSheet[\(label)]", "start — hop1 Task queued")
        // Capture label for use in guard-else branches where self may be nil.
        let capturedLabel = label
        // Hop 1: actor isolation crossing — does NOT guarantee sheet window exists yet.
        Task { @MainActor [weak self] in
            guard let self, !self.cancelled else {
                mbkLog("AnchoredSheet[\(capturedLabel)]", "hop1 — cancelled or deallocated, aborting")
                return
            }
            mbkLog("AnchoredSheet[\(self.label)]", "hop1 complete — queuing hop2 DispatchQueue")
            // Hop 2: drain one more runloop turn — sheet NSWindow exists by now.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled else {
                    mbkLog("AnchoredSheet[\(capturedLabel)]", "hop2 — cancelled or deallocated, aborting")
                    return
                }
                let pw = self.popoverWindow
                mbkLog("AnchoredSheet[\(self.label)]", "hop2 — polling NSApp.windows (count=\(NSApp.windows.count))")
                for w in NSApp.windows where w !== pw {
                    mbkLog("AnchoredSheet[\(self.label)]", "  candidate #\(w.windowNumber) styleMask=\(w.styleMask.rawValue) isKey=\(w.isKeyWindow) inSheets=\(pw.sheets.contains(w))")
                }
                guard let sheetWindow = NSApp.windows.first(where: {
                    $0 !== pw &&
                    $0.styleMask == .borderless &&
                    !pw.sheets.contains($0)
                }) else {
                    mbkLog("AnchoredSheet[\(self.label)]", "hop2 — no matching window found")
                    return
                }
                mbkLog("AnchoredSheet[\(self.label)]", "addChildWindow — windowNumber=\(sheetWindow.windowNumber)")
                pw.addChildWindow(sheetWindow, ordered: .above)
                self.overlayGate.hasActiveOverlay = true
                mbkLog("AnchoredSheet[\(self.label)]", "hasActiveOverlay=true")
            }
        }
    }

    func cancel() {
        cancelled = true
        mbkLog("AnchoredSheet[\(label)]", "cancel called")
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
                mbkLog("AnchoredSheet[isPresented]", "onChange newValue=\(newValue) windows=\(NSApp.windows.count)")
                if newValue {
                    guard let popoverWindow = NSApp.windows.first(where: {
                        $0.styleMask.contains(.nonactivatingPanel)
                    }) else {
                        mbkLog("AnchoredSheet[isPresented]", "onChange — no nonactivatingPanel, aborting")
                        return
                    }
                    mbkLog("AnchoredSheet[isPresented]", "onChange — popoverWindow #\(popoverWindow.windowNumber), starting task")
                    anchorTask = mbkWaitAndAnchorSheetWindow(
                        popoverWindow: popoverWindow,
                        overlayGate: overlayGate,
                        label: "isPresented"
                    )
                } else {
                    anchorTask?.cancel()
                    anchorTask = nil
                    overlayGate.hasActiveOverlay = false
                    mbkLog("AnchoredSheet[isPresented]", "onChange false — hasActiveOverlay=false")
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
                mbkLog("AnchoredSheet[item]", "onChange isPresented=\(isPresented) windows=\(NSApp.windows.count)")
                if isPresented {
                    guard let popoverWindow = NSApp.windows.first(where: {
                        $0.styleMask.contains(.nonactivatingPanel)
                    }) else {
                        mbkLog("AnchoredSheet[item]", "onChange — no nonactivatingPanel, aborting")
                        return
                    }
                    mbkLog("AnchoredSheet[item]", "onChange — popoverWindow #\(popoverWindow.windowNumber), starting task")
                    anchorTask = mbkWaitAndAnchorSheetWindow(
                        popoverWindow: popoverWindow,
                        overlayGate: overlayGate,
                        label: "item"
                    )
                } else {
                    anchorTask?.cancel()
                    anchorTask = nil
                    overlayGate.hasActiveOverlay = false
                    mbkLog("AnchoredSheet[item]", "onChange false — hasActiveOverlay=false")
                }
            }
    }
}
