import AppKit

/// How the rim light moves.
enum AnimationMode: String, CaseIterable {
    case musicSync, flow, idle, still

    var title: String {
        switch self {
        case .musicSync: return "Music Sync"
        case .flow: return "Default"
        case .idle: return "Idle"
        case .still: return "No Animation"
        }
    }

    /// Laps per second of the travelling lights.
    var travelSpeed: Double {
        switch self {
        case .musicSync: return 0.045
        case .flow: return 0.07
        case .idle: return 0.02
        case .still: return 0
        }
    }

    /// Revolutions of the color gradient around the screen per second.
    var flowSpeed: Double {
        switch self {
        case .musicSync: return 0.035
        case .flow: return 0.06
        case .idle: return 0.012
        case .still: return 0
        }
    }
}

/// Where the glow colors come from.
enum ColorSource: String, CaseIterable {
    case album, custom, sunset, ocean, neon, aurora, mono

    var title: String {
        switch self {
        case .album: return "Album Art"
        case .custom: return "Custom Gradient"
        case .sunset: return "Sunset"
        case .ocean: return "Ocean"
        case .neon: return "Neon"
        case .aurora: return "Aurora"
        case .mono: return "Moonlight"
        }
    }

    var preset: [NSColor]? {
        func c(_ hex: UInt32) -> NSColor { NSColor(hex: hex) }
        switch self {
        case .album, .custom: return nil
        case .sunset: return [c(0xFF5E62), c(0xFF9966), c(0xFFC371), c(0xFF4E8A)]
        case .ocean: return [c(0x00C6FF), c(0x0072FF), c(0x00F5D4), c(0x3A86FF)]
        case .neon: return [c(0xFF00E5), c(0x00F0FF), c(0x7B2FFF), c(0xFF2E63)]
        case .aurora: return [c(0x00FFA3), c(0x03E1FF), c(0xDC1FFF), c(0x00FF6A)]
        case .mono: return [c(0xE8EEFF), c(0xA9B8FF), c(0xFFFFFF), c(0xC9D4FF)]
        }
    }
}

/// Rendering and analysis quality. Low saves battery, Extreme spares nothing.
enum Quality: String, CaseIterable {
    case low, normal, extreme

    var title: String {
        switch self {
        case .low: return "Low (Battery Saver)"
        case .normal: return "Normal"
        case .extreme: return "Extreme (uses more battery)"
        }
    }

    /// Frame rate while music drives the light (Extreme uses ProMotion when the display has it).
    var musicFrameRate: Float {
        switch self {
        case .low: return 30
        case .normal: return 60
        case .extreme: return 120
        }
    }

    /// Pixels per point for the glow. The light is soft, so Low renders at half resolution on Retina.
    func renderScale(backing: CGFloat) -> CGFloat { self == .low ? 1 : backing }

    /// Audio analysis hop in samples (detection latency is about one hop).
    var analysisHop: Int { self == .extreme ? 256 : 512 }

    /// 0, 1, 2 for the shader.
    var level: Float {
        switch self {
        case .low: return 0
        case .normal: return 1
        case .extreme: return 2
        }
    }
}

enum DisplayScope: String, CaseIterable {
    case all, main

    var title: String { self == .all ? "All Displays" : "Main Display Only" }
}

