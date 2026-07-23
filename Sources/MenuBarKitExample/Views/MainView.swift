// MainView.swift
// MenuBarKitExample
//
// ScrollView capped at 80% screen height — content drives popover height
// via preferredContentSize KVO until the cap, then the list scrolls.
// Width = 260 (narrower than Settings 320) exercises arrow-centering on nav.

import AppKit
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState

    /// Cap scroll area at 80% of visible screen height so the popover
    /// never runs off screen on small displays.
    private var maxScrollHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.80
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("MBK Example").font(.headline)
                Spacer()
                Button("Settings →") {
                    print("[MainView] navigating to settings")
                    appState.route = .settings
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Scrollable list — height grows with content up to maxScrollHeight,
            // then scrolls. preferredContentSize KVO reports the capped height
            // to PopoverController which resizes + recenters the popover.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(appState.mainItems.enumerated()), id: \.offset) { _, item in
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
            .frame(maxHeight: maxScrollHeight)
        }
        .frame(width: 260)
        .onAppear { print("[MainView] onAppear items=\(appState.mainItems.count)") }
        .onDisappear { print("[MainView] onDisappear") }
    }
}
