#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# build.sh ile senkron tut.
VERSION="0.6.4"
APP_NAME="Deck"
APP="${APP_NAME}.app"

echo "→ App icon üretiliyor…"
swift scripts/make-icon.swift
iconutil -c icns AppIcon.iconset -o AppIcon.icns

# Not: --arch arm64 --arch x86_64 universal build'i Metal Toolchain ister
# (xcodebuild -downloadComponent MetalToolchain); şimdilik native arch.
echo "→ Release derleniyor (native arch)…"
swift build -c release
BIN_PATH=".build/release/${APP_NAME}"

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
</dict>
</plist>
PLIST

echo "→ Ad-hoc imzalanıyor…"
codesign --force --deep --sign - "${APP}"

cat > INSTALL.txt <<'TXT'
Deck Kurulum
============
1. Deck.app'i /Applications klasörüne sürükle.
2. Terminal'de şunu çalıştır (Gatekeeper karantinasını temizler):
   xattr -cr /Applications/Deck.app
3. Deck'i aç. tmux kurulu olmalı: brew install tmux
TXT

echo "→ Deck.zip paketleniyor…"
rm -f Deck.zip
zip -qry Deck.zip "${APP}" INSTALL.txt
rm -f INSTALL.txt

SIZE=$(du -h Deck.zip | cut -f1)
echo "✓ Deck.zip hazır (${SIZE}) — mimari: $(uname -m)"
