# CLAUDE.md — Voom

## What is Voom?

A privacy-first macOS screen recording app. Records screen + camera + mic, transcribes on-device with FluidAudio, and optionally shares via a self-hosted Cloudflare Worker. No Electron — pure Swift/SwiftUI.

## Quick Reference

```bash
# Build
cd Voom && xcodebuild -scheme Voom -configuration Debug build

# Run (debug — product is named "Voom Debug.app", not "Voom.app")
open ~/Library/Developer/Xcode/DerivedData/Voom-*/Build/Products/Debug/"Voom Debug.app"

# Kill and relaunch
pkill -f "Voom Debug"; sleep 1; open ~/Library/Developer/Xcode/DerivedData/Voom-*/Build/Products/Debug/"Voom Debug.app"

# Swift tests (pure logic in VoomCore)
swift test --package-path Packages/VoomCore

# Worker tests (vitest + workers pool)
cd voom-share && npm test

# Deploy worker — ALWAYS via the npm script.
# A bare `npx wrangler deploy` resolves wrangler.jsonc (the ID-less self-host
# config) and would deploy a fresh worker instead of production.
cd voom-share && npm run deploy

# Regenerate the self-host WorkerBundle after ANY sharing-side change
# (src/index.js, web/, schema.sql, migrations/). CI fails on drift.
cd voom-share && node scripts/build-selfhost-worker.mjs

# Release (tag triggers GitHub Actions)
git tag -a v3.X.0 -m "v3.X.0" && git push origin v3.X.0
```

Always rebuild and relaunch after code changes. Never test stale builds.

## Project Layout

Most code lives in local Swift packages under `Packages/`; the Xcode app target is a thin shell (entry point + views).

```
voom/
├── Voom/                              # macOS app target (Xcode, manual PBX refs)
│   ├── Voom.xcodeproj/
│   └── Voom/
│       ├── App/                       # VoomApp (@main), AppDelegate, AppState, WhatsNewProvider
│       ├── Views/
│       │   ├── Components/            # ToastOverlay
│       │   ├── Overlay/               # RecordingOverlay, CountdownOverlay, DisplayPicker, RegionSelector, Annotation*
│       │   ├── Panel/                 # ControlPanelView, ControlPanelManager, RecordingSessionController, MeetingPanelManager
│       │   ├── Player/                # PlayerView, NativePlayerView, TrimView, CutSpliceView, ChapterView, ShareSettingsSheet, …
│       │   ├── Library/               # LibraryWindow, FolderRow, CreateFolderSheet, StitchSheet, TagManager, TagFilterView
│       │   ├── Settings/              # SettingsView, InlineSettingsView, SelfHostSetupView
│       │   └── Onboarding/            # OnboardingView
│       └── Resources/
│           ├── Assets.xcassets / Info.plist / Voom.entitlements
│           └── WorkerBundle/          # GENERATED — worker.js, schema.sql, migration_0002…0006.sql
├── Packages/
│   ├── VoomCore/                      # Foundation layer (most services live here)
│   │   ├── Sources/VoomCore/
│   │   │   ├── Models/                # Recording, Folder, Annotation, BlurRegion, RecordingPreset
│   │   │   ├── Theme/Theme.swift      # VoomTheme — ALL design tokens
│   │   │   ├── AppDefaults.swift      # shared UserDefaults keys (e.g. AutoTranscribe)
│   │   │   └── Services/
│   │   │       ├── Capture/           # CameraCapture, InputTracker, MicTimeAdjuster
│   │   │       ├── Writing/           # VideoWriter (HEVC via AVAssetWriter; finalize() throws)
│   │   │       ├── Storage/           # RecordingStorage, LibraryDatabase (SQLite), PresetStore
│   │   │       ├── Transcription/     # TranscriptionService (FluidAudio)
│   │   │       ├── Sharing/           # ShareService, ShareCoordinator, CloudflareDeployService, ViewNotificationService
│   │   │       ├── Editing/           # VideoEditor, FillerWordDetector, PrivacyBlurRenderer, TranscriptEditor, AutoZoomAnalyzer
│   │   │       ├── Export/            # GIFExporter, TranscriptExporter
│   │   │       ├── TextAnalysis/      # TextAnalysisService (FoundationModels + VoomAI)
│   │   │       ├── KeychainStore.swift
│   │   │       └── GlobalHotkey.swift
│   │   └── Tests/VoomCoreTests/       # transcript math, filler detection, Codable fixtures, SQLite store
│   ├── VoomApp/                       # ScreenCaptureKit capture: ScreenRecorder, CameraOnlyRecorder
│   ├── VoomAI/                        # BYOK providers: AIService, AIConfig, AIProvider
│   ├── VoomMeetings/                  # MeetingDetectionService, MeetingRecorder, MeetingTranscription, SpeakerDiarizationService
│   └── VoomCLI/                       # `voom` executable + Claude skill (skill/voom/SKILL.md)
├── voom-share/                        # Cloudflare Worker
│   ├── src/index.js                   # All routes (API + OG pages); share page served from web/dist via ASSETS
│   ├── web/                           # Astro 6 share/embed pages (dist/ committed by design)
│   ├── test/                          # vitest suites (helpers + API integration)
│   ├── schema.sql                     # Consolidated D1 schema (kept in sync with SCHEMA_STATEMENTS)
│   ├── migrations/                    # 0002…0006 incremental migrations
│   ├── scripts/build-selfhost-worker.mjs  # regenerates Voom/Voom/Resources/WorkerBundle
│   ├── wrangler.toml                  # MAINTAINER config (real resource IDs) — deploy via `npm run deploy`
│   ├── wrangler.jsonc                 # Self-host / Deploy-button config (ID-less, distinct worker name)
│   └── wrangler.test.jsonc            # vitest pool config
└── .github/workflows/
    ├── build.yml                      # CI: app build + swift tests + VoomCLI + worker tests + WorkerBundle drift gate
    └── release.yml                    # Release: sign, notarize, DMG, Sparkle appcast, Homebrew cask bump
```

