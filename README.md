# Rimshot

A neon glow around the edges of your Mac's screen that takes its colors from the album art of whatever
you're playing in Spotify and moves with the music: kicks flash it, the bass swells it, the highs make
it shimmer, and the whole rim works as an equalizer (bass at the bottom, highs up around the notch).

## Download

Grab **Rimshot.zip** from the [latest release](../../releases/latest).

You need **macOS 26 (Tahoe) or newer** and the **Spotify desktop app**.

1. Unzip it and drag **Rimshot.app** into Applications.
2. Open it. macOS will say it can't check it for malware, because it isn't from the App Store or a
   paid Apple developer account. Click Done, open **System Settings → Privacy & Security**, scroll
   down and click **Open Anyway** next to Rimshot. You only do this once.
3. Allow the two prompts: controlling Spotify (for the song and its album colors) and recording
   system audio (Rimshot listens to Spotify's sound to find the beat; nothing is recorded or saved).

## Using it

- **Click** the screen icon in the menu bar to turn the light on or off. Off really is off: nothing
  is drawn, no audio is analysed and Spotify isn't polled.
- **Right-click** it for settings: animation, colors (album art, presets or your own gradient), glow,
  width, beat punch, quality, moving lights, equalizer edges, displays, mini player and more.
- Keep it in the Dock (right-click → Options → Keep in Dock) and click the Dock icon to toggle too.

**Quality**

| | Low | Normal | Extreme |
|---|---|---|---|
| Resolution | half | full Retina | full Retina, 16-bit color, extra brightness on XDR displays |
| Frame rate with music | 30 fps | 60 fps | 120 fps (ProMotion) |
| Beat detection | ~11 ms | ~11 ms | ~5 ms, fastest reaction |

On Bluetooth headphones, use **Beat Delay** if the light runs ahead of what you hear.

## How it works

- **Audio**: a private Core Audio process tap on Spotify only (macOS 26), analysed in memory with an
  FFT. Kicks come from spectral flux in the 40–150 Hz band against an adaptive threshold, with a
  check that tells kicks from bass-line notes. A tempo tracker (autocorrelation plus a comb over the
  onsets, phase-locked to detected kicks) puts pulses exactly on the beat.
- **Song and colors**: Apple Events to the Spotify app, album art from Spotify's CDN, and a
  hue-histogram palette pushed to neon saturation.
- **Light**: a Metal shader drawn only in four strips along the screen edges, with the frame rate
  dropped whenever nothing needs to move.

## Build from source

Needs the Xcode Command Line Tools only.

```sh
./build.sh      # builds build/Rimshot.app
./package.sh    # builds a universal (Apple silicon + Intel) dist/Rimshot.zip
```
