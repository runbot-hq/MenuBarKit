// FilePicker.swift
// MenuBarKit
//
// WHY panel.begin{} INSTEAD OF beginSheetModal:
//   beginSheetModal attaches NSOpenPanel as an AppKit sheet to the popover
//   hosting window. SwiftUI writes true back into any live .sheet(isPresented:)
//   binding on that window — corrupting isSheetPresented state.
//
// WHY panel.level = popoverWindow.level + 1, NOT addChildWindow:
//   addChildWindow creates a parent-child relationship:
//   1. Clicking outside the app boundary dismisses the child panel.
//   2. hasSheetChildWindow counts childWindows and triggers forceClose.
//   .floating (level 3) is below the popover's nonactivatingPanel level.
//   Reading the popover's actual level and adding 1 guarantees the panel
//   is always on top.
//
// WHY panel.orderOut AFTER COMPLETION:
//   NSOpenPanel windows are not automatically released after panel.begin{}.
//   Without explicit orderOut they accumulate in NSApp.windows.
//
// WHY gateWasAlreadyArmed / CONCURRENT OVERLAY SAFETY:
//   If called while a sheet is already open (gate=true), we must not clear
//   the gate on completion — the sheet is still holding it. We snapshot
//   the gate state before opening and only clear if we were the ones who
//   armed it. Mirrors the pattern in MBKAlertModifier.
//
// WHY DEFERRED GATE CLEAR:
//   The global mouse-down monitor fires on the same click that dismisses
//   the panel. Clearing hasActiveOverlay synchronously lets the monitor
//   see false on that event and call performClose. One
//   DispatchQueue.main.async hop defers the clear past that delivery.

import AppKit

@MainActor
public func mbkOpenFilePicker(
    overlayGate: MBKOverlayGate,
    message: String? = nil,
    completion: @escaping @MainActor (URL?) -> Void
) {
    mbkLog("FilePicker", "mbkOpenFilePicker called — overlayGate.hasActiveOverlay=\(overlayGate.hasActiveOverlay)")
    mbkLog("FilePicker", "window count=\(NSApp.windows.count)")
    for w in NSApp.windows {
        let title = w.title.isEmpty ? "<empty>" : w.title
        mbkLog("FilePicker", "  window #\(w.windowNumber) styleMask=\(w.styleMask.rawValue) isKey=\(w.isKeyWindow) title=\(title)")
    }

    // Snapshot before we touch the gate.
    let gateWasAlreadyArmed = overlayGate.hasActiveOverlay
    mbkLog("FilePicker", "gateWasAlreadyArmed=\(gateWasAlreadyArmed)")

    let popoverWindow = NSApp.windows.first {
        $0.styleMask.contains(.nonactivatingPanel)
    }
    let popoverLevel = popoverWindow?.level ?? .floating
    mbkLog("FilePicker", "popoverWindow=#\(popoverWindow?.windowNumber ?? -1) level=\(popoverLevel.rawValue)")

    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Select"
    if let message { panel.message = message }
    panel.level = NSWindow.Level(rawValue: popoverLevel.rawValue + 1)
    mbkLog("FilePicker", "panel created — level=\(panel.level.rawValue)")

    overlayGate.hasActiveOverlay = true
    mbkLog("FilePicker", "hasActiveOverlay=true — calling panel.begin")

    panel.begin { response in
        mbkLog("FilePicker", "panel.begin completion — response=\(response.rawValue) hasActiveOverlay=\(overlayGate.hasActiveOverlay) gateWasAlreadyArmed=\(gateWasAlreadyArmed)")
        panel.orderOut(nil)
        mbkLog("FilePicker", "panel.orderOut called — window count now=\(NSApp.windows.count)")
        DispatchQueue.main.async {
            if gateWasAlreadyArmed {
                mbkLog("FilePicker", "deferred: gate was already armed by concurrent overlay — preserving hasActiveOverlay=true")
            } else {
                mbkLog("FilePicker", "deferred gate clear — setting hasActiveOverlay=false")
                overlayGate.hasActiveOverlay = false
            }
            let url = response == .OK ? panel.url : nil
            mbkLog("FilePicker", "calling completion url=\(String(describing: url))")
            completion(url)
            mbkLog("FilePicker", "completion done")
        }
    }

    panel.makeKeyAndOrderFront(nil)
    mbkLog("FilePicker", "panel.begin returned — panel=#\(panel.windowNumber) level=\(panel.level.rawValue)")
}
