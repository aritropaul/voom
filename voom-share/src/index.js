const SHARE_CODE_CHARS = 'abcdefghjkmnpqrstuvwxyz23456789';
const SHARE_CODE_LENGTH = 10;
const EXPIRY_DAYS = 30;

function generateShareCode() {
  const bytes = new Uint8Array(SHARE_CODE_LENGTH);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, b => SHARE_CODE_CHARS[b % SHARE_CODE_CHARS.length]).join('');
}

function isAuthorized(request, env) {
  const auth = request.headers.get('Authorization');
  if (!auth) return false;
  const [scheme, token] = auth.split(' ');
  return scheme === 'Bearer' && token === env.API_SECRET;
}

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function errorResponse(message, status = 400) {
  return jsonResponse({ error: message }, status);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // API routes (authenticated)
    if (path.startsWith('/api/')) {
      if (request.method === 'OPTIONS') {
        return new Response(null, {
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
            'Access-Control-Allow-Headers': 'Authorization, Content-Type',
          },
        });
      }

      if (!isAuthorized(request, env)) {
        return errorResponse('Unauthorized', 401);
      }

      if (path === '/api/upload' && request.method === 'POST') {
        return handleUpload(request, env);
      }

      const uploadDataMatch = path.match(/^\/api\/upload-data\/([a-z0-9]+)$/);
      if (uploadDataMatch && request.method === 'PUT') {
        return handleUploadData(request, env, uploadDataMatch[1]);
      }

      const metadataMatch = path.match(/^\/api\/metadata\/([a-z0-9]+)$/);
      if (metadataMatch && request.method === 'POST') {
        return handleMetadata(request, env, metadataMatch[1]);
      }

      const renewMatch = path.match(/^\/api\/renew\/([a-z0-9]+)$/);
      if (renewMatch && request.method === 'POST') {
        return handleRenew(env, renewMatch[1]);
      }

      const deleteMatch = path.match(/^\/api\/delete\/([a-z0-9]+)$/);
      if (deleteMatch && request.method === 'DELETE') {
        return handleDelete(env, deleteMatch[1]);
      }

      return errorResponse('Not found', 404);
    }

    // Share page
    const shareMatch = path.match(/^\/s\/([a-z0-9]+)$/);
    if (shareMatch && request.method === 'GET') {
      return handleSharePage(env, shareMatch[1]);
    }

    // Video streaming
    const videoMatch = path.match(/^\/v\/([a-z0-9]+)$/);
    if (videoMatch && request.method === 'GET') {
      return handleVideoStream(request, env, videoMatch[1]);
    }

    // OG image
    const ogMatch = path.match(/^\/og\/([a-z0-9]+)$/);
    if (ogMatch && request.method === 'GET') {
      return handleOGImage(env, ogMatch[1]);
    }

    if (path === '/') {
      return new Response('Voom Share', { status: 200 });
    }

    return errorResponse('Not found', 404);
  },

  async scheduled(event, env) {
    await cleanupExpired(env);
  },
};

// --- API Handlers ---

