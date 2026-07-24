// FilePicker.swift
// MenuBarKit

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

    guard let window = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel)
    }) else {
        mbkLog("FilePicker", "no popover window found, aborting")
        return
    }
    mbkLog("FilePicker", "popover window=#\(window.windowNumber)")

    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Select"
    if let message { panel.message = message }
    mbkLog("FilePicker", "panel created — setting hasActiveOverlay=true")

    overlayGate.hasActiveOverlay = true
    mbkLog("FilePicker", "hasActiveOverlay=true — calling beginSheetModal")

    panel.beginSheetModal(for: window) { response in
        mbkLog("FilePicker", "beginSheetModal completion — response=\(response.rawValue) hasActiveOverlay=\(overlayGate.hasActiveOverlay)")
        Task { @MainActor in
            mbkLog("FilePicker", "completion Task hop — setting hasActiveOverlay=false")
            overlayGate.hasActiveOverlay = false
            let url = response == .OK ? panel.url : nil
            mbkLog("FilePicker", "hasActiveOverlay=false — calling completion url=\(String(describing: url))")
            completion(url)
            mbkLog("FilePicker", "completion done")
        }
    }
    mbkLog("FilePicker", "beginSheetModal returned (panel is now showing)")
}
