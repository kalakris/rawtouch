// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

// MARK: - Per-keyboard overrides (`devices.<key>`)

extension AppModel {
    /// This keyboard's entry, or an all-inherit blank.
    public func deviceOverrides(_ deviceKey: String) -> RawTouchConfiguration.Device {
        config.devices[deviceKey] ?? .init()
    }

    /// One pad's overrides on this keyboard (`devices.<key>.pads.<id>`),
    /// or an all-inherit blank.
    public func devicePadOverrides(_ deviceKey: String, _ padID: String) -> RawTouchConfiguration.Pad {
        config.devices[deviceKey]?.pads[padID] ?? .init()
    }

    /// Removes a keyboard's entry outright — switch, names, pad overrides
    /// and all: the Keyboards tab's "Remove Settings…", for a connected
    /// keyboard and a saved entry alike. The keyboard goes back to the
    /// top-level settings; nothing is left in the file.
    public func removeDevice(_ deviceKey: String) {
        updateConfig { $0.devices[deviceKey] = nil }
    }

    /// Switches a whole keyboard off (or back on) without touching its pad
    /// overrides. `true` is the inherit default, so switching back on
    /// clears the key rather than storing an explicit `true` — and an entry
    /// left with nothing in it is removed, so a keyboard that was only ever
    /// switched off and on leaves no trace in the file.
    public func setDeviceEnabled(_ deviceKey: String, _ enabled: Bool) {
        updateConfig { config in
            var device = config.devices[deviceKey] ?? .init()
            device.enabled = enabled ? nil : false
            store(device, for: deviceKey, in: &config)
        }
    }

    /// Writes one keyboard's entry, or removes it once it holds nothing
    /// worth keeping. The name is never written from here: it is the
    /// user's, and a keyboard that has not been renamed goes by the name
    /// its firmware reports.
    private func store(
        _ device: RawTouchConfiguration.Device, for deviceKey: String, in config: inout RawTouchConfiguration
    ) {
        config.devices[deviceKey] = device.hasNoOverrides ? nil : device
    }

    /// The Keyboards tab's name for a saved entry whose keyboard is not
    /// connected: the name the user gave it, else a plain description of
    /// what it is. Never the key — a line of hex is an identifier, not a
    /// name, and the page has a "Saved as" row that says it properly.
    public func savedEntryName(_ deviceKey: String) -> String {
        RawTouchConfiguration.usableName(config.devices[deviceKey]?.name) ?? "Saved keyboard"
    }

    /// Names a pad (`devices.<key>.pads.<id>.name`), trimmed and capped at
    /// `RawTouchConfiguration.nameLimit`. An empty name removes the key, so
    /// clearing the heading puts the pad back to the firmware's own
    /// numbering.
    public func setPadName(_ deviceKey: String, _ padID: String, _ name: String) {
        updateDevicePad(deviceKey, padID) { $0.name = Self.storableName(name) }
    }

    /// Names a keyboard (`devices.<key>.name`), by the same rules. An
    /// empty name removes the key, so clearing the heading puts the
    /// keyboard back to the name its firmware reports.
    public func setKeyboardName(_ deviceKey: String, _ name: String) {
        updateConfig { config in
            var device = config.devices[deviceKey] ?? .init()
            device.name = Self.storableName(name)
            store(device, for: deviceKey, in: &config)
        }
    }

    /// What a UI's text ends up as in the file: trimmed, capped, and nil
    /// when there is nothing left — the one place both names go through.
    private static func storableName(_ name: String) -> String? {
        RawTouchConfiguration.usableName(String(name.prefix(RawTouchConfiguration.nameLimit)))
    }

    /// Mutates one pad's overrides for one keyboard. A pad left with no
    /// overrides is removed from that keyboard's `pads`, and an entry left
    /// with nothing in it is removed too, so a pad set back to its
    /// inherited values leaves no trace in the file.
    public func updateDevicePad(
        _ deviceKey: String,
        _ padID: String,
        _ mutate: (inout RawTouchConfiguration.Pad) -> Void
    ) {
        updateConfig { config in
            var device = config.devices[deviceKey] ?? .init()
            var pad = device.pads[padID] ?? .init()
            mutate(&pad)
            device.pads[padID] = pad == RawTouchConfiguration.Pad() ? nil : pad
            store(device, for: deviceKey, in: &config)
        }
    }

    // MARK: - Section resets

    /// Clears one pad's per-keyboard overrides, keeping the keyboard's
    /// entry (and its other pads).
    public func resetDevicePad(_ deviceKey: String, _ padID: String) {
        updateDevicePad(deviceKey, padID) { $0 = .init() }
    }

    // MARK: - Per-tab restore (the settings window's one button per tab)

    /// The Scrolling tab: gain, direction and all of momentum, the
    /// lift-off strength floor included.
    public func restoreScrollingDefaults() {
        let defaults = RawTouchConfiguration()
        updateConfig {
            $0.scale = defaults.scale
            $0.reverseScrolling = defaults.reverseScrolling
            $0.momentum = .init()
        }
    }

    /// The Advanced tab: acceleration, display sync and the update check.
    public func restoreAdvancedDefaults() {
        updateConfig {
            $0.acceleration = .init()
            $0.resampling = .init()
            $0.updates = .init()
        }
    }
}
