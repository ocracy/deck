#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

./build.sh

DEST="/Applications/Deck.app"

echo "→ ${DEST} konumuna kuruluyor…"
rm -rf "${DEST}"
mv Deck.app "${DEST}"
xattr -cr "${DEST}" || true

echo ""
echo "✓ Kuruldu: ${DEST}"
echo "  Spotlight: ⌘+Space → \"deck\""
echo "  Veya: open -a Deck"