async function handleUpload(request, env) {
  const body = await request.json();
  const { title, duration, width, height, hasWebcam, fileSize } = body;

  if (!title) return errorResponse('title is required');

  const shareCode = generateShareCode();
  const expiresAt = new Date(Date.now() + EXPIRY_DAYS * 24 * 60 * 60 * 1000).toISOString();

  await env.DB.prepare(
    `INSERT INTO videos (share_code, title, duration, width, height, has_webcam, file_size, expires_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  )
    .bind(shareCode, title, duration || 0, width || 0, height || 0, hasWebcam ? 1 : 0, fileSize || 0, expiresAt)
    .run();

  const baseUrl = new URL(request.url).origin;

  return jsonResponse({
    shareCode,
    uploadURL: `${baseUrl}/api/upload-data/${shareCode}`,
    shareURL: `${baseUrl}/s/${shareCode}`,
    expiresAt,
  });
}

async function handleUploadData(request, env, shareCode) {
  const video = await env.DB.prepare('SELECT id FROM videos WHERE share_code = ?').bind(shareCode).first();
  if (!video) return errorResponse('Video not found', 404);

  const contentType = request.headers.get('Content-Type') || 'video/mp4';

  await env.VIDEOS_BUCKET.put(`videos/${shareCode}.mp4`, request.body, {
    httpMetadata: { contentType },
  });

  return jsonResponse({ ok: true });
}

async function handleMetadata(request, env, shareCode) {
  const video = await env.DB.prepare('SELECT id FROM videos WHERE share_code = ?').bind(shareCode).first();
  if (!video) return errorResponse('Video not found', 404);

  const body = await request.json();
  const { segments } = body;

  if (segments && segments.length > 0) {
    const stmt = env.DB.prepare(
      'INSERT INTO transcript_segments (video_id, start_time, end_time, text) VALUES (?, ?, ?, ?)'
    );
    const batch = segments.map(seg => stmt.bind(video.id, seg.startTime, seg.endTime, seg.text));
    await env.DB.batch(batch);
  }

  await env.DB.prepare('UPDATE videos SET upload_completed = 1 WHERE share_code = ?').bind(shareCode).run();

  return jsonResponse({ ok: true });
}

async function handleRenew(env, shareCode) {
  const newExpiry = new Date(Date.now() + EXPIRY_DAYS * 24 * 60 * 60 * 1000).toISOString();

  const result = await env.DB.prepare('UPDATE videos SET expires_at = ? WHERE share_code = ?')
    .bind(newExpiry, shareCode)
    .run();

  if (result.meta.changes === 0) return errorResponse('Video not found', 404);

  return jsonResponse({ expiresAt: newExpiry });
}

async function handleDelete(env, shareCode) {
  const video = await env.DB.prepare('SELECT id FROM videos WHERE share_code = ?').bind(shareCode).first();
  if (!video) return errorResponse('Video not found', 404);

  await env.VIDEOS_BUCKET.delete(`videos/${shareCode}.mp4`);
  await env.DB.prepare('DELETE FROM transcript_segments WHERE video_id = ?').bind(video.id).run();
  await env.DB.prepare('DELETE FROM videos WHERE id = ?').bind(video.id).run();

  return jsonResponse({ ok: true });
}

// --- Video Streaming ---

async function handleVideoStream(request, env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT * FROM videos WHERE share_code = ? AND upload_completed = 1 AND datetime(expires_at) > datetime('now')"
  )
    .bind(shareCode)
    .first();

  if (!video) return new Response('Not found', { status: 404 });

  const key = `videos/${shareCode}.mp4`;
  const rangeHeader = request.headers.get('Range');

  let object;
  if (rangeHeader) {
    const match = rangeHeader.match(/bytes=(\d+)-(\d*)/);
    if (match) {
      const start = parseInt(match[1], 10);
      const end = match[2] ? parseInt(match[2], 10) : undefined;
      object = await env.VIDEOS_BUCKET.get(key, {
        range: { offset: start, length: end !== undefined ? end - start + 1 : undefined },
      });

      if (!object) return new Response('Not found', { status: 404 });

      const totalSize = object.size;
      const actualEnd = end !== undefined ? end : totalSize - 1;

      return new Response(object.body, {
        status: 206,
        headers: {
          'Content-Type': 'video/mp4',
          'Content-Range': `bytes ${start}-${actualEnd}/${totalSize}`,
          'Content-Length': String(actualEnd - start + 1),
          'Accept-Ranges': 'bytes',
          'Cache-Control': 'public, max-age=3600',
        },
      });
    }
  }

  object = await env.VIDEOS_BUCKET.get(key);
  if (!object) return new Response('Not found', { status: 404 });

  return new Response(object.body, {
    status: 200,
    headers: {
      'Content-Type': 'video/mp4',
      'Content-Length': String(object.size),
      'Accept-Ranges': 'bytes',
      'Cache-Control': 'public, max-age=3600',
    },
  });
}

// --- Share Page ---

async function handleSharePage(env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT * FROM videos WHERE share_code = ? AND upload_completed = 1"
  )
    .bind(shareCode)
    .first();

  if (!video) {
    return new Response(expiredPageHTML(), {
      status: 404,
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  }

  const isExpired = new Date(video.expires_at + 'Z') < new Date();
  if (isExpired) {
    return new Response(expiredPageHTML(), {
      status: 404,
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  }

  // Increment view count
  await env.DB.prepare('UPDATE videos SET view_count = view_count + 1 WHERE id = ?').bind(video.id).run();

  const segments = await env.DB.prepare(
    'SELECT start_time, end_time, text FROM transcript_segments WHERE video_id = ? ORDER BY start_time'
  )
    .bind(video.id)
    .all();

  const viewCount = (video.view_count || 0) + 1;
  const html = sharePageHTML(video, segments.results || [], shareCode, viewCount);
  return new Response(html, {
    status: 200,
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' },
  });
}

// --- Cron Cleanup ---

async function cleanupExpired(env) {
  const expired = await env.DB.prepare(
    "SELECT id, share_code FROM videos WHERE datetime(expires_at) < datetime('now')"
  ).all();

  for (const video of expired.results || []) {
    await env.VIDEOS_BUCKET.delete(`videos/${video.share_code}.mp4`);
    await env.DB.prepare('DELETE FROM transcript_segments WHERE video_id = ?').bind(video.id).run();
    await env.DB.prepare('DELETE FROM videos WHERE id = ?').bind(video.id).run();
  }
}

// --- OG Image ---

async function handleOGImage(env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT * FROM videos WHERE share_code = ? AND upload_completed = 1 AND datetime(expires_at) > datetime('now')"
  )
    .bind(shareCode)
    .first();

  if (!video) return new Response('Not found', { status: 404 });

  const duration = formatDuration(video.duration);
  const date = formatDate(video.created_at);
  const title = video.title.length > 60 ? video.title.substring(0, 57) + '...' : video.title;
  const res = video.width > 0 ? `${video.width}×${video.height}` : '';

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <rect width="1200" height="630" fill="#000"/>
  <rect x="100" y="140" width="1000" height="350" rx="16" fill="#111" stroke="rgba(255,255,255,0.08)" stroke-width="1"/>
  <circle cx="600" cy="290" r="40" fill="rgba(255,255,255,0.06)"/>
  <polygon points="590,270 590,310 620,290" fill="rgba(255,255,255,0.3)"/>
  <text x="600" y="400" text-anchor="middle" fill="#e5e5e5" font-family="-apple-system,BlinkMacSystemFont,sans-serif" font-size="22" font-weight="500">${escapeHTML(title)}</text>
  <text x="600" y="440" text-anchor="middle" fill="#888" font-family="monospace" font-size="13" letter-spacing="1">${duration}  ·  ${date}${res ? '  ·  ' + res : ''}</text>
  <text x="600" y="570" text-anchor="middle" fill="#444" font-family="-apple-system,BlinkMacSystemFont,sans-serif" font-size="14" font-weight="500" letter-spacing="2">VOOM</text>
</svg>`;

  return new Response(svg, {
    status: 200,
    headers: {
      'Content-Type': 'image/svg+xml',
      'Cache-Control': 'public, max-age=86400',
    },
  });
}

// --- HTML Templates ---

function formatDuration(seconds) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  return `${m}:${String(s).padStart(2, '0')}`;
}

