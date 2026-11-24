// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// Decides when to re-read a keyboard's capability feature report to learn
/// the firmware version of a half that had not announced one yet.
///
/// Why a re-read is needed at all: on a wired split the peripheral half has
/// no connect-time hook to tell the central anything, so it announces its
/// `zmk-raw-touch` version over the split link **immediately before the
/// first frame of each touch on its pad**. The host, which reads the
/// feature report once at endpoint discovery, therefore sees the relayed
/// pad's slot as 0 — "Pad 1 half unknown" on the Keyboards tab — until
/// something makes it read the report again. The first frame of a touch is
/// exactly that trigger: by the time the frame reaches the host the announce
/// has already landed on the central.
///
/// The cost of getting this wrong is a feature-report GET per touch forever
/// against firmware that will never answer (an old peripheral half), so the
/// policy is bounded three ways:
///
/// - **Once per touch, per pad.** Only the first frame of a touch counts;
///   the ~100 Hz frames that follow it do not (`touching` edge detection).
/// - **At most one GET every `minimumRereadInterval` (2 s) per endpoint.**
///   One report describes every pad, so a re-read triggered by one pad also
///   answers for the other; quick successive touches share it.
/// - **At most `rereadsPerPad` (5) GETs per pad.** Past that the pad's half
///   is taken to be firmware old enough never to announce, and the pad is
///   given up on (`.gaveUp`) so the caller can stop watching its frames
///   entirely rather than polling for the rest of the session. Five is
///   enough to cover a peripheral that reconnects or misses an announce,
///   and small enough that the worst case is five wasted GETs per pad per
///   endpoint appearance.
///
/// Pure value semantics and no IOKit, so the whole policy is testable;
/// `RawTouchDeviceManager` owns an instance behind a lock, feeds it from the
/// HID callback thread, and performs the GET on the endpoint's report queue.
struct RawTouchFirmwareVersionProbe: Equatable {
    /// The floor between two capability GETs on one endpoint.
    static let minimumRereadInterval: TimeInterval = 2

    /// How many GETs a pad is worth before it is written off as a half that
    /// does not announce versions.
    static let rereadsPerPad = 5

    /// What the caller should do about the frame just seen.
    enum Decision: Equatable {
        /// Nothing: mid-touch, throttled, or already given up on.
        case none
        /// Re-read this endpoint's capability feature report now.
        case reread
        /// The pad's budget is spent: stop feeding this source's frames in.
        case gaveUp
    }

    private struct SourceState: Equatable {
        /// Whether the last frame seen from this source had a finger down —
        /// the edge that makes "the first frame of a touch" cheap to spot.
        var touching = false
        var rereadsIssued = 0
        var gaveUp = false
    }

    private var sources: [RawTouchSourceID: SourceState] = [:]

    /// When this endpoint's report was last re-read, on the frame timeline
    /// (host receive time). Per endpoint, not per pad: the GET answers for
    /// every pad the report describes.
    private var lastRereadAt: [RawTouchEndpointID: TimeInterval] = [:]

    /// Feeds in one frame from a pad still missing its half's version.
    /// `now` is the frame's host receive time (`ProcessInfo.systemUptime`).
    mutating func noteFrame(source: RawTouchSourceID, touched: Bool, now: TimeInterval) -> Decision {
        var state = sources[source] ?? SourceState()
        defer { sources[source] = state }

        guard touched else {
            // The release frame arms the next touch-down.
            state.touching = false
            return .none
        }
        guard !state.touching else {
            return .none  // mid-touch: the announce, if any, is already in
        }
        state.touching = true

        guard !state.gaveUp else {
            return .none
        }
        guard state.rereadsIssued < Self.rereadsPerPad else {
            state.gaveUp = true
            return .gaveUp
        }
        if let last = lastRereadAt[source.endpoint], now - last < Self.minimumRereadInterval {
            // Another pad on this keyboard was just read for, or this pad
            // was tapped twice in a row; that report already spoke for this
            // touch. Deliberately does not spend the pad's budget.
            return .none
        }

        state.rereadsIssued += 1
        lastRereadAt[source.endpoint] = now
        return .reread
    }

    /// Whether this pad has been written off (the caller stops watching it).
    func hasGivenUp(on source: RawTouchSourceID) -> Bool {
        sources[source]?.gaveUp ?? false
    }

    /// Drops everything remembered about an endpoint that went away. IDs are
    /// never reused, so this is housekeeping rather than correctness — but
    /// without it a long session of reconnects would accumulate entries.
    mutating func forget(endpoint: RawTouchEndpointID) {
        sources = sources.filter { $0.key.endpoint != endpoint }
        lastRereadAt[endpoint] = nil
    }
}
