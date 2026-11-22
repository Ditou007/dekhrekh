#!/usr/bin/env bash
# ./build.sh            build the app and the CLI into build/
# ./build.sh --install  also install: app to ~/Applications, CLI on PATH, start at login
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Dekhrekh.app"
CLI="build/dekhrekh"
SWIFT_FLAGS=(-O -swift-version 5 -target "$(uname -m)-apple-macosx14.0")
INSTALLED_APP="$HOME/Applications/Dekhrekh.app"
AGENT_LABEL="io.github.ditou007.dekhrekh"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

# A real certificate keeps the code signature's identity stable across rebuilds, so macOS
# permissions (Automation for Ghostty) are granted once. Ad-hoc signing changes every build.
SIGN_ID="${DEKHREKH_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development/ {print $2; exit}')}"
SIGN_ID="${SIGN_ID:--}"

sign() { codesign --force --sign "$SIGN_ID" "$1" >/dev/null 2>&1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc "${SWIFT_FLAGS[@]}" -o "$APP/Contents/MacOS/Dekhrekh" Sources/Shared/*.swift Sources/App/*.swift
sign "$APP"
echo "built $APP (signed: ${SIGN_ID})"

swiftc "${SWIFT_FLAGS[@]}" -o "$CLI" Sources/Shared/*.swift Sources/CLI/*.swift
sign "$CLI"
echo "built $CLI"

[ "${1:-}" = "--install" ] || exit 0

mkdir -p "$HOME/.local/bin" "$HOME/Applications" "$HOME/Library/LaunchAgents"
ln -sf "$PWD/$CLI" "$HOME/.local/bin/dekhrekh"
echo "linked ~/.local/bin/dekhrekh (make sure ~/.local/bin is on your PATH)"

pkill -x Dekhrekh 2>/dev/null || true
rm -rf "$INSTALLED_APP"
cp -R "$APP" "$INSTALLED_APP"
echo "installed $INSTALLED_APP"

cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>$INSTALLED_APP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
echo "login agent loaded: $AGENT_PLIST (starts Dekhrekh at login)"
