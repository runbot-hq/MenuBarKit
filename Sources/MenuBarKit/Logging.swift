// Logging.swift
// MenuBarKit

import Foundation

/// The active log handler. Defaults to `print`. Replace to route MBK logs
/// to your own logger (os_log, structured logger, etc.).
/// Set this before calling `MBKPopoverController.setup()`.
///
/// Example:
/// ```swift
/// MBKLogHandler = { subsystem, message in
///     logger.debug("[MBK:\(subsystem)] \(message)")
/// }
/// ```
public var MBKLogHandler: (_ subsystem: String, _ message: String) -> Void = { subsystem, message in
    print("[MBK:\(subsystem)] \(message)")
}

/// Internal logging entry point. Routes through `MBKLogHandler`.
/// Compiled out entirely in release builds.
@inlinable
func mbkLog(_ subsystem: String, _ message: String) {
#if DEBUG
    MBKLogHandler(subsystem, message)
#endif
}
