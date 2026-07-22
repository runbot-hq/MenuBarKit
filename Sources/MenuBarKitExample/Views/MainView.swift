// MainView.swift
// MenuBarKitExample

import SwiftUI

/// Landing view shown on first popover open. Navigates to `SettingsView`.
///
/// Uses the same `idealWidth` as `SettingsView` (320). All views in the popover's
/// navigation tree MUST agree on the same width — see PopoverController's
/// ARROW CENTERING note. A mismatched width here causes the popover to
/// side-jump and the arrow to misalign when navigating between views.
struct MainView: View {
    /// App state injected from the environment.
    @Environment(AppState.self) private var appState

    /// The main view body — a single Settings button.
    var body: some View {
        VStack(spacing: 12) {
            Button("Settings →") { appState.route = .settings }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(idealWidth: 320, maxWidth: .infinity, alignment: .top)
        .onAppear    { print("[MainView] onAppear") }
        .onDisappear { print("[MainView] onDisappear") }
    }
}
