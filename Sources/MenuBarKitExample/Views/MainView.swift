// MainView.swift
// MenuBarKitExample

import AppKit
import SwiftUI

/// Landing view shown on first popover open. Navigates to SettingsView.
///
/// SCROLL LIST — mimics run-bot's PanelMainView:
/// Items async-load 0.8s after first onAppear (cached after that).
/// The GeometryReader in PopoverController must fire onChange as the
/// VStack grows — this is the core height-expansion scenario under test.
///
/// Width is fixed (260); height is uncapped so fittingSize reflects
/// the full intrinsic height and GeometryReader fires onChange.
struct MainView: View {
    @Environment(AppState.self) private var appState

    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.80
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible immediately
            HStack {
                Text("MBK Example").font(.headline)
                Spacer()
                Button("Settings →") { appState.route = .settings }
                    .buttonStyle(.plain)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Scroll list — uncapped so GeometryReader sees real growth
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if appState.mainItems.isEmpty {
                        Text("Loading…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(appState.mainItems, id: \.self) { item in
                            HStack {
                                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                                Text(item).font(.caption)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 260)
        .frame(maxHeight: maxHeight)  // cap the whole VStack, not the ScrollView
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            print("[MainView] onAppear")
            guard appState.mainItems.isEmpty else { return }  // cached — skip reload
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                appState.mainItems = [
                    "build / test (ubuntu-latest)",
                    "build / test (macos-latest)",
                    "lint / swiftlint",
                    "release / tag-and-publish",
                    "deploy / staging",
                    "deploy / production",
                ]
            }
        }
    }
}
