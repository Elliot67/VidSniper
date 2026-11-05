# Main window

- **Header**: app logo (icon), name and a one-line description.
- **Two action tiles** side by side: "New Recording" (purple, with the shortcut) and "Import Video" (secondary, reminding ⌘O and drag and drop). Hover is highlighted. Dropping a video anywhere on the window also opens it (dashed purple frame). The tiles don't take keyboard focus, and no control is selected when the window opens (otherwise a blue focus ring showed on the first tile); Tab still navigates with the keyboard.
- Errors show in a discreet red banner.
- **"Last video"** card: name, type and tracks, "Open" button to reopen the editor if it was closed by mistake.
- **"Settings"** card, rows with an aligned icon, title, detail and a control on the right:
  - **Screen Recording**: required (red dot and "Allow" button until granted).
  - **Microphone**: **optional** (grey dot). Without permission, the Microphone toggle is disabled and recordings have no microphone track.
  - **Global shortcut** (⇧⌘8 by default): click the shortcut, then type the new one (at least ⌘, ⌥ or ⌃; Esc cancels). The current shortcut is suspended while typing. If another app already uses it, it is refused with a message. A small cross inside the same chip (only shown when the shortcut was changed) goes back to ⇧⌘8. The label follows the macOS order (⌃⌥⇧⌘) and shows the key as printed on the keyboard (AZERTY included).
  - **"Launch at login"** (`SMAppService`): the app starts without a window and the shortcut works right away. A global shortcut only exists while the app runs; that's a macOS limit. Turn it on from the app installed in `/Applications` (the option points to the location of the app that enables it).
- Closing the window doesn't quit the app (the shortcut stays active). Click the Dock icon to reopen it, ⌘Q to quit.

## macOS "bypass the private window picker" prompt

macOS (15+) regularly asks to confirm that an app may capture the screen directly, on top of the "Screen Recording" permission. It can't be avoided (only remote desktop apps get the special entitlement). The app queries ScreenCaptureKit **as soon as it launches**, so the prompt shows up then and not at the start of a recording.
