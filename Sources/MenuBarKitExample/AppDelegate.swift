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
// popoverController is exposed via the environment (through SizingBridge)
// so RootView can call setContentSize(_:) explicitly on route changes —
// see RootView.swift. MBKPopoverController never measures SwiftUI content
// itself; the example app is responsible for declaring its own sizes
// (Route.contentSize).

import AppKit
import MenuBarKit
import Observation
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
                .environment(sizingBridge),
            overlayGate: overlayGate,
            symbolName: "flask.fill",
            contentSize: appState.route.contentSize
        )
        popoverController.setup()
        sizingBridge.attach(popoverController)
    }

    // MARK: - Private

    /// App-specific observable state passed into views via SwiftUI environment.
    private let appState = AppState()
    /// Shared overlay gate — MenuBarKit reads and writes this; the example never touches it directly.
    private let overlayGate = MBKOverlayGate()
    /// The MenuBarKit controller that owns NSPopover, NSStatusItem, and all observers.
    private var popoverController: MBKPopoverController!
    /// Bridges RootView's route changes to explicit setContentSize(_:) calls.
    private let sizingBridge = SizingBridge()
}

/// Environment-injectable bridge giving RootView a way to call
/// `MBKPopoverController.setContentSize(_:)` without RootView needing to
/// know about NSApplicationDelegate. Deliberately just a closure holder —
/// no logic, no measurement, no state of its own. @Observable so it can be
/// injected via .environment(_:) / read via @Environment(SizingBridge.self)
/// the same way AppState and MBKOverlayGate are elsewhere in this app.
@Observable
@MainActor
final class SizingBridge {
    private weak var controller: MBKPopoverController?

    /// Called once from AppDelegate after MBKPopoverController is constructed
    /// (the controller doesn't exist yet at the point RootView's environment
    /// is wired up, so this two-step attach avoids a chicken-and-egg init order).
    func attach(_ controller: MBKPopoverController) {
        self.controller = controller
    }

    /// Explicitly declares the desired popover content size for the current
    /// route. This is the ONLY path by which size changes reach
    /// MBKPopoverController — no measurement, no GeometryReader, no
    /// fittingSize. See PopoverController.swift header for why.
    func setContentSize(_ size: CGSize) {
        controller?.setContentSize(NSSize(width: size.width, height: size.height))
    }
}
