// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// The host lease — how RawTouch mode is switched on at the protocol level:
/// the host acquires a lease on the frames by writing a SET feature report,
/// and while the lease is held the firmware emits touch frames and suppresses
/// the divided-down wheel events it would otherwise post in Standard mode.
/// Frames carry flags bit 2 (`lease_held`) for the endpoint they were sent
/// to, and the host synthesizes scroll **only** for those — so the wheel
/// fallback and synthesized scrolling are mutually exclusive by
/// construction, with the firmware as the single source of truth. That
/// closes the double-scroll window that opens after sleep, reboot or
/// re-pair, when the lease has lapsed but the host has not noticed yet.
///
/// The firmware module's docs/protocol.md is the normative wire contract;
/// `leasePayload` encodes it. A lease is written only to a device whose
/// feature report passed `RawTouchCapabilities`' validation and advertises
/// `Capability.hostLease` — an unvalidated device never gets a lease
/// command. The SET is written bare (the report ID in the call's argument
/// only; see `ReportFraming`), and any other command byte, length, or
/// non-zero reserved byte is rejected by the firmware. The lease is scoped
/// to the endpoint instance (transport + BLE profile) the write arrived on
/// and lapses on disconnect, profile switch, USB detach, or timeout expiry
/// — hence the renewal at no more than half the timeout, and the
/// re-acquire on every re-enumeration.
public enum RawTouchLease {
    /// Same report ID as the input and capability reports.
    public static let featureReportID: CFIndex = RawTouchCapabilities.featureReportID

    /// Command byte 0x01 = host lease.
    public static let leaseCommand: UInt8 = 0x01

    public static let acquireAction: UInt8 = 0x01
    public static let releaseAction: UInt8 = 0x00

    /// The firmware clamps the requested timeout into this range; 0 is
    /// rejected outright.
    public static let timeoutRange: ClosedRange<UInt8> = 5...120

    /// The timeout RawTouch asks for. Long enough that a briefly busy host
    /// never loses the lease, short enough that a crashed one restores the
    /// wheel fallback quickly.
    public static let defaultTimeoutSeconds: UInt8 = 30

    /// Renewal cadence: no more than half the requested timeout, and lazy
    /// enough not to wake the BLE radio needlessly.
    public static let renewalInterval: TimeInterval = 10

    /// Encodes an acquire/renew or release body. `timeoutSeconds` is clamped
    /// into the firmware's accepted range, so a caller can never emit the
    /// rejected `0`.
    public static func leasePayload(
        acquire: Bool,
        timeoutSeconds: UInt8 = defaultTimeoutSeconds
    ) -> [UInt8] {
        [
            leaseCommand,
            acquire ? acquireAction : releaseAction,
            timeoutSeconds.clamped(to: timeoutRange),
            0,  // reserved
        ]
    }
}

/// The tap confirm — the host's one contribution to a tap on a scrolling
/// pad. A pad that says it parks scroll taps
/// (`RawTouchCapabilities.Pad.parksScrollTaps`) does not emit a
/// scroll-context tap by itself while a lease is held: at lift-off it
/// holds the tap for ~250 ms and emits it only if this command arrives.
/// The firmware decides what a tap is and the keymap what it does; the
/// host supplies the one fact the firmware cannot know — that the touch did
/// not stop a coast (see `TouchScrollPipeline.onTapConfirm`).
///
/// A SET feature report framed exactly like the lease command (`payload`;
/// docs/protocol.md has the layout). Written only to firmware that
/// advertises `Capability.tapConfirm`. Honored only on the endpoint that
/// holds the lease; harmless when nothing is parked.
public enum RawTouchTapConfirm {
    /// Command byte 0x02 = tap confirm.
    public static let command: UInt8 = 0x02

    /// Encodes the confirm for the tap parked on `pad`.
    public static func payload(pad: UInt8) -> [UInt8] {
        [command, pad, 0, 0]
    }
}

/// One device's lease bookkeeping across the asynchronous write round trip.
///
/// Every acquire/release is a blocking feature-report transfer that runs off
/// the main queue and reports back later, so intent and reality are separated
/// in time. Without a generation stamp that gap is a real bug: an acquire still
/// in flight when the user disables RawTouch would land *after* the release
/// was requested and mark the lease held again, leaving the firmware in
/// RawTouch mode — suppressing its own wheel scrolling — with a host that has
/// stopped synthesizing, until the 30 s firmware lease expires.
///
/// The rule: every write is tagged with the generation it was issued under,
/// any new request bumps the generation, and a completion whose stamp is
/// stale is discarded. Factored out of `RawTouchDeviceManager` so the
/// ordering is unit-testable — there is no way to conjure an `IOHIDDevice` in
/// a test, so the manager itself cannot be driven through this path.
struct LeaseState: Equatable {
    /// What the manager wants for this device right now.
    private(set) var desiredHeld = false

    /// Whether the last acquire write that is *still current* landed. This is
    /// what `status.leaseHeld` reads, so it must never describe a lease we
    /// have since asked to drop.
    private(set) var held = false

    /// Whether the last acquire write that completed failed — the firmware
    /// rejected it, or the transfer errored. Per endpoint: one keyboard's
    /// failure says nothing about another's. Cleared only when an acquire
    /// lands or a release is requested: a renewal in flight has not
    /// answered yet, so an endpoint that keeps failing reads failed
    /// steadily instead of passing through pending on every renewal.
    private(set) var failed = false

    /// Bumped by every request; a completion stamped with anything older is
    /// speaking about a write we no longer care about.
    private(set) var generation: UInt64 = 0

    /// Where this lease stands, as the status reports it: not wanted, or
    /// wanted and held, failed, or still waiting for its first answer.
    var phase: RawTouchStatus.Endpoint.Lease {
        guard desiredHeld else {
            return .notWanted
        }
        return held ? .held : (failed ? .failed : .pending)
    }

    /// Records an acquire (or renew) request. Returns the stamp to tag the
    /// write with.
    mutating func beginAcquire() -> UInt64 {
        generation &+= 1
        desiredHeld = true
        return generation
    }

    /// Records a release request. `held` drops immediately — the status
    /// should read Standard mode from here on, not once the write returns —
    /// and any acquire in flight is obsoleted.
    @discardableResult
    mutating func beginRelease() -> UInt64 {
        generation &+= 1
        desiredHeld = false
        held = false
        failed = false
        return generation
    }

    /// Records the outcome of an acquire write. Ignored unless it is the write
    /// we are still waiting for.
    mutating func completeAcquire(landed: Bool, generation stamp: UInt64) {
        guard stamp == generation, desiredHeld else {
            return
        }
        held = landed
        failed = !landed
    }
}
