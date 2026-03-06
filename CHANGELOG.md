# Changelog

## 3.0.0 — 2026-03-05

- Migrated from WhisperKit to FluidAudio for on-device ASR and speaker diarization.
- Split monolithic app into VoomCore, VoomApp, and VoomMeetings packages.
- Split-track speaker diarization: saves separate mic and system audio during meeting recordings for accurate speaker separation.
- "You" identification: mic audio diarized separately so the local user's segments are labeled "You" instead of a generic speaker number.
- Remote speaker separation: system audio diarized independently for cleaner multi-speaker identification without local voice interference.
- Chapters now auto-generate after transcription for both regular and meeting recordings.
- Fixed chapter generation only covering first ~2 minutes by subsampling transcript evenly across full duration.
- Fixed garbled mic audio caused by AVAudioEngine voice processing conflicting with ScreenCaptureKit audio capture.
- Speaker labels displayed in transcript view.
- Added debug mode in settings.

## 2.8.1 — 2026-03-05

- Reduced video file size ~40% with optimized HEVC compression (8 Mbps, B-frames, 4s GOP).
- Replaced AVCaptureSession mic with AVAudioEngine for microphone capture.
- AI title generation now uses full transcript instead of only the first 2 minutes.
- Improved title prompts to focus on primary work topics, ignoring small talk.
- Enhanced AI summaries to 4-8 sentences covering decisions and action items.
- Meeting recordings auto-stop immediately when camera turns off.

## 2.8.0 — 2026-03-05

- Meeting detection: auto-trigger floating panel when video calls begin.
- Full dark theme applied to share settings sheet and all modal views.
- Share sheet primary buttons now use accentRed consistently.

## 2.7.3 — 2026-03-04

- Fixed Open Graph tags to use absolute URLs for share page embeds.
- Added embed player route for share links.

## 2.7.2 — 2026-03-04

- Refined vibrancy materials and card styling across the app.

## 2.7.1 — 2026-03-04

- Added vibrancy and blur materials to app backgrounds and cards.

## 2.7.0 — 2026-03-04

- Modernized codebase with destructive action confirmations.

## 2.6.2 — 2026-03-03

- Updated docs for free tier and added support email with system info.

## 2.6.1 — 2026-03-03

- Wired up tags feature in player detail view badge row and context menu.

## 2.6.0 — 2026-03-03

- Added self-host setup wizard to deploy Cloudflare Worker from within Voom.

## 2.5.2 — 2026-03-03

- Abort stale multipart uploads on failure.
- Added R2 lifecycle cleanup for orphaned uploads.

## 2.5.1 — 2026-03-03

- Fixed header buttons not being clickable.
- Added hardened runtime entitlements.

## 2.5.0 — 2026-03-03

- Fixed notarization by re-signing Sparkle binaries with timestamps.
- Enabled hardened runtime for release builds.
- Auto-set marketing and project version from git tag in release workflow.

## 2.4.1 — 2026-03-02

- Automated Sparkle appcast generation in release workflow.

## 2.4.0 — 2026-03-02

- UI overhaul: fixed selection colors, added animations.
- Integrated Sparkle for auto-updates.

## 2.3.1 — 2026-03-02

- Fixed sidebar navigation and recording data safety.

## 2.3.0 — 2026-03-02

- Full Loom feature parity: recording modes, video editing, folder organization, share enhancements.
- Fixed OG tags on password-protected share pages.

## 2.2.1 — 2026-03-02

- Improved share page: HD thumbnails, centered layout, app icon.

## 2.2.0 — 2026-03-02

- AI-generated titles and summaries for recordings.
- Editable title and summary fields.
- Multipart upload for large recordings.
- Thumbnail Open Graph images for share links.

## 2.1.1 — 2026-03-02

- DMG now includes Applications shortcut for drag-to-install.

## 2.1.0 — 2026-03-02

- New app icon.

## 2.0.0 — 2026-03-02

- Single audio track recording with real-time mic + system audio mixing.
- Custom toast notification system replacing alert dialogs.
- Custom video controls on share page with seekbar, volume, and fullscreen.
- View counter and timestamp copy links on shared videos.
- Increased upload timeout for large recordings.
- Upfront permission requests on app launch.

## 1.0.0 — 2026-03-02

- Screen recording with webcam PiP overlay.
- System audio and microphone capture.
- On-device transcription via WhisperKit.
- Share via link (self-hosted on Cloudflare).
- Global keyboard shortcut (Cmd+Shift+R).
- Auto-transcription toggle.
- First-launch onboarding flow.
