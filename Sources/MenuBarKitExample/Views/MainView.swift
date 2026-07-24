// MainView.swift
// MenuBarKitExample

import MenuBarKit
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKOverlayGate.self) private var overlayGate

    private var visibleItems: [MenuItem] { MenuItem.allCases.filter { !$0.isHidden } }

    var body: some View {
        let _ = print("[MainView] body evaluated — visibleCount=\(visibleItems.count) gate=\(overlayGate.hasActiveOverlay)")
        VStack(spacing: 0) {
            ForEach(visibleItems) { item in
                MenuItemRow(item: item)
                    .onTapGesture {
                        print("[MainView] tapped item=\(item.id)")
                        handleTap(item)
                    }
                if item != visibleItems.last { Divider() }
            }
        }
        .onAppear    { print("[MainView] onAppear visibleCount=\(visibleItems.count) gate=\(overlayGate.hasActiveOverlay)") }
        .onDisappear { print("[MainView] onDisappear") }
    }

    private func handleTap(_ item: MenuItem) {
        print("[MainView] handleTap item=\(item.id) route=\(appState.route)")
        switch item {
        case .settings:
            print("[MainView] navigating to settings")
            appState.route = .settings
        default:
            print("[MainView] item=\(item.id) has no handler")
        }
    }
}
