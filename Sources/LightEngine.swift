import AppKit
import os

/// What the audio analyser has heard most recently. Written from the audio queue, read by the
/// render loop. Times are in `CACurrentMediaTime()` seconds.
struct BeatSnapshot {
    /// The last few beats, newest last. Beats are stamped with output latency, so the newest one
    /// can still be in the future (e.g. on AirPods) and the renderer must not show it early.
    var beatTimes: (Double, Double, Double, Double) = (-100, -100, -100, -100)
    var beatStrengths: (Float, Float, Float, Float) = (0, 0, 0, 0)
    var beatCount: UInt64 = 0
    var accentTime: Double = -100   // last snare/clap-type hit (also latency-stamped)
    var period: Double = 0          // seconds per beat from the tempo tracker, 0 while unknown
    var gridTime: Double = 0        // a beat on the tempo grid (latency-stamped)
    var tempoConfidence: Float = 0  // 0..1
    var accentStrength: Float = 0
    var level: Float = 0            // loudness relative to the recent peak, 0..1
    var power: Float = 0            // absolute loudness (mean square), for drop detection
    var breath: Float = 0           // bass energy relative to its own average, 0..1
    var lastSoundTime: Double = -100
    /// Spectrum in 24 log-spaced bands (40 Hz–14 kHz), each 0..1 against its own recent peak.
    /// Inline storage, so the audio thread never allocates when it writes them.
    var bands = InlineArray<24, Float>(repeating: 0)

    mutating func addBeat(at time: Double, strength: Float) {
        beatTimes = (beatTimes.1, beatTimes.2, beatTimes.3, time)
        beatStrengths = (beatStrengths.1, beatStrengths.2, beatStrengths.3, strength)
        beatCount &+= 1
    }

    /// A detected beat within `window` seconds of `time`, if any.
    func beat(near time: Double, within window: Double) -> (time: Double, strength: Float)? {
        let t = [beatTimes.0, beatTimes.1, beatTimes.2, beatTimes.3]
        let s = [beatStrengths.0, beatStrengths.1, beatStrengths.2, beatStrengths.3]
        for i in (0..<4).reversed() where abs(t[i] - time) < window { return (t[i], s[i]) }
        return nil
    }

    /// The most recent beat that has already happened at `now`.
    func latestBeat(before now: Double) -> (time: Double, strength: Float)? {
        let t = [beatTimes.3, beatTimes.2, beatTimes.1, beatTimes.0]
        let s = [beatStrengths.3, beatStrengths.2, beatStrengths.1, beatStrengths.0]
        for i in 0..<4 where t[i] <= now { return (t[i], s[i]) }
        return nil
    }
}

final class BeatState: @unchecked Sendable {
    static let shared = BeatState()
    private let lock = OSAllocatedUnfairLock(initialState: BeatSnapshot())

    func update(_ body: (inout BeatSnapshot) -> Void) {
        lock.withLock { body(&$0) }
    }

    var snapshot: BeatSnapshot { lock.withLock { $0 } }
}

/// One frame's worth of lighting parameters, shared by every display.
struct LightFrame {
    var colors: [SIMD3<Float>] = []
    var intensity: Float = 0
    var thickness: Float = 40     // points
    var phase: Float = 0
    var clock: Float = 0
    var pulse: Float = 0
    var level: Float = 0
    var travel: Float = 0     // position of the travelling lights around the rim, wraps at 1
    var accent: Float = 0     // snare/clap sparkle envelope, 0..1
    var streaks: Float = 1    // strength of the travelling lights
    var drop: Float = 0       // burst after a breakdown, 0..1
    var eqAmount: Float = 0   // how strongly the spectrum shapes the rim, 0..1
    var eq = [Float](repeating: 0, count: 24)   // smoothed spectrum bands, 0..1
}

/// Owns the animation state (gradient rotation, palette crossfades, beat envelope) so that every
/// display shows exactly the same light, no matter how many display links ask for a frame.
@MainActor
final class LightEngine {
    static let shared = LightEngine()

    static let fallbackPalette: [NSColor] = [NSColor(hex: 0x7F5AF0), NSColor(hex: 0x2CB1FF), NSColor(hex: 0xFF6AD5)]

