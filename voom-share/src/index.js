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

function parseCookies(cookieStr) {
  const cookies = {};
  cookieStr.split(';').forEach(c => {
    const [key, ...val] = c.trim().split('=');
    if (key) cookies[key] = val.join('=');
  });
  return cookies;
}

async function generateAuthToken(shareCode, expiresAt, apiSecret) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw', encoder.encode(apiSecret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const sig = await crypto.subtle.sign('HMAC', key, encoder.encode(shareCode + expiresAt));
  return Array.from(new Uint8Array(sig), b => b.toString(16).padStart(2, '0')).join('');
}

async function verifyPasswordAuth(request, env, shareCode, video) {
  if (!video.password_hash) return true;
  const cookies = parseCookies(request.headers.get('Cookie') || '');
  const authToken = cookies[`voom_auth_${shareCode}`];
  if (!authToken) return false;
  const expected = await generateAuthToken(shareCode, video.expires_at, env.API_SECRET);
  return authToken === expected;
}

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

function formatVTTTime(seconds) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  const ms = Math.floor((s % 1) * 1000);
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(Math.floor(s)).padStart(2, '0')}.${String(ms).padStart(3, '0')}`;
}

function escapeHTML(str) {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function formatTimestamp(seconds) {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${String(s).padStart(2, '0')}`;
}

