# Editor

## Window

- Opens when recording stops, **in front**: the app is activated as soon as Stop or the shortcut is pressed (macOS refuses an activation that comes too late after the user's action). The main window keeps an "Open" button for the last video, in case the editor was closed by mistake.
- **Two large tabs, Edit | Export**, across the whole width (⌘1 / ⌘2, key drawn on each tab). The current tab is tinted purple, bold and underlined; the other one is dimmed. Below, a bar with the tab's tools (annotations, or Original and zoom for [Export](export.md)) and the shortcuts help on the right. Sharing lives only in the Export tab, but ⌘C and ⌘S work from both.
- Video player (`AVPlayerLayer`, without the built-in `AVPlayerView` controls that intercept the keyboard).
- Controls bar: play/pause, current time / edit duration, Split, Delete, Undo, Redo, zoom (−, +, Fit). Buttons never take keyboard focus.
- **Disabled buttons are greyed out** (Delete with no selection or on the last clip, Undo/Redo with no history, zoom out at the minimum).
- Chips have a fixed-width icon (the crossed-out variants are wider and made the UI jump).

## Timeline

- **Label column on the left**, outside the scrolling area: one cell per row ("Video", audio tracks, "Clicks", "Annotations"), icons aligned in a fixed-width column and texts aligned. Audio tracks and "Clicks" are **clickable cells** (the whole cell is the button): purple when the item is on, grey with a crossed-out icon when off, hover highlighted. A muted track is also greyed out across its whole row.
- **Horizontal scrolling and zoom**: by default the whole edit fits the width, unless it gets too tight (minimum 30 pt/s, then it scrolls). During playback, the timeline follows the playhead.
  - Trackpad over the timeline: **pinch to zoom** (the point under the fingers stays fixed), **two-finger vertical drag** (or mouse wheel) to scroll horizontally. Horizontal drag works too. These gestures are intercepted in AppKit (local monitor), because the SwiftUI ScrollView keeps them for itself.
  - Also: −/+ buttons and ⌘+ / ⌘−, where the playhead stays fixed.
  - **Fit**: fits the edit to the width **and** scrolls to its start, even if the scale doesn't change (otherwise you could stay in the empty margin reserved for trimmed parts).
- **Time ruler** at the top (ticks adapted to the zoom).
- **Margins at both ends**: before and after the edit, the timeline keeps enough room to extend any trimmed clip, including a middle clip whose available part goes beyond the start or end of the timeline. You can always scroll to the limit.
- **Fixed-size thumbnail tiles**, taken from a cache of the source (one frame every 0.5 s, 400 max): they stay sharp when zooming, with no stretching or regeneration.
- Chip rows (audio tracks, clicks): 35 pt and 30 pt high, to keep about 5 pt of margin around the chip.
- **One audio level row per track** (system audio, then microphone), to spot where to cut. They follow the edit. Read-only. Peak per 1/50 s slice, in decibels (-40 dB → empty) so quiet sounds are visible.
- **Readable timeline**: continuous horizontal lines (`Theme.separator`, stronger than borders) between the ruler, the video, each audio track and each annotation sub-row, across the whole width and above the blocks. The label column has its own background, separated by a vertical line. 18 pt margin below the timeline, **inside the scrolling content**, so the scroll bar doesn't cover the last annotation row.
- Click or drag on the timeline: moves the playhead and selects the clicked segment.

## Cuts and trimming

- The edit is a list of segments of the source video. Audio tracks are kept or muted entirely.
- Non-destructive: an `AVMutableComposition` rebuilt on every change. Undo / redo covers the whole state (segments, audio tracks, annotations).
- Each segment has two trim handles, which also cover the audio rows. Minimum duration 0.1 s.
- **Extension limit computed from the current neighbours** (`limit(ofSegment:)`): a segment can extend up to the end of the previous segment and the start of the next one in the source, or to the edges of the video. Two segments never overlap (no part played twice), and **deleting a segment makes its part recoverable** by extending a neighbour. Segments always stay in source order (no reordering), which keeps this computation valid.
- **Trim preview**: while dragging, the clip keeps its size and position (other clips don't move). The trim only applies on release. You can trim in several steps.
  - Shortening: the removed part is darkened, the video shows the frame at the new edge.
  - Extending: all the source available up to the limit shows in the background, opaque and grey (thumbnails + audio + click marks on the "Clicks" row), above the neighbouring clips. The part selected by dragging the handle turns to color. A dashed line marks the limit, and the video shows the source frame at the new edge.
  - Other clips are darkened while trimming.
  - **Auto-scroll**: when the mouse gets close (40 pt) to or past an edge of the timeline while trimming, the timeline scrolls that way, faster the further the mouse goes. The handle stays under the mouse.

## Audio levels and balance

Replaces per-track volume sliders, which had to be set for every video.

- **Normalization**: on opening, each track is analyzed (RMS per 1/50 s slice). A track is **active** if it goes above -45 dBFS for at least 1 s in total (0.3 to 1 s on a short video, 3 % of the duration). The average level of the active parts is brought to **-20 dBFS**, with a gain capped at **+18 dB** (and -30 dB).
- **Silent tracks** (microphone on without speaking, silent browser): never amplified. As soon as the analysis ends, the track is **muted automatically** (greyed cell, crossed-out icon) and **can't be turned back on** (inactive cell, "No sound detected on this track" tooltip). It is therefore left out of the export. This isn't a user edit: no undo step, and the history is fixed so that undo doesn't turn it back on.
- **Balance**: a **vertical slider between the two audio rows**, in its own column right of the label column (lighter `Theme.surface` background, line on the left), covering both tracks and hiding the line between them. At the top, system audio stands out; at the bottom, the voice stands out; in the middle (marked, snapping), same perceived level. Maximum gap ±20 dB: the track in the background is lowered, the other stays at the target level. Default: the voice stands out, system audio 10 dB lower. Double-click: default setting. Remembered for all videos, outside undo/redo.
- The balance is greyed out (with the reason in a tooltip) when a track is muted or silent: the remaining track is simply normalized.
- The audio level rows show the **final level** (after normalization and balance), from -40 dBFS (empty) to 0 dBFS (full height).
- The analysis reads the file on its own dispatch queue: reading blocks on every sample, and several analyses at once (several videos opened) used to take up all the Swift task threads and freeze the app.
- `AVAudioMix.setVolume` is capped at 100 %, so:
  - **Playback**: the gain goes through a custom audio processing tap (`MTAudioProcessingTap`, `AudioGain.swift`) that multiplies samples, clips them at ±1, and reads the gain continuously (the balance is heard live, without rebuilding the mix).
  - **Export**: **no `MTAudioProcessingTap`**. AVFoundation crashed when starting to read (`AVAssetReaderAudioMixOutput startReading`) when these taps were combined with the Core Image video composition of the clicks. Volumes are divided by the loudest one to stay under 100 % (`setVolume`), then that global gain is applied again to the mixed audio (Float32), clipped at ±1. Same result, since the mix is linear.

## Click highlighting

- **While recording**: a global mouse event monitor (no permission needed, unlike the keyboard) notes every left or right click **inside the area**: time in the video (pauses removed, nothing during a pause) and normalized position in the area (which may have moved). Clicks on VidSniper's mini bar are ignored.
- **Rendering**: two overlapping bubbles, reference radius of 22 screen points whatever the area size.
  - A translucent purple disc with a ring, growing (45 % → 100 % of the radius) and fading out over 0.5 s.
  - A wave: a thin outline that starts **0.2 s after** the disc, lasts 0.6 s and goes further (50 % → 200 % of the radius). You first see the small disc, then the large wave. Full animation: 0.8 s. The wave fades from the start (opacity (1 - progress)^1.5, ~35 % halfway) so it is already very transparent at its largest; the disc stays clearly visible, then fades near the end (1 - progress²).
- **In the editor**, like the audio tracks: a **"Clicks"** row in the timeline (absent for an imported video).
  - Left column: clickable "Clicks" cell to turn highlighting on or off (greyed out if there were no clicks), with a small color chip on the right (menu, same palette as annotations).
  - Timeline: a mark (line + dot in the click color) for each click, at its place in the edit; greyed row when highlighting is off. Read-only.
  - Settings remembered from one video to the next, outside undo/redo. Clicks follow the edit (a click in a removed part disappears).
- **Accurate preview**: the circles are drawn by a Core Image video composition (`VideoEffects.swift`), the same for playback and export. Without clicks, the export keeps the faster direct path.
- Limit: clicks only live in memory with the recording (no file next to the `.mov`).

## Annotations

Goal: highlight something simply, without a complex drawing tool.

- **Two styles**, each as a rounded rectangle or an ellipse:
  - **Frame**: colored outline (thickness 0.4 % of the video width), with a light shadow to stay readable on any background.
  - **Spotlight**: the image is darkened (60 %) except for the area. No color. Several visible spotlights = a single darkening with several holes.
- **Colors**: purple, red, yellow, green (Obsidian palette), for frames. The same chips are used for **clicks**: small color menu next to the "Clicks" chip, applied to all clicks, remembered.
- **One element, several renderings**: an annotation is an area + a duration; the style (frame / spotlight), shape (rectangle / ellipse) and color only change how it is drawn, and can be changed at any time.
- **"Annotate" bar** at the top of the Edit tab, above the video (where you draw): **Draw** tool (pen icon), **Frame / Spotlight** style, **rectangle / ellipse** shape, colors, delete, contextual help. Style, shape and color apply to the selected annotation, otherwise to the next ones (remembered).
- **Create**: turn on "Draw", drag over the video. The annotation takes the current style, shape and color, starts at the playhead and lasts 3 s. The tool then turns off and the annotation is selected.
- **Edit**: click a visible annotation to select it; drag to move, corners to resize; ⌫ to delete; Esc turns off the tool, then deselects. A selected annotation that isn't visible at that moment is shown dashed.
- **Duration**: "Annotations" row in the timeline (pen icon `pencil.and.scribble`), one block per annotation (split if a cut falls in the middle). Drag the block to move it, its edges to change start / end (8 pt edges, shown by a small bar on the selected block; minimum duration 0.3 s). Clicking a block moves the playhead onto the annotation if it wasn't there.
  - **Sub-rows**: the "Annotations" row grows by itself and blocks fill the height of their sub-row. Each annotation goes on the first free sub-row: two annotations overlapping in time never stack. While dragging, a block keeps its sub-row.
  - Block gestures: moving has normal priority (`.gesture`), edges have high priority. With moving at high priority, the parent block's gesture won over the edges and the duration couldn't be changed.
- **Fade** of 0.2 s in and out, **outside the block**: the timeline block is the period when the annotation is fully visible; the fade-in happens just before and the fade-out just after. An annotation placed at the playhead is therefore fully visible right away. The preview stays faithful to the export (no special display while editing).
- **Attached to the content**: ranges are in source time; cutting before an annotation shifts it with the image, deleting the passage removes it.
- **Undo / redo**: every creation, change (one gesture = one step) or deletion.
- **Rendering**: in the editor, drawn in SwiftUI over the video (smooth while drawing); in the export, drawn by Core Image (`AnnotationOverlay`) with the same shapes, thicknesses and colors, below the click circles. Changing an annotation doesn't rebuild the edit: only the export runs again (and is cached like the rest).

## Keyboard shortcuts

Handled at the window level, whatever has focus.

| Key | Action |
|---|---|
| Space | Play / pause |
| ← / → | Previous / next frame (⇧ for 1 s) |
| Home / End | Go to start / end |
| X | Split at the playhead (Edit tab) |
| Delete / ⌫ | Delete the selected segment or annotation (Edit tab) |
| Esc | Stop drawing, then deselect (Edit tab) |
| ⌘Z / ⇧⌘Z | Undo / redo (Edit tab) |
| ⌘+ / ⌘− | Zoom the timeline (Edit tab) or the video (Export tab) |
| ⌘0 | Fit the video (Export tab) |
| Hold ⌥ | Show the original (Export tab) |
| ⌘1 / ⌘2 | Edit / Export tab |
| ⌘C | Copy the exported video |
| ⌘S | Save a copy of the exported video |

Letters are read from the typed character, not the key position, so they work in AZERTY. ⌘1 / ⌘2 are read from the key code instead: in AZERTY, the 1 key types "&".

**Help**: a small **"?"** at the top right of the editor shows every shortcut on hover, one per line, grouped by category: Playback, Editing, Annotations, Timeline, Export, Anywhere (global shortcut, ⌘O). It opens in a floating card in the app's style.

## Importing a video

- **Open**: "Import Video…" in the main window, **⌘O** (File menu), **drop the file on the main window** (dashed purple frame on hover), **drop it on the Dock icon**, or **"Open With → VidSniper"** in the Finder (`CFBundleDocumentTypes`: `public.movie`, Viewer role, Alternate rank so it doesn't become the default app). A video received during launch opens once the app is ready.
- **Formats**: anything AVFoundation reads (`.mov`, `.mp4`, `.m4v`; H.264, HEVC, ProRes…). An unreadable file or one without a video track is refused with a message in the main window.
- **Audio tracks**: the editor keeps its two slots. 1 track → "Audio" row; 2 tracks or more → "Audio 1" and "Audio 2" with the balance between them; further tracks (rare) are ignored. Generic icons (waveform). Alternate tracks (languages of a film) aren't told apart and would be mixed: that case isn't targeted. Automatic normalization and silent track guards work as for a recording.
- **Rotation**: sizes (aspect ratio, thumbnails, export size) take the track rotation into account (portrait phone video).
- **Original file never touched**: read in place, never copied, changed or purged (the purge only targets `~/Library/Caches/VidSniper`). The exported MP4 takes the name of the original file.
- **No clicks**: the "Clicks" row is hidden for an imported video. Annotations work as for a recording.
- The main window keeps the last opened video ("Imported video + audio 1 + audio 2") to reopen the editor.
