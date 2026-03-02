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

    // Password verification (public)
    const verifyMatch = path.match(/^\/s\/([a-z0-9]+)\/verify-password$/);
    if (verifyMatch && request.method === 'POST') {
      return handleVerifyPassword(request, env, verifyMatch[1]);
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
      return handleGetComments(env, commentGetMatch[1]);
    }

    // Share page
    const shareMatch = path.match(/^\/s\/([a-z0-9]+)$/);
    if (shareMatch && request.method === 'GET') {
      return handleSharePage(request, env, shareMatch[1]);
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

    return errorResponse('Not found', 404);
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
  const { segments, title, summary } = body;

  if (segments && segments.length > 0) {
    const stmt = env.DB.prepare(
      'INSERT INTO transcript_segments (video_id, start_time, end_time, text) VALUES (?, ?, ?, ?)'
    );
    const batch = segments.map(seg => stmt.bind(video.id, seg.startTime, seg.endTime, seg.text));
    await env.DB.batch(batch);
  }

  // Update title, summary, and mark upload complete
  if (title || summary) {
    await env.DB.prepare(
      'UPDATE videos SET upload_completed = 1, title = COALESCE(?, title), summary = ? WHERE share_code = ?'
    ).bind(title || null, summary || null, shareCode).run();
  } else {
    await env.DB.prepare('UPDATE videos SET upload_completed = 1 WHERE share_code = ?').bind(shareCode).run();
  }

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
    const cookies = parseCookies(request.headers.get('Cookie') || '');
    if (cookies[`voom_auth_${shareCode}`] !== video.password_hash) {
      return new Response('Unauthorized', { status: 401 });
    }
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

async function handleSharePage(request, env, shareCode) {
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

  // Password protection check
  if (video.password_hash) {
    const cookies = parseCookies(request.headers.get('Cookie') || '');
    const authToken = cookies[`voom_auth_${shareCode}`];
    if (authToken !== video.password_hash) {
      return new Response(passwordPageHTML(shareCode, video.title), {
        status: 200,
        headers: { 'Content-Type': 'text/html; charset=utf-8' },
      });
    }
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
    await env.VIDEOS_BUCKET.delete(`thumbnails/${video.share_code}.jpg`);
    await env.DB.prepare('DELETE FROM reactions WHERE video_id = ?').bind(video.id).run();
    await env.DB.prepare('DELETE FROM comments WHERE video_id = ?').bind(video.id).run();
    await env.DB.prepare('DELETE FROM transcript_segments WHERE video_id = ?').bind(video.id).run();
    await env.DB.prepare('DELETE FROM videos WHERE id = ?').bind(video.id).run();
  }
}

// --- Password Verification ---

function parseCookies(cookieStr) {
  const cookies = {};
  cookieStr.split(';').forEach(c => {
    const [key, ...val] = c.trim().split('=');
    if (key) cookies[key] = val.join('=');
  });
  return cookies;
}

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

  // Set auth cookie (expires with share link)
  const expires = new Date(video.expires_at + 'Z');
  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: {
      'Content-Type': 'application/json',
      'Set-Cookie': `voom_auth_${shareCode}=${video.password_hash}; Path=/; Expires=${expires.toUTCString()}; SameSite=Lax; Secure`,
    },
  });
}

// --- Reactions ---

