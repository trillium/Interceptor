#!/bin/bash
# Uninstall Interceptor.
#
# Handles both install paths:
#   • Pkg install (public release):   /Applications, /usr/local/bin,
#     /Library/Application Support/Interceptor (system locations — needs sudo)
#   • Developer install (install.sh): repo-relative, no sudo
#
# Run with:
#   sudo bash /Library/Application Support/Interceptor/uninstall.sh   (pkg install)
#   bash scripts/uninstall.sh                                          (dev install)

set -euo pipefail

USER_HOME="${USER_HOME_OVERRIDE:-$HOME}"
# Honor sudo: prefer the GUI user's home so we clean per-user files even when
# uninstall is run as root.
if [[ -n "${SUDO_USER:-}" && -d "/Users/$SUDO_USER" ]]; then
  USER_HOME="/Users/$SUDO_USER"
fi

PATH_MARKER_START="# >>> interceptor path >>>"
PATH_MARKER_END="# <<< interceptor path <<<"

echo "==> Stopping interceptor processes..."
pkill -f "interceptor-daemon" 2>/dev/null || true
pkill -f "interceptor-bridge" 2>/dev/null || true

echo "==> Removing runtime files..."
rm -f /tmp/interceptor.sock /tmp/interceptor.pid
rm -f /tmp/interceptor-bridge.sock /tmp/interceptor-bridge.pid

echo "==> Removing native messaging manifests..."
rm -f "$USER_HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.interceptor.host.json"
rm -f "$USER_HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.interceptor.host.json"
rm -f "$USER_HOME/Library/Application Support/Google/ChromeForTesting/NativeMessagingHosts/com.interceptor.host.json"
rm -f "$USER_HOME/Library/Application Support/Chromium/NativeMessagingHosts/com.interceptor.host.json"

# Dev install — clean repo-relative generated dir if present
if [[ -d "$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/daemon/.generated" ]]; then
  rm -rf "$(cd "$(dirname "$0")/.." && pwd)/daemon/.generated"
fi

echo "==> Removing extension metadata from old installs if present..."
rm -f "$USER_HOME/Library/Application Support/Google/Chrome/External Extensions/hkjbaciefhhgekldhncknbjkofbpenng.json"
rm -f "$USER_HOME/Library/Application Support/BraveSoftware/Brave-Browser/External Extensions/hkjbaciefhhgekldhncknbjkofbpenng.json"

echo "==> Removing bridge LaunchAgent (both system and per-user paths)..."
TARGET_UID="$(id -u "${SUDO_USER:-$USER}" 2>/dev/null || echo "")"
if [[ -n "$TARGET_UID" ]]; then
  launchctl bootout "gui/$TARGET_UID/com.interceptor.bridge" 2>/dev/null || true
fi
rm -f "$USER_HOME/Library/LaunchAgents/com.interceptor.bridge.plist"
# pkg install puts the LaunchAgent here (system-wide, root-owned)
if [[ -e "/Library/LaunchAgents/com.interceptor.bridge.plist" ]]; then
  rm -f "/Library/LaunchAgents/com.interceptor.bridge.plist" 2>/dev/null && \
    echo "    removed /Library/LaunchAgents/com.interceptor.bridge.plist" || \
    echo "    /Library/LaunchAgents/com.interceptor.bridge.plist — re-run with sudo"
fi

echo "==> Removing pkg-installed system files (requires sudo to fully clean)..."
if [[ -e "/Applications/interceptor-bridge.app" ]]; then
  rm -rf "/Applications/interceptor-bridge.app" 2>/dev/null && \
    echo "    removed /Applications/interceptor-bridge.app" || \
    echo "    /Applications/interceptor-bridge.app — re-run with sudo"
fi
if [[ -e "/usr/local/bin/interceptor" ]]; then
  rm -f "/usr/local/bin/interceptor" 2>/dev/null && \
    echo "    removed /usr/local/bin/interceptor" || \
    echo "    /usr/local/bin/interceptor — re-run with sudo"
fi
if [[ -e "/usr/local/bin/interceptor-bridge" ]]; then
  rm -f "/usr/local/bin/interceptor-bridge" 2>/dev/null || true
fi
if [[ -e "/Library/Application Support/Interceptor" ]]; then
  rm -rf "/Library/Application Support/Interceptor" 2>/dev/null && \
    echo "    removed /Library/Application Support/Interceptor" || \
    echo "    /Library/Application Support/Interceptor — re-run with sudo"
fi

# Forget the package receipts so a future reinstall starts clean.
pkgutil --pkgs 2>/dev/null | grep -E '^com\.interceptor\.' | while read -r p; do
  pkgutil --forget "$p" >/dev/null 2>&1 || true
done

echo "==> Removing legacy CLI install directory if present..."
rm -rf "$USER_HOME/.interceptor"

echo "==> Removing legacy shell PATH hooks if present..."
for target in "$USER_HOME/.zprofile" "$USER_HOME/.zshrc" "$USER_HOME/.bash_profile" "$USER_HOME/.bashrc"; do
  [[ -f "$target" ]] || continue
  perl -0pi -e "s/\\Q$PATH_MARKER_START\\E.*?\\Q$PATH_MARKER_END\\E\\n?//sg" "$target"
done

echo ""
echo "Interceptor uninstalled."
echo ""
echo "Remove the browser extension manually if it is still present:"
echo "  Brave:  brave://extensions/"
echo "  Chrome: chrome://extensions/"
