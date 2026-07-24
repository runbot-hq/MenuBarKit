// SettingsView.swift
// MenuBarKitExample

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

            // Scenario 1
            Button("Open sheet") { appState.isSheetPresented = true }
                .mbkSheet(isPresented: $appState.isSheetPresented, overlayGate: overlayGate) {
                    SheetView()
                        .environment(appState)
                        .environment(overlayGate)
                }

            // Scenario 2
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

            // Scenario 3
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
