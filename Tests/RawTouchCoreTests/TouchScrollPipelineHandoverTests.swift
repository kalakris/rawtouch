// MIT License
// Copyright (c) 2026 RawTouch contributors

import CoreGraphics
import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// A keyboard switching connection mid-touch — USB plugged in while
/// scrolling over Bluetooth, or pulled out — sends its finger over the
/// other endpoint while the first goes silent without a release. The same
/// pad of the same keyboard (one hardware id on every connection) takes
/// the gesture over at its first frame: no 150 ms stall waiting for the old
/// source's watchdog, no new series, no jump, no momentum. Every CGEvent is
/// captured — nothing is posted.
final class TouchScrollPipelineHandoverTests: XCTestCase {
    private let frameInterval: TimeInterval = 0.01
    private let displayPeriod: TimeInterval = 1.0 / 120.0
    private let usb = RawTouchEndpointID(rawValue: 1)
    private let bluetooth = RawTouchEndpointID(rawValue: 2)
    private let otherKeyboard = RawTouchEndpointID(rawValue: 3)

    /// 10 counts a frame: 1000 counts/s, 250 pt/s at the tests' 0.25 pt
    /// per count.
    private let step = 10

    private func descriptor(
        id: UInt64,
        transport: RawTouchTransport,
        deviceID: UInt8
    ) -> RawTouchEndpointDescriptor {
        var descriptor = endpointDescriptor(id: id, transport: transport)
        descriptor.capabilities.deviceID = [0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xF0, deviceID]
        return descriptor
    }

    /// One keyboard over USB (1) and Bluetooth (2), and another keyboard (3).
    private func makeHarness(resampling: Bool) -> PipelineHarness {
        PipelineHarness(
            resampling: resampling,
            endpoints: [
                descriptor(id: 1, transport: .usb, deviceID: 0x97),
                descriptor(id: 2, transport: .bluetooth, deviceID: 0x97),
                descriptor(id: 3, transport: .usb, deviceID: 0x42),
            ]
        )
    }

    /// A frame of the finger at time `t` on the keyboard's clock: its
    /// position is where a steady drag from x 1000 is at `t`, stamped with
    /// the device time, as the keyboard sends it over any connection.
    private func finger(
        at t: TimeInterval,
        on endpoint: RawTouchEndpointID,
        pad: UInt8 = 0,
        transport: RawTouchTransport = .unknown
    ) -> RawTouchFrame {
        RawTouchFrame(
            padID: pad, x: 1000 + Int((t / frameInterval).rounded()) * step, y: 500, z: 40,
            touched: true, scrollMode: true, leaseHeld: true,
            deviceTimestampTicks: deviceTicks(at: t),
            transport: transport, endpoint: endpoint, timestamp: t + 0.001
        )
    }

    /// Delivers `frame`, then the vsyncs up to the next frame when
    /// resampling.
    private func deliver(_ frame: RawTouchFrame, to harness: PipelineHarness) {
        harness.pipeline.handle(wireFrame: frame)
        var vsync = frame.timestamp + 0.002
        while vsync < frame.timestamp + frameInterval {
            harness.ticker.tick(at: vsync)
            vsync += displayPeriod
        }
    }

    /// A drag on `first` for 100 ms, a 30 ms switch with no frames at all
    /// (the finger moves on), then on `second` for 100 ms, and a stopped
    /// lift. Returns the deltas posted from each connection's frames.
    private func switchMidDrag(
        from first: RawTouchEndpointID,
        to second: RawTouchEndpointID,
        resampling: Bool
    ) -> (harness: PipelineHarness, before: [Double], after: [Double]) {
        let harness = makeHarness(resampling: resampling)
        for index in 0...10 {
            deliver(finger(at: Double(index) * frameInterval, on: first), to: harness)
        }
        let before = harness.captured.deltas
        for index in 13...23 {
            deliver(finger(at: Double(index) * frameInterval, on: second), to: harness)
        }
        let after = Array(harness.captured.deltas.dropFirst(before.count))
        // The finger stops, then lifts: no coast either way.
        for index in 24...40 {
            var still = finger(at: Double(index) * frameInterval, on: second)
            still.x = 1000 + 23 * step
            deliver(still, to: harness)
        }
        deliver(releaseFrame(at: 0.41, scrollMode: true, endpoint: second), to: harness)
        return (harness, before, after)
    }

