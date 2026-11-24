// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// What the build calls itself, read out of Info.plist. The app is
/// semantically versioned `0.y.z` from its `v*` git tag: the tag without
/// the `v` is `CFBundleShortVersionString`, and the build number is the
/// commit count at that tag, so two builds of one version are tellable
/// apart. A build with no tag behind it (anything `scripts/make-app.sh`
/// makes without `RAWTOUCH_VERSION`) says so: `0.0.0-dev`.
///
/// The script stamps all three keys; the checked-in plist carries
/// placeholders, and `RawTouchGitCommit` is absent from bundles the script
/// did not assemble. Keeping the strings here rather than in the view
/// leaves the About wiring a single call.
public struct AppVersion: Equatable {
    /// `CFBundleShortVersionString` — "0.1.0", or `devShortVersion`.
    public let shortVersion: String

    /// `CFBundleVersion` — the commit count, as digits.
    public let build: String

    /// `RawTouchGitCommit` — the short commit hash, when the bundle has one.
    public let commit: String?

    /// What a build with no release tag behind it calls itself.
    public static let devShortVersion = "0.0.0-dev"

    /// The Info.plist key holding the short commit hash. Custom, so it
    /// carries the app's own prefix.
    public static let commitInfoKey = "RawTouchGitCommit"

    /// The documentation the About panel links to.
    public static let readmeURL = URL(string: "https://github.com/kalakris/rawtouch#readme")!

    /// The credits line that carries `readmeURL`. Named for its destination
    /// rather than showing the raw URL, the way system About panels do.
    public static let readmeLinkText = "Documentation on GitHub"

    public init(shortVersion: String, build: String, commit: String? = nil) {
        self.shortVersion = shortVersion.isEmpty ? Self.devShortVersion : shortVersion
        self.build = build.isEmpty ? "0" : build
        // An absent key and an empty one mean the same thing: no commit
        // (`plutil` happily stamps "" when git could not answer).
        self.commit = (commit?.isEmpty ?? true) ? nil : commit
    }

    /// Reads the three keys, tolerating a bundle that carries none of them
    /// (the bare executable run outside an app bundle, for instance).
    public init(infoDictionary: [String: Any]?) {
        self.init(
            shortVersion: infoDictionary?["CFBundleShortVersionString"] as? String ?? Self.devShortVersion,
            build: infoDictionary?["CFBundleVersion"] as? String ?? "0",
            commit: infoDictionary?[Self.commitInfoKey] as? String
        )
    }

    public init(bundle: Bundle) {
        self.init(infoDictionary: bundle.infoDictionary)
    }

    /// This running build's version, read from the main bundle once: what
    /// the About panel, the update check and its `User-Agent` all go by.
    public static let current = AppVersion(bundle: .main)

    /// The About panel's credits, one string per line: what protocol the
    /// host speaks, the documentation link, and — when the bundle records
    /// one — which commit this is. `readmeLinkText` is the line the caller
    /// turns into a link.
    public func creditLines(protocolVersion: Int) -> [String] {
        var lines = [
            "Speaks protocol \(protocolVersion).",
            Self.readmeLinkText,
        ]
        if let commit {
            lines.append("Build \(commit)")
        }
        return lines
    }
}
