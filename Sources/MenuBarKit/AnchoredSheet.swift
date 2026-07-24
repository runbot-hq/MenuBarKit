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
// WHY TWO HOPS:
//   Hop 1 — Task { @MainActor } in onChange:
//     Actor isolation crossing. Does NOT guarantee the NSWindow exists yet.
//   Hop 2 — DispatchQueue.main.async:
//     Drains one more run-loop turn. Sheet NSWindow exists by this point.
//
// SHEET WINDOW DISCRIMINATORS:
//   styleMask == .borderless is NOT reliable — on some macOS versions SwiftUI
//   sheet windows have styleMask=193 (titled). Removed.
//
//   Remaining discriminators:
//   1. window !== popoverWindow
//   2. !window.styleMask.contains(.nonactivatingPanel) — rejects popover itself
//   3. !popoverWindow.sheets.contains(window) — rejects NSOpenPanel presented
//      via beginSheetModal(for: popoverWindow), which appears in .sheets.
//      SwiftUI sheet windows added via addChildWindow do NOT appear in .sheets.
//      This is the definitive discriminator confirmed by logs (inSheets=true
//      for picker, inSheets=false for SwiftUI sheet).
//
// GATE TIMING:
//   hasActiveOverlay set TRUE only after addChildWindow succeeds.
//   Set FALSE unconditionally in onChange(false).
//
// CANCELLATION:
//   cancel() flag checked in both hops.

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
        let capturedLabel = label
        Task { @MainActor [weak self] in
            guard let self, !self.cancelled else {
                mbkLog("AnchoredSheet[\(capturedLabel)]", "hop1 — cancelled/deallocated")
                return
            }
            mbkLog("AnchoredSheet[\(self.label)]", "hop1 complete — queuing hop2")
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled else {
                    mbkLog("AnchoredSheet[\(capturedLabel)]", "hop2 — cancelled/deallocated")
                    return
                }
                let pw = self.popoverWindow
                mbkLog("AnchoredSheet[\(self.label)]", "hop2 — polling \(NSApp.windows.count) windows")
                for w in NSApp.windows where w !== pw {
                    mbkLog("AnchoredSheet[\(self.label)]", "  candidate #\(w.windowNumber) styleMask=\(w.styleMask.rawValue) isKey=\(w.isKeyWindow) inSheets=\(pw.sheets.contains(w)) isPanel=\(w.styleMask.contains(.nonactivatingPanel))")
                }
                guard let sheetWindow = NSApp.windows.first(where: {
                    $0 !== pw &&
                    !$0.styleMask.contains(.nonactivatingPanel) &&
                    !pw.sheets.contains($0)
                }) else {
                    mbkLog("AnchoredSheet[\(self.label)]", "hop2 — no matching window found")
                    return
                }
                mbkLog("AnchoredSheet[\(self.label)]", "addChildWindow — #\(sheetWindow.windowNumber) styleMask=\(sheetWindow.styleMask.rawValue)")
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
