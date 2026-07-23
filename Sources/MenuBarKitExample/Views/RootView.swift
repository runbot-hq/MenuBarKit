// RootView.swift
// MenuBarKitExample

import SwiftUI

/// Root container that switches between `MainView` and `SettingsView`
/// based on `AppState.route`.
///
/// NOTE: do NOT add .id(appState.route) here.
/// .id() forces SwiftUI to emit a transitional size event with the new
/// route's width but the old route's height (e.g. 320×369 when going
/// main→settings). applyContentSize sees dw=+60/dh=0 and shifts the
/// window left — the side-jump bug.
///
/// With sizingOptions=.preferredContentSize, SwiftUI re-measures and
/// fires preferredContentSize KVO after every layout pass, so the popover
/// always converges to the correct size without needing .id() to force it.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.route {
            case .main:     MainView()
            case .settings: SettingsView()
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        print("[RootView] GeometryReader onAppear size=(\(geo.size.width),\(geo.size.height)) route=\(appState.route)")
                    }
                    .onChange(of: geo.size) { old, new in
                        print("[RootView] size changed (\(old.width),\(old.height)) → (\(new.width),\(new.height)) route=\(appState.route)")
                    }
            }
        )
        .onAppear  { print("[RootView] onAppear  route=\(appState.route)") }
        .onDisappear { print("[RootView] onDisappear route=\(appState.route)") }
    }
}
