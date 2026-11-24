// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).

import Foundation

/// Reads the system-wide Natural Scrolling preference ("Natural scrolling" in
/// System Settings → Mouse/Trackpad), stored in the global domain as
/// `com.apple.swipescrolldirection`.
///
/// macOS applies this preference to hardware scroll input upstream of event
/// taps, so tapped wheel events already carry it. Synthetic events posted by
/// RawTouch bypass it entirely, so consumers that synthesize scrolling from
/// raw device coordinates must read it here and bake it into their output
/// sign.
public enum SystemScrollingPreference {
    public static let swipeScrollDirectionKey = "com.apple.swipescrolldirection"

    /// Posted by the system (as a distributed notification) when the Natural
    /// Scrolling checkbox changes.
    public static let didChangeNotification = Notification.Name("SwipeScrollDirectionDidChangeNotification")

    /// Whether the user prefers natural ("content follows fingers")
    /// scrolling. The key is absent until the user first touches the
    /// checkbox; the modern-macOS default is natural on.
    public static func prefersNatural() -> Bool {
        guard
            let value = CFPreferencesCopyAppValue(
                swipeScrollDirectionKey as CFString,
                kCFPreferencesAnyApplication
            ) as? Bool
        else {
            return true
        }

        return value
    }
}
