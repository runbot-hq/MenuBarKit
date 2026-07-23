// MainView.swift
// MenuBarKitExample
//
// Demonstrates dynamic height growth via a "Show more" button AND
// dynamic width cycling via a "←→" button in the header.
//
// Width cycle: 200 → 260 → 320 → 420 → (wrap) 200
// This exercises the preferredContentSize KVO path in PopoverController
// for both axes — the panel reflows width live without re-anchoring.
//
// Height growth: "Show more" reveals items 4 at a time.
// preferredContentSize KVO in PopoverController picks up every size
// change and resizes + recenters the popover automatically.

import AppKit
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState
    @State private var visibleCount: Int = 4
    @State private var widthIndex: Int = 1  // default = 260 (index 1)

    private static let widthSteps: [CGFloat] = [200, 260, 320, 420]

    private var currentWidth: CGFloat {
        Self.widthSteps[widthIndex]
    }

    private var nextWidth: CGFloat {
        Self.widthSteps[(widthIndex + 1) % Self.widthSteps.count]
    }

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
                // Width-cycle button — steps through widthSteps on each tap.
                Button {
                    let next = (widthIndex + 1) % Self.widthSteps.count
                    print("[MainView] width cycle: \(currentWidth) → \(Self.widthSteps[next])")
                    widthIndex = next
                } label: {
                    Label("\(Int(nextWidth))pt", systemImage: "arrow.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cycle panel width (tests dynamic resize)")

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
        .frame(width: currentWidth)  // driven by widthIndex
        .animation(.easeInOut(duration: 0.18), value: currentWidth)
        .onAppear {
            print("[MainView] onAppear items=\(appState.allMainItems.count) visible=\(visibleCount) width=\(currentWidth)")
        }
        .onDisappear {
            print("[MainView] onDisappear")
        }
    }
}
