// AppDelegate.swift
// MenuBarKitExample
//
// SESSION RESPAWN — hook split:
//   onWillShow       → restore route + reset isSheetPresented=false.
//                       Fires before popover.show() so the view renders clean.
//   onDidShow        → restore isSheetPresented from snapshot.
//                       Fires after show() — produces a genuine false→true
//                       transition that SwiftUI presents the sheet for.
//   onDidClose       → save snapshot with sheet=false (normal close).
//   onWillForceClose → save snapshot from live AppState (sheet genuinely open).

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
            // Reset to false before render so SwiftUI doesn't fire a
            // spurious onChange(true) from stale state. onDidShow sets
            // the real value after the popover window exists.
            appState.isSheetPresented = false
            print("[AppDelegate] route restored: \(snap.route), isSheetPresented reset to false")
        }

        popoverController.onDidShow = { [weak self] in
            guard let self, let snap = lastSession else { return }
            appState.isSheetPresented = snap.isSheetPresented
            print("[AppDelegate] isSheetPresented restored: \(snap.isSheetPresented)")
        }

        // Normal close — sheet never open here.
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