async function handleReact(request, env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT id, password_hash FROM videos WHERE share_code = ? AND upload_completed = 1 AND datetime(expires_at) > datetime('now')"
  ).bind(shareCode).first();

  if (!video) return errorResponse('Not found', 404);

  // Password check
  if (video.password_hash) {
    const cookies = parseCookies(request.headers.get('Cookie') || '');
    if (cookies[`voom_auth_${shareCode}`] !== video.password_hash) {
      return errorResponse('Unauthorized', 401);
    }
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
    "SELECT id, password_hash FROM videos WHERE share_code = ? AND upload_completed = 1 AND datetime(expires_at) > datetime('now')"
  ).bind(shareCode).first();

  if (!video) return errorResponse('Not found', 404);

  // Password check
  if (video.password_hash) {
    const cookies = parseCookies(request.headers.get('Cookie') || '');
    if (cookies[`voom_auth_${shareCode}`] !== video.password_hash) {
      return errorResponse('Unauthorized', 401);
    }
  }

  const body = await request.json();
  const { timestamp, author_name, text } = body;
  if (typeof timestamp !== 'number' || timestamp < 0) return errorResponse('Invalid timestamp');
  if (!text || text.trim().length === 0) return errorResponse('Text is required');
  if (text.length > 2000) return errorResponse('Text too long');

  const name = (author_name || 'Anonymous').substring(0, 100);

  await env.DB.prepare(
    'INSERT INTO comments (video_id, timestamp, author_name, text) VALUES (?, ?, ?, ?)'
  ).bind(video.id, timestamp, name, text.trim().substring(0, 2000)).run();

  return jsonResponse({ ok: true });
}

