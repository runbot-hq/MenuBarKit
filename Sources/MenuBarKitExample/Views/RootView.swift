// RootView.swift
// MenuBarKitExample

import SwiftUI

/// Root container that switches between `MainView` and `SettingsView`
/// based on `AppState.route`.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            switch appState.route {
            case .main:     MainView()
            case .settings: SettingsView()
            }
        }
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 12))
        .onAppear  { print("[RootView] onAppear  route=\(appState.route)") }
        .onDisappear { print("[RootView] onDisappear route=\(appState.route)") }
    }
}
