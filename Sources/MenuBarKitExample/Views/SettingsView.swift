// SettingsView.swift
// MenuBarKitExample
//
// Exercises all three scenarios:
//
//   Scenario 1 — Sheet anchors + blocks outside-click dismiss
//   Scenario 2 — File picker from popover level
//   Scenario 3 — Alert from popover level
//
// Width is driven by content (no fixed .frame(width:)) so the popover
// resizes horizontally based on whatever is visible.
//
// isSheetPresented is owned by AppState (not local @State) so it survives
// popover close/reopen and can be restored via SessionSnapshot.

import MenuBarKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var showWideRow = false

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline).frame(maxWidth: .infinity, alignment: .center)
            Divider()

            Toggle("Show wide row", isOn: $showWideRow)
            if showWideRow {
                Text("← this row is intentionally wide to drive a horizontal resize →")
                    .font(.system(size: 11, design: .monospaced))
                    .fixedSize()
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Scenario 1 — overlayGate: removed, read from environment
            Button("Open sheet") { appState.isSheetPresented = true }
                .mbkSheet(isPresented: $appState.isSheetPresented) {
                    SheetView()
                        .environment(appState)
                        .environment(overlayGate)
                }

            // Scenario 2 — overlayGate obtained from environment, passed explicitly
            // (mbkOpenFilePicker is a free function, not a ViewModifier)
            Button("Pick folder") {
                mbkOpenFilePicker(overlayGate: overlayGate) { url in
                    appState.pickedURL = url
                }
            }
            if let path = appState.pickedURL?.path {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }

            // Scenario 3 — overlayGate: removed, read from environment
            GroupBox("Alert from popover") {
                Button("Show alert") { appState.showAlert = true }
                Text("Alert should appear. Popover stays alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .mbkAlert(
                "Simulated Error",
                isPresented: $appState.showAlert
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
        .fixedSize()
        .onAppear    { print("[SettingsView] onAppear") }
        .onDisappear { print("[SettingsView] onDisappear") }
    }
}
