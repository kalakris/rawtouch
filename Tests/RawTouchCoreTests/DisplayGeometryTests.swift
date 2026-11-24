// MIT License
// Copyright (c) 2026 RawTouch contributors

import CoreGraphics
import XCTest

@testable import RawTouchCore

/// `DisplayGeometry`'s one branch that can be pinned without a real
/// display: what happens when CoreGraphics reports no geometry at all.
/// Everything else is a straight read of the running display and is
/// exercised by the pipeline through an injected provider.
final class DisplayGeometryTests: XCTestCase {
    /// A display with no bounds and no physical size — what a virtual
    /// display, or an external whose EDID is unusable, looks like — must
    /// not yield a zero or infinite gain. It borrows the main display's
    /// density: a panel on the same desk is a better guess about what a
    /// millimetre means than any constant. (Only when *that* says nothing
    /// either does the constant stand in, which no machine with a screen
    /// can exercise.)
    ///
    /// An ID no display can hold stands in for the unusable one:
    /// CoreGraphics answers zero for both. (`kCGNullDirectDisplay` is *not*
    /// usable here — ID 0 aliases to the main display.)
    func testADisplayWithNoReportedGeometryBorrowsTheMainDisplays() {
        XCTAssertEqual(
            DisplayGeometry.pointsPerMM(of: CGDirectDisplayID(0xDEAD_BEEF)),
            DisplayGeometry.pointsPerMM(of: CGMainDisplayID())
        )
        XCTAssertGreaterThan(DisplayGeometry.pointsPerMM(of: CGDirectDisplayID(0xDEAD_BEEF)), 0)
    }

    /// The fallback has to be a usable density: `pointsPerCount` divides by
    /// the pad's counts/mm, so a zero or negative here would silently kill
    /// scrolling on any display that reports no size.
    func testTheFallbackDensityIsPositive() {
        XCTAssertGreaterThan(DisplayGeometry.fallbackPointsPerMM, 0)
    }
}
