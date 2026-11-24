// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).

import Foundation

/// One absolute touch sample streamed by the keyboard's vendor-defined HID
/// collection.
///
/// Frames are carried in input report `reportID`, which
/// `RawTouchDeviceManager` filters on before parsing. Depending on the
/// transport the payload may repeat the report ID as a leading byte;
/// `ReportFraming` decides where the frame starts. The firmware module's
/// docs/protocol.md is the normative layout: `payloadLength` bytes of
/// pad_id, contact_id, absolute x and y (uint16 little-endian), z (touch
/// strength), `Flag` bits (contact, scroll context, lease, split relay),
/// a per-pad sequence counter and a 100 µs device
/// timestamp (uint16 little-endian, wrapping). Pad IDs are assigned by the
/// firmware and say nothing about where a pad is. Frames shorter than the
/// layout are malformed and rejected; trailing bytes are ignored.
///
/// Cadence: emitted only while a host lease is held for the sending endpoint —
/// one report per sample while touched (~100 Hz), exactly one release report
/// (touched = 0) at lift-off, nothing while idle. On a mid-touch lease lapse
/// the firmware sends a single synthetic release (`leaseHeld` clear) and goes
/// silent.
public struct RawTouchFrame: Equatable {
    /// HID input report ID carrying touch frames — a frozen protocol
    /// constant, deliberately the same ID as the capability feature report
    /// (`RawTouchCapabilities.featureReportID`).
    public static let reportID: UInt32 = 0x04

    /// pad_id, contact_id, x(2), y(2), z, flags, seq, timestamp(2).
    public static let payloadLength = 11

    /// Flag bit masks in wire byte 7.
    public enum Flag {
        public static let touched: UInt8 = 0x1
        public static let scrollMode: UInt8 = 0x2
        /// Bit 2 (`lease_held`): a host lease was held for the endpoint this
        /// frame was sent to when it was sampled, i.e. the firmware has
        /// suppressed its own divided-down wheel fallback and the host owns
        /// scrolling. Implied-set on ordinary frames (the firmware emits frames
        /// only while a lease is held); clear only on the single trailing
        /// release frame of a mid-touch lease lapse. Hosts synthesize scroll
        /// only when this is set — see `RawTouchLease`.
        public static let leaseHeld: UInt8 = 0x4
        /// Bit 3 (`relayed`): the pad is on a split peripheral, and its
        /// samples reached the central through the split relay.
        public static let relayed: UInt8 = 0x8
        /// Bit 4 (`relay_wireless`): with `relayed`, the relay was the
        /// wireless split link; clear, the wired one. Meaningless without
        /// `relayed`.
        public static let relayWireless: UInt8 = 0x10
    }

    public var padID: UInt8

    /// Distinguishes fingers on multi-touch pads; 0 on single-touch
    /// hardware.
    public var contactID: UInt8

    public var x: Int
    public var y: Int
    public var z: Int
    public var touched: Bool
    public var scrollMode: Bool

    /// Flags bit 2: a host lease was held for this frame's endpoint, so the
    /// firmware's wheel fallback is suppressed and the host owns scrolling.
    /// Synthesized frames (the stale-touch release) carry the value of the
    /// touch they close out.
    public var leaseHeld: Bool

    /// Flags bits 3–4: the split link this pad's samples crossed to reach
    /// the half that sent the frame; nil for a pad on that half itself, and
    /// for firmware that does not say (it sends both bits as zero). A
    /// label for the readout, nothing more.
    public var splitLink: RawTouchSplitLink?

    /// The per-pad wire sequence counter (+1 per emitted report, wraps).
    /// `nil` only on synthesized frames (e.g. the stale-touch release),
    /// which never cross the wire. Diagnostic only — silent drops are
    /// surfaced by `TouchScrollPipeline`'s gap logging.
    public var seq: UInt8?

    /// The raw device-side sample time in 100 µs ticks, wrapping at
    /// 6.5536 s. `nil` only on synthesized frames. `TouchScrollPipeline`
    /// unwraps this onto a continuous timeline (`RawTouchDeviceClock`)
    /// and rewrites `timestamp` with it before the frame reaches the
    /// engine.
    public var deviceTimestampTicks: UInt16?

    /// The transport this frame arrived over. Not on the wire — the
    /// firmware has no idea which of its endpoints the host is reading — so
    /// the parser leaves it `.unknown` and `RawTouchDeviceManager` stamps it
    /// from the device the report came from. The pipeline names it in its
    /// latency log line.
    public var transport: RawTouchTransport = .unknown

