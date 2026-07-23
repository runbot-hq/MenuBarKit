// AppState.swift
// MenuBarKitExample

import MenuBarKit
import SwiftUI

/// Navigation destinations.
enum AppRoute {
    case main
    case settings
}

/// Shared observable app state.
@Observable
@MainActor
final class AppState {
    var route: AppRoute = .main
    var pickedURL: URL?
    var showAlert: Bool = false

    // Async-loaded list items — mimic run-bot's @Observable workflow rows
    // that populate after the popover opens.
    var mainItems: [String] = []
    var settingsItems: [String] = []
}
