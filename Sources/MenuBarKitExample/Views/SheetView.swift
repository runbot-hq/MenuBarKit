// SheetView.swift
// MenuBarKitExample

import MenuBarKit
import SwiftUI

struct SheetView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKOverlayGate.self) private var overlayGate

    var body: some View {
        let _ = print("[SheetView] body evaluated — showSheetAlert=\(appState.showSheetAlert) gate=\(overlayGate.hasActiveOverlay)")
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            Text("Sheet").font(.headline).frame(maxWidth: .infinity, alignment: .center)
            Divider()

            // Scenario: file picker launched from inside a sheet
            GroupBox("Pick folder from sheet") {
                Button("Pick folder") {
                    print("[SheetView] Pick folder tapped — gate=\(overlayGate.hasActiveOverlay) isSheetPresented=\(appState.isSheetPresented)")
                    mbkOpenFilePicker(overlayGate: overlayGate) { url in
                        print("[SheetView] mbkOpenFilePicker completion — url=\(String(describing: url)) gate=\(overlayGate.hasActiveOverlay) isSheetPresented=\(appState.isSheetPresented)")
                        appState.sheetPickedURL = url
                    }
                }
                if let path = appState.sheetPickedURL?.path {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                }
                Text("Picker opens. Sheet + popover stay alive after dismiss.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            GroupBox("Alert from sheet") {
                Button("Show error alert") {
                    print("[SheetView] Show error alert tapped")
                    appState.showSheetAlert = true
                }
                Text("Alert should appear. Sheet + popover stay alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .alert("Simulated Error", isPresented: $appState.showSheetAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This is a test error message.")
            }

            Divider()
            Button("Close") {
                print("[SheetView] Close tapped — setting isSheetPresented=false")
                appState.isSheetPresented = false
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .fixedSize()
        .onAppear    { print("[SheetView] onAppear  gate=\(overlayGate.hasActiveOverlay) isSheetPresented=\(appState.isSheetPresented)") }
        .onDisappear { print("[SheetView] onDisappear gate=\(overlayGate.hasActiveOverlay) isSheetPresented=\(appState.isSheetPresented)") }
    }
}
