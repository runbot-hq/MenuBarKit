// PopoverControllerProtocol.swift
// MenuBarKit
//
// Protocol surface for MBKPopoverController.
// Declare dependencies on this protocol rather than the concrete class
// so components that consume the controller remain independently testable.
//
// USAGE IN run-bot:
//   1. Declare your coordinator/delegate with `var popoverController: any MBKPopoverControllerProtocol`.
//   2. In production, assign an `MBKPopoverController` instance.
//   3. In tests, assign a lightweight fake that records calls.

import Foundation

/// Protocol surface for `MBKPopoverController`.
/// Exposes setup and the four session-restore hooks — everything a host app
/// needs to integrate MenuBarKit without referencing the concrete class.
@MainActor
public protocol MBKPopoverControllerProtocol: AnyObject {

    /// Wires the status item, popover, and observers.
    /// Call from `applicationDidFinishLaunching` before any user interaction.
    func setup()

    /// Called in `openPopover()` before `popover.show()`.
    /// Safe for restoring route and other state with no overlay gate side effects.
    /// Do NOT restore `isSheetPresented` here — use `onDidShow` instead.
    var onWillShow: (() -> Void)? { get set }

    /// Called via `Task { @MainActor }` after `popover.show()`, giving SwiftUI
    /// one render cycle to settle.
    /// Use this to restore `isSheetPresented` and any state that arms the overlay
    /// gate or tries to anchor a sheet window.
    var onDidShow: (() -> Void)? { get set }

    /// Called at the end of `popoverDidClose` after all cleanup.
    /// Only fires on normal close (no overlay active).
    var onDidClose: (() -> Void)? { get set }

    /// Called inside `forceClose()` BEFORE the overlay gate is cleared and
    /// BEFORE the popover closes. Use to snapshot session state when a sheet
    /// overlay is active at outside-click time.
    var onWillForceClose: (() -> Void)? { get set }
}
