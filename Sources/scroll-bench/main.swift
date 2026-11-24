// MIT License
// Copyright (c) 2026 RawTouch contributors

import ApplicationServices
import CoreGraphics
import Foundation
import RawTouchCore
import RawTouchTestSupport

private let usage = """
    scroll-bench — posts a synthetic RawTouch scroll sequence (flick → momentum →
    catch → re-scroll → lift) through the real pipeline — display sync on the
    display under the cursor included — and poster, so what an app receives is
    exactly the stream RawTouch would post. For bench experiments
    against real apps; see bench/safari-bounce/. Never touches HID, so it runs
    alongside the RawTouch app — just keep your hands off the pads.

    usage: scroll-bench [options]
      --cursor X,Y         warp the cursor here first (global screen points)
      --scale PTS          points per count (default 0.25). The bench speaks the
                           engine's unit directly: the gain is left at 1.0 and
                           the display density pinned so the derivation lands
                           on exactly this many points/count
      --flick COUNTS       flick speed, counts per 10 ms frame (default 40)
      --flick-frames N     flick length in frames (default 12)
      --delay MS           release → catch delay (default 300)
      --rescroll COUNTS    re-scroll speed, counts per frame; the sign sets the
                           direction relative to the flick (default -30)
      --rescroll-frames N  re-scroll length in frames (default 20)
      --settle MS          hold still before the final lift, so it carries no
                           momentum (default 150)
      --decay S            momentum decay time constant (default: the app's,
                           \(RawTouchConfiguration.Momentum.defaultDecayTimeConstant))
      --flick-settle MS    hold still this long before the flick's lift, so it
                           carries NO momentum — a plain drag into the edge
                           (default 0 = a real flick)
      --catch-rest MS      after the catch's touch-down, hold still this long
                           before the re-scroll starts, as a landing finger does
                           (default 0 = move on the very next frame)
      --catch-ramp         ramp the re-scroll up from 1 count per frame, doubling
                           each frame until it reaches --rescroll, as a finger
                           starting from rest does (its first deltas are sub-pixel)
      --no-catch           flick only; let momentum run out
      --latency MS         display-sync latency (default 5)
      --offline            no posting at all: run the deterministic cadence
                           bench (100 Hz frames, simulated 120 Hz vsync, ON vs
                           OFF per input model) and exit
      --replay CSV         (offline) also replay the recorded delivery of a
                           raw-touch-monitor capture (see bench/captures/): the
                           frames' own device timestamps and arrival lateness
                           drive the bench's finger models. Repeatable
      --pad N              (offline) which pad(s) of the captures to replay;
                           repeatable; default: every pad with a long enough
                           touch
      --sweep              (offline) instead of the standard table, sweep the
                           resampling latency for each replayed capture and
                           report the stutter-versus-latency curve and its knee
      --latencies LIST     (sweep) comma-separated ms (default 0,1,…,8,10,…,20)
      --trials N           (sweep) recorded starts averaged per row (default 4)
      --recorded-finger    (sweep) drive the bench with the recording's own
                           finger motion instead of the steady drag: no CV or
                           0-delta story, but the jitter and carried columns
                           show what running ahead of the data costs on real
                           motion
      --verbose            print every engine event with its time

    Requires Accessibility for the posting process (not for --offline). It
    never prompts: run it from a terminal that already holds the grant, and
    never grant a prompt bound to this binary — the grant would stick to a
    build-directory copy (see CONTRIBUTING.md).
    """

// MARK: - Arguments

var cursor: CGPoint?
var scale = 0.25
var flickCounts = 40
var flickFrames = 12
var delayMS = 300.0
var rescrollCounts = -30
var rescrollFrames = 20
var settleMS = 150.0
var decay = RawTouchConfiguration.Momentum.defaultDecayTimeConstant
var flickSettleMS = 0.0
var catchRestMS = 0.0
var catchRamp = false
var noCatch = false
var latencyMS = OfflineBench.defaultLatencyMs
var offline = false
var replays: [String] = []
var replayPads: [Int] = []
var sweep = false
var sweepLatencies: [Double] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 18, 20]
var trials = 4
var recordedFinger = false
var verbose = false

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

var arguments = Array(CommandLine.arguments.dropFirst())
func next(_ flag: String) -> String {
    guard let value = arguments.first else {
        fail("\(flag) needs a value")
    }
    arguments.removeFirst()
    return value
}

func intValue(_ flag: String) -> Int {
    guard let value = Int(next(flag)) else {
        fail("\(flag) wants an integer")
    }
    return value
}

func doubleValue(_ flag: String) -> Double {
    guard let value = Double(next(flag)) else {
        fail("\(flag) wants a number")
    }
    return value
}

