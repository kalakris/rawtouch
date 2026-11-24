// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse's HID device manager — Copyright (c) 2021-2026
// LinearMouse (MIT) — with its `ConfigurationState`/`DeviceManager`/
// `HIDPhysicalDeviceIdentity` coupling removed and the host lease added.

import CoreGraphics
import Foundation
import IOKit.hid
import os.log

/// Owns the device side of RawTouch: an `IOHIDManager` matched on the
/// vendor-defined raw touch collection — by the usage pair alone, since ZMK
/// keyboards share a default VID/PID — the feature-report validation that
/// admits a device, the host lease, and the per-frame hand-off to
/// `TouchScrollPipeline`.
///
/// - Admission: on connect the feature report is read (once more a second
///   later when the first read finds none) and validated
///   (`RawTouchCapabilities`); a foreign collection squatting on the
///   generic usage pair fails and is ignored. A valid report without the
///   host-lease capability is reported as unsupported firmware and never
///   leased: that keyboard keeps scrolling on its own. The only other read
///   picks up a split half's firmware version and never re-decides
///   admission (`RawTouchFirmwareVersionProbe`).
/// - Lease: acquired, renewed at half the timeout and after a system sleep,
///   released on shutdown, re-acquired whenever the device re-enumerates —
///   only while the user's `enabled` preference and posting readiness
///   (`setPostingReady(_:)`) both allow it. Otherwise the device is still
///   admitted and reported, and keeps scrolling in Standard mode.
/// - Every matched device is one endpoint (`RawTouchEndpointID`) with its
///   own lease and status line; one endpoint's failure never affects
///   another's (`RawTouchEndpointRegistry`).
///
/// Threading: the `IOHIDManager` runs on `EventThread`'s run loop, so input
/// reports are parsed where the pipeline state lives, with no per-frame
/// hop. Connect and disconnect hop to the main queue, which owns the device
/// list and the leases. Blocking report transfers (`IOHIDDeviceGetReport`,
/// `IOHIDDeviceSetReport`) run on a serial queue per endpoint
/// (`OpenDevice.reportQueue`), never the main queue: per-endpoint order puts
/// a shutdown release after any renewal in flight on that endpoint, and a
/// Bluetooth endpoint that blocks as it vanishes cannot hold up another
/// keyboard's release.
public final class RawTouchDeviceManager {
    /// Frozen protocol constants: the vendor-defined usage pair raw touch
    /// frames live on. Deliberately no VID/PID — the feature-report
    /// validation, not the device's identity, decides who streams.
    public enum Constants {
        public static let usagePage = 0xFF00
        public static let usage = 0x01
    }

    /// What a matched device says about itself before any report is read,
    /// taken once at connect.
    struct DeviceIdentity {
        var productName: String
        /// The transport as macOS names it ("USB", "Bluetooth", "Bluetooth
        /// Low Energy"); the raw string goes into the logs so an
        /// unrecognized one can be identified from a user's log alone.
        var transportName: String?
        /// The identifiers a persistent device key can be built from — see
        /// `RawTouchDeviceKey` for which transport exposes which.
        var serialNumber: String?
        var bluetoothAddress: String?

        init(of device: IOHIDDevice) {
            productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
            transportName = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
            serialNumber = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
            bluetoothAddress = IOHIDDeviceGetProperty(device, "DeviceAddress" as CFString) as? String
        }

        var transport: RawTouchTransport {
            RawTouchTransport(hidTransport: transportName)
        }

        /// The keyboard's own hardware id — the same over every transport —
        /// or, for firmware that reports none, this connection's key.
        func deviceKey(reporting capabilities: RawTouchCapabilities) -> String? {
            RawTouchDeviceKey.hardwareID(capabilities.deviceIDHex)
                ?? RawTouchDeviceKey.transportKey(
                    transport: transport, serialNumber: serialNumber, bluetoothAddress: bluetoothAddress)
        }
    }

    /// The IOHIDDevice behind an endpoint, kept only for the report
    /// transfers; everything else about the endpoint lives in `registry`.
    struct OpenDevice {
        var id: RawTouchEndpointID
        var device: IOHIDDevice
        var identity: DeviceIdentity
        /// Where this endpoint's blocking report transfers run (see the
        /// threading note above). Created with the endpoint, dropped with it.
        var reportQueue: DispatchQueue

        var productName: String {
            identity.productName
        }
    }

    private var configuration: RawTouchConfiguration
    private let systemPrefersNaturalScrolling: () -> Bool

    private let eventThread = EventThread()
    private let poster: RawTouchScrollPoster
    private let pipeline: TouchScrollPipeline

    private static func makeReportQueue(for id: RawTouchEndpointID) -> DispatchQueue {
        DispatchQueue(label: "io.github.kalakris.RawTouch.hid-reports.\(id.rawValue)", qos: .userInitiated)
    }

