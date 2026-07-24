// PopoverControllerProtocol.swift
// MenuBarKit
//
// Protocol surface for MBKPopoverController.

import Foundation

/// Protocol surface for `MBKPopoverController`.
@MainActor
public protocol MBKPopoverControllerProtocol: AnyObject {

    /// Wires the status item, popover, and observers.
    /// Call from `applicationDidFinishLaunching` before any user interaction.
    func setup()

    /// Called in `openPopover()` before `popover.show()`.
    /// Safe for restoring route and other state with no overlay gate side effects.
    var onWillShow: (() -> Void)? { get set }

    /// Called via `Task { @MainActor }` after `popover.show()`, giving SwiftUI
    /// one render cycle to settle.
    /// Use this to restore `isSheetPresented` and any state that arms the overlay gate.
    var onDidShow: (() -> Void)? { get set }

    /// Called before any teardown whenever the popover closes.
    /// `wasForced` is `true` when the close was triggered by an outside click while a
    /// sheet was active (force-close path). Use this to reset live sheet state so SwiftUI
    /// tears down the sheet window before the popover closes.
    /// `wasForced` is `false` on a normal user-dismissed close — sheet state is already
    /// gone, no reset needed.
    var onWillClose: ((_ wasForced: Bool) -> Void)? { get set }
}
