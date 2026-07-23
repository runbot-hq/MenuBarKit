// MainView.swift
// MenuBarKitExample

import SwiftUI

/// Landing view shown on first popover open. Navigates to `SettingsView`.
///
/// Exercises dynamic width AND height via a scrollable list with variable-length
/// rows and a "Show more" button. Width tracks the widest visible row, clamped
/// by PopoverController's minWidth/maxWidth. Text truncates at maxWidth.
/// Height is clamped by PopoverController's maxHeight — scroll kicks in beyond that.
struct MainView: View {
    @Environment(AppState.self) private var appState

    /// Pre-populated items with varying label lengths so width changes on each
    /// "Show more" tap. Seeded so layout is deterministic across runs.
    private let allItems: [(icon: String, label: String)] = [
        ("checkmark.circle.fill",  "Build succeeded"),
        ("xmark.circle.fill",      "Test suite failed on runner macos-15-xl"),
        ("clock.fill",             "Queued"),
        ("arrow.clockwise",        "Re-running deploy-production"),
        ("checkmark.circle.fill",  "Lint passed"),
        ("xmark.circle.fill",      "E2E tests timed out after 60 minutes on staging"),
        ("clock.fill",             "Waiting for approval"),
        ("checkmark.circle.fill",  "Release build complete — v2.4.1"),
        ("arrow.clockwise",        "Retrying flaky snapshot test"),
        ("xmark.circle.fill",      "Deploy failed: health check did not pass"),
        ("checkmark.circle.fill",  "OK"),
        ("clock.fill",             "Pending dependency: upload-artifacts"),
        ("checkmark.circle.fill",  "Code signing passed"),
        ("xmark.circle.fill",      "Notarisation rejected"),
        ("arrow.clockwise",        "Scheduled nightly run"),
        ("checkmark.circle.fill",  "Delta upload done"),
        ("clock.fill",             "In progress"),
        ("xmark.circle.fill",      "Runner disconnected mid-job — investigate logs"),
        ("checkmark.circle.fill",  "Cache warmed"),
        ("checkmark.circle.fill",  "All checks passed — ready to merge"),
    ]

    @State private var visibleCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Workflows").font(.headline)
                Spacer()
                Button("Settings →") { appState.route = .settings }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(allItems.prefix(visibleCount).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Image(systemName: item.icon)
                                .foregroundStyle(iconColor(item.icon))
                                .font(.caption)
                            Text(item.label)
                                .font(.system(size: 12))
                                .lineLimit(1)   // truncate at maxWidth, never wrap
                            Spacer(minLength: 12)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        Divider()
                    }

                    if visibleCount < allItems.count {
                        let nextBatch = min(5, allItems.count - visibleCount)
                        Button("Show \(nextBatch) more…") {
                            visibleCount += nextBatch
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                // Reports full intrinsic height to the GeometryReader —
                // without this, ScrollView collapses to its proposal.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // No hard .frame(width:) — width is content-driven.
        // fixedSize() makes the root report its intrinsic size to both
        // fittingSize (read in openPopover) and the GeometryReader (read
        // via onChange after show()). PopoverController clamps the result
        // to [minWidth, maxWidth] x maxHeight.
        .fixedSize()
        .onAppear    { print("[MainView] onAppear visibleCount=\(visibleCount)") }
        .onDisappear { print("[MainView] onDisappear") }
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
