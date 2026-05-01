#!/bin/bash
# Build interceptor-bridge as a real macOS .app bundle so TCC tracks it
# by CFBundleIdentifier (com.interceptor.bridge). Required for Apple Events
# (app_intent), Accessibility, ScreenCapture, and Microphone consent prompts to
# render with a stable identity. Falls back to the legacy bare-binary path via
# a symlink so older callers keep working.
#
# Env overrides:
#   INTERCEPTOR_SIGNING_IDENTITY  codesign identity (default: HVM Developer ID)
#   INTERCEPTOR_BRIDGE_VERSION    version string in Info.plist (default 1.0.0)
#   INTERCEPTOR_SKIP_SIGNING=1    skip codesign + lsregister (dev mode)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BRIDGE_DIR="$PROJECT_DIR/interceptor-bridge"
DIST_DIR="$PROJECT_DIR/dist"

INTERCEPTOR_SIGNING_IDENTITY="${INTERCEPTOR_SIGNING_IDENTITY:-Developer ID Application: HACKER VALLEY MEDIA, LLC (TPWBZD35WW)}"
INTERCEPTOR_BRIDGE_IDENTIFIER="com.interceptor.bridge"
INTERCEPTOR_BRIDGE_VERSION="${INTERCEPTOR_BRIDGE_VERSION:-1.0.0}"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"
APP_DIR="$DIST_DIR/interceptor-bridge.app"

echo "==> Building interceptor-bridge (release)..."
cd "$BRIDGE_DIR"
swift build -c release 2>&1

BINARY="$BRIDGE_DIR/.build/release/interceptor-bridge"
if [ ! -f "$BINARY" ]; then
  echo "ERROR: Build failed — binary not found at $BINARY"
  exit 1
fi

mkdir -p "$DIST_DIR"

# Keep the legacy bare-binary path for back-compat — tests, the daemon's
# socket connect path, and older install scripts still look for it here.
cp "$BINARY" "$DIST_DIR/interceptor-bridge"
echo "==> Copied bare binary to $DIST_DIR/interceptor-bridge"

echo "==> Building .app bundle at $APP_DIR ..."
# real .app bundle so macOS TCC can track it by bundle identifier.
# This makes `tccutil` work, makes the Automation Privacy pane show
# interceptor-bridge with a proper name, and lets the OS pop the correct
# consent dialog the first time we send an Apple Event.
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/interceptor-bridge"

# Copy bundled Core ML models into the .app's Resources directory.
# We put them under Contents/Resources/ (rather than letting SwiftPM
# generate a nested resource bundle) because nested SwiftPM bundles lack
# an Info.plist and codesign rejects them.
SOURCE_RESOURCES_DIR="$BRIDGE_DIR/Sources/Resources"
if [[ -d "$SOURCE_RESOURCES_DIR" ]]; then
  for entry in "$SOURCE_RESOURCES_DIR"/*; do
    [[ -e "$entry" ]] || continue
    cp -R "$entry" "$APP_DIR/Contents/Resources/"
    echo "==> Bundled resource: $(basename "$entry")"
  done
fi

# Synthesize Info.plist. LSUIElement=true makes it a faceless agent (no dock
# icon, no menu bar) — same effect main.swift requests at runtime via
# NSApplication.setActivationPolicy(.accessory).
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>interceptor-bridge</string>
    <key>CFBundleIdentifier</key>
    <string>$INTERCEPTOR_BRIDGE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>interceptor-bridge</string>
    <key>CFBundleDisplayName</key>
    <string>interceptor-bridge</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$INTERCEPTOR_BRIDGE_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$INTERCEPTOR_BRIDGE_VERSION</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>interceptor-bridge dispatches Apple Events to apps you ask Interceptor to control via app_intent. macOS will prompt you to allow each target app the first time.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>interceptor-bridge uses the macOS accessibility tree to let Interceptor inspect and drive UI elements (mac_tree, mac_click, mac_type).</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>interceptor-bridge captures screen frames when you ask Interceptor to take screenshots or run screen capture / stream commands.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>interceptor-bridge captures microphone input when you ask Interceptor to use listen / audio commands.</string>
</dict>
</plist>
PLIST

if [[ "${INTERCEPTOR_SKIP_SIGNING:-0}" == "1" ]]; then
  echo "==> INTERCEPTOR_SKIP_SIGNING=1 — skipping codesign (development build)"
else
  if security find-identity -p codesigning -v 2>/dev/null | grep -q "$INTERCEPTOR_SIGNING_IDENTITY"; then
    echo "==> Codesigning bundle with: $INTERCEPTOR_SIGNING_IDENTITY"
    # Sign the inner binary first, then the bundle, with the same entitlements.
    codesign --force --options runtime --timestamp \
      --sign "$INTERCEPTOR_SIGNING_IDENTITY" \
      --identifier "$INTERCEPTOR_BRIDGE_IDENTIFIER" \
      --entitlements "$ENTITLEMENTS" \
      "$APP_DIR/Contents/MacOS/interceptor-bridge"

    codesign --force --options runtime --timestamp \
      --sign "$INTERCEPTOR_SIGNING_IDENTITY" \
      --identifier "$INTERCEPTOR_BRIDGE_IDENTIFIER" \
      --entitlements "$ENTITLEMENTS" \
      "$APP_DIR"

    codesign --verify --strict --verbose=2 "$APP_DIR" || true
  else
    echo "==> Signing identity not present in keychain — performing ad-hoc sign for development."
    echo "    Set INTERCEPTOR_SIGNING_IDENTITY to a real Developer ID for distribution."
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR/Contents/MacOS/interceptor-bridge" 2>/dev/null || true
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR" 2>/dev/null || true
  fi
fi

echo "==> Bundle ready at $APP_DIR"
ls -la "$APP_DIR/Contents/MacOS/interceptor-bridge"
echo "==> Build complete."
