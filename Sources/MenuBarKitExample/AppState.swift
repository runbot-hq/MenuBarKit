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
        didSet { AppState.log("route", oldValue, route) }
    }
    var isSheetPresented: Bool = false {
        didSet { AppState.log("isSheetPresented", oldValue, isSheetPresented) }
    }
    var pickedURL: URL? {
        didSet { print("[AppState] pickedURL: \(String(describing: pickedURL))") }
    }
    var sheetPickedURL: URL? {
        didSet { print("[AppState] sheetPickedURL: \(String(describing: sheetPickedURL))") }
    }
    var showAlert: Bool = false {
        didSet { AppState.log("showAlert", oldValue, showAlert) }
    }
    var showSheetAlert: Bool = false {
        didSet { AppState.log("showSheetAlert", oldValue, showSheetAlert) }
    }

    // Static helper — lives outside @Observable macro expansion,
    // so Thread and escaped quotes work without compiler issues.
    private static func log<T>(_ name: String, _ old: T, _ new: T) {
        let thread = Thread.isMainThread ? "main" : "bg"
        print("[AppState] \(name): \(old) -> \(new) | Thread=\(thread)")
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
