// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import os.log

/// Logging subsystem. A fixed string rather than
/// `Bundle.main.bundleIdentifier`, which a SwiftPM executable (the tests,
/// the bench) does not have.
public enum RawTouchLog {
    public static let subsystem = "io.github.kalakris.RawTouch"

    public static let device = OSLog(subsystem: subsystem, category: "Device")
    public static let scroll = OSLog(subsystem: subsystem, category: "Scroll")
    public static let lease = OSLog(subsystem: subsystem, category: "Lease")
    public static let configuration = OSLog(subsystem: subsystem, category: "Configuration")
    public static let notice = OSLog(subsystem: subsystem, category: "Notice")
    public static let updates = OSLog(subsystem: subsystem, category: "Updates")

    /// A plain-language line for the user as much as for a bug report —
    /// Accessibility missing, settings moved to a new key. Logged at
    /// `.default` so `log show` and Console.app list it without `--info`:
    /// an app launched from Finder or as a login item has no terminal, and
    /// whatever it writes to stderr is discarded.
    public static func note(_ message: String) {
        os_log("%{public}@", log: notice, type: .default, message)
    }
}
