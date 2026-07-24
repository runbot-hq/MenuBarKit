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
            guard let self else { print("[AppDelegate] onWillShow — self nil"); return }
            print("[AppDelegate] onWillShow — lastSession=\(String(describing: self.lastSession.map { "route=\($0.route) sheet=\($0.isSheetPresented)" }))")
            guard let snap = lastSession else {
                print("[AppDelegate] onWillShow — no session, skipping")
                return
            }
            print("[AppDelegate] onWillShow — restoring route=\(snap.route)")
            appState.route = snap.route
            print("[AppDelegate] onWillShow — route restored")
        }

        popoverController.onDidShow = { [weak self] in
            guard let self else { print("[AppDelegate] onDidShow — self nil"); return }
            print("[AppDelegate] onDidShow — lastSession=\(String(describing: self.lastSession.map { "route=\($0.route) sheet=\($0.isSheetPresented)" }))")
            guard let snap = lastSession else {
                print("[AppDelegate] onDidShow — no session, skipping")
                return
            }
            let sheetValue = snap.isSheetPresented
            print("[AppDelegate] onDidShow — will restore isSheetPresented=\(sheetValue)")
            // Clear BEFORE restoring so a second onDidShow (e.g. picker respawn)
            // does not re-fire sheet=true on a session that already ran.
            lastSession = AppState.SessionSnapshot(route: snap.route, isSheetPresented: false)
            print("[AppDelegate] onDidShow — lastSession.isSheetPresented cleared to false")
            appState.isSheetPresented = sheetValue
            print("[AppDelegate] onDidShow — isSheetPresented restored: \(sheetValue)")
        }

        popoverController.onDidClose = { [weak self] in
            guard let self else { print("[AppDelegate] onDidClose — self nil"); return }
            let snap = appState.saveSnapshot()
            print("[AppDelegate] onDidClose — saving route=\(snap.route) sheet=\(snap.isSheetPresented)")
            lastSession = snap
            print("[AppDelegate] session saved: route=\(snap.route) sheet=\(snap.isSheetPresented)")
        }

        popoverController.onWillForceClose = { [weak self] in
            guard let self else { print("[AppDelegate] onWillForceClose — self nil"); return }
            let snap = appState.saveSnapshot()
            print("[AppDelegate] onWillForceClose — saving route=\(snap.route) sheet=\(snap.isSheetPresented)")
            lastSession = snap
            print("[AppDelegate] session force-saved: route=\(snap.route) sheet=\(snap.isSheetPresented)")
        }

        print("[AppDelegate] setup complete")
    }

    private let appState = AppState()
    private let overlayGate = MBKOverlayGate()
    private var popoverController: MBKPopoverController!
    private var lastSession: AppState.SessionSnapshot?
}
