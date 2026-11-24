// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchCore
import XCTest

@testable import RawTouchAppCore

/// The update check's pure parts: reading a release tag, and deciding what
/// the menu offers from the installed app, the latest releases and the
/// keyboards connected.
final class UpdateCheckTests: XCTestCase {
    // MARK: - Release versions

    func testATagReadsWithOrWithoutItsV() {
        XCTAssertEqual(ReleaseVersion(tag: "v0.1.0"), ReleaseVersion(major: 0, minor: 1, patch: 0))
        XCTAssertEqual(ReleaseVersion(tag: "0.1.0"), ReleaseVersion(major: 0, minor: 1, patch: 0))
        XCTAssertEqual(ReleaseVersion(tag: "v12.34.56"), ReleaseVersion(major: 12, minor: 34, patch: 56))
    }

    /// A development build has no version to compare, so it is never told
    /// an app update is out.
    func testADevelopmentBuildHasNoReleaseVersion() {
        XCTAssertNil(ReleaseVersion(tag: AppVersion.devShortVersion))
    }

    func testAnythingButAPlainTripleIsNotARelease() {
        for tag in [
            "", "v", "0.1", "v0.1", "0.1.0.0", "v0.2.0-rc1", "0.1.0+build", "stable", "v0..1", "va.b.c", "0.1.+1",
            "0.1. 1", "V0.1.0", "v99999999999999999999.0.0",
        ] {
            XCTAssertNil(ReleaseVersion(tag: tag), tag)
        }
    }

    func testVersionsOrderNumericallyNotAsText() {
        let ordered = ["0.1.0", "0.1.1", "0.1.10", "0.2.0", "0.10.0", "1.0.0"].map { ReleaseVersion(tag: $0)! }
        XCTAssertEqual(ordered.shuffled().sorted(), ordered)
        XCTAssertFalse(ReleaseVersion(tag: "0.1.0")! < ReleaseVersion(tag: "v0.1.0")!)
        XCTAssertEqual(ReleaseVersion(tag: "v0.10.2")?.description, "0.10.2")
    }

    // MARK: - The decision

    /// One keyboard for the table: its name, and the module version each
    /// half has reported (nil = not said yet).
    private struct Board {
        var name: String
        var central: RawTouchFirmwareVersion?
        var pads: [UInt8: RawTouchFirmwareVersion?] = [:]
    }

    private func keyboards(_ boards: [Board]) -> [RawTouchKeyboard] {
        let endpoints = boards.enumerated().map { index, board in
            RawTouchStatus.Endpoint(
                id: RawTouchEndpointID(rawValue: UInt64(index + 1)),
                productName: board.name,
                transport: .usb,
                padIDs: board.pads.keys.sorted(),
                firmwareVersion: board.central,
                padFirmwareVersions: board.pads.compactMapValues { $0 },
                deviceKey: "id:\(index + 1)",
                lease: .held
            )
        }
        return RawTouchKeyboard.grouped(in: RawTouchStatus(endpoints: endpoints))
    }

    private func firmware(_ major: Int, _ minor: Int) -> RawTouchFirmwareVersion {
        RawTouchFirmwareVersion(major: major, minor: minor)
    }

