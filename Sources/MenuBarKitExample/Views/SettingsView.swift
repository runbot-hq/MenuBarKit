// SettingsView.swift
// MenuBarKitExample
//
// Exercises all three scenarios:
//
//   Scenario 1 — Sheet anchors + blocks outside-click dismiss
//   Scenario 2 — File picker from popover level
//   Scenario 3 — Alert from popover level
//
// Width is now driven by content (no fixed .frame(width:)) so the popover
// resizes horizontally based on whatever is visible. The "Show wide row"
// toggle reveals a wide element, forcing a horizontal resize — this
// exercises the delta-based centering fix with UI-driven width changes.

import MenuBarKit
import SwiftUI

/// Settings view that exercises the sheet-anchoring, file-picker, alert,
/// and content-driven width-change scenarios.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var showSheet = false
    @State private var showWideRow = false

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline).frame(maxWidth: .infinity, alignment: .center)
            Divider()

            // Width driver: toggle reveals a wide fixed-width label.
            // The VStack will widen to fit it, driving a horizontal resize.
            Toggle("Show wide row", isOn: $showWideRow)
            if showWideRow {
                Text("← this row is intentionally wide to drive a horizontal resize →")
                    .font(.system(size: 11, design: .monospaced))
                    .fixedSize()          // prevent wrapping — must report full intrinsic width
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Scenario 1
            Button("Open sheet") { showSheet = true }
                .mbkSheet(isPresented: $showSheet, overlayGate: overlayGate) {
                    SheetView()
                        .environment(appState)
                        .environment(overlayGate)
                }

            // Scenario 2
            Button("Pick folder (popover)") {
                mbkOpenFilePicker(target: .popover, overlayGate: overlayGate) { url in
                    appState.pickedURL = url
                }
            }
            if let path = appState.pickedURL?.path {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }

            // Scenario 3
            GroupBox("Alert from popover") {
                Button("Show alert") { appState.showAlert = true }
                Text("Alert should appear. Popover stays alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .mbkAlert(
                "Simulated Error",
                isPresented: $appState.showAlert,
                overlayGate: overlayGate
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This is a test error alert shown from the popover view.")
            }

            Divider()
            Button("← Back") { appState.route = .main }
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .fixedSize()   // let VStack report its intrinsic size to fittingSize
        .onAppear    { print("[SettingsView] onAppear") }
        .onDisappear { print("[SettingsView] onDisappear") }
    }
}
