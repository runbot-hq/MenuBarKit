// SizeReporter.swift
// MenuBarKit
//
// Apply `.mbkReportSize(to:)` once on the root view to forward size changes
// into MBKPopoverController.sizeRelay:
//
//   RootView()
//       .mbkReportSize(to: popoverController)

import SwiftUI

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
    let controller: MBKPopoverController

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
                controller.sizeRelay.send(NSSize(width: size.width, height: size.height))
            }
    }
}

// MARK: - View extension

public extension View {
    /// Measures this view's size and forwards changes to the given
    /// `MBKPopoverController` so it can reanchor the popover arrow.
    func mbkReportSize(to controller: MBKPopoverController) -> some View {
        modifier(MBKSizeReporterModifier(controller: controller))
    }
}