    /// The endpoint this frame arrived on — also not on the wire, and also
    /// stamped by `RawTouchDeviceManager`. With `padID` it names the frame's
    /// source (`RawTouchSourceID`), which is what keeps two keyboards that
    /// both have a pad 0 apart. `.default` on frames built without one
    /// (fixtures, the bench).
    public var endpoint: RawTouchEndpointID = .default

    /// The engine-timeline timestamp. At parse time this is the host receive
    /// time (system uptime) captured in the HID report callback;
    /// `TouchScrollPipeline` replaces it with the reconstructed device-side
    /// sample time so velocity is immune to BLE connection-interval
    /// batching.
    public var timestamp: TimeInterval

    /// Parses a report payload in place — no per-report heap allocation on
    /// the ~100 Hz HID-callback path. Parsing starts at `offset`, which the
    /// caller gets from `ReportFraming` (1 when the transport prepended the
    /// report ID byte, 0 when the payload is bare). Returns `nil` for
    /// payloads too short for the layout; extra trailing bytes (e.g.
    /// padding) are ignored.
    public init?(
        reportBytes: UnsafeRawBufferPointer,
        offset: Int = 0,
        timestamp: TimeInterval
    ) {
        guard reportBytes.count - offset >= Self.payloadLength else {
            return nil
        }

        func byte(_ index: Int) -> UInt8 {
            reportBytes[offset + index]
        }

        padID = byte(0)
        contactID = byte(1)
        x = Int(byte(2)) | (Int(byte(3)) << 8)
        y = Int(byte(4)) | (Int(byte(5)) << 8)
        z = Int(byte(6))
        let flags = byte(7)
        touched = flags & Flag.touched != 0
        scrollMode = flags & Flag.scrollMode != 0
        leaseHeld = flags & Flag.leaseHeld != 0
        splitLink = RawTouchSplitLink(flags: flags)
        seq = byte(8)
        deviceTimestampTicks = UInt16(byte(9)) | (UInt16(byte(10)) << 8)
        self.timestamp = timestamp
    }

    /// Array-based convenience over the buffer parse, for callers that
    /// already hold a copied payload (e.g. test fixtures).
    public init?(reportBytes: [UInt8], timestamp: TimeInterval) {
        guard
            let frame = reportBytes.withUnsafeBytes({
                RawTouchFrame(reportBytes: $0, timestamp: timestamp)
            })
        else {
            return nil
        }
        self = frame
    }

    public init(
        padID: UInt8 = 0,
        contactID: UInt8 = 0,
        x: Int = 0,
        y: Int = 0,
        z: Int = 0,
        touched: Bool,
        scrollMode: Bool,
        leaseHeld: Bool = true,
        splitLink: RawTouchSplitLink? = nil,
        seq: UInt8? = nil,
        deviceTimestampTicks: UInt16? = nil,
        transport: RawTouchTransport = .unknown,
        endpoint: RawTouchEndpointID = .default,
        timestamp: TimeInterval
    ) {
        self.padID = padID
        self.contactID = contactID
        self.x = x
        self.y = y
        self.z = z
        self.touched = touched
        self.scrollMode = scrollMode
        self.leaseHeld = leaseHeld
        self.splitLink = splitLink
        self.seq = seq
        self.deviceTimestampTicks = deviceTimestampTicks
        self.transport = transport
        self.endpoint = endpoint
        self.timestamp = timestamp
    }

    /// The frame's source: the pad on the endpoint it arrived on.
    public var source: RawTouchSourceID {
        RawTouchSourceID(endpoint: endpoint, padID: padID)
    }

    /// The raw coordinate on one axis. One accessor for everything that
    /// works per axis — the engine's position math (vertical from one raw
    /// axis, horizontal from the other) and the resampler's per-axis fit —
    /// instead of a switch in each.
    subscript(axis: RawTouchAxis) -> Int {
        get {
            switch axis {
            case .x: x
            case .y: y
            }
        }
        set {
            switch axis {
            case .x: x = newValue
            case .y: y = newValue
            }
        }
    }
}

/// The split link a relayed pad's samples crossed to reach the keyboard's
/// central half (flags bits 3–4).
public enum RawTouchSplitLink: Equatable {
    case wired
    case wireless

    /// Bit 3 says the pad is relayed, bit 4 which link; bit 4 alone means
    /// nothing, and both clear is a local pad or firmware that does not say.
    init?(flags: UInt8) {
        guard flags & RawTouchFrame.Flag.relayed != 0 else {
            return nil
        }
        self = flags & RawTouchFrame.Flag.relayWireless != 0 ? .wireless : .wired
    }
}
