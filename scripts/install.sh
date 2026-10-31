#!/bin/zsh
# Compile VidSniper en Release et l'installe dans /Applications, puis la lance.
# Usage : ./scripts/install.sh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "→ Génération du projet"
xcodegen --quiet

echo "→ Compilation (Release)"
xcodebuild \
    -project VidSniper.xcodeproj \
    -scheme VidSniper \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath build/release \
    -quiet \
    build

app="build/release/Build/Products/Release/VidSniper.app"

echo "→ Installation dans /Applications"
pkill -x VidSniper || true
sleep 1
rm -rf /Applications/VidSniper.app
cp -R "$app" /Applications/

echo "→ Lancement"
open /Applications/VidSniper.app
echo "VidSniper est installée dans /Applications."
