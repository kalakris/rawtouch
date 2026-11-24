// MIT License
// Copyright (c) 2026 RawTouch contributors

import XCTest

@testable import RawTouchAppCore

/// The version scheme the About panel states: `0.y.z` from the release tag,
/// the commit count as the build number, `0.0.0-dev` when there is no tag.
final class AppVersionTests: XCTestCase {
    // MARK: - Reading Info.plist

    func testReadsTheThreeKeys() {
        let version = AppVersion(infoDictionary: [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "42",
            "RawTouchGitCommit": "a1b2c3d",
        ])

        XCTAssertEqual(version.shortVersion, "0.1.0")
        XCTAssertEqual(version.build, "42")
        XCTAssertEqual(version.commit, "a1b2c3d")
    }

    func testBundleWithoutTheKeysReadsAsADevBuild() {
        let version = AppVersion(infoDictionary: nil)

        XCTAssertEqual(version.shortVersion, AppVersion.devShortVersion)
        XCTAssertEqual(version.build, "0")
        XCTAssertNil(version.commit)
    }

    func testEmptyCommitCountsAsNoCommit() {
        let version = AppVersion(shortVersion: "0.1.0", build: "42", commit: "")

        XCTAssertNil(version.commit)
    }

    // MARK: - About credits

    func testCreditsStateTheProtocolAndLinkTheDocumentation() {
        let version = AppVersion(shortVersion: "0.1.0", build: "42")

        XCTAssertEqual(
            version.creditLines(protocolVersion: 3),
            [
                "Speaks protocol 3.",
                AppVersion.readmeLinkText,
            ])
    }

    func testCreditsCarryTheProtocolTheHostActuallySpeaks() {
        let lines = AppVersion(shortVersion: "0.1.0", build: "42").creditLines(protocolVersion: 4)

        XCTAssertEqual(lines.first, "Speaks protocol 4.")
    }

    func testCreditsAppendTheBuildWhenTheBundleRecordsACommit() {
        let version = AppVersion(shortVersion: "0.0.0-dev", build: "17", commit: "a1b2c3d")

        XCTAssertEqual(
            version.creditLines(protocolVersion: 3),
            [
                "Speaks protocol 3.",
                AppVersion.readmeLinkText,
                "Build a1b2c3d",
            ])
    }

    func testTheDocumentationLinkPointsAtTheReadme() {
        XCTAssertEqual(
            AppVersion.readmeURL.absoluteString,
            "https://github.com/kalakris/rawtouch#readme"
        )
    }
}
