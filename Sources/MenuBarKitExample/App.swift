// App.swift
// MenuBarKitExample

import SwiftUI

@main
struct MenuBarKitExampleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}
