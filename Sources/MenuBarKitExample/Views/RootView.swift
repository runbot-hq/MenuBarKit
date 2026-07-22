// RootView.swift
// MenuBarKitExample
//
// Root container that switches between `MainView` and `SettingsView`
// based on `AppState.route`.
//
// SIZING: explicit, not measured. Every route change calls
// sizingBridge.setContentSize(appState.route.contentSize) directly —
// there is no GeometryReader, no fittingSize, no PreferenceKey anywhere
// in this file. See PopoverController.swift's header and
// AppState.swift's Route.contentSize for why measurement-based sizing
// was abandoned entirely. This is the ONE place the example app tells
// MenuBarKit how big the popover should be, and it does so on:
//   - onAppear (initial route)
//   - onChange(of: appState.route) (every subsequent route change)
import SwiftUI

struct RootView: View {
    /// App state injected from the environment.
    @Environment(AppState.self) private var appState
    /// Bridge used to explicitly declare popover content size per route.
    @Environment(SizingBridge.self) private var sizingBridge

    /// Renders `MainView` or `SettingsView` depending on the current route.
    var body: some View {
        Group {
            switch appState.route {
            case .main:     MainView()
            case .settings: SettingsView()
            }
        }
        .id(appState.route)
        .onAppear {
            print("[RootView] onAppear  route=\(appState.route)")
            sizingBridge.setContentSize(appState.route.contentSize)
        }
        .onDisappear { print("[RootView] onDisappear route=\(appState.route)") }
        .onChange(of: appState.route) { oldRoute, newRoute in
            let size = newRoute.contentSize
            print("[RootView] route changed \(oldRoute) → \(newRoute), declaring size (\(size.width),\(size.height))")
            sizingBridge.setContentSize(size)
        }
    }
}
