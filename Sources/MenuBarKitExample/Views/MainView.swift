// MainView.swift
// MenuBarKitExample

import AppKit
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState

    private var scrollMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.80
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .frame(maxHeight: scrollMaxHeight)  // cap here — VStack reports true intrinsic height
        }
        .frame(width: 260)
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            print("[MainView] onAppear")
            guard appState.mainItems.isEmpty else { return }
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
