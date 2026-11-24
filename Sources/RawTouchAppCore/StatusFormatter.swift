// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

/// Turns status snapshots into short factual fragments ("Go60 connected",
/// "RawTouch mode", "Pad 0 scrolling") — no sentences, no drama.
/// Pure functions — the menu just prints what comes back.
///
/// This file names things and says what mode each keyboard is in; the
/// firmware rows are in `StatusFormatter+Firmware.swift`, and the
/// measurements (the last gesture, the measured latency) in
/// `StatusFormatter+Readout.swift`.
public enum StatusFormatter {
    /// The human name for a pad: the one it was given on its keyboard
    /// (`devices.<key>.pads.<id>.name`), else the firmware's own numbering.
    /// Pad IDs are assigned by the firmware and carry no side information,
    /// so the default stays literal rather than guessing which side a pad
    /// is on — which is exactly why the name is editable.
    public static func padName(
        _ padID: UInt8,
        deviceKey: String? = nil,
        in configuration: RawTouchConfiguration = .init()
    ) -> String {
        configuration.configuredPadName(forPad: padID, deviceKey: deviceKey) ?? "Pad \(padID)"
    }

    /// "Go60 Right · Bluetooth" — one connection, named with its
    /// transport: what the latency readout labels a connection with.
    public static func connectionName(_ endpoint: RawTouchStatus.Endpoint) -> String {
        guard let transport = endpoint.transport.displayName else {
            return endpoint.productName
        }
        return "\(endpoint.productName) \u{00B7} \(transport)"
    }

