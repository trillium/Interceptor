#!/bin/bash
# Release pipeline — build, sign, notarize, staple, and produce a signed
# installer package suitable for direct public distribution.
#
# Output: dist/release/Interceptor-<version>.pkg
#
# What this does, in order:
#   1.  Verify signing identities, notary profile, entitlements, host arch.
#   2.  bash scripts/build.sh — extension, CLI, daemon, bridge .app.
#   3.  Codesign CLI + daemon with hardened runtime, timestamp, entitlements.
#       (Bridge .app is already signed by build-bridge.sh.)
#   4.  Stage payload + extension + manifest template under dist/release/staging/.
#   5.  Round 1 notarize a zip of the binary payload.
#   6.  Staple the bridge .app (Mach-O binaries can't be stapled — they ride
#       on the online ticket Apple registers during notarization).
#   7.  pkgbuild four component pkgs from the staged tree.
#   8.  productbuild combines them via distribution.xml.
#   9.  productsign signs the combined pkg with the Installer cert.
#   10. Round 2 notarize the signed pkg.
#   11. Staple the pkg.
#   12. Verify with stapler validate, pkgutil --check-signature, spctl --assess.
#
# Env overrides (sensible defaults assume Hacker Valley Media's HVM team):
#   INTERCEPTOR_SIGNING_IDENTITY    Developer ID Application name
#   INTERCEPTOR_INSTALLER_IDENTITY  Developer ID Installer name
#   INTERCEPTOR_NOTARY_PROFILE      keychain profile name for notarytool
#   INTERCEPTOR_VERSION             version string (else read from package.json)

set -euo pipefail

# ── Resolve repo root from script location ────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ── Defaults (overridable via env) ────────────────────────────────────────────
SIGNING_IDENTITY="${INTERCEPTOR_SIGNING_IDENTITY:-Developer ID Application: HACKER VALLEY MEDIA, LLC (TPWBZD35WW)}"
INSTALLER_IDENTITY="${INTERCEPTOR_INSTALLER_IDENTITY:-Developer ID Installer: HACKER VALLEY MEDIA, LLC (TPWBZD35WW)}"
NOTARY_PROFILE="${INTERCEPTOR_NOTARY_PROFILE:-interceptor-notary}"
ENT="$REPO_ROOT/scripts/entitlements.plist"
DIST_XML="$REPO_ROOT/scripts/release/distribution.xml"
POSTINSTALL="$REPO_ROOT/scripts/release/postinstall"

