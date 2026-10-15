import AppKit
import SwiftUI

@MainActor
final class MiniPlayerModel: ObservableObject {
    @Published var track: TrackInfo?
    @Published var artwork: NSImage?
    @Published var accent: Color = .white
    @Published var spotifyRunning = false
}

/// Small floating Liquid Glass now-playing card. Optional; toggled from the menu.
@MainActor
final class MiniPlayerController {
    private let spotify: SpotifyMonitor
    private let model = MiniPlayerModel()
    private var panel: NSPanel?

    init(spotify: SpotifyMonitor) {
        self.spotify = spotify
        NotificationCenter.default.addObserver(forName: SpotifyMonitor.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyVisibility() }
        }
        sync()
        applyVisibility()
    }

    private func sync() {
        model.track = spotify.track
        model.artwork = spotify.artwork
        model.spotifyRunning = spotify.isRunning
        model.accent = Color(nsColor: spotify.palette.first ?? .white)
    }

    /// Shown only while the light is on and the mini player is enabled. Hiding destroys the panel
    /// outright: a merely ordered-out SwiftUI window keeps its timeline (and the CPU) ticking.
    private func applyVisibility() {
        if Settings.shared.miniPlayer && Settings.shared.enabled {
            if panel == nil { panel = makePanel() }
            panel?.orderFrontRegardless()
        } else if let p = panel {
            p.orderOut(nil)
            p.contentView = nil
            panel = nil
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 96),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.canHide = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: MiniPlayerView(model: model, spotify: spotify))
        host.sizingOptions = [.preferredContentSize]
        p.contentView = host
        if !p.setFrameUsingName("RimshotMiniPlayer"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: v.maxX - 340, y: v.maxY - 120))
        }
        p.setFrameAutosaveName("RimshotMiniPlayer")
        return p
    }
}

private struct MiniPlayerView: View {
    @ObservedObject var model: MiniPlayerModel
    let spotify: SpotifyMonitor

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 4) {
                Text(model.track?.name ?? (model.spotifyRunning ? "Nothing playing" : "Spotify isn't open"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(model.track?.artist ?? "Rimshot")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                progress
                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: 320)
        .modifier(MiniPlayerChrome(accent: model.accent))
        .padding(1)
    }

    private var artwork: some View {
        Group {
            if let art = model.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: 70, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: model.accent.opacity(0.45), radius: 10)
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let t = model.track
            let pos = t?.position(at: CACurrentMediaTime()) ?? 0
            let frac = (t?.duration ?? 0) > 0 ? pos / t!.duration : 0
            HStack(spacing: 6) {
                Text(format(pos)).monospacedDigit()
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.15))
                        Capsule().fill(model.accent).frame(width: g.size.width * min(max(frac, 0), 1))
                    }
                }
                .frame(height: 4)
                Text(format(t?.duration ?? 0)).monospacedDigit()
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            button("backward.fill", size: 12) { spotify.previous() }
            button(model.track?.isPlaying == true ? "pause.fill" : "play.fill", size: 15) { spotify.playPause() }
            button("forward.fill", size: 12) { spotify.next() }
        }
        .padding(.top, 1)
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold)).frame(width: 22, height: 18)
        }
        .buttonStyle(.plain)
    }

    private func format(_ s: Double) -> String {
        let total = Int(max(s, 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct MiniPlayerChrome: ViewModifier {
    let accent: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(accent.opacity(0.18)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(accent.opacity(0.2), lineWidth: 1))
        }
    }
}
