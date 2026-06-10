# Contributing to Voom

Thanks for your interest in contributing.

## Getting Started

1. Fork the repo and clone it
2. Open `Voom/Voom.xcodeproj` in Xcode 26+ (macOS 26 SDK; CI builds with Xcode 26.2)
3. Build and run

The app runs as a menu bar agent. Click the menu bar icon to open the control panel. The Debug build product is named **"Voom Debug.app"**.

## Project Structure

Most code lives in local Swift packages under `Packages/`. The Xcode app target (`Voom/Voom/`) only contains the entry point and SwiftUI views.

```
Voom/Voom/
  App/              Entry point, AppDelegate, AppState, WhatsNewProvider
  Views/
    Components/     ToastOverlay
    Panel/          Floating control panel + RecordingSessionController
    Library/        Recording library window, folders, tags
    Player/         Video player with transcript, trim, cut, chapters
    Settings/       App settings, self-host setup wizard
    Overlay/        Screen overlays (countdown, display picker, region select, annotations)
    Onboarding/     First-launch onboarding
  Resources/        Assets, Info.plist, entitlements, generated WorkerBundle

Packages/
  VoomCore/         Models, VoomTheme (Theme/Theme.swift), and most services:
                    Capture/ (camera, input tracking), Writing/ (HEVC encoding),
                    Storage/ (SQLite library), Transcription/ (FluidAudio),
                    Sharing/, Editing/, Export/, TextAnalysis/, KeychainStore
                    + Tests/VoomCoreTests (run with `swift test`)
  VoomApp/          ScreenCaptureKit capture (ScreenRecorder, CameraOnlyRecorder)
  VoomAI/           Bring-your-own-key AI providers (Anthropic/OpenAI/Google/xAI)
  VoomMeetings/     Meeting detection, recording, speaker diarization
  VoomCLI/          `voom` command-line tool

voom-share/         Cloudflare Worker (R2 + D1)
  src/index.js      All routes (API + OG pages); share page is the Astro app
  web/              Astro share/embed pages (dist/ is committed by design)
  test/             vitest suites (run with `npm test`)
  schema.sql        Consolidated D1 schema
  migrations/       Incremental migrations (0002…)
  scripts/          build-selfhost-worker.mjs — regenerates the app's WorkerBundle
```

## Guidelines

- Keep it simple. Voom is intentionally minimal.
- Follow existing patterns — services use `actor` singletons (`static let shared`), UI state uses `@Observable @MainActor`, views use `@Environment`.
- Use `VoomTheme` for all colors, spacing, fonts, and radii. Never hardcode design values.
- Use `await MainActor.run { ... }` for cross-actor UI updates. Never use `DispatchQueue.main.async` in new code.
- New files in `Packages/*` need no registration (SPM globs sources). New files in the app target must be manually added to `project.pbxproj` (PBXFileReference + PBXBuildFile + PBXGroup).
- Run the tests: `swift test --package-path Packages/VoomCore` and `cd voom-share && npm test`. Then test your changes by recording a video end-to-end.
- If you touch `voom-share/src`, `web/`, `schema.sql`, or `migrations/`: rebuild `web/` if needed (`cd web && npm run build`), then run `node scripts/build-selfhost-worker.mjs` and commit the regenerated `Voom/Voom/Resources/WorkerBundle/`. CI fails on a stale bundle.
- No new dependencies without discussion.

## Cloud Sharing (optional)

See the README for Cloudflare setup. You don't need cloud sharing to work on the app — it's entirely optional and runs on the free tier.

To run the worker locally during development:

```bash
cd voom-share && npm run dev
```

## Submitting Changes

1. Create a branch from `main`
2. Make your changes
3. Open a PR with a clear description of what and why
