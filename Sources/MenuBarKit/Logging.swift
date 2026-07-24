// Logging.swift
// MenuBarKit

import Foundation

/// The active log handler. Defaults to `print`. Replace to route MBK logs
/// to your own logger (os_log, structured logger, etc.).
/// Set this before calling `MBKPopoverController.setup()`.
/// Isolated to `@MainActor` because all MBK log call sites are on the main actor.
///
/// Example:
/// ```swift
/// mbkLogHandler = { subsystem, message in
///     logger.debug("[MBK:\(subsystem)] \(message)")
/// }
/// ```
@MainActor
public var mbkLogHandler: (_ subsystem: String, _ message: String) -> Void = { subsystem, message in
    print("[MBK:\(subsystem)] \(message)")
}

/// Internal logging entry point. Routes through `mbkLogHandler`.
/// Compiled out entirely in release builds.
@MainActor
@inlinable
func mbkLog(_ subsystem: String, _ message: String) {
#if DEBUG
    mbkLogHandler(subsystem, message)
#endif
}
