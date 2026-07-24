// AppDelegate.swift
// MenuBarKitExample

import AppKit
import MenuBarKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[AppDelegate] applicationDidFinishLaunching")
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
        print("[AppDelegate] popoverController created")
        popoverController.setup()

        popoverController.onWillShow = { [weak self] in
            guard let self, let snap = lastSession else { return }
            print("[AppDelegate] onWillShow -- restoring route=\(snap.route)")
            appState.route = snap.route
        }

        popoverController.onDidShow = { [weak self] in
            guard let self, let snap = lastSession else { return }
            print("[AppDelegate] onDidShow -- restoring isSheetPresented=\(snap.isSheetPresented)")
            // Clear before restoring so a second onDidShow (e.g. file picker respawn)
            // does not re-fire sheet=true on a session that already ran.
            lastSession = AppState.SessionSnapshot(route: snap.route, isSheetPresented: false)
            appState.isSheetPresented = snap.isSheetPresented
        }

        popoverController.onWillClose = { [weak self] in
            guard let self else { return }
            // Fires before any teardown in both normal and force-close paths,
            // so host state is always intact when this snapshot is taken.
            lastSession = appState.saveSnapshot()
            print("[AppDelegate] onWillClose -- session saved: route=\(lastSession!.route) sheet=\(lastSession!.isSheetPresented)")
        }

        print("[AppDelegate] setup complete")
    }

    private let appState = AppState()
    private let overlayGate = MBKOverlayGate()
    private var popoverController: MBKPopoverController!
    private var lastSession: AppState.SessionSnapshot?
}
