// AppState.swift
// MenuBarKitExample

import Foundation
import Observation

enum Route: Equatable {
    case main
    case settings
}

@Observable
@MainActor
final class AppState {
    var route: Route = .main {
        didSet { print("[AppState] route: \(oldValue) → \(self.route)") }
    }
    var isSheetPresented: Bool = false {
        didSet { print("[AppState] isSheetPresented: \(oldValue) → \(self.isSheetPresented)") }
    }
    var pickedURL: URL?
    var sheetPickedURL: URL?
    var showAlert: Bool = false {
        didSet { print("[AppState] showAlert: \(oldValue) → \(self.showAlert)") }
    }
    var showSheetAlert: Bool = false {
        didSet { print("[AppState] showSheetAlert: \(oldValue) → \(self.showSheetAlert)") }
    }

    struct SessionSnapshot {
        var route: Route
        var isSheetPresented: Bool
    }

    func saveSnapshot() -> SessionSnapshot {
        SessionSnapshot(route: route, isSheetPresented: isSheetPresented)
    }

    func restoreSnapshot(_ snapshot: SessionSnapshot) {
        route = snapshot.route
        isSheetPresented = snapshot.isSheetPresented
    }
}
