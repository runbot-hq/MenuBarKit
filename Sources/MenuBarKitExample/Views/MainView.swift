// MainView.swift
// MenuBarKitExample

import SwiftUI

/// Landing view shown on first popover open. Navigates to `SettingsView`.
///
/// Exercises dynamic height via a scrollable list with a "Show more" button.
/// Uses a plain VStack (not LazyVStack) inside the ScrollView so that
/// fittingSize returns the correct intrinsic height before the view is
/// attached to a window — LazyVStack and ScrollView alone cannot measure
/// their content height without window bounds.
///
/// Intentionally uses a DIFFERENT width (280) than SettingsView to
/// exercise PopoverController's dynamic-width arrow centering fix.
struct MainView: View {
    @Environment(AppState.self) private var appState

    /// All available list items. Pre-populated at init so fittingSize
    /// is correct on first open without any async data loading.
    private let allItems: [String] = (1...20).map { "Workflow run #\($0 * 100 + Int.random(in: 0...99))" }

    /// Number of items currently visible in the list.
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

            // Scrollable list — ScrollView provides scroll when popover is clamped
            // to maxHeight. Plain VStack (not Lazy) gives correct intrinsic height
            // to fittingSize pre-window.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(allItems.prefix(visibleCount).enumerated()), id: \.offset) { _, item in
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text(item)
                                .font(.system(size: 12))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        Divider()
                    }

                    // Show more button — only when items remain hidden
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
                // fixedSize on the inner VStack makes it report its full
                // intrinsic height rather than filling the ScrollView's proposal.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 280)
        // fixedSize on the outer VStack so the root reports intrinsic height
        // to fittingSize (read in openPopover before show()) and to the
        // GeometryReader in PopoverController (read after show() via onChange).
        // PopoverController.maxHeight clamps the result — no .frame(maxHeight:) here.
        .fixedSize()
        .onAppear    { print("[MainView] onAppear") }
        .onDisappear { print("[MainView] onDisappear") }
    }
}
