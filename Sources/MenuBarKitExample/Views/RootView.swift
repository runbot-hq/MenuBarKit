// RootView.swift
// MenuBarKitExample

import SwiftUI

/// Root container that switches between `MainView` and `SettingsView`
/// based on `AppState.route`.
///
/// NOTE: do NOT add .id(appState.route) here.
/// Glass is handled by NSGlassEffectView in PopoverController — no
/// SwiftUI glass modifiers needed here.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.route {
            case .main:     MainView()
            case .settings: SettingsView()
            }
        }
        .background(.clear)
        .onAppear  { print("[RootView] onAppear  route=\(appState.route)") }
        .onDisappear { print("[RootView] onDisappear route=\(appState.route)") }
    }
}
