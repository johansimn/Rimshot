#!/bin/zsh
# Builds Rimshot.app into ./build. Needs only the Xcode Command Line Tools (no Xcode).
set -euo pipefail
cd "${0:A:h}"

APP=build/Rimshot.app
# The newest SDK in CommandLineTools can be newer than the installed compiler; MacOSX.sdk points at
# the one that matches it.
SDK=$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)
[[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]] && SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon, drawn by Sources/AppIcon.swift. Regenerated only when the drawing code changes.
if [[ ! -f build/AppIcon.icns || Sources/AppIcon.swift -nt build/AppIcon.icns ]]; then
  swiftc -swift-version 5 -sdk "$SDK" -target arm64-apple-macos26.0 -module-cache-path build/ModuleCache \
    tools/make-icon/main.swift Sources/AppIcon.swift Sources/Settings.swift -o build/make-icon
  rm -rf build/AppIcon.iconset
  build/make-icon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

swiftc -O -swift-version 5 \
  -sdk "$SDK" -target arm64-apple-macos26.0 \
  -module-cache-path build/ModuleCache \
  -framework AppKit -framework SwiftUI -framework Metal -framework QuartzCore \
  -framework CoreAudio -framework AudioToolbox -framework Accelerate -framework ServiceManagement \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/Rimshot"

cp Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature. macOS ties the Spotify-control and audio permissions to it, so a rebuilt app
# may ask for them again.
codesign --force --sign - --identifier local.rimshot.app "$APP"
echo "Built $APP"
