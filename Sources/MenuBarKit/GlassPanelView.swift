// GlassPanelView.swift
import SwiftUI

/// Internal wrapper that applies a tinted liquid-glass background to the
/// popover panel content using the SwiftUI `.glassEffect` API.
/// Tint alpha: increase toward 1.0 for darker glass.
struct MBKGlassPanelView<Content: View>: View {
    let content: Content

    var body: some View {
        content
            .background(.clear)
            .glassEffect(
                .regular.tint(.black.opacity(0.4)),
                in: RoundedRectangle(cornerRadius: 12)
            )
    }
}
