// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

/// A release's version, from its tag: `v0.1.0` or `0.1.0`. Both projects
/// tag `vX.Y.Z` and nothing else is a release, so anything else — a
/// pre-release suffix, a fourth component, `0.0.0-dev` — reads as nil
/// rather than as a version to compare.
public struct ReleaseVersion: Comparable, Hashable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses a tag or a `CFBundleShortVersionString`. A development
    /// build's `0.0.0-dev` (`AppVersion.devShortVersion`) is nil, so a dev
    /// build is never told an app update is out.
    public init?(tag: String) {
        let parts = (tag.hasPrefix("v") ? tag.dropFirst() : Substring(tag))
            .split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in
            part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil
        }
        guard parts.count == 3, numbers.count == 3 else {
            return nil
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }
}

/// The two projects the update check asks about.
public enum ReleaseRepository: CaseIterable {
    /// RawTouch itself.
    case app
    /// The `zmk-raw-touch` firmware module.
    case module

    /// `owner/name` on GitHub.
    public var path: String {
        switch self {
        case .app:
            return "kalakris/rawtouch"
        case .module:
            return "kalakris/zmk-raw-touch"
        }
    }

    /// The GitHub API's latest release: the newest published one, never a
    /// draft or a pre-release.
    public var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(path)/releases/latest")!
    }
}

/// A published release: its version, and its page on GitHub.
public struct LatestRelease: Hashable {
    public var version: ReleaseVersion
    public var url: URL

    public init(version: ReleaseVersion, url: URL) {
        self.version = version
        self.url = url
    }
}

/// What the last successful check found. Nil is "no release yet", which is
/// what GitHub says until a repository publishes its first.
public struct LatestReleases: Equatable {
    public var app: LatestRelease?
    public var module: LatestRelease?

    public init(app: LatestRelease? = nil, module: LatestRelease? = nil) {
        self.app = app
        self.module = module
    }
}

/// One thing the menu offers to update: the app, or one keyboard's
/// firmware. Opening it opens the release's page; nothing is downloaded.
public struct UpdateNotice: Hashable {
    public enum Subject: Hashable {
        case app
        /// A connected keyboard, named as the rest of the menu names it.
        case firmware(keyboard: RawTouchKeyboard.ID, name: String)
    }

    public var subject: Subject
    public var release: LatestRelease

    public init(subject: Subject, release: LatestRelease) {
        self.subject = subject
        self.release = release
    }

    /// "RawTouch 0.1.1 Available…", "Firmware 0.2.0 Available for Go60…".
    public var menuTitle: String {
        wording().menuTitle
    }

    /// Every sentence the menu and the alert say about this notice, built
    /// from one reading of its subject. `installedAppVersion` and
    /// `keyboards` say what the subject runs now; the menu title needs
    /// neither.
    struct Wording {
        /// "RawTouch 0.1.1 Available…"
        var menuTitle: String
        /// The alert's title when this is the only update found: "RawTouch
        /// 0.1.1 is available".
        var alertTitle: String
        /// The alert's message under that title: what is running now.
        var alertMessage: String
        /// One line of the alert that lists several updates: "Firmware
        /// 0.2.0 for Go60 (it runs 0.1)".
        var alertLine: String
    }

    func wording(installedAppVersion: String = "", keyboards: [RawTouchKeyboard] = []) -> Wording {
        let product: String
        let target: String
        let message: String
        let aside: String
        switch subject {
        case .app:
            product = "RawTouch \(release.version)"
            target = ""
            message = "You have \(installedAppVersion)."
            aside = " (you have \(installedAppVersion))"
        case .firmware(let keyboard, let name):
            let running = keyboards.first { $0.id == keyboard }?.oldestReportedModuleVersion
            product = "Firmware \(release.version)"
            target = " for \(name)"
            message =
                (running.map { "It runs \($0). " } ?? "") + "The release page explains how to rebuild and flash it."
            aside = running.map { " (it runs \($0))" } ?? ""
        }
        return Wording(
            menuTitle: "\(product) Available\(target)\u{2026}",
            alertTitle: "\(product) is available\(target)",
            alertMessage: message,
            alertLine: "\(product)\(target)\(aside)"
        )
    }

    /// The notices to show: the app's, when the installed version is older
    /// than the latest release, and one per connected keyboard whose
    /// firmware is.
    ///
    /// Firmware compares **major.minor only**: that is all a keyboard
    /// reports (one packed byte, `RawTouchFirmwareVersion`), so a module
    /// patch release is invisible here by design — 0.2.1 is no news to a
    /// keyboard reporting 0.2. A half that has reported nothing (old
    /// firmware, or a split half not yet touched) is left out rather than
    /// guessed at; a keyboard is out of date when any half it has heard
    /// from is older, since both halves have to run one build anyway.
    ///
    /// A development build (`0.0.0-dev`) has no version to compare and is
    /// never offered the app; its keyboards still are.
    public static func notices(
        installedAppVersion: String,
        releases: LatestReleases,
        keyboards: [RawTouchKeyboard]
    ) -> [UpdateNotice] {
        let installed = ReleaseVersion(tag: installedAppVersion)
        let app = releases.app.flatMap { release in
            installed.map { $0 < release.version } == true ? UpdateNotice(subject: .app, release: release) : nil
        }
        let firmware = releases.module.map { release in
            keyboards
                .filter { $0.reportedModuleVersions.contains { $0.isOlder(than: release.version) } }
                .map { UpdateNotice(subject: .firmware(keyboard: $0.id, name: $0.name), release: release) }
        }
        return [app].compactMap { $0 } + (firmware ?? [])
    }
}

