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
// SESSION RESPAWN:
//   onDidClose snapshots route + isSheetPresented into lastSession.
//   onWillShow restores lastSession before show() so the popover
//   reopens into the exact hierarchy it had when it closed.

import AppKit
import MenuBarKit
import SwiftUI

/// Application delegate. Creates the shared `AppState` and `MBKOverlayGate`,
/// then hands them to `MBKPopoverController` for the full menu-bar lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Wires the popover controller on launch.
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

        popoverController.onDidClose = { [weak self] in
            guard let self else { return }
            lastSession = appState.saveSnapshot()
            print("[AppDelegate] session saved: route=\(lastSession!.route) sheet=\(lastSession!.isSheetPresented)")
        }
        popoverController.onWillShow = { [weak self] in
            guard let self, let snap = lastSession else { return }
            appState.restoreSnapshot(snap)
            print("[AppDelegate] session restored: route=\(snap.route) sheet=\(snap.isSheetPresented)")
        }
    }

    // MARK: - Private

    /// App-specific observable state passed into views via SwiftUI environment.
    private let appState = AppState()
    /// Shared overlay gate — MenuBarKit reads and writes this; the example never touches it directly.
    private let overlayGate = MBKOverlayGate()
    /// The MenuBarKit controller that owns NSPopover, NSStatusItem, and all observers.
    private var popoverController: MBKPopoverController!
    /// Last saved session snapshot. nil on first open (no state to restore).
    private var lastSession: AppState.SessionSnapshot?
}
