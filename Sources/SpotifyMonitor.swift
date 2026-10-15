import AppKit
import CoreServices

struct TrackInfo: Equatable {
    var id: String
    var name: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var isPlaying: Bool
    var duration: Double   // seconds
    var position: Double   // seconds, at `fetchedAt`
    var fetchedAt: Double  // CACurrentMediaTime()

    /// Playback position extrapolated to `now`.
    func position(at now: Double) -> Double {
        guard isPlaying else { return position }
        return min(position + (now - fetchedAt), duration)
    }

    static func == (a: TrackInfo, b: TrackInfo) -> Bool {
        a.id == b.id && a.isPlaying == b.isPlaying && a.name == b.name && a.artworkURL == b.artworkURL
    }
}

/// Watches the Spotify desktop app: what's playing, its album art and palette.
///
/// Spotify is queried with raw Apple Events on a background queue, addressed by PID (so a poll can
/// never relaunch Spotify) with a 1 s timeout (so a busy Spotify, or the first-run permission
/// prompt, can't stall the main thread and the light). Spotify's distributed notification triggers
/// an immediate refresh; a slow poll is the safety net.
@MainActor
final class SpotifyMonitor {
    static let didChange = Notification.Name("RimshotSpotifyDidChange")
    nonisolated static let bundleID = "com.spotify.client"

    private(set) var track: TrackInfo?
    private(set) var artwork: NSImage?
    private(set) var palette: [NSColor] = []
    private(set) var isRunning = false
    /// Set when macOS refused to let us talk to Spotify (Automation permission denied).
    private(set) var automationDenied = false

    private let client = SpotifyClient()
    private var timer: Timer?
    private var inFlight = false
    private var refreshAgain = false
    private var artworkTask: URLSessionDataTask?
    private var loadedArtworkURL: URL?

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePolling() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SpotifyMonitor.bundleID else { return }
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        updatePolling()
    }

    /// Only talk to Spotify while the light is on (the mini player only shows then, too).
    private var active: Bool { Settings.shared.enabled }

    private func updatePolling() {
        if active, timer == nil {
            let t = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            t.tolerance = 0.5
            RunLoop.main.add(t, forMode: .common)
            timer = t
            refresh()
        } else if !active, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    func refresh() {
        guard active else { return }
        guard !inFlight else { refreshAgain = true; return }
        inFlight = true
        client.snapshot { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(result) }
            }
        }
    }

    private func apply(_ result: Result<SpotifyClient.Snapshot?, SpotifyClient.Failure>) {
        inFlight = false
        var newTrack: TrackInfo?
        var running = true
        switch result {
        case .success(nil):
            running = false
        case .success(let snap?):
            if automationDenied { log.notice("Spotify automation allowed") }
            automationDenied = false
            if let t = snap.track {
                newTrack = TrackInfo(id: t.id, name: t.name, artist: t.artist, album: t.album, artworkURL: t.artworkURL,
                                     isPlaying: snap.playing, duration: Double(t.durationMs) / 1000,
                                     position: snap.position, fetchedAt: CACurrentMediaTime())
            }
        case .failure(.denied):
            if !automationDenied { log.error("Spotify automation denied") }
            automationDenied = true
            newTrack = track
        case .failure(.notRunning):
            running = false
        case .failure(let other):
            // Timeouts happen while the permission prompt is up; keep what we had.
            log.error("Spotify query failed: \(String(describing: other), privacy: .public)")
            newTrack = track
        }

        if newTrack?.id != track?.id, let t = newTrack {
            log.notice("Now playing: \(t.name, privacy: .public) — \(t.artist, privacy: .public)")
        }
        let changed = running != isRunning || newTrack != track || newTrack?.position != track?.position
        isRunning = running
        track = newTrack

        if let url = newTrack?.artworkURL, url != loadedArtworkURL {
            loadArtwork(url)
        } else if newTrack == nil, loadedArtworkURL != nil {
            artworkTask?.cancel()
            loadedArtworkURL = nil
            artwork = nil
            palette = []
            post()
        } else if changed {
            post()
        }

        if refreshAgain {
            refreshAgain = false
            refresh()
        }
    }

    private func loadArtwork(_ url: URL) {
        artworkTask?.cancel()
        loadedArtworkURL = url
        artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            let colors = Palette.extract(from: image)
            log.notice("Album palette: \(colors.map(\.hexString).joined(separator: " "), privacy: .public)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.loadedArtworkURL == url else { return }
                    self.artwork = image
                    self.palette = colors
                    self.post()
                }
            }
        }
        artworkTask?.resume()
    }

    private func post() {
        NotificationCenter.default.post(name: SpotifyMonitor.didChange, object: self)
    }

    // MARK: Playback controls

    func playPause() { command("PlPs") }
    func next() { command("Next") }
    func previous() { command("Prev") }

    func openSpotify() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyMonitor.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func command(_ code: StaticString) {
        guard isRunning else { openSpotify(); return }
        client.send(fourCC(code)) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.refresh()
                    // Spotify updates its state a beat after the command.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.refresh() }
                }
            }
        }
    }
}

