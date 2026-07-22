// RootView.swift
// MenuBarKitExample

import MenuBarKit
import SwiftUI

/// Root container that switches between `MainView` and `SettingsView`.
/// `.mbkReportSize()` reads size from the environment `MBKSizeRelay` and
/// forwards it to `MBKPopoverController` to reanchor the popover arrow.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.route {
            case .main:     MainView()
            case .settings: SettingsView()
            }
        }
        .id(appState.route)
        .mbkReportSize()
    }
}
