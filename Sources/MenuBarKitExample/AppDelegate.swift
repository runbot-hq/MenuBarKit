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
//   onDidShow   → restore isSheetPresented only. Fires via Task { @MainActor }
//                 after popover.show(), so the popover window exists and
//                 AnchoredSheet can anchor correctly without phantom gate arming.
//   onDidClose       → snapshot on normal close (no overlay active).
//   onWillForceClose → snapshot when sheet is open at outside-click time,
//                      BEFORE gate is cleared and BEFORE isSheetPresented resets.

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

        // Restore isSheetPresented after show() — needs popover window to exist
        // so AnchoredSheet can anchor correctly and arm the gate without leaving
        // it permanently true on a phantom window.
        popoverController.onDidShow = { [weak self] in
            guard let self, let snap = lastSession else { return }
            appState.isSheetPresented = snap.isSheetPresented
            print("[AppDelegate] isSheetPresented restored: \(snap.isSheetPresented)")
        }

        // Normal close — snapshot after close.
        popoverController.onDidClose = { [weak self] in
            guard let self else { return }
            lastSession = appState.saveSnapshot()
            print("[AppDelegate] session saved: route=\(lastSession!.route) sheet=\(lastSession!.isSheetPresented)")
        }

        // Force-close (sheet open + outside click) — snapshot BEFORE gate is
        // cleared and BEFORE isSheetPresented resets.
        popoverController.onWillForceClose = { [weak self] in
            guard let self else { return }
            lastSession = appState.saveSnapshot()
            print("[AppDelegate] session force-saved: route=\(lastSession!.route) sheet=\(lastSession!.isSheetPresented)")
        }
    }

    // MARK: - Private

    private let appState = AppState()
    private let overlayGate = MBKOverlayGate()
    private var popoverController: MBKPopoverController!
    private var lastSession: AppState.SessionSnapshot?
}
