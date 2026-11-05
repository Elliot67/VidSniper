# UI

Inspired by Obsidian.

- Follows the system theme (light or dark), with the palette centralized in `VidSniper/UI/Theme.swift`.
- Dark: background `#1E1E1E`, secondary background `#262626`, borders `#363636`, text `#DADADA`, muted text `#999999`.
- Light: background `#FFFFFF`, secondary background `#F6F6F6`, borders `#E0E0E0`, text `#222222`, muted text `#5C5C5C`.
- Purple accent `#8A5CF5`. 6 px rounded corners, small fonts, thin borders, no gradients.

## Shared components

- **Chips** (`ToggleChip`, `ChipLabel`): toggles with an icon, purple when on. The icon has a fixed width, because crossed-out variants are wider. A chip can show a shortcut as a drawn key (`KeyCap`), like ⌥ on the Original button.
- **Floating cards** (`FloatingCard`): used instead of the system popovers (shortcuts help), with the app's background, rounded corners, a thin border and a soft shadow. Shown on hover, they don't catch the mouse.
- **Buttons**: `AccentButtonStyle` (filled purple), `SecondaryButtonStyle` (`large: true` matches the accent button's size), `IconButtonStyle` (round, icon only).
- **Windows that appear without animation**: the selection overlay fades in, and the recording outline, handle and mini bar appear instantly. The default macOS animations are drawn by the system and would end up in the recording.
