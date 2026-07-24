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
            guard let self else { print("[AppDelegate] onWillShow -- self nil"); return }
            print("[AppDelegate] onWillShow -- lastSession=\(String(describing: self.lastSession.map { "route=\($0.route) sheet=\($0.isSheetPresented)" }))")
            guard let snap = lastSession else {
                print("[AppDelegate] onWillShow -- no session, skipping")
                return
            }
            print("[AppDelegate] onWillShow -- restoring route=\(snap.route)")
            appState.route = snap.route
            print("[AppDelegate] onWillShow -- route restored")
        }

        popoverController.onDidShow = { [weak self] in
            guard let self else { print("[AppDelegate] onDidShow -- self nil"); return }
            print("[AppDelegate] onDidShow -- lastSession=\(String(describing: self.lastSession.map { "route=\($0.route) sheet=\($0.isSheetPresented)" }))")
            guard let snap = lastSession else {
                print("[AppDelegate] onDidShow -- no session, skipping")
                return
            }
            let sheetValue = snap.isSheetPresented
            print("[AppDelegate] onDidShow -- will restore isSheetPresented=\(sheetValue)")
            // Clear BEFORE restoring so a second onDidShow does not re-fire.
            lastSession = AppState.SessionSnapshot(route: snap.route, isSheetPresented: false)
            print("[AppDelegate] onDidShow -- lastSession.isSheetPresented cleared to false")
            appState.isSheetPresented = sheetValue
            print("[AppDelegate] onDidShow -- isSheetPresented restored: \(sheetValue)")
        }

        popoverController.onDidClose = { [weak self] in
            guard let self else { print("[AppDelegate] onDidClose -- self nil"); return }
            // If onWillForceClose already saved the snapshot (with sheet=true), don't
            // overwrite it here — by this point isSheetPresented is already false and
            // we would lose the intent to reopen the sheet on next show.
            if didForceClose {
                print("[AppDelegate] onDidClose -- skipping save, force-close snapshot is authoritative")
                didForceClose = false
                return
            }
            let snap = appState.saveSnapshot()
            print("[AppDelegate] onDidClose -- saving route=\(snap.route) sheet=\(snap.isSheetPresented)")
            lastSession = snap
            print("[AppDelegate] session saved: route=\(snap.route) sheet=\(snap.isSheetPresented)")
        }

        popoverController.onWillForceClose = { [weak self] in
            guard let self else { print("[AppDelegate] onWillForceClose -- self nil"); return }
            // Snapshot FIRST while isSheetPresented is still true.
            let snap = appState.saveSnapshot()
            print("[AppDelegate] onWillForceClose -- saving route=\(snap.route) sheet=\(snap.isSheetPresented)")
            lastSession = snap
            didForceClose = true
            print("[AppDelegate] session force-saved: route=\(snap.route) sheet=\(snap.isSheetPresented)")
            // Reset live state so SwiftUI dismisses the sheet before the window is torn
            // down, preventing a duplicate presentation on the next open.
            print("[AppDelegate] onWillForceClose -- resetting isSheetPresented to false")
            appState.isSheetPresented = false
        }

        print("[AppDelegate] setup complete")
    }

    private let appState = AppState()
    private let overlayGate = MBKOverlayGate()
    private var popoverController: MBKPopoverController!
    private var lastSession: AppState.SessionSnapshot?
    private var didForceClose = false
}