function formatDate(isoString) {
  const d = new Date(isoString + 'Z');
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

function formatTimestamp(seconds) {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${String(s).padStart(2, '0')}`;
}

function escapeHTML(str) {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function sharePageHTML(video, segments, shareCode, viewCount) {
  const segmentsJSON = JSON.stringify(
    segments.map(s => ({ start: s.start_time, end: s.end_time, text: s.text }))
  );

  const segmentsHTML = segments
    .map(
      s => `
      <div class="transcript-row" data-start="${s.start_time}">
        <span class="timestamp">${formatTimestamp(s.start_time)}</span>
        <span class="text">${escapeHTML(s.text)}</span>
        <button class="copy-ts" title="Copy link to this timestamp" data-time="${s.start_time}">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>
        </button>
      </div>`
    )
    .join('');

  const viewCountStr = viewCount === 1 ? '1 view' : `${viewCount.toLocaleString()} views`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHTML(video.title)} — Voom</title>
<meta property="og:title" content="${escapeHTML(video.title)}">
<meta property="og:type" content="video.other">
<meta property="og:video" content="/v/${shareCode}">
<meta property="og:video:type" content="video/mp4">
<meta property="og:video:width" content="${video.width}">
<meta property="og:video:height" content="${video.height}">
<meta property="og:image" content="/og/${shareCode}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${escapeHTML(video.title)}">
<meta name="twitter:image" content="/og/${shareCode}">
<style>
:root{--bg:#000;--text-main:#e5e5e5;--text-muted:#888;--accent:#fff;--space-xs:12px;--space-s:24px;--space-m:48px;--font-sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;--font-mono:"SF Mono",Monaco,ui-monospace,monospace}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent;margin:0;padding:0}
body{background:var(--bg);color:var(--text-main);font-family:var(--font-sans);-webkit-font-smoothing:antialiased}

.container{max-width:800px;margin:0 auto;padding:var(--space-m) var(--space-s);display:flex;flex-direction:column;gap:var(--space-m);min-height:100vh;justify-content:center}

/* Player */
.player-section{width:100%;border-radius:12px;position:relative;overflow:hidden;background:#050505;border:1px solid rgba(255,255,255,.08);box-shadow:0 8px 32px rgba(0,0,0,.4),0 2px 8px rgba(0,0,0,.3);cursor:pointer}
video{display:block;width:100%;background:#000}

/* Big center play button */
.big-play{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);width:72px;height:72px;border-radius:50%;background:rgba(0,0,0,.55);-webkit-backdrop-filter:blur(12px);backdrop-filter:blur(12px);border:1px solid rgba(255,255,255,.15);display:flex;align-items:center;justify-content:center;pointer-events:none;opacity:1;transition:opacity .2s,transform .15s;z-index:3}
.big-play svg{margin-left:4px}
.player-section.playing .big-play{opacity:0;pointer-events:none}
.player-section:hover .big-play{opacity:1}
.player-section.playing:hover .big-play{opacity:0}
.player-section.hide-cursor{cursor:none}

/* Always-visible bottom progress bar — z-index below controls so it hides when controls visible */
.progress-bar-bottom{position:absolute;bottom:0;left:0;right:0;height:3px;background:rgba(255,255,255,.1);z-index:3;pointer-events:none}
.progress-bar-bottom .fill{height:100%;background:var(--text-main);width:0%;transition:width .1s linear}

/* Control bar */
.controls{position:absolute;bottom:0;left:0;right:0;padding:0 12px 8px;display:flex;align-items:center;gap:8px;background:linear-gradient(transparent,rgba(0,0,0,.7) 40%,rgba(0,0,0,.85));-webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px);opacity:0;transition:opacity .25s;z-index:4;pointer-events:none}
.controls.visible{opacity:1;pointer-events:auto}
.controls button{background:none;border:none;color:rgba(255,255,255,.85);cursor:pointer;padding:6px;display:flex;align-items:center;justify-content:center;border-radius:4px;transition:color .15s}
.controls button:hover{color:#fff}

/* Seekbar */
.seekbar-container{flex:1;display:flex;align-items:center;height:32px;position:relative;cursor:pointer}
.seekbar-track{width:100%;height:4px;background:rgba(255,255,255,.15);border-radius:2px;position:relative;transition:height .15s}
.seekbar-container:hover .seekbar-track{height:6px}
.seekbar-buffered{position:absolute;top:0;left:0;height:100%;background:rgba(255,255,255,.2);border-radius:2px}
.seekbar-fill{position:absolute;top:0;left:0;height:100%;background:#fff;border-radius:2px}
.seekbar-thumb{position:absolute;top:50%;width:14px;height:14px;border-radius:50%;background:#fff;transform:translate(-50%,-50%);opacity:0;transition:opacity .15s;box-shadow:0 1px 4px rgba(0,0,0,.4)}
.seekbar-container:hover .seekbar-thumb{opacity:1}

/* Time display */
.time-display{font-family:var(--font-mono);font-size:11px;color:rgba(255,255,255,.7);white-space:nowrap;user-select:none}

/* Volume */
.volume-group{display:flex;align-items:center;gap:2px}
.volume-slider{width:0;overflow:hidden;transition:width .2s;display:flex;align-items:center}
.volume-group:hover .volume-slider{width:60px}
.volume-slider input[type=range]{width:56px;height:4px;-webkit-appearance:none;appearance:none;background:rgba(255,255,255,.2);border-radius:2px;outline:none;cursor:pointer}
.volume-slider input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:12px;height:12px;border-radius:50%;background:#fff;cursor:pointer}

/* Speed selector */
.speed-btn{font-family:var(--font-mono);font-size:11px;min-width:32px;position:relative}
.speed-menu{position:absolute;bottom:100%;left:50%;transform:translateX(-50%);background:rgba(20,20,20,.95);-webkit-backdrop-filter:blur(16px);backdrop-filter:blur(16px);border:1px solid rgba(255,255,255,.1);border-radius:8px;padding:4px 0;display:none;flex-direction:column;min-width:64px;margin-bottom:8px}
.speed-menu.open{display:flex}
.speed-menu button{padding:6px 12px;font-family:var(--font-mono);font-size:11px;text-align:center;color:rgba(255,255,255,.7);white-space:nowrap}
.speed-menu button:hover{color:#fff;background:rgba(255,255,255,.08)}
.speed-menu button.active{color:#fff}

/* CC button in controls */
.cc-ctrl{font-size:11px;font-weight:700;letter-spacing:.5px}
.cc-ctrl.on{color:#fff;text-decoration:underline;text-underline-offset:3px}

/* Captions */
.caption-overlay{position:absolute;bottom:56px;left:0;right:0;text-align:center;pointer-events:none;padding:0 10%;transition:opacity .2s;z-index:3}
.caption-overlay span{display:inline-block;padding:6px 16px;border-radius:6px;background:rgba(0,0,0,.7);-webkit-backdrop-filter:blur(16px);backdrop-filter:blur(16px);color:#fff;font-size:15px;font-weight:500;line-height:1.4}
.caption-overlay.hidden{opacity:0}

/* Metadata */
.metadata{display:flex;flex-direction:column;gap:var(--space-xs)}
.meta-row{display:flex;align-items:center;justify-content:space-between;gap:var(--space-s)}
.stats{display:flex;gap:var(--space-s);font-family:var(--font-mono);font-size:11px;color:var(--text-muted);text-transform:uppercase;letter-spacing:1px;flex-wrap:wrap}
h1{font-size:17px;font-weight:500;line-height:1.3;letter-spacing:-.01em}
.copy-link-btn{display:inline-flex;align-items:center;gap:6px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);border-radius:6px;padding:5px 12px;color:var(--text-muted);font-family:var(--font-mono);font-size:11px;cursor:pointer;transition:all .15s;white-space:nowrap;text-transform:uppercase;letter-spacing:1px}
.copy-link-btn:hover{background:rgba(255,255,255,.1);color:var(--text-main)}

/* Transcript */
.transcript-section{display:flex;flex-direction:column;gap:var(--space-s)}
.section-header{padding-bottom:var(--space-xs)}
.label{font-family:var(--font-mono);font-size:11px;text-transform:uppercase;letter-spacing:2px;color:var(--text-muted)}
.transcript-list{display:flex;flex-direction:column;gap:var(--space-s);max-height:480px;overflow-y:auto}
.transcript-row{display:grid;grid-template-columns:60px 1fr 28px;align-items:baseline;cursor:pointer;padding:4px 0;transition:opacity .15s;position:relative}
.transcript-row:hover .text{color:var(--text-main)}
.timestamp{font-family:var(--font-mono);font-size:11px;color:var(--text-muted)}
.text{font-size:15px;line-height:1.6;color:var(--text-muted);transition:color .2s}
.transcript-row.active .text{color:var(--text-main)}
.transcript-row.active .timestamp{color:var(--text-main)}
.copy-ts{opacity:0;background:none;border:none;color:var(--text-muted);cursor:pointer;padding:2px;transition:opacity .15s,color .15s;align-self:center}
.transcript-row:hover .copy-ts{opacity:1}
.copy-ts:hover{color:var(--text-main)}

/* Toast */
.toast{position:fixed;bottom:24px;left:50%;transform:translateX(-50%) translateY(20px);background:rgba(255,255,255,.12);-webkit-backdrop-filter:blur(16px);backdrop-filter:blur(16px);border:1px solid rgba(255,255,255,.1);color:#fff;font-family:var(--font-mono);font-size:12px;padding:8px 20px;border-radius:8px;opacity:0;transition:opacity .2s,transform .2s;pointer-events:none;z-index:100}
.toast.show{opacity:1;transform:translateX(-50%) translateY(0)}

.transcript-list::-webkit-scrollbar{width:4px}
.transcript-list::-webkit-scrollbar-track{background:transparent}
.transcript-list::-webkit-scrollbar-thumb{background:rgba(255,255,255,.08);border-radius:4px}

@media(max-width:600px){
  .container{padding:var(--space-s) 16px}
  .player-section{border-radius:10px}
  h1{font-size:20px}
  .transcript-list{max-height:360px}
  .caption-overlay{bottom:44px;padding:0 16px}
  .caption-overlay span{font-size:13px}
  .big-play{width:56px;height:56px}
  .big-play svg{width:24px;height:24px;margin-left:3px}
  .volume-group:hover .volume-slider{width:0}
  .meta-row{flex-direction:column;align-items:flex-start;gap:8px}
}
</style>
</head>
<body>
<div class="container">

  <div class="player-section" id="player-section">
    <video id="player" preload="metadata" playsinline poster="/og/${shareCode}">
      <source src="/v/${shareCode}" type="video/mp4">
    </video>
    <div class="big-play" id="big-play">
      <svg width="32" height="32" viewBox="0 0 24 24" fill="#fff"><polygon points="6,3 20,12 6,21"/></svg>
    </div>
    <div class="caption-overlay hidden" id="captions"><span></span></div>
    <div class="progress-bar-bottom" id="progress-bottom"><div class="fill" id="progress-fill"></div></div>
    <div class="controls" id="controls">
      <button id="ctrl-play" title="Play/Pause">
        <svg id="icon-play" width="20" height="20" viewBox="0 0 24 24" fill="#fff"><polygon points="6,3 20,12 6,21"/></svg>
        <svg id="icon-pause" width="20" height="20" viewBox="0 0 24 24" fill="#fff" style="display:none"><rect x="5" y="3" width="4" height="18"/><rect x="15" y="3" width="4" height="18"/></svg>
      </button>
      <span class="time-display" id="time-display">0:00 / 0:00</span>
      <div class="seekbar-container" id="seekbar">
        <div class="seekbar-track">
          <div class="seekbar-buffered" id="seekbar-buffered"></div>
          <div class="seekbar-fill" id="seekbar-fill"></div>
        </div>
        <div class="seekbar-thumb" id="seekbar-thumb"></div>
      </div>
      <div class="volume-group">
        <button id="ctrl-mute" title="Mute (M)">
          <svg id="icon-vol" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07"/></svg>
          <svg id="icon-mute" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="display:none"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><line x1="23" y1="9" x2="17" y2="15"/><line x1="17" y1="9" x2="23" y2="15"/></svg>
        </button>
        <div class="volume-slider"><input type="range" id="volume-range" min="0" max="1" step="0.05" value="1"></div>
      </div>
      <div style="position:relative">
        <button class="speed-btn" id="ctrl-speed" title="Playback speed">1x</button>
        <div class="speed-menu" id="speed-menu">
          <button data-speed="0.5">0.5x</button>
          <button data-speed="1" class="active">1x</button>
          <button data-speed="1.25">1.25x</button>
          <button data-speed="1.5">1.5x</button>
          <button data-speed="2">2x</button>
        </div>
      </div>
      ${segments.length > 0 ? '<button class="cc-ctrl on" id="cc-btn" title="Toggle captions (C)">CC</button>' : ''}
      <button id="ctrl-fs" title="Fullscreen (F)">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 3 21 3 21 9"/><polyline points="9 21 3 21 3 15"/><line x1="21" y1="3" x2="14" y2="10"/><line x1="3" y1="21" x2="10" y2="14"/></svg>
      </button>
    </div>
  </div>

  <div class="metadata">
    <div class="meta-row">
      <div class="stats">
        <span>${formatDuration(video.duration)}</span>
        <span>${viewCountStr}</span>
        <span>${formatDate(video.created_at)}</span>
        ${video.width > 0 ? `<span>${video.width} × ${video.height}</span>` : ''}
      </div>
      <button class="copy-link-btn" id="copy-link-btn">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>
        Copy link
      </button>
    </div>
    <h1>${escapeHTML(video.title)}</h1>
  </div>

  ${segments.length > 0 ? `
  <div class="transcript-section">
    <div class="section-header">
      <span class="label">Transcript</span>
    </div>
    <div class="transcript-list" id="transcript-list">${segmentsHTML}</div>
  </div>` : ''}

</div>
<div class="toast" id="toast">Copied!</div>
<script>
(function(){
const vid=document.getElementById('player');
const section=document.getElementById('player-section');
const bigPlay=document.getElementById('big-play');
const controls=document.getElementById('controls');
const cap=document.getElementById('captions');
const capSpan=cap?cap.querySelector('span'):null;
const ccBtn=document.getElementById('cc-btn');
const segs=${segmentsJSON};
const rows=document.querySelectorAll('.transcript-row');
let ccOn=${segments.length > 0 ? 'true' : 'false'};

/* --- Toast --- */
const toastEl=document.getElementById('toast');
let toastTimer=null;
function showToast(msg){
  toastEl.textContent=msg||'Copied!';
  toastEl.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer=setTimeout(()=>toastEl.classList.remove('show'),1800);
}

/* --- Play/Pause --- */
const iconPlay=document.getElementById('icon-play');
const iconPause=document.getElementById('icon-pause');
function togglePlay(){if(vid.paused){vid.play()}else{vid.pause()}}

section.addEventListener('click',(e)=>{
  if(e.target.closest('.controls')||e.target.closest('button'))return;
  togglePlay();
});

function updatePlayState(){
  const playing=!vid.paused;
  section.classList.toggle('playing',playing);
  iconPlay.style.display=playing?'none':'block';
  iconPause.style.display=playing?'block':'none';
}
vid.addEventListener('play',updatePlayState);
vid.addEventListener('pause',updatePlayState);
document.getElementById('ctrl-play').addEventListener('click',(e)=>{e.stopPropagation();togglePlay()});

/* --- Controls visibility --- */
let hideTimer=null;
function showControls(){
  controls.classList.add('visible');
  section.classList.remove('hide-cursor');
  clearTimeout(hideTimer);
  if(!vid.paused){
    hideTimer=setTimeout(()=>{
      controls.classList.remove('visible');
      section.classList.add('hide-cursor');
    },2000);
  }
}
section.addEventListener('mousemove',showControls);
section.addEventListener('mouseleave',()=>{
  if(!vid.paused){
    clearTimeout(hideTimer);
    hideTimer=setTimeout(()=>{
      controls.classList.remove('visible');
      section.classList.add('hide-cursor');
    },500);
  }
});
vid.addEventListener('pause',()=>{controls.classList.add('visible');section.classList.remove('hide-cursor')});
vid.addEventListener('play',()=>{showControls()});
/* Show controls initially */
controls.classList.add('visible');

/* --- Time + Progress --- */
const timeDisplay=document.getElementById('time-display');
const progressFill=document.getElementById('progress-fill');
const seekbarFill=document.getElementById('seekbar-fill');
const seekbarBuffered=document.getElementById('seekbar-buffered');
const seekbarThumb=document.getElementById('seekbar-thumb');

function fmtTime(s){
  s=Math.floor(s||0);
  const m=Math.floor(s/60);const sec=s%60;
  return m+':'+String(sec).padStart(2,'0');
}

vid.addEventListener('loadedmetadata',()=>{
  timeDisplay.textContent=fmtTime(0)+' / '+fmtTime(vid.duration);
  /* Handle ?t= param */
  const params=new URLSearchParams(window.location.search);
  const t=parseFloat(params.get('t'));
  if(t>0&&t<vid.duration){vid.currentTime=t}
});

vid.addEventListener('timeupdate',()=>{
  const t=vid.currentTime;
  const d=vid.duration||1;
  const pct=(t/d)*100;
  progressFill.style.width=pct+'%';
  seekbarFill.style.width=pct+'%';
  seekbarThumb.style.left=pct+'%';
  timeDisplay.textContent=fmtTime(t)+' / '+fmtTime(d);

  /* Captions + transcript highlight */
  let found=false;
  rows.forEach((el,i)=>{
    if(!segs[i])return;
    const s=segs[i];
    const active=t>=s.start&&t<s.end;
    el.classList.toggle('active',active);
    if(active){
      el.scrollIntoView({block:'nearest',behavior:'smooth'});
      if(capSpan&&ccOn){capSpan.textContent=s.text;cap.classList.remove('hidden');found=true}
    }
  });
  if(!found&&capSpan){cap.classList.add('hidden')}
});

vid.addEventListener('progress',()=>{
  if(vid.buffered.length>0){
    const buffEnd=vid.buffered.end(vid.buffered.length-1);
    seekbarBuffered.style.width=(buffEnd/(vid.duration||1))*100+'%';
  }
});

/* --- Seekbar --- */
const seekbar=document.getElementById('seekbar');
let seeking=false;
function seekFromEvent(e){
  const rect=seekbar.getBoundingClientRect();
  const pct=Math.max(0,Math.min(1,(e.clientX-rect.left)/rect.width));
  vid.currentTime=pct*(vid.duration||0);
}
seekbar.addEventListener('mousedown',(e)=>{e.stopPropagation();seeking=true;seekFromEvent(e)});
document.addEventListener('mousemove',(e)=>{if(seeking)seekFromEvent(e)});
document.addEventListener('mouseup',()=>{seeking=false});
/* Touch seek */
seekbar.addEventListener('touchstart',(e)=>{e.stopPropagation();seeking=true;seekFromEvent(e.touches[0])},{passive:true});
document.addEventListener('touchmove',(e)=>{if(seeking)seekFromEvent(e.touches[0])},{passive:true});
document.addEventListener('touchend',()=>{seeking=false});

/* --- Volume --- */
const volRange=document.getElementById('volume-range');
const iconVol=document.getElementById('icon-vol');
const iconMute=document.getElementById('icon-mute');
let savedVol=1;
function updateVolIcons(){
  const muted=vid.muted||vid.volume===0;
  iconVol.style.display=muted?'none':'block';
  iconMute.style.display=muted?'block':'none';
}
document.getElementById('ctrl-mute').addEventListener('click',(e)=>{
  e.stopPropagation();
  if(vid.muted||vid.volume===0){vid.muted=false;vid.volume=savedVol||1;volRange.value=vid.volume}
  else{savedVol=vid.volume;vid.muted=true;volRange.value=0}
  updateVolIcons();
});
volRange.addEventListener('input',(e)=>{
  e.stopPropagation();
  vid.volume=parseFloat(volRange.value);
  vid.muted=vid.volume===0;
  savedVol=vid.volume||savedVol;
  updateVolIcons();
});

/* --- Speed --- */
const speedBtn=document.getElementById('ctrl-speed');
const speedMenu=document.getElementById('speed-menu');
const speeds=[0.5,1,1.25,1.5,2];
speedBtn.addEventListener('click',(e)=>{
  e.stopPropagation();
  speedMenu.classList.toggle('open');
});
speedMenu.querySelectorAll('button').forEach(btn=>{
  btn.addEventListener('click',(e)=>{
    e.stopPropagation();
    const s=parseFloat(btn.dataset.speed);
    vid.playbackRate=s;
    speedBtn.textContent=s===1?'1x':s+'x';
    speedMenu.querySelectorAll('button').forEach(b=>b.classList.remove('active'));
    btn.classList.add('active');
    speedMenu.classList.remove('open');
  });
});
document.addEventListener('click',()=>speedMenu.classList.remove('open'));

/* --- CC toggle --- */
if(ccBtn){
  ccBtn.addEventListener('click',(e)=>{
    e.stopPropagation();
    ccOn=!ccOn;
    ccBtn.classList.toggle('on',ccOn);
    if(cap)cap.classList.toggle('hidden',!ccOn);
  });
}

/* --- Fullscreen --- */
document.getElementById('ctrl-fs').addEventListener('click',(e)=>{
  e.stopPropagation();
  if(document.fullscreenElement){document.exitFullscreen()}
  else{section.requestFullscreen().catch(()=>{})}
});

/* --- Keyboard shortcuts --- */
document.addEventListener('keydown',(e)=>{
  if(e.target.tagName==='INPUT'||e.target.tagName==='TEXTAREA')return;
  switch(e.key.toLowerCase()){
    case ' ':case 'k':e.preventDefault();togglePlay();break;
    case 'arrowleft':e.preventDefault();vid.currentTime=Math.max(0,vid.currentTime-5);break;
    case 'arrowright':e.preventDefault();vid.currentTime=Math.min(vid.duration,vid.currentTime+5);break;
    case 'm':vid.muted=!vid.muted;volRange.value=vid.muted?0:(vid.volume);updateVolIcons();break;
    case 'f':if(document.fullscreenElement){document.exitFullscreen()}else{section.requestFullscreen().catch(()=>{})};break;
    case 'c':if(ccBtn){ccOn=!ccOn;ccBtn.classList.toggle('on',ccOn);if(cap)cap.classList.toggle('hidden',!ccOn)};break;
  }
});

/* --- Transcript seek + copy timestamp --- */
function seekTo(t){vid.currentTime=t;vid.play()}
rows.forEach((el)=>{
  el.addEventListener('click',(e)=>{
    if(e.target.closest('.copy-ts'))return;
    const t=parseFloat(el.dataset.start);
    seekTo(t);
  });
});
document.querySelectorAll('.copy-ts').forEach(btn=>{
  btn.addEventListener('click',(e)=>{
    e.stopPropagation();
    const t=Math.floor(parseFloat(btn.dataset.time));
    const url=window.location.origin+window.location.pathname+'?t='+t;
    navigator.clipboard.writeText(url).then(()=>showToast('Copied!')).catch(()=>{});
  });
});

/* --- Copy link button --- */
document.getElementById('copy-link-btn').addEventListener('click',()=>{
  let url=window.location.origin+window.location.pathname;
  const t=Math.floor(vid.currentTime||0);
  if(t>0)url+='?t='+t;
  navigator.clipboard.writeText(url).then(()=>showToast('Copied!')).catch(()=>{});
});

})();
</script>
</body>
</html>`;
}

function expiredPageHTML() {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Recording Not Found — Voom</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#0a0a0a;color:rgba(255,255,255,.92);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",system-ui,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;-webkit-font-smoothing:antialiased}
.card{text-align:center;padding:48px;max-width:400px}
.icon{font-size:48px;margin-bottom:16px;opacity:.3}
h1{font-size:20px;font-weight:600;margin-bottom:8px}
p{font-size:14px;color:rgba(255,255,255,.45);line-height:1.6}
</style>
</head>
<body>
<div class="card">
  <div class="icon">🔗</div>
  <h1>This recording has expired</h1>
  <p>The link you followed is no longer available. Shared recordings expire after 30 days.</p>
</div>
</body>
</html>`;
}