// --- Main Router ---

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

      const thumbnailMatch = path.match(/^\/api\/upload-thumbnail\/([a-z0-9]+)$/);
      if (thumbnailMatch && request.method === 'PUT') {
        return handleUploadThumbnail(request, env, thumbnailMatch[1]);
      }

      const multipartStartMatch = path.match(/^\/api\/upload-multipart\/([a-z0-9]+)$/);
      if (multipartStartMatch && request.method === 'POST') {
        return handleMultipartStart(request, env, multipartStartMatch[1]);
      }

      const multipartPartMatch = path.match(/^\/api\/upload-part\/([a-z0-9]+)\/(.+?)\/(\d+)$/);
      if (multipartPartMatch && request.method === 'PUT') {
        return handleMultipartPart(request, env, multipartPartMatch[1], multipartPartMatch[2], parseInt(multipartPartMatch[3], 10));
      }

      const multipartCompleteMatch = path.match(/^\/api\/upload-complete\/([a-z0-9]+)\/(.+)$/);
      if (multipartCompleteMatch && request.method === 'POST') {
        return handleMultipartComplete(request, env, multipartCompleteMatch[1], multipartCompleteMatch[2]);
      }

      const multipartAbortMatch = path.match(/^\/api\/upload-abort\/([a-z0-9]+)\/(.+)$/);
      if (multipartAbortMatch && request.method === 'POST') {
        return handleMultipartAbort(request, env, multipartAbortMatch[1], multipartAbortMatch[2]);
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

      if (path === '/api/check-views' && request.method === 'POST') {
        return handleCheckViews(request, env);
      }

      return errorResponse('Not found', 404);
    }

    // CORS preflight for public endpoints
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type',
        },
      });
    }

    // Password verification (public)
    const verifyMatch = path.match(/^\/s\/([a-z0-9]+)\/verify-password$/);
    if (verifyMatch && request.method === 'POST') {
      return handleVerifyPassword(request, env, verifyMatch[1]);
    }

    // Share data endpoint (public, for SPA)
    const dataMatch = path.match(/^\/s\/([a-z0-9]+)\/data$/);
    if (dataMatch && request.method === 'GET') {
      return handleShareData(request, env, dataMatch[1]);
    }

    // Reactions (public)
    const reactMatch = path.match(/^\/s\/([a-z0-9]+)\/react$/);
    if (reactMatch && request.method === 'POST') {
      return handleReact(request, env, reactMatch[1]);
    }
    const reactGetMatch = path.match(/^\/s\/([a-z0-9]+)\/reactions$/);
    if (reactGetMatch && request.method === 'GET') {
      return handleGetReactions(env, reactGetMatch[1]);
    }

    // Comments (public)
    const commentMatch = path.match(/^\/s\/([a-z0-9]+)\/comment$/);
    if (commentMatch && request.method === 'POST') {
      return handleComment(request, env, commentMatch[1]);
    }
    const commentGetMatch = path.match(/^\/s\/([a-z0-9]+)\/comments$/);
    if (commentGetMatch && request.method === 'GET') {
      return handleGetComments(request, env, commentGetMatch[1]);
    }

    // VTT captions
    const vttMatch = path.match(/^\/vtt\/([a-z0-9]+)$/);
    if (vttMatch && request.method === 'GET') {
      return handleVTT(request, env, vttMatch[1]);
    }

    // Share page — serve Astro SPA or OG for bots
    const shareMatch = path.match(/^\/s\/([a-z0-9]+)$/);
    if (shareMatch && request.method === 'GET') {
      const shareCode = shareMatch[1];
      const ua = request.headers.get('User-Agent') || '';
      if (/bot|crawl|spider|facebook|twitter|slack|discord|telegram|whatsapp|linkedin/i.test(ua)) {
        return handleOGPage(request, env, shareCode);
      }
      return env.ASSETS.fetch(new Request(new URL('/share', url), request));
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

    // Embed player — serve Astro embed page
    const embedMatch = path.match(/^\/embed\/([a-z0-9]+)$/);
    if (embedMatch && request.method === 'GET') {
      return env.ASSETS.fetch(new Request(new URL('/embed', url), request));
    }

    // Thumbnail (high-res poster)
    const thumbMatch = path.match(/^\/thumb\/([a-z0-9]+)$/);
    if (thumbMatch && request.method === 'GET') {
      const thumb = await env.VIDEOS_BUCKET.get(`thumbnails/${thumbMatch[1]}.jpg`);
      if (thumb) {
        return new Response(thumb.body, {
          headers: { 'Content-Type': 'image/jpeg', 'Cache-Control': 'public, max-age=86400' },
        });
      }
      return new Response('Not found', { status: 404 });
    }

    // Static assets from R2
    if (path === '/icon-64.png' && request.method === 'GET') {
      const obj = await env.VIDEOS_BUCKET.get('static/icon-64.png');
      if (obj) {
        return new Response(obj.body, {
          headers: { 'Content-Type': 'image/png', 'Cache-Control': 'public, max-age=604800' },
        });
      }
    }

    if (path === '/') {
      return new Response('Voom Share', { status: 200 });
    }

    // Fall through to static assets
    return env.ASSETS.fetch(request);
  },

  async scheduled(event, env) {
    await cleanupExpired(env);
  },
};

// --- API Handlers ---

