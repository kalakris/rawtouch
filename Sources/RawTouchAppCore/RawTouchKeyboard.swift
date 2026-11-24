// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

/// One physical keyboard, as the app shows it: the endpoints RawTouch has
/// for it — USB, Bluetooth, or both — under the one key its settings live
/// at.
///
/// `RawTouchStatus.endpoints` is per connection, because that is what a
/// lease, a clock and a watchdog belong to. Nothing a user sets is: a
/// keyboard is one thing whether it is plugged in or paired, and protocol 4
/// firmware says so itself by reporting the same hardware id over both. So
/// the settings window and the menu work in these, and the runtime keeps
/// working in endpoints.
public struct RawTouchKeyboard: Equatable, Identifiable {
    /// What a picker can hold onto: the key when there is one, else the
    /// single endpoint that has none.
    public enum ID: Hashable {
        case key(String)
        case endpoint(RawTouchEndpointID)
    }

    public var id: ID
    /// The key its settings live under (`devices.<key>`), or nil when the
    /// keyboard has nothing stable to be keyed by.
    public var key: String?
    /// What to call it: the name the user gave it
    /// (`devices.<key>.name`), else the product name its firmware reports —
    /// plus the transport when the key is a per-transport one (that
    /// entry *is* one connection), plus the tail of the key when another
    /// connected keyboard reads the same.
    public var name: String
    /// What it is called when it has no name of its own: the product name
    /// its firmware reports (plus the transport for a per-connection key).
    /// What a heading being renamed offers as its placeholder, so clearing
    /// the field shows what clearing it will restore.
    public var defaultName: String
    /// Its connections, in connect order.
    public var endpoints: [RawTouchStatus.Endpoint]
    /// Every pad any of its connections reports, ascending. A relayed pad
    /// can be missing from one connection's report and present in the
    /// other's, and it is the same pad either way.
    public var padIDs: [UInt8]
    /// The hardware id its firmware reports, or nil.
    public var deviceID: String?

    public var transports: [RawTouchTransport] {
        endpoints.map(\.transport)
    }

    /// Every connection agrees about RawTouch mode.
    public var leasesAgree: Bool {
        endpoints.dropFirst().allSatisfy { $0.lease == endpoints.first?.lease }
    }

    /// Whether settings can be written for it at all: it needs a key, and
    /// firmware that has RawTouch mode.
    public var editableKey: String? {
        guard endpoints.contains(where: { $0.lease != .unsupportedFirmware }) else {
            return nil
        }
        return key
    }

    /// Groups a status snapshot's endpoints into keyboards, keeping connect
    /// order. Endpoints sharing a device key are one keyboard; an endpoint
    /// without a key is its own, since nothing says it is any other.
    ///
    /// The configuration comes in because a keyboard's name can be the
    /// user's: it is resolved here, once, so the picker, the headings, the
    /// menu, the readout and the latency row all say the same thing — and
    /// so that two keyboards are told apart by the tail of their key only
    /// while the names actually on screen collide.
    public static func grouped(
        in status: RawTouchStatus,
        configuration: RawTouchConfiguration = .init()
    ) -> [RawTouchKeyboard] {
        var order: [ID] = []
        var groups: [ID: [RawTouchStatus.Endpoint]] = [:]
        for endpoint in status.endpoints {
            let id = endpoint.deviceKey.map(ID.key) ?? .endpoint(endpoint.id)
            if groups[id] == nil {
                order.append(id)
            }
            groups[id, default: []].append(endpoint)
        }

        let keyboards = order.map { id -> RawTouchKeyboard in
            let endpoints = groups[id] ?? []
            let key = endpoints.first?.deviceKey
            let defaultName = baseName(of: endpoints, key: key)
            return RawTouchKeyboard(
                id: id,
                key: key,
                name: configuration.configuredKeyboardName(forDeviceKey: key) ?? defaultName,
                defaultName: defaultName,
                endpoints: endpoints,
                padIDs: Set(endpoints.flatMap(\.padIDs)).sorted(),
                deviceID: endpoints.compactMap(\.deviceID).first
            )
        }

        // Two keyboards reading alike — two of the same model — are told
        // apart by the tail of their key.
        let counts = keyboards.reduce(into: [String: Int]()) { $0[$1.name, default: 0] += 1 }
        return keyboards.map { keyboard in
            guard counts[keyboard.name] ?? 0 > 1 else {
                return keyboard
            }
            var named = keyboard
            let suffix =
                keyboard.key.map(RawTouchDeviceKey.shortSuffix(of:))
                ?? "#\(keyboard.endpoints.first?.id.rawValue ?? 0)"
            named.name = "\(keyboard.name) (\(suffix))"
            return named
        }
    }

    /// The product name, with the transport appended when the entry is
    /// keyed per transport (a keyboard whose firmware reports no hardware
    /// id): that entry really is one connection's, and saying so is what
    /// keeps its two entries apart.
    private static func baseName(of endpoints: [RawTouchStatus.Endpoint], key: String?) -> String {
        guard let endpoint = endpoints.first else {
            return ""
        }
        guard let key, !RawTouchDeviceKey.isHardwareID(key), let transport = endpoint.transport.displayName else {
            return endpoint.productName
        }
        return "\(endpoint.productName) \u{00B7} \(transport)"
    }
}

/// What the Keyboards tab is pointed at: a connected keyboard, or a saved
/// entry for one that is not connected right now.
///
/// The rule the view follows, kept here so it can be tested: the tab opens
/// on the keyboard that last scrolled, and then **stays put**. Following
/// the last-used keyboard is right at the moment the window opens — the
/// keyboard you just flicked is the one you came to adjust — and wrong
/// afterwards, when it would move the page out from under a hand already
/// on a slider. So `resolve` never looks at `lastScrolled` once a selection
/// exists; it only falls back when the selected keyboard goes away, which
/// beats blanking the tab.
public enum KeyboardsTabSelection: Hashable {
    case keyboard(RawTouchKeyboard.ID)
    case saved(String)

    /// Whether this selection still names something that exists.
    public func isAvailable(keyboards: [RawTouchKeyboard], savedKeys: [String]) -> Bool {
        switch self {
        case .keyboard(let id):
            return keyboards.contains { $0.id == id }
        case .saved(let key):
            return savedKeys.contains(key)
        }
    }

    /// What the tab shows when it opens, and what it falls back to: the
    /// keyboard that last scrolled, else the first connected one, else the
    /// first saved entry, else nothing at all.
    public static func initial(
        keyboards: [RawTouchKeyboard],
        savedKeys: [String],
        lastScrolled: RawTouchKeyboard.ID?
    ) -> KeyboardsTabSelection? {
        if let lastScrolled, keyboards.contains(where: { $0.id == lastScrolled }) {
            return .keyboard(lastScrolled)
        }
        if let first = keyboards.first {
            return .keyboard(first.id)
        }
        return savedKeys.first.map(KeyboardsTabSelection.saved)
    }

    /// What to show now, given what the user (or the seeding) picked.
    public static func resolve(
        picked: KeyboardsTabSelection?,
        keyboards: [RawTouchKeyboard],
        savedKeys: [String],
        lastScrolled: RawTouchKeyboard.ID?
    ) -> KeyboardsTabSelection? {
        guard let picked, picked.isAvailable(keyboards: keyboards, savedKeys: savedKeys) else {
            return initial(keyboards: keyboards, savedKeys: savedKeys, lastScrolled: lastScrolled)
        }
        return picked
    }
}
