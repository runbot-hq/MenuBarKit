// SizeReporter.swift
// MenuBarKit
//
// Usage:
//   1. Create MBKSizeRelay and inject it into the SwiftUI environment.
//   2. Apply .mbkReportSize() to your root view.
//   3. Pass the relay into MBKPopoverController(sizeRelay:).
//
// Route-change flash fix
// ──────────────────────
// When the SwiftUI route changes the GeometryReader fires once at the
// old (wrong) size before firing at the new correct size. This causes a
// visible flash. Fix: call relay.freezeForRouteChange() just before
// mutating the route. PopoverController hides the window (alphaValue=0)
// until the next reshowWithSize() call, when it snaps to the correct
// frame and restores alphaValue=1.

import Combine
import Observation
import SwiftUI

// MARK: - Relay

/// Carries content-size updates from SwiftUI into `MBKPopoverController`.
/// Create one instance, inject via `.environment()`, and pass to the controller.
@Observable
public final class MBKSizeRelay {
    public let subject = PassthroughSubject<NSSize, Never>()
    /// Fired when a route change is about to happen. PopoverController
    /// hides the window on this signal and restores it after the next resize.
    public let routeChangeSignal = PassthroughSubject<Void, Never>()

    public init() {}

    /// Call this immediately before mutating the route/navigation state.
    /// PopoverController will hide the window until the new size is committed.
    public func freezeForRouteChange() {
        routeChangeSignal.send()
    }
}

// MARK: - PreferenceKey

struct MBKSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

// MARK: - ViewModifier

struct MBKSizeReporterModifier: ViewModifier {
    @Environment(MBKSizeRelay.self) private var relay

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: MBKSizePreferenceKey.self, value: geo.size)
                }
            )
            .onPreferenceChange(MBKSizePreferenceKey.self) { size in
                guard size.width > 0, size.height > 0 else { return }
                relay.subject.send(NSSize(width: size.width, height: size.height))
            }
    }
}

// MARK: - View extension

public extension View {
    /// Measures this view's size and forwards changes to the `MBKSizeRelay`
    /// found in the SwiftUI environment.
    func mbkReportSize() -> some View {
        modifier(MBKSizeReporterModifier())
    }
}