async function handleGetComments(env, shareCode) {
  const video = await env.DB.prepare(
    "SELECT id FROM videos WHERE share_code = ? AND upload_completed = 1 AND datetime(expires_at) > datetime('now')"
  ).bind(shareCode).first();

  if (!video) return errorResponse('Not found', 404);

  const comments = await env.DB.prepare(
    'SELECT timestamp, author_name, text, created_at FROM comments WHERE video_id = ? ORDER BY timestamp ASC'
  ).bind(video.id).all();

  return jsonResponse({ comments: comments.results || [] });
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
<meta property="og:description" content="${video.summary ? escapeHTML(video.summary) : ''}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${escapeHTML(video.title)}">
<meta name="twitter:description" content="${video.summary ? escapeHTML(video.summary) : ''}">
<meta name="twitter:image" content="/og/${shareCode}">
<style>
:root{--bg:#000;--text-main:#e5e5e5;--text-muted:#888;--accent:#fff;--space-xs:12px;--space-s:24px;--space-m:48px;--font-sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;--font-mono:"SF Mono",Monaco,ui-monospace,monospace}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent;margin:0;padding:0}
body{background:var(--bg);color:var(--text-main);font-family:var(--font-sans);-webkit-font-smoothing:antialiased}

.page-icon{display:flex;justify-content:center;padding:var(--space-m) 0 0}
.page-icon img{border-radius:10px}
.container{max-width:800px;margin:0 auto;padding:max(24px,calc(50vh - 340px)) var(--space-s) var(--space-m);display:flex;flex-direction:column;gap:var(--space-m);align-items:center}
.container>*{width:100%}

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
.summary{font-size:13px;line-height:1.6;color:var(--text-muted);margin-top:6px}
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

/* CTA overlay */
.cta-overlay{position:absolute;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,.85);-webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px);display:none;align-items:center;justify-content:center;flex-direction:column;gap:16px;z-index:5}
.cta-overlay.visible{display:flex}
.cta-overlay a{display:inline-flex;align-items:center;gap:8px;padding:14px 28px;background:#fff;color:#000;font-size:15px;font-weight:600;border-radius:10px;text-decoration:none;transition:opacity .15s}
.cta-overlay a:hover{opacity:.85}
.cta-replay{background:none!important;border:1px solid rgba(255,255,255,.2)!important;color:#fff!important;font-size:13px!important;padding:10px 20px!important}

/* Reactions */
.reactions-bar{display:flex;gap:6px;align-items:center;flex-wrap:wrap}
.react-btn{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.08);border-radius:20px;padding:6px 12px;font-size:16px;cursor:pointer;transition:all .15s;display:flex;align-items:center;gap:4px;color:var(--text-muted);font-family:var(--font-mono);font-size:11px}
.react-btn:hover{background:rgba(255,255,255,.12);border-color:rgba(255,255,255,.15)}
.react-btn .emoji{font-size:16px}
.react-btn .count{font-size:11px}
.reaction-bubble{position:absolute;pointer-events:none;font-size:24px;animation:floatUp 1.5s ease-out forwards;z-index:10}
@keyframes floatUp{0%{opacity:1;transform:translateY(0)}100%{opacity:0;transform:translateY(-80px)}}

/* Comments */
.comments-section{display:flex;flex-direction:column;gap:var(--space-s)}
.comment-list{display:flex;flex-direction:column;gap:16px;max-height:400px;overflow-y:auto}
.comment{display:flex;flex-direction:column;gap:4px;padding:12px;background:rgba(255,255,255,.03);border:1px solid rgba(255,255,255,.06);border-radius:8px}
.comment-header{display:flex;align-items:center;gap:8px;font-size:12px;color:var(--text-muted)}
.comment-author{font-weight:500;color:var(--text-main)}
.comment-ts{font-family:var(--font-mono);cursor:pointer;transition:color .15s}
.comment-ts:hover{color:var(--text-main)}
.comment-text{font-size:14px;line-height:1.5;color:var(--text-main)}
.comment-form{display:flex;flex-direction:column;gap:8px;padding:12px;background:rgba(255,255,255,.03);border:1px solid rgba(255,255,255,.06);border-radius:8px}
.comment-form input,.comment-form textarea{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);border-radius:6px;padding:8px 12px;color:#fff;font-size:13px;font-family:inherit;outline:none;resize:vertical}
.comment-form input:focus,.comment-form textarea:focus{border-color:rgba(255,255,255,.25)}
.comment-form textarea{min-height:60px}
.comment-form button{align-self:flex-end;padding:8px 16px;background:#fff;color:#000;border:none;border-radius:6px;font-size:12px;font-weight:600;cursor:pointer;transition:opacity .15s}
.comment-form button:hover{opacity:.85}
.comment-list::-webkit-scrollbar{width:4px}
.comment-list::-webkit-scrollbar-track{background:transparent}
.comment-list::-webkit-scrollbar-thumb{background:rgba(255,255,255,.08);border-radius:4px}

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
<div class="page-icon"><img src="/icon-64.png" width="40" height="40" alt="Voom"></div>
<div class="container">

  <div class="player-section" id="player-section">
    <video id="player" preload="metadata" playsinline poster="/thumb/${shareCode}">
      <source src="/v/${shareCode}" type="video/mp4">
    </video>
    <div class="big-play" id="big-play">
      <svg width="32" height="32" viewBox="0 0 24 24" fill="#fff"><polygon points="6,3 20,12 6,21"/></svg>
    </div>
    ${video.cta_url ? `<div class="cta-overlay" id="cta-overlay">
      <a href="${escapeHTML(video.cta_url)}" target="_blank" rel="noopener">${escapeHTML(video.cta_text || 'Learn More')}</a>
      <button class="cta-replay" id="cta-replay">Replay</button>
    </div>` : ''}
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
    ${video.summary ? `<p class="summary">${escapeHTML(video.summary)}</p>` : ''}
  </div>

  <div class="reactions-bar" id="reactions-bar">
    <button class="react-btn" data-emoji="\u{1F44D}"><span class="emoji">\u{1F44D}</span><span class="count" id="rc-0">0</span></button>
    <button class="react-btn" data-emoji="\u{2764}\u{FE0F}"><span class="emoji">\u{2764}\u{FE0F}</span><span class="count" id="rc-1">0</span></button>
    <button class="react-btn" data-emoji="\u{1F602}"><span class="emoji">\u{1F602}</span><span class="count" id="rc-2">0</span></button>
    <button class="react-btn" data-emoji="\u{1F62E}"><span class="emoji">\u{1F62E}</span><span class="count" id="rc-3">0</span></button>
    <button class="react-btn" data-emoji="\u{1F525}"><span class="emoji">\u{1F525}</span><span class="count" id="rc-4">0</span></button>
    <button class="react-btn" data-emoji="\u{1F44F}"><span class="emoji">\u{1F44F}</span><span class="count" id="rc-5">0</span></button>
  </div>

  ${segments.length > 0 ? `
  <div class="transcript-section">
    <div class="section-header">
      <span class="label">Transcript</span>
    </div>
    <div class="transcript-list" id="transcript-list">${segmentsHTML}</div>
  </div>` : ''}

  <div class="comments-section">
    <div class="section-header">
      <span class="label">Comments</span>
    </div>
    <div class="comment-list" id="comment-list"></div>
    <div class="comment-form" id="comment-form">
      <input type="text" id="comment-name" placeholder="Your name" maxlength="100">
      <textarea id="comment-text" placeholder="Add a comment..." maxlength="2000"></textarea>
      <button id="comment-submit">Post Comment</button>
    </div>
  </div>

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
      /* scroll disabled — was pulling page down to transcript */
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

/* --- CTA overlay --- */
const ctaOverlay=document.getElementById('cta-overlay');
const ctaReplay=document.getElementById('cta-replay');
if(ctaOverlay){
  vid.addEventListener('ended',()=>{ctaOverlay.classList.add('visible')});
  vid.addEventListener('play',()=>{ctaOverlay.classList.remove('visible')});
  if(ctaReplay){ctaReplay.addEventListener('click',(e)=>{e.stopPropagation();vid.currentTime=0;vid.play()})}
}

/* --- Reactions --- */
const shareCode='${shareCode}';
const emojiList=['\u{1F44D}','\u{2764}\u{FE0F}','\u{1F602}','\u{1F62E}','\u{1F525}','\u{1F44F}'];
const reactionCounts=[0,0,0,0,0,0];

function updateReactionCounts(){
  emojiList.forEach((_,i)=>{
    const el=document.getElementById('rc-'+i);
    if(el)el.textContent=reactionCounts[i]>0?reactionCounts[i]:'';
  });
}

// Load initial reactions
fetch('/s/'+shareCode+'/reactions').then(r=>r.json()).then(data=>{
  (data.reactions||[]).forEach(r=>{
    const idx=emojiList.indexOf(r.emoji);
    if(idx>=0)reactionCounts[idx]++;
  });
  updateReactionCounts();
}).catch(()=>{});

document.querySelectorAll('.react-btn').forEach(btn=>{
  btn.addEventListener('click',()=>{
    const emoji=btn.dataset.emoji;
    const t=vid.currentTime||0;
    fetch('/s/'+shareCode+'/react',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({timestamp:t,emoji:emoji})})
    .then(r=>{if(r.ok){
      const idx=emojiList.indexOf(emoji);
      if(idx>=0){reactionCounts[idx]++;updateReactionCounts()}
      // Float bubble
      const bubble=document.createElement('div');
      bubble.className='reaction-bubble';
      bubble.textContent=emoji;
      const rect=btn.getBoundingClientRect();
      bubble.style.left=rect.left+'px';
      bubble.style.top=(rect.top-10)+'px';
      document.body.appendChild(bubble);
      setTimeout(()=>bubble.remove(),1500);
    }}).catch(()=>{});
  });
});

/* --- Comments --- */
const commentList=document.getElementById('comment-list');
const commentName=document.getElementById('comment-name');
const commentText=document.getElementById('comment-text');
const commentSubmit=document.getElementById('comment-submit');

// Restore saved name
commentName.value=localStorage.getItem('voom_comment_name')||'';

function renderComment(c){
  const div=document.createElement('div');
  div.className='comment';
  const ts=Math.floor(c.timestamp);
  const m=Math.floor(ts/60);const s=ts%60;
  const timeStr=m+':'+String(s).padStart(2,'0');
  div.innerHTML='<div class="comment-header"><span class="comment-author">'+escapeHTMLJS(c.author_name)+'</span><span class="comment-ts" data-time="'+c.timestamp+'">'+timeStr+'</span></div><div class="comment-text">'+escapeHTMLJS(c.text)+'</div>';
  div.querySelector('.comment-ts').addEventListener('click',()=>{vid.currentTime=c.timestamp;vid.play()});
  return div;
}

function escapeHTMLJS(str){return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}

// Load comments
fetch('/s/'+shareCode+'/comments').then(r=>r.json()).then(data=>{
  (data.comments||[]).forEach(c=>commentList.appendChild(renderComment(c)));
}).catch(()=>{});

commentSubmit.addEventListener('click',()=>{
  const text=commentText.value.trim();
  if(!text)return;
  const name=commentName.value.trim()||'Anonymous';
  localStorage.setItem('voom_comment_name',name);
  commentSubmit.disabled=true;
  commentSubmit.textContent='Posting...';
  fetch('/s/'+shareCode+'/comment',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({timestamp:vid.currentTime||0,author_name:name,text:text})})
  .then(r=>{
    if(r.ok){
      commentList.appendChild(renderComment({timestamp:vid.currentTime||0,author_name:name,text:text}));
      commentText.value='';
      showToast('Comment posted');
    }else{showToast('Failed to post')}
    commentSubmit.disabled=false;commentSubmit.textContent='Post Comment';
  }).catch(()=>{commentSubmit.disabled=false;commentSubmit.textContent='Post Comment'});
});

})();
</script>
</body>
</html>`;
}

function passwordPageHTML(shareCode, title) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHTML(title)} — Voom</title>
<meta property="og:title" content="${escapeHTML(title)}">
<meta property="og:type" content="video.other">
<meta property="og:image" content="/og/${shareCode}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:description" content="Shared via Voom">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${escapeHTML(title)}">
<meta name="twitter:image" content="/og/${shareCode}">
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#000;color:#e5e5e5;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;-webkit-font-smoothing:antialiased}
.card{text-align:center;padding:48px;max-width:400px;width:100%}
.icon{font-size:48px;margin-bottom:24px;opacity:.5}
h1{font-size:20px;font-weight:600;margin-bottom:8px}
p{font-size:14px;color:rgba(255,255,255,.45);line-height:1.6;margin-bottom:24px}
input{width:100%;padding:12px 16px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);border-radius:8px;color:#fff;font-size:15px;outline:none;margin-bottom:12px;font-family:inherit}
input:focus{border-color:rgba(255,255,255,.25)}
button{width:100%;padding:12px;background:#fff;color:#000;border:none;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer;transition:opacity .15s}
button:hover{opacity:.85}
.error{color:#ff4444;font-size:13px;margin-bottom:12px;display:none}
</style>
</head>
<body>
<div class="card">
  <div class="icon">🔒</div>
  <h1>This recording is protected</h1>
  <p>Enter the password to view this recording.</p>
  <input type="password" id="pw" placeholder="Password" autocomplete="off" autofocus>
  <div class="error" id="error">Incorrect password. Please try again.</div>
  <button id="submit">Unlock</button>
</div>
<script>
const pw=document.getElementById('pw');
const err=document.getElementById('error');
const btn=document.getElementById('submit');
async function verify(){
  err.style.display='none';
  btn.textContent='Verifying...';
  btn.disabled=true;
  try{
    const res=await fetch('/s/${shareCode}/verify-password',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:pw.value})});
    if(res.ok){window.location.reload()}
    else{err.style.display='block';btn.textContent='Unlock';btn.disabled=false;pw.focus();pw.select()}
  }catch(e){err.textContent='Connection error';err.style.display='block';btn.textContent='Unlock';btn.disabled=false}
}
btn.addEventListener('click',verify);
pw.addEventListener('keydown',(e)=>{if(e.key==='Enter')verify()});
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