async function handleUpload(request, env) {
  const body = await request.json();
  const { title, duration, width, height, hasWebcam, fileSize, password_hash, cta_url, cta_text } = body;

  if (!title) return errorResponse('title is required');

  const shareCode = generateShareCode();
  const expiresAt = new Date(Date.now() + EXPIRY_DAYS * 24 * 60 * 60 * 1000).toISOString();

  await env.DB.prepare(
    `INSERT INTO videos (share_code, title, duration, width, height, has_webcam, file_size, expires_at, password_hash, cta_url, cta_text)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  )
    .bind(shareCode, title, duration || 0, width || 0, height || 0, hasWebcam ? 1 : 0, fileSize || 0, expiresAt, password_hash || null, cta_url || null, cta_text || null)
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

async function handleUploadThumbnail(request, env, shareCode) {
  const video = await env.DB.prepare('SELECT id FROM videos WHERE share_code = ?').bind(shareCode).first();
  if (!video) return errorResponse('Video not found', 404);

  const contentType = request.headers.get('Content-Type') || 'image/jpeg';

  await env.VIDEOS_BUCKET.put(`thumbnails/${shareCode}.jpg`, request.body, {
    httpMetadata: { contentType },
  });

  return jsonResponse({ ok: true });
}

async function handleMultipartStart(request, env, shareCode) {
  const video = await env.DB.prepare('SELECT id FROM videos WHERE share_code = ?').bind(shareCode).first();
  if (!video) return errorResponse('Video not found', 404);

  const key = `videos/${shareCode}.mp4`;
  const multipartUpload = await env.VIDEOS_BUCKET.createMultipartUpload(key, {
    httpMetadata: { contentType: 'video/mp4' },
  });

  return jsonResponse({ uploadId: multipartUpload.uploadId });
}

async function handleMultipartPart(request, env, shareCode, uploadId, partNumber) {
  const video = await env.DB.prepare('SELECT id FROM videos WHERE share_code = ?').bind(shareCode).first();
  if (!video) return errorResponse('Video not found', 404);

  const key = `videos/${shareCode}.mp4`;
  const multipartUpload = env.VIDEOS_BUCKET.resumeMultipartUpload(key, uploadId);

  const part = await multipartUpload.uploadPart(partNumber, request.body);

  return jsonResponse({ partNumber: part.partNumber, etag: part.etag });
}

async function handleMultipartAbort(request, env, shareCode, uploadId) {
  const key = `videos/${shareCode}.mp4`;
  try {
    const multipartUpload = env.VIDEOS_BUCKET.resumeMultipartUpload(key, uploadId);
    await multipartUpload.abort();
  } catch (e) {
    // Ignore errors — upload may already be completed or expired
  }
  return jsonResponse({ ok: true });
}

async function handleMultipartComplete(request, env, shareCode, uploadId) {
  const video = await env.DB.prepare('SELECT id FROM videos WHERE share_code = ?').bind(shareCode).first();
  if (!video) return errorResponse('Video not found', 404);

  const key = `videos/${shareCode}.mp4`;
  const multipartUpload = env.VIDEOS_BUCKET.resumeMultipartUpload(key, uploadId);

  const body = await request.json();
  const parts = body.parts; // [{ partNumber, etag }, ...]

  await multipartUpload.complete(parts);

  return jsonResponse({ ok: true });
}

async function handleMetadata(request, env, shareCode) {
  const video = await env.DB.prepare('SELECT id FROM videos WHERE share_code = ?').bind(shareCode).first();
  if (!video) return errorResponse('Video not found', 404);

  const body = await request.json();
  const { segments, title, summary, chapters, isMeeting } = body;

  if (segments && segments.length > 0) {
    const stmt = env.DB.prepare(
      'INSERT INTO transcript_segments (video_id, start_time, end_time, text, speaker) VALUES (?, ?, ?, ?, ?)'
    );
    const batch = segments.map(seg => stmt.bind(video.id, seg.startTime, seg.endTime, seg.text, seg.speaker || null));
    await env.DB.batch(batch);
  }

  if (chapters && chapters.length > 0) {
    const stmt = env.DB.prepare(
      'INSERT INTO chapters (video_id, timestamp, title) VALUES (?, ?, ?)'
    );
    const batch = chapters.map(ch => stmt.bind(video.id, ch.timestamp, ch.title));
    await env.DB.batch(batch);
  }

  // Update title, summary, is_meeting, and mark upload complete
  const updateFields = ['upload_completed = 1'];
  const updateBinds = [];
  if (title) { updateFields.push('title = ?'); updateBinds.push(title); }
  if (summary !== undefined) { updateFields.push('summary = ?'); updateBinds.push(summary || null); }
  if (isMeeting !== undefined) { updateFields.push('is_meeting = ?'); updateBinds.push(isMeeting ? 1 : 0); }
  updateBinds.push(shareCode);
  await env.DB.prepare(
    `UPDATE videos SET ${updateFields.join(', ')} WHERE share_code = ?`
  ).bind(...updateBinds).run();

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
  await env.VIDEOS_BUCKET.delete(`thumbnails/${shareCode}.jpg`);
  await env.DB.prepare('DELETE FROM chapters WHERE video_id = ?').bind(video.id).run();
  await env.DB.prepare('DELETE FROM reactions WHERE video_id = ?').bind(video.id).run();
  await env.DB.prepare('DELETE FROM comments WHERE video_id = ?').bind(video.id).run();
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

  // Password protection check for video stream
  if (video.password_hash) {
    const authed = await verifyPasswordAuth(request, env, shareCode, video);
    if (!authed) return new Response('Unauthorized', { status: 401 });
  }

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
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Expose-Headers': 'Content-Range, Content-Length, Accept-Ranges',
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
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Expose-Headers': 'Content-Range, Content-Length, Accept-Ranges',
    },
  });
}

// --- VTT Captions ---

async function handleVTT(request, env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT * FROM videos WHERE share_code = ? AND upload_completed = 1 AND datetime(expires_at) > datetime('now')"
  ).bind(shareCode).first();

  if (!video) return new Response('Not found', { status: 404 });

  // Password protection check
  if (video.password_hash) {
    const authed = await verifyPasswordAuth(request, env, shareCode, video);
    if (!authed) return new Response('Unauthorized', { status: 401 });
  }

  const segments = await env.DB.prepare(
    'SELECT start_time, end_time, text, speaker FROM transcript_segments WHERE video_id = ? ORDER BY start_time'
  ).bind(video.id).all();

  let vtt = 'WEBVTT\n\n';
  (segments.results || []).forEach((seg, i) => {
    const start = formatVTTTime(seg.start_time);
    const end = formatVTTTime(seg.end_time);
    const speaker = seg.speaker ? `<v ${seg.speaker}>` : '';
    vtt += `${i + 1}\n${start} --> ${end}\n${speaker}${seg.text}\n\n`;
  });

  return new Response(vtt, {
    headers: {
      'Content-Type': 'text/vtt; charset=utf-8',
      'Cache-Control': 'public, max-age=3600',
      'Access-Control-Allow-Origin': '*',
    },
  });
}

// --- Share Data (JSON endpoint for SPA) ---

async function handleShareData(request, env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT * FROM videos WHERE share_code = ? AND upload_completed = 1"
  ).bind(shareCode).first();

  if (!video) return jsonResponse({ expired: true }, 404);

  const isExpired = new Date(video.expires_at + 'Z') < new Date();
  if (isExpired) return jsonResponse({ expired: true }, 404);

  if (video.password_hash) {
    const authed = await verifyPasswordAuth(request, env, shareCode, video);
    if (!authed) {
      return jsonResponse({ password_protected: true, title: video.title }, 401);
    }
  }

  // Increment view count
  await env.DB.prepare('UPDATE videos SET view_count = view_count + 1 WHERE id = ?').bind(video.id).run();

  const segments = await env.DB.prepare(
    'SELECT start_time, end_time, text, speaker FROM transcript_segments WHERE video_id = ? ORDER BY start_time'
  ).bind(video.id).all();

  const chapters = await env.DB.prepare(
    'SELECT timestamp, title FROM chapters WHERE video_id = ? ORDER BY timestamp'
  ).bind(video.id).all();

  return jsonResponse({
    video: {
      title: video.title,
      duration: video.duration,
      width: video.width,
      height: video.height,
      summary: video.summary,
      has_webcam: video.has_webcam,
      cta_url: video.cta_url,
      cta_text: video.cta_text,
      created_at: video.created_at,
      view_count: (video.view_count || 0) + 1,
      is_meeting: video.is_meeting,
    },
    segments: (segments.results || []),
    chapters: (chapters.results || []),
    shareCode,
  });
}

// --- OG Page (bot-only, minimal HTML with meta tags) ---

async function handleOGPage(request, env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT * FROM videos WHERE share_code = ? AND upload_completed = 1"
  ).bind(shareCode).first();

  if (!video) return new Response('Not found', { status: 404 });

  const isExpired = new Date(video.expires_at + 'Z') < new Date();
  if (isExpired) return new Response('Not found', { status: 404 });

  const baseUrl = new URL(request.url).origin;
  const desc = video.summary ? escapeHTML(video.summary) : `${formatTimestamp(video.duration)} screen recording`;

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${escapeHTML(video.title)} — Voom</title>
<meta property="og:title" content="${escapeHTML(video.title)}">
<meta property="og:type" content="video.other">
<meta property="og:url" content="${baseUrl}/s/${shareCode}">
<meta property="og:video" content="${baseUrl}/embed/${shareCode}">
<meta property="og:video:secure_url" content="${baseUrl}/embed/${shareCode}">
<meta property="og:video:type" content="text/html">
<meta property="og:video:width" content="${video.width}">
<meta property="og:video:height" content="${video.height}">
<meta property="og:image" content="${baseUrl}/og/${shareCode}">
<meta property="og:image:secure_url" content="${baseUrl}/og/${shareCode}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:site_name" content="Voom">
<meta property="og:description" content="${desc}">
<meta name="twitter:card" content="player">
<meta name="twitter:title" content="${escapeHTML(video.title)}">
<meta name="twitter:description" content="${desc}">
<meta name="twitter:image" content="${baseUrl}/og/${shareCode}">
<meta name="twitter:player" content="${baseUrl}/embed/${shareCode}">
<meta name="twitter:player:width" content="${video.width}">
<meta name="twitter:player:height" content="${video.height}">
</head>
<body>
<p>${escapeHTML(video.title)}</p>
</body>
</html>`;

  return new Response(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'public, max-age=3600' },
  });
}

