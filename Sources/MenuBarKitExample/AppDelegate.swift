// AppDelegate.swift
// MenuBarKitExample
//
// Thin consumer of MenuBarKit. Owns only:
//   - AppState (app-specific data)
//   - MBKOverlayGate (passed into MenuBarKit)
//   - MBKPopoverController (configured with root view + gate)
//
// Nothing about popover lifecycle, monitors, or window management lives here.
//
// SESSION RESPAWN — hook split:
//   onWillShow  → restore route only. Fires before popover.show(). Safe because
//                 route has no overlay gate side effects.
//   onDidShow   → intentionally does NOT restore isSheetPresented.
//                 SwiftUI cannot re-anchor a sheet window during respawn:
//                 the hosting view is freshly rebuilt, onChange(true) fires
//                 before a window exists, the anchor observer waits forever,
//                 the gate is never armed, and every outside click closes the
//                 popover immediately. Route is sufficient — user re-opens sheet.
//   onDidClose       → snapshot on normal close (sheet always saved as false).
//   onWillForceClose → snapshot when sheet is open (sheet saved as false
//                      to prevent restore loop).

import AppKit
import MenuBarKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        popoverController = MBKPopoverController(
            rootView: RootView()
                .environment(appState)
                .environment(overlayGate),
            overlayGate: overlayGate,
            symbolName: "flask.fill",
            minWidth: 200,
            maxWidth: 480,
            maxHeight: 600
        )
        popoverController.setup()

        // Restore route before show() — no gate side effects.
        popoverController.onWillShow = { [weak self] in
            guard let self, let snap = lastSession else { return }
            appState.route = snap.route
            print("[AppDelegate] route restored: \(snap.route)")
        }

        // isSheetPresented is intentionally NOT restored here.
        // See file header for explanation.
        popoverController.onDidShow = { _ in }

        // Normal close — snapshot route only; sheet always false.
        popoverController.onDidClose = { [weak self] in
            guard let self else { return }
            lastSession = AppState.SessionSnapshot(route: appState.route, isSheetPresented: false)
            print("[AppDelegate] session saved: route=\(lastSession!.route) sheet=false")
        }

        // Force-close (sheet open + outside click) — snapshot route, sheet=false
        // so restore never tries to re-present a sheet that can’t be anchored.
        popoverController.onWillForceClose = { [weak self] in
            guard let self else { return }
            lastSession = AppState.SessionSnapshot(route: appState.route, isSheetPresented: false)
            print("[AppDelegate] session force-saved: route=\(lastSession!.route) sheet=false")
        }
    }

    // MARK: - Private

    private let appState = AppState()
    private let overlayGate = MBKOverlayGate()
    private var popoverController: MBKPopoverController!
    private var lastSession: AppState.SessionSnapshot?
}
