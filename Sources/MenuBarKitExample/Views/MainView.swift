// MainView.swift
// MenuBarKitExample

import SwiftUI

/// Landing view shown on first popover open. Navigates to `SettingsView`.
///
/// Intentionally uses a DIFFERENT width (260) than SettingsView (320) to
/// exercise PopoverController's dynamic-width arrow centering fix (see
/// positioningRect re-assignment, guarded against degenerate button bounds,
/// in applyContentSize()).
struct MainView: View {
    /// App state injected from the environment.
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            Text("Main").font(.headline)
            Button("Go to Settings") { appState.route = .settings }
        }
        .padding(16)
        .frame(width: 260)
        .onAppear    { print("[MainView] onAppear") }
        .onDisappear { print("[MainView] onDisappear") }
    }
}