// --- Cron Cleanup ---

async function cleanupExpired(env) {
  const expired = await env.DB.prepare(
    "SELECT id, share_code FROM videos WHERE datetime(expires_at) < datetime('now')"
  ).all();

  for (const video of expired.results || []) {
    await env.VIDEOS_BUCKET.delete(`videos/${video.share_code}.mp4`);
    await env.VIDEOS_BUCKET.delete(`thumbnails/${video.share_code}.jpg`);
    await env.DB.prepare('DELETE FROM chapters WHERE video_id = ?').bind(video.id).run();
    await env.DB.prepare('DELETE FROM reactions WHERE video_id = ?').bind(video.id).run();
    await env.DB.prepare('DELETE FROM comments WHERE video_id = ?').bind(video.id).run();
    await env.DB.prepare('DELETE FROM transcript_segments WHERE video_id = ?').bind(video.id).run();
    await env.DB.prepare('DELETE FROM videos WHERE id = ?').bind(video.id).run();
  }
}

// --- Password Verification ---

async function handleVerifyPassword(request, env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT * FROM videos WHERE share_code = ? AND upload_completed = 1"
  ).bind(shareCode).first();

  if (!video || !video.password_hash) return errorResponse('Not found', 404);

  const body = await request.json();
  const password = body.password || '';

  // Hash the provided password with SHA-256 and compare
  const encoder = new TextEncoder();
  const data = encoder.encode(password);
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

  if (hashHex !== video.password_hash) {
    return jsonResponse({ error: 'Incorrect password' }, 403);
  }

  // Generate HMAC token instead of using raw hash
  const authToken = await generateAuthToken(shareCode, video.expires_at, env.API_SECRET);
  const expires = new Date(video.expires_at + 'Z');

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: {
      'Content-Type': 'application/json',
      'Set-Cookie': `voom_auth_${shareCode}=${authToken}; Path=/; Expires=${expires.toUTCString()}; SameSite=Lax; Secure`,
    },
  });
}

