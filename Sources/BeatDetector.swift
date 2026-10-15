import Accelerate
import AudioToolbox
import QuartzCore

/// Realtime kick tracker. Fed the tap's buffers on the audio queue and publishes beats, loudness and
/// a slow "breathing" value into `BeatState`. Allocation-free after `configure`.
///
/// Onset strength is positive spectral flux over the kick band only (40–150 Hz), log-compressed
/// relative to the band's recent peak so quiet and loud masters behave the same and hi-hats can't
/// trigger it. A beat fires on the rising edge through an adaptive threshold
/// `max(median + k·MAD over ~1 s, floor · recent flux peak)`; the floor is what keeps breakdowns
/// and quiet passages from producing phantom beats. Off-beat bass notes are softened by comparing
/// kick-band flux with low-mid (150–600 Hz) flux.
///
/// On top of that runs a tempo tracker: the autocorrelation of the last ~6 s of onset strength gives
/// the beat period, a comb over the same signal gives the phase, and the resulting grid is
/// published so the renderer can land pulses exactly on the beat (and fill single missed kicks).
/// Once the grid is confident, onsets far from it (off-beat bass, syncopation) are demoted to
/// accents instead of full beats.
final class BeatDetector: @unchecked Sendable {
    struct DebugRow {
        var time: Double, flux: Float, threshold: Float, ratio: Float, high: Float
        var beat: Float, accent: Float, period: Double, confidence: Float, phase: Float
    }

    private let fftSize = 2048
    private var hop = 512
    private let log2n: vDSP_Length = 11

    private let fftSetup: FFTSetup
    private var window: [Float]
    private var ring: [Float]
    private var ringWrite = 0
    private var pending = 0
    private var frame: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var prevKick: [Float]
    private var prevMid: [Float]
    private var prevMidSelf: [Float]

    private var sampleRate: Double = 48_000
    private var hopSeconds: Double = 512.0 / 48_000
    private var kickBins = 2...6
    private var midBins = 7...26
    private var highBins = 64...341

    private var history: [Float]
    private var accentHistory: [Float]
    private var prevHigh: [Float]
    private var highPeak: Float = 1e-6
    private var accentPeak: Float = 1e-6
    private var prevAccent: Float = 0
    private var lastAccent: Double = -10
    private var historyCount = 0
    private var historyIndex = 0
    private var scratch: [Float]

    private var kickPeak: Float = 1e-6
    private var midPeak: Float = 1e-6
    private var fluxPeak: Float = 1e-6
    private var prevFlux: Float = 0
    private var lastBeat: Double = -10
    private var onsetWindowEnd: Double = 0
    private var loudPeak: Float = 1e-4
    private var bassAverage: Float = 0
    private var breath: Float = 0
    private var gateOpen = false

    // Spectrum bands for the equalizer edges.
    static let bandCount = 24
    private var bandRanges: [(lo: Int, hi: Int)] = []
    private var bandPeak = [Float](repeating: 1e-6, count: 24)
    private var bandValue = [Float](repeating: 0, count: 24)
    private var bandFloor = [Float](repeating: 0.06, count: 24)

    // The spectrum and loudness are delayed by the output latency (like the beats are stamped), so
    // the equalizer stays in step with what you hear, e.g. on Bluetooth headphones.
    private var delayFrames = 1
    private var bandHistory = [Float](repeating: 0, count: 24)
    private var levelHistory = [Float](repeating: 0, count: 1)
    private var powerHistory = [Float](repeating: 0, count: 1)
    private var historyWrite = 0

    // Tempo tracking: onset strength per hop over ~6 s, and the grid derived from it.
    private var env = [Float](repeating: 0, count: 2048)
    private var envLength = 560
    private var envWrite = 0
    private var envFilled = 0
    private var envScratch = [Float](repeating: 0, count: 2048)
    private var acf = [Float](repeating: 0, count: 512)
    private var hopsSinceTempo = 0
    private var period: Double = 0          // seconds per beat, 0 while unknown
    private var confidence: Float = 0
    private var gridTime: Double = 0        // tap time of a beat on the grid
    private var pendingPeriod: Double = 0
    private var pendingVotes = 0

