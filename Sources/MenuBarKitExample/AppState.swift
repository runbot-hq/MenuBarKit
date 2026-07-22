// AppState.swift
// MenuBarKitExample
//
// App-specific state only. No popover lifecycle, no overlay gate —
// those live in MenuBarKit.
//
//   route           — which top-level view is visible.
//   pickedPath      — result from file picker opened in SettingsView.
//   sheetPickedPath — result from file picker opened inside SheetView.
//   showAlert       — drives the .mbkAlert modifier in SettingsView (popover level).
//   showSheetAlert  — drives the .alert modifier in SheetView (sheet level).

import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "MenuBarKitExample", category: "AppState")

/// Navigation destinations for the example app's root view switcher.
enum Route: Equatable {
    /// The main landing view.
    case main
    /// The settings view that exercises sheet and file picker scenarios.
    case settings
}

/// Example app state. Owns only navigation and file-picker results.
@Observable
@MainActor
final class AppState {
    /// Currently displayed route.
    var route: Route = .main {
        didSet {
            log.debug("[AppState] route changed: \(String(describing: oldValue), privacy: .public) → \(String(describing: route), privacy: .public)")
        }
    }
    /// URL selected by the file picker opened from SettingsView (popover context). nil until first pick.
    var pickedURL: URL?
    /// URL selected by the file picker opened from SheetView (sheet context). nil until first pick.
    var sheetPickedURL: URL?
    /// Controls the error alert presented from SettingsView (popover level).
    var showAlert: Bool = false {
        didSet { log.debug("[AppState] showAlert: \(oldValue, privacy: .public) → \(showAlert, privacy: .public)") }
    }
    /// Controls the error alert presented from inside SheetView.
    var showSheetAlert: Bool = false {
        didSet { log.debug("[AppState] showSheetAlert: \(oldValue, privacy: .public) → \(showSheetAlert, privacy: .public)") }
    }
}
