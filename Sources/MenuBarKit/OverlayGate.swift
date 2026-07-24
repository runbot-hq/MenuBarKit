// OverlayGate.swift
// MenuBarKit

import Foundation
import Observation

@Observable
@MainActor
public final class MBKOverlayGate {
    /// True whenever ANY overlay (sheet, alert, file picker) is active.
    /// Blocks outside-click popover dismiss and workspace-switch dismiss.
    public var hasActiveOverlay: Bool = false {
        didSet {
            mbkLog("OverlayGate", "hasActiveOverlay: \(oldValue) → \(self.hasActiveOverlay)")
        }
    }

    /// True specifically when a file picker panel is open.
    /// Used by PopoverController's event monitor to distinguish an outside
    /// click aimed at the picker from a genuine dismiss gesture, even when
    /// a sheet child window is simultaneously present.
    public var hasFilePickerOverlay: Bool = false {
        didSet {
            mbkLog("OverlayGate", "hasFilePickerOverlay: \(oldValue) → \(self.hasFilePickerOverlay)")
        }
    }

    public init() {
        mbkLog("OverlayGate", "init")
    }
}
