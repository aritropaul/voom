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
  App/            Entry point, AppDelegate, AppState
  Models/         Recording data model
  Views/
    Panel/        Floating control panel (record/stop)
    Library/      Recording library window
    Player/       Video player with transcript
    Settings/     App settings
    Overlay/      Screen overlays (countdown, display picker, camera PiP)
  Services/
    Capture/      ScreenCaptureKit recording + camera
    Writing/      HEVC video encoding
    Transcription/ WhisperKit on-device transcription
    Sharing/      Cloudflare upload service
    Storage/      Local recording persistence

voom-share/       Cloudflare Worker (share page + API)
```

## Guidelines

- Keep it simple. Voom is intentionally minimal.
- Follow existing patterns — services use actor singletons, views use `@Environment`.
- Test your changes by recording a video end-to-end.
- No new dependencies without discussion.

## Cloud Sharing (optional)

See the README for Cloudflare setup. You don't need cloud sharing running to work on the app — it's entirely optional.

## Submitting Changes

1. Create a branch from `main`
2. Make your changes
3. Open a PR with a clear description of what and why
