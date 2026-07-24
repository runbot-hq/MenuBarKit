// FilePicker.swift
// MenuBarKit
//
// WHY panel.begin{} INSTEAD OF beginSheetModal:
//   beginSheetModal attaches NSOpenPanel as an AppKit sheet to the popover
//   hosting window. SwiftUI writes true back into any live .sheet(isPresented:)
//   binding on that window — corrupting isSheetPresented state.
//
// WHY addChildWindow:
//   panel.begin{} alone leaves the panel behind the popover window.
//   addChildWindow(panel, ordered: .above) ensures the panel renders on top.
//   We remove the child relationship in the completion block before clearing
//   the gate, so hasSheetChildWindow never sees it as a sheet overlay.
//
// WHY DEFERRED GATE CLEAR:
//   The global mouse-down monitor fires on the same click that dismisses
//   the panel. Clearing hasActiveOverlay synchronously lets the monitor see
//   false on that event and call performClose. One DispatchQueue.main.async
//   hop defers the clear past that event delivery.

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

    guard let popoverWindow = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel)
    }) else {
        mbkLog("FilePicker", "no popover window found, aborting")
        return
    }
    mbkLog("FilePicker", "popoverWindow=#\(popoverWindow.windowNumber)")

    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Select"
    if let message { panel.message = message }
    mbkLog("FilePicker", "panel created")

    overlayGate.hasActiveOverlay = true
    mbkLog("FilePicker", "hasActiveOverlay=true — calling panel.begin")

    panel.begin { response in
        mbkLog("FilePicker", "panel.begin completion — response=\(response.rawValue) hasActiveOverlay=\(overlayGate.hasActiveOverlay)")
        popoverWindow.removeChildWindow(panel)
        mbkLog("FilePicker", "removeChildWindow done")
        DispatchQueue.main.async {
            mbkLog("FilePicker", "deferred gate clear — setting hasActiveOverlay=false")
            overlayGate.hasActiveOverlay = false
            let url = response == .OK ? panel.url : nil
            mbkLog("FilePicker", "hasActiveOverlay=false — calling completion url=\(String(describing: url))")
            completion(url)
            mbkLog("FilePicker", "completion done")
        }
    }

    popoverWindow.addChildWindow(panel, ordered: .above)
    mbkLog("FilePicker", "addChildWindow done — panel=#\(panel.windowNumber)")
    panel.makeKeyAndOrderFront(nil)
    mbkLog("FilePicker", "makeKeyAndOrderFront called")
}
