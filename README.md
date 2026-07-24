# MenuBarKit

A Swift package for the NSPopover + SwiftUI sheet + NSOpenPanel + alert layer of a macOS menu-bar app. Swift 6.2, macOS 26, `@MainActor`-first throughout.

**Platform & Stack**

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple&logoColor=white)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![SPM](https://img.shields.io/badge/SPM-compatible-F05138?logo=swift&logoColor=white)

**CI**

![Unit Tests](https://github.com/runbot-hq/MenuBarKit/actions/workflows/swift-test.yml/badge.svg)
![SwiftLint](https://github.com/runbot-hq/MenuBarKit/actions/workflows/swiftlint.yml/badge.svg)
![Periphery](https://github.com/runbot-hq/MenuBarKit/actions/workflows/periphery.yml/badge.svg)
[![Greptile](https://img.shields.io/badge/🦎%20AI%20Review-Greptile-6C47FF?logoColor=white)](https://greptile.com)

## Installation

```swift
.package(url: "https://github.com/runbot-hq/MenuBarKit", branch: "main")
```

## What's in the box

| File | What it provides |
|---|---|
| `OverlayGate.swift` | `MBKOverlayGate` — `@Observable @MainActor` class; `hasActiveOverlay` blocks popover dismiss while any overlay is live; `hasFilePickerOverlay` distinguishes file picker presence so outside clicks are ignored during a pick |
| `PopoverController.swift` | `MBKPopoverController` — full `NSPopover` + `NSStatusItem` lifecycle; outside-click monitor; workspace app-switch observer; `onWillClose(wasForced:)` callback fires before any teardown on both normal and force-close paths |
| `AnchoredSheet.swift` | `.mbkSheet(isPresented:overlayGate:content:)` and `.mbkSheet(item:overlayGate:content:)` — SwiftUI sheet anchored as a child window of the popover so it survives outside-clicks and focus changes |
| `FilePicker.swift` | `mbkOpenFilePicker(overlayGate:message:completion:)` — `NSOpenPanel` via `panel.begin`, always levels above the popover, gate cleared in completion handler; works from both popover and sheet contexts |
| `Alert.swift` | `.mbkAlert(_:isPresented:overlayGate:actions:)` and `.mbkAlert(_:isPresented:overlayGate:actions:message:)` — drop-in replacement for `.alert()` that gates `MBKOverlayGate` for the full alert lifetime, including safe handling of alerts presented while a sheet is concurrently open |
| `Logging.swift` | `mbkLog()` — `#if DEBUG`-gated, `@inlinable`, zero-cost in release; route to your own logger via `MBKLogHandler` |

## Usage

```swift
// 1. Create the gate — shared across controller and views
let gate = MBKOverlayGate()

// 2. Create and wire the controller
let controller = MBKPopoverController(rootView: ContentView(), overlayGate: gate)
controller.setup() // call from applicationDidFinishLaunching

// 3. Lifecycle callbacks
controller.onWillShow = {
    // restore route — fires before popover.show()
}
controller.onDidShow = {
    // restore sheet state — fires after one render cycle
}
controller.onWillClose = { wasForced in
    // snapshot everything — fires before any teardown
    // wasForced=true: user clicked outside while sheet was open
    // wasForced=false: normal user-dismissed close
}

// 4a. Sheet — Bool binding
.mbkSheet(isPresented: $showSettings, overlayGate: gate) {
    SettingsView()
}

// 4b. Sheet — optional Identifiable & Equatable item binding
.mbkSheet(item: $editingItem, overlayGate: gate) { item in
    ItemDetailView(item: item)
}

// 5. File picker — works from popover and sheet contexts
mbkOpenFilePicker(overlayGate: gate) { url in
    // handle url
}

// 6. File picker with in-panel message
mbkOpenFilePicker(overlayGate: gate, message: "Select a directory") { url in
    // handle url
}

// 7. Alert — gate managed automatically; safe when a sheet is concurrently open
.mbkAlert("Something went wrong", isPresented: $showAlert, overlayGate: gate) {
    Button("OK", role: .cancel) {}
} message: {
    Text("Please try again.")
}

// 8. Custom log handler (optional — set before setup())
MBKLogHandler = { subsystem, message in
    logger.debug("[MBK:\(subsystem)] \(message)")
}
```

## Known limitations

- **`DispatchQueue.main.async` in `MBKSheetAnchorTask`** — hop2 of the two-hop sheet anchor still uses GCD inside a Swift concurrency context. Works correctly in practice but is impure. See [#21](https://github.com/runbot-hq/MenuBarKit/issues/21) for the full blast-radius assessment before replacing it.
- **Sheet window predicate is heuristic** — `AnchoredSheet` finds the sheet window by `styleMask.contains(.borderless) && isKeyWindow`. Works for single-sheet environments; may need strengthening if multiple borderless windows are present simultaneously.

## Open tasks

- [ ] Replace `DispatchQueue.main.async` in `MBKSheetAnchorTask` with a pure Swift concurrency hop (see [#21](https://github.com/runbot-hq/MenuBarKit/issues/21))
- [ ] Strengthen sheet window predicate for multi-window environments
- [ ] Add more test coverage (gate teardown paths, popover delegate logic, force-close path)
- [ ] Remove explicit `overlayGate:` parameter from all MBK modifiers — resolve via `@Environment` internally (see [#2](https://github.com/runbot-hq/MenuBarKit/issues/2))
