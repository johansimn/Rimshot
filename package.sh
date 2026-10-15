#!/bin/zsh
# Builds a shareable Rimshot.zip in ./dist: a universal app (Apple silicon + Intel) plus a short
# "how to open" note. Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "${0:A:h}"

./build.sh >/dev/null
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
APP=build/Rimshot.app

# Rebuild the executable for Intel too and merge the two into one universal binary.
swiftc -O -swift-version 5 -sdk "$SDK" -target x86_64-apple-macos26.0 -module-cache-path build/ModuleCache-x86 \
  -framework AppKit -framework SwiftUI -framework Metal -framework QuartzCore \
  -framework CoreAudio -framework AudioToolbox -framework Accelerate -framework ServiceManagement \
  Sources/*.swift -o build/Rimshot-x86_64
lipo -create "$APP/Contents/MacOS/Rimshot" build/Rimshot-x86_64 -output build/Rimshot-universal
mv build/Rimshot-universal "$APP/Contents/MacOS/Rimshot"
codesign --force --sign - --identifier local.rimshot.app "$APP"

rm -rf dist && mkdir -p dist/Rimshot
cp -R "$APP" dist/Rimshot/
cat > "dist/Rimshot/How to open Rimshot.txt" <<'NOTE'
Rimshot: a neon glow around your screen that follows the album colors and the beat of whatever
you play in Spotify.

Needs: macOS 26 (Tahoe) or newer, and the Spotify desktop app.

1. Drag Rimshot.app into your Applications folder.
2. Open it. macOS will say it can't check it for malware, because it isn't from the App Store or a
   paid Apple developer account. Click Done, then open System Settings > Privacy & Security, scroll
   down, and click "Open Anyway" next to Rimshot. Confirm once more. You only do this once.
3. Allow the two prompts: controlling Spotify (for the song and album colors) and recording system
   audio (Rimshot listens to Spotify's sound to find the beat; nothing is saved).
4. Click the screen icon in the menu bar to turn the light on or off. Right-click it for settings.
   You can keep it in the Dock too and click it there to toggle.
NOTE
ditto -c -k --norsrc --noextattr --keepParent dist/Rimshot dist/Rimshot.zip
echo "Created dist/Rimshot.zip"