    private var targetColors: [SIMD3<Float>] = LightEngine.fallbackPalette.map(\.rgb)
    private var colors: [SIMD3<Float>] = LightEngine.fallbackPalette.map(\.rgb)

    private var lastTime: Double = 0
    private var phase: Double = 0
    private var travel: Double = 0
    private var streaks: Float = 1
    private var clock: Double = 0
    private var level: Float = 0
    private var master: Float = 0          // fades the whole light in and out
    private var kick: Float = 0            // extra gradient speed after a beat
    private var lastSeenBeat: Double = -100
    private var tempo: Double = 0              // seconds per beat while the tempo is confident
    private var lastGridIndex: Double = .nan
    private var gridHits: UInt8 = 0            // last 8 grid beats, 1 = a kick landed on it
    private var gridHitCount = 0
    private var eq = [Float](repeating: 0, count: 24)
    private var eqSlow = [Float](repeating: 0, count: 24)   // slower follower, for per-band transients
    private var eqAmount: Float = 0
    private var colorStep: Double = 0          // palette rotation added by beats, eased in
    private var colorStepTarget: Double = 0
    private var shortPower: Float = 0
    private var longPower: Float = 0
    private var musicSince: Double = -1          // when the current stretch of music started
    private var drop: Float = 0
    private var lastDrop: Double = -100

    private var gridHitRate: Float {
        gridHitCount < 4 ? 0 : Float(gridHits.nonzeroBitCount) / Float(min(gridHitCount, 8))
    }

    private func recordGridHit(_ hit: Bool) {
        gridHits = (gridHits << 1) | (hit ? 1 : 0)
        gridHitCount += 1
    }
    private var frame = LightFrame()

    /// Whether beat-synced audio is currently driving the light.
    private(set) var hearingMusic = false

    /// How often the display links should fire right now. 0 means nothing is moving.
    private(set) var wantedFrameRate: Float = 60

    func setPalette(_ palette: [NSColor]) {
        var p = palette.map(\.rgb)
        if p.isEmpty { p = LightEngine.fallbackPalette.map(\.rgb) }
        if p.count > 6 { p = Array(p.prefix(6)) }
        targetColors = p
    }

