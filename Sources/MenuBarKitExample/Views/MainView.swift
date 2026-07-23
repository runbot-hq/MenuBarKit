// MainView.swift
// MenuBarKitExample

import SwiftUI

/// Landing view shown on first popover open. Navigates to SettingsView.
///
/// SCROLL LIST — mimic run-bot:
/// Items start empty and are async-loaded 0.8s after onAppear via a Task,
/// exactly like run-bot's workflow rows loading from @Observable AppState.
/// The GeometryReader in PopoverController.setupPopover() must fire
/// onChange when the ScrollView grows — this is the scenario under test.
///
/// WIDTH CONTRACT (matches PanelMainView):
///   .frame(width: 260).fixedSize(horizontal: true, vertical: false)
///   Width is fixed; ScrollView drives height. The GeometryReader sees
///   height growth as items load.
struct MainView: View {
    @Environment(AppState.self) private var appState

    /// Maximum scroll height — 80% of visible screen, matching run-bot.
    private var scrollMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.80
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row — always visible immediately (mimic PanelHeaderView)
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

            // Scrollable list — mirrors run-bot's actionsSectionScrollable
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
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.green)
                                Text(item)
                                    .font(.caption)
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
            // Simulate async data load — mirrors run-bot's @Observable
            // AppState.runnerState update that arrives after popover opens.
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
            appState.mainItems = []
        }
    }
}
