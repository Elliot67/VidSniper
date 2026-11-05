# VidSniper - plan

App macOS pour enregistrer rapidement une zone de l'écran, faire 2-3 retouches et partager la vidéo (Slack, Jira...) sans passer par le Finder.

> Ce document est mis à jour à chaque étape avec les retours de test, pour toujours décrire le comportement réel de l'app.

## Avancement

| # | Contenu | Statut |
|---|---|---|
| 0 | Projet XcodeGen, signature, permissions, fenêtre principale, `Theme.swift` | Fait |
| 1 | Raccourci global, sélecteur de zone, capture 3 pistes, mini barre, déplacement de zone en cours d'enregistrement | Fait |
| 2 | Éditeur : lecture, trim, cuts, pistes audio, raccourcis clavier, annuler, timeline zoomable | Fait |
| 3 | Export : réglages, estimation, glisser, copier, enregistrer, cache ; niveaux audio automatiques + balance | Fait |
| 4 (bonus) | Mise en évidence des clics (animation à deux bulles, couleur, ligne "Clics" dans la timeline) | Fait |
| 4 (bonus) | Installation dans `/Applications`, réglage du raccourci global, icône de l'app | Fait |
| 4 (bonus) | Annotations (cadre / projecteur, rectangle / ellipse, couleurs) sur une plage de temps, timeline retravaillée, aide des raccourcis | Fait |
| 5 | **Importer un fichier vidéo** existant pour l'éditer et l'exporter avec le même éditeur (version de base, sans clics) | Fait |
| 6 | Finitions : récupérer une partie supprimée en rallongeant un voisin, clics dans l'aperçu de rallonge, page d'accueil refaite avec le logo | Fait |
| 7 | Traductions anglais / français (String Catalogs) | Fait, à tester |
| 8 | Onglets Édition / Export : aperçu du MP4, bouton Original, zoom, poids de chaque option, confirmation de copie | Fait |
| 9 | Export : définition Retina / Écran, 5 niveaux de compression, clé toutes les 10 s, plancher 200 kb/s | Fait |
| 10 | ~~Courbe de qualité~~ (fidélité de chaque niveau, mesurée sur les passages qui bougent le plus) | Abandonné : trop lent, ne dit pas si le texte reste lisible (décision de l'utilisateur) |
| 11 | **À faire ensuite** : au début de l'enregistrement, le contour de la zone apparaît avec une animation (bordures qui rentrent dans le cadre, léger zoom), et il se retrouve au tout début de chaque vidéo. Supprimer l'animation et le zoom : le contour doit être là, immobile, dès la première image | À faire (demande de l'utilisateur, après la courbe de qualité) |
| - | ~~Remplacer une piste audio par un fichier~~ | Abandonné (pas nécessaire) |

### Import de vidéo (phase 5)

- **Ouvrir** : bouton "Importer une vidéo…" dans la fenêtre principale, **⌘O** (menu Fichier), **glisser le fichier sur la fenêtre principale** (cadre violet en pointillés au survol), **glisser sur l'icône du Dock** ou **"Ouvrir avec → VidSniper"** dans le Finder (`CFBundleDocumentTypes` : `public.movie`, rôle Viewer, rang Alternate pour ne pas devenir l'app par défaut). Une vidéo reçue pendant le démarrage est ouverte une fois l'app prête.
- **Formats** : tout ce qu'AVFoundation lit (`.mov`, `.mp4`, `.m4v` ; H.264, HEVC, ProRes…). Fichier illisible ou sans piste vidéo : refusé avec un message dans la fenêtre principale.
- **Pistes audio** : l'éditeur garde ses deux emplacements. 1 piste → ligne "Audio" ; 2 pistes ou plus → "Audio 1" et "Audio 2" avec la balance entre les deux ; les pistes suivantes (rares) sont ignorées. Icônes génériques (forme d'onde). Choix assumé : les pistes alternatives (langues d'un film) ne sont pas distinguées, elles seraient mixées, car ce cas n'est pas visé. Normalisation automatique et garde-fous des pistes muettes comme pour un enregistrement.
- **Rotation** : les dimensions (proportions, miniatures, taille d'export) tiennent compte de la rotation de la piste (vidéo de téléphone en portrait).
- **Fichier d'origine jamais touché** : lu en place, ni copié, ni modifié, ni purgé (la purge ne vise que `~/Library/Caches/VidSniper`). Le MP4 exporté porte le nom du fichier d'origine.
- **Pas de clics** : la ligne "Clics" de la timeline est masquée pour une vidéo importée. Les annotations, elles, marchent comme pour un enregistrement.
- La fenêtre principale garde la dernière vidéo ouverte ("Vidéo importée + audio 1 + audio 2") pour rouvrir l'éditeur.

## Le déroulé

Raccourci global (⌘⇧8) → sélection d'une zone → enregistrement avec mini barre → éditeur (cuts, pistes audio) → glisser ou copier la vidéo. Rien n'est conservé, sauf via "Enregistrer…".

## Stack

- **Swift 6 + SwiftUI**, AppKit pour les fenêtres spéciales (calque de sélection, mini barre, poignée).
- **macOS 15 minimum** (dev sur macOS 26).
- **ScreenCaptureKit** pour la capture, **AVFoundation** pour le montage et l'export. Pas de ffmpeg.
- **Raccourci global via l'API Carbon** (`RegisterEventHotKey`) : pas de dépendance, pas de permission Accessibilité. Un écran de réglage du raccourci pourra venir plus tard.
- **XcodeGen** : `project.yml` versionné, le `.xcodeproj` est généré et ignoré par git.
- App dans le Dock, sans icône dans la barre des menus, sans App Sandbox (usage perso).
- Signature "Apple Development", team `T9WD2H73Y6`, hardened runtime avec l'entitlement micro. Une signature stable évite que macOS redemande la permission d'écran à chaque build.

### Build (contraintes du sandbox de Claude Code)

- `xcodegen` et `xcodebuild` sont exclus du sandbox, mais **uniquement lancés sans arguments**.
- `xcodegen` (génère le projet), puis `xcodebuild` (build Debug dans `build/Debug/VidSniper.app`).
- Relancer l'app : `pkill -x VidSniper; sleep 1; open build/Debug/VidSniper.app` (le `sleep` évite l'erreur -600).
- Prérequis signature : le certificat intermédiaire Apple **WWDR G3** (https://www.apple.com/certificateauthority/) doit être installé, sinon le certificat de dev est considéré invalide.
- **Installation** : `./scripts/install.sh` (à lancer soi-même, hors sandbox) compile en Release, remplace `/Applications/VidSniper.app` et la lance. Même signature que le build de dev : les permissions restent accordées. Il **supprime ensuite les copies de build** (`build/Debug` et le build Release), après les avoir désenregistrées de Launch Services : une seule VidSniper sur le Mac (pas de conflit sur le raccourci global, pas de doublon dans Spotlight).

### Traductions (anglais / français)

- Méthode standard Apple : **String Catalogs**. Le code est écrit en **anglais** (langue source, `developmentLanguage: en`), le français est dans `VidSniper/Resources/Localizable.xcstrings`. Les textes de l'Info.plist (description du micro, type de document "Video") sont traduits dans `InfoPlist.xcstrings`.
- La langue suit celle du système (Réglages Système > Général > Langue et région, avec un réglage par app possible dans "Applications"). Anglais par défaut pour toute autre langue.
- Dans le code : les littéraux SwiftUI (`Text("…")`, `Button`, `Label`, `.help`) sont traduits automatiquement. Tout texte qui passe par une variable `String` (titres des composants `ToggleChip`, `ActionTile`, `Card`, `SettingsRow`, cellules de la timeline, erreurs, textes dessinés en AppKit) passe par `String(localized: "…")`. Ce qui ne se traduit pas (nom de l'app, durées, dimensions) utilise `Text(verbatim:)`.
- Interpolations : `"Size: \(x)"` donne la clé `Size: %@` (`%lld` pour un entier) ; avec plusieurs valeurs, la traduction peut les réordonner (`%1$@`, `%2$@`).
- Ajouter un texte : l'écrire en anglais dans le code, puis ajouter la traduction dans le catalogue (Xcode le complète à chaque build quand le projet est ouvert dans Xcode ; en ligne de commande, les clés extraites sont dans les fichiers `.stringsdata` du dossier `build/`).
- Les libellés n'ont pas la même longueur selon la langue : les boutons "Copier" et "Enregistrer…" de l'export prennent tous les deux la largeur du plus long (retour de test en anglais, où "Copy" était plus large que "Save…"). Ils ont aussi la même hauteur, la même police et la même position d'icône : `SecondaryButtonStyle(large: true)` reprend les dimensions d'`AccentButtonStyle`.
- Le nom des fichiers enregistrés suit aussi la langue ("2026-10-31 at 14.03.22" / "2026-10-31 à 14.03.22").

### Distribution (gratuite, sans App Store)

- **Pas de compte Apple Developer payant** : l'app est signée avec le certificat gratuit "Apple Development" (signature stable d'une version à l'autre, donc les permissions sont gardées après une mise à jour), mais **pas notarisée**. macOS bloque son premier lancement chez les autres : "Ouvrir quand même" dans Réglages Système > Confidentialité et sécurité, ou `xattr -dr com.apple.quarantine /Applications/VidSniper.app`.
- **Téléchargement** : `./scripts/release.sh` compile en Release (Apple Silicon + Intel), vérifie la signature, zippe l'app avec `ditto` dans `dist/VidSniper-<version>.zip` (ignoré par git) et met à jour la recette Homebrew. `--publish` crée en plus la Release GitHub (`gh`) et pousse la recette. Version : `CFBundleShortVersionString` dans `project.yml`, à augmenter avant chaque publication.
- **Release automatique (GitHub Actions)** : `.github/workflows/release.yml`, déclenchée par un tag : `git tag v0.2.0 && git push origin v0.2.0`. Sur un runner macOS de GitHub (gratuit pour un dépôt public) : installe XcodeGen, lance `scripts/release.sh` avec la version du tag (`VERSION`, écrite dans `project.yml` le temps du build) et une **signature ad hoc** (`SIGN_IDENTITY=-`), crée la Release avec le zip et des notes générées, puis committe la recette Homebrew sur `main`. Choix de l'utilisateur : **pas de certificat dans le CI**, donc macOS redemande les permissions écran et micro après chaque mise à jour installée depuis une Release (et une fois en passant de `install.sh` à une Release, ou l'inverse). Ajouter le certificat plus tard : l'exporter en `.p12` dans les secrets du dépôt et l'importer dans un trousseau temporaire avant le build.
- **Homebrew** : le tap est **dans le dépôt de l'app** (dossier `Casks/` à la racine, recette `Casks/vidsniper.rb`). Installation en deux commandes : `brew tap elliot67/vidsniper https://github.com/Elliot67/vid-sniper` puis `brew install --cask vidsniper`. La recette retire la quarantaine après l'installation (`postflight`), donc pas de blocage au premier lancement. Le dépôt officiel de Homebrew n'est pas possible : il exige des apps notarisées.
- Le dépôt GitHub doit être **public** pour que le téléchargement et le tap fonctionnent. Nom supposé : `Elliot67/vid-sniper` (variable `REPO` du script, et URLs de la recette et du README à ajuster si besoin).
- `README.md` : présentation, installation (téléchargement, Homebrew, premier lancement), développement.
- **Icône** : générée par `scripts/make-icon.swift` (fond sombre façon Obsidian, coins de sélection, viseur violet, point rouge d'enregistrement), qui écrit toutes les tailles dans `VidSniper/Resources/Assets.xcassets/AppIcon.appiconset`. À relancer seulement pour modifier l'icône.

## UI : style Obsidian

- Suit le thème système (clair ou sombre), palette centralisée dans `VidSniper/UI/Theme.swift`.
- Sombre : fond `#1E1E1E`, fond secondaire `#262626`, bordures `#363636`, texte `#DADADA`, texte atténué `#999999`.
- Clair : fond `#FFFFFF`, fond secondaire `#F6F6F6`, bordures `#E0E0E0`, texte `#222222`, texte atténué `#5C5C5C`.
- Accent violet `#8A5CF5`. Coins arrondis 6 px, petites polices, fines bordures, pas de dégradés.

## Fenêtre principale

- **En-tête** : logo de l'app (icône), nom et phrase de présentation.
- **Deux tuiles d'action** côte à côte : "Nouvel enregistrement" (violette, avec le raccourci) et "Importer une vidéo" (secondaire, rappel de ⌘O et du glisser-déposer). Survol marqué. Glisser une vidéo n'importe où sur la fenêtre l'ouvre aussi (cadre violet en pointillés). Les tuiles ne prennent pas le focus clavier, et aucun contrôle n'est sélectionné à l'ouverture de la fenêtre (sinon contour bleu sur la première tuile, puis sur le bouton du raccourci) ; Tab permet toujours de naviguer au clavier.
- Erreurs dans un bandeau rouge discret.
- Carte **"Dernière vidéo"** : nom, type et pistes, bouton "Ouvrir".
- Carte **"Réglages"**, lignes avec icône alignée, titre, détail et contrôle à droite :
  - **Enregistrement de l'écran** : obligatoire (point rouge et bouton "Autoriser" tant qu'il n'est pas accordé).
  - **Micro** : **optionnel** (point gris). Sans autorisation, l'interrupteur Micro est désactivé et l'enregistrement se fait sans piste micro.
  - **Raccourci global** (⇧⌘8 par défaut) : clic sur le raccourci, puis taper le nouveau (au moins ⌘, ⌥ ou ⌃ ; Esc annule). Le raccourci actuel est suspendu pendant la saisie. S'il est déjà pris par une autre app, il est refusé avec un message. Une petite croix intégrée à la même pastille (visible seulement si le raccourci a été changé) revient à ⇧⌘8. Libellé dans l'ordre macOS (⌃⌥⇧⌘), touche telle qu'imprimée sur le clavier (AZERTY compris).
  - **"Lancer à l'ouverture de session"** (`SMAppService`) : l'app démarre sans fenêtre et le raccourci est disponible tout de suite. Un raccourci global n'existe que si l'app tourne, c'est une limite de macOS. À activer depuis l'app installée dans `/Applications` (l'option pointe vers l'emplacement de l'app qui l'active).
- Fermer la fenêtre ne quitte pas l'app (le raccourci reste actif). Clic sur l'icône du Dock pour la rouvrir, ⌘Q pour quitter.

### Demande macOS "contourner le sélecteur de fenêtre privée"

macOS (15+) demande périodiquement de confirmer qu'une app peut capturer l'écran directement, en plus de la permission "Enregistrement de l'écran". On ne peut pas l'éviter (seules les apps de bureau à distance ont l'autorisation spéciale). L'app interroge ScreenCaptureKit **dès son lancement** pour que cette demande apparaisse à ce moment-là et pas au début d'un enregistrement.

## Fonctionnement

### 1. Sélection de zone (façon Cmd+Shift+4)

- ⌘⇧8 assombrit tous les écrans et affiche un curseur en croix. ⌘⇧8 à nouveau ou Esc annule. Le voile sombre apparaît en **simple fondu** (0,15 s) : l'animation par défaut de macOS animait tout le rectangle de l'écran. Il disparaît instantanément, pour ne jamais être dans l'enregistrement.
- On **glisse directement sur l'écran** pour tracer la zone, avec ses dimensions en pixels affichées en direct.
- La zone reste ajustable : 8 poignées pour redimensionner, glisser l'intérieur pour déplacer. Taille minimale 10×10.
- **Un simple clic ne fait rien** (il ne sélectionne plus l'écran entier, ce qui bloquait l'ajustement).
- **Bords aimantés** : un bord à moins de 8 pt du bord de l'écran s'y colle, et ce côté est surligné en violet épais.
- **Plein écran** :
  - Bouton bascule "Plein écran" / "Quitter le plein écran" dans le panneau.
  - Coller les quatre bords à la main passe aussi en plein écran (même comportement que le bouton).
  - En quittant le plein écran : retour à la zone précédente, sauf si elle touchait un bord de l'écran ; dans ce cas, zone par défaut centrée sur 60 % de l'écran.
  - En plein écran, glisser n'importe où retrace une nouvelle zone.
- **Panneau toujours visible** : sous la zone, ou en bas de l'écran s'il n'y a pas de zone ou en plein écran. Il contient Plein écran, Micro, Son système, Annuler, Enregistrer (grisé sans zone). Curseur flèche au survol du panneau. Un clic dans un vide du panneau ne fait plus disparaître celui-ci (il commençait un tracé dont le relâchement n'arrivait jamais à la vue de sélection).
- Entrée lance l'enregistrement. Une zone par écran au maximum, une seule active à la fois. La dernière zone est proposée par défaut.

### 2. Enregistrement

- `SCStream` filtre sur l'écran et la zone (`sourceRect`, Retina géré) et exclut toutes les fenêtres de l'app.
- `AVAssetWriter` écrit un `.mov` avec **3 pistes séparées** : vidéo HEVC 60 i/s (HEVC pour supporter le 5K), son système (AAC stéréo), micro (AAC mono). Ordre des pistes audio : son système, puis micro.
- Cadre en pointillés violets autour de la zone et **mini barre** déplaçable : chrono, Pause/Reprendre, Stop. ⌘⇧8 arrête aussi.
- Pause : les horodatages sont décalés, pas de trou dans la vidéo.
- **Déplacer la zone en cours d'enregistrement** :
  - Poignée violette à quatre flèches au-dessus du coin haut gauche du cadre (à l'intérieur si la zone touche le haut de l'écran), masquée en plein écran.
  - Seule la position change (même taille, même écran), via `SCStream.updateConfiguration`, sans coupure. Marche pendant l'enregistrement et en pause.
  - La mini barre suit la zone en gardant sa position relative.
  - Curseur : flèche. La main ouverte au survol clignotait avec la flèche (l'app est en arrière-plan pendant l'enregistrement et macOS remet la flèche à chaque mouvement) ; la propriété privée `SetsCursorInBackground` n'a pas suffi. Choix de l'utilisateur : la flèche si la main n'est pas fiable.
- Fichiers dans `~/Library/Caches/VidSniper/Recordings/`, purgés au lancement au-delà de 24 h.

### 3. Éditeur (s'ouvre automatiquement à la fin)

- S'ouvre à l'arrêt de l'enregistrement, **au premier plan** : l'app est activée dès le clic sur Stop ou le raccourci (macOS refuse une activation trop tardive après l'action de l'utilisateur). La fenêtre principale garde un bouton "Ouvrir l'éditeur" pour le dernier enregistrement, si on a fermé l'éditeur par erreur.
- Lecteur vidéo (`AVPlayerLayer`, sans les contrôles intégrés d'`AVPlayerView` qui interceptent le clavier).
- Barre de contrôles : lecture/pause, temps courant / durée du montage, Couper, Supprimer, Annuler, Rétablir, zoom (−, +, Ajuster). Les boutons ne prennent jamais le focus clavier.
- **Les boutons désactivés sont grisés** (Supprimer sans sélection ou sur le dernier clip, Annuler/Rétablir sans historique, dézoom au minimum).
- Les pastilles ont une icône de largeur fixe (les variantes barrées sont plus larges et faisaient sauter l'UI).
- Timeline :
  - **Colonne de libellés à gauche**, hors de la zone défilante : une cellule par ligne ("Vidéo", pistes audio, "Clics", "Annotations"), icônes alignées dans une colonne de largeur fixe et textes alignés. Les pistes audio et "Clics" sont des **cellules cliquables** (toute la cellule est le bouton) : violette quand l'élément est actif, grise avec icône barrée quand il est coupé, survol marqué. Une piste coupée est aussi grisée sur toute sa ligne dans la timeline.
  - **Niveaux audio automatiques + balance** (remplace les curseurs de volume par piste, à refaire à chaque vidéo) :
    - **Normalisation** : à l'ouverture, chaque piste est analysée (RMS par tranche de 1/50 s). Une piste est **active** si elle dépasse -45 dBFS pendant au moins 1 s au total (0,3 s à 1 s sur une vidéo courte, 3 % de la durée). Le niveau moyen des passages actifs est ramené à **-20 dBFS**, avec un gain plafonné à **+18 dB** (et -30 dB).
    - **Pistes sans son** (micro allumé sans parler, navigateur silencieux) : jamais amplifiées. Dès l'analyse terminée, la piste est **coupée d'office** (cellule grisée, icône barrée) et **ne peut pas être réactivée** (cellule inactive, bulle d'aide "Pas de son détecté sur cette piste"). Elle est donc absente de l'export. Ce n'est pas une modification de l'utilisateur : pas d'étape d'annulation, et l'historique est corrigé pour qu'annuler ne la réactive pas.
    - **Balance** : un **curseur vertical entre les deux lignes de son**, dans sa propre colonne à droite de la colonne de libellés (fond plus clair `Theme.surface`, trait à gauche), qui couvre les deux pistes et masque le trait horizontal qui les sépare. En haut, le son système ressort ; en bas, la voix ressort ; au milieu (repère, aimanté), même niveau perçu. Écart maximal ±20 dB : la piste en retrait est atténuée, l'autre reste au niveau cible. Par défaut : la voix ressort, son système 10 dB plus bas. Double-clic : réglage par défaut. Mémorisée pour toutes les vidéos, hors annuler/rétablir.
    - La balance est grisée (avec la raison en bulle d'aide) si une piste est coupée ou sans son : la piste restante est simplement normalisée.
    - Les lignes de niveau sonore affichent le **niveau final** (après normalisation et balance), de -40 dBFS (vide) à 0 dBFS (pleine hauteur).
    - Technique : `setVolume` d'`AVAudioMix` est limité à 100 %.
      - **Lecture** : le gain passe par un traitement audio maison (`MTAudioProcessingTap`, `AudioGain.swift`) qui multiplie les échantillons et les écrête à ±1, et lit le gain en continu (la balance s'entend en direct, sans reconstruire le mix).
      - **Export** : **pas de `MTAudioProcessingTap`**. AVFoundation plantait au démarrage de la lecture (`AVAssetReaderAudioMixOutput startReading`) quand ces traitements étaient combinés à la composition vidéo Core Image des clics. Les volumes sont divisés par le plus fort pour rester sous 100 % (`setVolume`), puis ce gain global est réappliqué sur le son mixé (Float32), écrêté à ±1. Même résultat, le mix étant linéaire.
  - **Défilement horizontal et zoom** : par défaut, tout le montage tient dans la largeur, sauf s'il devient trop serré (minimum 30 pt/s, on défile alors). Pendant la lecture, la timeline suit la tête de lecture.
    - Trackpad au-dessus de la timeline : **pincer pour zoomer** (le point sous les doigts reste fixe), **glisser verticalement à deux doigts** (ou molette) pour défiler horizontalement. Le glisser horizontal marche aussi. Ces gestes sont interceptés en AppKit (moniteur local), car la ScrollView SwiftUI les garde pour elle.
    - Aussi : boutons −/+ et ⌘+ / ⌘−, où c'est la tête de lecture qui reste fixe.
    - **Ajuster** : fait tenir le montage dans la largeur **et** défile jusqu'à son début, même si l'échelle ne change pas (sinon on pouvait rester dans la marge vide réservée aux parties rognées).
  - **Règle de temps** en haut (graduations adaptées au zoom).
  - **Marges aux extrémités** : avant et après le montage, la timeline réserve assez de place pour rallonger n'importe quel clip rogné, y compris un clip du milieu dont la partie disponible dépasse le début ou la fin de la timeline. On peut ainsi toujours défiler jusqu'à la limite.
  - **Vignettes en tuiles de taille fixe**, tirées d'un cache de la source (une image toutes les 0,5 s, 400 max) : elles restent nettes au zoom, sans étirement ni régénération.
  - Lignes à pastille (pistes audio, clics) : 35 pt et 30 pt de haut, pour garder environ 5 pt de marge autour de la pastille.
  - **Une ligne de niveau sonore par piste** (son système, puis micro), pour repérer où couper. Elles suivent le montage. Lecture seule. Calcul : crête par tranche de 1/50 s, normalisée par piste, en décibels (-40 dB → vide) pour que les sons faibles se voient.
  - Clic ou glisser sur la timeline : déplace la tête de lecture et sélectionne le segment cliqué.
  - Chaque segment a deux poignées de rognage, qui couvrent aussi les lignes de son. Durée minimale 0,1 s.
  - **Limite de rallonge calculée d'après les voisins du moment** (`limit(ofSegment:)`) : un segment peut s'étendre jusqu'à la fin du segment précédent et au début du suivant dans la source, ou jusqu'aux bords de la vidéo. Deux segments ne se chevauchent jamais (pas de passage en double), et **supprimer un segment rend sa partie récupérable** en rallongeant un voisin. Les segments restent toujours dans l'ordre de la source (pas de réordonnancement), ce qui garantit ce calcul.
  - **Rognage en aperçu** : pendant le glisser, le clip garde sa taille et sa position (les autres clips ne bougent pas). Le rognage ne s'applique qu'au relâchement. On peut rogner en plusieurs fois.
    - Raccourcir : la partie retirée est assombrie, la vidéo montre l'image du nouveau bord.
    - Rallonger : toute la source disponible jusqu'à la limite s'affiche en fond, opaque et en gris (vignettes + son + repères des clics sur la ligne "Clics"), par-dessus les clips voisins. La portion sélectionnée en tirant la poignée passe en couleur. Un trait en pointillés marque la limite, et la vidéo montre l'image source du nouveau bord.
    - Pendant un rognage, les autres clips sont assombris.
    - **Défilement automatique** : si la souris approche (40 pt) ou dépasse un bord de la timeline pendant un rognage, la timeline défile dans ce sens, d'autant plus vite que la souris va loin. La poignée reste sous la souris.
- Le montage est une liste de segments de la vidéo source. Pistes audio : gardées ou coupées entièrement.
- Non destructif : une `AVMutableComposition` reconstruite à chaque modification. Annuler / rétablir sur tout l'état (segments + pistes audio).

**Raccourcis clavier** (gérés au niveau de la fenêtre, quel que soit le focus) :

| Touche | Action |
|---|---|
| Espace | Lecture / pause |
| X | Couper à la tête de lecture |
| Suppr / ⌫ | Supprimer le segment sélectionné |
| ← / → | Reculer / avancer d'une image (⇧ pour 1 s) |
| Début / Fin | Aller au début / à la fin |
| ⌘Z / ⌘⇧Z | Annuler / rétablir |
| ⌘+ / ⌘− | Zoomer / dézoomer la timeline |
| ⌘C | Copier la vidéo exportée |
| ⌘S | Enregistrer une copie de la vidéo exportée |

Les lettres sont lues d'après le caractère tapé et non la position de la touche, pour fonctionner en AZERTY.

**Aide** : plus de texte d'aide affiché en permanence. Un petit **"?"** en haut à droite de l'éditeur (au bout de la barre "Annoter") affiche au survol tous les raccourcis, un par ligne, regroupés par catégorie : Lecture, Montage, Annotations, Timeline, Export, Partout (raccourci global, ⌘O).

### Mise en évidence des clics (phase 4)

- **Pendant l'enregistrement** : un moniteur global d'événements souris (pas de permission nécessaire, contrairement au clavier) note chaque clic gauche ou droit fait **dans la zone** : instant dans la vidéo (pauses déduites, rien pendant une pause) et position normalisée dans la zone (qui peut avoir été déplacée). Les clics sur la mini barre de VidSniper ne sont pas comptés.
- **Rendu** : deux bulles superposées, rayon de référence de 22 points d'écran quelle que soit la taille de la zone.
  - Un disque violet translucide cerclé, qui grandit (45 % → 100 % du rayon) et s'efface en 0,5 s.
  - Une onde : un simple contour fin, qui part **0,2 s après** le disque, dure 0,6 s et va plus loin (50 % → 200 % du rayon). On voit d'abord le petit disque, puis la grande onde. Animation complète : 0,8 s. L'onde s'efface dès son départ (opacité (1 - avancement)^1,5, ~35 % à mi-parcours) pour être déjà très transparente à sa taille maximale ; le disque reste bien visible puis s'efface vers la fin (1 - avancement²).
- **Dans l'éditeur**, sur le modèle des pistes audio : une ligne **"Clics"** dans la timeline (absente pour une vidéo importée).
  - Colonne de gauche : cellule "Clics" cliquable pour activer / couper la mise en évidence (grisée s'il n'y a eu aucun clic), avec à droite une petite pastille de couleur (menu, même palette que les annotations).
  - Timeline : un repère (trait + point de la couleur des clics) à chaque clic, à sa place dans le montage ; ligne grisée quand la mise en évidence est coupée. Lecture seule.
  - Réglages mémorisés d'une vidéo à l'autre, hors annuler/rétablir. Les clics suivent le montage (un clic dans une partie coupée disparaît).
- **Aperçu fidèle** : les cercles sont dessinés par une composition vidéo Core Image (`VideoEffects.swift`), la même à la lecture et à l'export. Sans clics, l'export garde le chemin direct, plus rapide.
- Limite : les clics ne sont gardés qu'en mémoire avec l'enregistrement (pas de fichier à côté du `.mov`).

### Annotations (phase 4)

But : mettre un élément en avant simplement, sans outil de dessin complexe.

- **Deux styles**, chacun en rectangle arrondi ou en ellipse :
  - **Cadre** : contour coloré (épaisseur 0,4 % de la largeur de la vidéo), avec une légère ombre pour rester lisible sur tous les fonds.
  - **Projecteur** : l'image est assombrie (60 %) sauf la zone. Pas de couleur. Plusieurs projecteurs visibles en même temps = un seul assombrissement percé de plusieurs zones.
- **Couleurs** : violet, rouge, jaune, vert (palette d'Obsidian), pour les cadres. Les mêmes pastilles servent aux **clics** : petit menu de couleur à côté de la pastille "Clics", appliqué à tous les clics, mémorisé.
- **Un seul élément, plusieurs rendus** : une annotation est une zone + une durée ; le style (cadre / projecteur), la forme (rectangle / ellipse) et la couleur ne changent que son rendu, et se modifient à tout moment.
- **Barre "Annoter"** en haut de la fenêtre, au-dessus de la vidéo (sur laquelle on trace) : outil **Tracer** (icône de stylo), rendu **Cadre / Projecteur**, forme **rectangle / ellipse**, couleurs, supprimer, aide contextuelle. Rendu, forme et couleur s'appliquent à l'annotation sélectionnée, sinon aux prochaines (mémorisés).
- **Créer** : activer "Tracer", glisser sur la vidéo. L'annotation prend le rendu, la forme et la couleur courants, démarre à la tête de lecture et dure 3 s. L'outil se désarme ensuite et l'annotation est sélectionnée.
- Icône de la ligne "Annotations" dans la timeline : un stylo (`pencil.and.scribble`).
- **Modifier** : clic sur une annotation visible pour la sélectionner ; glisser pour la déplacer, coins pour la redimensionner ; ⌫ pour la supprimer ; Esc désarme l'outil puis désélectionne. Une annotation sélectionnée mais pas visible à cet instant est montrée en pointillés.
- **Durée** : ligne "Annotations" dans la timeline, un bloc par annotation (scindé si une coupe tombe au milieu). Glisser le bloc pour le déplacer, ses bords pour changer début / fin (bords de 8 pt, repérés par une petite barre sur le bloc sélectionné ; durée minimale 0,3 s). Clic sur un bloc : la tête de lecture vient sur l'annotation si elle n'y était pas.
  - **Sous-lignes** : la ligne "Annotations" s'agrandit toute seule, les blocs occupent toute la hauteur de leur sous-ligne. Chaque annotation est placée sur la première sous-ligne libre : deux annotations qui se chevauchent dans le temps ne s'empilent jamais. Pendant un glisser, le bloc garde sa sous-ligne.
- **Timeline lisible** : traits horizontaux continus (couleur `Theme.separator`, plus marquée que les bordures) entre la règle, la vidéo, chaque piste audio et chaque sous-ligne d'annotations, sur toute la largeur (colonne de libellés comprise, sans coupure) et par-dessus les blocs. La colonne de libellés a un fond distinct, séparé de la timeline par un trait vertical. Marge de 18 pt sous la timeline, **à l'intérieur du contenu défilant** (une ScrollView horizontale prend la hauteur de son contenu et place sa barre en bas de celui-ci) : la barre de défilement ne recouvre plus la dernière ligne d'annotations.
- Gestes des blocs d'annotation : le déplacement est en priorité normale (`.gesture`), les bords en priorité haute. Avec le déplacement en priorité haute, le geste du bloc parent l'emportait sur ceux des bords : on ne pouvait pas changer la durée.
- **Fondu** de 0,2 s à l'entrée et à la sortie, **en dehors du bloc** : le bloc de la timeline est la période où l'annotation est visible à 100 %, le fondu d'entrée se fait juste avant et celui de sortie juste après. Une annotation posée à la tête de lecture y est donc entièrement visible tout de suite. L'aperçu reste fidèle à l'export (pas d'affichage spécial pendant l'édition).
- **Attachées au contenu** : les plages sont en temps de la source ; couper avant une annotation la décale avec l'image, supprimer le passage la fait disparaître.
- **Annuler / rétablir** : chaque création, modification (un geste = une étape) ou suppression.
- **Rendu** : dans l'éditeur, dessinées en SwiftUI par-dessus la vidéo (fluide pendant le tracé) ; à l'export, dessinées par Core Image (`AnnotationOverlay`) avec les mêmes formes, épaisseurs et couleurs, sous les cercles de clic. Modifier une annotation ne reconstruit pas le montage : seul l'export est relancé (et mis en cache comme le reste).

### 4. Export (onglet Export de l'éditeur)

**Onglets Édition / Export** (phase 8, demande de l'utilisateur : vérifier que la vidéo compressée reste lisible) :
- **Deux grands onglets Édition | Export sur toute la largeur** (⌘1 / ⌘2, touche dessinée sur chaque onglet ; option A choisie par l'utilisateur parmi 3 pistes, pour les mettre en avant), l'onglet affiché teinté de violet, en gras et souligné, l'autre en retrait (2e test : avec le fond clair sur l'onglet affiché, on croyait que c'était l'autre qui était actif). Dessous, une barre avec les outils de l'onglet (annotations, ou Original et zoom), aide des raccourcis à droite. Pas de barre d'export dans l'onglet Édition : tout le partage est dans l'onglet Export (⌘C et ⌘S marchent depuis les deux).
- **Export toujours en direct** : chaque modification relance l'export en arrière-plan, quel que soit l'onglet affiché, pour qu'en arrivant sur Export la vidéo soit en général déjà prête.
- **Deux lecteurs** dans `EditorDocument` : `player` (montage, avec clics et annotations) et `exportPlayer` (MP4 prêt). `activePlayer` est celui qui est affiché ; lecture, pause, déplacements et le suivi de la tête de lecture passent par lui. Changer d'onglet ou appuyer sur "Original" passe la main d'un lecteur à l'autre (`switchPlayer`) : même image, lecture continuée si elle était en cours.
- `ExportModel.onReadyURLChange` : dès qu'un MP4 est prêt (ou ne l'est plus, pendant un nouvel export), il est chargé dans `exportPlayer` à la position courante.
- **Aperçu du MP4** avec une barre de lecture simple, un badge "MP4 · largeur × hauteur", la progression pendant un export.
- **Original** : bouton à maintenir (ou ⌥ maintenu, touche dessinée sur le bouton : retour de l'utilisateur, on ne comprenait pas comment s'en servir) : le montage non compressé s'affiche à la même place et à la même taille que le MP4 (annotations en lecture seule), pour repérer d'un coup d'œil ce que la compression abîme. Relâcher revient au MP4. ⌥ est relâché d'office si la fenêtre perd le focus.
- **Zoom de la vidéo** (retour de l'utilisateur : deux boutons ne suffisaient pas, il veut zoomer librement, au pincement aussi) : − / pourcentage / +, "Ajuster" et "Taille réelle" (100 % = 1 pixel du MP4 = 1 pixel de l'écran, pour juger la lisibilité d'un texte). Boutons et raccourcis par paliers ronds (10, 25, 50, 75, 100, 125, 150, 175, 200, 250, 300, 400, 500, 600, 800 %) : ×1,5 donnait 100, 150, 225, 338 (2e test). Pincement autour du pointeur, le pourcentage suit les doigts (avant : mis à jour seulement à la fin du geste). Changer de définition garde le même cadrage : même point au centre, et le zoom est recalculé pour que la vidéo garde la même taille à l'écran (ex. 300 % en Écran = 150 % en Retina), pour comparer facilement (retour de l'utilisateur). Défilement à deux doigts, ⌘+ / ⌘− / ⌘0 dans l'onglet Export. Vue `ZoomablePreview` : `NSScrollView` avec loupe native, contenu centré tant qu'il est plus petit que la zone, zoom de 10 % à 800 % (jamais sous l'ajustement ni sous 100 %). L'original est montré au même format, donc réduit comme le MP4.
- **Confirmation de copie** (retour de l'utilisateur : on ne voyait pas qu'on avait copié avec ⌘C depuis l'onglet Édition) : le bouton reste "Copier", et un message "Vidéo copiée" (sans rien d'autre, 2e test) apparaît 2 s en haut de la vidéo, dans les deux onglets.
- ⌘1 / ⌘2 lus d'après le code de la touche : en AZERTY, la touche 1 donne "&" (le raccourci ne marchait pas au premier test).
- Raccourcis de montage (X, ⌫, annuler, zoom de la timeline, Esc) actifs seulement dans l'onglet Édition ; lecture (Espace, flèches, Début / Fin) dans les deux.
- En passant sur Export, l'outil Tracer est désarmé et l'annotation désélectionnée.

- **Définition** : **Retina** (tous les pixels capturés) ou **Écran** (taille vue à l'écran, ÷ 2 en Retina, par défaut), avec seulement les dimensions sous chaque choix (le poids n'est affiché que pour la compression, retour de l'utilisateur). Jamais en dessous : sous la taille écran, le texte devient illisible, mieux vaut compresser davantage (décision de l'utilisateur, après comparaison avec Premiere, Resolve, Screen Studio, Cap, Descript, CleanShot, CapCut, Audacity). Sans enregistrement Retina (vidéo importée), la ligne est masquée.
- **Compression** : 5 niveaux nommés, Maximale / Haute / Équilibrée (par défaut) / Légère / Très légère (0,12 / 0,07 / 0,04 / 0,024 / 0,014 bit par pixel et par image, ÷ ~1,7 à chaque niveau). L'utilisateur trouvait l'ancien niveau le plus léger (0,035) pas assez compressé. Réglages mémorisés d'un export à l'autre.
- Au plus **une image complète toutes les 10 s** (au lieu de 2 s ; c'est un maximum, l'encodeur en ajoute de lui-même quand l'image change d'un coup) : même poids, plus de bits pour les passages qui bougent, aucune perte de fidélité. **Débit minimum 200 kb/s** (au lieu de 500, qui rendait les niveaux bas identiques sur les petites zones). 30 i/s et H.264 gardés (fluidité des animations, compatibilité).
- **Choisir la compression** : à la main, dans l'onglet Export : zoom ou "Taille réelle" sur le passage à vérifier, ⌥ maintenu pour comparer avec l'original, et le poids sous chaque bouton (la courbe de qualité a été retirée, voir Idées écartées).
- **Poids de chaque option** sous son nom : pour une taille, avec la qualité choisie, et inversement. Poids réel si la combinaison a déjà été exportée pendant la session (cache), sinon estimation ("≈"), corrigée par le rapport poids réel / estimé du dernier export (l'estimation par le débit surestime souvent les enregistrements d'écran, très statiques).
- Plus de résumé (dimensions, poids estimé puis réel) à côté de la miniature : les dimensions sont sous les définitions et le poids sous chaque niveau de compression (retour de l'utilisateur). L'erreur d'export éventuelle reste affichée sur l'aperçu.
- **Couleurs** : même espace sur toute la chaîne (`VideoColor`) : capture convertie en sRGB par ScreenCaptureKit, enregistrement et MP4 étiquetés primaires / matrice BT.709 + courbe sRGB, composition d'export rendue dans cet espace. Avant : enregistrement sans étiquette, affiché tel quel et étiré sur la gamme de l'écran (plus vif), MP4 étiqueté BT.709 et converti, d'où des couleurs différentes avec ⌥ (retour de l'utilisateur), même en Retina qualité maximale. Les enregistrements faits avant ce changement restent sans étiquette.
- MP4 H.264 (High) + AAC 128 kb/s stéréo, 30 i/s, optimisé pour le streaming. Les pistes audio gardées sont mixées en une seule piste : couper une seule des deux pistes ne change donc pas le poids, et couper les deux ne fait gagner que ~16 Ko/s (le son pèse très peu face à la vidéo).
- Vitesse d'export : les images sont composées directement à la taille d'export (pas en pleine résolution puis réduites), et l'encodage se fait sans images B. Le gain est surtout visible à 75 % et 50 %. Limite du H.264 matériel : 4096 × 2304, la taille est réduite automatiquement au-delà (écrans 5K).
- **Export automatique en arrière-plan** à chaque modification du montage ou des réglages, 0,5 s après la dernière modification. Un nouvel export annule le précédent. Le fichier final est remplacé d'un coup (jamais à moitié écrit).
- **Annulation sûre** : le démarrage, la lecture des échantillons (vidéo et audio) et l'annulation passent tous par une seule file de travail (`ExportJob.queue`). Appeler `cancelReading` depuis le fil principal pendant un `copyNextSampleBuffer` détruisait le lecteur en pleine lecture et faisait planter l'app (par exemple en activant / désactivant les clics pendant un export).
- Le fichier porte le nom de l'enregistrement (`VidSniper 2026-10-31 à 10.12.03.mp4`), c'est celui que voient les destinataires. Il est rangé dans `~/Library/Caches/VidSniper/Exports/<clé>/`, purgé après 24 h comme les enregistrements.
- **Cache des exports** : chaque combinaison montage + taille + qualité + volumes garde son fichier pendant la session. Revenir à un réglage déjà essayé (pour comparer les poids, par exemple) rend la vidéo disponible immédiatement, sans réexporter.
- **Vignette à glisser** (début du montage) : barre de progression pendant l'export, badge "Glisser" quand c'est prêt. On la glisse directement dans Slack, Jira, un mail…
- **Copier** (bouton ou ⌘C) : met le fichier dans le presse-papier comme "Copier" dans le Finder (`NSPasteboard` avec l'URL du fichier). Le bouton affiche "Copiée" pendant 2 s (icônes dans un cadre de taille fixe, largeur et hauteur, pour éviter le saut). Validé dans Slack.
- **Enregistrer…** (bouton ou ⌘S) : `NSSavePanel` pour garder une copie où l'on veut.

## Points à vérifier

- ~~Que le collage dans Slack fonctionne~~ : validé, ainsi que le glisser-déposer.
- ~~Que le gain audio (> 100 %) soit appliqué à l'export~~ : validé.
- Que l'app reste bien sans fenêtre quand elle est lancée à l'ouverture de session (à vérifier depuis l'app installée dans `/Applications`, après avoir coupé puis réactivé l'option depuis celle-ci).

## Idées écartées (décision de l'utilisateur)

- **Courbe de qualité de l'export** (fidélité SSIM de chaque niveau de compression, mesurée en encodant les 5 secondes qui bougent le plus, dans une carte au survol d'une icône). Retirée : plusieurs secondes de calcul à chaque montage dans une app qui doit aller vite, et une moyenne sur toute l'image ne dit pas si un texte reste lisible ; même avec le poids à côté, on ne savait pas quoi choisir. La vérification à la main (taille réelle + ⌥) est plus rapide et plus juste. Ce qui en reste : la correction des couleurs (trouvée en comparant avec ⌥), les cartes flottantes aux couleurs de l'app (aide des raccourcis), les boutons de compression de même largeur, la bordure du panneau en arrière-plan, et le choix "sous la taille écran, mieux vaut compresser que réduire".

- **Garder les clics avec l'enregistrement** (fichier à côté du `.mov`) : non. Les clics ne vivent qu'en mémoire.
- **Historique des derniers enregistrements** dans la fenêtre principale : non, seul le dernier est accessible.
- **Garder le montage à la réouverture / après un plantage** (sauvegarde automatique en JSON + mémoriser la dernière vidéo ouverte) : écarté pour l'instant. Faisable simplement si besoin plus tard : l'état du montage (`EditState`) tient en un seul objet.
