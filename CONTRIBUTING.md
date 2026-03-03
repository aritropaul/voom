# Contributing to Voom

Thanks for your interest in contributing.

## Getting Started

1. Fork the repo and clone it
2. Open `Voom/Voom.xcodeproj` in Xcode 16+ (macOS 15 SDK required)
3. Build and run

The app runs as a menu bar agent. Click the menu bar icon to open the control panel.

## Project Structure

```
Voom/
  App/              Entry point, AppDelegate, AppState
  Models/           Recording, Folder, Annotation data models
  Views/
    Theme.swift     VoomTheme — all design tokens (colors, spacing, fonts)
    Components/     ToastOverlay
    MenuBar/        CameraPreviewView
    Panel/          Floating control panel (record/stop)
    Library/        Recording library window, folders, tags
    Player/         Video player with transcript, trim, cut, chapters
    Settings/       App settings, self-host setup wizard
    Overlay/        Screen overlays (countdown, display picker, region select, annotations)
    Onboarding/     First-launch onboarding
  Services/
    Capture/        ScreenCaptureKit recording + camera
    Writing/        HEVC video encoding (VideoToolbox)
    Transcription/  WhisperKit on-device transcription
    Sharing/        Cloudflare upload, deploy, view notifications
    Storage/        Local recording persistence (JSON)
    Editing/        Trim, cut/splice, filler word detection
    Export/         GIF export
    TextAnalysis/   Title + summary generation (Apple Intelligence)

voom-share/         Cloudflare Worker (R2 + D1 + share page)
  src/index.js      All routes (API + share page HTML)
  schema.sql        D1 schema
  migrations/       Database migrations
```

## Guidelines

- Keep it simple. Voom is intentionally minimal.
- Follow existing patterns — services use `actor` singletons (`static let shared`), UI state uses `@Observable @MainActor`, views use `@Environment`.
- Use `VoomTheme` for all colors, spacing, fonts, and radii. Never hardcode design values.
- Use `await MainActor.run { ... }` for cross-actor UI updates. Never use `DispatchQueue.main.async` in new code.
- New files must be manually added to `project.pbxproj` (PBXFileReference + PBXBuildFile + PBXGroup).
- Test your changes by recording a video end-to-end.
- No new dependencies without discussion.

## Cloud Sharing (optional)

See the README for Cloudflare setup. You don't need cloud sharing to work on the app — it's entirely optional and runs on the free tier.

To deploy the worker locally during development:

```bash
cd voom-share && npx wrangler dev
```

## Submitting Changes

1. Create a branch from `main`
2. Make your changes
3. Open a PR with a clear description of what and why