    /// "USB", "USB and Bluetooth" — the plain English list the menu wants.
    private static func joined(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else {
            return items.first ?? ""
        }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: - Lease mode

    /// The mode alone: "RawTouch mode", "Standard mode", "Switching to
    /// RawTouch mode…", "Firmware without RawTouch mode".
    public static func leaseMode(for lease: RawTouchStatus.Endpoint.Lease) -> String {
        switch lease {
        case .held:
            return "RawTouch mode"
        case .notWanted, .disabled, .failed:
            return "Standard mode"
        case .pending:
            return "Switching to RawTouch mode\u{2026}"
        case .unsupportedFirmware:
            return "Firmware without RawTouch mode"
        }
    }

    /// Why it is in that mode, when the mode alone does not say:
    /// "switched off", "switch failed, reconnect to retry". Nil otherwise.
    public static func leaseReason(for lease: RawTouchStatus.Endpoint.Lease) -> String? {
        switch lease {
        case .disabled:
            return "switched off"
        case .failed:
            return "switch failed, reconnect to retry"
        case .held, .notWanted, .pending, .unsupportedFirmware:
            return nil
        }
    }

    /// One endpoint's mode, with the reason when it is not simply so:
    /// "RawTouch mode", "Standard mode", "Switching to RawTouch mode…",
    /// "Standard mode — switched off", "Standard mode — switch failed,
    /// reconnect to retry", "Firmware without RawTouch mode".
    public static func leaseLine(for lease: RawTouchStatus.Endpoint.Lease) -> String {
        let mode = leaseMode(for: lease)
        guard let reason = leaseReason(for: lease) else {
            return mode
        }
        return "\(mode) \u{2014} \(reason)"
    }

    /// The same for one connection of a keyboard whose connections
    /// disagree, naming which one it is: "Standard mode over Bluetooth —
    /// switch failed, reconnect to retry". The transport sits with the
    /// mode, before the reason, because that is what it qualifies.
    public static func leasePhrase(for endpoint: RawTouchStatus.Endpoint) -> String {
        var phrase = leaseMode(for: endpoint.lease)
        if let transport = endpoint.transport.displayName {
            phrase += " over \(transport)"
        }
        guard let reason = leaseReason(for: endpoint.lease) else {
            return phrase
        }
        return "\(phrase) \u{2014} \(reason)"
    }

    // MARK: - Keyboard status

    /// The settings window's status line for one keyboard: what mode it is
    /// in, over which connections, and what its pads are doing right now
    /// when one of them is doing something.
    ///
    /// Stated once — "RawTouch mode · USB and Bluetooth" — while every
    /// connection agrees, which is the normal case and the only thing
    /// worth knowing then. When they disagree, each says its own piece:
    /// "RawTouch mode over USB · Standard mode over Bluetooth — switch
    /// failed, reconnect to retry".
    public static func keyboardStatus(
        for keyboard: RawTouchKeyboard,
        in status: RawTouchStatus,
        configuration: RawTouchConfiguration = .init()
    ) -> String {
        let mode =
            keyboard.leasesAgree
            ? [leaseLine(for: keyboard.endpoints.first?.lease ?? .notWanted), transportList(keyboard)]
                .compactMap { $0 }
                .joined(separator: " \u{00B7} ")
            : keyboard.endpoints.map(leasePhrase(for:)).joined(separator: " \u{00B7} ")
        guard let activity = padActivityLine(for: status, on: keyboard, configuration: configuration) else {
            return mode
        }
        return "\(mode) \u{00B7} \(activity)"
    }

    /// "USB", "USB and Bluetooth" — the connections a keyboard is reachable
    /// over; nil when macOS named none of them.
    public static func transportList(_ keyboard: RawTouchKeyboard) -> String? {
        let named = keyboard.transports.compactMap(\.displayName)
        return named.isEmpty ? nil : joined(named)
    }

    /// "Pad 0 scrolling" / "Pad 1 coasting" when the activity is on one of
    /// this keyboard's connections, or nil.
    private static func padActivityLine(
        for status: RawTouchStatus,
        on keyboard: RawTouchKeyboard,
        configuration: RawTouchConfiguration
    ) -> String? {
        let ids = Set(keyboard.endpoints.map(\.id))
        switch status.activity {
        case .idle:
            return nil
        case .touching(let pad, let endpoint) where ids.contains(endpoint):
            return "\(padName(pad, deviceKey: keyboard.key, in: configuration)) scrolling"
        case .coasting(let pad, let endpoint) where ids.contains(endpoint):
            return "\(padName(pad, deviceKey: keyboard.key, in: configuration)) coasting"
        case .touching, .coasting:
            return nil
        }
    }

    // MARK: - Menu

    /// The menu's status block: one line per keyboard, whichever way it is
    /// connected — "Go60 Right · USB and Bluetooth: RawTouch mode" — and
    /// each connection's own piece only when they disagree: "Go60 Right:
    /// RawTouch mode over USB, Standard mode over Bluetooth — switch
    /// failed, reconnect to retry". A lease belongs to a connection and can
    /// fail on its own, so a keyboard whose connections differ is never
    /// summarized; one that agrees is never enumerated.
    public static func keyboardLines(for keyboards: [RawTouchKeyboard]) -> [String] {
        guard !keyboards.isEmpty else {
            return ["Waiting for device"]
        }
        return keyboards.map(keyboardLine(for:))
    }

    /// One keyboard's menu line.
    public static func keyboardLine(for keyboard: RawTouchKeyboard) -> String {
        guard keyboard.leasesAgree else {
            let phrases = keyboard.endpoints.map(leasePhrase(for:)).joined(separator: ", ")
            return "\(keyboard.name): \(phrases)"
        }
        let mode = leaseLine(for: keyboard.endpoints.first?.lease ?? .notWanted)
        guard let transports = transportList(keyboard) else {
            return "\(keyboard.name): \(mode)"
        }
        return "\(keyboard.name) \u{00B7} \(transports): \(mode)"
    }

    /// "Pad 0 scrolling" / "Pad 1 coasting", or nil while idle (an
    /// idle line would be noise — absence reads as idle). With more than
    /// one keyboard present the pad is named with its keyboard — "Go60
    /// Right: Pad 0 scrolling" — since two keyboards can both have a pad 0.
    /// Not with its connection: the pad is the keyboard's either way.
    /// `keyboards` is `status` grouped under `configuration`.
    public static func activityLine(
        for status: RawTouchStatus,
        keyboards: [RawTouchKeyboard],
        configuration: RawTouchConfiguration = .init()
    ) -> String? {
        let padID: UInt8
        let endpointID: RawTouchEndpointID
        let verb: String
        switch status.activity {
        case .idle:
            return nil
        case .touching(let pad, let endpoint):
            (padID, endpointID, verb) = (pad, endpoint, "scrolling")
        case .coasting(let pad, let endpoint):
            (padID, endpointID, verb) = (pad, endpoint, "coasting")
        }
        let deviceKey = status.endpoints.first { $0.id == endpointID }?.deviceKey
        let line = "\(padName(padID, deviceKey: deviceKey, in: configuration)) \(verb)"
        guard keyboards.count > 1,
            let keyboard = keyboards.first(where: { $0.endpoints.contains { $0.id == endpointID } })
        else {
            return line
        }
        return "\(keyboard.name): \(line)"
    }

    /// The one-line reason the icon shows attention, or nil when healthy.
    /// Ordered like `iconState`'s attention triggers so the text always
    /// explains the icon: Accessibility first (nothing works without it),
    /// then firmware without RawTouch-mode support, then a config error —
    /// named, not quoted: a decoder's message is for the log, where it
    /// already is, not for a menu line. What the line does say is the
    /// consequence: while the file cannot be read, changes made in
    /// Settings apply but are not saved over it; when a save fails, they
    /// apply but are not kept.
    public static func attentionLine(
        axTrusted: Bool,
        leaseUnsupportedProductName: String?,
        configError: RawTouchStatus.ConfigError?,
        loginItemError: String? = nil
    ) -> String? {
        if !axTrusted {
            return "Accessibility permission needed"
        }
        if leaseUnsupportedProductName != nil {
            return "Firmware doesn\u{2019}t support RawTouch mode \u{2014} update needed"
        }
        switch configError {
        case .unreadable:
            return "config.json couldn\u{2019}t be read \u{2014} changes aren\u{2019}t saved"
        case .unsaved:
            return "config.json couldn\u{2019}t be saved \u{2014} changes apply but aren\u{2019}t kept"
        case nil:
            break
        }
        if loginItemError != nil {
            // Scrolling is unaffected; the toggle simply did not take.
            // Login Items is where macOS shows what it refused and why.
            return "Start at Login couldn\u{2019}t be changed \u{2014} see Login Items in System Settings"
        }
        return nil
    }
}
