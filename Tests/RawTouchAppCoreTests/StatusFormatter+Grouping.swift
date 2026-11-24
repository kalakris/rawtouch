// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchAppCore
import RawTouchCore

/// The formatters that read keyboards take them already grouped, as
/// `AppModel.settingsKeyboards` holds them. These test shorthands group a
/// status snapshot the way the model does, so a test states only the
/// snapshot.
extension StatusFormatter {
    static func keyboardLines(
        for status: RawTouchStatus,
        configuration: RawTouchConfiguration = .init()
    ) -> [String] {
        keyboardLines(for: RawTouchKeyboard.grouped(in: status, configuration: configuration))
    }

    static func activityLine(
        for status: RawTouchStatus,
        configuration: RawTouchConfiguration = .init()
    ) -> String? {
        activityLine(
            for: status,
            keyboards: RawTouchKeyboard.grouped(in: status, configuration: configuration),
            configuration: configuration
        )
    }

    static func gestureSourceLine(
        _ gesture: RawTouchGestureSummary,
        in status: RawTouchStatus,
        configuration: RawTouchConfiguration = .init()
    ) -> String {
        gestureSourceLine(
            gesture,
            keyboards: RawTouchKeyboard.grouped(in: status, configuration: configuration),
            configuration: configuration
        )
    }
}
