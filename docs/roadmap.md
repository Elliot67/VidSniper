# Roadmap

## Progress

| # | Content | Status |
|---|---|---|
| 0 | XcodeGen project, signing, permissions, main window, `Theme.swift` | Done |
| 1 | Global shortcut, area selector, 3-track capture, mini bar, moving the area while recording | Done |
| 2 | Editor: playback, trim, cuts, audio tracks, keyboard shortcuts, undo, zoomable timeline | Done |
| 3 | Export: settings, size estimate, drag, copy, save, cache; automatic audio levels + balance | Done |
| 4 (bonus) | Click highlighting (two-bubble animation, color, "Clicks" row in the timeline) | Done |
| 4 (bonus) | Install in `/Applications`, global shortcut setting, app icon | Done |
| 4 (bonus) | Annotations (frame / spotlight, rectangle / ellipse, colors) over a time range, reworked timeline, shortcuts help | Done |
| 5 | **Import an existing video file** to edit and export it with the same editor (basic version, no clicks) | Done |
| 6 | Polish: recover a deleted part by extending a neighbour, clicks in the extend preview, new home screen with the logo | Done |
| 7 | English / French translations (String Catalogs) | Done, to test |
| 8 | Edit / Export tabs: MP4 preview, Original button, zoom, size of each option, copy confirmation | Done |
| 9 | Export: Retina / Screen resolution, 5 compression levels, keyframe every 10 s at most, 200 kb/s floor | Done |
| 10 | ~~Quality curve~~ (fidelity of each level, measured on the passages that move the most) | Dropped: too slow, doesn't tell whether text stays readable |
| 11 | Area outline without the appearing animation (it ended up at the start of every video) | Done |
| 12 | Automated tests: unit, real export, translations (`./scripts/test.sh`, run before each release) | Done (28 tests, ~2 s) |
| - | ~~Replace an audio track with a file~~ | Dropped (not needed) |

## To check

- That the app stays windowless when launched at login (check from the app installed in `/Applications`, after turning the option off and on again from it).
- The English version of the app: `pkill -x VidSniper; sleep 1; open build/Debug/VidSniper.app --args -AppleLanguages '(en)'`.

## Rejected ideas

- **Export quality curve** (SSIM fidelity of each compression level, measured by encoding the 5 seconds that move the most, in a card shown when hovering an icon). Removed: several seconds of computing for every edit in an app that has to be fast, and an average over the whole image doesn't tell whether text stays readable; even with the size next to it, it didn't help choose. Checking by hand (actual size + ⌥) is faster and more accurate. What remains from it: the color fix (found by comparing with ⌥), the floating cards in the app's style (shortcuts help), the equal-width compression buttons, and the rule "below screen size, compress more rather than shrink".
- **Keeping clicks with the recording** (a file next to the `.mov`): no. Clicks only live in memory.
- **History of recent recordings** in the main window: no, only the last one can be reopened.
- **Keeping the edit after reopening or a crash** (JSON autosave + remembering the last opened video): set aside for now. Easy to add later if needed: the edit state (`EditState`) is a single value.
- **A lower bitrate floor** so that "Very Light" differs from "Light" on small areas: left as is for now.
