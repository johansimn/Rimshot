import Accelerate
import AppKit
import AudioToolbox
import CoreAudio
import os

/// Captures Spotify's audio output with a Core Audio process tap and feeds it to the beat detector.
/// Spotify's own playback is untouched (the tap is private and unmuted) and nothing is recorded:
/// samples are analysed in memory and dropped.
///
/// The tap targets Spotify by bundle ID with process restore (macOS 26), so the HAL itself adds
/// and drops Spotify's processes as it launches, quits or relaunches. The chain is only rebuilt
/// when the output device, its format, or coreaudiod itself changes, or when a watchdog notices
/// the stream has stalled. All setup and teardown is serialised on `control`.
final class SpotifyAudioTap: @unchecked Sendable {
    enum Status: Equatable {
        case off
        case waiting            // Spotify isn't playing anything yet
        case listening          // hearing sound
        case silent             // tap running, Spotify quiet
        case denied             // buffers arrive but are all zeros while Spotify is outputting
        case failed(String)
    }

    static let spotifyBundleIDs = ["com.spotify.client", "com.spotify.client.helper"]

    private let control = DispatchQueue(label: "local.rimshot.tap-control")
    private let io = DispatchQueue(label: "local.rimshot.tap-io", qos: .userInteractive)
    private let detector = BeatDetector()
    private let state = OSAllocatedUnfairLock(initialState: Status.off)
    private let ioStats = OSAllocatedUnfairLock(initialState: IOStats())

    private struct IOStats {
        var lastCallback: Double = 0
        var lastNonZero: Double = 0
    }

    // Owned by `control`.
    private var requested = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var watchdog: DispatchSourceTimer?
    private var listening = false
    private var builtAt: Double = 0
    private var lastRebuild: Double = 0
    private var pendingRebuild: DispatchWorkItem?
    private var deviceLatency: Double = 0
    private var userOffset: Double = 0
    private var clockWithOutputDevice = false
    private var analysisHop = 512
    private var zeroRebuilds = 0
    private var beatLog: (time: Double, count: UInt64) = (0, 0)

    var status: Status { state.withLock { $0 } }

    // MARK: Public controls (any thread)

    func start() {
        control.async { [self] in
            guard !requested else { return }
            requested = true
            addListeners()
            let timer = DispatchSource.makeTimerSource(queue: control)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            watchdog = timer
            zeroRebuilds = 0
            rebuild()
        }
    }

    func stop() {
        control.async { [self] in stopOnControl() }
    }

    /// Synchronous teardown for app termination: a tap left behind lingers in coreaudiod.
    func stopNow() {
        control.sync { stopOnControl() }
    }

    func setSensitivity(_ value: Double) { detector.setSensitivity(value) }

    /// A new song started: its tempo has nothing to do with the last one's.
    func resetTempo() { detector.resetTempo() }

    /// Extreme quality analyses in smaller hops for lower latency; takes effect via a rebuild.
    func setAnalysisHop(_ hop: Int) {
        control.async { [self] in
            guard hop != analysisHop else { return }
            analysisHop = hop
            if requested { rebuild() }
        }
    }

    func setSyncOffset(milliseconds: Double) {
        control.async { [self] in
            userOffset = milliseconds / 1000
            detector.setLatency(deviceLatency + userOffset)
        }
    }

    // MARK: Control queue

    private func stopOnControl() {
        guard requested else { return }
        requested = false
        watchdog?.cancel()
        watchdog = nil
        pendingRebuild?.cancel()
        removeListeners()
        teardown()
        setStatus(.off)
    }

    private func setStatus(_ s: Status) {
        let old = state.withLock { st -> Status in let o = st; st = s; return o }
        if old != s { log.notice("Beat sync status: \(String(describing: s), privacy: .public)") }
    }