    // Written from the control/main side, read per hop. Plain stores of word-sized values.
    private var sensitivity: Float = 0.55
    private var latency: Double = 0
    private var tempoResetRequested = false

    /// Forget the current tempo (a new song started).
    func resetTempo() { tempoResetRequested = true }

    /// Per-hop feature capture for tuning (`defaults write local.rimshot.app debugOnsets -bool true`).
    /// Never captures audio, only the numbers below.
    static let debugEnabled = UserDefaults.standard.bool(forKey: "debugOnsets")
    /// Read once here (main thread) so the audio thread never touches UserDefaults.
    private let debug = BeatDetector.debugEnabled
    private let debugLock = NSLock()
    private var debugRows: [DebugRow] = []

    func drainDebugRows() -> [DebugRow] {
        debugLock.lock(); defer { debugLock.unlock() }
        let rows = debugRows
        debugRows.removeAll(keepingCapacity: true)
        return rows
    }

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: fftSize)
        frame = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        mags = [Float](repeating: 0, count: fftSize / 2)
        prevKick = [Float](repeating: 0, count: 64)
        prevMid = [Float](repeating: 0, count: 64)
        prevMidSelf = [Float](repeating: 0, count: 64)
        history = [Float](repeating: 0, count: 128)
        accentHistory = [Float](repeating: 0, count: 128)
        prevHigh = [Float](repeating: 0, count: 512)
        scratch = [Float](repeating: 0, count: 128)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Call before audio starts flowing (not concurrently with `process`). A 256-sample hop halves
    /// detection latency at twice the (still tiny) CPU cost.
    func configure(sampleRate rate: Double, hop newHop: Int = 512) {
        sampleRate = rate > 0 ? rate : 48_000
        hop = newHop
        hopSeconds = Double(hop) / sampleRate
        let binHz = sampleRate / Double(fftSize)
        func bin(_ hz: Double) -> Int { max(1, min(fftSize / 2 - 1, Int((hz / binHz).rounded()))) }
        kickBins = bin(40)...max(bin(40) + 1, bin(150))
        midBins = (kickBins.upperBound + 1)...max(kickBins.upperBound + 2, bin(600))
        highBins = bin(1_500)...max(bin(1_500) + 1, bin(8_000))
        // 24 log-spaced bands from 40 Hz to 14 kHz, each at least one FFT bin wide.
        bandRanges = (0..<Self.bandCount).map { i in
            let f0 = 40 * pow(14_000.0 / 40, Double(i) / Double(Self.bandCount))
            let f1 = 40 * pow(14_000.0 / 40, Double(i + 1) / Double(Self.bandCount))
            let lo = bin(f0)
            return (lo, max(lo, bin(f1) - 1))
        }
        for i in 0..<Self.bandCount {
            bandPeak[i] = 1e-6
            bandValue[i] = 0
            // Music's spectrum falls ~5 dB per octave, so the noise floor slopes down with frequency;
            // a flat floor would pin every band above ~1.5 kHz near zero.
            let centre = 40 * pow(14_000.0 / 40, (Double(i) + 0.5) / Double(Self.bandCount))
            bandFloor[i] = Float(0.06 * min(1, 500 / centre))
        }
        delayFrames = Int((0.7 / hopSeconds).rounded(.up)) + 1
        bandHistory = [Float](repeating: 0, count: delayFrames * Self.bandCount)
        levelHistory = [Float](repeating: 0, count: delayFrames)
        powerHistory = [Float](repeating: 0, count: delayFrames)
        historyWrite = 0
        // Tempo buffers sized for this rate: ~6 s of onsets, lags up to 1 s (and twice that).
        let envCount = Int((6.0 / hopSeconds).rounded(.up)) + 1
        env = [Float](repeating: 0, count: envCount)
        envScratch = [Float](repeating: 0, count: envCount)
        acf = [Float](repeating: 0, count: 2 * Int((1.0 / hopSeconds).rounded(.up)) + 4)
        bassAverage = 0; breath = 0; loudPeak = 1e-4
        let historyLength = min(max(Int(1.0 / hopSeconds), 16), 256)
        if scratch.count < historyLength { scratch = [Float](repeating: 0, count: historyLength) }
        history = [Float](repeating: 0, count: historyLength)
        accentHistory = [Float](repeating: 0, count: historyLength)
        scratch = [Float](repeating: 0, count: historyLength)
        prevHigh = [Float](repeating: 0, count: highBins.count)
        highPeak = 1e-6; accentPeak = 1e-6; prevAccent = 0
        prevKick = [Float](repeating: 0, count: kickBins.count)
        prevMid = [Float](repeating: 0, count: midBins.count)
        prevMidSelf = [Float](repeating: 0, count: midBins.count)
        historyCount = 0
        historyIndex = 0
        ringWrite = 0
        pending = 0
        kickPeak = 1e-6; midPeak = 1e-6; fluxPeak = 1e-6
        prevFlux = 0
        gateOpen = false
        envLength = min(Int(6.0 / hopSeconds), env.count)
        envWrite = 0; envFilled = 0; hopsSinceTempo = 0
        period = 0; confidence = 0; gridTime = 0; pendingPeriod = 0; pendingVotes = 0
    }

    func setSensitivity(_ s: Double) { sensitivity = Float(min(max(s, 0), 1)) }

    /// Seconds between the tap seeing audio and the listener hearing it (output device latency
    /// plus the user's sync offset). Beats are stamped this far in the future.
    func setLatency(_ seconds: Double) { latency = seconds }

    /// Feed one IO buffer. `hostTime` is the buffer's `mHostTime`.
    func process(_ abl: UnsafeMutableAudioBufferListPointer, interleaved: Bool, channels: Int, hostTime: UInt64) {
        guard let first = abl.first, let p0 = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let start = hostTime != 0 ? AudioConvertHostTimeToNanos(hostTime) : 0
        let bufferStart = start != 0 ? Double(start) / 1e9 : CACurrentMediaTime()

        if interleaved {
            let ch = max(channels, 1)
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let scale = 1 / Float(ch)
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<ch { s += p0[i * ch + c] }
                push(s * scale, at: bufferStart, index: i)
            }
        } else {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let planes = abl.count
            let scale = 1 / Float(max(planes, 1))
            for i in 0..<frames {
                var s: Float = 0
                for b in 0..<planes {
                    if let p = abl[b].mData?.assumingMemoryBound(to: Float.self) { s += p[i] }
                }
                push(s * scale, at: bufferStart, index: i)
            }
        }
    }

    @inline(__always)
    private func push(_ x: Float, at bufferStart: Double, index: Int) {
        ring[ringWrite] = x.isFinite ? x : 0   // one bad sample must never poison the analysis
        ringWrite = (ringWrite + 1) & (fftSize - 1)
        pending += 1
        if pending >= hop {
            pending = 0
            analyse(at: bufferStart + Double(index + 1) / sampleRate)
        }
    }

    private func analyse(at time: Double) {
        let n = fftSize
        // Unroll the ring so the newest sample is last.
        let tail = n - ringWrite
        ring.withUnsafeBufferPointer { r in
            frame.withUnsafeMutableBufferPointer { f in
                for i in 0..<tail { f[i] = r[ringWrite + i] }
                for i in 0..<ringWrite { f[tail + i] = r[i] }
            }
        }

        // Loudness of the newest hop, in dBFS, through a silence gate with hysteresis.
        var rms: Float = 0
        frame.withUnsafeBufferPointer { f in
            vDSP_rmsqv(f.baseAddress! + (n - hop), 1, &rms, vDSP_Length(hop))
        }
        let db = 20 * log10f(max(rms, 1e-9))
        if gateOpen, db < -60 { gateOpen = false } else if !gateOpen, db > -50 { gateOpen = true }

        if !gateOpen {
            // Silence still counts as time passing: the tempo tracker measures periods in hops, so
            // skipping quiet hops would squeeze its timeline (128 BPM read as 144 on a sparse groove).
            env[envWrite] = 0
            envWrite = (envWrite + 1) % envLength
            envFilled = min(envFilled + 1, envLength)
            prevFlux = 0
            prevAccent = 0
            publish(time: time, level: 0, power: 0, beat: nil, accent: nil, sounding: false)
            return
        }

        frame.withUnsafeMutableBufferPointer { f in
            vDSP_vmul(f.baseAddress!, 1, window, 1, f.baseAddress!, 1, vDSP_Length(n))
        }
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                frame.withUnsafeBufferPointer { f in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                im[0] = 0  // drop the packed Nyquist value
                mags.withUnsafeMutableBufferPointer { m in
                    vDSP_zvabs(&split, 1, m.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }

        let dt = Float(hopSeconds)

        // Equalizer bands: mean magnitude per band against that band's own slowly decaying peak,
        // floored by the loudest band so near-silent bands don't get amplified into noise.
        var loudestPeak: Float = 1e-6
        for i in 0..<Self.bandCount {
            let r = bandRanges[i]
            var sum: Float = 0
            for k in r.lo...r.hi { sum += mags[k] }
            let e = sum / Float(r.hi - r.lo + 1)
            bandPeak[i] = max(e, bandPeak[i] * expf(-dt / 3))
            loudestPeak = max(loudestPeak, bandPeak[i])
            bandValue[i] = e
        }
        for i in 0..<Self.bandCount {
            bandValue[i] = min(bandValue[i] / max(bandPeak[i], bandFloor[i] * loudestPeak), 1)
        }

        // Level-relative log compression: v = log1p(10 · mag / recentPeak).
        var kickMax: Float = 0, midMax: Float = 0, bassEnergy: Float = 0
        for k in kickBins { kickMax = max(kickMax, mags[k]); bassEnergy += mags[k] * mags[k] }
        for k in midBins { midMax = max(midMax, mags[k]) }
        kickPeak = max(kickMax, kickPeak * expf(-dt / 6))
        midPeak = max(midMax, midPeak * expf(-dt / 6))

        var kickFlux: Float = 0
        for (j, k) in kickBins.enumerated() {
            let v = log1pf(10 * mags[k] / kickPeak)
            kickFlux += max(0, v - prevKick[j])
            prevKick[j] = v
        }
        // Low-mid flux two ways: against the kick band's reference (compares actual energy, used
        // for strength) and against its own reference (tells kicks from bass-note changes).
        var midFlux: Float = 0, midFluxSelf: Float = 0
        for (j, k) in midBins.enumerated() {
            let v = log1pf(10 * mags[k] / kickPeak)
            midFlux += max(0, v - prevMid[j])
            prevMid[j] = v
            let w = log1pf(10 * mags[k] / midPeak)
            midFluxSelf += max(0, w - prevMidSelf[j])
            prevMidSelf[j] = w
        }
        let lo = kickFlux / Float(kickBins.count)
        let mid = midFlux / Float(midBins.count)
        let midSelf = midFluxSelf / Float(midBins.count)
        let flux = kickFlux

        // Adaptive threshold: median + k·MAD over the last second, floored by the recent peak.
        fluxPeak = max(flux, fluxPeak * expf(-dt / 3))
        history[historyIndex] = flux
        historyIndex = (historyIndex + 1) % history.count
        historyCount = min(historyCount + 1, history.count)
        let (median, mad) = medianAndMAD(of: history)
        let sens = sensitivity
        let kMAD = 2.6 - 1.2 * sens
        let floorShare = 0.5 - 0.27 * sens
        let threshold = max(median + kMAD * mad, floorShare * fluxPeak, 0.02)
        let refractory = 0.2 - 0.06 * Double(sens)

        // Accents: snares, claps and other sharp hits, from flux in 1.5–8 kHz. They make the
        // travelling lights sparkle; hi-hats are kept small by the same threshold rule as kicks.
        var highMax: Float = 0
        for k in highBins { highMax = max(highMax, mags[k]) }
        highPeak = max(highMax, highPeak * expf(-dt / 6))
        var highFlux: Float = 0
        for (j, k) in highBins.enumerated() {
            let v = log1pf(10 * mags[k] / highPeak)
            highFlux += max(0, v - prevHigh[j])
            prevHigh[j] = v
        }
        highFlux /= Float(highBins.count)
        accentPeak = max(highFlux, accentPeak * expf(-dt / 3))

        // Onset strength for the tempo tracker: kick-led, with some help from the highs for music
        // without a steady kick.
        env[envWrite] = flux / max(fluxPeak, 1e-6) + 0.5 * highFlux / max(accentPeak, 1e-6)
        envWrite = (envWrite + 1) % envLength
        envFilled = min(envFilled + 1, envLength)
        if tempoResetRequested {
            tempoResetRequested = false
            envFilled = 0; period = 0; confidence = 0; gridTime = 0; pendingVotes = 0
        }
        hopsSinceTempo += 1
        if hopsSinceTempo * hop >= Int(sampleRate / 2) {
            hopsSinceTempo = 0
            estimateTempo(now: time)
        }

        var beat: Float?
        var accent: Float?
        // A kick's onset is concentrated below 150 Hz; a bass-line note change lights up the low
        // mids just as much. On a synthetic mix with an off-beat saw bass, the self-referenced
        // low/mid ratio was never below 1.0 for kicks but was for 31 of 43 bass-note triggers;
        // the energy ratio then scales strength (kicks ~5-7, bass notes ~3).
        let gate = 1.25 - 0.4 * sens
        let ratio = lo / max(midSelf, 1e-6)
        let gridPhase = phaseOnGrid(time)
        // An onset opens a short window: a kick's very first instant (its click) is broadband and can
        // fail the kick/bass test, while the next few clearly pass. Fire on the first instant that does.
        if flux > threshold, prevFlux <= threshold, time - lastBeat > refractory, historyCount > 8 {
            onsetWindowEnd = time + 0.03
        }
        if time <= onsetWindowEnd, flux > threshold, ratio >= gate {
            onsetWindowEnd = 0
            let kickness = min(max((lo / max(mid, 1e-6) - 1) / 4, 0.4), 1)
            let strength = min(max(flux / fluxPeak, 0.35), 1) * kickness
            if let ph = gridPhase, abs(ph) > 0.2 {
                // Well off the beat grid: an off-beat bass note or syncopation. Sparkle, don't flash.
                accent = strength * 0.6
            } else {
                beat = strength
                // Phase-lock: each on-beat kick pulls the grid a quarter of the way onto itself.
                if let ph = gridPhase { gridTime += 0.25 * Double(ph) * period }
            }
            lastBeat = time
        }
        prevFlux = flux

        accentHistory[historyIndex == 0 ? accentHistory.count - 1 : historyIndex - 1] = highFlux
        let (aMedian, aMAD) = medianAndMAD(of: accentHistory)
        let aThreshold = max(aMedian + (3.0 - 1.2 * sens) * aMAD, (0.55 - 0.2 * sens) * accentPeak, 1e-3)
        if highFlux > aThreshold, prevAccent <= aThreshold, time - lastAccent > 0.09, historyCount > 8 {
            accent = max(accent ?? 0, min(max(highFlux / accentPeak, 0.3), 1))
            lastAccent = time
        }
        prevAccent = highFlux

        if debug {
            let row = DebugRow(time: time, flux: flux, threshold: threshold, ratio: ratio, high: highFlux,
                               beat: beat ?? 0, accent: accent ?? 0, period: period, confidence: confidence,
                               phase: gridPhase ?? .nan)
            debugLock.lock(); debugRows.append(row); debugLock.unlock()
        }

        // Breathing: bass energy relative to its own ~4 s average (1.0 means "normal").
        bassAverage += (bassEnergy - bassAverage) * (1 - expf(-dt / 4))
        let rel = bassEnergy / max(bassAverage, 1e-9)
        let target = min(max((rel - 0.7) / 1.3, 0), 1)
        let tau: Float = target > breath ? 0.02 : 0.25
        breath += (target - breath) * (1 - expf(-dt / tau))

        loudPeak = max(rms, loudPeak * expf(-dt / 5))
        let level = min(rms / max(loudPeak, 1e-5), 1)
        publish(time: time, level: level, power: rms * rms, beat: beat, accent: accent, sounding: true)
    }

    /// Where `time` falls relative to the beat grid, in beats: 0 on a beat, ±0.5 halfway between.
    /// nil while the grid isn't trustworthy.
    private func phaseOnGrid(_ time: Double) -> Float? {
        guard period > 0, confidence > 0.45, gridTime > 0 else { return nil }
        let beats = (time - gridTime) / period
        return Float(beats - beats.rounded())
    }

    /// Tempo from the autocorrelation of onset strength (60–200 BPM, with a gentle preference for
    /// ~120 and support from the double period to avoid octave errors), then phase from a comb over
    /// the most recent beats. The grid is nudged rather than jumped, like a phase-locked loop.
    private func estimateTempo(now time: Double) {
        let n = envFilled
        guard n >= Int(3.0 / hopSeconds) else { return }
        env.withUnsafeBufferPointer { e in
            envScratch.withUnsafeMutableBufferPointer { x in
                let start = (envWrite - n + envLength) % envLength
                for i in 0..<n { x[i] = e[(start + i) % envLength] }
            }
        }
        var mean: Float = 0
        vDSP_meanv(envScratch, 1, &mean, vDSP_Length(n))

        let minLag = max(2, Int((60.0 / 200.0 / hopSeconds).rounded(.down)))
        let maxLag = min(Int((60.0 / 60.0 / hopSeconds).rounded(.up)), n / 3, acf.count / 2 - 1)
        guard maxLag > minLag + 2 else { return }

        var energy: Float = 0
        envScratch.withUnsafeMutableBufferPointer { x in
            var neg = -mean
            vDSP_vsadd(x.baseAddress!, 1, &neg, x.baseAddress!, 1, vDSP_Length(n))
            vDSP_dotpr(x.baseAddress!, 1, x.baseAddress!, 1, &energy, vDSP_Length(n))
            energy /= Float(n)
            guard energy > 1e-6 else { return }
            acf.withUnsafeMutableBufferPointer { r in
                for lag in minLag...(2 * maxLag + 1) where lag < n {
                    var v: Float = 0
                    vDSP_dotpr(x.baseAddress! + lag, 1, x.baseAddress!, 1, &v, vDSP_Length(n - lag))
                    r[lag] = v / Float(n - lag) / energy
                }
            }
        }
        guard energy > 1e-6 else { return }

        var best = minLag
        var bestScore: Float = -.infinity
        for lag in minLag...maxLag {
            let bpm = 60 / (Double(lag) * hopSeconds)
            let octaves = log2(bpm / 120) / 0.9
            let prior = Float(exp(-0.5 * octaves * octaves))
            let score = (acf[lag] + 0.5 * max(acf[2 * lag], 0)) * prior
            if score > bestScore { bestScore = score; best = lag }
        }
        // Sub-hop precision from a parabola through the peak.
        var lagF = Double(best)
        if best > minLag, best < maxLag {
            let a = acf[best - 1], b = acf[best], c = acf[best + 1]
            let denom = a - 2 * b + c
            // Only at a true peak, and never more than half a hop.
            if b >= a, b >= c, denom < -1e-6 { lagF += Double(min(max(0.5 * (a - c) / denom, -0.5), 0.5)) }
        }
        let acfPeriod = lagF * hopSeconds
        guard acfPeriod > Double(minLag) * hopSeconds * 0.95, acfPeriod < Double(maxLag) * hopSeconds * 1.05 else { return }
        let newConfidence = min(max(acf[best], 0), 1)

        // Refine period and phase together with a comb over the rising edges of the onset signal
        // (the same moment the beat detector fires on): try periods within ±4% of the estimate and
        // every phase, summing the edges that land on the last ~12 beats.
        envScratch.withUnsafeMutableBufferPointer { x in
            // x[i] := max(x[i] - x[i-1], 0), back to front so each step reads the original x[i-1].
            if n > 1 { for i in stride(from: n - 1, to: 0, by: -1) { x[i] = max(x[i] - x[i - 1], 0) } }
            x[0] = 0
        }
        var bestPeriod = acfPeriod, bestOffset = 0.0
        var bestComb: Float = -.infinity
        for step in -16...16 {
            let candidate = acfPeriod * (1 + Double(step) * 0.0025)
            let periodHops = candidate / hopSeconds
            let span = min(Int(periodHops.rounded()), maxLag + 1)
            guard span >= 2 else { continue }
            let beats = max(1, min(12, Int(Double(n - 1 - span) / periodHops)))
            for j in 0..<span {
                var sum: Float = 0
                for k in 0..<beats {
                    let i = n - 1 - j - Int((Double(k) * periodHops).rounded())
                    if i >= 0 { sum += envScratch[i] }
                }
                if sum > bestComb { bestComb = sum; bestPeriod = candidate; bestOffset = Double(j) }
            }
        }
        let newPeriod = bestPeriod
        guard newPeriod > 0.25, newPeriod < 1.05 else { return }

        // Keep a steady tempo through small wobbles; switch only when a new one is seen twice.
        if period == 0 || abs(newPeriod - period) / period < 0.04 {
            period = period == 0 ? newPeriod : period * 0.6 + newPeriod * 0.4
            pendingVotes = 0
        } else if abs(newPeriod - pendingPeriod) / newPeriod < 0.04 {
            pendingVotes += 1
            if pendingVotes >= 2 { period = newPeriod; gridTime = 0; pendingVotes = 0 }
        } else {
            pendingPeriod = newPeriod
            pendingVotes = 1
        }
        confidence = confidence * 0.6 + newConfidence * 0.4

        // Phase: blend the comb's estimate into the grid (the per-beat phase lock does the fine work).
        let observed = time - bestOffset * hopSeconds
        if gridTime == 0 {
            gridTime = observed
        } else {
            let k = ((observed - gridTime) / period).rounded()
            let predicted = gridTime + k * period
            var error = observed - predicted
            if error > period / 2 { error -= period } else if error < -period / 2 { error += period }
            gridTime = predicted + 0.2 * error
        }
    }

    private func medianAndMAD(of values: [Float]) -> (Float, Float) {
        let count = min(historyCount, values.count)
        guard count > 2 else { return (0, 0) }
        return scratch.withUnsafeMutableBufferPointer { s -> (Float, Float) in
            values.withUnsafeBufferPointer { h in
                for i in 0..<count { s[i] = h[i] }
            }
            vDSP_vsort(s.baseAddress!, vDSP_Length(count), 1)
            let median = s[count / 2]
            for i in 0..<count { s[i] = abs(s[i] - median) }
            vDSP_vsort(s.baseAddress!, vDSP_Length(count), 1)
            return (median, s[count / 2])
        }
    }

    private func publish(time: Double, level: Float, power: Float, beat: Float?, accent: Float?, sounding: Bool) {
        let breath = sounding ? self.breath : 0
        let lat = latency
        let tempoPeriod = period, tempoGrid = gridTime, tempoConfidence = confidence

        // Store this hop's spectrum and loudness, then publish the ones from `latency` ago.
        let n = Self.bandCount
        for i in 0..<n { bandHistory[historyWrite * n + i] = sounding ? bandValue[i] : 0 }
        levelHistory[historyWrite] = level
        powerHistory[historyWrite] = power
        let back = min(max(Int((lat / hopSeconds).rounded()), 0), delayFrames - 1)
        let read = (historyWrite - back + delayFrames) % delayFrames
        historyWrite = (historyWrite + 1) % delayFrames

        BeatState.shared.update { s in
            s.level = self.levelHistory[read]
            s.power = self.powerHistory[read]
            s.breath = breath
            s.period = tempoPeriod
            s.gridTime = tempoGrid > 0 ? tempoGrid + lat : 0
            s.tempoConfidence = sounding ? tempoConfidence : 0
            for i in 0..<n { s.bands[i] = self.bandHistory[read * n + i] }
            if sounding { s.lastSoundTime = time }
            if let beat { s.addBeat(at: time + lat, strength: beat) }
            if let accent {
                s.accentTime = time + lat
                s.accentStrength = accent
            }
        }
    }
}
