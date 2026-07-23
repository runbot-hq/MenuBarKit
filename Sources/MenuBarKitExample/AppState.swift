// AppState.swift
// MenuBarKitExample

import Foundation
import Observation

enum Route: Equatable {
    case main
    case settings
}

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

    // Pre-populated so the list is visible immediately on first open.
    // In run-bot these arrive async from @Observable state; the growth
    // scenario is exercised by the settingsItems async load below.
    var mainItems: [String] = [
        "build / test (ubuntu-latest)",
        "build / test (macos-latest)",
        "lint / swiftlint",
        "release / tag-and-publish",
        "deploy / staging",
        "deploy / production",
    ]

    // Empty at init — loaded async in SettingsView.onAppear to exercise
    // the popover-grows-after-open scenario.
    var settingsItems: [String] = []
}
