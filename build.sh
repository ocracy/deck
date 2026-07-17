#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# dist.sh ile senkron tut — tek sürüm kaynağı.
VERSION="0.6.4"

APP_NAME="Deck"
APP="${APP_NAME}.app"
BIN_PATH=".build/release/${APP_NAME}"

echo "→ App icon üretiliyor…"
swift scripts/make-icon.swift
iconutil -c icns AppIcon.iconset -o AppIcon.icns

echo "→ ${APP_NAME} derleniyor (release)…"
swift build -c release

if [ ! -f "${BIN_PATH}" ]; then
  echo "✗ Build başarısız: ${BIN_PATH} yok"
  exit 1
fi

echo "→ ${APP} paketleniyor…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN_PATH}" "${APP}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP}/Contents/MacOS/${APP_NAME}"
cp AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Deck</string>
  <key>CFBundleIdentifier</key><string>app.deck.launcher</string>
  <key>CFBundleName</key><string>Deck</string>
  <key>CFBundleDisplayName</key><string>Deck</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><false/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
  <key>NSCameraUsageDescription</key>
  <string>Deck'in gömülü tarayıcısı, yerel web sayfalarının getUserMedia() kullanabilmesi için kamera erişimine ihtiyaç duyar.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Deck'in gömülü tarayıcısı, yerel web sayfalarının getUserMedia() kullanabilmesi için mikrofon erişimine ihtiyaç duyar.</string>
</dict>
</plist>
PLIST

echo "✓ Hazır: $(pwd)/${APP}"
