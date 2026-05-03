#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/tools"
BUILD="$ROOT/build"
APP="$BUILD/Divoom MiniToo.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

mkdir -p "$BUILD"

echo "Building Swift daemon..."
swiftc "$TOOLS/DivoomDaemon.swift" \
  -framework Foundation \
  -framework IOBluetooth \
  -framework Network \
  -o "$TOOLS/divoom-daemon"

echo "Building menu-bar app executable..."
swiftc "$TOOLS/DivoomMenuBar.swift" \
  -framework AppKit \
  -o "$TOOLS/divoom-menubar"

echo "Packaging $APP..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES/tools"

cp "$TOOLS/divoom-menubar" "$MACOS/DivoomMiniToo"
cp "$TOOLS/divoom-daemon" "$RESOURCES/tools/divoom-daemon"
cp "$TOOLS/divoom_send.py" "$RESOURCES/tools/divoom_send.py"
cp "$TOOLS/divoom_clock.py" "$RESOURCES/tools/divoom_clock.py"
cp "$TOOLS/send_divoom_image.py" "$RESOURCES/tools/send_divoom_image.py"
cp "$ROOT/PROTOCOL.md" "$RESOURCES/PROTOCOL.md"
chmod +x "$MACOS/DivoomMiniToo" "$RESOURCES/tools/divoom-daemon"

if [[ -x "$ROOT/.venv/bin/python" ]]; then
  echo "Bundling Python venv..."
  ditto "$ROOT/.venv" "$RESOURCES/.venv"
  if [[ -L "$RESOURCES/.venv/bin/python3.14" ]]; then
    PY_TARGET="$(realpath "$ROOT/.venv/bin/python3.14")"
    rm "$RESOURCES/.venv/bin/python3.14"
    cp "$PY_TARGET" "$RESOURCES/.venv/bin/python3.14"
    chmod +x "$RESOURCES/.venv/bin/python3.14"
  fi
else
  echo "warning: $ROOT/.venv/bin/python not found; packaged app will fall back to system python3" >&2
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>DivoomMiniToo</string>
  <key>CFBundleIdentifier</key>
  <string>local.divoom.minitoo</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Divoom MiniToo</string>
  <key>CFBundleDisplayName</key>
  <string>Divoom MiniToo</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Divoom MiniToo opens a Bluetooth RFCOMM channel to send images to the display.</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  echo "Ad-hoc signing app..."
  codesign --force --deep --sign - "$APP" >/dev/null
fi

cat <<EOF

Built: $APP

Install:
  cp -R "$APP" /Applications/

Open:
  open "$APP"

On launch, the app disconnects the Divoom audio profile once, starts the Swift daemon, and keeps RFCOMM open.
EOF
