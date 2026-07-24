// FilePicker.swift
// MenuBarKit
//
// WHY panel.begin{} INSTEAD OF beginSheetModal:
//   beginSheetModal attaches NSOpenPanel as an AppKit sheet to the popover
//   hosting window. SwiftUI writes true back into any live .sheet(isPresented:)
//   binding on that window — corrupting isSheetPresented state.
//
// WHY panel.level = .floating, NOT addChildWindow:
//   addChildWindow creates a parent-child relationship that causes two problems:
//   1. Clicking outside the app boundary dismisses the child panel (child
//      windows inherit parent activation/deactivation behaviour).
//   2. hasSheetChildWindow counts childWindows.count and cannot distinguish
//      a file picker child from an AnchoredSheet child — triggers forceClose.
//   Setting panel.level = .floating keeps the panel above normal windows and
//   above the popover without any parent-child relationship.
//
// WHY DEFERRED GATE CLEAR:
//   The global mouse-down monitor fires on the same click that dismisses the
//   panel. Clearing hasActiveOverlay synchronously lets the monitor see false
//   on that event and call performClose. One DispatchQueue.main.async hop
//   defers the clear past that event delivery.

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

    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Select"
    if let message { panel.message = message }
    panel.level = .floating
    mbkLog("FilePicker", "panel created — level=floating")

    overlayGate.hasActiveOverlay = true
    mbkLog("FilePicker", "hasActiveOverlay=true — calling panel.begin")

    panel.begin { response in
        mbkLog("FilePicker", "panel.begin completion — response=\(response.rawValue) hasActiveOverlay=\(overlayGate.hasActiveOverlay)")
        DispatchQueue.main.async {
            mbkLog("FilePicker", "deferred gate clear — setting hasActiveOverlay=false")
            overlayGate.hasActiveOverlay = false
            let url = response == .OK ? panel.url : nil
            mbkLog("FilePicker", "hasActiveOverlay=false — calling completion url=\(String(describing: url))")
            completion(url)
            mbkLog("FilePicker", "completion done")
        }
    }

    panel.makeKeyAndOrderFront(nil)
    mbkLog("FilePicker", "panel.begin returned — panel=#\(panel.windowNumber) level=\(panel.level.rawValue)")
}