    private func assertSeamless(
        _ result: (harness: PipelineHarness, before: [Double], after: [Double]),
        to second: RawTouchEndpointID,
        _ label: String
    ) {
        let phases = result.harness.captured.scrollPhases
        XCTAssertEqual(phases.filter { $0 == .began }.count, 1, "\(label): one series, no second began")
        XCTAssertEqual(phases.filter { $0 == .ended }.count, 1, "\(label): ended once, at the lift")
        XCTAssertEqual(phases.last, .ended, label)
        XCTAssertFalse(phases.contains(.cancelled), label)
        XCTAssertEqual(result.harness.captured.phases.filter { $0.momentum != .none }.count, 0, "\(label): no coast")
        XCTAssertGreaterThan(
            result.after.reduce(0, +), 0, "\(label): the new connection scrolls at once, no watchdog wait")
        // No jump: the new connection's deltas are the finger's own frame
        // of motion (plus, resampled, the few counts the new track's
        // estimate runs ahead), and the 30 ms the finger moved through
        // during the switch is not caught up in one go (it would be 7.5 pt
        // more): 10 frames before and 10 after, 2.5 pt each.
        let frameOfMotion = Double(step) * 0.25
        for delta in result.after {
            XCTAssertLessThanOrEqual(abs(delta), frameOfMotion + 1, "\(label): no jump")
        }
        XCTAssertEqual((result.before + result.after).reduce(0, +), 20 * frameOfMotion, accuracy: 1, label)
        let summary = result.harness.summaries.last
        XCTAssertEqual(summary?.endpoint, second, "\(label): the gesture ended as the new connection's")
        XCTAssertEqual(summary?.liftOffSpeed ?? -1, 0, accuracy: 1, "\(label): a stopped lift, no momentum spike")
    }

    func testUSBToBluetoothMidDragContinuesTheGesture() {
        for resampling in [false, true] {
            let result = switchMidDrag(from: usb, to: bluetooth, resampling: resampling)
            assertSeamless(result, to: bluetooth, "USB → Bluetooth, resampling \(resampling)")
        }
    }

    func testBluetoothToUSBMidDragContinuesTheGesture() {
        for resampling in [false, true] {
            let result = switchMidDrag(from: bluetooth, to: usb, resampling: resampling)
            assertSeamless(result, to: usb, "Bluetooth → USB, resampling \(resampling)")
        }
    }

    /// A flick handed over mid-motion coasts from the finger's speed as
    /// the new connection measured it: the switch's jump is not in it.
    func testAFlickHandedOverCoastsAtTheFingersSpeed() {
        let harness = makeHarness(resampling: false)
        for index in 0...10 {
            deliver(finger(at: Double(index) * frameInterval, on: usb), to: harness)
        }
        for index in 13...20 {
            deliver(finger(at: Double(index) * frameInterval, on: bluetooth), to: harness)
        }
        deliver(releaseFrame(at: 0.21, scrollMode: true, endpoint: bluetooth), to: harness)
        XCTAssertEqual(harness.summaries.last?.liftOffSpeed ?? -1, 250, accuracy: 5, "1000 counts/s × 0.25")
        XCTAssertEqual(harness.pipeline.activeSource?.endpoint, bluetooth)
    }

    /// A frame still in flight on the connection the keyboard left arrives
    /// after the new one's: it is older on the keyboard's clock, and does
    /// not take the gesture back.
    func testAStragglerOnTheOldConnectionDoesNotTakeTheGestureBack() {
        let harness = makeHarness(resampling: false)
        for index in 0...5 {
            deliver(finger(at: Double(index) * frameInterval, on: bluetooth), to: harness)
        }
        deliver(finger(at: 0.07, on: usb), to: harness)
        deliver(finger(at: 0.06, on: bluetooth), to: harness)
        XCTAssertEqual(harness.pipeline.activeSource?.endpoint, usb)
        let posted = harness.captured.deltas.count
        deliver(finger(at: 0.08, on: usb), to: harness)
        XCTAssertEqual(harness.captured.deltas.last ?? -1, Double(step) * 0.25, accuracy: 1e-9)
        XCTAssertEqual(harness.captured.deltas.count, posted + 1)
    }

    /// Another keyboard's pad 0 is a different finger: it waits for the
    /// gesture to end, as before.
    func testAnotherKeyboardDoesNotTakeTheGestureOver() {
        let harness = makeHarness(resampling: false)
        for index in 0...5 {
            deliver(finger(at: Double(index) * frameInterval, on: usb), to: harness)
        }
        deliver(finger(at: 0.06, on: otherKeyboard), to: harness)
        XCTAssertEqual(harness.pipeline.activeSource?.endpoint, usb)
    }

    /// The keyboard's other pad over its other connection is a different
    /// finger too.
    func testAnotherPadOfTheSameKeyboardDoesNotTakeTheGestureOver() {
        let harness = makeHarness(resampling: false)
        for index in 0...5 {
            deliver(finger(at: Double(index) * frameInterval, on: usb), to: harness)
        }
        deliver(finger(at: 0.06, on: bluetooth, pad: 1), to: harness)
        XCTAssertEqual(harness.pipeline.activeSource, RawTouchSourceID(endpoint: usb, padID: 0))
    }
}