    func testTheNoticesFollowTheTable() {
        let app = publishedRelease("v0.2.0")
        let module = publishedRelease("v0.2.1", repository: .module)
        let cases: [(String, installed: String, LatestReleases, [Board], [String])] = [
            ("no releases yet", "0.1.0", .init(), [Board(name: "Go60", central: firmware(0, 1))], []),
            ("app older", "0.1.9", .init(app: app), [], ["RawTouch 0.2.0 Available\u{2026}"]),
            ("app same", "0.2.0", .init(app: app), [], []),
            ("app newer", "0.3.0", .init(app: app), [], []),
            ("dev build", AppVersion.devShortVersion, .init(app: app), [], []),
            (
                "module newer minor", "0.2.0", .init(module: module), [Board(name: "Go60", central: firmware(0, 1))],
                ["Firmware 0.2.1 Available for Go60\u{2026}"]
            ),
            (
                "module newer major", "0.2.0", .init(module: publishedRelease("v1.0.0", repository: .module)),
                [Board(name: "Go60", central: firmware(0, 9))], ["Firmware 1.0.0 Available for Go60\u{2026}"]
            ),
            (
                "module patch release is invisible", "0.2.0", .init(module: module),
                [Board(name: "Go60", central: firmware(0, 2))], []
            ),
            (
                "keyboard newer than release", "0.2.0", .init(module: module),
                [Board(name: "Go60", central: firmware(0, 3))], []
            ),
            (
                "version unknown", "0.2.0", .init(module: module), [Board(name: "Go60", central: nil, pads: [0: nil])],
                []
            ),
            (
                "split, unknown half is skipped", "0.2.0", .init(module: module),
                [Board(name: "Go60", central: firmware(0, 2), pads: [0: firmware(0, 2), 1: nil])], []
            ),
            (
                "split, one half older", "0.2.0", .init(module: module),
                [Board(name: "Go60", central: firmware(0, 2), pads: [0: firmware(0, 2), 1: firmware(0, 1)])],
                ["Firmware 0.2.1 Available for Go60\u{2026}"]
            ),
            (
                "one notice per keyboard, app first", "0.1.0", .init(app: app, module: module),
                [
                    Board(name: "Go60", central: firmware(0, 1), pads: [0: firmware(0, 1), 1: firmware(0, 1)]),
                    Board(name: "Sofle", central: firmware(0, 2)),
                    Board(name: "Corne", central: firmware(0, 1)),
                ],
                [
                    "RawTouch 0.2.0 Available\u{2026}", "Firmware 0.2.1 Available for Go60\u{2026}",
                    "Firmware 0.2.1 Available for Corne\u{2026}",
                ]
            ),
            ("no keyboards", "0.2.0", .init(module: module), [], []),
        ]

        for (name, installed, releases, boards, expected) in cases {
            let notices = UpdateNotice.notices(
                installedAppVersion: installed, releases: releases, keyboards: keyboards(boards))
            XCTAssertEqual(notices.map(\.menuTitle), expected, name)
        }
    }

    /// The notices carry what the menu needs: the page to open, and which
    /// keyboard a firmware notice is about.
    func testANoticeOpensItsReleasePage() {
        let module = publishedRelease("v0.2.0", repository: .module)
        let boards = keyboards([Board(name: "Go60", central: firmware(0, 1))])

        let notices = UpdateNotice.notices(
            installedAppVersion: "0.1.0", releases: .init(module: module), keyboards: boards)

        XCTAssertEqual(
            notices, [UpdateNotice(subject: .firmware(keyboard: boards[0].id, name: "Go60"), release: module)])
        XCTAssertEqual(
            notices.first?.release.url.absoluteString, "https://github.com/kalakris/zmk-raw-touch/releases/tag/v0.2.0")
    }

    // MARK: - The alert a manual check answers with

