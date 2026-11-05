#!/bin/zsh
# Lance tous les tests : vidéos de test, tests unitaires et d'intégration (export réel), traductions.
# Lancé aussi par release.sh avant chaque version. Demande ffmpeg (brew install ffmpeg).
#
#   ./scripts/test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "→ Vidéos de test"
./scripts/make-fixtures.sh

echo "→ Génération du projet"
xcodegen --quiet

# Compilation à part (la première, dans un dossier neuf, prend une à deux minutes ; les suivantes sont rapides).
echo "→ Compilation"
xcodebuild \
    -project VidSniper.xcodeproj \
    -scheme VidSniper \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath build/test \
    -quiet \
    build-for-testing

echo "→ Tests"
# TEST_RUNNER_* : transmis aux tests (sans le préfixe), active les tests d'intégration.
# Résultats au fil de l'eau (une ligne par test, puis le bilan), journal complet dans build/test/tests.log.
# Code de retour relu à la main : dans zsh, set -e n'arrête pas le script sur un échec au milieu d'un pipe.
result=0
TEST_RUNNER_VIDSNIPER_INTEGRATION=1 xcodebuild \
    -project VidSniper.xcodeproj \
    -scheme VidSniper \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath build/test \
    test-without-building \
    2>&1 | tee build/test/tests.log \
    | { grep --line-buffered -E "Test case|Test run|recorded an issue|Expectation failed|error:|TEST (SUCCEEDED|FAILED)" || true; } \
    || result=$?
if (( result != 0 )); then
    echo "Des tests échouent (détail : build/test/tests.log)." >&2
    exit 1
fi

echo "→ Traductions"
python3 scripts/check-translations.py build/test

echo "Tous les tests passent."
