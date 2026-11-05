# Export

Everything about the MP4 lives in the editor's **Export tab**, to check that the compressed video stays readable before sharing it.

## Live export

- **Always up to date**: every change to the edit or the settings starts a new export in the background, 0.5 s after the last change, whatever tab is shown. When you reach the Export tab, the video is usually ready. A new export cancels the previous one, and the final file is replaced in one go (never half written).
- **Safe cancelling**: starting, reading samples (video and audio) and cancelling all go through a single work queue (`ExportJob.queue`). Calling `cancelReading` from the main thread during a `copyNextSampleBuffer` destroyed the reader mid-read and crashed the app (for example when toggling clicks during an export).
- Once the editor is closed, no export starts anymore (the audio analysis, sometimes finishing after closing, used to start one that nobody cancelled).
- **Cache**: each combination of edit + resolution + compression + volumes keeps its file during the session. Going back to a setting already tried (to compare sizes, for example) makes the video available immediately, without exporting again.
- Files are named after the recording (`VidSniper 2026-10-31 at 10.12.03.mp4`), which is what recipients see. They are stored in `~/Library/Caches/VidSniper/Exports/<key>/` and purged after 24 h, like recordings.

## Preview

- **Two players** in `EditorDocument`: `player` (the edit, with clicks and annotations) and `exportPlayer` (the finished MP4). `activePlayer` is the one shown; play, pause, seeking and playhead tracking go through it. Switching tabs or holding "Original" hands over from one player to the other (`switchPlayer`): same frame, playback continues if it was running.
- `ExportModel.onReadyURLChange`: as soon as an MP4 is ready (or no longer is, during a new export), it is loaded into `exportPlayer` at the current position.
- **MP4 preview** with a simple playback bar, an "MP4 · width × height" badge, and the progress during an export. Export errors show on the preview.
- **Original**: button to hold (or hold ⌥, key drawn on the button): the uncompressed edit shows at the same place and size as the MP4 (annotations read-only), to spot at a glance what compression damages. Releasing goes back to the MP4. ⌥ is released automatically if the window loses focus.
- **Zoom**: − / percentage / +, "Fit" and "Actual Size" (100 % = 1 MP4 pixel = 1 screen pixel, to judge whether text is readable).
  - Buttons and shortcuts use round steps (10, 25, 50, 75, 100, 125, 150, 175, 200, 250, 300, 400, 500, 600, 800 %).
  - Pinch around the pointer, with the percentage following the fingers; two-finger scrolling; ⌘+ / ⌘− / ⌘0.
  - Changing the resolution keeps the same framing: same point in the center, and the zoom is recomputed so the video keeps the same size on screen (e.g. 300 % in Screen = 150 % in Retina), for easy comparison.
  - `ZoomablePreview` view: `NSScrollView` with native magnification, content centered while smaller than the area, zoom from 10 % to 800 % (never below fit or below 100 %). The original is shown in the same format, so scaled like the MP4.
- Editing shortcuts (X, ⌫, undo, timeline zoom, Esc) only work in the Edit tab; playback (Space, arrows, Home / End) works in both. Switching to Export turns off the Draw tool and deselects the annotation.

## Settings

- **Resolution**: **Retina** (all captured pixels) or **Screen** (size as seen on screen, ÷ 2 on Retina, default), with only the dimensions under each choice. Never below: under screen size, text becomes unreadable, so it's better to compress more. The row is hidden for a video without Retina pixels (imported video).
- **Compression**: 5 named levels, Maximum / High / Balanced (default) / Light / Very Light (0.12 / 0.07 / 0.04 / 0.024 / 0.014 bits per pixel per frame, ÷ ~1.7 at each level). All 5 buttons have the same width. Settings remembered from one export to the next.
- **Size of each level** under its name: real size if that combination was already exported during the session (cache), otherwise an estimate ("≈"), corrected by the real / estimated ratio of the last export.
- **Choosing the compression** is done by eye: zoom or "Actual Size" on the passage to check, hold ⌥ to compare with the original, and read the size under each button.

## Encoding

- MP4 H.264 (High) + AAC 128 kb/s stereo, **30 fps**, optimized for streaming. The kept audio tracks are mixed into a single track: muting just one of the two doesn't change the size, and muting both only saves ~16 KB/s (audio weighs very little next to the video).
- The frame rate is forced to 30 fps (`sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid`): Apple's composition constructors otherwise follow the source track timing (60 fps, variable) and ignore `frameDuration`.
- At most **one full frame (keyframe) every 10 s**: it's a maximum, the encoder adds one by itself when the image changes suddenly. Same size, more bits for the moving parts, no loss of fidelity.
- **Minimum bitrate 200 kb/s**. On a small area (under ~870 × 550), Light and Very Light both hit this floor and give the same file.
- Frames are composed directly at the export size (not at full resolution then scaled down), and encoded without B-frames, for speed. Hardware H.264 limit: 4096 × 2304; above that (5K screens), the size is reduced automatically.

## Colors

The same color space across the whole chain (`VideoColor`): the capture is converted to sRGB by ScreenCaptureKit, the recording and the MP4 are tagged with BT.709 primaries / matrix and the sRGB transfer curve, and the export composition is rendered in that space. Before this, recordings had no color tag and were displayed as is, stretched over the display's gamut (more vivid), while the MP4 was tagged BT.709 and converted: colors differed when comparing with ⌥. Recordings made before this change remain untagged.

## Sharing

- **Thumbnail to drag** (start of the edit): progress bar during the export, "Drag" badge when ready. Drag it straight into Slack, Jira, an email…
- **Copy** (button or ⌘C): puts the file on the clipboard like "Copy" in the Finder (`NSPasteboard` with the file URL). A "Video copied" message shows for 2 s at the top of the video, in both tabs. Works in Slack.
- **Save…** (button or ⌘S): `NSSavePanel` to keep a copy anywhere.
- The Copy and Save buttons share the width of the longest label (which depends on the language), and the same height, font and icon position.
