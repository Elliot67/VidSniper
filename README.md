# VidSniper

App macOS pour enregistrer rapidement une zone de l'écran, faire quelques retouches et partager la vidéo (Slack, Jira…) sans passer par le Finder.

- Raccourci global (⇧⌘8 par défaut) : sélection d'une zone ou de l'écran entier, puis enregistrement avec le son système et le micro.
- Éditeur : coupes, pistes audio équilibrées automatiquement, mise en évidence des clics, annotations (cadre, projecteur).
- Export MP4 léger en arrière-plan, à glisser ou copier (⌘C) directement dans Slack, Jira, un mail…
- Import d'une vidéo existante pour l'éditer de la même façon.

Nécessite **macOS 15 (Sequoia)** ou plus récent.

## Installer

### Téléchargement

1. Télécharger `VidSniper-<version>.zip` depuis la [dernière Release](https://github.com/Elliot67/vid-sniper/releases/latest).
2. Dézipper et glisser `VidSniper.app` dans **Applications**.
3. **Premier lancement** : l'app n'est pas notarisée par Apple (pas de compte développeur payant), macOS la bloque une fois. Au choix :
   - ouvrir l'app, puis **Réglages Système > Confidentialité et sécurité > "Ouvrir quand même"** (tout en bas) ;
   - ou, dans le Terminal : `xattr -dr com.apple.quarantine /Applications/VidSniper.app`.

### Homebrew

```sh
brew tap elliot67/vidsniper https://github.com/Elliot67/vid-sniper
brew install --cask vidsniper
```

Le blocage du premier lancement est levé automatiquement. Mises à jour : `brew upgrade --cask vidsniper`.

### Au premier lancement

- Autoriser **l'enregistrement de l'écran** (obligatoire) et le **micro** (optionnel) depuis la fenêtre de l'app.
- Optionnel : activer **"Lancer à l'ouverture de session"** pour que le raccourci marche sans ouvrir l'app.

## Développement

Prérequis : Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), un certificat "Apple Development" (compte Apple gratuit). Pour compiler avec un autre compte, remplacer `DEVELOPMENT_TEAM` et `bundleIdPrefix` dans `project.yml`.

```sh
xcodegen                    # génère VidSniper.xcodeproj
xcodebuild                  # build Debug dans build/Debug/
./scripts/install.sh        # build Release, installe dans /Applications, supprime la version de dev
./scripts/release.sh        # prépare dist/VidSniper-<version>.zip et la recette Homebrew
./scripts/release.sh --publish   # publie la Release GitHub et pousse la recette
```

Le fonctionnement détaillé et les choix techniques sont dans [PLAN.md](PLAN.md).
