// FilePicker.swift
// MenuBarKit
//
// WHY panel.begin{} INSTEAD OF beginSheetModal:
//   beginSheetModal(for: popoverWindow) attaches NSOpenPanel as an AppKit
//   sheet to the popover hosting window. SwiftUI sees a new sheet appear on
//   that window and writes true back into any live .sheet(isPresented:)
//   binding on the same window — corrupting isSheetPresented state.
//   panel.begin{} presents the panel as a floating window with no sheet
//   relationship to any window, so SwiftUI never fires that writeback.

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
    mbkLog("FilePicker", "panel created — setting hasActiveOverlay=true")

    overlayGate.hasActiveOverlay = true
    mbkLog("FilePicker", "hasActiveOverlay=true — calling panel.begin (floating, no sheet attachment)")

    panel.begin { response in
        mbkLog("FilePicker", "panel.begin completion — response=\(response.rawValue) hasActiveOverlay=\(overlayGate.hasActiveOverlay)")
        Task { @MainActor in
            mbkLog("FilePicker", "completion Task hop — setting hasActiveOverlay=false")
            overlayGate.hasActiveOverlay = false
            let url = response == .OK ? panel.url : nil
            mbkLog("FilePicker", "hasActiveOverlay=false — calling completion url=\(String(describing: url))")
            completion(url)
            mbkLog("FilePicker", "completion done")
        }
    }
    mbkLog("FilePicker", "panel.begin returned (panel is now showing)")
}
