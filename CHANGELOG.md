# Changelog

## 2.8.1 — 2026-03-05 (SHAME)

### Fixes
- Reduced video file size ~40% by optimizing HEVC compression (8 Mbps bitrate, B-frames enabled, 4s GOP).
- AI title generation now uses full transcript instead of only the first 2 minutes.
- Improved title prompts to focus on primary work topics, ignoring small talk.
- Enhanced summary generation with more thorough 4-8 sentence output covering decisions and action items.
- Meeting recordings auto-stop immediately when camera turns off (no more waiting for audio silence).
- Replaced AVCaptureSession mic capture with AVAudioEngine voice processing for hardware echo cancellation and noise suppression.

## 2.8.0 — 2026-03-05 (DEFAULT)

### Changes
- Meeting detection: auto-trigger floating panel when meetings begin.
- Full dark theme applied to share settings sheet and all modal views.
- Improved AI-generated titles and summaries for screen recordings.

## 2.7.3 — 2026-03-04 (SHAME)

### Fixes
- Share sheet primary buttons now use accentRed consistently.

## 2.7.2 — 2026-03-04 (SHAME)

### Fixes
- Refined vibrancy materials and card styling.

## 2.7.1 — 2026-03-04 (SHAME)

### Fixes
- Added vibrancy/blur materials to app backgrounds and cards.

## 2.7.0 — 2026-03-04 (DEFAULT)

### Changes
- Modernized codebase with destructive action confirmations.

## 2.1.1 — 2026-03-02 (SHAME)

### Fixes
- DMG now includes Applications shortcut for drag-to-install.

## 2.1.0 — 2026-03-02 (DEFAULT)

### Changes
- New app icon.
- Added icon to README.

## 2.0.0 — 2026-03-02 (PROUD)

### Highlights
- Single audio track recording with real-time mic + system audio mixing.
- Custom toast notification system replacing alert dialogs.
- Improved share page with custom video controls.

### Recording
- Mic and system audio are now mixed into a single track during recording, eliminating browser playback issues.
- Voice is prioritized over system audio when both sources are active (system audio is ducked).
- Removed post-recording audio merge step — uploads start immediately.

### UI
- New pill-shaped toast overlay for share feedback (link copied, upload success/failure, unshare).
- Toasts auto-dismiss after 2 seconds with smooth slide-in animations.
- Toolbar buttons split into separate groups with proper spacing.
- Delete button uses destructive placement for visual separation.

### Share Page
- Custom video controls with seekbar, volume, and fullscreen.
- View counter on shared videos.
- Timestamp copy links in transcript rows.

### Reliability
- Increased upload timeout (5 min request / 1 hr resource) for large recordings.
- Upfront permission requests on app launch.

## 1.0.0 — 2026-03-02

### Initial Release
- Screen recording with webcam PiP overlay.
- System audio + microphone capture.
- On-device transcription via WhisperKit (fully offline).
- Share via link (self-hosted on Cloudflare).
- Global keyboard shortcut (Cmd+Shift+R).
- Auto-transcription toggle.
- First-launch onboarding flow.
