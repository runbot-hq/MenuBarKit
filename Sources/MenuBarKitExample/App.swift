// App.swift
// MenuBarKitExample
//
// TEMPORARY proof-of-concept: plain window in center of screen
// with liquid glass, no NSPanel, no menu bar, no popover.
// Revert this file to restore normal behaviour.

import SwiftUI

@main
struct MenuBarKitExampleApp: App {
    var body: some Scene {
        WindowGroup {
            GlassProofView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 320, height: 200)
    }
}

struct GlassProofView: View {
    var body: some View {
        GlassEffectContainer {
            ZStack {
                Color.clear
                Text("Liquid Glass")
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            .glassEffect(in: RoundedRectangle(cornerRadius: 16))
        }
        .frame(width: 320, height: 200)
    }
}
