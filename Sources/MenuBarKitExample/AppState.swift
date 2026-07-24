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
        didSet { print("[AppState] route: \(oldValue) → \(self.route) | Thread=\(Thread.isMainThread ? \"main\" : \"bg\")") }
    }
    var isSheetPresented: Bool = false {
        didSet { print("[AppState] isSheetPresented: \(oldValue) → \(self.isSheetPresented) | Thread=\(Thread.isMainThread ? \"main\" : \"bg\")") }
    }
    var pickedURL: URL? {
        didSet { print("[AppState] pickedURL: \(String(describing: self.pickedURL))") }
    }
    var sheetPickedURL: URL? {
        didSet { print("[AppState] sheetPickedURL: \(String(describing: self.sheetPickedURL))") }
    }
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
        let snap = SessionSnapshot(route: route, isSheetPresented: isSheetPresented)
        print("[AppState] saveSnapshot — route=\(snap.route) sheet=\(snap.isSheetPresented)")
        return snap
    }

    func restoreSnapshot(_ snapshot: SessionSnapshot) {
        print("[AppState] restoreSnapshot — route=\(snapshot.route) sheet=\(snapshot.isSheetPresented)")
        route = snapshot.route
        isSheetPresented = snapshot.isSheetPresented
        print("[AppState] restoreSnapshot done")
    }
}
