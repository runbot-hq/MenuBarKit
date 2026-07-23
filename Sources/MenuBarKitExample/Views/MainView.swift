// MainView.swift
// MenuBarKitExample
//
// Uses a plain VStack (no ScrollView) so fittingSize reports correct full
// height before the view is attached to a window.
// Width=260 vs Settings width=320 exercises arrow centering on nav.

import AppKit
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MBK Example").font(.headline)
                Spacer()
                Button("Settings →") { appState.route = .settings }
                    .buttonStyle(.plain)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ForEach(appState.mainItems, id: \.self) { item in
                HStack {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text(item).font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider().padding(.leading, 12)
            }
        }
        .frame(width: 260)
        .fixedSize(horizontal: true, vertical: false)
        .onAppear { print("[MainView] onAppear") }
    }
}