// --- Reactions ---

async function handleReact(request, env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT id, password_hash, expires_at FROM videos WHERE share_code = ? AND upload_completed = 1 AND datetime(expires_at) > datetime('now')"
  ).bind(shareCode).first();

  if (!video) return errorResponse('Not found', 404);

  // Password check
  if (video.password_hash) {
    const authed = await verifyPasswordAuth(request, env, shareCode, video);
    if (!authed) return errorResponse('Unauthorized', 401);
  }

  const body = await request.json();
  const { timestamp, emoji } = body;
  const allowedEmojis = ['👍', '❤️', '😂', '😮', '🔥', '👏'];
  if (!allowedEmojis.includes(emoji)) return errorResponse('Invalid emoji');
  if (typeof timestamp !== 'number' || timestamp < 0) return errorResponse('Invalid timestamp');

  // Rate limit: 50 reactions per IP per video
  const clientIP = request.headers.get('CF-Connecting-IP') || 'unknown';
  const count = await env.DB.prepare(
    'SELECT COUNT(*) as cnt FROM reactions WHERE video_id = ? AND client_ip = ?'
  ).bind(video.id, clientIP).first();
  if (count && count.cnt >= 50) return errorResponse('Rate limit exceeded', 429);

  await env.DB.prepare(
    'INSERT INTO reactions (video_id, timestamp, emoji, client_ip) VALUES (?, ?, ?, ?)'
  ).bind(video.id, timestamp, emoji, clientIP).run();

  return jsonResponse({ ok: true });
}