while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--help", "-h":
        print(usage)
        exit(0)
    case "--cursor":
        let parts = next(argument).split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else {
            fail("--cursor wants X,Y")
        }
        cursor = CGPoint(x: parts[0], y: parts[1])
    case "--scale": scale = doubleValue(argument)
    case "--flick": flickCounts = intValue(argument)
    case "--flick-frames": flickFrames = intValue(argument)
    case "--delay": delayMS = doubleValue(argument)
    case "--rescroll": rescrollCounts = intValue(argument)
    case "--rescroll-frames": rescrollFrames = intValue(argument)
    case "--settle": settleMS = doubleValue(argument)
    case "--decay": decay = doubleValue(argument)
    case "--flick-settle": flickSettleMS = doubleValue(argument)
    case "--catch-rest": catchRestMS = doubleValue(argument)
    case "--catch-ramp": catchRamp = true
    case "--no-catch": noCatch = true
    case "--latency": latencyMS = doubleValue(argument)
    case "--offline": offline = true
    case "--replay": replays.append(next(argument))
    case "--pad": replayPads.append(intValue(argument))
    case "--sweep": sweep = true
    case "--latencies":
        sweepLatencies = next(argument).split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard !sweepLatencies.isEmpty else {
            fail("--latencies wants comma-separated numbers")
        }
    case "--trials": trials = intValue(argument)
    case "--recorded-finger": recordedFinger = true
    case "--verbose": verbose = true
    default:
        fail("unknown argument \(argument)\n\n\(usage)")
    }
}

// Counts and durations the sequence below loops over or waits on.
if flickFrames < 2 {
    fail("--flick-frames wants at least 2 (the touch-down and one moving frame)")
}
if rescrollFrames < 1 {
    fail("--rescroll-frames wants at least 1")
}
if trials < 1 {
    fail("--trials wants at least 1")
}
for (flag, milliseconds) in [
    ("--delay", delayMS), ("--settle", settleMS), ("--flick-settle", flickSettleMS), ("--catch-rest", catchRestMS),
]
where milliseconds < 0 {
    fail("\(flag) wants a duration of 0 ms or more")
}

setbuf(stdout, nil)

// MARK: - Offline bench (posts nothing; no Accessibility needed)

if offline {
    var traces: [CaptureTrace] = []
    sweepLatencies.sort()
    for path in replays {
        let pads = replayPads.isEmpty ? ((try? CaptureTrace.pads(inFile: path)) ?? []) : replayPads
        for pad in pads {
            do {
                traces.append(try CaptureTrace.load(path: path, pad: pad))
            } catch {
                if replayPads.isEmpty {
                    FileHandle.standardError.write(Data("[bench] skipping: \(error)\n".utf8))
                } else {
                    fail("\(error)")
                }
            }
        }
    }
    if sweep {
        guard !traces.isEmpty else {
            fail("--sweep needs at least one --replay capture")
        }
        OfflineBench.sweep(traces: traces, latencies: sweepLatencies, trials: trials, recordedFinger: recordedFinger)
    } else {
        OfflineBench.run(extraInputs: traces.compactMap { OfflineBench.InputModel.replay($0, trial: 0) })
    }
    exit(0)
}

// MARK: - Permissions

func trace(_ message: String) {
    if verbose {
        FileHandle.standardError.write(Data(("[bench] " + message + "\n").utf8))
    }
}

trace("checking Accessibility")
guard AXIsProcessTrusted() else {
    fail(
        """
        Accessibility is not granted for this process, so scroll events cannot be posted. \
        Run from a terminal that already holds the grant. Do NOT grant a prompt bound to this binary.
        """
    )
}

// MARK: - Clock

let frameInterval = 0.01

func now() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}

func sleep(until deadline: TimeInterval) {
    let remaining = deadline - now()
    if remaining > 0.002 {
        Thread.sleep(forTimeInterval: remaining - 0.001)
    }
    while now() < deadline {
        usleep(100)
    }
}

// MARK: - Driver

let t0 = now()

/// What the sequence below drives: the full pipeline on its event thread
/// with a real CVDisplayLink ticker. Frames go in at real time, are
/// resampled onto the display under the cursor, and momentum rides its
/// vsync — exactly the app's path. Posts through the real poster.
final class PipelineDriver {
    /// The pad resolution the simulated device reports; it cancels out of
    /// the points-per-count derivation (see the `pointsPerMM` provider).
    static let padCountsPerMM = 38

    /// Wraps the real ticker to measure how far behind its vsync stamps
    /// the ticks actually run on the event thread (verbose only).
    private final class MeasuringTicker: DisplayTicking {
        let inner: DisplayTicking
        var lags: [TimeInterval] = []

        init(inner: DisplayTicking) {
            self.inner = inner
        }

