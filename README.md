<p align="center">
  <img src="icon.png" width="128" height="128" alt="Voom icon">
</p>

<h1 align="center">Voom</h1>

<p align="center">Open-source Loom alternative for macOS. Record your screen, camera, and mic — get a shareable link in seconds.</p>

## What it does

- **Screen recording** — capture any display at full retina resolution (HEVC)
- **Camera overlay** — picture-in-picture webcam with draggable positioning
- **System + mic audio** — record both simultaneously
- **On-device transcription** — powered by WhisperKit (distil-large-v3), fully offline
- **Share via link** — upload to your own Cloudflare infrastructure, get a clean share page with synced transcript and captions
- **30-day expiry** — links auto-expire, daily cron cleans up storage

## Architecture

```
Voom/                   macOS app (Swift, SwiftUI, ScreenCaptureKit)
voom-share/             Cloudflare Worker (R2 + D1 + Workers)
```

The app is entirely local-first. Cloud sharing is opt-in per recording and runs on your own Cloudflare account (~$0.35/month for 2-3 videos/day).

## Setup

### macOS App

Open `Voom/Voom.xcodeproj` in Xcode and build. Requires macOS 15+.

### Cloud Sharing (optional)

```bash
cd voom-share
npm install
npx wrangler login
npx wrangler r2 bucket create voom-videos
npx wrangler d1 create voom-share-db
# paste the database_id into wrangler.toml
npx wrangler d1 execute voom-share-db --file=./schema.sql --remote
npx wrangler secret put API_SECRET
npx wrangler deploy
```

Then in the app: right-click menu bar icon → Settings → paste your Worker URL and API secret.

## Share Page

Each shared recording gets a minimal dark page with:
- Video player with range-request seeking
- Live captions (CC toggle)
- Clickable synced transcript
- View-only — no download

## Voom vs Loom

| | Voom | Loom |
|---|---|---|
| **Price** | Free, forever | $15/user/month (Business) |
| **App size** | ~5 MB | ~200 MB |
| **Privacy** | Recordings stay on your Mac. Cloud sharing is opt-in to your own infra | All recordings uploaded to Loom servers |
| **Transcription** | On-device via WhisperKit — nothing leaves your machine | Cloud-based |
| **Screen + cam + mic** | Yes | Yes |
| **Share via link** | Yes (self-hosted on Cloudflare) | Yes (Loom-hosted) |
| **Synced transcript** | Yes | Yes |
| **Link expiry** | 30 days (configurable) | Never (paid), 5 min (free) |
| **Recording limit** | Unlimited, any length | 5 min (free), 45 min (business) |
| **Storage limit** | Your disk + your R2 bucket | 25 videos (free) |
| **Open source** | Yes (MIT) | No |
| **Custom branding** | Fork it, it's yours | Enterprise plan only |
| **Electron** | No — native Swift/SwiftUI | Yes |
| **Dependencies** | WhisperKit | Electron, ffmpeg, many more |
| **Offline recording** | Yes | No |
| **Platform** | macOS | macOS, Windows, Chrome, iOS, Android |

Voom doesn't try to replace every Loom feature. No comments, no reactions, no CRM integrations, no analytics dashboard. It records your screen, transcribes it locally, and gives you a link. That's it.

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
