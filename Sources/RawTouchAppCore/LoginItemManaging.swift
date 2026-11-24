// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import ServiceManagement

/// Start-at-login, abstracted so tests can fake it — registering a real
/// login item from a test host would enroll a throwaway `.build` binary
/// with launchd.
public protocol LoginItemManaging {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// The real thing: `SMAppService.mainApp`, which registers the running app
/// bundle itself (macOS 13+). Only meaningful when running from an installed
/// RawTouch.app; constructed exclusively by the app target.
public struct MainAppLoginItem: LoginItemManaging {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
