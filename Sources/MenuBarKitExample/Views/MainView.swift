// MainView.swift — DEBUG STRIP
// Reduced to a single Text to prove glass is (or isn't) transparent.
// No List, no ScrollView, no Divider, no background modifiers at all.
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Text("Hello glass")
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(40)
            .onAppear { print("[MainView] onAppear") }
            .onDisappear { print("[MainView] onDisappear") }
    }
}