# ── Parse --version flag (defaults to package.json version) ───────────────────
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --version=*) VERSION="${arg#--version=}" ;;
    --version)   shift; VERSION="${1:-}" ;;
    *) ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  if [[ -n "${INTERCEPTOR_VERSION:-}" ]]; then
    VERSION="$INTERCEPTOR_VERSION"
  else
    VERSION="$(grep -E '"version"' "$REPO_ROOT/package.json" | head -1 | sed -E 's/.*"version": *"([^"]+)".*/\1/')"
  fi
fi

if [[ -z "$VERSION" ]]; then
  echo "ERROR: could not determine version (try --version=X.Y.Z)" >&2
  exit 1
fi

# ── Output paths ──────────────────────────────────────────────────────────────
RELEASE_DIR="$REPO_ROOT/dist/release"
STAGING_DIR="$RELEASE_DIR/staging"
COMPONENTS_DIR="$RELEASE_DIR/components"
PAYLOAD_ZIP="$RELEASE_DIR/payload.zip"
UNSIGNED_PKG="$RELEASE_DIR/Interceptor-${VERSION}-unsigned.pkg"
SIGNED_PKG="$RELEASE_DIR/Interceptor-${VERSION}.pkg"

# Final install destinations the pkg payload mimics
DEST_CLI_DIR="usr/local/bin"
DEST_BRIDGE_DIR="Applications"
DEST_SUPPORT_DIR="Library/Application Support/Interceptor"
DEST_EXTENSION_DIR="${DEST_SUPPORT_DIR}/extension"

# ── Step 1: Prerequisite checks ───────────────────────────────────────────────
echo "==> Step 1: Verifying prerequisites"

if ! security find-identity -v 2>/dev/null | grep -q "$SIGNING_IDENTITY"; then
  echo "ERROR: signing identity not found in keychain: $SIGNING_IDENTITY" >&2
  echo "       (override via INTERCEPTOR_SIGNING_IDENTITY)" >&2
  exit 1
fi

if ! security find-identity -v 2>/dev/null | grep -q "$INSTALLER_IDENTITY"; then
  echo "ERROR: installer identity not found in keychain: $INSTALLER_IDENTITY" >&2
  echo "       (override via INTERCEPTOR_INSTALLER_IDENTITY)" >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "ERROR: notarytool keychain profile '$NOTARY_PROFILE' is not configured." >&2
  echo "       Create it with:" >&2
  echo "         xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
  echo "           --apple-id <your-apple-id> --team-id <your-team-id> --password <app-specific-password>" >&2
  exit 1
fi

if [[ ! -f "$ENT" ]]; then
  echo "ERROR: entitlements file missing at $ENT" >&2
  exit 1
fi
if ! plutil -lint "$ENT" >/dev/null; then
  echo "ERROR: entitlements file is not a valid plist: $ENT" >&2
  exit 1
fi

if [[ ! -f "$DIST_XML" ]]; then
  echo "ERROR: distribution.xml missing at $DIST_XML" >&2
  exit 1
fi

if [[ ! -x "$POSTINSTALL" ]]; then
  echo "ERROR: postinstall script missing or not executable: $POSTINSTALL" >&2
  exit 1
fi

echo "    Version:           $VERSION"
echo "    Signing identity:  $SIGNING_IDENTITY"
echo "    Installer cert:    $INSTALLER_IDENTITY"
echo "    Notary profile:    $NOTARY_PROFILE"
echo ""

# ── Step 2: Build ─────────────────────────────────────────────────────────────
echo "==> Step 2: bash scripts/build.sh"
bash "$REPO_ROOT/scripts/build.sh"
echo ""

# ── Step 3: Codesign CLI + daemon ─────────────────────────────────────────────
echo "==> Step 3: Codesigning CLI and daemon (hardened runtime + timestamp)"

codesign --force --options runtime --timestamp \
  --sign "$SIGNING_IDENTITY" \
  --identifier "com.interceptor.cli" \
  --entitlements "$ENT" \
  "$REPO_ROOT/dist/interceptor"

codesign --force --options runtime --timestamp \
  --sign "$SIGNING_IDENTITY" \
  --identifier "com.interceptor.daemon" \
  --entitlements "$ENT" \
  "$REPO_ROOT/daemon/interceptor-daemon"

codesign --verify --strict --verbose=2 "$REPO_ROOT/dist/interceptor"
codesign --verify --strict --verbose=2 "$REPO_ROOT/daemon/interceptor-daemon"
codesign --verify --strict --verbose=2 "$REPO_ROOT/dist/interceptor-bridge.app"
echo ""

# ── Step 4: Stage payload tree ────────────────────────────────────────────────
echo "==> Step 4: Staging payload tree under dist/release/staging/"

rm -rf "$RELEASE_DIR"
mkdir -p "$STAGING_DIR/cli/$DEST_CLI_DIR"
mkdir -p "$STAGING_DIR/bridge/$DEST_BRIDGE_DIR"
mkdir -p "$STAGING_DIR/daemon/$DEST_SUPPORT_DIR"
mkdir -p "$STAGING_DIR/extension/$DEST_EXTENSION_DIR"
mkdir -p "$COMPONENTS_DIR"

# CLI: dist/interceptor → staging/cli/usr/local/bin/interceptor
ditto "$REPO_ROOT/dist/interceptor" "$STAGING_DIR/cli/$DEST_CLI_DIR/interceptor"
chmod 755 "$STAGING_DIR/cli/$DEST_CLI_DIR/interceptor"

# Bridge: dist/interceptor-bridge.app → staging/bridge/Applications/interceptor-bridge.app
ditto "$REPO_ROOT/dist/interceptor-bridge.app" "$STAGING_DIR/bridge/$DEST_BRIDGE_DIR/interceptor-bridge.app"

# Daemon binary: daemon/interceptor-daemon → staging/daemon/<support>/interceptor-daemon
ditto "$REPO_ROOT/daemon/interceptor-daemon" "$STAGING_DIR/daemon/$DEST_SUPPORT_DIR/interceptor-daemon"
chmod 755 "$STAGING_DIR/daemon/$DEST_SUPPORT_DIR/interceptor-daemon"

# Pre-render the native messaging host manifest with the now-stable absolute
# daemon path baked in. Pkg install paths are fixed, so there's no reason to
# ship a template + run sed at install time — just lay down the final file.
RENDERED_MANIFEST="$STAGING_DIR/daemon/$DEST_SUPPORT_DIR/com.interceptor.host.json"
ABS_DAEMON_PATH="/$DEST_SUPPORT_DIR/interceptor-daemon"
ESCAPED_DAEMON_PATH="$(printf '%s' "$ABS_DAEMON_PATH" | sed 's/[&|\\]/\\&/g')"
sed "s|__DAEMON_PATH__|$ESCAPED_DAEMON_PATH|g" \
  "$REPO_ROOT/daemon/com.interceptor.host.json" > "$RENDERED_MANIFEST"
chmod 644 "$RENDERED_MANIFEST"

# Stage uninstall script for the user
ditto "$REPO_ROOT/scripts/uninstall.sh" "$STAGING_DIR/daemon/$DEST_SUPPORT_DIR/uninstall.sh"
chmod 755 "$STAGING_DIR/daemon/$DEST_SUPPORT_DIR/uninstall.sh"

# Stage the project README so users have local docs at the install location
ditto "$REPO_ROOT/README.md" "$STAGING_DIR/daemon/$DEST_SUPPORT_DIR/README.md"
chmod 644 "$STAGING_DIR/daemon/$DEST_SUPPORT_DIR/README.md"

# Stage the LaunchAgent plist as part of the daemon component payload (was
# being written by a heredoc in the postinstall — moving it here means the
# pkg owns the file properly: pkgutil tracks it, it's idempotent across
# reinstalls, and macOS auto-loads it on every user login).
mkdir -p "$STAGING_DIR/daemon/Library/LaunchAgents"
ditto "$REPO_ROOT/scripts/release/com.interceptor.bridge.plist" \
  "$STAGING_DIR/daemon/Library/LaunchAgents/com.interceptor.bridge.plist"
chmod 644 "$STAGING_DIR/daemon/Library/LaunchAgents/com.interceptor.bridge.plist"

# Browser extension: extension/dist → staging/extension/<support>/extension
ditto "$REPO_ROOT/extension/dist" "$STAGING_DIR/extension/$DEST_EXTENSION_DIR"

echo "    Staged tree:"
find "$STAGING_DIR" -maxdepth 4 -type d | sed 's|^|    |'
echo ""

# ── Step 5: Round 1 notarization (binary payload) ─────────────────────────────
echo "==> Step 5: Round 1 notarization — submitting binary payload"

mkdir -p "$RELEASE_DIR/_payload"
ditto "$STAGING_DIR/cli/$DEST_CLI_DIR/interceptor" "$RELEASE_DIR/_payload/interceptor"
ditto "$STAGING_DIR/daemon/$DEST_SUPPORT_DIR/interceptor-daemon" "$RELEASE_DIR/_payload/interceptor-daemon"
ditto "$STAGING_DIR/bridge/$DEST_BRIDGE_DIR/interceptor-bridge.app" "$RELEASE_DIR/_payload/interceptor-bridge.app"

(cd "$RELEASE_DIR" && rm -f payload.zip && \
  ditto -c -k --keepParent --sequesterRsrc _payload payload.zip)

echo "    Submitting $PAYLOAD_ZIP to Apple notary (this can take 1-15 min)..."
NOTARY_OUTPUT_1="$(xcrun notarytool submit "$PAYLOAD_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
echo "$NOTARY_OUTPUT_1"

if ! echo "$NOTARY_OUTPUT_1" | grep -q "status: Accepted"; then
  echo "ERROR: round 1 notarization did not return Accepted" >&2
  exit 1
fi
echo ""

# ── Step 6: Staple the bridge .app (Mach-O can't be stapled) ──────────────────
echo "==> Step 6: Stapling bridge .app (in staging tree)"
xcrun stapler staple "$STAGING_DIR/bridge/$DEST_BRIDGE_DIR/interceptor-bridge.app"
xcrun stapler validate "$STAGING_DIR/bridge/$DEST_BRIDGE_DIR/interceptor-bridge.app"
echo ""

# ── Step 7: pkgbuild four component pkgs ──────────────────────────────────────
echo "==> Step 7: Building component pkgs"

# CLI component
pkgbuild \
  --root "$STAGING_DIR/cli" \
  --identifier "com.interceptor.cli.pkg" \
  --version "$VERSION" \
  --install-location "/" \
  "$COMPONENTS_DIR/Interceptor-CLI.pkg"

# Bridge component — uses an explicit component plist that locks
# BundleIsRelocatable=false so the user can't drag the .app to a different
# location and break the postinstall-rendered NMH manifest paths.
pkgbuild \
  --root "$STAGING_DIR/bridge" \
  --identifier "com.interceptor.bridge.pkg" \
  --version "$VERSION" \
  --install-location "/" \
  --component-plist "$REPO_ROOT/scripts/release/bridge-component.plist" \
  "$COMPONENTS_DIR/Interceptor-Bridge.pkg"

# Daemon component — attach the postinstall script here so it runs after the
# manifest template is on disk
pkgbuild \
  --root "$STAGING_DIR/daemon" \
  --identifier "com.interceptor.daemon.pkg" \
  --version "$VERSION" \
  --install-location "/" \
  --scripts "$REPO_ROOT/scripts/release" \
  "$COMPONENTS_DIR/Interceptor-Daemon.pkg"

# Extension component
pkgbuild \
  --root "$STAGING_DIR/extension" \
  --identifier "com.interceptor.extension.pkg" \
  --version "$VERSION" \
  --install-location "/" \
  "$COMPONENTS_DIR/Interceptor-Extension.pkg"

echo "    Built component pkgs:"
ls -la "$COMPONENTS_DIR"
echo ""

# ── Step 8: productbuild combines components ──────────────────────────────────
echo "==> Step 8: productbuild combining components into unsigned pkg"

productbuild \
  --distribution "$DIST_XML" \
  --package-path "$COMPONENTS_DIR" \
  --resources "$REPO_ROOT/scripts/release/Resources" \
  --version "$VERSION" \
  "$UNSIGNED_PKG"

echo "    Unsigned pkg: $UNSIGNED_PKG"
ls -lh "$UNSIGNED_PKG"
echo ""

# ── Step 9: productsign with Developer ID Installer cert ──────────────────────
echo "==> Step 9: Signing pkg with Developer ID Installer cert"

productsign \
  --sign "$INSTALLER_IDENTITY" \
  --timestamp \
  "$UNSIGNED_PKG" \
  "$SIGNED_PKG"

pkgutil --check-signature "$SIGNED_PKG"
echo ""

# ── Step 10: Round 2 notarization (the signed pkg) ────────────────────────────
echo "==> Step 10: Round 2 notarization — submitting signed pkg"

NOTARY_OUTPUT_2="$(xcrun notarytool submit "$SIGNED_PKG" \
  --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
echo "$NOTARY_OUTPUT_2"

if ! echo "$NOTARY_OUTPUT_2" | grep -q "status: Accepted"; then
  echo "ERROR: round 2 notarization did not return Accepted" >&2
  exit 1
fi
echo ""

# ── Step 11: Staple the pkg ───────────────────────────────────────────────────
echo "==> Step 11: Stapling the pkg"
xcrun stapler staple "$SIGNED_PKG"
xcrun stapler validate "$SIGNED_PKG"
echo ""

# ── Step 12: Final verification ───────────────────────────────────────────────
echo "==> Step 12: Final verification"

echo "--- pkgutil --check-signature ---"
pkgutil --check-signature "$SIGNED_PKG"
echo ""

echo "--- xcrun stapler validate ---"
xcrun stapler validate "$SIGNED_PKG"
echo ""

echo "--- spctl --assess --type install ---"
spctl --assess --type install --verbose=2 "$SIGNED_PKG" 2>&1 || true
echo ""

# Clean up scratch staging that round 1 needed
rm -rf "$RELEASE_DIR/_payload"
rm -f "$PAYLOAD_ZIP"
rm -f "$UNSIGNED_PKG"

echo "================================================================"
echo "Release ready:"
echo "  $SIGNED_PKG"
echo "  $(du -h "$SIGNED_PKG" | cut -f1) — signed, notarized, stapled"
echo "================================================================"