private func fourCC(_ s: StaticString) -> FourCharCode {
    s.withUTF8Buffer { $0.reduce(0) { ($0 << 8) | FourCharCode($1) } }
}

/// Raw Apple Events to Spotify, confined to one private serial queue.
final class SpotifyClient: @unchecked Sendable {
    struct Track { var id, name, artist, album: String; var artworkURL: URL?; var durationMs: Int }
    struct Snapshot { var playing: Bool; var position: Double; var track: Track? }
    enum Failure: Error { case notRunning, denied, timeout, other(Int) }

    private let queue = DispatchQueue(label: "local.rimshot.spotify", qos: .utility)
    private var cached: Track?

    // The very first query is allowed to show the "control Spotify" permission prompt; macOS only asks once.
    private static let options = NSAppleEventDescriptor.SendOptions([.waitForReply])

    private static var pid: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyMonitor.bundleID)
            .first { !$0.isTerminated }?.processIdentifier
    }

    /// `nil` snapshot means Spotify isn't running.
    func snapshot(_ done: @escaping @Sendable (Result<Snapshot?, Failure>) -> Void) {
        queue.async { [self] in
            guard let pid = Self.pid else { done(.success(nil)); return }
            do { done(.success(try snapshot(pid: pid))) } catch let f as Failure { done(.failure(f)) } catch { done(.failure(.other(0))) }
        }
    }

    func send(_ command: FourCharCode, then: @escaping @Sendable () -> Void) {
        queue.async {
            if let pid = Self.pid {
                let ev = NSAppleEventDescriptor(eventClass: fourCC("spfy"), eventID: command,
                                                targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                                returnID: AEReturnID(kAutoGenerateReturnID),
                                                transactionID: AETransactionID(kAnyTransactionID))
                _ = try? Self.checked { try ev.sendEvent(options: Self.options, timeout: 2) }
            }
            then()
        }
    }

    private func snapshot(pid: pid_t) throws -> Snapshot {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let app = NSAppleEventDescriptor.null()
        let state = try get(target, property(fourCC("pPlS"), of: app)).enumCodeValue
        let position = (try? get(target, property(fourCC("pPos"), of: app)).doubleValue) ?? 0
        let current = property(fourCC("pTrk"), of: app)
        guard let id = try? get(target, property(fourCC("ID  "), of: current)).stringValue, !id.isEmpty,
              state != fourCC("kPSS") else {
            return Snapshot(playing: false, position: position, track: nil)
        }
        if cached?.id != id {
            // Metadata only changes with the track, so fetch it only then.
            func text(_ code: StaticString) -> String { (try? get(target, property(fourCC(code), of: current)).stringValue) ?? "" }
            var art = text("aUrl")
            // Spotify sometimes hands out http:// artwork links, which App Transport Security blocks.
            if art.hasPrefix("http://") { art = "https://" + art.dropFirst(7) }
            let duration = (try? get(target, property(fourCC("pDur"), of: current)).int32Value) ?? 0
            cached = Track(id: id, name: text("pnam"), artist: text("pArt"), album: text("pAlb"),
                           artworkURL: URL(string: art).flatMap { $0.scheme == "https" ? $0 : nil },
                           durationMs: Int(duration))
        }
        return Snapshot(playing: state == fourCC("kPSP"), position: position, track: cached)
    }

    private func property(_ code: FourCharCode, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier))!
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: DescType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        spec.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: DescType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: code), forKeyword: AEKeyword(keyAEKeyData))
        return spec
    }

    private func get(_ target: NSAppleEventDescriptor, _ spec: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let ev = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                                        targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                        transactionID: AETransactionID(kAnyTransactionID))
        ev.setParam(spec, forKeyword: AEKeyword(keyDirectObject))
        let reply = try Self.checked { try ev.sendEvent(options: Self.options, timeout: 1) }
        guard let value = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { throw Failure.other(-1728) }
        return value
    }

    /// `sendEvent` can either throw or return a reply carrying an error number.
    private static func checked(_ send: () throws -> NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do { reply = try send() } catch let e as NSError { throw failure(e.code) }
        if let n = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, n != 0 { throw failure(Int(n)) }
        return reply
    }

    private static func failure(_ code: Int) -> Failure {
        switch code {
        case -600, -609: return .notRunning
        case -1743, -1744: return .denied
        case -1712: return .timeout
        default: return .other(code)
        }
    }
}
