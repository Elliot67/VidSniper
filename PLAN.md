# VidSniper - plan

App macOS pour enregistrer rapidement une zone de l'écran, faire 2-3 retouches et partager la vidéo (Slack, Jira...) sans passer par le Finder.

> Ce document est mis à jour à chaque étape avec les retours de test, pour toujours décrire le comportement réel de l'app.

## Avancement

| # | Contenu | Statut |
|---|---|---|
| 0 | Projet XcodeGen, signature, permissions, fenêtre principale, `Theme.swift` | Fait |
| 1 | Raccourci global, sélecteur de zone, capture 3 pistes, mini barre, déplacement de zone en cours d'enregistrement | Fait |
| 2 | Éditeur : lecture, trim, cuts, pistes audio, raccourcis clavier, annuler, timeline zoomable | Fait |
| 3 | Export : réglages, estimation, glisser, copier, enregistrer | En cours |
| 4 (bonus) | Mise en évidence des clics, rectangle/ellipse sur une plage de temps, remplacement d'une piste audio | À faire |

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

## UI : style Obsidian

- Suit le thème système (clair ou sombre), palette centralisée dans `VidSniper/UI/Theme.swift`.
- Sombre : fond `#1E1E1E`, fond secondaire `#262626`, bordures `#363636`, texte `#DADADA`, texte atténué `#999999`.
- Clair : fond `#FFFFFF`, fond secondaire `#F6F6F6`, bordures `#E0E0E0`, texte `#222222`, texte atténué `#5C5C5C`.
- Accent violet `#8A5CF5`. Coins arrondis 6 px, petites polices, fines bordures, pas de dégradés.

## Fenêtre principale

- Bouton "Nouvel enregistrement" + rappel du raccourci.
- Panneau des permissions :
  - **Enregistrement de l'écran** : obligatoire (point rouge tant qu'il n'est pas accordé).
  - **Micro** : **optionnel** (point gris). Sans autorisation, l'interrupteur Micro est désactivé et l'enregistrement se fait sans piste micro.
- Option **"Lancer à l'ouverture de session"** (`SMAppService`) : l'app démarre sans fenêtre et ⌘⇧8 est disponible tout de suite. Un raccourci global n'existe que si l'app tourne, c'est une limite de macOS.
- Fermer la fenêtre ne quitte pas l'app (le raccourci reste actif). Clic sur l'icône du Dock pour la rouvrir, ⌘Q pour quitter.

### Demande macOS "contourner le sélecteur de fenêtre privée"

macOS (15+) demande périodiquement de confirmer qu'une app peut capturer l'écran directement, en plus de la permission "Enregistrement de l'écran". On ne peut pas l'éviter (seules les apps de bureau à distance ont l'autorisation spéciale). L'app interroge ScreenCaptureKit **dès son lancement** pour que cette demande apparaisse à ce moment-là et pas au début d'un enregistrement.

## Fonctionnement

### 1. Sélection de zone (façon Cmd+Shift+4)

- ⌘⇧8 assombrit tous les écrans et affiche un curseur en croix. ⌘⇧8 à nouveau ou Esc annule.
- On **glisse directement sur l'écran** pour tracer la zone, avec ses dimensions en pixels affichées en direct.
- La zone reste ajustable : 8 poignées pour redimensionner, glisser l'intérieur pour déplacer. Taille minimale 10×10.
- **Un simple clic ne fait rien** (il ne sélectionne plus l'écran entier, ce qui bloquait l'ajustement).
- **Bords aimantés** : un bord à moins de 8 pt du bord de l'écran s'y colle, et ce côté est surligné en violet épais.
- **Plein écran** :
  - Bouton bascule "Plein écran" / "Quitter le plein écran" dans le panneau.
  - Coller les quatre bords à la main passe aussi en plein écran (même comportement que le bouton).
  - En quittant le plein écran : retour à la zone précédente, sauf si elle touchait un bord de l'écran ; dans ce cas, zone par défaut centrée sur 60 % de l'écran.
  - En plein écran, glisser n'importe où retrace une nouvelle zone.
- **Panneau toujours visible** : sous la zone, ou en bas de l'écran s'il n'y a pas de zone ou en plein écran. Il contient Plein écran, Micro, Son système, Annuler, Enregistrer (grisé sans zone). Curseur flèche au survol du panneau.
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
  - Curseur main ouverte dès le survol (tracking area active même app en arrière-plan).
- Fichiers dans `~/Library/Caches/VidSniper/Recordings/`, purgés au lancement au-delà de 24 h.

### 3. Éditeur (s'ouvre automatiquement à la fin)

