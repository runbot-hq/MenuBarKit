// MainView.swift
// MenuBarKitExample

import SwiftUI

/// Landing view shown on first popover open. Navigates to SettingsView.
///
/// SCROLL LIST — mimics run-bot's PanelMainView:
/// Items start empty and async-load 0.8s after onAppear via a Task,
/// exactly like run-bot's workflow rows arriving from @Observable AppState.
/// The GeometryReader in PopoverController.setupPopover() must fire
/// onChange as the ScrollView grows — this is the core scenario under test.
///
/// Width is fixed (260); ScrollView drives height only.
struct MainView: View {
    @Environment(AppState.self) private var appState

    private var scrollMaxHeight: CGFloat {
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

            // Async-loaded scroll list
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
            .frame(maxHeight: scrollMaxHeight)
        }
        .frame(width: 260)
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            print("[MainView] onAppear")
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
        .onDisappear {
            print("[MainView] onDisappear")
            appState.mainItems = []
        }
    }
}
