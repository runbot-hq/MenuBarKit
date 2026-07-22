// SettingsView.swift
// MenuBarKitExample
//
// Exercises all three scenarios:
//
//   Scenario 1 — Sheet anchors + blocks outside-click dismiss:
//     "Open sheet" presents via .mbkSheet(), which wires the SwiftUI sheet
//     window as a child of the popover window and gates dismiss.
//
//   Scenario 2 — File picker from popover level:
//     "Pick folder (popover)" calls mbkOpenFilePicker(target: .popover).
//
//   Scenario 3 — Alert from popover level:
//     "Show alert" sets AppState.showAlert = true.
//     .mbkAlert wraps .alert() and manages the overlay gate automatically,
//     preventing the outside-click monitor and workspace observer from
//     closing the popover while the alert is on screen.
//
// Intentionally uses a fixed width (480) VERY DIFFERENT from MainView's (260)
// to exercise PopoverController's dynamic-width arrow centering fix. The gap
// was widened from an earlier 320 specifically to make any residual
// arrow/box centering bug big and obvious at a glance instead of a subtle
// ~30pt drift that's easy to miss in a screenshot. MUST be a fixed
// .frame(width:) — NOT idealWidth + maxWidth: .infinity. The latter makes
// the view stretch to fill whatever width the popover already has instead
// of reporting its own intrinsic width via fittingSize, which is what
// caused contentSize to stay frozen at the previous route's width.

import MenuBarKit
import SwiftUI

/// Settings view that exercises the sheet-anchoring, file-picker, and alert scenarios.
struct SettingsView: View {
    /// App state injected from the environment.
    @Environment(AppState.self) private var appState
    /// Overlay gate injected from the environment.
    // TODO(#2): remove overlayGate once MBK modifiers resolve it from @Environment internally.
    @Environment(MBKOverlayGate.self) private var overlayGate
    /// Controls whether the anchored sheet is presented.
    @State private var showSheet = false

    /// The root view hierarchy for the settings screen.
    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 12) {
            Text("Settings").font(.headline)
            Divider()

            // Scenario 1
            // TODO(#2): overlayGate: parameter removed when MBK resolves gate via @Environment.
            Button("Open sheet") { showSheet = true }
                .mbkSheet(isPresented: $showSheet, overlayGate: overlayGate) {
                    SheetView()
                        .environment(appState)
                        .environment(overlayGate)
                }

            // Scenario 2
            // TODO(#2): overlayGate: parameter removed when MBK resolves gate via @Environment.
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
            // TODO(#2): overlayGate: parameter removed when MBK resolves gate via @Environment.
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
        .frame(width: 480)
        .onAppear    { print("[SettingsView] onAppear") }
        .onDisappear { print("[SettingsView] onDisappear") }
    }
}
