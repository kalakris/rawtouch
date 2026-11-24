// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

// The Keyboards tab's firmware row.
extension StatusFormatter {
    /// The settings window's firmware line for one keyboard: the module
    /// version its central half reports and the protocol both sides speak —
    /// "0.1 · protocol 4" — naming any pad whose own half differs, "0.1 ·
    /// protocol 4 · Pad 1 half 0.0", or has said nothing yet, "0.1 ·
    /// protocol 4 · Pad 1 half: touch it to read". A split flashed on one
    /// side only reads there. Firmware old enough not to report a
    /// version at all says so instead of guessing: "protocol 4 · version
    /// unknown".
    ///
    /// Said once while every connection reports the same — the same
    /// keyboard answers both, so it normally does. Two connections that
    /// disagree (a relayed pad announced on one and not yet the other) each
    /// say their own, named by transport.
    public static func firmwareLine(
        for endpoint: RawTouchStatus.Endpoint,
        configuration: RawTouchConfiguration = .init()
    ) -> String {
        let proto = "protocol \(RawTouchCapabilities.protocolVersion)"
        guard let central = endpoint.firmwareVersion else {
            // Without the central's version the pads' have nothing to
            // disagree with; one honest fragment beats a list of halves.
            return "\(proto) \u{00B7} version unknown"
        }
        var parts = ["\(central)", proto]
        for padID in endpoint.padIDs.sorted() {
            let name = padName(padID, deviceKey: endpoint.deviceKey, in: configuration)
            guard let version = endpoint.padFirmwareVersions[padID] else {
                // Not a fault: a relayed half announces its version with
                // the first frame of the first touch, so the row says what
                // would fill it in rather than reporting a blank.
                parts.append("\(name) half: touch it to read")
                continue
            }
            if version != central {
                parts.append("\(name) half \(version)")
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The firmware line for a whole keyboard, or nil when none of its
    /// connections has firmware to report on.
    ///
    /// One line, never one per connection: the feature report is answered
    /// by the keyboard's central half on every transport, so it describes
    /// the keyboard, and the registry keeps it that way — merged across
    /// connections, a pad's half version known as soon as any of them has
    /// learned it. So "touch it to read" appears only while no connection
    /// has heard from that half.
    public static func keyboardFirmwareLine(
        for keyboard: RawTouchKeyboard,
        configuration: RawTouchConfiguration = .init()
    ) -> String? {
        guard let endpoint = keyboard.endpoints.first(where: { $0.lease != .unsupportedFirmware }) else {
            return nil
        }
        var report = endpoint
        // Every pad the keyboard has, whichever connection listed it.
        report.padIDs = keyboard.padIDs
        return firmwareLine(for: report, configuration: configuration)
    }

    /// The firmware row's tooltip.
    public static let firmwareHelp =
        "The firmware module\u{2019}s version on this keyboard, and per pad the "
        + "version of the half that pad belongs to \u{2014} a right half flashed without the left shows up here. "
        + "The protocol number is what the app and the module must agree on."
}
