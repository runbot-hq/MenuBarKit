// RootView.swift
// MenuBarKitExample

import MenuBarKit
import SwiftUI

/// Root container that switches between `MainView` and `SettingsView`
/// based on `AppState.route`.
///
/// `.mbkReportSize(to:)` measures the resolved size after each layout pass
/// and pushes it into `MBKPopoverController.sizeRelay`, which calls
/// `show(relativeTo:of:preferredEdge:)` again to reanchor the popover arrow.
struct RootView: View {
    @Environment(AppState.self) private var appState
    let popoverController: MBKPopoverController

    var body: some View {
        Group {
            switch appState.route {
            case .main:     MainView()
            case .settings: SettingsView()
            }
        }
        .id(appState.route)
        .mbkReportSize(to: popoverController)
    }
}
