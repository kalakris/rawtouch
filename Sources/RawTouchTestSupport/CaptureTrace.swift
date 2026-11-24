// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// A recorded delivery trace: one pad's frames from a `raw-touch-monitor`
/// capture (`bench/captures/`), cut into contiguous touched runs, each
/// frame carrying its device sample time and how late it reached the host.
///
/// The offline bench replays these in place of its synthetic delivery
/// models, so the stutter-versus-latency curve it measures is the one a
/// real path produces: USB or BLE to the host, wired or BLE between the
/// halves, local or relayed pad. Only what the wire says is used — the
/// frame's own device timestamp and its arrival time — never the finger's
/// position, which the bench's finger models supply so the truth is known.
///
/// Lateness is arrival minus device time, minus the smallest such offset in
/// the run: how much later than its run's fastest frame each frame arrived.
/// That is exactly what the host can measure live (the device clock's
/// anchor tightening tracks the same minimum), and what a resampling
/// latency has to cover.
public struct CaptureTrace {
    public struct Frame {
        /// Device sample time, relative to the run's first frame.
        public let deviceTime: TimeInterval
        /// Arrival lateness beyond the run's fastest frame (≥ 0).
        public let lateness: TimeInterval
        /// The reported position, raw pad counts.
        public let x: Int
        public let y: Int
        /// The reported touch strength (z).
        public let z: Int
    }

    /// Consecutive-seq frames of one touch, release excluded.
    public struct Run {
        public let frames: [Frame]

        /// Device time covered by the run.
        public var span: TimeInterval {
            frames.last?.deviceTime ?? 0
        }
    }

    public struct LoadError: Error, CustomStringConvertible {
        public let description: String
    }

    /// The capture's file name.
    public let name: String
    public let pad: Int
    /// Longest first.
    public let runs: [Run]
    /// Every run's frame lateness, sorted ascending, for the percentiles.
    public let latenesses: [TimeInterval]

    public var frameCount: Int {
        latenesses.count
    }

    /// The `p`-th (0...1) percentile of lateness across all runs, seconds.
    public func latenessPercentile(_ p: Double) -> TimeInterval {
        guard !latenesses.isEmpty else {
            return 0
        }
        let index = min(latenesses.count - 1, Int(p * Double(latenesses.count)))
        return latenesses[index]
    }

    /// One tick of the 16-bit device timestamp, per the wire spec.
    private static let tickDuration: TimeInterval = 100e-6
    /// A gap in device time or arrival larger than this ends a run, as it
    /// re-anchors the host's device clock.
    private static let discontinuity: TimeInterval = 2.0

    /// The distinct pad IDs a monitor CSV contains, ascending.
    public static func pads(inFile path: String) throws -> [Int] {
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw LoadError(description: "\(path): \(error.localizedDescription)")
        }
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else {
            throw LoadError(description: "\(path): empty")
        }
        let header = lines.removeFirst().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let padColumn = header.firstIndex(of: "pad") else {
            throw LoadError(description: "\(path): no `pad` column")
        }
        var pads = Set<Int>()
        for line in lines where !line.hasPrefix("#") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            if fields.count > padColumn, let pad = Int(fields[padColumn]) {
                pads.insert(pad)
            }
        }
        return pads.sorted()
    }

    /// Loads one pad's runs from a monitor CSV (columns `host_ns, dev, pad,
    /// contact, x, y, z, flags, seq, ts_ticks`). Runs shorter than
    /// `minimumRun` frames are dropped.
    public static func load(path: String, pad: Int, minimumRun: Int = 10) throws -> CaptureTrace {
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw LoadError(description: "\(path): \(error.localizedDescription)")
        }
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else {
            throw LoadError(description: "\(path): empty")
        }
        let header = lines.removeFirst().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        func column(_ name: String) throws -> Int {
            guard let index = header.firstIndex(of: name) else {
                throw LoadError(description: "\(path): no `\(name)` column (header: \(header.joined(separator: ",")))")
            }
            return index
        }
        let hostColumn = try column("host_ns")
        let padColumn = try column("pad")
        let flagsColumn = try column("flags")
        let seqColumn = try column("seq")
        let ticksColumn = try column("ts_ticks")
        let xColumn = try column("x")
        let yColumn = try column("y")
        let zColumn = try column("z")

        // Absolute (unwrapped) device time and arrival per frame of the run
        // being assembled.
        var current: [(deviceTime: TimeInterval, arrival: TimeInterval, x: Int, y: Int, z: Int)] = []
        var runs: [Run] = []
        var previousSeq: Int?
        var previousTouched = false
        var previousArrival: TimeInterval?
        var lastTicks: Int?
        var unwrapped = 0

        func finishRun() {
            defer { current = [] }
            guard current.count >= minimumRun, let first = current.first else {
                return
            }
            let minimumOffset = current.map { $0.arrival - $0.deviceTime }.min()!
            runs.append(
                Run(
                    frames: current.map { frame in
                        Frame(
                            deviceTime: frame.deviceTime - first.deviceTime,
                            lateness: frame.arrival - frame.deviceTime - minimumOffset,
                            x: frame.x,
                            y: frame.y,
                            z: frame.z
                        )
                    }))
        }

        for line in lines where !line.hasPrefix("#") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > max(hostColumn, padColumn, flagsColumn, seqColumn, ticksColumn),
                let rowPad = Int(fields[padColumn]), rowPad == pad,
                let hostNS = Int64(fields[hostColumn]),
                let flags = Int(fields[flagsColumn]),
                let seq = Int(fields[seqColumn]),
                let ticks = Int(fields[ticksColumn]),
                fields.count > max(xColumn, yColumn, zColumn),
                let rowX = Int(fields[xColumn]), let rowY = Int(fields[yColumn]), let rowZ = Int(fields[zColumn])
            else {
                continue
            }
            let arrival = TimeInterval(hostNS) / 1e9
            if let lastTicks {
                unwrapped += (ticks - lastTicks) & 0xFFFF
            } else {
                unwrapped = ticks
            }
            lastTicks = ticks
            let deviceTime = TimeInterval(unwrapped) * tickDuration
            let touched = flags & 1 != 0

            let continues =
                touched && previousTouched
                && previousSeq.map { (($0 + 1) & 0xFF) == seq } == true
                && previousArrival.map { arrival - $0 < discontinuity } == true
                && (current.last.map { deviceTime - $0.deviceTime < discontinuity } ?? true)
            if !continues {
                finishRun()
            }
            if touched {
                current.append((deviceTime, arrival, rowX, rowY, rowZ))
            }
            previousSeq = seq
            previousTouched = touched
            previousArrival = arrival
        }
        finishRun()

        guard !runs.isEmpty else {
            throw LoadError(description: "\(path): no touched run of \(minimumRun)+ frames on pad \(pad)")
        }
        runs.sort { $0.frames.count > $1.frames.count }
        return CaptureTrace(
            name: (path as NSString).lastPathComponent,
            pad: pad,
            runs: runs,
            latenesses: runs.flatMap { $0.frames.map(\.lateness) }.sorted()
        )
    }
}
