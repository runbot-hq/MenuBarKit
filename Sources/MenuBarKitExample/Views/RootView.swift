// RootView.swift
// MenuBarKitExample

import SwiftUI

/// Root container that switches between `MainView` and `SettingsView`
/// based on `AppState.route`.
///
/// `.id(appState.route)` forces SwiftUI to destroy and recreate the view
/// on every route change rather than updating in place. Without it, SwiftUI
/// reuses the same view identity and never issues a new preferredContentSize
/// measurement, so the popover size stays frozen at the first route's size.
struct RootView: View {
    /// App state injected from the environment.
    @Environment(AppState.self) private var appState

    /// Renders `MainView` or `SettingsView` depending on the current route.
    var body: some View {
        Group {
            switch appState.route {
            case .main:     MainView()
            case .settings: SettingsView()
            }
        }
        .id(appState.route)
    }
}
