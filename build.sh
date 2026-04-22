#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="EVE"
BUNDLE="$APP_NAME.app"
BUNDLE_ID="com.hermes.dock-toggle"  # keep id so TCC grants stick

echo "==> Building Swift package (release)…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
EXEC="$BIN_PATH/HermesToggle"
if [ ! -x "$EXEC" ]; then
  echo "!! Executable not found at $EXEC" >&2
  exit 1
fi

echo "==> Assembling ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$EXEC" "$BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>EVE</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><false/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Hermes listens to your voice so you can chat hands-free.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Hermes uses on-device speech recognition to detect the wake word "Eve" and your commands.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# --- Bundle voice bridge ---
if [ -d voice-bridge ]; then
  echo "==> Bundling voice-bridge/"
  mkdir -p "$BUNDLE/Contents/Resources/voice-bridge"
  cp voice-bridge/*.py "$BUNDLE/Contents/Resources/voice-bridge/" 2>/dev/null || true
fi

echo "==> Rendering icon via helper…"
ICON_TMP="$(mktemp -d)"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

# Render a 1024x1024 PNG with the same drawing code via a tiny inline Swift script.
RENDER_SWIFT="$ICON_TMP/render.swift"
cat > "$RENDER_SWIFT" <<'SWIFT'
import AppKit
import Foundation

let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()
let rect = NSRect(origin: .zero, size: size)
let cx = rect.midX
let cy = rect.midY
let r: CGFloat = 360  // orb radius — fits cleanly inside 1024 without touching edges

// Core orb — warm amber radial gradient, off-center light source for depth.
let orbPath = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
let orbGrad = NSGradient(colors: [
    NSColor(calibratedRed: 1.00, green: 0.82, blue: 0.38, alpha: 1.0),
    NSColor(calibratedRed: 1.00, green: 0.58, blue: 0.18, alpha: 1.0),
    NSColor(calibratedRed: 0.78, green: 0.30, blue: 0.08, alpha: 1.0)
])!
orbGrad.draw(in: orbPath, relativeCenterPosition: NSPoint(x: -0.3, y: 0.3))

// Subtle morph ring (single stroke) for the "Siri orb" signature.
let ringPath = NSBezierPath()
let lobes: CGFloat = 5
let amp: CGFloat = 14
let steps = 240
for i in 0...steps {
    let theta = CGFloat(i) / CGFloat(steps) * .pi * 2
    let wobble = sin(theta * lobes) * amp
    let rr = r + wobble + 6
    let x = cx + cos(theta) * rr
    let y = cy + sin(theta) * rr
    if i == 0 { ringPath.move(to: NSPoint(x: x, y: y)) }
    else { ringPath.line(to: NSPoint(x: x, y: y)) }
}
ringPath.close()
NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.45, alpha: 0.35).setStroke()
ringPath.lineWidth = 3
ringPath.stroke()

// Specular highlight — upper-left crescent.
let hlRect = NSRect(x: cx - r * 0.35, y: cy + r * 0.15, width: r * 0.55, height: r * 0.35)
NSColor(calibratedWhite: 1.0, alpha: 0.35).setFill()
NSBezierPath(ovalIn: hlRect).fill()

img.unlockFocus()
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

SRC_PNG="$ICON_TMP/icon_1024.png"
swift "$RENDER_SWIFT" "$SRC_PNG"

for s in 16 32 64 128 256 512 1024; do
  sips -z "$s" "$s" "$SRC_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
done
cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
rm "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"

iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc with entitlements)…"
codesign --force --deep --sign - \
  --entitlements "$(pwd)/entitlements.plist" \
  --options runtime \
  "$BUNDLE" >/dev/null

echo "==> Built: $(pwd)/$BUNDLE"
echo "    Install:   cp -R '$(pwd)/$BUNDLE' /Applications/"
echo "    Then drag /Applications/$BUNDLE onto your Dock."
