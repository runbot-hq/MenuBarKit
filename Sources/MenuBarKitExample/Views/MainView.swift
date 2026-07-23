// MainView.swift
// MenuBarKitExample
//
// Demonstrates dynamic height growth via a "Show more" button.
// preferredContentSize KVO in PopoverController picks up every height
// change and resizes + recenters the popover automatically.
// Width = 260 (narrower than Settings 320) exercises arrow-centering on nav.

import AppKit
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState
    @State private var visibleCount: Int = 4

    private var maxScrollHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.80
    }

    private var visibleItems: [String] {
        Array(appState.allMainItems.prefix(visibleCount))
    }

    private var remainingCount: Int {
        appState.allMainItems.count - visibleCount
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

            // Scrollable list — grows with content up to maxScrollHeight.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleItems.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Image(systemName: "checkmark.circle").foregroundStyle(.green)
                            Text(item).font(.caption)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        Divider().padding(.leading, 12)
                    }

                    // Show more button — only visible when items remain.
                    if remainingCount > 0 {
                        Button {
                            let next = min(4, remainingCount)
                            print("[MainView] show more tapped — revealing \(next) items")
                            visibleCount += next
                        } label: {
                            HStack {
                                Image(systemName: "chevron.down").font(.caption2)
                                Text("Show \(min(4, remainingCount)) more…").font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: maxScrollHeight)
        }
        .frame(width: 260)
        .onAppear {
            print("[MainView] onAppear items=\(appState.allMainItems.count) visible=\(visibleCount)")
        }
        .onDisappear {
            print("[MainView] onDisappear")
        }
    }
}
