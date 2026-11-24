// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).

import AppKit
import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// Hands a poster engine events on a steady cadence — the pad's 10 ms
/// unless stated — the timeline its began rules are measured on: each
/// event is one frame after the one before.
final class Cadence {
    let poster: RawTouchScrollPoster
    let period: TimeInterval
    private(set) var time: TimeInterval = 0

    init(_ poster: RawTouchScrollPoster, period: TimeInterval = 0.01) {
        self.poster = poster
        self.period = period
    }

    func post(_ event: TouchScrollEngine.Event) {
        poster.post(event, at: time)
        time += period
    }
}

final class RawTouchScrollPosterTests: XCTestCase {
    // MARK: - RawTouch's own windows

    /// Tuning scroll feel means flicking the pad while watching the
    /// settings window's readout — which would otherwise scroll the form
    /// out from under the slider being dragged. A gesture that starts over
    /// one of our own windows posts nothing at all, momentum included.
    func testAGestureOverOurOwnWindowPostsNothing() {
        let captured = CapturedScrollEvents()
        let ownership = FakePointerWindowOwnership(isOverOwnWindow: true)
        let poster = Cadence(captured.makePoster(windowOwnership: ownership))

        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 0, deltaY: 40),
            .touchEnded,
            .momentumBegan(deltaX: 0, deltaY: 30),
            .momentumChanged(deltaX: 0, deltaY: 10),
            .momentumEnded,
        ] {
            poster.post(event)
        }

        XCTAssertTrue(captured.events.isEmpty, "not even the gesture series opened")
        XCTAssertEqual(ownership.callCount, 1, "asked once, at touch-down \u{2014} never per frame")
    }

    /// The decision is the gesture's: a window that comes up under the
    /// pointer mid-flick does not stop it, and the next gesture decides
    /// afresh.
    func testTheDecisionIsMadeOncePerGesture() {
        let captured = CapturedScrollEvents()
        let ownership = FakePointerWindowOwnership(isOverOwnWindow: false)
        let poster = Cadence(captured.makePoster(windowOwnership: ownership))

        poster.post(.touchBegan)
        ownership.isOverOwnWindow = true
        poster.post(.touchChanged(deltaX: 0, deltaY: 40))
        poster.post(.touchEnded)
        XCTAssertEqual(captured.scrollPhases, [.began, .ended])

        captured.reset()
        poster.post(.touchBegan)
        poster.post(.touchChanged(deltaX: 0, deltaY: 40))
        poster.post(.touchEnded)
        XCTAssertTrue(captured.events.isEmpty, "the next gesture starts over our window and stays silent")
        XCTAssertEqual(ownership.callCount, 2)
    }

    func testTheBeganWaitsForTheFirstNonZeroDelta() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        // A finger that rests for two frames before moving — routine with
        // display-rate resampling, where the frame after the touch-down
        // often precedes the pad's second sample.
        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 0, deltaY: 0),
            .touchChanged(deltaX: 0, deltaY: 0),
            .touchChanged(deltaX: 0, deltaY: 6),
            .touchChanged(deltaX: 0, deltaY: 0),
            .touchEnded,
        ] {
            poster.post(event)
        }

        let views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.scrollPhase), [.began, .changed, .ended])
        XCTAssertEqual(
            views.map(\.deltaYFixedPt), [6, 0, 0], "the began carries the first real motion; later rests still post")
        // The gesture series (mayBegin + series start) still opened at
        // touch-down, ahead of the first scroll event.
        XCTAssertNotEqual(captured.events.first?.type, .scrollWheel)
        XCTAssertGreaterThan(captured.events.count, views.count)
    }

    func testCatchSequencePostsWellFormedPhases() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        // Flick, momentum, then catch and a fresh drag. The touches carry
        // a whisper of sideways motion, as a real finger's do: with it the
        // direction is clear on the first frame (a bare zero would wait
        // for a second frame — see `beganPending`).
        let sequence: [TouchScrollEngine.Event] = [
            .touchBegan,
            .touchChanged(deltaX: 0.1, deltaY: 24),
            .touchEnded,
            .momentumBegan(deltaX: 0, deltaY: 12),
            .momentumChanged(deltaX: 0, deltaY: 8),
            .momentumEnded,
            .touchBegan,
            .touchChanged(deltaX: 0.1, deltaY: -8),
            .touchEnded,
        ]
        for event in sequence {
            poster.post(event)
        }

        // A touch-down posts no scroll event: the began is deferred to the
        // first movement and carries its delta (WebKit drops a zero-delta
        // began before it can reset its rubber-band state).
        let views = captured.scrollWheelViews
        XCTAssertEqual(views.count, 7)

        let expectedScrollPhases: [CGScrollPhase?] = [
            .began, .ended, nil, nil, nil, .began, .ended,
        ]
        let expectedMomentumPhases: [CGMomentumScrollPhase] = [
            .none, .none, .begin, .continuous, .end, .none, .none,
        ]
        for (index, view) in views.enumerated() {
            XCTAssertEqual(view.scrollPhase, expectedScrollPhases[index], "index \(index)")
            XCTAssertEqual(view.momentumPhase, expectedMomentumPhases[index], "index \(index)")
            XCTAssertTrue(view.continuous)
        }

        XCTAssertEqual(views[0].deltaYFixedPt, 24)  // the began carries the first delta
        XCTAssertEqual(views[2].deltaYFixedPt, 12)
        XCTAssertEqual(views[5].deltaYFixedPt, -8)

        // Every scroll event carries RawTouch's synthetic marker.
        XCTAssertTrue(
            captured.events
                .filter { $0.type == .scrollWheel }
                .allSatisfy(\.isRawTouchSyntheticEvent))

        // Gesture-series companions are emitted alongside touch phases (the
        // non-scrollWheel gesture events).
        XCTAssertGreaterThan(captured.events.count, views.count)
    }

    func testTouchWithoutMovementEndsAsCancelled() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        poster.post(.touchBegan)
        let afterTouchDown = captured.events.count
        poster.post(.touchEnded)

        // Touch-down: mayBegin + series start only, no scroll event. A lift
        // with no movement never began, so it ends as cancelled — the
        // sequence a real trackpad sends for a rest-and-lift.
        XCTAssertEqual(afterTouchDown, 2)
        XCTAssertTrue(captured.events.prefix(2).allSatisfy { $0.type != .scrollWheel })
        let views = captured.scrollWheelViews
        XCTAssertEqual(views.count, 1)
        XCTAssertEqual(views[0].scrollPhase, .cancelled)
        XCTAssertEqual(views[0].deltaYFixedPt, 0)
    }

    func testEventsCarryTheInjectedClockAsTimestamps() {
        var emittedEvents: [CGEvent] = []
        var uptime: TimeInterval = 100.0
        let poster = Cadence(
            RawTouchScrollPoster(
                eventSink: { emittedEvents.append($0.copy() ?? $0) },
                modifierFlags: { [] },
                now: { uptime }
            ))

        // Every event of a burst — the scroll event and its gesture
        // companions — carries the same nanosecond uptime stamp. WebKit's
        // ProMotion momentum interpolator fits velocity from these; zero
        // stamps broke Safari's rubber-band recovery on >60 Hz displays.
        poster.post(.touchBegan)
        let firstBurst = emittedEvents
        emittedEvents.removeAll()
        uptime += 0.01
        poster.post(.touchChanged(deltaX: 0, deltaY: 24))
        let secondBurst = emittedEvents

        let expectedFirst = CGEventTimestamp(100.0 * 1_000_000_000)
        let expectedSecond = CGEventTimestamp(100.01 * 1_000_000_000)
        XCTAssertGreaterThan(firstBurst.count, 1)  // scroll + companions
        XCTAssertGreaterThan(secondBurst.count, 1)
        XCTAssertTrue(firstBurst.allSatisfy { $0.timestamp == expectedFirst })
        XCTAssertTrue(secondBurst.allSatisfy { $0.timestamp == expectedSecond })
    }

    /// A flick moves several points on its first motion frame: the began
    /// goes out on that frame, on the flick's axis, and the fraction it
    /// moved on the other axis rides on the next changed event.
    func testAFlickReleasesTheBeganOnItsFirstMotionFrameOnItsAxis() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 0.1, deltaY: 8),
            .touchChanged(deltaX: 0.2, deltaY: 6),
            .touchEnded,
        ] {
            poster.post(event)
        }

        let views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.scrollPhase), [.began, .changed, .ended])
        XCTAssertEqual(views[0].deltaYFixedPt, 8, accuracy: 1e-4)
        XCTAssertEqual(views[0].deltaXFixedPt, 0, "the began names one axis")
        XCTAssertEqual(views[0].deltaYPt, 8, "and its integer point delta is non-zero — the WebKit rule")
        XCTAssertEqual(views[1].deltaYFixedPt, 6, accuracy: 1e-4)
        XCTAssertEqual(
            views[1].deltaXFixedPt, 0.3, accuracy: 1e-4, "the held sideways fraction is delivered, not dropped")
    }

    /// A finger starting from rest moves a fraction of a point per frame,
    /// with a hint of sideways jitter. Safari reads the integer point delta,
    /// so a began posted on the first of those would be a zero-delta began
    /// to WebKit (see `beganPending`); with any cross-axis motion at all the
    /// began waits for two points along the axis, or four frames.
    func testASlowDragWaitsForTwoPointsAlongItsAxis() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 0.05, deltaY: 0.6),
            .touchChanged(deltaX: 0.05, deltaY: 0.6),
            .touchChanged(deltaX: 0.05, deltaY: 0.6),
            .touchChanged(deltaX: 0.05, deltaY: 0.6),
            .touchChanged(deltaX: 0, deltaY: 0.6),
            .touchEnded,
        ] {
            poster.post(event)
        }
        var views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.scrollPhase), [.began, .changed, .ended])
        XCTAssertEqual(views[0].deltaYFixedPt, 2.4, accuracy: 1e-4, "released at two points, carrying all of it")
        XCTAssertEqual(views[0].deltaYPt, 2)
        XCTAssertEqual(views[0].deltaXFixedPt, 0)
        XCTAssertEqual(views[1].deltaYFixedPt, 0.6, accuracy: 1e-4)
        XCTAssertEqual(views[1].deltaXFixedPt, 0.2, accuracy: 1e-4, "the held jitter rides along")

        // A slow drag that stays ambiguous (2:3 sideways) is released at
        // the cap, on the leading axis, with the other riding after it.
        captured.reset()
        poster.post(.touchBegan)
        for _ in 0..<9 {
            poster.post(.touchChanged(deltaX: 0.2, deltaY: 0.3))
        }
        poster.post(.touchEnded)
        views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.scrollPhase), [.began, .changed, .ended])
        XCTAssertEqual(views[0].deltaYFixedPt, 2.4, accuracy: 1e-4, "eight frames' worth, at the cap")
        XCTAssertEqual(views[0].deltaXFixedPt, 0)
        XCTAssertEqual(views[1].deltaXFixedPt, 1.8, accuracy: 1e-4, "the held sideways motion plus the ninth frame's")
        XCTAssertEqual(views[1].deltaYFixedPt, 0.3, accuracy: 1e-4)

        // Purely axial motion (a pad set to one axis) follows the same
        // rule: two points, at the fourth frame here.
        captured.reset()
        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 0, deltaY: 0.6),
            .touchChanged(deltaX: 0, deltaY: 0.6),
            .touchChanged(deltaX: 0, deltaY: 0.6),
            .touchChanged(deltaX: 0, deltaY: 0.6),
            .touchChanged(deltaX: 0, deltaY: 0.6),
            .touchEnded,
        ] {
            poster.post(event)
        }
        views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.scrollPhase), [.began, .changed, .ended])
        XCTAssertEqual(views[0].deltaYFixedPt, 2.4, accuracy: 1e-4)
        XCTAssertEqual(views[0].deltaYPt, 2)
    }

    /// The third recorded shape: 2.05 pt sideways with exactly zero
    /// vertical on the first frame — the contact centroid sliding along a
    /// landing finger — then a vertical flick. The landing window is not
    /// evidence; the third frame decides.
    func testTheLandingWindowIsNotEvidence() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: -2.05, deltaY: 0),
            .touchChanged(deltaX: -1.15, deltaY: -2.95),
            .touchChanged(deltaX: -0.5, deltaY: -6),
            .touchChanged(deltaX: 0, deltaY: -8),
            .touchEnded,
        ] {
            poster.post(event)
        }

        let views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.scrollPhase), [.began, .changed, .ended])
        XCTAssertEqual(views[0].deltaXFixedPt, 0, "vertical, once it led 2:1 past four points")
        XCTAssertEqual(views[0].deltaYFixedPt, -8.95, accuracy: 1e-4)
        XCTAssertEqual(views[1].deltaXFixedPt, -3.7, accuracy: 1e-4, "the sideways start arrives one event later")
        XCTAssertEqual(views[1].deltaYFixedPt, -8, accuracy: 1e-4)

        // A genuinely horizontal drag with the same first frame is named
        // horizontal once it has travelled further than a slide can.
        captured.reset()
        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 3.2, deltaY: 0),
            .touchChanged(deltaX: 2.61, deltaY: 0.18),
            .touchChanged(deltaX: 2, deltaY: 0.1),
            .touchChanged(deltaX: 2.5, deltaY: 0),
            .touchEnded,
        ] {
            poster.post(event)
        }
        XCTAssertEqual(captured.scrollWheelViews.map(\.scrollPhase), [.began, .ended])
        XCTAssertEqual(
            captured.scrollWheelViews[0].deltaXFixedPt, 10.31, accuracy: 1e-4,
            "eight points: further than any landing slide")
        XCTAssertEqual(captured.scrollWheelViews[0].deltaYFixedPt, 0)
    }

    /// A recorded vertical flick whose first motion frame is 1.15 pt
    /// sideways and 0.13 pt up — jitter — then vertical. A began released
    /// on that frame would be horizontal, and WebKit/Chromium would latch
    /// the whole gesture horizontal.
    func testFirstFrameJitterDoesNotPickTheAxis() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 1.15, deltaY: 0.13),
            .touchChanged(deltaX: 0.3, deltaY: 4),
            .touchChanged(deltaX: 0, deltaY: 4),
            .touchChanged(deltaX: 0.1, deltaY: 5),
            .touchEnded,
        ] {
            poster.post(event)
        }

        let views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.scrollPhase), [.began, .changed, .ended])
        XCTAssertEqual(views[0].deltaXFixedPt, 0, "the began waits out the landing and names vertical")
        XCTAssertEqual(views[0].deltaYFixedPt, 8.13, accuracy: 1e-4, "released on the third frame")
        XCTAssertEqual(views[1].deltaXFixedPt, 1.55, accuracy: 1e-4, "the sideways motion arrives one event later")
        XCTAssertEqual(views[1].deltaYFixedPt, 5, accuracy: 1e-4)
    }

    /// The second shape: 2.44 pt sideways against 1.15 pt up on the first
    /// frame, then vertical. Two points of travel with a 2:1 lead is not
    /// trusted; four points with a 2:1 lead is.
    func testATwoToOneLeadNeedsFourPointsOfTravel() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 2.44, deltaY: 1.15),
            .touchChanged(deltaX: 0.5, deltaY: 5),
            .touchChanged(deltaX: 0.2, deltaY: 5),
            .touchChanged(deltaX: 0, deltaY: 5),
            .touchEnded,
        ] {
            poster.post(event)
        }

        let views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.scrollPhase), [.began, .changed, .ended])
        XCTAssertEqual(views[0].deltaYFixedPt, 11.15, accuracy: 1e-4, "vertical, released after the landing window")
        XCTAssertEqual(views[0].deltaXFixedPt, 0)
        XCTAssertEqual(views[1].deltaXFixedPt, 3.14, accuracy: 1e-4)
    }

    /// A genuinely diagonal start is released at the cap, vertical unless
    /// horizontal clearly leads; the other axis follows on the next changed
    /// event, so an app that does not latch still scrolls diagonally.
    func testAnAmbiguousStartIsReleasedAtTheCapOnTheLeadingAxis() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 1, deltaY: 1),
            .touchChanged(deltaX: 1, deltaY: 1),
            .touchChanged(deltaX: 1, deltaY: 1),
            .touchChanged(deltaX: 1.2, deltaY: 1),
            .touchChanged(deltaX: 1, deltaY: 1),
            .touchChanged(deltaX: 1, deltaY: 1),
            .touchChanged(deltaX: 1, deltaY: 1),
            .touchChanged(deltaX: 1, deltaY: 1),
            .touchChanged(deltaX: 1, deltaY: 1),
            .touchEnded,
        ] {
            poster.post(event)
        }

        let views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.scrollPhase), [.began, .changed, .ended])
        XCTAssertEqual(views[0].deltaYFixedPt, 8, accuracy: 1e-4, "eighth frame: a near tie goes to vertical")
        XCTAssertEqual(views[0].deltaXFixedPt, 0)
        XCTAssertEqual(views[1].deltaXFixedPt, 9.2, accuracy: 1e-4, "the held horizontal motion plus this frame's")
        XCTAssertEqual(views[1].deltaYFixedPt, 1, accuracy: 1e-4)
    }

    func testATouchThatNeverReachesAWholePointEndsAsCancelled() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 0, deltaY: 0.3),
            .touchChanged(deltaX: 0, deltaY: -0.2),
            .touchChanged(deltaX: 0, deltaY: 0.4),
            .touchEnded,
        ] {
            poster.post(event)
        }

        XCTAssertEqual(captured.scrollWheelViews.map(\.scrollPhase), [.cancelled])
    }

    /// A lift before the direction was decided still decides it: a whole
    /// point pending goes out as the began on the dominant axis, then the
    /// ended — so the coast that follows belongs to a gesture that began.
    func testALiftWithAWholePointPendingReleasesTheBeganThenEnds() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 0.3, deltaY: 1.5),
            .touchEnded,
            .momentumBegan(deltaX: 0, deltaY: 10),
            .momentumChanged(deltaX: 0, deltaY: 6),
            .momentumEnded,
        ] {
            poster.post(event)
        }

        let views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.scrollPhase), [.began, .ended, nil, nil, nil])
        XCTAssertEqual(views.map(\.momentumPhase), [.none, .none, .begin, .continuous, .end])
        XCTAssertEqual(views[0].deltaYFixedPt, 1.5, accuracy: 1e-4)
        XCTAssertEqual(views[0].deltaXFixedPt, 0, "the began names one axis")
        XCTAssertEqual(views[0].deltaYPt, 1, "a whole point, as WebKit needs")
    }

    /// A touch that ends as `cancelled` never began, so a coast the engine
    /// runs after it has no gesture to belong to: nothing of it is posted,
    /// and the next touch posts normally.
    func testNoMomentumIsPostedAfterACancelledTouch() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 0, deltaY: 0.4),
            .touchEnded,
            .momentumBegan(deltaX: 0, deltaY: 10),
            .momentumChanged(deltaX: 0, deltaY: 6),
            .momentumEnded,
        ] {
            poster.post(event)
        }
        XCTAssertEqual(captured.scrollWheelViews.map(\.scrollPhase), [.cancelled])
        XCTAssertEqual(captured.scrollWheelViews.map(\.momentumPhase), [.none])

        captured.reset()
        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 0.1, deltaY: 24),
            .touchEnded,
            .momentumBegan(deltaX: 0, deltaY: 12),
            .momentumEnded,
        ] {
            poster.post(event)
        }
        XCTAssertEqual(captured.scrollWheelViews.map(\.momentumPhase), [.none, .none, .begin, .end])
    }

    // MARK: - Two axes

    /// Everything axis 1 (vertical) carries, axis 2 (horizontal) carries
    /// too: line steps, integer points, the precise fixed-point delta, the
    /// IOHIDEvent field, and the gesture companion's scroll X.
    func testHorizontalDeltasFillTheAxis2Fields() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        poster.post(.touchBegan)
        poster.post(.touchChanged(deltaX: 24, deltaY: 6))
        poster.post(.touchChanged(deltaX: -13, deltaY: 0))
        poster.post(.touchEnded)
        poster.post(.momentumBegan(deltaX: 12, deltaY: 3))
        poster.post(.momentumChanged(deltaX: 8, deltaY: 2))
        poster.post(.momentumEnded)

        // The began names its dominant axis (24 right, 4:1); the 6 pt of
        // vertical motion held back from it rides on the next changed.
        let views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.deltaXFixedPt), [24, -13, 0, 12, 8, 0])
        XCTAssertEqual(views.map(\.deltaYFixedPt), [0, 6, 0, 3, 2, 0])
        XCTAssertEqual(views.map(\.deltaXPt), [24, -13, 0, 12, 8, 0])
        XCTAssertEqual(views.map(\.deltaYPt), [0, 6, 0, 3, 2, 0])
        XCTAssertEqual(views.map(\.deltaX), [2, -1, 0, 1, 0, 0], "line steps of 12 pt, rounded toward zero")
        XCTAssertEqual(views.map(\.deltaY), [0, 0, 0, 0, 0, 0])

        // The gesture companions carry both too (the began's and the
        // changed's; mayBegin and the series events carry zero).
        let scrollGestures = captured.events.filter {
            $0.type == .gesture && $0.getIntegerValueField(.gestureHIDType) == Int64(IOHIDEventType.scroll.rawValue)
                && $0.getIntegerValueField(.gesturePhase) != Int64(CGSGesturePhase.mayBegin.rawValue)
        }
        XCTAssertEqual(scrollGestures.map { $0.getDoubleValueField(.gestureScrollX) }, [24, -13, 0])
        XCTAssertEqual(scrollGestures.map { $0.getDoubleValueField(.gestureScrollY) }, [0, 6, 0])
    }

    /// The two-axis rule on a purely horizontal drag: the began names
    /// horizontal, and sub-point motion on both axes throughout never
    /// begins at all.
    func testAHorizontalDragBeginsHorizontalAndSubPointMotionIsCancelled() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 0.3, deltaY: 0),
            .touchChanged(deltaX: 0.4, deltaY: 0),
            .touchChanged(deltaX: 0.5, deltaY: 0),
            .touchChanged(deltaX: 8, deltaY: 0),
            .touchEnded,
        ] {
            poster.post(event)
        }
        var views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.scrollPhase), [.began, .ended])
        XCTAssertEqual(
            views[0].deltaXFixedPt, 9.2, accuracy: 1e-4,
            "the flick frame releases it, carrying every fraction moved so far")
        XCTAssertEqual(views[0].deltaXPt, 9)
        XCTAssertEqual(views[0].deltaYFixedPt, 0)

        // Sub-point on both axes throughout: never began, cancelled.
        captured.reset()
        for event in [
            TouchScrollEngine.Event.touchBegan,
            .touchChanged(deltaX: 0.4, deltaY: 0.4),
            .touchChanged(deltaX: 0.4, deltaY: -0.4),
            .touchEnded,
        ] {
            poster.post(event)
        }
        XCTAssertEqual(captured.scrollWheelViews.map(\.scrollPhase), [.cancelled])
    }

    func testSubpixelHorizontalDeltasAccumulateSeparatelyFromVertical() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        poster.post(.touchBegan)
        poster.post(.touchChanged(deltaX: 8, deltaY: 1))  // a flick: the began, horizontal
        for _ in 0..<4 {
            poster.post(.touchChanged(deltaX: 0.4, deltaY: 0.7))
        }
        poster.post(.touchEnded)

        let views = captured.scrollWheelViews
        XCTAssertEqual(views.reduce(0.0) { $0 + $1.deltaXPt }, 9, "8 + 4 × 0.4 = 9.6 → 9 whole points")
        XCTAssertEqual(
            views.reduce(0.0) { $0 + $1.deltaYPt }, 3, "1 (held from the began) + 4 × 0.7 = 3.8 → 3 whole points")
    }

    func testSubpixelDeltasAccumulateAcrossTouchChanges() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        // Six sub-point axial steps: the began is released at the fifth
        // frame (two points, past the landing window), the sixth is a
        // changed event.
        poster.post(.touchBegan)
        for _ in 0..<6 {
            poster.post(.touchChanged(deltaX: 0, deltaY: 0.4))
        }
        poster.post(.touchEnded)

        let views = captured.scrollWheelViews
        // Fixed-point delta carries the value (within the field's 16.16
        // fixed-point resolution)...
        XCTAssertEqual(views[1].deltaYFixedPt, 0.4, accuracy: 1e-4)
        // ...while integer point deltas accumulate remainders instead of
        // truncating each fraction to zero.
        let totalPointDelta = views.reduce(0.0) { $0 + $1.deltaYPt }
        XCTAssertEqual(totalPointDelta, 2, "6 × 0.4 = 2.4 → 2 whole points, remainders carried")
    }

    // MARK: - The began rules

    /// Each row of `beganRules`, pinned: a motion meant for it matches it
    /// first, and the same motion just short of it falls through.
    func testEachBeganRuleMatchesItsOwnCase() {
        typealias Case = (
            pending: (x: Double, y: Double), lastFrame: (x: Double, y: Double), elapsed: TimeInterval, row: Int?
        )
        let cases: [Case] = [
            ((0.1, 6), (10, 600), 0.01, 0),  // a vertical flick frame
            ((0.1, 6), (200, 600), 0.01, nil),  // sideways a third of it: no flick
            ((6, 0.1), (600, 100), 0.01, 1),  // a horizontal flick frame
            ((0.5, 2), (5, 20), 0.03, 2),  // vertical, clear
            ((0.5, 2), (5, 20), 0.029, nil),  // still inside the landing window
            ((1.5, 4), (5, 20), 0.03, 3),  // vertical, settled
            ((8, 2), (20, 5), 0.03, 4),  // horizontal, clear
            ((12, 5), (20, 5), 0.03, 5),  // horizontal, settled
            ((8, 3.5), (20, 5), 0.08, 6),  // past the cap: horizontal beyond a slide
            ((8, 3.5), (20, 5), 0.079, nil),  // not yet past it
            ((3, 1.5), (20, 5), 0.08, 7),  // past the cap: vertical
            ((5, 0.2), (20, 1), 0.08, nil),  // a sideways slide: no vertical began without a whole point
            ((5, 0.2), (20, 1), 0.5, nil),
        ]
        for (index, test) in cases.enumerated() {
            let row = RawTouchScrollPoster.beganRules.firstIndex {
                $0.matches(pending: test.pending, lastFrame: test.lastFrame, elapsed: test.elapsed)
            }
            XCTAssertEqual(row, test.row, "case \(index)")
        }
    }

    /// Past the cap an ambiguous start goes vertical only when the vertical
    /// axis has a whole point to carry: a slow sideways slide (5 pt across,
    /// 0.2 pt up) would otherwise release a vertical began whose integer
    /// delta is zero — one WebKit ignores. It waits, and its lift releases
    /// the began on the axis it actually moved along.
    func testASidewaysSlidePastTheCapDoesNotBeginVertically() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster())

        poster.post(.touchBegan)
        for _ in 0..<12 {
            poster.post(.touchChanged(deltaX: 0.42, deltaY: 0.017))
        }
        XCTAssertTrue(captured.scrollWheelViews.isEmpty, "120 ms and no began")
        poster.post(.touchEnded)

        let views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.scrollPhase), [.began, .ended])
        XCTAssertEqual(views[0].deltaXFixedPt, 5.04, accuracy: 1e-4)
        XCTAssertEqual(views[0].deltaYFixedPt, 0)
    }

    /// A flick-speed frame decides the axis but not the delta: a short
    /// frame can be fast and still move under a point, and the began it
    /// released would carry a zero integer delta. It keeps waiting.
    func testAFlickSpeedFrameUnderAWholePointKeepsWaiting() {
        let captured = CapturedScrollEvents()
        let poster = captured.makePoster()

        poster.post(.touchBegan, at: 0)
        poster.post(.touchChanged(deltaX: 0, deltaY: 0.8), at: 0.001)  // 800 pt/s, 0.8 pt
        XCTAssertTrue(captured.scrollWheelViews.isEmpty)

        poster.post(.touchChanged(deltaX: 0, deltaY: 7), at: 0.011)
        let views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.scrollPhase), [.began])
        XCTAssertEqual(views[0].deltaYFixedPt, 7.8, accuracy: 1e-4)
        XCTAssertEqual(views[0].deltaYPt, 7)
    }

    /// A reversal: a frame up, then a flick-speed frame down that nearly
    /// cancels it. The flick names the axis, but the pending motion is
    /// 0.4 pt — the began waits for the next frame's whole point.
    func testAFlickAfterAReversalWaitsForAWholePoint() {
        let captured = CapturedScrollEvents()
        let poster = captured.makePoster()

        poster.post(.touchBegan, at: 0)
        poster.post(.touchChanged(deltaX: 0, deltaY: -4.6), at: 0.010)  // 460 pt/s: no flick
        poster.post(.touchChanged(deltaX: 0, deltaY: 5), at: 0.0175)  // 667 pt/s, 0.4 pt pending
        XCTAssertTrue(captured.scrollWheelViews.isEmpty, "a 0.4 pt began would be a zero-delta began")

        poster.post(.touchChanged(deltaX: 0, deltaY: 5), at: 0.025)
        let views = captured.scrollWheelViews
        XCTAssertEqual(views.map(\.scrollPhase), [.began])
        XCTAssertEqual(views[0].deltaYFixedPt, 5.4, accuracy: 1e-4)
        XCTAssertEqual(views[0].deltaYPt, 5)
    }

    /// When a steady drag of `velocity` (points/second) posted every
    /// `period` releases its began: the time after touch-down, and the
    /// began's deltas.
    private func began(
        velocity: (x: Double, y: Double),
        period: TimeInterval
    ) -> (time: TimeInterval, deltaX: Double, deltaY: Double)? {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster(), period: period)
        poster.post(.touchBegan)
        for _ in 0..<Int((0.2 / period).rounded()) {
            let time = poster.time
            poster.post(.touchChanged(deltaX: velocity.x * period, deltaY: velocity.y * period))
            if let view = captured.scrollWheelViews.first {
                return (time, view.deltaXFixedPt, view.deltaYFixedPt)
            }
        }
        return nil
    }

    /// The rules are times and speeds, not frame counts: frames reach the
    /// poster at the pad's 100 Hz, or resampled at the display's 60 or
    /// 120 Hz, and every rate decides on the first frame at or past the
    /// time the pad's own cadence would.
    func testTheBeganDecidesAtTheSameTimesAtEveryFrameRate() {
        for rate in [100.0, 120, 60] {
            let period = 1 / rate
            let firstFrame = { (time: TimeInterval) in (time / period - 1e-6).rounded(.up) * period }

            // A flick-speed frame decides at once; one below it waits for
            // the landing window, even where a 60 Hz frame covers 8 pt.
            XCTAssertEqual(
                began(velocity: (0, 700), period: period)?.time ?? -1, period, accuracy: 1e-9, "\(rate) Hz flick")
            XCTAssertEqual(
                began(velocity: (0, 500), period: period)?.time ?? -1, firstFrame(0.030), accuracy: 1e-9,
                "\(rate) Hz sub-flick")

            // A slow vertical drag: at the end of the landing window.
            XCTAssertEqual(
                began(velocity: (0, 100), period: period)?.time ?? -1, firstFrame(0.030), accuracy: 1e-9,
                "\(rate) Hz drag")

            // A diagonal: at the cap, vertical.
            let diagonal = began(velocity: (100, 100), period: period)
            XCTAssertEqual(diagonal?.time ?? -1, firstFrame(0.080), accuracy: 1e-9, "\(rate) Hz diagonal")
            XCTAssertEqual(diagonal?.deltaX, 0)
        }
    }

    // MARK: - The coast's integer point delta

    /// AppKit's `scrollingDeltaY` is the integer point delta, so the coast
    /// carries its fractions just as the touch does: over a whole coast the
    /// whole points posted add up to the precise motion, and the slow tail
    /// (under a point per 120 Hz tick below 120 pt/s) still moves.
    func testTheCoastCarriesItsFractionsIntoTheIntegerDelta() {
        let captured = CapturedScrollEvents()
        let poster = Cadence(captured.makePoster(), period: 1.0 / 120.0)
        let engine = TouchScrollEngine(config: .init(pointsPerCount: 0.25, momentum: .init(decayTimeConstant: 0.55)))

        // A flick at 4000 counts/s × 0.25 = 1000 pt/s, then its coast on
        // 120 Hz ticks.
        var t = 0.0
        for frame in 0..<12 {
            t = Double(frame) * 0.01
            engine.handle(frame: scrollFrame(y: 500 + frame * 40, at: t)).forEach(poster.post)
        }
        engine.handle(frame: releaseFrame(at: t + 0.01, scrollMode: true)).forEach(poster.post)
        captured.reset()
        var tick = t + 0.01
        while engine.wantsMomentumTicks {
            tick += 1.0 / 120.0
            engine.momentumTick(at: tick).forEach(poster.post)
        }

        let views = captured.scrollWheelViews
        let precise = views.reduce(0) { $0 + $1.deltaYFixedPt }
        let whole = views.reduce(0) { $0 + $1.deltaYPt }
        XCTAssertGreaterThan(precise, 400)
        XCTAssertEqual(whole, precise, accuracy: 1, "nothing lost to truncation")
        XCTAssertGreaterThan(views.suffix(20).reduce(0) { $0 + $1.deltaYPt }, 0, "the slow tail still moves")
    }
}
