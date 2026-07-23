// FilePicker.swift
// MenuBarKit
//
// Presents NSOpenPanel anchored to the popover window via beginSheetModal,
// and manages overlayGate.hasActiveOverlay for the duration of the panel's lifetime.
//
// WHY beginSheetModal INSTEAD OF runModal:
//   NSOpenPanel.runModal() blocks the main thread and ignores the popover.
//   beginSheetModal attaches the panel as a sheet to a specific window,
//   keeping it visually anchored.
//
// WHY hasActiveOverlay IS SET BEFORE beginSheetModal:
//   popoverShouldClose can fire at any point, including during the brief window
//   between when we decide to open the panel and when beginSheetModal returns.
//   Setting the gate before the call ensures the dismiss gate is armed for the
//   entire panel lifetime with no race.
//
// beginSheetModal COMPLETION — WHY Task { @MainActor }:
//   NSOpenPanel.beginSheetModal delivers its completion on the main thread, but
//   this guarantee is informal (not expressed in the Swift type system). The
//   completion mutates overlayGate.hasActiveOverlay (@MainActor-isolated) and
//   calls back into caller-supplied code that may also touch actor-isolated state.
//   Wrapping in Task { @MainActor } makes the actor hop explicit and
//   compiler-enforced, rather than relying on AppKit's undocumented delivery
//   guarantee. This is the correct Swift 6 pattern.

import AppKit

/// Opens a directory picker anchored to the popover window.
/// The completion closure is called on the main actor with the selected URL,
/// or nil if the user cancelled.
///
/// - Parameters:
///   - overlayGate: The shared overlay gate; set to `true` while the picker is open.
///   - message: Optional descriptive message shown in the panel header.
///     Pass `nil` to use the system default.
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