    func testTheReportFollowsTheTable() {
        let app = publishedRelease("v0.2.0")
        let module = publishedRelease("v0.2.1", repository: .module)
        // Both found, neither newer than what runs.
        let current = LatestReleases(app: app, module: publishedRelease("v0.1.0", repository: .module))
        let go60 = Board(name: "Go60", central: firmware(0, 2), pads: [0: firmware(0, 2), 1: firmware(0, 1)])
        let sofle = Board(name: "Sofle", central: firmware(0, 1))
        let cases:
            [(String, Result<LatestReleases, Error>, installed: String, [Board], title: String, message: String, Int)] =
                [
                    (
                        "unreachable", .failure(FakeReleaseSource.Unreachable()), "0.1.0", [go60],
                        "Couldn\u{2019}t check for updates",
                        "RawTouch couldn\u{2019}t get an answer from GitHub. Check your internet connection and try again.",
                        0
                    ),
                    (
                        "rate limited", .failure(ReleaseSourceError.unexpectedStatus(403)), "0.1.0", [],
                        "Couldn\u{2019}t check for updates",
                        "GitHub is limiting requests from this network. Try again in an hour.", 0
                    ),
                    (
                        "up to date, no keyboard", .success(.init(app: app)), "0.2.0", [],
                        "RawTouch is up to date", "RawTouch 0.2.0 is the newest release.", 0
                    ),
                    (
                        "up to date, one keyboard", .success(current), "0.2.0", [sofle],
                        "RawTouch is up to date",
                        "RawTouch 0.2.0 and Sofle\u{2019}s firmware 0.1 are the newest releases.", 0
                    ),
                    (
                        "up to date, two keyboards", .success(current), "0.2.0",
                        [sofle, Board(name: "Corne", central: nil)],
                        "RawTouch is up to date",
                        "RawTouch 0.2.0 and Sofle\u{2019}s firmware 0.1 are the newest releases.", 0
                    ),
                    (
                        "no module release: the firmware is not called newest", .success(.init(app: app)), "0.2.0",
                        [sofle],
                        "RawTouch is up to date", "RawTouch 0.2.0 is the newest release.", 0
                    ),
                    (
                        "no app release: the app is not called newest",
                        .success(.init(module: publishedRelease("v0.1.0", repository: .module))), "0.2.0", [sofle],
                        "Firmware is up to date", "Sofle\u{2019}s firmware 0.1 is the newest release.", 0
                    ),
                    (
                        "no release at all", .success(.init()), "0.2.0", [sofle],
                        "No releases found", "GitHub lists no RawTouch release to compare with yet.", 0
                    ),
                    (
                        "up to date, two reporting keyboards", .success(current), "0.2.0",
                        [sofle, Board(name: "Corne", central: firmware(0, 1))],
                        "RawTouch is up to date",
                        "RawTouch 0.2.0 and your keyboards\u{2019} firmware are the newest releases.", 0
                    ),
                    (
                        "development build", .success(.init(app: app)), AppVersion.devShortVersion, [sofle],
                        "No firmware updates", "Development builds aren\u{2019}t compared with RawTouch releases.", 0
                    ),
                    (
                        "app update", .success(.init(app: app)), "0.1.0", [],
                        "RawTouch 0.2.0 is available", "You have 0.1.0.", 1
                    ),
                    (
                        "firmware update names the oldest half", .success(.init(module: module)), "0.1.0", [go60],
                        "Firmware 0.2.1 is available for Go60",
                        "It runs 0.1. The release page explains how to rebuild and flash it.", 1
                    ),
                    (
                        "several updates", .success(.init(app: app, module: module)), "0.1.0", [go60, sofle],
                        "Updates are available",
                        "RawTouch 0.2.0 (you have 0.1.0)\nFirmware 0.2.1 for Go60 (it runs 0.1)\nFirmware 0.2.1 for Sofle (it runs 0.1)",
                        3
                    ),
                ]

        for (name, result, installed, boards, title, message, pages) in cases {
            let connected = keyboards(boards)
            let releases = (try? result.get()) ?? LatestReleases()
            let report = UpdateCheckReport.report(
                for: result,
                notices: UpdateNotice.notices(installedAppVersion: installed, releases: releases, keyboards: connected),
                installedAppVersion: installed,
                keyboards: connected
            )
            XCTAssertEqual(report.title, title, name)
            XCTAssertEqual(report.message, message, name)
            XCTAssertEqual(report.releasePages.count, pages, name)
        }
    }

    func testTheViewButtonCountsItsPages() {
        let page = URL(string: "https://github.com/kalakris/rawtouch/releases/tag/v0.2.0")!
        XCTAssertEqual(UpdateCheckReport(title: "", message: "", releasePages: [page]).viewButtonTitle, "View Release")
        XCTAssertEqual(
            UpdateCheckReport(title: "", message: "", releasePages: [page, page]).viewButtonTitle, "View Releases")
    }
}
