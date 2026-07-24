// AppDelegate.swift
// MenuBarKitExample
//
// SESSION RESPAWN — hook split:
//   onWillShow       → restore route only. No isSheetPresented touch —
//                       SwiftUI resets it to false when the popover closes,
//                       so onDidShow gets a genuine false→true transition.
//   onDidShow        → restore isSheetPresented from snapshot via Task hop.
//                       Popover window exists at this point.
//   onDidClose       → saveSnapshot() from live AppState — captures
//                       isSheetPresented correctly (SwiftUI has reset it
//                       to false by the time this fires on normal close;
//                       on force-close onWillForceClose already saved it).
//   onWillForceClose → saveSnapshot() BEFORE gate cleared and BEFORE
//                       isSheetPresented resets — captures sheet=true.

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

        // Restore route only — do NOT touch isSheetPresented here.
        // SwiftUI resets isSheetPresented=false when the popover view
        // disappears on close, so onDidShow will get a genuine false→true.
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

        popoverController.onDidClose = { [weak self] in
            guard let self else { return }
            lastSession = appState.saveSnapshot()
            print("[AppDelegate] session saved: route=\(lastSession!.route) sheet=\(lastSession!.isSheetPresented)")
        }

        popoverController.onWillForceClose = { [weak self] in
            guard let self else { return }
            lastSession = appState.saveSnapshot()
            print("[AppDelegate] session force-saved: route=\(lastSession!.route) sheet=\(lastSession!.isSheetPresented)")
        }
    }

    private let appState = AppState()
    private let overlayGate = MBKOverlayGate()
    private var popoverController: MBKPopoverController!
    private var lastSession: AppState.SessionSnapshot?
}