    /// How long `shutdown()` waits for the release writes to leave. Past it
    /// the process exits anyway and the firmware's own lease timeout (30 s)
    /// puts the keyboard back into Standard mode.
    private static let shutdownReleaseTimeout: TimeInterval = 2

    // Main-queue state.
    private(set) var started = false

    /// Whether scroll events can actually be posted (see
    /// `setPostingReady(_:)`). False until told otherwise, so nothing is
    /// leased before the trust check has run: `RawTouchService` sets it
    /// from that check before `start()`.
    private var postingReady = false

    private var hidManager: IOHIDManager?
    private var hidManagerRunLoop: CFRunLoop?

    /// Every endpoint seen, its lease state and generation stamps
    /// (IOKit-free, so it is tested on its own).
    var registry = RawTouchEndpointRegistry()

    /// The IOKit handles of the admitted endpoints, in connect order.
    private(set) var openDevices: [OpenDevice] = []

    /// Devices whose capability read is in flight on their report queue,
    /// each under the endpoint ID allocated for this appearance. A device that
    /// disconnects meanwhile is dropped from here, and its result — tagged
    /// with the ID — is discarded when it lands, even if the same device
    /// has since reappeared under a new ID.
    private var validatingDevices: [OpenDevice] = []
    private var leaseRenewalTimer: DispatchSourceTimer?
    private var naturalScrollingObserver: NSObjectProtocol?
    private var padActivity: RawTouchStatus.PadActivity = .idle
    private var lastGesture: RawTouchGestureSummary?
    /// What each source's frame delivery has measured it needs: the
    /// Advanced tab's read-only latency row. Per source — endpoint and pad
    /// — because that is what the estimator is per, and on a split the two
    /// pads' paths are not alike.
    private var measuredLatencyMs: [RawTouchSourceID: Double] = [:]
    private var configError: RawTouchStatus.ConfigError?

    /// The current status snapshot (main-queue state). Recomputed after
    /// every state change; identical consecutive snapshots are suppressed.
    public private(set) var status: RawTouchStatus

    /// Called on the main queue whenever `status` changes. Never invoked
    /// with a snapshot equal to the previous one.
    public var onStatusChange: ((RawTouchStatus) -> Void)?

    /// One admitted device as the frame path sees it (see below).
    private struct VerifiedDevice {
        var device: IOHIDDevice
        var id: RawTouchEndpointID
        var transport: RawTouchTransport
        var awaitsFirmwareVersion: Bool
    }

    // Cross-thread mirror of the validated-device set: the input-report
    // callback runs on the event thread and must not touch `registry` or
    // `openDevices`. It carries each device's endpoint ID and transport so
    // a frame can be tagged without a second lookup — one lock, one scan,
    // on the ~100 Hz path. `awaitsFirmwareVersion` rides along for the same
    // reason: the frame path must know whether this endpoint has a pad
    // worth re-reading for without a second lookup, and it is false for
    // every endpoint almost always.
    let verifiedDevicesLock = NSLock()
    private var lockedVerifiedDevices: [VerifiedDevice] = []
    /// The firmware-version re-read state, under the same lock
    /// (`FirmwareVersionWatch`).
    var lockedFirmwareVersionWatch = FirmwareVersionWatch()

