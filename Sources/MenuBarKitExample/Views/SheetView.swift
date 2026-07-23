// SheetView.swift
// MenuBarKitExample
//
// Scenario 2 continued — file picker from inside the sheet.
// Scenario 3 — alert from inside the sheet.

import MenuBarKit
import SwiftUI

struct SheetView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKOverlayGate.self) private var overlayGate
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 16) {
            Text("Sheet").font(.headline)

            GroupBox("Alert from sheet") {
                Button("Show error alert") { appState.showSheetAlert = true }
                Text("Alert should appear. Sheet + popover stay alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .alert("Simulated Error", isPresented: $appState.showSheetAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This is a test error alert shown from inside a sheet.")
            }

            GroupBox("File picker from sheet") {
                Button("Pick folder (sheet)") {
                    mbkOpenFilePicker(overlayGate: overlayGate) { url in
                        appState.sheetPickedURL = url
                    }
                }
                if let path = appState.sheetPickedURL?.path {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            Button("Dismiss") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 280)
    }
}
