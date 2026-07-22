// SettingsView.swift
// MenuBarKitExample

import MenuBarKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var showSheet = false

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 12) {
            Text("Settings").font(.headline)
            Divider()

            Button("Open sheet") { showSheet = true }
                .mbkSheet(isPresented: $showSheet, overlayGate: overlayGate) {
                    SheetView()
                        .environment(appState)
                        .environment(overlayGate)
                }

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
        }
        .padding(16)
        .frame(width: 520)
        .onAppear    { print("[SettingsView] onAppear") }
        .onDisappear { print("[SettingsView] onDisappear") }
    }
}
