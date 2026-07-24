// OverlayGate.swift
// MenuBarKit

import Foundation
import Observation

@Observable
@MainActor
public final class MBKOverlayGate {
    public var hasActiveOverlay: Bool = false {
        didSet {
            // Thread.callStackSymbols not available inside @Observable macro expansion;
            // log the flip with old/new values only.
            mbkLog("OverlayGate", "hasActiveOverlay: \(oldValue) → \(self.hasActiveOverlay)")
        }
    }
    public init() {
        mbkLog("OverlayGate", "init")
    }
}