        func startTicks(handler: @escaping (TimeInterval) -> Void) -> DisplayTickSource? {
            inner.startTicks { [weak self] timestamp in
                self?.lags.append(now() - timestamp)
                handler(timestamp)
            }
        }
    }

    /// Counters written on the event thread, read from the main thread.
    private final class Counters {
        let lock = NSLock()
        var events = 0
        var momentumTicks = 0
        var activity: RawTouchStatus.PadActivity = .idle
    }

    private let eventThread = EventThread()
    private let pipeline: TouchScrollPipeline
    private let ticker: MeasuringTicker
    private let counters = Counters()

    init() {
        eventThread.start()
        ticker = MeasuringTicker(inner: CVDisplayLinkTicker(eventThread: eventThread))

        var configuration = RawTouchConfiguration()
        configuration.momentum.decayTimeConstant = decay
        configuration.resampling = .init(enabled: true)
        // Ballistics off: `--scale` is meant to be the whole of the
        // mapping.
        configuration.acceleration.enabled = false

        let counters = counters
        let poster = RawTouchScrollPoster(eventSink: { event in
            if event.type == .scrollWheel {
                let view = ScrollWheelEventView(event)
                counters.lock.lock()
                counters.events += 1
                if view.momentumPhase == .continuous {
                    counters.momentumTicks += 1
                }
                counters.lock.unlock()
                if verbose {
                    print(
                        String(
                            format: "%8.1f ms  deltaY=%.3f phase=%@ momentum=%@",
                            (now() - t0) * 1000, view.deltaYFixedPt,
                            String(describing: view.scrollPhase), String(describing: view.momentumPhase)
                        ))
                }
            }
            event.post(tap: .cgSessionEventTap)
        })
        pipeline = TouchScrollPipeline(
            configuration: configuration,
            poster: poster,
            scheduler: eventThread,
            displayTicker: ticker,
            // `--scale` is points per count, but the configuration's gain
            // is relative to physical 1:1: leave the gain at its default
            // 1.0 and pin the display density at `scale × counts/mm`, so
            // `gain × points/mm ÷ counts/mm` comes out at exactly `scale`.
            pointsPerMM: { scale * Double(Self.padCountsPerMM) }
        )
        // The bench measures a stated latency; the estimator is validated
        // against recordings by the unit tests and the offline sweep.
        pipeline.fixedLatency = latencyMS / 1000
        pipeline.onActivityChange = { activity in
            counters.lock.lock()
            counters.activity = activity
            counters.lock.unlock()
        }

        // A pad scrolling from raw y, uninverted (`invertY` set is what
        // yields `invert == false` in the derivation), so the frames below
        // scroll the way their y moves.
        let configured = eventThread.performAndWait { [pipeline] in
            pipeline.configure(
                capabilities: RawTouchCapabilities(
                    padsPresent: 0x01,
                    capabilityBits: RawTouchCapabilities.Capability.hostLease,
                    countsPerMM: Self.padCountsPerMM,
                    invertY: true
                ),
                systemPrefersNatural: false
            )
            return true
        }
        guard configured == true else {
            fail("event thread did not start")
        }
    }

    var eventCount: Int {
        counters.lock.lock()
        defer { counters.lock.unlock() }
        return counters.events
    }

    var momentumTicks: Int {
        counters.lock.lock()
        defer { counters.lock.unlock() }
        return counters.momentumTicks
    }

    /// Whether momentum is running right now.
    var isCoasting: Bool {
        counters.lock.lock()
        defer { counters.lock.unlock() }
        if case .coasting = counters.activity {
            return true
        }
        return false
    }

    func handle(_ frame: RawTouchFrame) {
        trace("handing \(frame.touched ? "touch" : "release") to the pipeline")
        eventThread.perform { [pipeline] in
            pipeline.handle(wireFrame: frame)
        }
    }

