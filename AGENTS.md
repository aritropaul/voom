# Repository Guidelines

## Project Structure
- `Voom/` — macOS app (Swift 6, SwiftUI, ScreenCaptureKit, AVFoundation). Xcode project with manual PBX file references.
- `voom-share/` — Cloudflare Worker (R2 + D1 + Workers) for share page and video hosting.

## Build, Test, Run
- Build: `cd Voom && xcodebuild -scheme Voom -configuration Debug build`
- Release: `cd Voom && xcodebuild -scheme Voom -configuration Release build`
- Run after build: `open ~/Library/Developer/Xcode/DerivedData/Voom-*/Build/Products/Debug/Voom.app`
- Kill and relaunch: `pkill -x Voom; sleep 1; open ~/Library/Developer/Xcode/DerivedData/Voom-*/Build/Products/Debug/Voom.app`
- Deploy worker: `cd voom-share && npx wrangler deploy`
- Always rebuild and relaunch the app after code changes before validating behavior.

## Architecture
- Services use the actor singleton pattern (`static let shared`).
- `RecordingStore` is `@Observable @MainActor` with `update(_ recording:)` for mutations.
- `VoomTheme` holds all design tokens (colors, spacing, radii, typography).
- New files must be added to `project.pbxproj` manually (PBXFileReference + PBXBuildFile + PBXGroup).

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
- Cloud sharing secrets are set at runtime via Settings UI and stored in UserDefaults.
- Worker API secret is deployed via `npx wrangler secret put API_SECRET`.

## Commit Guidelines
- Short imperative commit messages (e.g., "Fix audio mixing when both sources active").
- Keep commits scoped to one logical change.
- PRs should include summary, what changed, and how to test.

## Versioning
- Follows [Pride Versioning](https://pridever.org/) (PROUD.DEFAULT.SHAME).
- Bump PROUD for releases you're proud of, DEFAULT for normal releases, SHAME for embarrassing fixes.
