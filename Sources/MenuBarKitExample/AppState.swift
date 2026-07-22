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

/// Navigation destinations for the example app's root view switcher.
enum Route: Equatable {
    /// The main landing view.
    case main
    /// The settings view that exercises sheet and file picker scenarios.
    case settings

    /// Explicit, caller-declared content size for this route. This is the
    /// ONLY source of truth for popover sizing — MBKPopoverController does
    /// not measure SwiftUI content in any way (see PopoverController.swift
    /// header for why every measurement-based approach was abandoned).
    /// These values MUST match each route view's own .frame(width:) —
    /// there is no mechanism that keeps them in sync automatically, so
    /// update both together when a route's layout changes.
    var contentSize: CGSize {
        switch self {
        case .main:     CGSize(width: 260, height: 56)
        case .settings: CGSize(width: 640, height: 320)
        }
    }
}

/// Example app state. Owns only navigation and file-picker results.
@Observable
@MainActor
final class AppState {
    /// Currently displayed route.
    var route: Route = .main {
        didSet { print("[AppState] route: \(oldValue) → \(self.route)") }
    }
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
}