## Architecture

### Core Patterns

**Actor singletons** — every service:
```swift
actor SomeService {
    static let shared = SomeService()
    private init() {}
}
```

**Observable state** — UI-reactive containers:
```swift
@Observable @MainActor
final class SomeStore {
    // ...
}
```

**RecordingStore** uses `update(_ recording:)` for all mutations. Never mutate a `Recording` directly outside the store. `delete()` also removes the public share, thumbnail, and sidecar files.

**RecordingSessionController** (app target, `@Observable @MainActor`) owns the recorder lifecycle (ScreenRecorder / CameraOnlyRecorder / MeetingRecorder), the camera preview, the duration timer, and the user-visible `errorMessage`. Views forward intents to it; AppDelegate's quit guard calls `stopForQuit()` so quitting mid-recording always finalizes and saves first.

**ShareCoordinator** (VoomCore) is the single implementation of share/copy/renew/unshare flows — views only translate outcomes into toasts.

### Concurrency Model

| Context | Isolation | Examples |
|---------|-----------|---------|
| UI state | `@MainActor` | AppState, RecordingStore, RecordingSessionController, ShareUploadTracker, DeployProgress |
| I/O services | `actor` | ScreenRecorder, RecordingStorage, ShareService, TranscriptionService |
| FluidAudio | `nonisolated(unsafe)` | Only accessed from TranscriptionService / SpeakerDiarizationService |
| SCStream callbacks | Global queue | Must dispatch to MainActor for state updates |

Use `await MainActor.run { ... }` for cross-actor UI updates. Never use DispatchQueue.main.async in new code.

### Recording Pipeline

1. **SCContentFilter** excludes Voom's own windows (except camera PiP + annotation overlay)
2. **SCStream** captures video frames (BGRA32, native Retina) + audio samples
3. **VideoWriter** encodes via AVAssetWriter → HEVC hardware encoder → MP4. `finalize()` **throws** if the writer failed (disk full) — recorders attempt salvage and surface errors; never present an unfinalized file as a recording.
4. Camera PiP window is captured directly by SCStream (no compositor overlay)

### Data Persistence

```
~/Movies/Voom/
├── Voom-YYYY-MM-DD-HHmmss.mp4    # Video files (the source of truth)
├── .library.sqlite                # SQLite library index (recordings/folders/tags as JSON rows, WAL mode)
├── *.cursor.json                  # Cursor-event sidecars
└── .thumbnails/{UUID}.jpg         # Poster frames
```

