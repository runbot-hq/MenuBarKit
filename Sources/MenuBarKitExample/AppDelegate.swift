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
// popoverController is exposed via the environment so RootView can call
// setContentSize(_:) explicitly on route changes — see RootView.swift.
// MBKPopoverController never measures SwiftUI content itself; the example
// app is responsible for declaring its own sizes (Route.contentSize).

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
                .environment(overlayGate)
                .environment(SizingBridge(controller: { [weak self] in self?.popoverController })),
            overlayGate: overlayGate,
            symbolName: "flask.fill",
            contentSize: appState.route.contentSize
        )
        popoverController.setup()
    }

    // MARK: - Private

    /// App-specific observable state passed into views via SwiftUI environment.
    private let appState = AppState()
    /// Shared overlay gate — MenuBarKit reads and writes this; the example never touches it directly.
    private let overlayGate = MBKOverlayGate()
    /// The MenuBarKit controller that owns NSPopover, NSStatusItem, and all observers.
    private var popoverController: MBKPopoverController!
}

/// Thin @Environment-injectable wrapper giving RootView a way to call
/// `MBKPopoverController.setContentSize(_:)` without RootView needing to
/// know about NSApplicationDelegate. Deliberately just a closure holder —
/// no logic, no measurement, no state of its own.
@MainActor
final class SizingBridge {
    private let controller: () -> MBKPopoverController?

    init(controller: @escaping () -> MBKPopoverController?) {
        self.controller = controller
    }

    func setContentSize(_ size: CGSize) {
        controller()?.setContentSize(NSSize(width: size.width, height: size.height))
    }
}
