#!/usr/bin/env python3
"""Vérifie le catalogue Localizable.xcstrings par rapport aux textes du code.

Les textes à traduire sont relevés par le compilateur (fichiers .stringsdata d'un build). Erreur si un texte
du code n'a pas de traduction française, ou si une traduction ne sert plus.

Usage : scripts/check-translations.py <dossier de build>   (ex. build/test, après ./scripts/test.sh)
"""
import glob
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
build = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "build"

keys = set()
for path in glob.glob(str(build / "**" / "*.stringsdata"), recursive=True):
    # Seuls les textes de l'app comptent, pas ceux des tests.
    if "VidSniperTests" in path:
        continue
    for table in json.load(open(path)).get("tables", {}).values():
        keys.update(entry["key"] for entry in table)
# Clé vide relevée sur un Text("") de MainView : rien à traduire.
keys.discard("")

if not keys:
    sys.exit(f"Aucun texte relevé dans {build} : compiler d'abord.")

catalog = json.load(open(root / "VidSniper/Resources/Localizable.xcstrings"))["strings"]
missing = sorted(
    key for key in keys
    if catalog.get(key, {}).get("localizations", {}).get("fr", {}).get("stringUnit", {}).get("state") != "translated"
)
unused = sorted(key for key in catalog if key not in keys)

for key in missing:
    print(f"Traduction française manquante : {key!r}")
for key in unused:
    print(f"Traduction inutilisée : {key!r}")
if missing or unused:
    sys.exit(1)
print(f"Traductions : {len(keys)} textes, tous traduits.")
