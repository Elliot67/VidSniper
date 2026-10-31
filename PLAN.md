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
| 4 (bonus) | Mise en évidence des clics | Fait (animation à valider) |
| 4 (bonus) | Installation dans `/Applications`, vérification du lancement à l'ouverture de session, réglage du raccourci global, icône de l'app | À faire (prochaine étape) |
| 4 (bonus) | Rectangle/ellipse sur une plage de temps, remplacement d'une piste audio | À faire |
| 5 (plus tard, à la fin) | **Importer un fichier vidéo** existant pour l'éditer et l'exporter avec le même éditeur | À faire |

### Notes pour l'import de vidéo (phase 5)

- Ouvrir un fichier (bouton dans la fenêtre principale, glisser-déposer sur l'icône du Dock ou sur la fenêtre, ⌘O).
- L'éditeur suppose aujourd'hui un `.mov` VidSniper : pistes audio dans l'ordre son système puis micro, une piste vidéo. Pour un fichier importé : pistes audio quelconques (0, 1 ou plusieurs), libellés génériques ("Audio 1", "Audio 2"…), éventuelle rotation (`preferredTransform`), fréquence d'images variable.
- Le fichier importé ne doit jamais être modifié ni supprimé par la purge des 24 h (seul l'export va dans le cache).

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
  - **Niveaux audio automatiques + balance** (remplace les curseurs de volume par piste, à refaire à chaque vidéo) :
    - **Normalisation** : à l'ouverture, chaque piste est analysée (RMS par tranche de 1/50 s). Une piste est **active** si elle dépasse -45 dBFS pendant au moins 1 s au total (0,3 s à 1 s sur une vidéo courte, 3 % de la durée). Le niveau moyen des passages actifs est ramené à **-20 dBFS**, avec un gain plafonné à **+18 dB** (et -30 dB).
    - **Pistes sans son** (micro allumé sans parler, navigateur silencieux) : jamais amplifiées ni touchées, pour ne pas faire remonter le souffle. La pastille l'indique dans sa bulle d'aide ("Pas de son détecté sur le micro").
    - **Balance** : un **curseur vertical entre les deux lignes de son**, dans la colonne de gauche. En haut, le son système ressort ; en bas, la voix ressort ; au milieu (repère, aimanté), même niveau perçu. Écart maximal ±20 dB : la piste en retrait est atténuée, l'autre reste au niveau cible. Par défaut : la voix ressort, son système 10 dB plus bas. Double-clic : réglage par défaut. Mémorisée pour toutes les vidéos, hors annuler/rétablir.
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
| ⌘C | Copier la vidéo exportée |
| ⌘S | Enregistrer une copie de la vidéo exportée |

Les lettres sont lues d'après le caractère tapé et non la position de la touche, pour fonctionner en AZERTY.

### Mise en évidence des clics (phase 4)

- **Pendant l'enregistrement** : un moniteur global d'événements souris (pas de permission nécessaire, contrairement au clavier) note chaque clic gauche ou droit fait **dans la zone** : instant dans la vidéo (pauses déduites, rien pendant une pause) et position normalisée dans la zone (qui peut avoir été déplacée). Les clics sur la mini barre de VidSniper ne sont pas comptés.
- **Rendu** : deux bulles superposées, rayon de référence de 22 points d'écran quelle que soit la taille de la zone.
  - Un disque violet translucide cerclé, qui grandit (45 % → 100 % du rayon) et s'efface en 0,5 s.
  - Une onde : un simple contour fin, qui part **0,2 s après** le disque, dure 0,6 s et va plus loin (50 % → 200 % du rayon). On voit d'abord le petit disque, puis la grande onde. Animation complète : 0,8 s. L'onde s'efface dès son départ (opacité (1 - avancement)^1,5, ~35 % à mi-parcours) pour être déjà très transparente à sa taille maximale ; le disque reste bien visible puis s'efface vers la fin (1 - avancement²).
- **Dans l'éditeur** : pastille "Clics" dans la barre de contrôles (grisée s'il n'y a eu aucun clic). Réglage mémorisé d'une vidéo à l'autre, hors annuler/rétablir. Les clics suivent le montage (un clic dans une partie coupée disparaît).
- **Aperçu fidèle** : les cercles sont dessinés par une composition vidéo Core Image (`VideoEffects.swift`), la même à la lecture et à l'export. Sans clics, l'export garde le chemin direct, plus rapide.
- Limite : les clics ne sont gardés qu'en mémoire avec l'enregistrement (pas de fichier à côté du `.mov`).

### 4. Export (panneau en bas de l'éditeur)

- **Taille** : 100 % / 75 % / 50 %. **Qualité** : Haute / Moyenne / Légère (0,10 / 0,06 / 0,035 bit par pixel et par image). Réglages mémorisés d'un export à l'autre.
- Résumé : dimensions finales (ex. "1920 × 1080 · MP4"), puis **"Estimation : ≈ X Mo"** pendant l'export (débit × durée), remplacé par le **poids réel** une fois le fichier prêt.
- MP4 H.264 (High) + AAC 128 kb/s stéréo, 30 i/s, optimisé pour le streaming. Les pistes audio gardées sont mixées en une seule piste : couper une seule des deux pistes ne change donc pas le poids, et couper les deux ne fait gagner que ~16 Ko/s (le son pèse très peu face à la vidéo).
- Vitesse d'export : les images sont composées directement à la taille d'export (pas en pleine résolution puis réduites), et l'encodage se fait sans images B. Le gain est surtout visible à 75 % et 50 %. Limite du H.264 matériel : 4096 × 2304, la taille est réduite automatiquement au-delà (écrans 5K).
- **Export automatique en arrière-plan** à chaque modification du montage ou des réglages, 0,5 s après la dernière modification. Un nouvel export annule le précédent. Le fichier final est remplacé d'un coup (jamais à moitié écrit).
- Le fichier porte le nom de l'enregistrement (`VidSniper 2026-10-31 à 10.12.03.mp4`), c'est celui que voient les destinataires. Il est rangé dans `~/Library/Caches/VidSniper/Exports/<clé>/`, purgé après 24 h comme les enregistrements.
- **Cache des exports** : chaque combinaison montage + taille + qualité + volumes garde son fichier pendant la session. Revenir à un réglage déjà essayé (pour comparer les poids, par exemple) rend la vidéo disponible immédiatement, sans réexporter.
- **Vignette à glisser** (début du montage) : barre de progression pendant l'export, badge "Glisser" quand c'est prêt. On la glisse directement dans Slack, Jira, un mail…
- **Copier** (bouton ou ⌘C) : met le fichier dans le presse-papier comme "Copier" dans le Finder (`NSPasteboard` avec l'URL du fichier). Le bouton affiche "Copiée" pendant 2 s (icônes dans un cadre de taille fixe, largeur et hauteur, pour éviter le saut). Validé dans Slack.
- **Enregistrer…** (bouton ou ⌘S) : `NSSavePanel` pour garder une copie où l'on veut.

## Points à vérifier

- ~~Que le collage dans Slack fonctionne~~ : validé, ainsi que le glisser-déposer.
- ~~Que le gain audio (> 100 %) soit appliqué à l'export~~ : validé.
- Que l'app reste bien sans fenêtre quand elle est lancée à l'ouverture de session.
- Plus tard : installer l'app dans `/Applications` (le lancement à l'ouverture de session pointe vers l'emplacement actuel de l'app).
