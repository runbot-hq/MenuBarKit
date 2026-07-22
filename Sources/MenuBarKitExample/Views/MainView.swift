// MainView.swift
// MenuBarKitExample
//
// TEST BRANCH test/intrinsic-content-size-kvo: .frame(width: 260) removed.
// This view's width is now whatever its own content (the button) needs,
// via NSHostingView.intrinsicContentSize — no manual number declared here.

import SwiftUI

/// Landing view shown on first popover open. Navigates to `SettingsView`.
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
        .fixedSize()
        .onAppear    { print("[MainView] onAppear") }
        .onDisappear { print("[MainView] onDisappear") }
    }
}
