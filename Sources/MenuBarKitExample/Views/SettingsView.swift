// SettingsView.swift
// MenuBarKitExample
//
// Exercises all scenarios:
//   1 — Sheet anchors + blocks outside-click dismiss
//   2 — File picker from popover level
//   3 — Alert from popover level
//   4 — Async scroll list (mimic run-bot SettingsView runner rows)
//
// Width is fixed (320); height uncapped so GeometryReader fires onChange.

import MenuBarKit
import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var showSheet = false

    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.80
    }

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Settings").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Async-loaded runner list — uncapped
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if appState.settingsItems.isEmpty {
                        Text("Loading runners…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(appState.settingsItems, id: \.self) { item in
                            HStack {
                                Image(systemName: "server.rack").foregroundStyle(.blue)
                                Text(item).font(.caption)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Controls
            VStack(alignment: .leading, spacing: 8) {
                Button("Open sheet") { showSheet = true }
                    .mbkSheet(isPresented: $showSheet, overlayGate: overlayGate) {
                        SheetView()
                    }

                Button("Pick folder (popover)") {
                    mbkOpenFilePicker(target: .popover, overlayGate: overlayGate) { url in
                        appState.pickedURL = url
                    }
                }
                if let url = appState.pickedURL {
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }

                GroupBox("Alert from popover") {
                    Button("Show alert") { appState.showAlert = true }
                    Text("Alert should appear. Popover stays alive.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .mbkAlert("Test Alert", isPresented: $appState.showAlert, overlayGate: overlayGate) {
                    Button("OK", role: .cancel) { appState.showAlert = false }
                } message: {
                    Text("Popover must stay open.")
                }

                Button("← Back") { appState.route = .main }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
        .frame(maxHeight: maxHeight)  // cap the whole VStack, not the ScrollView
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            print("[SettingsView] onAppear")
            guard appState.settingsItems.isEmpty else { return }  // cached — skip reload
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                appState.settingsItems = [
                    "runner-mac-01 (idle)",
                    "runner-mac-02 (busy)",
                    "runner-linux-01 (idle)",
                    "runner-linux-02 (idle)",
                    "runner-linux-03 (busy)",
                ]
            }
        }
    }
}
