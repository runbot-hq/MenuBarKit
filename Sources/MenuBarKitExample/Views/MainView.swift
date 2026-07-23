// MainView.swift
// MenuBarKitExample
//
// Shows a pre-populated list immediately on open.
// Width=260, Settings=320 — the width difference exercises arrow centering.

import AppKit
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState

    private var scrollMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.80
    }

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

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
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
                .padding(.vertical, 4)
            }
            .frame(maxHeight: scrollMaxHeight)
        }
        .frame(width: 260)
        .fixedSize(horizontal: true, vertical: false)
        .onAppear { print("[MainView] onAppear") }
    }
}
