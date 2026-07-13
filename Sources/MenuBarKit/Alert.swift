// Alert.swift
// MenuBarKit
//
// Adds mbkAlert ViewModifier — the production replacement for the
// mbkSetOverlay() spike escape hatch used in RunBotSpike SettingsView.
//
// PROBLEM:
//   SwiftUI's .alert() is a system-modal presentation that AppKit manages
//   independently of NSWindow child relationships. It therefore does not
//   need the two-hop window-anchoring logic of MBKAnchoredSheet. However,
//   it still needs to arm MBKOverlayGate.hasActiveOverlay so the
//   outside-click monitor does not close the popover while the alert is
//   on screen.
//
// SOLUTION:
//   Wrap .alert() in a ViewModifier that mirrors the gate-management
//   pattern of MBKAnchoredSheetModifier: onChange(of: isPresented) sets
//   hasActiveOverlay = true when the alert appears, false when dismissed.
//
//   No AppKit window walking is needed — the alert lifetime is tracked
//   purely through the isPresented binding.
//
// CONCURRENT OVERLAY SAFETY:
//   OverlayGate.swift documents that the single-Bool gate is sufficient
//   because only one overlay (sheet OR file picker) can normally be live
//   at a time. The one acknowledged exception is an alert presented while
//   a sheet is already open.
//
//   For that case this modifier guards the clear path:
//     - On alert appear: always set gate = true.
//     - On alert dismiss: only clear gate = false if no sheet was
//       concurrently open when the alert appeared.
//
//   This is tracked via a @State Bool `gateWasArmedByConcurrentOverlay`
//   captured at alert-appear time. If the gate was already true (sheet
//   live) when the alert appeared, the modifier does not clear it on
//   dismiss — preserving the sheet's gate ownership.
//
//   If a future scenario genuinely requires full reference counting,
//   replace MBKOverlayGate.hasActiveOverlay Bool with an Int and use
//   increment/decrement. The modifier's body would then simply +1 on
//   appear and -1 on dismiss.
//
// USAGE:
//   Replace:
//     .alert("Title", isPresented: $flag) { ... }
//     .onChange(of: flag) { _, v in overlayGate.mbkSetOverlay(v) }
//
//   With:
//     .mbkAlert("Title", isPresented: $flag, overlayGate: overlayGate) { ... }
//
//   Or with a message trailing closure:
//     .mbkAlert("Title", isPresented: $flag, overlayGate: overlayGate) {
//         Button("OK", role: .cancel) {}
//     } message: {
//         Text("Something went wrong.")
//     }

import SwiftUI

// MARK: - View extension

/// View extension providing `mbkAlert` modifier overloads.
public extension View {

    /// Presents an alert and manages `overlayGate.hasActiveOverlay` for its lifetime.
    ///
    /// Drop-in replacement for SwiftUI's `.alert(_:isPresented:actions:)` that
    /// additionally gates the `MBKOverlayGate` so the outside-click monitor
    /// does not close the popover while the alert is on screen.
    ///
    /// - Parameters:
    ///   - title: The alert title string.
    ///   - isPresented: Binding that controls presentation.
    ///   - overlayGate: The gate owned by the enclosing `MBKPopoverController`.
    ///   - actions: Alert action buttons.
    func mbkAlert<A: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        overlayGate: MBKOverlayGate,
        @ViewBuilder actions: @escaping () -> A
    ) -> some View {
        modifier(MBKAlertModifier(
            title: title,
            isPresented: isPresented,
            overlayGate: overlayGate,
            actions: actions,
            message: { EmptyView() }
        ))
    }

    /// Presents an alert with a message and manages `overlayGate.hasActiveOverlay`.
    ///
    /// Drop-in replacement for SwiftUI's `.alert(_:isPresented:actions:message:)`.
    ///
    /// - Parameters:
    ///   - title: The alert title string.
    ///   - isPresented: Binding that controls presentation.
    ///   - overlayGate: The gate owned by the enclosing `MBKPopoverController`.
    ///   - actions: Alert action buttons.
    ///   - message: Secondary message view shown below the title.
    func mbkAlert<A: View, M: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        overlayGate: MBKOverlayGate,
        @ViewBuilder actions: @escaping () -> A,
        @ViewBuilder message: @escaping () -> M
    ) -> some View {
        modifier(MBKAlertModifier(
            title: title,
            isPresented: isPresented,
            overlayGate: overlayGate,
            actions: actions,
            message: message
        ))
    }
}

// MARK: - Modifier

/// ViewModifier that wraps SwiftUI's `.alert()` and gates `MBKOverlayGate`
/// for the full alert lifetime.
///
/// See file header for design rationale, concurrent-overlay safety notes,
/// and migration guidance.
///
/// Prefer the `View.mbkAlert(...)` convenience overloads over constructing
/// this modifier directly.
public struct MBKAlertModifier<A: View, M: View>: ViewModifier {
    /// The alert title.
    public let title: String
    /// Whether the alert is currently presented.
    @Binding public var isPresented: Bool
    /// The gate that blocks popover dismiss while the alert is live.
    public let overlayGate: MBKOverlayGate
    /// Alert action buttons.
    public let actions: () -> A
    /// Optional secondary message view.
    public let message: () -> M

    /// Tracks whether the gate was already armed by a concurrent overlay
    /// (e.g. a sheet) at the moment this alert appeared.
    /// Used to decide whether to clear the gate on alert dismiss:
    /// if true, the gate was not ours to clear — the concurrent overlay
    /// still owns it.
    @State private var gateWasArmedByConcurrentOverlay = false

    /// Creates the modifier.
    /// - Parameters:
    ///   - title: The alert title string.
    ///   - isPresented: Binding that controls presentation.
    ///   - overlayGate: The gate owned by the enclosing `MBKPopoverController`.
    ///   - actions: Alert action buttons.
    ///   - message: Secondary message view shown below the title.
    public init(
        title: String,
        isPresented: Binding<Bool>,
        overlayGate: MBKOverlayGate,
        @ViewBuilder actions: @escaping () -> A,
        @ViewBuilder message: @escaping () -> M
    ) {
        self.title = title
        self._isPresented = isPresented
        self.overlayGate = overlayGate
        self.actions = actions
        self.message = message
    }

    /// Applies the alert and gate-management logic.
    public func body(content: Content) -> some View {
        content
            .alert(title, isPresented: $isPresented, actions: actions, message: message)
            .onChange(of: isPresented) { _, newValue in
                if newValue {
                    // Record whether the gate was already armed so the dismiss
                    // path knows whether to clear it.
                    gateWasArmedByConcurrentOverlay = overlayGate.hasActiveOverlay
                    overlayGate.hasActiveOverlay = true
                    mbkLog("Alert", "appeared — gate armed (concurrent=\(gateWasArmedByConcurrentOverlay))")
                } else {
                    // Only clear the gate if we were the ones who armed it.
                    // If a concurrent sheet was live when the alert appeared,
                    // the gate belongs to the sheet — do not clear.
                    if !gateWasArmedByConcurrentOverlay {
                        overlayGate.hasActiveOverlay = false
                        mbkLog("Alert", "dismissed — gate cleared")
                    } else {
                        mbkLog("Alert", "dismissed — gate preserved (concurrent overlay still live)")
                    }
                }
            }
    }
}
