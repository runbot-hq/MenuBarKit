// RootView.swift
// MenuBarKitExample

import MenuBarKit
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let _ = print("[RootView] body evaluated — route=\(appState.route) isSheetPresented=\(appState.isSheetPresented)")
        Group {
            switch appState.route {
            case .main:     MainView()
            case .settings: SettingsView()
            }
        }
        .id(appState.route)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        print("[RootView] GeometryReader onAppear size=(\(geo.size.width),\(geo.size.height)) route=\(appState.route)")
                    }
                    .onChange(of: geo.size) { old, new in
                        print("[RootView] size changed (\(old.width),\(old.height)) -> (\(new.width),\(new.height)) route=\(appState.route)")
                    }
            }
        )
        .onAppear    { print("[RootView] onAppear  route=\(appState.route) isSheetPresented=\(appState.isSheetPresented)") }
        .onDisappear { print("[RootView] onDisappear route=\(appState.route) isSheetPresented=\(appState.isSheetPresented)") }
    }
}
