// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "rawtouch",
    platforms: [
        // macOS 13 is the floor for the APIs used: CGEvent/IOHID/Foundation
        // are all far older, and the app layer sticks to macOS 13 SwiftUI
        // (MenuBarExtra, Window scenes, SMAppService — deliberately no
        // SettingsLink/@Observable).
        .macOS(.v13)
    ],
    products: [
        .executable(name: "RawTouchApp", targets: ["RawTouchApp"]),
        .library(name: "RawTouchCore", targets: ["RawTouchCore"]),
    ],
    targets: [
        .target(
            name: "RawTouchCore",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOKit"),
            ]
        ),
        // The menubar app's model layer: everything the app does that is not
        // literally a view, kept out of the executable so it is unit-testable
        // without a running app (and without IOKit, AX prompts or login-item
        // registration — every system dependency is injectable).
        .target(
            name: "RawTouchAppCore",
            dependencies: ["RawTouchCore"],
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        // Test-only helpers shared by both test targets and the offline
        // bench: the hand-driven display ticker, the frame fixtures and
        // event-capture doubles, the deterministic PRNG, the fake device
        // manager. Deliberately not a product, and nothing that ships
        // depends on it — RawTouchCore in particular must not.
        .target(name: "RawTouchTestSupport", dependencies: ["RawTouchCore"]),
        // Thin SwiftUI views over RawTouchAppCore; assembled into
        // RawTouch.app by scripts/make-app.sh.
        .executableTarget(name: "RawTouchApp", dependencies: ["RawTouchAppCore"]),
        // Bench harness: posts synthetic RawTouch scroll gestures for
        // experiments against real apps (see bench/). Development-only, so
        // deliberately not a product.
        .executableTarget(name: "scroll-bench", dependencies: ["RawTouchCore", "RawTouchTestSupport"]),
        .testTarget(name: "RawTouchCoreTests", dependencies: ["RawTouchCore", "RawTouchTestSupport"]),
        .testTarget(name: "RawTouchAppCoreTests", dependencies: ["RawTouchAppCore", "RawTouchTestSupport"]),
    ]
)
