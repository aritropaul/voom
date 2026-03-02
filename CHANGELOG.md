# Changelog

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