    /// Waits until `deadline` (or forever for `.infinity`) or until the
    /// momentum ends, whichever is first. Returns whether momentum was
    /// still running at the deadline.
    func runMomentum(until deadline: TimeInterval) -> Bool {
        // Give the release a moment to land on the event thread before
        // reading the activity.
        Thread.sleep(forTimeInterval: 0.005)
        while isCoasting {
            if now() >= deadline {
                return true
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        if deadline.isFinite {
            sleep(until: deadline)
        }
        return false
    }

    func finish() {
        eventThread.perform { [pipeline] in
            pipeline.interrupt()
        }
        eventThread.stop()
        if verbose, !ticker.lags.isEmpty {
            let ms = ticker.lags.map { $0 * 1000 }
            print(
                String(
                    format:
                        "display ticks: %d; event-thread arrival after the vsync stamp: mean %.2f ms, min %.2f, max %.2f",
                    ms.count, ms.reduce(0, +) / Double(ms.count), ms.min()!, ms.max()!
                ))
        }
    }
}

let driver = PipelineDriver()
trace("pipeline + display link ready")

func scrollFrame(y: Int, at timestamp: TimeInterval) -> RawTouchFrame {
    .init(padID: 0, x: 1000, y: y, z: 40, touched: true, scrollMode: true, leaseHeld: true, timestamp: timestamp)
}

func releaseFrame(at timestamp: TimeInterval) -> RawTouchFrame {
    .init(padID: 0, touched: false, scrollMode: true, leaseHeld: true, timestamp: timestamp)
}

// MARK: - Sequence

if let cursor {
    // A posted mouse-moved event both warps the cursor and updates which
    // window is "under" it for the scroll events that follow.
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cursor, mouseButton: .left)?
        .post(tap: .cgSessionEventTap)
    Thread.sleep(forTimeInterval: 0.15)
}

var y = 2000
let start = now()

// Flick: frame 0 is the touch-down, every later frame moves `flickCounts`.
for index in 0..<flickFrames {
    let at = start + Double(index) * frameInterval
    sleep(until: at)
    if index > 0 {
        y += flickCounts
    }
    driver.handle(scrollFrame(y: y, at: now()))
}
// Optional hold before the lift: a drag that stops carries no momentum, so
// the edge is reached (or stretched) by the finger alone.
let flickSettleFrames = Int((flickSettleMS / 1000 / frameInterval).rounded())
if flickSettleFrames > 0 {
    for index in 1...flickSettleFrames {
        sleep(until: start + Double(flickFrames - 1 + index) * frameInterval)
        driver.handle(scrollFrame(y: y, at: now()))
    }
}
let releaseAt = start + Double(flickFrames + flickSettleFrames) * frameInterval
sleep(until: releaseAt)
driver.handle(releaseFrame(at: now()))
let seedPointsPerSecond = Double(flickCounts) / frameInterval * scale

if noCatch {
    let hadMomentum = driver.runMomentum(until: now() + 0.03) || driver.momentumTicks > 0
    _ = driver.runMomentum(until: .infinity)
    print(
        String(
            format: "flick seed ≈ %.0f pt/s; momentum %@; %d momentum ticks over %.0f ms",
            seedPointsPerSecond, hadMomentum ? "ran" : "did not start", driver.momentumTicks,
            (now() - releaseAt) * 1000))
    driver.finish()
    exit(0)
}

// Coast until the catch.
let catchAt = releaseAt + delayMS / 1000
let momentumActiveAtCatch = driver.runMomentum(until: catchAt)
let ticksBeforeCatch = driver.momentumTicks

// Catch + re-scroll: touch down where the finger was, optionally rest there
// (a real finger lands and sits for a few frames before it moves), drag the
// other way, hold still, lift (a stopped lift carries no momentum).
driver.handle(scrollFrame(y: y, at: now()))
let catchRestFrames = Int((catchRestMS / 1000 / frameInterval).rounded())
if catchRestFrames > 0 {
    for index in 1...catchRestFrames {
        sleep(until: catchAt + Double(index) * frameInterval)
        driver.handle(scrollFrame(y: y, at: now()))
    }
}
let rescrollStart = catchAt + Double(catchRestFrames) * frameInterval
var rampCounts = 1
let rescrollFrom = y
for index in 1...rescrollFrames {
    sleep(until: rescrollStart + Double(index) * frameInterval)
    if catchRamp && rampCounts < abs(rescrollCounts) {
        y += rescrollCounts.signum() * rampCounts
        rampCounts *= 2
    } else {
        y += rescrollCounts
    }
    driver.handle(scrollFrame(y: y, at: now()))
}
let settleFrames = Int((settleMS / 1000 / frameInterval).rounded())
let settleStart = rescrollStart + Double(rescrollFrames) * frameInterval
for index in 1...max(settleFrames, 1) {
    sleep(until: settleStart + Double(index) * frameInterval)
    driver.handle(scrollFrame(y: y, at: now()))
}
sleep(until: settleStart + Double(settleFrames + 1) * frameInterval)
driver.handle(releaseFrame(at: now()))
_ = driver.runMomentum(until: .infinity)  // should be instant: no momentum expected

// What the finger moved, ramp included.
let expectedRescrollPoints = Double(abs(y - rescrollFrom)) * scale
print(
    String(
        format:
            "seed ≈ %.0f pt/s | catch at %.0f ms after release (momentum %@, %d ticks) | re-scroll %.0f pt over %d frames | %d events%@",
        seedPointsPerSecond, delayMS, momentumActiveAtCatch ? "still active" : "already over",
        ticksBeforeCatch, expectedRescrollPoints, rescrollFrames, driver.eventCount,
        String(format: " | display sync %.1f ms", latencyMS)
    ))
driver.finish()