async function handleGetReactions(env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT id FROM videos WHERE share_code = ? AND upload_completed = 1 AND datetime(expires_at) > datetime('now')"
  ).bind(shareCode).first();

  if (!video) return errorResponse('Not found', 404);

  const reactions = await env.DB.prepare(
    'SELECT timestamp, emoji, created_at FROM reactions WHERE video_id = ? ORDER BY created_at DESC LIMIT 500'
  ).bind(video.id).all();

  return jsonResponse({ reactions: reactions.results || [] });
}

// --- Comments ---

async function handleComment(request, env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT id, password_hash, expires_at FROM videos WHERE share_code = ? AND upload_completed = 1 AND datetime(expires_at) > datetime('now')"
  ).bind(shareCode).first();

  if (!video) return errorResponse('Not found', 404);

  // Password check
  if (video.password_hash) {
    const authed = await verifyPasswordAuth(request, env, shareCode, video);
    if (!authed) return errorResponse('Unauthorized', 401);
  }

  const body = await request.json();
  const { timestamp, author_name, text } = body;
  if (typeof timestamp !== 'number' || timestamp < 0) return errorResponse('Invalid timestamp');
  if (!text || text.trim().length === 0) return errorResponse('Text is required');
  if (text.length > 2000) return errorResponse('Text too long');

  // Rate limit: 5 comments per IP per 5 minutes
  const clientIP = request.headers.get('CF-Connecting-IP') || 'unknown';
  const recent = await env.DB.prepare(
    "SELECT COUNT(*) as cnt FROM comments WHERE video_id = ? AND client_ip = ? AND datetime(created_at) > datetime('now', '-5 minutes')"
  ).bind(video.id, clientIP).first();
  if (recent && recent.cnt >= 5) return errorResponse('Rate limit exceeded', 429);

  const name = (author_name || 'Anonymous').substring(0, 100);

  await env.DB.prepare(
    'INSERT INTO comments (video_id, timestamp, author_name, text, client_ip) VALUES (?, ?, ?, ?, ?)'
  ).bind(video.id, timestamp, name, text.trim().substring(0, 2000), clientIP).run();

  return jsonResponse({ ok: true });
}

