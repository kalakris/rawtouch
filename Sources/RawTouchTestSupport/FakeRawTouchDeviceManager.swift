// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

/// A `RawTouchDeviceManaging` that records every call and lets a test push
/// status snapshots, so `RawTouchService` and `AppModel` can both be driven
/// without IOKit, a host lease, or an event thread — the suite-wide "posts
/// nothing, opens nothing" rule.
public final class FakeRawTouchDeviceManager: RawTouchDeviceManaging {
    public private(set) var status = RawTouchStatus()
    public var onStatusChange: ((RawTouchStatus) -> Void)?

    public private(set) var startCount = 0
    public private(set) var shutdownCount = 0
    public private(set) var appliedConfigurations: [RawTouchConfiguration] = []
    public private(set) var reportedErrors: [RawTouchStatus.ConfigError] = []

    /// Every `setPostingReady(_:)` in order, including the one the service
    /// makes before `start()`. Tests assert on this rather than on
    /// `configuration.enabled`: the user's preference must survive a missing
    /// Accessibility grant untouched.
    public private(set) var postingReadyCalls: [Bool] = []

    /// The last readiness the manager was told, or nil if it was never told.
    public var lastPostingReady: Bool? {
        postingReadyCalls.last
    }

    /// Whether `onStatusChange` was already installed when `start()` ran —
    /// the manager's contract, since the initial snapshot is never replayed.
    public private(set) var hadStatusHookAtStart = false

    public init() {}

    public func start() {
        startCount += 1
        hadStatusHookAtStart = onStatusChange != nil
    }

    public func apply(configuration: RawTouchConfiguration) {
        appliedConfigurations.append(configuration)
        // Mirror the real manager's observable side effects: a clean apply
        // clears any config error and tracks the master switch.
        var newStatus = status
        newStatus.configError = nil
        newStatus.enabled = configuration.enabled
        push(newStatus)
    }

    public func setPostingReady(_ ready: Bool) {
        postingReadyCalls.append(ready)
        // Mirror the real manager's observable side effects: readiness shows
        // in the status, and losing it drops the lease at once.
        var newStatus = status
        newStatus.postingReady = ready
        if !ready {
            for index in newStatus.endpoints.indices where newStatus.endpoints[index].lease == .held {
                newStatus.endpoints[index].lease = .notWanted
            }
        }
        push(newStatus)
    }

    public func reportConfigurationError(_ error: RawTouchStatus.ConfigError) {
        reportedErrors.append(error)
        var newStatus = status
        newStatus.configError = error
        push(newStatus)
    }

    public func shutdown() {
        shutdownCount += 1
    }

    /// Publishes a snapshot the way the real manager does: deduped, then
    /// through `onStatusChange`.
    public func push(_ newStatus: RawTouchStatus) {
        guard newStatus != status else {
            return
        }
        status = newStatus
        onStatusChange?(newStatus)
    }
}