/// The alert that answers "Check for Updates…". The click closes the menu,
/// so a check the user asked for is answered where they are looking; an
/// automatic check never alerts, it only adds the menu's notices.
public struct UpdateCheckReport: Equatable {
    public var title: String
    public var message: String
    /// The pages the first button opens. Empty: the alert only informs,
    /// and its one button is OK.
    public var releasePages: [URL]

    public init(title: String, message: String, releasePages: [URL] = []) {
        self.title = title
        self.message = message
        self.releasePages = releasePages
    }

    /// "View Release", or "View Releases" when it opens more than one.
    public var viewButtonTitle: String {
        releasePages.count > 1 ? "View Releases" : "View Release"
    }

    /// The report for a finished manual check: the updates it found, that
    /// there are none, or that it could not ask.
    public static func report(
        for result: Result<LatestReleases, Error>,
        notices: [UpdateNotice],
        installedAppVersion: String,
        keyboards: [RawTouchKeyboard]
    ) -> UpdateCheckReport {
        let wordings = notices.map { $0.wording(installedAppVersion: installedAppVersion, keyboards: keyboards) }
        switch (result, notices.count) {
        case (.failure(let error), _):
            return failure(rateLimited: isRateLimit(error))
        case (.success(let releases), 0):
            return upToDate(installedAppVersion: installedAppVersion, releases: releases, keyboards: keyboards)
        case (.success, 1):
            return UpdateCheckReport(
                title: wordings[0].alertTitle,
                message: wordings[0].alertMessage,
                releasePages: [notices[0].release.url]
            )
        case (.success, _):
            return UpdateCheckReport(
                title: "Updates are available",
                message: wordings.map(\.alertLine).joined(separator: "\n"),
                releasePages: notices.map(\.release.url)
            )
        }
    }

    /// No update found. Only a subject whose latest release was actually
    /// found is called the newest: a repository with no release yet (or
    /// none visible) proves nothing about what is installed.
    private static func upToDate(
        installedAppVersion: String,
        releases: LatestReleases,
        keyboards: [RawTouchKeyboard]
    ) -> UpdateCheckReport {
        guard ReleaseVersion(tag: installedAppVersion) != nil else {
            return UpdateCheckReport(
                title: "No firmware updates",
                message: "Development builds aren\u{2019}t compared with RawTouch releases."
            )
        }
        // The keyboards whose firmware said which version it runs.
        let reported = keyboards.compactMap { keyboard in
            keyboard.oldestReportedModuleVersion.map { (name: keyboard.name, version: $0) }
        }
        let app = releases.app.map { _ in "RawTouch \(installedAppVersion)" }
        let firmware = releases.module.flatMap { _ -> String? in
            switch reported.count {
            case 0: return nil
            case 1: return "\(reported[0].name)\u{2019}s firmware \(reported[0].version)"
            default: return "your keyboards\u{2019} firmware"
            }
        }
        let named = [app, firmware].compactMap { $0 }
        guard !named.isEmpty else {
            return UpdateCheckReport(
                title: "No releases found",
                message: "GitHub lists no RawTouch release to compare with yet."
            )
        }
        return UpdateCheckReport(
            title: app != nil ? "RawTouch is up to date" : "Firmware is up to date",
            message: named.joined(separator: " and ")
                + (named.count > 1 ? " are the newest releases." : " is the newest release.")
        )
    }

    private static func failure(rateLimited: Bool) -> UpdateCheckReport {
        UpdateCheckReport(
            title: "Couldn\u{2019}t check for updates",
            message: rateLimited
                ? "GitHub is limiting requests from this network. Try again in an hour."
                : "RawTouch couldn\u{2019}t get an answer from GitHub. Check your internet connection and try again."
        )
    }

    /// GitHub answers an anonymous client over its hourly allowance with 403
    /// or 429.
    private static func isRateLimit(_ error: Error) -> Bool {
        switch error as? ReleaseSourceError {
        case .unexpectedStatus(403)?, .unexpectedStatus(429)?:
            return true
        default:
            return false
        }
    }
}

extension RawTouchKeyboard {
    /// Every module version a half of this keyboard has reported over any
    /// of its connections: the central's, and each pad's own half's. A half
    /// that has said nothing is absent.
    var reportedModuleVersions: [RawTouchFirmwareVersion] {
        endpoints.flatMap { endpoint in
            [endpoint.firmwareVersion].compactMap { $0 } + endpoint.padFirmwareVersions.values
        }
    }

    /// The oldest of those: what an update notice says the keyboard runs.
    var oldestReportedModuleVersion: RawTouchFirmwareVersion? {
        reportedModuleVersions.min { ($0.major, $0.minor) < ($1.major, $1.minor) }
    }
}

extension RawTouchFirmwareVersion {
    /// Older than a release, by the major.minor a keyboard can report.
    func isOlder(than release: ReleaseVersion) -> Bool {
        (major, minor) < (release.major, release.minor)
    }
}