/// UserDefaults-backed settings. Every change posts `Settings.didChange`.
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("RimshotSettingsDidChange")

    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "enabled": true,
            "mode": AnimationMode.musicSync.rawValue,
            "colorSource": ColorSource.album.rawValue,
            "intensity": 0.85,
            "thickness": 60.0,
            "sensitivity": 0.6,
            "displays": DisplayScope.all.rawValue,
            "hdr": false,
            "customA": NSColor(hex: 0xFF3CAC).hexString,
            "customB": NSColor(hex: 0x2B86C5).hexString,
            "miniPlayer": false,
            "syncOffset": 0.0,
            "hideFromCapture": false,
            "movingLights": true,
            "equalizer": true,
            "showInDock": true,
            "quality": Quality.normal.rawValue,
        ])
    }

    private func changed() {
        NotificationCenter.default.post(name: Settings.didChange, object: self)
    }

    var enabled: Bool {
        get { d.bool(forKey: "enabled") }
        set { d.set(newValue, forKey: "enabled"); changed() }
    }

    var mode: AnimationMode {
        get { AnimationMode(rawValue: d.string(forKey: "mode") ?? "") ?? .musicSync }
        set { d.set(newValue.rawValue, forKey: "mode"); changed() }
    }

    var colorSource: ColorSource {
        get { ColorSource(rawValue: d.string(forKey: "colorSource") ?? "") ?? .album }
        set { d.set(newValue.rawValue, forKey: "colorSource"); changed() }
    }

    /// Overall brightness of the glow, 0.2 ... 1.5.
    var intensity: Double {
        get { d.double(forKey: "intensity") }
        set { d.set(newValue, forKey: "intensity"); changed() }
    }

    /// Glow reach in points, 20 ... 500.
    var thickness: Double {
        get { d.double(forKey: "thickness") }
        set { d.set(newValue, forKey: "thickness"); changed() }
    }

    /// How eagerly beats are detected and how hard they hit, 0 ... 1.
    var sensitivity: Double {
        get { d.double(forKey: "sensitivity") }
        set { d.set(newValue, forKey: "sensitivity"); changed() }
    }

    var displays: DisplayScope {
        get { DisplayScope(rawValue: d.string(forKey: "displays") ?? "") ?? .all }
        set { d.set(newValue.rawValue, forKey: "displays"); changed() }
    }

    /// Render in extended dynamic range so the glow can exceed SDR white on XDR displays.
    var hdr: Bool {
        get { d.bool(forKey: "hdr") }
        set { d.set(newValue, forKey: "hdr"); changed() }
    }

    var miniPlayer: Bool {
        get { d.bool(forKey: "miniPlayer") }
        set { d.set(newValue, forKey: "miniPlayer"); changed() }
    }

    /// Extra delay applied to beats, in milliseconds, for outputs that under-report latency.
    var syncOffset: Double {
        get { d.double(forKey: "syncOffset") }
        set { d.set(newValue, forKey: "syncOffset"); changed() }
    }

    /// Bright lights in the album's colors that travel around the band.
    var movingLights: Bool {
        get { d.bool(forKey: "movingLights") }
        set { d.set(newValue, forKey: "movingLights"); changed() }
    }

    var quality: Quality {
        get { Quality(rawValue: d.string(forKey: "quality") ?? "") ?? .normal }
        set { d.set(newValue.rawValue, forKey: "quality"); changed() }
    }

    /// Show a Dock icon that toggles the light when clicked (and can be kept in the Dock).
    var showInDock: Bool {
        get { d.bool(forKey: "showInDock") }
        set { d.set(newValue, forKey: "showInDock"); changed() }
    }

    /// The spectrum shapes the rim: bass at the bottom, highs at the top.
    var equalizer: Bool {
        get { d.bool(forKey: "equalizer") }
        set { d.set(newValue, forKey: "equalizer"); changed() }
    }

    /// Keep the glow out of screenshots and screen recordings.
    var hideFromCapture: Bool {
        get { d.bool(forKey: "hideFromCapture") }
        set { d.set(newValue, forKey: "hideFromCapture"); changed() }
    }

    var customA: NSColor {
        get { NSColor(hexString: d.string(forKey: "customA") ?? "") ?? .systemPink }
        set { d.set(newValue.hexString, forKey: "customA"); changed() }
    }

    var customB: NSColor {
        get { NSColor(hexString: d.string(forKey: "customB") ?? "") ?? .systemBlue }
        set { d.set(newValue.hexString, forKey: "customB"); changed() }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }

    convenience init?(hexString: String) {
        let s = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }

    /// sRGB components as a SIMD vector for the shader.
    var rgb: SIMD3<Float> {
        let c = usingColorSpace(.sRGB) ?? self
        return SIMD3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
    }
}
