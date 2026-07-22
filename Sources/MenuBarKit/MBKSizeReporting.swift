// MBKSizeReporting.swift
// MenuBarKit
//
// Provides .mbkReportSize(), the size-reporting mechanism used by
// MBKPopoverController to detect content-size changes.
//
// WHY NOT NSHostingView.fittingSize:
//   fittingSize asks the hosted SwiftUI view "what size do you want",
//   which only works if every view in the tree has an intrinsic size
//   opinion. A GeometryReader anywhere in the tree breaks this contract —
//   it has no intrinsic size of its own, it just reports back whatever
//   size AppKit already proposed. That makes fittingSize an echo of the
//   current frame rather than a real measurement, so resize detection
//   built on it silently never fires (this broke MenuBarKitExample,
//   whose RootView wraps content in a GeometryReader for diagnostic
//   logging).
//
//   PreferenceKey propagation does not have this problem: each view
//   reports its own actual laid-out size up the tree via a
//   background(GeometryReader{...}) at the POINT OF USE, and
//   .mbkReportSize() sits at the outermost layer specifically to capture
//   that value, regardless of what's nested below it.

import SwiftUI

private struct MBKSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

public extension View {
    /// Reports this view's laid-out size via a callback, whenever it changes.
    /// Used internally by MBKPopoverController to size and resize its window.
    /// Safe to nest inside views that themselves use GeometryReader — the
    /// size reported here is this view's own frame, not derived from
    /// asking the hosted tree for a fittingSize.
    func mbkReportSize(_ onChange: @escaping (CGSize) -> Void) -> some View {
        self
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: MBKSizeKey.self, value: geo.size)
                }
            )
            .onPreferenceChange(MBKSizeKey.self) { size in
                onChange(size)
            }
    }
}
