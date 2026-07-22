// RootView.swift
// MenuBarKitExample
//
// *** TEST BRANCH test/intrinsic-content-size-kvo ***
// Deliberately does NOT call sizingBridge.setContentSize() anymore. This
// branch is testing whether NSHostingView.intrinsicContentSize (KVO) alone
// can drive popover sizing with zero manual size declarations from the
// example app. If Main and Settings end up at genuinely different,
// content-appropriate widths with NO code here declaring a number, the
// experiment worked. If not — revert to fix/popover-arrow-centering's
// version of this file, which uses Route.contentSize + sizingBridge
// explicitly and is known to work.
import SwiftUI

struct RootView: View {
    /// App state injected from the environment.
    @Environment(AppState.self) private var appState

    /// Renders `MainView` or `SettingsView` depending on the current route.
    var body: some View {
        Group {
            switch appState.route {
            case .main:     MainView()
            case .settings: SettingsView()
            }
        }
        .id(appState.route)
        .onAppear { print("[RootView] onAppear  route=\(appState.route)") }
        .onDisappear { print("[RootView] onDisappear route=\(appState.route)") }
    }
}