    private lazy var debugFile: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Rimshot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("onsets.csv")
        FileManager.default.createFile(atPath: url.path, contents: Data("time,flux,threshold,ratio,high,beat,accent,period,confidence,phase\n".utf8))
        log.notice("Writing onset features to \(url.path, privacy: .public)")
        return try? FileHandle(forWritingTo: url)
    }()

    /// Appends the detector's captured features (never audio) to ~/Library/Logs/Rimshot/onsets.csv.
    private func writeDebugRows() {
        let rows = detector.drainDebugRows()
        guard !rows.isEmpty, let file = debugFile else { return }
        var text = ""
        for r in rows {
            text += String(format: "%.4f,%.4f,%.4f,%.3f,%.4f,%.3f,%.3f,%.4f,%.3f,%.3f\n",
                           r.time, r.flux, r.threshold, r.ratio, r.high, r.beat, r.accent, r.period, r.confidence, r.phase)
        }
        file.seekToEndOfFile()
        file.write(Data(text.utf8))
    }

    fileprivate func scheduleRebuild() {
        control.async { [self] in
            guard requested else { return }
            pendingRebuild?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.rebuild() }
            pendingRebuild = work
            control.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    /// coreaudiod restarted: every object ID and listener we hold is stale.
    fileprivate func serviceRestarted() {
        control.async { [self] in
            guard requested else { return }
            listening = false
            tapID = kAudioObjectUnknown
            aggregateID = kAudioObjectUnknown
            procID = nil
            addListeners()
            rebuild()
        }
    }

    private func tick() {
        guard requested else { return }
        if case .failed = status, aggregateID == kAudioObjectUnknown {
            // Retry a failed setup every few seconds (e.g. no output device for a moment).
            if CACurrentMediaTime() - lastRebuild > 5 { rebuild() }
            return
        }
        guard aggregateID != kAudioObjectUnknown else { return }

        let now = CACurrentMediaTime()
        let stats = ioStats.withLock { $0 }
        let outputting = spotifyIsOutputting()
        let heard = now - BeatState.shared.snapshot.lastSoundTime < 1.5

        if now - stats.lastNonZero < 1.5 { zeroRebuilds = 0 }

        if now - beatLog.time >= 10 {
            let snap = BeatState.shared.snapshot
            if heard, beatLog.time > 0 {
                let rate = Double(snap.beatCount &- beatLog.count) / (now - beatLog.time) * 60
                let tempo = snap.period > 0 ? Int((60 / snap.period).rounded()) : 0
                log.notice("Beats: \(Int(rate), privacy: .public)/min over 10 s; tempo \(tempo, privacy: .public) BPM, confidence \(String(format: "%.2f", snap.tempoConfidence), privacy: .public)")
            }
            beatLog = (now, snap.beatCount)
        }
        if BeatDetector.debugEnabled { writeDebugRows() }

        if heard {
            setStatus(.listening)
        } else if outputting && now - builtAt > 3 && now - stats.lastCallback < 1.5 && now - stats.lastNonZero > 3 {
            // Callbacks keep arriving but carry only zeros while Spotify plays. Usually that's a
            // declined permission, occasionally a stuck tap, which only a full rebuild fixes.
            if zeroRebuilds < 1 {
                zeroRebuilds += 1
                rebuild()
            } else {
                setStatus(.denied)
            }
            return
        } else {
            setStatus(outputting ? .silent : .waiting)
        }

        // Watchdog: Spotify is playing but our IO proc went quiet. Rebuild at most every 5 s, and
        // never while the display sleeps (nobody could answer a permission prompt).
        if outputting, now - stats.lastCallback > 2.5, now - builtAt > 3, now - lastRebuild > 5,
           CGDisplayIsAsleep(CGMainDisplayID()) == 0 {
            rebuild()
        }
    }

    private func rebuild() {
        guard requested else { return }
        lastRebuild = CACurrentMediaTime()
        teardown()
        do {
            try build()
        } catch {
            // A tap-only device can fail to start on some setups; clock it with the output device instead.
            teardown()
            if !clockWithOutputDevice {
                clockWithOutputDevice = true
                do { try build() } catch {
                    teardown()
                    clockWithOutputDevice = false
                    log.error("Audio tap failed: \(error.localizedDescription, privacy: .public)")
                    setStatus(.failed(error.localizedDescription))
                    return
                }
            } else {
                log.error("Audio tap failed: \(error.localizedDescription, privacy: .public)")
                setStatus(.failed(error.localizedDescription))
                return
            }
        }
        builtAt = CACurrentMediaTime()
        log.notice("Audio tap built (output-clocked: \(self.clockWithOutputDevice, privacy: .public), latency \(Int(self.deviceLatency * 1000), privacy: .public) ms)")
        setStatus(spotifyIsOutputting() ? .silent : .waiting)
    }

    // MARK: Core Audio

    private struct TapError: LocalizedError {
        let what: String
        let code: OSStatus
        var errorDescription: String? { code == 0 ? what : "\(what) (\(code))" }
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw TapError(what: what, code: status) }
    }

    private func build() throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: spotifyProcessObjects())
        desc.bundleIDs = Self.spotifyBundleIDs
        desc.isProcessRestoreEnabled = true
        desc.name = "Rimshot Spotify Beat Sync"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "Couldn't create the audio tap")
        tapID = tap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format), "Couldn't read the tap format")
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            throw TapError(what: "Unexpected tap audio format", code: 0)
        }

        // Tap-only by default: adding the output device would also open its input streams, which
        // on a headset means the microphone (and AirPods dropping into call-quality audio).
        let output = try defaultOutputDevice()
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Rimshot Spotify Tap",
            kAudioAggregateDeviceUIDKey: "local.rimshot.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ] as [String: Any]],
        ]
        if clockWithOutputDevice {
            let uid = try deviceUID(output)
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = uid
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
        }
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg), "Couldn't create the capture device")
        aggregateID = agg

        deviceLatency = outputLatency(of: output, sampleRate: format.mSampleRate)
        detector.configure(sampleRate: format.mSampleRate, hop: analysisHop)
        detector.setLatency(deviceLatency + userOffset)
        ioStats.withLock { $0 = IOStats() }

        var proc: AudioDeviceIOProcID?
        let block = Self.makeIOBlock(detector: detector, stats: ioStats,
                                     interleaved: format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                                     channels: Int(format.mChannelsPerFrame))
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, io, block), "Couldn't create the audio callback")
        procID = proc
        // The System Audio Recording prompt appears here the first time.
        try check(AudioDeviceStart(aggregateID, procID), "Couldn't start audio capture")
    }

    /// Built outside any actor so the closure isn't inferred to be main-actor isolated (in Swift 6
    /// that inserts an executor check that traps on the audio thread). Captures only thread-safe state.
    private static func makeIOBlock(detector: BeatDetector, stats: OSAllocatedUnfairLock<IOStats>,
                                    interleaved: Bool, channels: Int) -> AudioDeviceIOBlock {
        return { @Sendable _, input, inputTime, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let now = CACurrentMediaTime()
            var peak: Float = 0
            if let b = abl.first, let p = b.mData?.assumingMemoryBound(to: Float.self), b.mDataByteSize > 0 {
                vDSP_maxmgv(p, 1, &peak, vDSP_Length(Int(b.mDataByteSize) / MemoryLayout<Float>.size))
            }
            let nonZero = peak > 0
            stats.withLock { s in
                s.lastCallback = now
                if nonZero { s.lastNonZero = now }
            }
            let host = inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : 0
            detector.process(abl, interleaved: interleaved, channels: channels, hostTime: host)
        }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
    }

    // MARK: Listeners
    //
    // Uses the C-function listener API: removing a *block* listener from Swift silently does
    // nothing, because every call bridges a new block.

    private static let systemSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioHardwarePropertyServiceRestarted,
    ]

    private func addListeners() {
        guard !listening else { return }
        listening = true
        let me = Unmanaged.passUnretained(self).toOpaque()
        for sel in Self.systemSelectors {
            var a = address(sel)
            AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &a, halListener, me)
        }
    }

    private func removeListeners() {
        guard listening else { return }
        listening = false
        let me = Unmanaged.passUnretained(self).toOpaque()
        for sel in Self.systemSelectors {
            var a = address(sel)
            AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &a, halListener, me)
        }
    }

    // MARK: Property helpers

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func spotifyProcessObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.filter {
            let id = bundleID(of: $0) ?? ""
            return id == "com.spotify.client" || id.hasPrefix("com.spotify.client.")
        }
    }

    private func spotifyIsOutputting() -> Bool {
        spotifyProcessObjects().contains { object in
            var addr = address(kAudioProcessPropertyIsRunningOutput)
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &running) == noErr && running != 0
        }
    }

    private func bundleID(of object: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func defaultOutputDevice() throws -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device),
                  "No audio output device")
        guard device != kAudioObjectUnknown else { throw TapError(what: "No audio output device", code: 0) }
        return device
    }

    private func deviceUID(_ device: AudioObjectID) throws -> String {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = address(kAudioDevicePropertyDeviceUID)
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid), "Couldn't read the output device")
        guard let uid else { throw TapError(what: "Output device has no ID", code: 0) }
        return uid.takeRetainedValue() as String
    }

    /// Seconds between audio being handed to the output device and it reaching the listener.
    private func outputLatency(of device: AudioObjectID, sampleRate: Double) -> Double {
        func frames(_ selector: AudioObjectPropertySelector, _ object: AudioObjectID) -> UInt32 {
            var addr = address(selector, kAudioObjectPropertyScopeOutput)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : 0
        }
        var total = frames(kAudioDevicePropertyLatency, device)
            + frames(kAudioDevicePropertySafetyOffset, device)
            + frames(kAudioDevicePropertyBufferFrameSize, device)

        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size >= 4 {
            var streams = [AudioObjectID](repeating: 0, count: Int(size) / 4)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr, let first = streams.first {
                var sAddr = address(kAudioStreamPropertyLatency)
                var v: UInt32 = 0
                var s = UInt32(4)
                if AudioObjectGetPropertyData(first, &sAddr, 0, nil, &s, &v) == noErr { total += v }
            }
        }
        return sampleRate > 0 ? Double(total) / sampleRate : 0
    }
}

/// HAL property listener (C function, so it can be removed again). Runs on a HAL notification thread.
private func halListener(_ object: AudioObjectID, _ count: UInt32,
                         _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
                         _ client: UnsafeMutableRawPointer?) -> OSStatus {
    guard let client else { return noErr }
    let tap = Unmanaged<SpotifyAudioTap>.fromOpaque(client).takeUnretainedValue()
    let selectors = UnsafeBufferPointer(start: addresses, count: Int(count)).map(\.mSelector)
    if selectors.contains(kAudioHardwarePropertyServiceRestarted) {
        tap.serviceRestarted()
    } else {
        tap.scheduleRebuild()
    }
    return noErr
}