    public init(
        configuration: RawTouchConfiguration = .init(),
        systemPrefersNaturalScrolling: @escaping () -> Bool = SystemScrollingPreference.prefersNatural
    ) {
        self.configuration = configuration
        self.systemPrefersNaturalScrolling = systemPrefersNaturalScrolling
        poster = RawTouchScrollPoster()
        pipeline = TouchScrollPipeline(
            configuration: configuration,
            poster: poster,
            scheduler: eventThread,
            displayTicker: CVDisplayLinkTicker(eventThread: eventThread)
        )
        status = RawTouchStatus(enabled: configuration.enabled, postingReady: postingReady)

        // Activity transitions are rare (gesture start/momentum/end, never
        // per frame), so the hop from the event thread to the main queue —
        // where the rest of the status lives — is cheap.
        pipeline.onActivityChange = { [weak self] activity in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                padActivity = activity
                publishStatus()
            }
        }
        // Every source's measurement, as often as a summary: the estimator
        // only moves while a finger is down.
        pipeline.onMeasuredLatencies = { [weak self] latencies in
            DispatchQueue.main.async { [weak self] in
                guard let self, latencies != measuredLatencyMs else {
                    return
                }
                measuredLatencyMs = latencies
                publishStatus()
            }
        }
        // At most once per touch, and only for a tap: the write goes out on
        // the endpoint's report queue, reached through the main queue where
        // the device list lives.
        pipeline.onTapConfirm = { [weak self] source in
            DispatchQueue.main.async { [weak self] in
                self?.confirmTap(pad: source.padID, on: source.endpoint)
            }
        }
        // Twice per gesture at most (lift-off, coast end): as cheap a hop
        // as the activity one.
        pipeline.onGestureSummary = { [weak self] summary in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                lastGesture = summary
                publishStatus()
            }
        }
    }

    /// The IOHIDManager's callbacks reach this object through an
    /// unretained pointer, so a manager released while started would leave
    /// them pointing at freed memory: releasing it shuts it down first.
    /// Callers still call `shutdown()` themselves — it waits for the lease
    /// releases, which belongs on the quit path, not wherever the last
    /// reference happens to go.
    deinit {
        shutdown()
    }

    // MARK: - Lifecycle (main queue)

    public func start() {
        guard !started else {
            return
        }
        started = true

        eventThread.start()

        // Push the readiness set before start(): `EventThread.perform` drops
        // blocks while the thread is down, so a `setPostingReady(false)` that
        // arrived first would never have reached the pipeline.
        let postingReady = postingReady
        eventThread.perform { [pipeline] in
            pipeline.setPostingReady(postingReady)
        }

        // The Natural Scrolling checkbox announces changes via a distributed
        // notification; the engine sign depends on it, so re-derive live.
        naturalScrollingObserver = DistributedNotificationCenter.default().addObserver(
            forName: SystemScrollingPreference.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reconfigure()
        }

        openHIDManager()
    }

    /// Releases the lease, closes out any gesture, and tears down the
    /// HID manager and event thread. Safe to call once, from the main queue.
    ///
    /// The release writes are the one place this waits on the report queues:
    /// the process is about to exit, and a keyboard left with a lease held
    /// scrolls nowhere until the lease times out. The wait is bounded
    /// (`shutdownReleaseTimeout`) and cannot deadlock — work on a report
    /// queue only ever hops back to the main queue asynchronously.
    public func shutdown() {
        guard started else {
            return
        }
        started = false

        leaseRenewalTimer?.cancel()
        leaseRenewalTimer = nil
        validatingDevices.removeAll()

        if let naturalScrollingObserver {
            DistributedNotificationCenter.default().removeObserver(naturalScrollingObserver)
            self.naturalScrollingObserver = nil
        }

        releaseAllLeasesAndWait()

        closeHIDManager()
        for device in openDevices {
            registry.remove(device.id)
        }
        openDevices.removeAll()
        updateVerifiedDevices()
        publishStatus()

        // Close the gesture on the event thread, then stop it (the stop is
        // FIFO-ordered behind this block).
        eventThread.perform { [pipeline] in
            pipeline.interrupt()
        }
        eventThread.stop()
    }

    // MARK: - Configuration

    /// Applies a new configuration live, from the main queue. A no-op when
    /// nothing changed (apart from clearing any recorded config error — the
    /// caller only gets here with a configuration that loaded cleanly).
    ///
    /// A switch flipping off releases the lease on the endpoints it covers,
    /// and flipping on acquires it (`reconcileLeases()`). Device validation
    /// is independent of either switch, so a disabled RawTouch still tracks
    /// (and reports in `status`) the devices it sees.
    public func apply(configuration newConfiguration: RawTouchConfiguration) {
        configError = nil

        guard newConfiguration != configuration else {
            publishStatus()
            return
        }

        configuration = newConfiguration

        // Pushes the new settings to the pipeline on the event thread. When
        // `enabled` just flipped false this also interrupts it: `configure`
        // closes out any gesture in flight once streaming is off.
        reconfigure()
        reconcileLeases()
        publishStatus()
    }

    /// Whether this process can post scroll events right now — the second
    /// half of lease ownership. See `RawTouchDeviceManaging.setPostingReady`.
    ///
    /// Dropping it releases the lease on every device and interrupts the
    /// pipeline, so the keyboard goes straight back to scrolling on its own
    /// rather than waiting out the firmware's 30 s lease. Raising it acquires
    /// the lease on everything present. Never touches `configuration.enabled`:
    /// the user's preference is not ours to rewrite, and it has to come back
    /// intact when the grant lands.
    public func setPostingReady(_ ready: Bool) {
        guard ready != postingReady else {
            return
        }

        postingReady = ready

        os_log(
            "Posting readiness %{public}@; %{public}@",
            log: RawTouchLog.lease,
            type: .info,
            ready ? "restored" : "lost",
            ready ? "acquiring the lease" : "releasing the lease (the keyboard scrolls on its own)"
        )

        eventThread.perform { [pipeline] in
            pipeline.setPostingReady(ready)
        }

        reconcileLeases()
        publishStatus()
    }

    /// Whether this endpoint's lease is ours to hold: the user wants
    /// RawTouch, on this keyboard too (`devices.<key>.enabled`), **and** we
    /// can post what we synthesize. Holding a lease otherwise would
    /// suppress the firmware's wheel fallback and synthesize nothing in its
    /// place — no scrolling at all, the opposite of what switching RawTouch
    /// off promises; a keyboard switched off must fall back to Standard
    /// mode, not sit with its lease held and its frames dropped.
    private func leaseIsDesired(for entry: RawTouchEndpointRegistry.Entry) -> Bool {
        postingReady && configuration.isEnabled(deviceKey: entry.deviceKey)
    }

    /// Brings every admitted endpoint's lease request in line with whether
    /// it is wanted, and the renewal timer in line with whether any is.
    /// Called after every change to an input of that decision — the
    /// configuration, posting readiness, an endpoint admitted or gone — so
    /// the request and the desire never disagree for longer than one call.
    private func reconcileLeases() {
        let changes = registry.leaseChanges(isDesired: leaseIsDesired(for:))
        changes.acquire.forEach(acquireLease(on:))
        changes.release.forEach(releaseLease(on:))

        guard !registry.requestedLeases.isEmpty else {
            leaseRenewalTimer?.cancel()
            leaseRenewalTimer = nil
            return
        }
        if leaseRenewalTimer == nil {
            leaseRenewalTimer = makeLeaseRenewalTimer()
        }
    }

    /// Records a configuration-file failure for `status.configError`
    /// (main queue). Cleared by the next successful `apply(configuration:)`.
    public func reportConfigurationError(_ error: RawTouchStatus.ConfigError) {
        configError = error
        publishStatus()
    }

    /// Recomputes the status snapshot from the main-queue state and delivers
    /// it through `onStatusChange` if it actually changed.
    func publishStatus() {
        // `endpoints` carries every endpoint with its own lease outcome; the
        // status derives its summary fields from them. A lease that is not
        // wanted has been released by `reconcileLeases()` before any
        // publish, which drops `held` at once, so an endpoint reads `.held`
        // exactly while its lease is.
        let newStatus = RawTouchStatus(
            enabled: configuration.enabled,
            postingReady: postingReady,
            activity: padActivity,
            configError: configError,
            endpoints: registry.statusEndpoints(
                isDisabled: { [configuration] entry in
                    !configuration.isEnabled(deviceKey: entry.deviceKey)
                },
                measuredLatencyMs: measuredLatencyMs
            ),
            validatingEndpointCount: validatingDevices.count,
            lastGesture: lastGesture
        )

        guard newStatus != status else {
            return
        }
        status = newStatus
        onStatusChange?(newStatus)
    }

    private func reconfigure() {
        let endpoints = registry.descriptors
        let prefersNatural = systemPrefersNaturalScrolling()
        let configuration = configuration

        eventThread.perform { [pipeline] in
            pipeline.configure(
                endpoints: endpoints,
                configuration: configuration,
                systemPrefersNatural: prefersNatural
            )
        }
    }

    // MARK: - IOHIDManager

    private func openHIDManager() {
        guard hidManager == nil else {
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Match on the vendor usage pair alone: any keyboard implementing the
        // raw touch protocol qualifies, and the feature-report validation
        // in `deviceDidConnect` — not a VID/PID — decides whether a matched
        // device actually streams. The report ID is not part of the match
        // (IOHIDManager cannot match on it); the input-report callback
        // filters on it instead.
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey: Constants.usagePage,
            kIOHIDDeviceUsageKey: Constants.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { context, _, _, device in
                guard let context else {
                    return
                }
                let manager = Unmanaged<RawTouchDeviceManager>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.deviceDidConnect(device)
                }
            }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { context, _, _, device in
                guard let context else {
                    return
                }
                let manager = Unmanaged<RawTouchDeviceManager>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.deviceDidDisconnect(device)
                }
            }, context)
        IOHIDManagerRegisterInputReportCallback(
            manager,
            { context, result, sender, type, reportID, report, reportLength in
                guard let context, let sender, result == kIOReturnSuccess, type == kIOHIDReportTypeInput else {
                    return
                }
                let manager = Unmanaged<RawTouchDeviceManager>.fromOpaque(context).takeUnretainedValue()
                let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
                manager.handleReport(from: device, reportID: reportID, bytes: report, length: reportLength)
            },
            context
        )

        // Schedule on the event thread's run loop so input reports arrive
        // directly on the thread that consumes them — no per-report hop, no
        // main-thread wakeups.
        let runLoop: CFRunLoop = eventThread.runLoop?.getCFRunLoop() ?? CFRunLoopGetMain()
        hidManagerRunLoop = runLoop
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.commonModes.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            os_log(
                "IOHIDManagerOpen returned 0x%{public}x; idle until a matching device opens",
                log: RawTouchLog.device,
                type: .error,
                openResult
            )
        }

        hidManager = manager
    }

    /// Closes the manager on the thread it is scheduled on, where its
    /// callbacks run: a callback is then never mid-flight — parsing a
    /// report buffer the close frees, or reaching this object through its
    /// unretained context — while the manager comes apart. The main queue
    /// waits; nothing on the event thread ever waits on the main queue.
    private func closeHIDManager() {
        guard let manager = hidManager else {
            return
        }
        hidManager = nil
        let runLoop = hidManagerRunLoop
        hidManagerRunLoop = nil

        let close = {
            IOHIDManagerRegisterInputReportCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            if let runLoop {
                IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.commonModes.rawValue)
            }
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if eventThread.performAndWait(close) == nil {
            close()  // no event thread: the manager was scheduled on the main run loop
        }
    }

    /// A matched device appeared (main queue). The capability read that
    /// admits it is a blocking feature-report GET, so it runs on
    /// `reportQueue` and admission resumes back here.
    private func deviceDidConnect(_ device: IOHIDDevice) {
        guard started,
            !validatingDevices.contains(where: { $0.device === device }),
            !openDevices.contains(where: { $0.device === device })
        else {
            return
        }

        // A fresh endpoint ID for this appearance: whatever is still queued
        // for a previous appearance of the same device carries the old one.
        let id = registry.allocateID()
        let open = OpenDevice(
            id: id, device: device, identity: DeviceIdentity(of: device), reportQueue: Self.makeReportQueue(for: id))
        validatingDevices.append(open)
        // Visible while the read is in flight: a caller deciding whether any
        // keyboard could still serve, on firmware without RawTouch mode,
        // must not conclude "none" while this one is still being read.
        publishStatus()

        readCapabilities(of: open) { [weak self] capabilities in
            self?.deviceDidValidate(id, capabilities: capabilities, attempt: 1)
        }
    }

    /// Reads a device's capability report on its report queue, `delay`
    /// from now, and hands the result to `landed` on the main queue.
    private func readCapabilities(
        of open: OpenDevice,
        after delay: TimeInterval = 0,
        landed: @escaping (RawTouchCapabilities?) -> Void
    ) {
        let device = open.device
        open.reportQueue.asyncAfter(deadline: .now() + delay) {
            let capabilities = RawTouchReportTransfers.readCapabilities(from: device)
            DispatchQueue.main.async {
                landed(capabilities)
            }
        }
    }

    /// The capability read landed (main queue): admit the device, read
    /// again once if it found no report, or explain why not. A device that
    /// disconnected while the read was in flight is no longer in
    /// `validatingDevices` and is dropped here.
    private func deviceDidValidate(_ id: RawTouchEndpointID, capabilities: RawTouchCapabilities?, attempt: Int) {
        // Keyed by the endpoint ID, not the device: a device that left and
        // came back mid-read is validating again under a new ID, and this
        // result belongs to the appearance that is gone.
        guard started, let index = validatingDevices.firstIndex(where: { $0.id == id }) else {
            return
        }

        // Still validating while the retry waits, so the device reads as
        // one that may yet serve, and a disconnect meanwhile drops it.
        if capabilities == nil, let delay = RawTouchReportTransfers.capabilityRetryDelay(afterAttempt: attempt) {
            retryCapabilityRead(of: validatingDevices[index], after: delay, attempt: attempt + 1)
            return
        }

        let open = validatingDevices.remove(at: index)
        // Squatter defense: validate before trusting anything this device
        // sends.
        guard let capabilities else {
            os_log(
                "Device %{public}@ has no supported raw touch feature report; treating as non-streaming",
                log: RawTouchLog.device,
                type: .info,
                open.productName
            )
            return
        }
        // Without the host lease the keyboard keeps scrolling on its own in
        // Standard mode, so synthesizing here would scroll twice.
        guard capabilities.supportsHostLease else {
            admitUnsupported(open)
            return
        }
        admit(open, capabilities: capabilities)
    }

    /// The capability read found no report: read again after `delay`.
    private func retryCapabilityRead(of open: OpenDevice, after delay: TimeInterval, attempt: Int) {
        os_log(
            "Device %{public}@ returned no raw touch feature report; reading it again in %{public}.0f s",
            log: RawTouchLog.device,
            type: .info,
            open.productName,
            delay
        )
        readCapabilities(of: open, after: delay) { [weak self] capabilities in
            self?.deviceDidValidate(open.id, capabilities: capabilities, attempt: attempt)
        }
    }

    /// A RawTouch device whose firmware has no host lease: reported per
    /// endpoint, so the menu can name the keyboard that needs updating
    /// while any other keyboard keeps working, and never leased or read.
    private func admitUnsupported(_ open: OpenDevice) {
        os_log(
            """
            Device %{public}@ over %{public}@ has no RawTouch mode support (host-lease capability missing); \
            not acquiring a lease. Update its firmware to a build that supports RawTouch mode
            """,
            log: RawTouchLog.lease,
            type: .error,
            open.productName,
            open.identity.transportName ?? "an unnamed transport"
        )
        registry.addUnsupported(.init(id: open.id, productName: open.productName, transport: open.identity.transport))
        openDevices.append(open)
        publishStatus()
    }

    /// A validated device joins: logged, registered under its device key,
    /// leased if that is wanted, and handed to the pipeline.
    private func admit(_ open: OpenDevice, capabilities: RawTouchCapabilities) {
        let deviceKey = open.identity.deviceKey(reporting: capabilities)
        logAdmission(of: open, capabilities: capabilities, deviceKey: deviceKey)

        registry.admit(
            .init(
                id: open.id,
                productName: open.productName,
                transport: open.identity.transport,
                capabilities: capabilities,
                deviceKey: deviceKey
            ))
        openDevices.removeAll { $0.device === open.device }
        openDevices.append(open)
        updateVerifiedDevices()

        // Acquire the lease at once if it is wanted: until it lands the
        // keyboard stays in Standard mode — scrolling with its own wheel
        // events and emitting no frames. A device whose lease is not wanted
        // is still admitted and reported: discovery is independent of the
        // lease.
        reconcileLeases()
        reconfigure()
        publishStatus()
    }

    /// The connect log: what the device reported, and the scroll gain it
    /// works out to on the main display.
    private func logAdmission(of open: OpenDevice, capabilities: RawTouchCapabilities, deviceKey: String?) {
        let pad = capabilities.primaryPad ?? .init()
        os_log(
            """
            RawTouch device connected: %{public}@ over %{public}@ as %{public}@, key %{public}@ (protocol \
            v%{public}d, pads 0x%{public}x; primary pad %{public}d counts/mm, rotate90=%{public}d \
            invertX=%{public}d invertY=%{public}d, max %{public}dx%{public}d)
            """,
            log: RawTouchLog.device,
            type: .info,
            open.productName,
            open.identity.transportName ?? "an unnamed transport",
            String(describing: open.id),
            deviceKey.map(RawTouchDeviceKey.redacted)
                ?? "none (no stable identifier; per-keyboard overrides unavailable)",
            capabilities.version,
            capabilities.padsPresent,
            pad.countsPerMM,
            pad.rotate90 ? 1 : 0,
            pad.invertX ? 1 : 0,
            pad.invertY ? 1 : 0,
            pad.xMax,
            pad.yMax
        )

        // The configured `scale` is a dimensionless gain, so log what it
        // works out to in the engine's own unit for the main display: the
        // one number to compare against when scrolling feels wrong. Every
        // gesture resolves this again for the display it happens on.
        let gain = configuration.resolvedGain(forPad: capabilities.primaryPadID ?? 0, deviceKey: deviceKey)
        let pointsPerMM = DisplayGeometry.pointsPerMM(of: CGMainDisplayID())
        os_log(
            """
            Scroll gain %{public}.2f = %{public}.3f points/count on the main display \
            (%{public}.2f points/mm, pad %{public}.0f counts/mm)
            """,
            log: RawTouchLog.device,
            type: .info,
            gain,
            RawTouchConfiguration.pointsPerCount(
                gain: gain,
                pointsPerMM: pointsPerMM,
                countsPerMM: pad.effectiveCountsPerMM
            ),
            pointsPerMM,
            pad.effectiveCountsPerMM
        )
    }

    private func deviceDidDisconnect(_ device: IOHIDDevice) {
        // A device that went away mid-validation must not be admitted when
        // its capability read lands.
        validatingDevices.removeAll { $0.device === device }

        guard let index = openDevices.firstIndex(where: { $0.device === device }) else {
            return
        }
        let open = openDevices.remove(at: index)

        os_log(
            "RawTouch device disconnected: %{public}@ (%{public}@)",
            log: RawTouchLog.device,
            type: .info,
            open.productName,
            String(describing: open.id)
        )
        registry.remove(open.id)
        // The endpoint's measurements go with it: a reconnect is a new
        // endpoint with fresh estimators.
        measuredLatencyMs = measuredLatencyMs.filter { $0.key.endpoint != open.id }
        verifiedDevicesLock.lock()
        lockedFirmwareVersionWatch.probe.forget(endpoint: open.id)
        verifiedDevicesLock.unlock()
        updateVerifiedDevices()
        // Stops the renewal timer when this was the last lease to renew.
        reconcileLeases()

        // The pipeline drops this endpoint's sources: if one of them owned
        // the gesture in flight it is closed out (canceled, no momentum) so
        // apps are not left mid-phase; a gesture on any other endpoint —
        // another keyboard, or this keyboard's other transport — carries on
        // untouched.
        reconfigure()
        publishStatus()
    }

    func updateVerifiedDevices() {
        let awaitingFromRegistry = registry.padsAwaitingFirmwareVersion

        verifiedDevicesLock.lock()
        // A pad the probe has written off (its half never announces a
        // version) drops out here, which takes its endpoint's frames off the
        // probe path entirely rather than leaving them to be examined for
        // the rest of the session.
        let awaiting = awaitingFromRegistry.filter { !lockedFirmwareVersionWatch.probe.hasGivenUp(on: $0) }
        let awaitingEndpoints = Set(awaiting.map(\.endpoint))
        lockedFirmwareVersionWatch.padsAwaiting = awaiting
        lockedVerifiedDevices = openDevices.compactMap { open in
            guard let entry = registry.entry(open.id) else {
                return nil  // unsupported firmware: never read
            }
            return VerifiedDevice(
                device: open.device,
                id: open.id,
                transport: entry.transport,
                awaitsFirmwareVersion: awaitingEndpoints.contains(open.id)
            )
        }
        verifiedDevicesLock.unlock()
    }

    // MARK: - Host lease (state on the main queue, writes on reportQueue)

    /// The timer that renews every requested lease; `reconcileLeases()`
    /// keeps exactly one running while any lease is requested.
    private func makeLeaseRenewalTimer() -> DispatchSourceTimer {
        // On the wall clock, not uptime: uptime stops while the Mac sleeps
        // but the firmware's lease timeout does not, so after a sleep longer
        // than the lease the keyboard is back in Standard mode. A wall-clock
        // deadline that fell due during sleep fires on wake, so every wanted
        // lease is re-acquired the moment the host is back, instead of up to
        // one renewal interval later.
        let interval = RawTouchLease.renewalInterval
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            // Each write publishes the status itself when it returns.
            registry.requestedLeases.forEach(acquireLease(on:))
        }
        timer.resume()
        return timer
    }

    /// Writes an acquire (or renewal) and records whether it landed, so
    /// `status.leaseHeld` (surfaced in the menu as RawTouch mode vs Standard
    /// mode) reflects the device's actual state rather than our intent. The
    /// write itself is a blocking transfer on `reportQueue`; the bookkeeping
    /// happens back on the main queue when it returns, so a slow BLE link never
    /// stalls the UI.
    ///
    /// The write carries the lease generation it was issued under, so a
    /// completion that a release has since overtaken cannot resurrect
    /// `leaseHeld` (see `LeaseState`). Only `reconcileLeases()` and the
    /// renewal timer call this, and only for an endpoint whose lease is
    /// wanted.
    private func acquireLease(on id: RawTouchEndpointID) {
        guard let open = openDevices.first(where: { $0.id == id }),
            let entry = registry.entry(id),
            let generation = registry.beginAcquire(id)
        else {
            return  // already gone
        }
        let device = open.device
        let label = RawTouchReportTransfers.label(entry)

        open.reportQueue.async { [weak self] in
            let held = RawTouchReportTransfers.writeLease(acquire: true, to: device, label: label)
            DispatchQueue.main.async { [weak self] in
                // Ignored when the endpoint has gone away or a release (or
                // a newer acquire) overtook this write meanwhile.
                self?.registry.completeAcquire(id, generation: generation, landed: held)
                self?.publishStatus()
            }
        }
    }

    /// Confirms the tap a pad parked at lift-off (`RawTouchTapConfirm`), on
    /// the endpoint the touch came in on — the one holding the lease, which
    /// is the only one the firmware takes it from. Fire and forget: the
    /// write rides the endpoint's report queue like a lease write, behind
    /// any renewal in flight, and a confirm that fails or lands after the
    /// firmware's window costs one click and nothing else, so it is logged
    /// at debug level and not retried.
    private func confirmTap(pad: UInt8, on id: RawTouchEndpointID) {
        guard let open = openDevices.first(where: { $0.id == id }), let entry = registry.entry(id) else {
            return  // the endpoint went away since the lift-off
        }
        let device = open.device
        let label = RawTouchReportTransfers.label(entry)

        open.reportQueue.async {
            let result = RawTouchReportTransfers.writeFeatureCommand(RawTouchTapConfirm.payload(pad: pad), to: device)
            os_log(
                "Tap confirm for pad %{public}d %{public}@ %{public}@ (0x%{public}x)",
                log: RawTouchLog.lease,
                type: .debug,
                Int(pad),
                result == kIOReturnSuccess ? "written to" : "failed on",
                label,
                result
            )
        }
    }

    /// Releases the lease on one device. `leaseHeld` drops immediately —
    /// the intent is what the status should show from here on — and the write
    /// goes out on the endpoint's report queue, behind any acquire already
    /// queued for the same device (the queue is serial). The shutdown path
    /// uses `releaseAllLeasesAndWait()` instead, which waits for the writes.
    private func releaseLease(on id: RawTouchEndpointID) {
        guard let open = openDevices.first(where: { $0.id == id }), let entry = registry.entry(id) else {
            return
        }
        registry.beginRelease(id)
        let device = open.device
        let label = RawTouchReportTransfers.label(entry)

        open.reportQueue.async {
            _ = RawTouchReportTransfers.writeLease(acquire: false, to: device, label: label)
        }
    }

    /// Releases every device's lease and waits (bounded) for the writes to
    /// complete: the process is exiting, and an unreleased lease leaves the
    /// keyboard out of Standard mode until the firmware's own timeout. The
    /// releases go out concurrently, one per endpoint queue, so a keyboard
    /// that blocks in its write (a Bluetooth endpoint vanishing mid-transfer)
    /// cannot starve another keyboard's release; each queue is serial, so
    /// any renewal already in flight on an endpoint finishes before its
    /// release goes out. Main queue only.
    private func releaseAllLeasesAndWait() {
        let devices = openDevices.compactMap { open -> (device: IOHIDDevice, queue: DispatchQueue, label: String)? in
            guard let entry = registry.entry(open.id) else {
                return nil  // unsupported firmware never held a lease
            }
            return (open.device, open.reportQueue, RawTouchReportTransfers.label(entry))
        }
        guard !devices.isEmpty else {
            return
        }
        // Every device, lease held or not: an acquire still in flight would
        // otherwise land after we are gone. The release is a no-op on the
        // firmware side when there was nothing to release.
        registry.beginReleaseAll()

        let done = DispatchGroup()
        for device in devices {
            device.queue.async(group: done) {
                _ = RawTouchReportTransfers.writeLease(acquire: false, to: device.device, label: device.label)
            }
        }

        if done.wait(timeout: .now() + Self.shutdownReleaseTimeout) == .timedOut {
            os_log(
                "Lease release did not complete within %{public}.0f s; the firmware lease will time out instead",
                log: RawTouchLog.lease,
                type: .error,
                Self.shutdownReleaseTimeout
            )
        }
    }

    // MARK: - Report handling (event thread)

    /// The endpoint ID and transport of a validated device, or nil when the
    /// device is not (or no longer) one this manager trusts — the admission
    /// check and the frame's tags in one lookup. `awaitsFirmwareVersion`
    /// says whether any of its pads is still missing its half's firmware
    /// version, so the frame path can skip the probe entirely otherwise.
    private func endpoint(of device: IOHIDDevice) -> VerifiedDevice? {
        verifiedDevicesLock.lock()
        defer { verifiedDevicesLock.unlock() }
        return lockedVerifiedDevices.first { $0.device === device }
    }

    /// Called by the HID input-report callback on the run loop the manager is
    /// scheduled on — the event thread.
    private func handleReport(
        from device: IOHIDDevice,
        reportID: UInt32,
        bytes: UnsafeMutablePointer<UInt8>,
        length: CFIndex
    ) {
        // Only touch frames (report ID 0x04) are ours. Depending on transport
        // and collection splitting — over BLE in particular — macOS can
        // deliver *other* input reports of the same HID service to this
        // matched device (e.g. ZMK's 9-byte mouse report), which would parse
        // as a phantom touch frame since `RawTouchFrame` accepts any
        // payload of sufficient length. Checked first: the integer compare is
        // free and this callback runs at ~100 Hz, while the verified-device
        // check below takes a lock and scans.
        guard reportID == RawTouchFrame.reportID else {
            return
        }

        guard let endpoint = endpoint(of: device) else {
            return
        }

        // Parse straight out of the callback's buffer — no per-report heap
        // allocation. The payload may or may not repeat the report ID as its
        // first byte, depending on the transport; `ReportFraming` knows the
        // rule and says where the frame starts.
        let payload = UnsafeRawBufferPointer(start: bytes, count: length)
        guard
            let offset = ReportFraming.payloadOffset(
                bufferLength: length,
                firstByte: length > 0 ? bytes[0] : nil,
                reportID: UInt8(RawTouchFrame.reportID),
                payloadLength: RawTouchFrame.payloadLength
            )
        else {
            // Too short to be a frame either way: drop silently.
            return
        }

        guard
            var frame = RawTouchFrame(
                reportBytes: payload,
                offset: offset,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
        else {
            // Malformed/short report: drop silently (never crash).
            return
        }
        // Not on the wire: the endpoint the report came in on is the host's
        // knowledge. Its transport is for the log; its ID, with the pad ID,
        // is the frame's source — and a frame still queued when its endpoint
        // is replaced carries the old ID, which the pipeline no longer
        // knows, so it is dropped there.
        frame.transport = endpoint.transport
        frame.endpoint = endpoint.id

        // Almost always false, and then this costs one branch: only a
        // keyboard with a pad whose half has not announced its firmware
        // version is watched, and only until it does (or is given up on).
        if endpoint.awaitsFirmwareVersion {
            noteFrameForFirmwareVersion(
                source: RawTouchSourceID(endpoint: endpoint.id, padID: frame.padID),
                touched: frame.touched,
                now: frame.timestamp
            )
        }

        if eventThread.isCurrent {
            pipeline.handle(wireFrame: frame)
        } else {
            eventThread.perform { [pipeline] in
                pipeline.handle(wireFrame: frame)
            }
        }
    }
}
