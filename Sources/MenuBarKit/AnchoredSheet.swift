// AnchoredSheet.swift
// MenuBarKit
//
// GATE TIMING:
//   overlayGate.hasActiveOverlay is set TRUE synchronously in onChange before
//   any async hops. This ensures the event monitor sees the gate immediately
//   even if the poll hasn't fired yet. Set FALSE synchronously on dismiss.
//
// WHY TWO HOPS:
//   Hop 1 — Task { @MainActor }: actor crossing. Sheet NSWindow may not exist.
//   Hop 2 — DispatchQueue.main.async: one more runloop drain. Window exists.
//
// SHEET WINDOW DISCRIMINATOR:
//   .borderless && isKeyWindow — SwiftUI makes the sheet window key immediately
//   on creation. NSOpenPanel is not borderless. Zombie sentinel windows are not
//   key. This pair is the reliable discriminator from d7e8596.

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
                    mbkLog("AnchoredSheet[\(self.label)]",
                           "  candidate #\(w.windowNumber) styleMask=\(w.styleMask.rawValue)"
                           + " isKey=\(w.isKeyWindow) borderless=\(w.styleMask == .borderless)"
                           + " inSheets=\(pw.sheets.contains(w))")
                }
                guard let sheetWindow = NSApp.windows.first(where: {
                    $0 !== pw &&
                    $0.styleMask.contains(.borderless) &&
                    $0.isKeyWindow
                }) else {
                    mbkLog("AnchoredSheet[\(self.label)]", "hop2 — no matching window found")
                    return
                }
                mbkLog("AnchoredSheet[\(self.label)]", "addChildWindow — #\(sheetWindow.windowNumber)")
                pw.addChildWindow(sheetWindow, ordered: .above)
                mbkLog("AnchoredSheet[\(self.label)]", "addChildWindow done")
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
        overlayGate: MBKOverlayGate,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(MBKAnchoredSheetModifier(isPresented: isPresented, overlayGate: overlayGate, sheetContent: content))
    }

    func mbkSheet<Item: Identifiable & Equatable, SheetContent: View>(
        item: Binding<Item?>,
        overlayGate: MBKOverlayGate,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        modifier(MBKAnchoredSheetItemModifier(item: item, overlayGate: overlayGate, sheetContent: content))
    }
}

// MARK: - isPresented variant

public struct MBKAnchoredSheetModifier<SheetContent: View>: ViewModifier {
    @Binding public var isPresented: Bool
    public let overlayGate: MBKOverlayGate
    public let sheetContent: () -> SheetContent
    @State private var anchorTask: MBKSheetAnchorTask?

    public func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, content: sheetContent)
            .onChange(of: isPresented) { _, newValue in
                mbkLog("AnchoredSheet[isPresented]", "onChange newValue=\(newValue) windows=\(NSApp.windows.count)")
                // Arm gate synchronously before hops so event monitor
                // sees it immediately regardless of poll result.
                overlayGate.hasActiveOverlay = newValue
                if newValue {
                    guard let popoverWindow = NSApp.windows.first(where: {
                        $0.styleMask.contains(.nonactivatingPanel)
                    }) else {
                        mbkLog("AnchoredSheet[isPresented]", "onChange — no nonactivatingPanel, aborting")
                        return
                    }
                    mbkLog("AnchoredSheet[isPresented]", "onChange — popoverWindow #\(popoverWindow.windowNumber), gate=true, starting task")
                    anchorTask = mbkWaitAndAnchorSheetWindow(
                        popoverWindow: popoverWindow,
                        overlayGate: overlayGate,
                        label: "isPresented"
                    )
                } else {
                    anchorTask?.cancel()
                    anchorTask = nil
                    mbkLog("AnchoredSheet[isPresented]", "onChange false — gate=false")
                }
            }
    }
}

// MARK: - item variant

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
                mbkLog("AnchoredSheet[item]", "onChange isPresented=\(isPresented) windows=\(NSApp.windows.count)")
                overlayGate.hasActiveOverlay = isPresented
                if isPresented {
                    guard let popoverWindow = NSApp.windows.first(where: {
                        $0.styleMask.contains(.nonactivatingPanel)
                    }) else {
                        mbkLog("AnchoredSheet[item]", "onChange — no nonactivatingPanel, aborting")
                        return
                    }
                    mbkLog("AnchoredSheet[item]", "onChange — popoverWindow #\(popoverWindow.windowNumber), gate=true, starting task")
                    anchorTask = mbkWaitAndAnchorSheetWindow(
                        popoverWindow: popoverWindow,
                        overlayGate: overlayGate,
                        label: "item"
                    )
                } else {
                    anchorTask?.cancel()
                    anchorTask = nil
                    mbkLog("AnchoredSheet[item]", "onChange false — gate=false")
                }
            }
    }
}
