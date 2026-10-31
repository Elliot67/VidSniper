#!/bin/zsh
# Prépare une version téléchargeable de VidSniper : build Release (Apple Silicon + Intel), signé avec le
# certificat "Apple Development" (gratuit), zippé dans dist/, et recette Homebrew (Casks/vidsniper.rb) à jour.
#
# Usage :
#   ./scripts/release.sh            prépare dist/VidSniper-<version>.zip et met à jour la recette
#   ./scripts/release.sh --publish  publie aussi la Release GitHub (gh) et pousse la recette
#
# La version vient de CFBundleShortVersionString dans project.yml : l'augmenter avant chaque publication.
# Dépôt GitHub : REPO=<compte>/<dépôt> pour changer celui par défaut.
set -euo pipefail

cd "$(dirname "$0")/.."

repo="${REPO:-Elliot67/vid-sniper}"
publish=false
[[ "${1:-}" == "--publish" ]] && publish=true

echo "→ Génération du projet"
xcodegen --quiet
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" VidSniper/Resources/Info.plist)
echo "  Version $version"

echo "→ Compilation (Release, Apple Silicon + Intel)"
rm -rf build/release
xcodebuild \
    -project VidSniper.xcodeproj \
    -scheme VidSniper \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath build/release \
    -quiet \
    build

app="build/release/Build/Products/Release/VidSniper.app"
codesign --verify --strict "$app"

echo "→ Archive"
mkdir -p dist
zip="dist/VidSniper-$version.zip"
rm -f "$zip"
# ditto garde les attributs et la signature de l'app intacts (zip ne le fait pas).
ditto -c -k --keepParent "$app" "$zip"
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
echo "  $zip"
echo "  sha256 $sha"

echo "→ Recette Homebrew"
sed -i '' \
    -e "s/^  version \".*\"/  version \"$version\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" \
    Casks/vidsniper.rb

if ! $publish; then
    echo ""
    echo "Prêt. Pour publier : ./scripts/release.sh --publish (ou créer la Release v$version à la main"
    echo "sur https://github.com/$repo/releases avec $zip, puis committer Casks/vidsniper.rb)."
    exit 0
fi

echo "→ Publication de la Release v$version sur $repo"
gh release create "v$version" "$zip" \
    --repo "$repo" \
    --title "VidSniper $version" \
    --notes "Téléchargement direct ou Homebrew : voir le README (premier lancement à débloquer une fois)."

echo "→ Recette Homebrew"
git add Casks/vidsniper.rb
git commit -m "Homebrew : VidSniper $version"
git push

echo "VidSniper $version est publiée."
