<p align="center">
  <img src="icon.png" width="128" height="128" alt="Voom icon">
</p>

<h1 align="center">Voom</h1>

<p align="center">Open-source Loom alternative for macOS. Record your screen, camera, and mic — get a shareable link in seconds.</p>

## What it does

### Recording
- **Screen recording** — capture any display at full retina resolution (HEVC)
- **Camera-only mode** — record webcam directly without screen capture
- **Region selection** — drag to select a portion of your screen to record
- **Camera overlay** — picture-in-picture webcam with draggable corner positioning
- **System + mic audio** — record both simultaneously
- **Drawing tools** — annotate your screen live during recording (freehand, arrows, shapes, text)
- **Pause/resume** — pause and resume recording without splitting files

### Post-recording
- **On-device transcription** — powered by WhisperKit (distil-large-v3), fully offline
- **Trim** — cut the start and end of a recording
- **Cut/splice** — remove sections from the middle of a recording
- **Stitch** — combine multiple recordings into one
- **Filler word removal** — detect and cut "um", "uh", "like", etc. from transcribed recordings
- **Chapters** — add timestamped chapter markers for easy navigation
- **GIF export** — copy a GIF of the first 15 seconds to clipboard

### Organization
- **Folders** — organize recordings into color-coded folders
- **Tags** — add color-coded tags and filter by them
- **Search** — search across titles and transcripts

### Sharing
- **Share via link** — upload to your own Cloudflare infrastructure, get a clean share page with synced transcript and captions
- **Password protection** — optionally require a password to view shared recordings
- **Emoji reactions** — viewers can react at specific timestamps
- **Timestamped comments** — viewers can leave comments tied to video timestamps
- **CTA buttons** — add a call-to-action overlay that appears when the video ends
- **View notifications** — get macOS notifications when someone watches your recording
- **30-day expiry** — links auto-expire, daily cron cleans up storage

## Architecture

```
Voom/                   macOS app (Swift, SwiftUI, ScreenCaptureKit)
voom-share/             Cloudflare Worker (R2 + D1 + Workers)
```

The app is entirely local-first. Cloud sharing is opt-in per recording and runs on your own Cloudflare account — completely free under Cloudflare's free tier.

## Setup

### macOS App

Open `Voom/Voom.xcodeproj` in Xcode and build. Requires macOS 15+.

### Cloud Sharing (optional)

**Option A: In-app setup wizard (recommended)**

Open Settings → Cloud Sharing → Self-Host. Paste your Cloudflare API token and account ID. The app creates the R2 bucket, D1 database, runs migrations, deploys the worker, and configures everything automatically.

**Option B: Manual CLI deploy**

```bash
cd voom-share
npm install
npx wrangler login
npx wrangler r2 bucket create voom-videos
npx wrangler d1 create voom-share-db
# paste the database_id into wrangler.toml
npx wrangler d1 execute voom-share-db --file=./schema.sql --remote
npx wrangler d1 execute voom-share-db --file=./migrations/0002_share_enhancements.sql --remote
npx wrangler secret put API_SECRET
npx wrangler deploy
```

Then in the app: Settings → Cloud Sharing → paste your Worker URL and API secret.

### Cloudflare Free Tier

Cloud sharing runs entirely within Cloudflare's free tier:

| Service | What Voom uses it for | Free tier |
|---------|----------------------|-----------|
| Workers | API + share page | 100,000 requests/day |
| R2 | Video file storage | 10 GB + zero egress |
| D1 | Metadata, transcripts, comments | 5 GB + 5M reads/day |
| Cron Triggers | Daily expiry cleanup | Included |

No credit card required. You'd only need a paid plan ($5/mo) if you exceed these limits.

## Share Page

Each shared recording gets a minimal dark page with:
- Video player with range-request seeking
- Live captions (CC toggle)
- Clickable synced transcript
- Emoji reactions at timestamps
- Timestamped comments
- Optional password protection
- Optional CTA button overlay

## Voom vs Loom

| | Voom | Loom |
|---|---|---|
| **Price** | Free, forever (including cloud sharing) | $15/user/month (Business) |
| **App size** | ~5 MB | ~200 MB |
| **Privacy** | Recordings stay on your Mac. Cloud sharing is opt-in to your own infra | All recordings uploaded to Loom servers |
| **Transcription** | On-device via WhisperKit — nothing leaves your machine | Cloud-based |
| **Screen + cam + mic** | Yes | Yes |
| **Camera-only mode** | Yes | Yes |
| **Region selection** | Yes | Yes |
| **Drawing tools** | Yes | Yes (paid) |
| **Trim / cut / stitch** | Yes | Trim only (paid) |
| **Filler word removal** | Yes | Yes (paid) |
| **Share via link** | Yes (self-hosted on Cloudflare) | Yes (Loom-hosted) |
| **Synced transcript** | Yes | Yes |
| **Comments & reactions** | Yes | Yes |
| **Password protection** | Yes | Yes (paid) |
| **Link expiry** | 30 days (configurable) | Never (paid), 5 min (free) |
| **Recording limit** | Unlimited, any length | 5 min (free), 45 min (business) |
| **Storage limit** | Your disk + your R2 bucket | 25 videos (free) |
| **Open source** | Yes (MIT) | No |
| **Custom branding** | Fork it, it's yours | Enterprise plan only |
| **Electron** | No — native Swift/SwiftUI | Yes |
| **Dependencies** | WhisperKit | Electron, ffmpeg, many more |
| **Offline recording** | Yes | No |
| **Platform** | macOS | macOS, Windows, Chrome, iOS, Android |

## Stack

| Component | Technology |
|-----------|-----------|
| App | Swift, SwiftUI, ScreenCaptureKit, AVFoundation |
| Encoding | HEVC (VideoToolbox hardware encoder) |
| Transcription | WhisperKit (on-device, Apple Silicon) |
| Storage | Cloudflare R2 |
| Database | Cloudflare D1 (SQLite) |
| API + Share Page | Cloudflare Workers |

## License

MIT
