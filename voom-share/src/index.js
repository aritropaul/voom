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

  const html = sharePageHTML(video, segments.results || [], shareCode);
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

function sharePageHTML(video, segments, shareCode) {
  const segmentsJSON = JSON.stringify(
    segments.map(s => ({ start: s.start_time, end: s.end_time, text: s.text }))
  );

  const segmentsHTML = segments
    .map(
      s => `
      <div class="transcript-row" onclick="seekTo(${s.start_time})">
        <span class="timestamp">${formatTimestamp(s.start_time)}</span>
        <span class="text">${escapeHTML(s.text)}</span>
      </div>`
    )
    .join('');

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
<style>
:root{--bg:#000;--text-main:#e5e5e5;--text-muted:#888;--accent:#fff;--space-xs:12px;--space-s:24px;--space-m:48px;--font-sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;--font-mono:"SF Mono",Monaco,ui-monospace,monospace}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent;margin:0;padding:0}
body{background:var(--bg);color:var(--text-main);font-family:var(--font-sans);-webkit-font-smoothing:antialiased}

.container{max-width:800px;margin:0 auto;padding:var(--space-m) var(--space-s);display:flex;flex-direction:column;gap:var(--space-m);min-height:100vh;justify-content:center}

/* Player */
.player-section{width:100%;border-radius:12px;position:relative;overflow:hidden;background:#050505;border:1px solid rgba(255,255,255,.08);box-shadow:0 8px 32px rgba(0,0,0,.4),0 2px 8px rgba(0,0,0,.3)}
video{display:block;width:100%;background:#000}

/* Captions */
.caption-overlay{position:absolute;bottom:56px;left:0;right:0;text-align:center;pointer-events:none;padding:0 10%;transition:opacity .2s}
.caption-overlay span{display:inline-block;padding:6px 16px;border-radius:6px;background:rgba(0,0,0,.7);-webkit-backdrop-filter:blur(16px);backdrop-filter:blur(16px);color:#fff;font-size:15px;font-weight:500;line-height:1.4}
.caption-overlay.hidden{opacity:0}
.cc-btn{position:absolute;top:12px;right:12px;width:30px;height:30px;border-radius:8px;border:none;background:rgba(255,255,255,.08);color:rgba(255,255,255,.5);font-size:11px;font-weight:700;cursor:pointer;display:flex;align-items:center;justify-content:center;transition:all .15s;z-index:2}
.cc-btn:hover{background:rgba(255,255,255,.14);color:#fff}
.cc-btn.on{background:rgba(255,255,255,.18);color:#fff}

/* Metadata */
.metadata{display:flex;flex-direction:column;gap:var(--space-xs)}
.stats{display:flex;gap:var(--space-s);font-family:var(--font-mono);font-size:11px;color:var(--text-muted);text-transform:uppercase;letter-spacing:1px}
h1{font-size:17px;font-weight:500;line-height:1.3;letter-spacing:-.01em}

/* Transcript */
.transcript-section{display:flex;flex-direction:column;gap:var(--space-s)}
.section-header{padding-bottom:var(--space-xs)}
.label{font-family:var(--font-mono);font-size:11px;text-transform:uppercase;letter-spacing:2px;color:var(--text-muted)}
.transcript-list{display:flex;flex-direction:column;gap:var(--space-s);max-height:480px;overflow-y:auto}
.transcript-row{display:grid;grid-template-columns:60px 1fr;align-items:baseline;cursor:pointer;padding:4px 0;transition:opacity .15s}
.transcript-row:hover .text{color:var(--text-main)}
.timestamp{font-family:var(--font-mono);font-size:11px;color:var(--text-muted)}
.text{font-size:15px;line-height:1.6;color:var(--text-muted);transition:color .2s}
.transcript-row.active .text{color:var(--text-main)}
.transcript-row.active .timestamp{color:var(--text-main)}

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
}
</style>
</head>
<body>
<div class="container">

  <div class="player-section">
    <video id="player" controls controlsList="nodownload" oncontextmenu="return false" preload="metadata" playsinline>
      <source src="/v/${shareCode}" type="video/mp4">
    </video>
    <div class="caption-overlay hidden" id="captions"><span></span></div>
    ${segments.length > 0 ? '<button class="cc-btn" id="cc-btn" title="Toggle captions">CC</button>' : ''}
  </div>

  <div class="metadata">
    <div class="stats">
      <span>${formatDuration(video.duration)}</span>
      <span>${formatDate(video.created_at)}</span>
      ${video.width > 0 ? `<span>${video.width} × ${video.height}</span>` : ''}
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
<script>
const vid=document.getElementById('player');
const cap=document.getElementById('captions');
const capSpan=cap?cap.querySelector('span'):null;
const ccBtn=document.getElementById('cc-btn');
const segs=${segmentsJSON};
const rows=document.querySelectorAll('.transcript-row');
let ccOn=${segments.length > 0 ? 'true' : 'false'};

if(ccBtn){
  ccBtn.classList.toggle('on',ccOn);
  if(ccOn&&cap)cap.classList.remove('hidden');
  ccBtn.addEventListener('click',()=>{
    ccOn=!ccOn;
    ccBtn.classList.toggle('on',ccOn);
    if(cap)cap.classList.toggle('hidden',!ccOn);
  });
}

function seekTo(t){vid.currentTime=t;vid.play()}

vid.addEventListener('timeupdate',()=>{
  const t=vid.currentTime;
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
