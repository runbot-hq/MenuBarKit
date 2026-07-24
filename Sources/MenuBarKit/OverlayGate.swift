// OverlayGate.swift
// MenuBarKit

import Observation

@Observable
@MainActor
public final class MBKOverlayGate {
    public var hasActiveOverlay: Bool = false {
        didSet {
            mbkLog("OverlayGate", "hasActiveOverlay: \(oldValue) → \(self.hasActiveOverlay) | caller=\(Thread.callStackSymbols[1])")
        }
    }
    public init() {
        mbkLog("OverlayGate", "init")
    }
}
