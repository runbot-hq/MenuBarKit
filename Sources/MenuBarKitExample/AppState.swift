// AppState.swift
// MenuBarKitExample
//
// App-specific state only. No popover lifecycle, no overlay gate —
// those live in MenuBarKit.
//
//   route           — which top-level view is visible.
//   pickedURL       — result from file picker opened in SettingsView.
//   sheetPickedURL  — result from file picker opened inside SheetView.
//   showAlert       — drives the .mbkAlert modifier in SettingsView (popover level).
//   showSheetAlert  — drives the .alert modifier in SheetView (sheet level).
//   mainItems       — async-loaded list rows for MainView (mimic run-bot workflows).
//   settingsItems   — async-loaded list rows for SettingsView (mimic run-bot runners).

import Foundation
import Observation

/// Navigation destinations for the example app's root view switcher.
enum Route: Equatable {
    case main
    case settings
}

/// Example app state. Owns only navigation and file-picker results.
@Observable
@MainActor
final class AppState {
    var route: Route = .main {
        didSet { print("[AppState] route: \(oldValue) → \(self.route)") }
    }
    var pickedURL: URL?
    var sheetPickedURL: URL?
    var showAlert: Bool = false {
        didSet { print("[AppState] showAlert: \(oldValue) → \(self.showAlert)") }
    }
    var showSheetAlert: Bool = false {
        didSet { print("[AppState] showSheetAlert: \(oldValue) → \(self.showSheetAlert)") }
    }

    // Async-loaded list items — mimic run-bot's @Observable workflow / runner rows
    // that populate after the popover opens.
    var mainItems: [String] = []
    var settingsItems: [String] = []
}
