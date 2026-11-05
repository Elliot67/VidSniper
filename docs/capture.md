# Capture

## Selecting an area (like ⇧⌘4)

- ⇧⌘8 dims every screen and shows a crosshair cursor. ⇧⌘8 again or Esc cancels. The dark overlay appears with a **simple fade** (0.15 s): the default macOS animation animated the whole screen rectangle. It disappears instantly, so it never ends up in the recording.
- **Drag directly on the screen** to draw the area, with its size in pixels shown live.
- The area stays adjustable: 8 handles to resize, drag inside to move. Minimum size 10 × 10.
- **A single click does nothing** (it used to select the whole screen, which got in the way of adjusting).
- **Snapping edges**: an edge closer than 8 pt to the screen edge sticks to it, and that side is highlighted with a thick purple line.
- **Full screen**:
  - "Full Screen" / "Exit Full Screen" toggle in the panel.
  - Snapping all four edges by hand also switches to full screen (same behavior as the button).
  - Leaving full screen goes back to the previous area, unless it touched a screen edge; then a default area centered on 60 % of the screen is used.
  - In full screen, dragging anywhere draws a new area.
- **Panel always visible**: below the area, or at the bottom of the screen when there is no area or in full screen. It holds Full Screen, Microphone, System Audio, Cancel, Record (greyed out without an area). Arrow cursor when hovering the panel. Clicking an empty part of the panel doesn't start a new area (it used to hide the panel for good).
- Return starts recording. At most one area per screen, only one active at a time. The last area is offered by default.

## Recording

- `SCStream` filters on the screen and the area (`sourceRect`, Retina handled) and excludes every window of the app.
- `AVAssetWriter` writes a `.mov` with **3 separate tracks**: HEVC video at 60 fps (HEVC to support 5K), system audio (stereo AAC), microphone (mono AAC). Audio track order: system audio, then microphone.
- **Colors**: ScreenCaptureKit converts the capture to sRGB, and the file is tagged BT.709 primaries / matrix with the sRGB transfer curve (see [Export](export.md#colors)).
- Dashed purple outline around the area and a movable **mini bar**: timer, Pause/Resume, Stop. ⇧⌘8 also stops.
- Pause: timestamps are shifted, no gap in the video.
- **Moving the area while recording**:
  - Purple four-arrow handle above the top-left corner of the outline (inside if the area touches the top of the screen), hidden in full screen.
  - Only the position changes (same size, same screen), through `SCStream.updateConfiguration`, without interruption. Works while recording and while paused.
  - The mini bar follows the area and keeps its relative position.
  - Arrow cursor on the handle: an open hand flickered with the arrow (the app is in the background while recording, and macOS resets the cursor on every move).
- **Outline, handle and mini bar appear instantly** (`animationBehavior = .none`): the macOS opening animation (slight zoom, borders sliding into the frame) is drawn by the system, outside the filter that excludes the app's windows, and showed at the very start of every video.
- Files go to `~/Library/Caches/VidSniper/Recordings/` and are purged at launch after 24 h.
