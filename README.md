# MenuBarKit

A Swift package for the NSPopover + SwiftUI sheet + NSOpenPanel layer of a macOS menu-bar app. Swift 6.2, macOS 26, `@MainActor`-first throughout.

## Installation

```swift
.package(url: "https://github.com/runbot-hq/MenuBarKit", branch: "main")
```

## What’s in the box

| File | What it provides |
|---|---|
| `OverlayGate.swift` | `MBKOverlayGate` — `@Observable @MainActor` class; single `Bool` that blocks popover dismiss while any overlay is live |
| `PopoverController.swift` | `MBKPopoverController` — full `NSPopover` + `NSStatusItem` lifecycle; outside-click monitor; workspace app-switch observer |
| `AnchoredSheet.swift` | `.mbkSheet(isPresented:overlayGate:content:)` and `.mbkSheet(item:overlayGate:content:)` — SwiftUI sheet anchored as a child window of the popover so it survives outside-clicks and focus changes |
| `FilePicker.swift` | `mbkOpenFilePicker(target:overlayGate:message:completion:)` — `NSOpenPanel` via `beginSheetModal`, anchored to the correct window (popover or sheet child) |
| `Logging.swift` | `mbkLog()` — `#if DEBUG`-gated, `@inlinable`, zero-cost in release |

## Usage

```swift
// 1. Create the gate — shared across controller and views
let gate = MBKOverlayGate()

// 2. Create and wire the controller
let controller = MBKPopoverController(rootView: ContentView(), overlayGate: gate)
controller.setup() // call from applicationDidFinishLaunching

// 3a. Sheet — Bool binding
.mbkSheet(isPresented: $showSettings, overlayGate: gate) {
    SettingsView()
}

// 3b. Sheet — optional Identifiable & Equatable item binding
.mbkSheet(item: $editingItem, overlayGate: gate) { item in
    ItemDetailView(item: item)
}

// 4. File picker from popover context
mbkOpenFilePicker(target: .popover, overlayGate: gate) { url in
    // handle url
}

// 5. File picker from sheet context, with in-panel message
mbkOpenFilePicker(target: .sheet, overlayGate: gate, message: "Select a directory") { url in
    // handle url
}
```

## Known limitations

This package is **work in progress**. Known issues are documented inline with `// SPIKE ONLY`, `#warning`, and `TARGET IMPLEMENTATION` comments. The main ones:

- **Dismiss-safety gap** — `overlayGate.hasActiveOverlay` clears before AppKit finishes tearing down the sheet child window. Affects both sheet variants. Fix: replace the SwiftUI binding observation with `NSWindow.didBecomeKeyNotification` tracking — see `TARGET IMPLEMENTATION` in `AnchoredSheet.swift`.
- **`DispatchQueue.main.async` in `anchorSheetWindow()`** — mixes GCD with Swift concurrency. Gated by `#warning`. To be replaced with the notification-based approach.
- **`sheetChildWindow` predicate is intentionally weak** — works for single-child-window environments only. See `FilePicker.swift` before strengthening.

## Open tasks

- [ ] Replace `DispatchQueue.main.async` in `anchorSheetWindow()` with `NSWindow.didBecomeKeyNotification` (see `TARGET IMPLEMENTATION` in `AnchoredSheet.swift`)
- [ ] Fix dismiss-safety gap — tie gate lifetime to window lifecycle, not SwiftUI binding state
- [ ] Strengthen `sheetChildWindow` predicate for multi-child-window environments
- [ ] Add `MenuBarKitTests` target covering gate logic and teardown paths
