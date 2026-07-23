// FilePicker.swift
// MenuBarKit
//
// Presents NSOpenPanel anchored to the popover window via beginSheetModal,
// and manages overlayGate.hasActiveOverlay for the duration of the panel's lifetime.
//
// GATE:
//   MBKOverlayGate is passed explicitly here because mbkOpenFilePicker is a
//   free function, not a ViewModifier — it has no access to the SwiftUI
//   environment. The caller must pass the gate obtained from @Environment.
//
// WHY beginSheetModal INSTEAD OF runModal:
//   NSOpenPanel.runModal() blocks the main thread and ignores the popover.
//   beginSheetModal attaches the panel as a sheet to a specific window,
//   keeping it visually anchored.
//
// WHY hasActiveOverlay IS SET BEFORE beginSheetModal:
//   popoverShouldClose can fire between deciding to open the panel and
//   beginSheetModal returning. Setting the gate first ensures no race.
//
// beginSheetModal COMPLETION — WHY Task { @MainActor }:
//   NSOpenPanel.beginSheetModal delivers its completion on the main thread,
//   but this guarantee is informal. Task { @MainActor } makes the actor hop
//   explicit and compiler-enforced — the correct Swift 6 pattern.

import AppKit

/// Opens a directory picker anchored to the popover window.
/// The completion closure is called on the main actor with the selected URL,
/// or nil if the user cancelled.
///
/// - Parameters:
///   - overlayGate: The shared overlay gate — obtain from `@Environment(MBKOverlayGate.self)`.
///   - message: Optional descriptive message shown in the panel header.
///   - completion: Called on the main actor with the selected `URL`, or `nil` if cancelled.
@MainActor
public func mbkOpenFilePicker(
    overlayGate: MBKOverlayGate,
    message: String? = nil,
    completion: @escaping @MainActor (URL?) -> Void
) {
    guard let window = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel)
    }) else {
        mbkLog("FilePicker", "no popover window found, aborting")
        return
    }

    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Select"
    if let message { panel.message = message }

    overlayGate.hasActiveOverlay = true
    mbkLog("FilePicker", "hasActiveOverlay=true")

    panel.beginSheetModal(for: window) { response in
        Task { @MainActor in
            overlayGate.hasActiveOverlay = false
            mbkLog("FilePicker", "hasActiveOverlay=false")
            completion(response == .OK ? panel.url : nil)
        }
    }
}
