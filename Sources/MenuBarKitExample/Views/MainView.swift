// MainView.swift
// MenuBarKitExample

import MenuBarKit
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKOverlayGate.self) private var overlayGate

    var body: some View {
        let _ = print("[MainView] body evaluated — route=\(appState.route) gate=\(overlayGate.hasActiveOverlay)")
        VStack(spacing: 12) {
            Text("Main").font(.headline)
            Button("Go to Settings") {
                print("[MainView] Go to Settings tapped")
                appState.route = .settings
            }
        }
        .padding(16)
        .frame(width: 260)
        .onAppear    { print("[MainView] onAppear route=\(appState.route) gate=\(overlayGate.hasActiveOverlay)") }
        .onDisappear { print("[MainView] onDisappear") }
    }
}