- `LibraryDatabase` (VoomCore) wraps system SQLite: per-row upserts, one corrupt row can't take down the library, WAL makes app + CLI concurrent access safe.
- Legacy `.recordings.json` / `.folders.json` / `.tags.json` are migrated to SQLite on first launch (renamed `.migrated`, never deleted).
- If the index is empty but MP4s exist, the store rebuilds entries by disk scan.
- Secrets (`ShareAPISecret`, `AIAPIKey`) live in the **Keychain** via `KeychainStore`, never UserDefaults.

### Cloud Sharing

- **Worker**: Cloudflare Workers (ES module). Top-level error middleware returns JSON 500s.
- **Storage**: R2 bucket `voom-videos`; **Database**: D1 `voom-share-db`.
- **Auth**: Bearer token (`API_SECRET` env var on worker; Keychain on client), timing-safe compare.
- **Share passwords**: client sends SHA256(password); worker stores salted `SHA256(salt + clientHash)` with lazy upgrade of legacy rows; verify-password is rate limited (10/IP/5min); OG pages/images are gated for protected videos.
- **Schema**: `SCHEMA_VERSION` + `SCHEMA_MIGRATIONS` in `src/index.js` is the runtime source of truth. Any change that ALTERs an existing table MUST add a `SCHEMA_MIGRATIONS` entry under a bumped version (CREATE-only changes can't reach existing DBs), plus a numbered file in `migrations/` for the token-deploy path, plus the consolidated `schema.sql`, plus the `migrationResources` list in `CloudflareDeployService.swift`.
- **Expiry**: 30 days per share, daily cron cleanup (03:00 UTC everywhere — keep wrangler.toml, wrangler.jsonc, and CloudflareDeployService in sync).
- **Self-host**: `CloudflareDeployService` auto-provisions from a token; the Deploy-button path uses `wrangler.jsonc` (worker name intentionally differs from production so a bare deploy can never overwrite it).

Worker routes: `/api/*` (authenticated), `/s/:code` (share page; OG HTML for bots), `/v/:code` (video stream with bounded/open/suffix ranges + 416), `/vtt/:code`, `/og/:code`, `/thumb/:code`.

**The WorkerBundle is generated.** After any change to `src/index.js`, `web/`, `schema.sql`, or `migrations/`: rebuild `web/` if its source changed (`cd web && npm run build`), then `node scripts/build-selfhost-worker.mjs`, and commit `Voom/Voom/Resources/WorkerBundle/`. CI has a drift gate that fails otherwise.

## Design System (VoomTheme)

All tokens live in `Packages/VoomCore/Sources/VoomCore/Theme/Theme.swift`. Never hardcode colors, spacing, or fonts.

```swift
// Colors
VoomTheme.backgroundPrimary / Secondary / Tertiary / Card / Hover / Selected
VoomTheme.textPrimary / Secondary / Tertiary / Quaternary
VoomTheme.borderSubtle / Medium / Strong
VoomTheme.accentRed / accentGreen / accentOrange

// Typography (functions)
VoomTheme.fontTitle()     // 15pt semibold
VoomTheme.fontHeadline()  // 12pt semibold
VoomTheme.fontBody()      // 13pt
VoomTheme.fontCaption()   // 11pt
VoomTheme.fontMono()      // 10pt monospaced
VoomTheme.fontBadge()     // 10pt medium

// Spacing (CGFloat constants, NOT functions)
VoomTheme.spacingXS  // 4
VoomTheme.spacingSM  // 8
VoomTheme.spacingMD  // 12
VoomTheme.spacingLG  // 16
VoomTheme.spacingXL  // 24
VoomTheme.spacingXXL // 32

// Radii (CGFloat constants)
VoomTheme.radiusSmall  // 4
VoomTheme.radiusMedium // 8
VoomTheme.radiusLarge  // 12

// View modifiers / components
.voomCard()               // Standard card background
VoomBadge, ActionBarButton, ToolPillButton, VoomEmptyState, FlowLayout
```

Dark theme only. No light mode.

## Testing

- **Swift**: `swift test --package-path Packages/VoomCore` — covers `VideoEditor.adjustTranscript` math, `FillerWordDetector`, `Recording` decode against a v1 fixture (guards schema evolution — new `Recording` fields MUST be Optional or this test fails), and the SQLite store (round-trip, JSON migration, corrupt recovery).
- **Worker**: `cd voom-share && npm test` — vitest with the Cloudflare workers pool (real D1/R2 semantics): auth, upload validation, ranges, password flow (salting, lazy upgrade, rate limit), delete cleanup, error middleware.
- CI runs both plus a VoomCLI build and the WorkerBundle drift gate on every push/PR.

## Adding New Files

**Packages/`*`**: just create the file — SPM globs sources, no registration needed. Prefer putting new services/models in VoomCore.

**App target (Voom/Voom/)**: Xcode uses manual PBX references. Every new file needs 3 entries in `project.pbxproj`:

1. **PBXFileReference** — declares the file exists
2. **PBXBuildFile** — links it to Sources or Resources build phase
3. **PBXGroup** — places it in the correct folder group

```
// PBXFileReference section:
HEXID1 /* NewFile.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NewFile.swift; sourceTree = "<group>"; };

// PBXBuildFile section:
HEXID2 /* NewFile.swift in Sources */ = {isa = PBXBuildFile; fileRef = HEXID1 /* NewFile.swift */; };

// Add HEXID1 to the appropriate PBXGroup children list
// Add HEXID2 to PBXSourcesBuildPhase (A10006001) files list
```

Use random 24-char hex IDs for new entries. Key group UUIDs (verified):
- Sources build phase: `A10006001`
- Resources build phase: `A10006002`
- Views group: `A10005003` · Panel: `A10005009` · Player: `A10005006` · Library: `A10005005` · Overlay: `A10005008` · Settings: `A10005017` · Onboarding: `A10005018` · Components: `A10005019` · Resources group: `A10005020`

For folder references (like WorkerBundle): use `lastKnownFileType = folder` and add to Resources build phase.

## Code Signing

- **Identity**: `Apple Development` (automatic, team `2J3WW2KWBU`)
- **Entitlements**: No sandbox, camera + mic access
- **Debug bundle ID**: `com.voom.app.debug` / **Release**: `com.voom.app`
- **Hardened runtime**: Off in Debug, **on in Release** (pbxproj and CI agree; required for notarization)
- Never leave stale builds in `Voom/build/` — Launch Services may pick them over DerivedData

## Release Process

1. Commit changes to `main`
2. Tag: `git tag -a v3.X.0 -m "v3.X.0 — description"` and push tag
3. `release.yml` workflow: builds → signs with Developer ID → notarizes (hard-fails on any non-Accepted status) → creates DMG → generates Sparkle appcast → publishes GitHub Release → bumps Homebrew cask
4. Sparkle auto-updater picks up the appcast

Both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are set from the git tag automatically by the workflow.

## Coding Conventions

- **Swift 6** with targeted strict concurrency
- **`@Observable`** over `ObservableObject`; **`@State`** over `@StateObject`
- **MARK comments**: `// MARK: - Section` to organize code
- **Minimal changes**: don't refactor code you didn't need to touch
- **No over-engineering**: no abstractions for one-time operations
- **Errors are surfaced, not swallowed**: recording/share/transcription failures reach the user (toast or alert) — never `try?` away a failure on a user-data path
- **Commit style**: short imperative (`Fix audio mixing when both sources active`)
- **Versioning**: [Pride Versioning](https://pridever.org/) — PROUD.DEFAULT.SHAME

## Secrets — Never Commit

- API secrets, tokens, credentials
- Team IDs, cert hashes, signing identities (except in pbxproj where Xcode requires them)
- Worker URLs, email addresses, local paths
- Runtime secrets belong in the Keychain (`KeychainStore`), never UserDefaults
- Audit with `grep -r` before committing docs or config

## Git

- GitHub account: `aritropaul` (switch with `gh auth switch --user aritropaul`)
- Remote: `https://github.com/aritropaul/voom.git`
- Always commit to `main` (no feature branches for solo dev)

## Dependencies

| Package | Purpose | Where | Manager |
|---------|---------|-------|---------|
| FluidAudio (0.15.2+) | On-device ASR and speaker diarization | VoomCore, VoomMeetings | Swift Package |
| Sparkle | Auto-updates with EdDSA signing | Xcode project | Swift Package |
| WhatsNewKit | What's-new sheets | Xcode project | Swift Package |
| swift-argument-parser | CLI parsing | VoomCLI | Swift Package |
| wrangler | Worker deploy CLI | voom-share | npm |
| vitest + @cloudflare/vitest-pool-workers | Worker tests | voom-share | npm |
| astro (v6) | Share/embed pages | voom-share/web | npm |
