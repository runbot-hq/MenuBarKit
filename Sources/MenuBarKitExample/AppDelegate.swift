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
//   onWillShow       → restore route only. Fires before popover.show().
//   onDidShow        → restore isSheetPresented. Fires after popover.show()
//                       so the popover window exists when AnchoredSheet
//                       registers its anchor observer.
//   onDidClose       → save snapshot with sheet=false. Normal close means
//                       no sheet was visible — if it were, forceClose fires
//                       instead. Saving appState.isSheetPresented would
//                       capture a stale true and cause a respawn loop.
//   onWillForceClose → save snapshot from live AppState — the ONLY case
//                       where sheet=true is valid to persist.

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

        popoverController.onWillShow = { [weak self] in
            guard let self, let snap = lastSession else { return }
            appState.route = snap.route
            print("[AppDelegate] route restored: \(snap.route)")
        }

        popoverController.onDidShow = { [weak self] in
            guard let self, let snap = lastSession else { return }
            appState.isSheetPresented = snap.isSheetPresented
            print("[AppDelegate] isSheetPresented restored: \(snap.isSheetPresented)")
        }

        // Normal close — sheet is never open here (forceClose handles that).
        // Always save sheet=false to avoid stale-true respawn loop.
        popoverController.onDidClose = { [weak self] in
            guard let self else { return }
            let snap = AppState.SessionSnapshot(route: appState.route, isSheetPresented: false)
            lastSession = snap
            print("[AppDelegate] session saved: route=\(snap.route) sheet=false")
        }

        // Force-close — sheet IS open. Save live state before teardown.
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
