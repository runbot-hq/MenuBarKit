// AppDelegate.swift
// MenuBarKitExample

import AppKit
import MenuBarKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire sizeRelay into appState so route willSet can freeze the window.
        appState.sizeRelay = sizeRelay

        popoverController = MBKPopoverController(
            rootView: RootView()
                .environment(appState)
                .environment(overlayGate)
                .environment(sizeRelay),
            overlayGate: overlayGate,
            sizeRelay: sizeRelay,
            symbolName: "flask.fill"
        )
        popoverController.setup()
    }

    private let appState    = AppState()
    private let overlayGate = MBKOverlayGate()
    private let sizeRelay   = MBKSizeRelay()
    private var popoverController: MBKPopoverController!
}
