#!/bin/zsh
# Compile VidSniper en Release, l'installe dans /Applications, supprime la version de dev, puis lance l'app.
# Usage : ./scripts/install.sh
set -euo pipefail

cd "$(dirname "$0")/.."

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

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

# Une seule VidSniper sur le Mac : les copies de build (même identifiant) sont désenregistrées
# auprès de macOS puis supprimées. Sinon, deux apps se disputeraient le raccourci global
# et Spotlight proposerait les deux.
echo "→ Suppression des versions de dev"
for copy in build/Debug/VidSniper.app "$app"; do
    if [[ -d "$copy" ]]; then
        "$lsregister" -u "$copy" 2>/dev/null || true
        rm -rf "$copy"
    fi
done
"$lsregister" -f /Applications/VidSniper.app

echo "→ Lancement"
open /Applications/VidSniper.app
echo "VidSniper est installée dans /Applications."
