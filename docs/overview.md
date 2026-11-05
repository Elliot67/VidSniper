# Overview

VidSniper is a macOS app to quickly record an area of the screen, make a few edits, and share the video (Slack, Jira…) without going through the Finder.

> **Keep these docs up to date.** Every change to the app (new feature, fix, changed behavior or decision) must update the matching page in `docs/` in the same commit, and [roadmap.md](roadmap.md) when it changes the progress. The docs must always describe the app as it actually is.

## Typical flow

Global shortcut (⇧⌘8) → select an area → record with the mini bar → editor (cuts, audio tracks, annotations) → drag or copy the video. Nothing is kept unless you use "Save…".

## Stack

- **Swift 6 + SwiftUI**, with AppKit for the special windows (selection overlay, mini bar, drag handle).
- **macOS 15 minimum** (developed on macOS 26).
- **ScreenCaptureKit** for capture, **AVFoundation** for editing and export. No ffmpeg in the app (only used to generate test videos).
- **Global shortcut through the Carbon API** (`RegisterEventHotKey`): no dependency, no Accessibility permission.
- **XcodeGen**: `project.yml` is versioned, the `.xcodeproj` is generated and ignored by git.
- The app lives in the Dock, with no menu bar icon and no App Sandbox.
- Signed with "Apple Development" (team `T9WD2H73Y6`), hardened runtime with the microphone entitlement. A stable signature keeps macOS from asking for the screen permission again after each build.