    /// Advances the animation to `now` (idempotent for repeated calls with the same time) and returns the frame.
    func frame(at now: Double) -> LightFrame {
        if lastTime != 0 && now <= lastTime { return frame }
        // After a pause (light off, display asleep, frozen mode) continue smoothly from one normal
        // frame instead of jumping a big step.
        let dt = lastTime == 0 || now - lastTime > 0.25 ? 1.0 / 60 : now - lastTime
        lastTime = now

        let s = Settings.shared
        let mode = s.mode
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Crossfade the palette. Palettes with different lengths are resampled around the rim.
        if colors.count != targetColors.count {
            colors = (0..<targetColors.count).map { i in sample(colors, at: Float(i) / Float(targetColors.count)) }
        }
        let colorRate = Float(1 - exp(-dt / 0.3))
        var colorsMoving = false
        for i in colors.indices {
            let delta = targetColors[i] - colors[i]
            if abs(delta.x) + abs(delta.y) + abs(delta.z) > 0.002 { colorsMoving = true }
            colors[i] += delta * colorRate
        }

        let fadeTarget: Float = s.enabled ? 1 : 0
        master += (fadeTarget - master) * Float(1 - exp(-dt / 0.3))
        if abs(master - fadeTarget) < 0.001 { master = fadeTarget }

        var beat = BeatState.shared.snapshot
        // Never let a bad value from the audio side stick in the integrators below.
        if !beat.level.isFinite { beat.level = 0 }
        if !beat.breath.isFinite { beat.breath = 0 }
        if !beat.power.isFinite { beat.power = 0 }
        let sens = Float(s.sensitivity)
        // Extreme reacts to everything as hard and as fast as it can.
        let extreme = s.quality == .extreme
        var pulse: Float = 0
        var accent: Float = 0
        var targetLevel: Float = 0
        hearingMusic = mode == .musicSync && now - beat.lastSoundTime < 1.0
        if !hearingMusic { tempo = 0 }

        if hearingMusic {
            // The light reaches your eyes about a frame after it's drawn, so look slightly ahead.
            let t = now + 1 / Double(max(wantedFrameRate, 30)) + 0.008
            var hit: (time: Double, strength: Float)? = beat.latestBeat(before: t)
            // Tempo grid: put the pulse exactly on the beat, and fill a missed kick, but only in
            // songs that really have a kick on (nearly) every beat, so half-time grooves and
            // breakdowns don't get invented pulses.
            if beat.tempoConfidence > 0.45, beat.period > 0.25, beat.gridTime > 0 {
                let index = ((t - beat.gridTime) / beat.period).rounded(.down)
                let g = beat.gridTime + index * beat.period
                if index != lastGridIndex {
                    // Score the grid beat we just left: did a real kick land on it?
                    let previous = g - beat.period
                    if lastGridIndex.isFinite { recordGridHit(beat.beat(near: previous, within: 0.08) != nil) }
                    lastGridIndex = index
                }
                // Snap to a detected kick near the grid point only once it has actually happened.
                if let d = beat.beat(near: g, within: 0.08), d.time <= t {
                    hit = d
                } else if gridHitRate >= 0.75, let last = beat.latestBeat(before: t), t - last.time < 2.2 * beat.period {
                    if hit == nil || g > hit!.time { hit = (g, last.strength * 0.6) }
                }
            } else {
                gridHits = 0
                gridHitCount = 0
                lastGridIndex = .nan
            }
            if let b = hit {
                let since = max(Float(t - b.time), 0)
                // Instant attack, ~150 ms decay. Even soft kicks land visibly.
                // Extreme: tighter, harder hits so fast patterns stay distinct.
                let decay: Float = extreme ? 0.09 + 0.05 * sens : 0.12 + 0.06 * sens
                let peak = min((extreme ? 0.55 : 0.45) + 0.75 * b.strength * (0.7 + 0.6 * sens), 1)
                pulse = peak * exp(-since / decay)
                if abs(b.time - lastSeenBeat) > 0.08 {
                    lastSeenBeat = b.time
                    kick = min(kick + 0.45 * b.strength * (0.6 + sens), 1.2)
                    // Each kick turns the album colours a notch around the screen.
                    colorStepTarget += Double(0.04 + 0.06 * b.strength) * Double(0.6 + sens) * (extreme ? 1.4 : 1)
                }
            }
            tempo = beat.tempoConfidence > 0.45 && beat.period > 0.25 ? beat.period : 0
            if beat.accentTime <= now {
                accent = beat.accentStrength * exp(-Float(now - beat.accentTime) / 0.09)
            }
            targetLevel = 0.5 * beat.breath + 0.5 * beat.level * beat.level

            // Equalizer: fast rise, quick fall, so the rim dances with the spectrum.
            // Extreme follows the spectrum almost instantly and adds a flash wherever a band jumps
            // (a sudden hit lights up its own stretch of the rim).
            let up = Float(1 - exp(-dt / (extreme ? 0.008 : 0.02)))
            let down = Float(1 - exp(-dt / (extreme ? 0.09 : 0.14)))
            let slow = Float(1 - exp(-dt / 0.25))
            for i in 0..<24 {
                var v = beat.bands[i].isFinite ? beat.bands[i] : 0
                eqSlow[i] += (v - eqSlow[i]) * slow
                if extreme { v = min(v + 1.2 * max(v - eqSlow[i], 0), 1) }
                eq[i] += (v - eq[i]) * (v > eq[i] ? up : down)
            }

            // Drops: real loudness (not the peak-relative level) jumping 4 dB or more above the last
            // few seconds, once the music has been playing for a while, sets off a burst.
            if musicSince < 0 {
                musicSince = now
                shortPower = beat.power
                longPower = beat.power
            }
            shortPower += (beat.power - shortPower) * Float(1 - exp(-dt / 0.4))
            longPower += (beat.power - longPower) * Float(1 - exp(-dt / 6))
            let rise = 10 * log10(max(shortPower, 1e-9) / max(longPower, 1e-9))
            if now - musicSince > 4, rise > 4, now - lastDrop > 8 {
                drop = 1
                lastDrop = now
            }
        } else if mode != .still && !reduceMotion {
            // Gentle breathing so the light still feels alive without music.
            let rate = mode == .idle ? 0.09 : 0.18
            targetLevel = Float(0.5 + 0.5 * sin(now * 2 * .pi * rate)) * 0.5
        }

        if !hearingMusic {
            let fall = Float(1 - exp(-dt / 0.3))
            for i in 0..<24 { eq[i] -= eq[i] * fall; eqSlow[i] -= eqSlow[i] * fall }
            musicSince = -1
        }
        drop *= Float(exp(-dt / 1.2))
        // Follow sound actually being there right now, so a pause doesn't leave the rim dimmed by an
        // empty spectrum for a second.
        let sounding = hearingMusic && now - beat.lastSoundTime < 0.15
        eqAmount += ((s.equalizer && sounding ? 1 : 0) - eqAmount) * Float(1 - exp(-dt / (sounding ? 0.5 : 0.12)))
        colorStep += (colorStepTarget - colorStep) * (1 - exp(-dt / 0.12))
        if colorStepTarget > 1000 { colorStepTarget -= 1000; colorStep -= 1000 }

        let levelTau = targetLevel > level ? 0.03 : 0.18
        level += (targetLevel - level) * Float(1 - exp(-dt / levelTau))
        kick *= Float(exp(-dt / 0.35))

        let speed = reduceMotion ? 0 : mode.flowSpeed + Double(kick) * 0.15
        phase = (phase + dt * speed).truncatingRemainder(dividingBy: 1)
        // The travelling lights get a burst of speed on every kick.
        // With a known tempo the lights travel a fixed stretch of the rim per beat, so their motion
        // locks to the groove; kicks still give them a shove.
        let baseTravel = tempo > 0 ? (1 / tempo) / 48 : mode.travelSpeed
        let travelSpeed = reduceMotion ? 0 : baseTravel + Double(kick) * 0.5 + Double(drop) * 0.5
        travel = (travel + dt * travelSpeed).truncatingRemainder(dividingBy: 1)
        streaks += ((s.movingLights ? 1 : 0) - streaks) * Float(1 - exp(-dt / 0.4))
        // Busy hi-hats speed up the fluorescent flow; quiet passages calm it.
        let highs = (eq[16..<24].reduce(0, +)) / 8
        // In Extreme with a confident tempo the flow is locked to it: the shader's main ripple runs at
        // 0.9 cycles per clock second, so this rate passes one ripple every two beats. Otherwise busy
        // hi-hats speed the flow up and quiet passages calm it.
        let flowRate = extreme && tempo > 0 ? (1 / tempo) / 0.9 / 2 : Double(1 + 1.8 * highs * eqAmount)
        if mode != .still && !reduceMotion { clock += dt * flowRate }

        frame = LightFrame(
            colors: colors,
            intensity: Float(s.intensity) * master,
            thickness: Float(s.thickness),
            phase: Float((phase + colorStep).truncatingRemainder(dividingBy: 1)),
            clock: Float(clock.truncatingRemainder(dividingBy: 10_000)),
            pulse: pulse,
            level: level,
            travel: Float(travel),
            accent: accent,
            streaks: streaks,
            drop: drop,
            eqAmount: eqAmount * (extreme ? 1 : 0.5 + 0.5 * sens),
            eq: eq
        )

        // Frame pacing: the quality's full rate only while music drives the light; slow breathing
        // needs far less.
        let fading = master != fadeTarget
        let maxRate = s.quality.musicFrameRate
        // Keep drawing until fading values settle, or the light would freeze half-way.
        let settling = eqAmount > 0.003 || level > 0.003 || kick > 0.003 || drop > 0.01
            || abs(streaks - (s.movingLights ? 1 : 0)) > 0.003 || abs(colorStepTarget - colorStep) > 0.001
        if hearingMusic || fading || colorsMoving || settling {
            wantedFrameRate = maxRate
        } else if master == 0 || mode == .still || reduceMotion {
            wantedFrameRate = 0
        } else {
            wantedFrameRate = min(maxRate, mode == .flow ? 30 : 20)
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { wantedFrameRate = min(wantedFrameRate, 30) }
        return frame
    }

    private func sample(_ palette: [SIMD3<Float>], at t: Float) -> SIMD3<Float> {
        guard !palette.isEmpty else { return SIMD3(1, 1, 1) }
        let f = t * Float(palette.count)
        let i0 = Int(f) % palette.count
        let i1 = (i0 + 1) % palette.count
        let w = f - Float(Int(f))
        return palette[i0] + (palette[i1] - palette[i0]) * w
    }
}
