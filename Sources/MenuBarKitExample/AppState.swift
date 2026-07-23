// AppState.swift
// MenuBarKitExample
//
// App-specific state only. No popover lifecycle, no overlay gate —
// those live in MenuBarKit.
//
//   route              — which top-level view is visible.
//   isSheetPresented   — whether the sheet in SettingsView is open.
//                        Lifted out of local @State so it survives across
//                        popover sessions via SessionSnapshot.
//   pickedPath         — result from file picker opened in SettingsView.
//   sheetPickedPath    — result from file picker opened inside SheetView.
//   showAlert          — drives the .mbkAlert modifier in SettingsView (popover level).
//   showSheetAlert     — drives the .alert modifier in SheetView (sheet level).

import Foundation
import Observation

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
        didSet { print("[AppState] route: \(oldValue) → \(self.route)") }
    }
    /// Whether the sheet in SettingsView is currently presented.
    /// Lifted out of local @State so it can be saved/restored across popover sessions.
    var isSheetPresented: Bool = false
    /// URL selected by the file picker opened from SettingsView (popover context). nil until first pick.
    var pickedURL: URL?
    /// URL selected by the file picker opened from SheetView (sheet context). nil until first pick.
    var sheetPickedURL: URL?
    /// Controls the error alert presented from SettingsView (popover level).
    var showAlert: Bool = false {
        didSet { print("[AppState] showAlert: \(oldValue) → \(self.showAlert)") }
    }
    /// Controls the error alert presented from inside SheetView.
    var showSheetAlert: Bool = false {
        didSet { print("[AppState] showSheetAlert: \(oldValue) → \(self.showSheetAlert)") }
    }

    // MARK: - Session snapshot

    /// Lightweight snapshot of the state worth restoring on next popover open.
    /// pickedURL, showAlert, showSheetAlert are intentionally excluded — transient.
    struct SessionSnapshot {
        var route: Route
        var isSheetPresented: Bool
    }

    func saveSnapshot() -> SessionSnapshot {
        SessionSnapshot(route: route, isSheetPresented: isSheetPresented)
    }

    func restoreSnapshot(_ snapshot: SessionSnapshot) {
        route = snapshot.route
        isSheetPresented = snapshot.isSheetPresented
    }
}
