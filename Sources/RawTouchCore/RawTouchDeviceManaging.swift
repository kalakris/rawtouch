// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// The surface `RawTouchService` drives — exactly the slice of
/// `RawTouchDeviceManager` its callers need. The protocol exists for the
/// tests: a fake conformer lets the whole model layer run without opening
/// IOKit, acquiring a lease, or posting anything, per the suite-wide rule.
public protocol RawTouchDeviceManaging: AnyObject {
    /// The current status snapshot. Read once right after construction —
    /// `onStatusChange` does not replay it.
    var status: RawTouchStatus { get }

    /// Called on the main queue whenever `status` changes; never invoked
    /// with a snapshot equal to the previous one. Set before `start()`.
    var onStatusChange: ((RawTouchStatus) -> Void)? { get set }

    func start()
    func apply(configuration: RawTouchConfiguration)

    /// Tells the manager whether scroll events can actually be posted right now
    /// (in practice: whether Accessibility is granted). Deliberately **not**
    /// folded into `RawTouchConfiguration` — the user's `enabled` preference is
    /// theirs and must survive a missing grant untouched, while this is a fact
    /// about the process. Lease ownership is the conjunction of the two,
    /// because holding a lease while nothing can be posted suppresses the
    /// firmware's own scrolling and puts silence in its place.
    ///
    /// Idempotent, and main-queue only like everything else here. Set it
    /// before `start()` so a device that appears immediately never has a
    /// lease acquired prematurely.
    func setPostingReady(_ ready: Bool)

    func reportConfigurationError(_ error: RawTouchStatus.ConfigError)

    /// Releases the lease. Must run before the process exits, on every
    /// quit path.
    func shutdown()
}

extension RawTouchDeviceManager: RawTouchDeviceManaging {}
