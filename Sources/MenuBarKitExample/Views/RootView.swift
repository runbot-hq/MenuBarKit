// RootView.swift
// MenuBarKitExample

import MenuBarKit
import SwiftUI

/// Root container that switches between `MainView` and `SettingsView`.
/// `.mbkReportSize()` reads size from the environment `MBKSizeRelay` and
/// forwards it to `MBKPopoverController` to reanchor the popover arrow.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKSizeRelay.self) private var sizeRelay

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

    /// Freeze the window before route mutation so the wrong-size frame
    /// is never visible. PopoverController restores alpha after setFrame.
    func navigate(to route: AppRoute) {
        sizeRelay.freezeForRouteChange()
        appState.route = route
    }
}
