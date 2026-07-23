// MainView.swift
// MenuBarKitExample
//
// Exercises dynamic width AND height via a scrollable list with variable-length
// rows and a "Show 5 more…" button.
//
// Width is content-driven (no fixed .frame(width:)). The VStack reports its
// intrinsic width via .fixedSize() and PopoverController clamps the result to
// [minWidth, maxWidth]. Rows use .lineLimit(1) so text exceeding maxWidth
// truncates with an ellipsis rather than wrapping.
//
// Height grows with each "Show more" press up to PopoverController's maxHeight,
// after which the ScrollView scrolls vertically.

import AppKit
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState

    // Deterministic varied-length items. Mix of short, medium and long labels
    // so successive "Show more" presses produce visible width changes.
    private let allItems: [(icon: String, label: String)] = [
        ("checkmark.circle.fill", "Build succeeded"),
        ("xmark.circle.fill",     "Test suite failed on runner macos-15-xl"),
        ("clock.fill",            "Queued"),
        ("arrow.clockwise",       "Re-running deploy-production"),
        ("checkmark.circle.fill", "Lint passed"),
        ("xmark.circle.fill",     "E2E tests timed out after 60 minutes on staging"),
        ("clock.fill",            "Waiting for approval"),
        ("checkmark.circle.fill", "Release build complete — v2.4.1"),
        ("arrow.clockwise",       "Retrying flaky snapshot test"),
        ("xmark.circle.fill",     "Deploy failed: health check did not pass"),
        ("checkmark.circle.fill", "OK"),
        ("clock.fill",            "Pending dependency: upload-artifacts"),
        ("checkmark.circle.fill", "Code signing passed"),
        ("xmark.circle.fill",     "Notarisation rejected"),
        ("arrow.clockwise",       "Scheduled nightly run"),
        ("checkmark.circle.fill", "Delta upload done"),
        ("clock.fill",            "In progress"),
        ("xmark.circle.fill",     "Runner disconnected mid-job — investigate logs"),
        ("checkmark.circle.fill", "Cache warmed"),
        ("checkmark.circle.fill", "All checks passed — ready to merge"),
    ]

    @State private var visibleCount = 5

    private var visibleItems: [(icon: String, label: String)] {
        Array(allItems.prefix(visibleCount))
    }

    private var remainingCount: Int {
        allItems.count - visibleCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("MBK Example").font(.headline)
                Spacer(minLength: 16)
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

            // Scrollable list. The inner VStack uses .fixedSize(horizontal: false, vertical: true)
            // so it reports its full intrinsic height to the GeometryReader inside ScrollView,
            // while width is driven by the outer .fixedSize() on the root VStack.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleItems.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Image(systemName: item.icon)
                                .foregroundStyle(iconColor(item.icon))
                                .font(.caption)
                            Text(item.label)
                                .font(.system(size: 12))
                                .lineLimit(1)           // truncate at maxWidth, never wrap
                                .truncationMode(.tail)
                            Spacer(minLength: 12)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        Divider().padding(.leading, 12)
                    }

                    // Show more button — only when items remain.
                    if remainingCount > 0 {
                        let batch = min(5, remainingCount)
                        Button {
                            print("[MainView] show more tapped — revealing \(batch) items")
                            visibleCount += batch
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.down").font(.caption2)
                                Text("Show \(batch) more…").font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .scrollContentBackground(.hidden) // ← nuke grey ScrollView bg
            .background(.clear)               // ← belt-and-braces
        }
        .background(.clear) // ← nuke root VStack default opaque bg
        // No fixed width — content-driven. .fixedSize() makes the root VStack
        // report its intrinsic size so preferredContentSize KVO fires correctly.
        // PopoverController clamps the result to [minWidth, maxWidth] x maxHeight.
        .fixedSize()
        .onAppear {
            print("[MainView] onAppear visibleCount=\(visibleCount)")
        }
        .onDisappear {
            print("[MainView] onDisappear")
        }
    }

    private func iconColor(_ systemName: String) -> Color {
        switch systemName {
        case "checkmark.circle.fill": return .green
        case "xmark.circle.fill":     return .red
        case "clock.fill":            return .orange
        default:                      return .blue
        }
    }
}
