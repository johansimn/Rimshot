import AppKit
import ServiceManagement

/// The menu bar icon and everything in its menu. Clicking the icon turns the light on or off;
/// right-click (or Control/Option-click) opens the menu, which is rebuilt each time it opens.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let spotify: SpotifyMonitor
    private let audio: SpotifyAudioTap
    private let miniPlayer: MiniPlayerController
    private var editingColor: Int = 0

    init(spotify: SpotifyMonitor, audio: SpotifyAudioTap, miniPlayer: MiniPlayerController) {
        self.spotify = spotify
        self.audio = audio
        self.miniPlayer = miniPlayer
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self
        menu.autoenablesItems = false
        updateIcon()
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    func menuDidClose(_ menu: NSMenu) {
        // Detach again so the next plain click toggles instead of opening the menu.
        item.menu = nil
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
            || event?.modifierFlags.contains(.option) == true
        if wantsMenu {
            showMenu()
        } else {
            Settings.shared.enabled.toggle()
        }
    }

    func showMenu() {
        item.menu = menu
        item.button?.performClick(nil)
    }

    private func updateIcon() {
        let on = Settings.shared.enabled
        item.button?.image = AppIcon.menuBarImage(on: on)
        item.button?.toolTip = on ? "Rimshot is on — click to turn off, right-click for settings"
                                  : "Rimshot is off — click to turn on, right-click for settings"
    }

    private func rebuild() {
        menu.removeAllItems()
        let s = Settings.shared

        // Now playing
        menu.addItem(nowPlayingItem())
        menu.addItem(controlsItem())
        menu.addItem(.separator())

        menu.addItem(toggle("Light On", s.enabled) { Settings.shared.enabled.toggle() })

        let anim = NSMenu()
        for m in AnimationMode.allCases {
            anim.addItem(toggle(m.title, s.mode == m) { Settings.shared.mode = m })
        }
        menu.addItem(submenu("Animation", anim))
        menu.addItem(toggle("Moving Lights", s.movingLights) { Settings.shared.movingLights.toggle() })
        menu.addItem(toggle("Equalizer Edges", s.equalizer) { Settings.shared.equalizer.toggle() })
        let quality = NSMenu()
        for q in Quality.allCases {
            quality.addItem(toggle(q.title, s.quality == q) { Settings.shared.quality = q })
        }
        menu.addItem(submenu("Quality", quality))

        let colors = NSMenu()
        for c in ColorSource.allCases {
            let it = toggle(c.title, s.colorSource == c) { Settings.shared.colorSource = c }
            it.image = swatch(c == .album ? (spotify.palette.isEmpty ? LightEngine.fallbackPalette : spotify.palette)
                                : c == .custom ? [s.customA, s.customB] : c.preset ?? [])
            colors.addItem(it)
            if c == .custom { colors.addItem(.separator()) }
            if c == .album { colors.addItem(.separator()) }
        }
        colors.addItem(.separator())
        colors.addItem(action("Pick Gradient Start Color…") { [weak self] in self?.pickColor(0) })
        colors.addItem(action("Pick Gradient End Color…") { [weak self] in self?.pickColor(1) })
        menu.addItem(submenu("Colors", colors))
        menu.addItem(.separator())

        menu.addItem(slider("Glow", value: s.intensity, range: 0.2...1.5) { Settings.shared.intensity = $0 })
        menu.addItem(slider("Width", value: s.thickness, range: 20...500) { Settings.shared.thickness = $0 })
        menu.addItem(slider("Beat Punch", value: s.sensitivity, range: 0...1) { Settings.shared.sensitivity = $0 })
        menu.addItem(slider("Beat Delay (for Bluetooth headphones)", value: s.syncOffset, range: -100...300,
                            format: { "\(Int($0.rounded())) ms" }) { Settings.shared.syncOffset = $0 })
        menu.addItem(.separator())

        let displays = NSMenu()
        for d in DisplayScope.allCases {
            displays.addItem(toggle(d.title, s.displays == d) { Settings.shared.displays = d })
        }
        menu.addItem(submenu("Displays", displays))
        let edr = NSScreen.screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
        let hdrItem = toggle("HDR Glow", s.hdr) { Settings.shared.hdr.toggle() }
        hdrItem.isEnabled = edr
        hdrItem.toolTip = edr ? "Lets the glow get brighter than white on XDR / HDR displays."
                              : "No HDR-capable display connected."
        menu.addItem(hdrItem)
        menu.addItem(toggle("Mini Player", s.miniPlayer) { Settings.shared.miniPlayer.toggle() })
        menu.addItem(toggle("Hide Glow in Screen Recordings", s.hideFromCapture) { Settings.shared.hideFromCapture.toggle() })
        menu.addItem(toggle("Show in Dock", s.showInDock) { Settings.shared.showInDock.toggle() })
        menu.addItem(.separator())

        menu.addItem(audioStatusItem())
        if spotify.automationDenied {
            menu.addItem(action("Allow Rimshot to Control Spotify…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            })
        }
        menu.addItem(toggle("Launch at Login", SMAppService.mainApp.status == .enabled) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch {
                NSSound.beep()
            }
        })
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Rimshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: Sections

    private func nowPlayingItem() -> NSMenuItem {
        let it = NSMenuItem()
        guard let t = spotify.track else {
            it.title = spotify.isRunning ? "Spotify isn't playing anything" : "Spotify isn't open"
            it.isEnabled = false
            if !spotify.isRunning {
                it.title = "Open Spotify"
                it.isEnabled = true
                it.target = self
                it.action = #selector(runClosure(_:))
                it.representedObject = Closure { [weak self] in self?.spotify.openSpotify() }
            }
            return it
        }
        let title = NSMutableAttributedString(string: t.name, attributes: [.font: NSFont.menuFont(ofSize: 13).bold])
        title.append(NSAttributedString(string: "\n\(t.artist)", attributes: [
            .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        it.attributedTitle = title
        if let art = spotify.artwork {
            let img = NSImage(size: NSSize(width: 34, height: 34), flipped: false) { rect in
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
                art.draw(in: rect)
                return true
            }
            it.image = img
        }
        it.isEnabled = false
        return it
    }

    private func controlsItem() -> NSMenuItem {
        let it = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 34))
        let playing = spotify.track?.isPlaying ?? false
        let specs: [(String, Selector)] = [
            ("backward.fill", #selector(prev)),
            (playing ? "pause.fill" : "play.fill", #selector(playPause)),
            ("forward.fill", #selector(next)),
        ]
        for (i, spec) in specs.enumerated() {
            let b = NSButton(image: NSImage(systemSymbolName: spec.0, accessibilityDescription: nil)!, target: self, action: spec.1)
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.symbolConfiguration = .init(pointSize: i == 1 ? 17 : 14, weight: .semibold)
            b.frame = NSRect(x: 70 + CGFloat(i) * 46, y: 2, width: 38, height: 30)
            view.addSubview(b)
        }
        it.view = view
        return it
    }

    private func audioStatusItem() -> NSMenuItem {
        let it = NSMenuItem()
        it.isEnabled = false
        switch audio.status {
        case .listening:
            it.title = "♪ Beat Sync: listening to Spotify"
        case .waiting:
            it.title = spotify.isRunning ? "Beat Sync: press play in Spotify" : "Beat Sync: waiting for Spotify"
        case .silent:
            it.title = "Beat Sync: ready"
        case .denied:
            it.title = "Beat Sync needs audio access — Open Settings…"
            it.isEnabled = true
            it.target = self
            it.action = #selector(openAudioPrivacy)
        case .off:
            it.title = Settings.shared.mode == .musicSync ? "Beat Sync: off" : "Beat Sync: off (pick Music Sync)"
        case .failed(let message):
            it.title = "Beat Sync unavailable: \(message)"
        }
        return it
    }

    // MARK: Actions

    @objc private func prev() { spotify.previous() }
    @objc private func playPause() { spotify.playPause() }
    @objc private func next() { spotify.next() }

    @objc private func openAudioPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }

    private func pickColor(_ slot: Int) {
        editingColor = slot
        Settings.shared.colorSource = .custom
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.mode = .wheel
        panel.color = slot == 0 ? Settings.shared.customA : Settings.shared.customB
        panel.setTarget(self)
        panel.setAction(#selector(colorPicked(_:)))
        panel.title = slot == 0 ? "Gradient Start Color" : "Gradient End Color"
        NSApp.activate()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    @objc private func colorPicked(_ panel: NSColorPanel) {
        if editingColor == 0 { Settings.shared.customA = panel.color } else { Settings.shared.customB = panel.color }
    }

    // MARK: Builders

    private final class Closure: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc private func runClosure(_ sender: NSMenuItem) {
        (sender.representedObject as? Closure)?.run()
    }

    private func action(_ title: String, key: String = "", _ run: @escaping () -> Void) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: #selector(runClosure(_:)), keyEquivalent: key)
        it.target = self
        it.representedObject = Closure(run)
        return it
    }

    private func toggle(_ title: String, _ on: Bool, key: String = "", _ run: @escaping () -> Void) -> NSMenuItem {
        let it = action(title, key: key, run)
        it.state = on ? .on : .off
        return it
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = sub
        return it
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>,
                        format: ((Double) -> String)? = nil, _ onChange: @escaping (Double) -> Void) -> NSMenuItem {
        let it = NSMenuItem()
        it.view = SliderRow(title: title, value: value, range: range, format: format, onChange: onChange)
        return it
    }

    private func swatch(_ colors: [NSColor]) -> NSImage? {
        guard !colors.isEmpty else { return nil }
        return NSImage(size: NSSize(width: 26, height: 12), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSGradient(colors: colors.count == 1 ? colors + colors : colors)?.draw(in: path, angle: 0)
            NSColor.black.withAlphaComponent(0.15).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }
}

/// A labelled slider that lives inside a menu.
private final class SliderRow: NSView {
    private let onChange: (Double) -> Void
    private let format: ((Double) -> String)?
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")

    init(title: String, value: Double, range: ClosedRange<Double>, format: ((Double) -> String)?,
         onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        self.format = format
        slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 42))

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: 22, width: 200, height: 16)
        addSubview(label)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        valueLabel.textColor = .tertiaryLabelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 196, y: 22, width: 56, height: 16)
        addSubview(valueLabel)

        slider.frame = NSRect(x: 18, y: 2, width: 236, height: 20)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed)
        addSubview(slider)
        updateValueLabel()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateValueLabel() {
        valueLabel.stringValue = format?(slider.doubleValue) ?? ""
    }

    @objc private func changed() {
        updateValueLabel()
        onChange(slider.doubleValue)
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