async function handleGetComments(request, env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT id FROM videos WHERE share_code = ? AND upload_completed = 1 AND datetime(expires_at) > datetime('now')"
  ).bind(shareCode).first();

  if (!video) return errorResponse('Not found', 404);

  const url = new URL(request.url);
  const page = Math.max(1, parseInt(url.searchParams.get('page') || '1', 10));
  const limit = Math.min(parseInt(url.searchParams.get('limit') || '50', 10), 100);
  const offset = (page - 1) * limit;

  const total = await env.DB.prepare(
    'SELECT COUNT(*) as cnt FROM comments WHERE video_id = ?'
  ).bind(video.id).first();

  const comments = await env.DB.prepare(
    'SELECT timestamp, author_name, text, created_at FROM comments WHERE video_id = ? ORDER BY timestamp ASC LIMIT ? OFFSET ?'
  ).bind(video.id, limit, offset).all();

  return jsonResponse({
    comments: comments.results || [],
    total: total ? total.cnt : 0,
    page,
    limit,
  });
}

// --- Check Views (authenticated) ---

async function handleCheckViews(request, env) {
  const body = await request.json();
  const { shareCodes } = body;
  if (!Array.isArray(shareCodes) || shareCodes.length === 0) return errorResponse('shareCodes required');

  const placeholders = shareCodes.map(() => '?').join(',');
  const results = await env.DB.prepare(
    `SELECT share_code, view_count FROM videos WHERE share_code IN (${placeholders})`
  ).bind(...shareCodes).all();

  const views = {};
  for (const row of results.results || []) {
    views[row.share_code] = row.view_count || 0;
  }

  return jsonResponse({ views });
}

// --- OG Image ---

async function handleOGImage(env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT * FROM videos WHERE share_code = ? AND upload_completed = 1 AND datetime(expires_at) > datetime('now')"
  )
    .bind(shareCode)
    .first();

  if (!video) return new Response('Not found', { status: 404 });

  // Serve uploaded thumbnail if available
  const thumb = await env.VIDEOS_BUCKET.get(`thumbnails/${shareCode}.jpg`);
  if (thumb) {
    return new Response(thumb.body, {
      status: 200,
      headers: {
        'Content-Type': 'image/jpeg',
        'Cache-Control': 'public, max-age=86400',
      },
    });
  }

  // Fallback SVG
  const duration = formatDuration(video.duration);
  const date = formatDate(video.created_at);
  const title = video.title.length > 60 ? video.title.substring(0, 57) + '...' : video.title;
  const res = video.width > 0 ? `${video.width}\u00d7${video.height}` : '';

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <rect width="1200" height="630" fill="#000"/>
  <rect x="100" y="140" width="1000" height="350" rx="16" fill="#111" stroke="rgba(255,255,255,0.08)" stroke-width="1"/>
  <circle cx="600" cy="290" r="40" fill="rgba(255,255,255,0.06)"/>
  <polygon points="590,270 590,310 620,290" fill="rgba(255,255,255,0.3)"/>
  <text x="600" y="400" text-anchor="middle" fill="#e5e5e5" font-family="-apple-system,BlinkMacSystemFont,sans-serif" font-size="22" font-weight="500">${escapeHTML(title)}</text>
  <text x="600" y="440" text-anchor="middle" fill="#888" font-family="monospace" font-size="13" letter-spacing="1">${duration}  \u00b7  ${date}${res ? '  \u00b7  ' + res : ''}</text>
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

// --- Embed Player ---

async function handleEmbed(request, env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT * FROM videos WHERE share_code = ? AND upload_completed = 1 AND datetime(expires_at) > datetime('now')"
  )
    .bind(shareCode)
    .first();
  if (!video) return new Response('Not found', { status: 404 });

  const baseUrl = new URL(request.url).origin;
  const html = `<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<style>*{margin:0;padding:0}html,body{width:100%;height:100%;background:#000;overflow:hidden}video{width:100%;height:100%;object-fit:contain}</style>
</head><body>
<video controls autoplay playsinline poster="${baseUrl}/og/${shareCode}">
<source src="${baseUrl}/v/${shareCode}" type="video/mp4">
</video>
</body></html>`;
  return new Response(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'public, max-age=3600' },
  });
}
