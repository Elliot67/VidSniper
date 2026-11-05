# Development

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Tests also need ffmpeg (`brew install ffmpeg`).

```sh
xcodegen               # generate the Xcode project
xcodebuild             # debug build in build/Debug/
./scripts/test.sh      # run all tests (see testing.md)
./scripts/install.sh   # install a release build in /Applications
```

- Relaunch the debug build: `pkill -x VidSniper; sleep 1; open build/Debug/VidSniper.app` (the `sleep` avoids error -600). Add `--args -AppleLanguages '(en)'` to run it in English.
- **Signing**: the Apple intermediate certificate **WWDR G3** (https://www.apple.com/certificateauthority/) must be installed, otherwise the development certificate is considered invalid. To build with another account, change `DEVELOPMENT_TEAM` and `bundleIdPrefix` in `project.yml`.
- **Installing**: `./scripts/install.sh` builds in Release, replaces `/Applications/VidSniper.app` and launches it. Same signature as the debug build, so permissions stay granted. It then **deletes the build copies** (`build/Debug` and the Release build) after unregistering them from Launch Services: only one VidSniper on the Mac (no conflict on the global shortcut, no duplicate in Spotlight).
- To publish a release, see [release.md](release.md).

## Removing the app

Only one VidSniper should be installed at a time (the global shortcut can only belong to one). To switch between a local build and the Homebrew version, remove the current one first:

```sh
# App installed by ./scripts/install.sh (or by hand)
pkill -x VidSniper; rm -rf /Applications/VidSniper.app

# App installed with Homebrew
brew uninstall --cask vidsniper
# ...or replace it in place
brew install --cask --force vidsniper

# Also remove caches and settings (shortcut, compression, balance…)
brew uninstall --zap --cask vidsniper

# Reset the screen recording and microphone permissions
tccutil reset ScreenCapture com.elintz.VidSniper
tccutil reset Microphone com.elintz.VidSniper
```

A local build and a release don't have the same signature: macOS asks for the screen and microphone permissions again after switching. If "Launch at login" was on, turn it off and on again from the newly installed app.

## Working in the Claude Code sandbox

- `xcodegen` and `xcodebuild` only work in the sandbox when **run without arguments**.
- `xcodebuild test` can't run there (writes to `~/Library/Developer` are refused, the video encoder is blocked): `./scripts/test.sh` is run by hand. The tests are type-checked with `swiftc -typecheck` against `build/Debug/VidSniper.swiftmodule`.

## Translations (English / French)

- Apple's standard method: **String Catalogs**. The code is written in **English** (source language, `developmentLanguage: en`), French lives in `VidSniper/Resources/Localizable.xcstrings`. Info.plist texts (microphone description, "Video" document type) are translated in `InfoPlist.xcstrings`.
- The language follows the system (System Settings > General > Language & Region, with a per-app setting under "Applications"). English for any other language.
- In code: SwiftUI literals (`Text("…")`, `Button`, `Label`, `.help`) are translated automatically. Any text going through a `String` variable (titles of `ToggleChip`, `ActionTile`, `Card`, `SettingsRow`, timeline cells, errors, texts drawn in AppKit) goes through `String(localized: "…")`. What isn't translated (app name, durations, dimensions) uses `Text(verbatim:)`.
- Interpolations: `"Size: \(x)"` gives the key `Size: %@` (`%lld` for an integer); with several values, the translation can reorder them (`%1$@`, `%2$@`).
- Adding a text: write it in English in the code, then add the translation to the catalog (Xcode fills it on each build when the project is open in Xcode; from the command line, extracted keys are in the `.stringsdata` files of the `build/` folder). `scripts/check-translations.py` (run by `./scripts/test.sh`) fails on a missing or unused translation.
- Labels don't have the same length in each language: lay out buttons so they adapt (the export Copy and Save buttons share the width of the longest one).
- Saved file names follow the language too ("2026-10-31 at 14.03.22" / "2026-10-31 à 14.03.22").
