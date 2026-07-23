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

    // Full dataset — all items available immediately.
    // MainView shows the first `visibleCount` and exposes a Show More button.
    let allMainItems: [String] = [
        "build / test (ubuntu-latest)",
        "build / test (macos-latest)",
        "lint / swiftlint",
        "release / tag-and-publish",
        "deploy / staging",
        "deploy / production",
        "security / codeql",
        "security / dependency-review",
        "notify / slack-on-failure",
        "notify / slack-on-success",
        "perf / benchmark",
        "perf / size-check",
    ]

    // Empty at init — loaded async in SettingsView.onAppear to exercise
    // the popover-grows-after-open scenario.
    var settingsItems: [String] = []
}
