import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlays: OverlayController!
    private var spotify: SpotifyMonitor!
    private let audio = SpotifyAudioTap()
    private var miniPlayer: MiniPlayerController!
    private var menu: StatusMenu!
    private var sigterm: DispatchSourceSignal?
    private var lastTrackID: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opening the app (from the Dock, Finder or at login) always means "light on".
        if !Settings.shared.enabled { Settings.shared.enabled = true }
        NSApp.mainMenu = makeMainMenu()
        spotify = SpotifyMonitor()
        miniPlayer = MiniPlayerController(spotify: spotify)
        overlays = OverlayController()
        menu = StatusMenu(spotify: spotify, audio: audio, miniPlayer: miniPlayer)

        let center = NotificationCenter.default
        center.addObserver(forName: SpotifyMonitor.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePalette()
                if self.spotify.track?.id != self.lastTrackID {
                    self.lastTrackID = self.spotify.track?.id
                    self.audio.resetTempo()
                }
            }
        }
        center.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        settingsChanged()

        // A tap left behind in coreaudiod outlives the process, so tear it down on `kill` too.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigterm = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        audio.stopNow()
    }

    /// Clicking the Dock icon toggles the light, then hands focus straight back to whatever you
    /// were using.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Settings.shared.enabled.toggle()
        DispatchQueue.main.async { NSApp.hide(nil) }
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        let on = Settings.shared.enabled
        m.addItem(withTitle: on ? "Turn Light Off" : "Turn Light On", action: #selector(toggleLight), keyEquivalent: "").target = self
        m.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: "").target = self
        return m
    }

    @objc private func toggleLight() { Settings.shared.enabled.toggle() }

    @objc private func showSettings() {
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.menu.showMenu() }
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "Turn Light On/Off", action: #selector(toggleLight), keyEquivalent: "l").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Rimshot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Rimshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        return main
    }

    private var lastDockState: (shown: Bool, on: Bool)?

    private func updateDock() {
        let s = Settings.shared
        let state = (shown: s.showInDock, on: s.enabled)
        if lastDockState?.shown != state.shown {
            NSApp.setActivationPolicy(state.shown ? .regular : .accessory)
        }
        if state.shown, lastDockState?.on != state.on || lastDockState?.shown != state.shown {
            NSApp.applicationIconImage = AppIcon.dockImage(on: state.on, size: 256)
        }
        lastDockState = state
    }

    private func settingsChanged() {
        let s = Settings.shared
        updateDock()
        updatePalette()
        audio.setSensitivity(s.sensitivity)
        audio.setAnalysisHop(s.quality.analysisHop)
        audio.setSyncOffset(milliseconds: s.syncOffset)
        // Only capture audio while it's actually used.
        if s.enabled && s.mode == .musicSync { audio.start() } else { audio.stop() }
    }

    private func updatePalette() {
        let s = Settings.shared
        switch s.colorSource {
        case .album:
            LightEngine.shared.setPalette(spotify.palette.isEmpty ? LightEngine.fallbackPalette : spotify.palette)
        case .custom:
            LightEngine.shared.setPalette([s.customA, s.customB])
        default:
            LightEngine.shared.setPalette(s.colorSource.preset ?? LightEngine.fallbackPalette)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(Settings.shared.showInDock ? .regular : .accessory)
    app.run()
}
