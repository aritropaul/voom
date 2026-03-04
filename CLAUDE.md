# CLAUDE.md — Voom

## What is Voom?

A privacy-first macOS screen recording app. Records screen + camera + mic, transcribes on-device with WhisperKit, and optionally shares via a self-hosted Cloudflare Worker. No Electron — pure Swift/SwiftUI.

## Quick Reference

```bash
# Build
cd Voom && xcodebuild -scheme Voom -configuration Debug build

# Run (debug)
open ~/Library/Developer/Xcode/DerivedData/Voom-*/Build/Products/Debug/"Voom Debug.app"

# Kill and relaunch
pkill -f "Voom Debug"; sleep 1; open ~/Library/Developer/Xcode/DerivedData/Voom-*/Build/Products/Debug/"Voom Debug.app"

# Deploy worker
cd voom-share && npx wrangler deploy

# Release (tag triggers GitHub Actions)
git tag -a v2.X.0 -m "v2.X.0" && git push origin v2.X.0
```

Always rebuild and relaunch after code changes. Never test stale builds.

## Project Layout

```
voom/
├── Voom/                              # macOS app
│   ├── Voom.xcodeproj/               # Manual PBX file refs
│   └── Voom/
│       ├── App/                       # VoomApp, AppDelegate, AppState
│       ├── Models/                    # Recording, Folder, Annotation
│       ├── Services/
│       │   ├── Capture/               # ScreenRecorder, CameraCapture, FrameCompositor, CameraOnlyRecorder
│       │   ├── Writing/               # VideoWriter (HEVC/H.264 via VideoToolbox)
│       │   ├── Storage/               # RecordingStorage (JSON persistence)
│       │   ├── Transcription/         # TranscriptionService (WhisperKit)
│       │   ├── Sharing/               # ShareService, CloudflareDeployService, ViewNotificationService
│       │   ├── Editing/               # VideoEditor, FillerWordDetector
│       │   ├── Export/                # GIFExporter
│       │   ├── TextAnalysis/          # TextAnalysisService
│       │   └── GlobalHotkey.swift
│       ├── Views/
│       │   ├── Theme.swift            # VoomTheme — ALL design tokens live here
│       │   ├── Components/            # ToastOverlay
│       │   ├── MenuBar/               # CameraPreviewView
│       │   ├── Overlay/               # RecordingOverlay, CountdownOverlay, DisplayPicker, RegionSelector, Annotation*
│       │   ├── Panel/                 # ControlPanelView, ControlPanelManager
│       │   ├── Player/                # PlayerView, NativePlayerView, TrimView, CutSpliceView, ChapterView, ShareSettingsSheet
│       │   ├── Library/               # LibraryWindow, FolderRow, CreateFolderSheet, StitchSheet, TagManager, TagFilterView
│       │   ├── Settings/              # SettingsView, InlineSettingsView, SelfHostSetupView
│       │   └── Onboarding/            # OnboardingView
│       └── Resources/
│           ├── Assets.xcassets
│           ├── Info.plist
│           ├── Voom.entitlements
│           └── WorkerBundle/          # Bundled worker.js, schema.sql, migration_0002.sql
├── voom-share/                        # Cloudflare Worker
│   ├── src/index.js                   # All routes (API + share page HTML)
│   ├── schema.sql                     # D1 schema (videos, transcript_segments)
│   ├── migrations/                    # 0002_share_enhancements.sql (reactions, comments, password, CTA)
│   └── wrangler.toml                  # R2 bucket, D1 database, cron triggers
└── .github/workflows/
    ├── build.yml                      # CI: unsigned build on push/PR
    └── release.yml                    # Release: sign, notarize, DMG, Sparkle appcast
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

**RecordingStore** uses `update(_ recording:)` for all mutations. Never mutate a `Recording` directly outside the store.

### Concurrency Model

| Context | Isolation | Examples |
|---------|-----------|---------|
| UI state | `@MainActor` | AppState, RecordingStore, ShareUploadTracker, DeployProgress |
| I/O services | `actor` | ScreenRecorder, RecordingStorage, ShareService, TranscriptionService |
| WhisperKit | `nonisolated(unsafe)` | Only accessed from TranscriptionService |
| SCStream callbacks | Global queue | Must dispatch to MainActor for state updates |

Use `await MainActor.run { ... }` for cross-actor UI updates. Never use DispatchQueue.main.async in new code.

### Recording Pipeline

1. **SCContentFilter** excludes Voom's own windows (except camera PiP + annotation overlay)
2. **SCStream** captures video frames (BGRA32, native Retina) + audio samples
3. **VideoWriter** encodes via AVAssetWriter → HEVC hardware encoder → MP4
4. Camera PiP window is captured directly by SCStream (no compositor overlay)

### Data Persistence

```
~/Movies/Voom/
├── Voom-YYYY-MM-DD-HHmmss.mp4    # Video files
├── .recordings.json                # Recording metadata
├── .folders.json                   # Folder structure
├── .tags.json                      # Tag definitions
└── .thumbnails/{UUID}.jpg          # Poster frames
```

### Cloud Sharing

- **Worker**: Cloudflare Workers (ES module format)
- **Storage**: R2 bucket `voom-videos` for video files
- **Database**: D1 `voom-share-db` for metadata, transcripts, reactions, comments
- **Auth**: Bearer token (`API_SECRET` env var on worker, UserDefaults on client)
- **Expiry**: 30 days per share, daily cron cleanup
- **Self-host deploy**: CloudflareDeployService auto-discovers account from token, creates all resources

Worker routes: `/api/*` (authenticated), `/s/:code` (public share page), `/v/:code` (video stream with range requests).

## Design System (VoomTheme)

All tokens live in `Views/Theme.swift`. Never hardcode colors, spacing, or fonts.

```swift
// Colors
VoomTheme.backgroundPrimary / Secondary / Tertiary / Card
VoomTheme.textPrimary / Secondary / Tertiary / Quaternary
VoomTheme.borderSubtle / Medium / Strong
VoomTheme.accentRed / accentGreen / accentOrange

// Typography
VoomTheme.fontTitle()     // 15pt semibold
VoomTheme.fontHeadline()  // 12pt semibold
VoomTheme.fontBody()      // 13pt
VoomTheme.fontCaption()   // 11pt
VoomTheme.fontMono()      // 10pt monospaced
VoomTheme.fontBadge()     // 10pt medium

// Spacing
VoomTheme.spacingXS(4) / SM(8) / MD(12) / LG(16) / XL(24) / XXL(32)

// Radii
VoomTheme.radiusSmall(4) / radiusMedium(8) / radiusLarge(12)

// View modifiers
.voomCard()               // Standard card background
```

Dark theme only. No light mode.

## Adding New Files

Xcode uses manual PBX references. Every new file needs 3 entries in `project.pbxproj`:

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

Use random 24-char hex IDs for new entries. Key group UUIDs:
- Sources build phase: `A10006001`
- Resources build phase: `A10006002`
- Sharing group: `A10005016`
- Settings group: `A10005017`
- Resources group: `A10005020`

For folder references (like WorkerBundle): use `lastKnownFileType = folder` and add to Resources build phase.

## Code Signing

- **Identity**: `Apple Development` (automatic, team `2J3WW2KWBU`)
- **Entitlements**: No sandbox, camera + mic access
- **Debug bundle ID**: `com.voom.app.debug` / **Release**: `com.voom.app`
- **Hardened runtime**: Off in debug, on in release (required for notarization)
- Never leave stale builds in `Voom/build/` — Launch Services may pick them over DerivedData

## Release Process

1. Commit changes to `main`
2. Tag: `git tag -a v2.X.0 -m "v2.X.0 — description"` and push tag
3. `release.yml` workflow: builds → signs with Developer ID → notarizes → creates DMG → generates Sparkle appcast → publishes GitHub Release
4. Sparkle auto-updater picks up the appcast

Both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are set from the git tag automatically by the workflow.

## Coding Conventions

- **Swift 6** with targeted strict concurrency
- **`@Observable`** over `ObservableObject`; **`@State`** over `@StateObject`
- **MARK comments**: `// MARK: - Section` to organize code
- **Minimal changes**: don't refactor code you didn't need to touch
- **No over-engineering**: no abstractions for one-time operations
- **Commit style**: short imperative (`Fix audio mixing when both sources active`)
- **Versioning**: [Pride Versioning](https://pridever.org/) — PROUD.DEFAULT.SHAME

## Secrets — Never Commit

- API secrets, tokens, credentials
- Team IDs, cert hashes, signing identities (except in pbxproj where Xcode requires them)
- Worker URLs, email addresses, local paths
- Audit with `grep -r` before committing docs or config

## Git

- GitHub account: `aritropaul` (switch with `gh auth switch --user aritropaul`)
- Remote: `https://github.com/aritropaul/voom.git`
- Always commit to `main` (no feature branches for solo dev)

## Dependencies

| Package | Purpose | Manager |
|---------|---------|---------|
| WhisperKit | On-device transcription (distil-large-v3) | Swift Package |
| Sparkle | Auto-updates with EdDSA signing | Swift Package |
| wrangler | Cloudflare Worker deployment CLI | npm |
