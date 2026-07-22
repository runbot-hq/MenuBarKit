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
// WIDTH (TEST BRANCH test/intrinsic-content-size-kvo): the fixed
// `.frame(width: 640)` from the working branch has been REMOVED here on
// purpose. This view's width is now determined entirely by its own
// content — specifically the long, unwrapped diagnostic string below —
// via NSHostingView.intrinsicContentSize. If content-driven sizing is
// truly working, this view should end up noticeably wider than
// MainView's ~260pt without anyone declaring a number anywhere.
import MenuBarKit
import SwiftUI

/// Settings view that exercises the sheet-anchoring, file-picker, and alert scenarios.
struct SettingsView: View {
    /// App state injected from the environment.
    @Environment(AppState.self) private var appState
    /// Overlay gate injected from the environment.
    // TODO(#2): remove overlayGate once MBK resolves gate via @Environment internally.
    @Environment(MBKOverlayGate.self) private var overlayGate
    /// Controls whether the anchored sheet is presented.
    @State private var showSheet = false

    /// The root view hierarchy for the settings screen.
    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 12) {
            Text("Settings").font(.headline)
            Divider()

            // Intentionally wide, unwrapped content so this view's ideal
            // width is genuinely larger than MainView's, with no manual
            // .frame(width:) anywhere forcing it — the point of this test
            // branch. lineLimit(1) + fixedSize() forces SwiftUI to size
            // this Text at its full single-line width rather than wrapping
            // it to whatever width a parent might otherwise propose.
            Text("Diagnostic path: /Users/eon/Library/Application Support/MenuBarKitExample/config/settings.snapshot.json")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .fixedSize()

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
        .fixedSize()
        .onAppear    { print("[SettingsView] onAppear") }
        .onDisappear { print("[SettingsView] onDisappear") }
    }
}
