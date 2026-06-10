# Repository Guidelines

## Project Structure
- `Voom/` — macOS app target (Swift 6, SwiftUI). Thin: `@main`, AppDelegate/AppState, and all SwiftUI views. Xcode project with manual PBX file references.
- `Packages/` — local Swift packages where most code lives:
  - `VoomCore` — models, theme, storage (SQLite), sharing, editing, transcription, export services.
  - `VoomApp` — ScreenCaptureKit capture layer (ScreenRecorder, CameraOnlyRecorder).
  - `VoomAI` — BYOK AI providers (Anthropic/OpenAI/Google/xAI).
  - `VoomMeetings` — meeting detection, recording, diarization.
  - `VoomCLI` — `voom` command-line tool (SwiftPM executable).
- `voom-share/` — Cloudflare Worker (R2 + D1) for sharing; `web/` is the Astro share page.

## Build, Test, Run
- Build app: `cd Voom && xcodebuild -scheme Voom -configuration Debug build`
- Run after build: `open ~/Library/Developer/Xcode/DerivedData/Voom-*/Build/Products/Debug/"Voom Debug.app"` (the Debug product is named "Voom Debug", not "Voom")
- Kill and relaunch: `pkill -f "Voom Debug"; sleep 1; open ~/Library/Developer/Xcode/DerivedData/Voom-*/Build/Products/Debug/"Voom Debug.app"`
- Swift tests: `swift test --package-path Packages/VoomCore`
- Worker tests: `cd voom-share && npm test`
- Deploy worker (maintainer): `cd voom-share && npm run deploy` — NEVER a bare `npx wrangler deploy` (that resolves `wrangler.jsonc`, the self-host config).
- After any change to `voom-share/src/index.js`, `web/`, `schema.sql`, or `migrations/`: run `node voom-share/scripts/build-selfhost-worker.mjs` and commit the regenerated `Voom/Voom/Resources/WorkerBundle/` (CI fails on drift).
- Always rebuild and relaunch the app after code changes before validating behavior.

## Architecture
- Services use the actor singleton pattern (`static let shared`).
- `RecordingStore` is `@Observable @MainActor` with `update(_ recording:)` for mutations; persistence is SQLite (`~/Movies/Voom/.library.sqlite`) via `LibraryDatabase`.
- `RecordingSessionController` (app target) owns recorder lifecycle; views forward intents.
- `VoomTheme` (in `Packages/VoomCore/Sources/VoomCore/Theme/Theme.swift`) holds all design tokens.
- New files in the app target must be added to `project.pbxproj` manually (PBXFileReference + PBXBuildFile + PBXGroup). Files in `Packages/*` need no registration — SPM globs sources.

## Coding Style
- Swift 6 with targeted strict concurrency.
- Prefer `@Observable` over `ObservableObject`; `@State` over `@StateObject`.
- Match existing MARK organization and naming conventions.
- Keep changes minimal — don't refactor code you didn't need to touch.

## Code Signing
- Must use Apple Development certificate (not self-signed).
- `CODE_SIGN_IDENTITY = "Apple Development"`, `CODE_SIGN_STYLE = Automatic`.
- Never leave stale builds in `build/` — macOS Launch Services may pick those over DerivedData builds.

## Secrets
- Never commit API secrets, tokens, or credentials.
- The share API secret and AI keys are stored in the Keychain (`KeychainStore` in VoomCore), never UserDefaults.
- Worker API secret is deployed via `npx wrangler secret put API_SECRET`.

## Commit Guidelines
- Short imperative commit messages (e.g., "Fix audio mixing when both sources active").
- Keep commits scoped to one logical change.
- PRs should include summary, what changed, and how to test.

## Versioning
- Follows [Pride Versioning](https://pridever.org/) (PROUD.DEFAULT.SHAME).
- Bump PROUD for releases you're proud of, DEFAULT for normal releases, SHAME for embarrassing fixes.