- S'ouvre à l'arrêt de l'enregistrement, **au premier plan** : l'app est activée dès le clic sur Stop ou le raccourci (macOS refuse une activation trop tardive après l'action de l'utilisateur). La fenêtre principale garde un bouton "Ouvrir l'éditeur" pour le dernier enregistrement, si on a fermé l'éditeur par erreur.
- Lecteur vidéo (`AVPlayerLayer`, sans les contrôles intégrés d'`AVPlayerView` qui interceptent le clavier).
- Barre de contrôles : lecture/pause, temps courant / durée du montage, Couper, Supprimer, Annuler, Rétablir, zoom (−, +, Ajuster). Les boutons ne prennent jamais le focus clavier.
- **Les boutons désactivés sont grisés** (Supprimer sans sélection ou sur le dernier clip, Annuler/Rétablir sans historique, dézoom au minimum).
- Les pastilles ont une icône de largeur fixe (les variantes barrées sont plus larges et faisaient sauter l'UI).
- Timeline :
  - **Colonne de libellés à gauche**, hors de la zone défilante : "Vidéo", puis une pastille par piste audio (Son système, Micro) qui sert aussi à garder ou couper la piste. Une piste coupée est grisée sur toute sa ligne.
  - **Défilement horizontal et zoom** : par défaut, tout le montage tient dans la largeur, sauf s'il devient trop serré (minimum 30 pt/s, on défile alors). Pendant la lecture, la timeline suit la tête de lecture.
    - Trackpad au-dessus de la timeline : **pincer pour zoomer** (le point sous les doigts reste fixe), **glisser verticalement à deux doigts** (ou molette) pour défiler horizontalement. Le glisser horizontal marche aussi. Ces gestes sont interceptés en AppKit (moniteur local), car la ScrollView SwiftUI les garde pour elle.
    - Aussi : boutons −/+ et ⌘+ / ⌘−, où c'est la tête de lecture qui reste fixe.
    - **Ajuster** : fait tenir le montage dans la largeur **et** défile jusqu'à son début, même si l'échelle ne change pas (sinon on pouvait rester dans la marge vide réservée aux parties rognées).
  - **Règle de temps** en haut (graduations adaptées au zoom).
  - **Marges aux extrémités** : avant et après le montage, la timeline réserve assez de place pour rallonger n'importe quel clip rogné, y compris un clip du milieu dont la partie disponible dépasse le début ou la fin de la timeline. On peut ainsi toujours défiler jusqu'à la limite.
  - **Vignettes en tuiles de taille fixe**, tirées d'un cache de la source (une image toutes les 0,5 s, 400 max) : elles restent nettes au zoom, sans étirement ni régénération.
  - **Une ligne de niveau sonore par piste** (son système, puis micro), pour repérer où couper. Elles suivent le montage. Lecture seule. Calcul : crête par tranche de 1/50 s, normalisée par piste, en décibels (-40 dB → vide) pour que les sons faibles se voient.
  - Clic ou glisser sur la timeline : déplace la tête de lecture et sélectionne le segment cliqué.
  - Chaque segment a deux poignées de rognage, qui couvrent aussi les lignes de son. Un segment issu d'une découpe ne peut pas déborder sur la partie voisine (bornes mémorisées à la découpe). Durée minimale 0,1 s.
  - **Rognage en aperçu** : pendant le glisser, le clip garde sa taille et sa position (les autres clips ne bougent pas). Le rognage ne s'applique qu'au relâchement. On peut rogner en plusieurs fois.
    - Raccourcir : la partie retirée est assombrie, la vidéo montre l'image du nouveau bord.
    - Rallonger : toute la source disponible jusqu'à la limite s'affiche en fond, opaque et en gris (vignettes + son), par-dessus les clips voisins. La portion sélectionnée en tirant la poignée passe en couleur. Un trait en pointillés marque la limite, et la vidéo montre l'image source du nouveau bord.
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
| ⌘C | Copier la vidéo exportée (phase 3) |

Les lettres sont lues d'après le caractère tapé et non la position de la touche, pour fonctionner en AZERTY.

### 4. Export (phase 3)

- Dimensions : 100 % / 75 % / 50 %. Qualité : Haute / Moyenne / Légère (débit cible).
- **Poids estimé en direct** (débit × durée).
- MP4 H.264 généré en arrière-plan à chaque modification (debounce). Limite H.264 : 4096 px de large, à réduire automatiquement pour les écrans 5K.
- **Glisser** depuis une vignette, **Copier** (⌘C, `NSPasteboard` avec l'URL du fichier, comme le Finder), **Enregistrer…** (`NSSavePanel`).

## Points à vérifier

- Que le collage dans Slack fonctionne (sinon, glisser-déposer).
- Que l'app reste bien sans fenêtre quand elle est lancée à l'ouverture de session.
- Plus tard : installer l'app dans `/Applications` (le lancement à l'ouverture de session pointe vers l'emplacement actuel de l'app).
