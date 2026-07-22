// AppDelegate.swift
// MenuBarKitExample

import AppKit
import MenuBarKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MBKPopoverController(
            rootView: RootView(popoverController: popoverController)
                .environment(appState)
                .environment(overlayGate),
            overlayGate: overlayGate,
            symbolName: "flask.fill"
        )
        popoverController = controller
        popoverController.setup()
    }

    private let appState    = AppState()
    private let overlayGate = MBKOverlayGate()
    private var popoverController: MBKPopoverController!
}
