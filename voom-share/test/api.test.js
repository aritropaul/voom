import { describe, it, expect, beforeAll } from 'vitest';
import { env, SELF } from 'cloudflare:test';
import { sha256Hex } from '../src/index.js';

const AUTH = { Authorization: 'Bearer test-secret' };
const BASE = 'https://share.test';

async function createShare(extra = {}) {
  const res = await SELF.fetch(`${BASE}/api/upload`, {
    method: 'POST',
    headers: { ...AUTH, 'Content-Type': 'application/json' },
    body: JSON.stringify({ title: 'Test Recording', duration: 12.5, width: 1920, height: 1080, fileSize: 1000, ...extra }),
  });
  expect(res.status).toBe(200);
  return res.json();
}

async function completeUpload(shareCode, bytes = new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7])) {
  const put = await SELF.fetch(`${BASE}/api/upload-data/${shareCode}`, {
    method: 'PUT',
    headers: { ...AUTH, 'Content-Type': 'video/mp4' },
    body: bytes,
  });
  expect(put.status).toBe(200);
  const meta = await SELF.fetch(`${BASE}/api/metadata/${shareCode}`, {
    method: 'POST',
    headers: { ...AUTH, 'Content-Type': 'application/json' },
    body: JSON.stringify({ segments: [{ startTime: 0, endTime: 1, text: 'hello world' }] }),
  });
  expect(meta.status).toBe(200);
}

describe('auth', () => {
  it('rejects /api/* without a token', async () => {
    const res = await SELF.fetch(`${BASE}/api/health`);
    expect(res.status).toBe(401);
  });

  it('rejects a wrong token', async () => {
    const res = await SELF.fetch(`${BASE}/api/health`, { headers: { Authorization: 'Bearer wrong' } });
    expect(res.status).toBe(401);
  });

  it('rejects a Bearer header with no token', async () => {
    const res = await SELF.fetch(`${BASE}/api/health`, { headers: { Authorization: 'Bearer' } });
    expect(res.status).toBe(401);
  });

  it('accepts the correct token', async () => {
    const res = await SELF.fetch(`${BASE}/api/health`, { headers: AUTH });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, app: 'voom' });
  });
});

describe('upload validation', () => {
  it('requires a title', async () => {
    const res = await SELF.fetch(`${BASE}/api/upload`, {
      method: 'POST',
      headers: { ...AUTH, 'Content-Type': 'application/json' },
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(400);
  });

  it('rejects javascript: CTA URLs', async () => {
    const res = await SELF.fetch(`${BASE}/api/upload`, {
      method: 'POST',
      headers: { ...AUTH, 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: 'x', cta_url: 'javascript:alert(1)' }),
    });
    expect(res.status).toBe(400);
  });

  it('accepts https CTA URLs and returns a well-formed share code', async () => {
    const data = await createShare({ cta_url: 'https://example.com', cta_text: 'Visit' });
    expect(data.shareCode).toMatch(/^[a-z0-9]{10}$/);
    expect(data.shareURL).toContain(`/s/${data.shareCode}`);
  });
});

describe('share data + view counts', () => {
  it('serves data for a completed upload and increments views', async () => {
    const { shareCode } = await createShare();
    await completeUpload(shareCode);

    const res1 = await SELF.fetch(`${BASE}/s/${shareCode}/data`);
    expect(res1.status).toBe(200);
    const d1 = await res1.json();
    expect(d1.video.title).toBe('Test Recording');
    expect(d1.video.view_count).toBe(1);
    expect(d1.segments).toHaveLength(1);

    const res2 = await SELF.fetch(`${BASE}/s/${shareCode}/data`);
    const d2 = await res2.json();
    expect(d2.video.view_count).toBe(2);
  });

  it('404s for incomplete uploads', async () => {
    const { shareCode } = await createShare();
    const res = await SELF.fetch(`${BASE}/s/${shareCode}/data`);
    expect(res.status).toBe(404);
  });
});

describe('video streaming + ranges', () => {
  let shareCode;
  const bytes = new Uint8Array(100).map((_, i) => i);

  beforeAll(async () => {
    ({ shareCode } = await createShare());
    await completeUpload(shareCode, bytes);
  });

  it('serves the full object without a Range header', async () => {
    const res = await SELF.fetch(`${BASE}/v/${shareCode}`);
    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Length')).toBe('100');
    expect(res.headers.get('Accept-Ranges')).toBe('bytes');
  });

  it('serves a bounded range with the full size in Content-Range', async () => {
    const res = await SELF.fetch(`${BASE}/v/${shareCode}`, { headers: { Range: 'bytes=10-19' } });
    expect(res.status).toBe(206);
    expect(res.headers.get('Content-Range')).toBe('bytes 10-19/100');
    expect(res.headers.get('Content-Length')).toBe('10');
    const body = new Uint8Array(await res.arrayBuffer());
    expect(Array.from(body)).toEqual([10, 11, 12, 13, 14, 15, 16, 17, 18, 19]);
  });

  it('serves an open-ended range', async () => {
    const res = await SELF.fetch(`${BASE}/v/${shareCode}`, { headers: { Range: 'bytes=90-' } });
    expect(res.status).toBe(206);
    expect(res.headers.get('Content-Range')).toBe('bytes 90-99/100');
    expect(res.headers.get('Content-Length')).toBe('10');
  });

  it('serves a suffix range (bytes=-N)', async () => {
    const res = await SELF.fetch(`${BASE}/v/${shareCode}`, { headers: { Range: 'bytes=-5' } });
    expect(res.status).toBe(206);
    expect(res.headers.get('Content-Range')).toBe('bytes 95-99/100');
    const body = new Uint8Array(await res.arrayBuffer());
    expect(Array.from(body)).toEqual([95, 96, 97, 98, 99]);
  });

  it('returns 416 for an unsatisfiable range', async () => {
    const res = await SELF.fetch(`${BASE}/v/${shareCode}`, { headers: { Range: 'bytes=5000-' } });
    expect(res.status).toBe(416);
  });
});

describe('password protection', () => {
  const password = 'hunter2';
  let clientHash;

  beforeAll(async () => {
    clientHash = await sha256Hex(password); // what the desktop app sends at share time
  });

  async function protectedShare() {
    const share = await createShare({ password_hash: clientHash });
    await completeUpload(share.shareCode);
    return share.shareCode;
  }

  it('gates /data behind the password', async () => {
    const shareCode = await protectedShare();
    const res = await SELF.fetch(`${BASE}/s/${shareCode}/data`);
    expect(res.status).toBe(401);
    expect((await res.json()).password_protected).toBe(true);
  });

  it('gates reactions, comments, and the thumbnail behind the password', async () => {
    const shareCode = await protectedShare();

    expect((await SELF.fetch(`${BASE}/s/${shareCode}/reactions`)).status).toBe(401);
    expect((await SELF.fetch(`${BASE}/s/${shareCode}/comments`)).status).toBe(401);
    expect((await SELF.fetch(`${BASE}/thumb/${shareCode}`)).status).toBe(404);

    // …and unlocks them all with the auth cookie.
    const good = await SELF.fetch(`${BASE}/s/${shareCode}/verify-password`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password }),
    });
    expect(good.status).toBe(200);
    const cookie = good.headers.get('Set-Cookie').split(';')[0];

    expect((await SELF.fetch(`${BASE}/s/${shareCode}/reactions`, { headers: { Cookie: cookie } })).status).toBe(200);
    expect((await SELF.fetch(`${BASE}/s/${shareCode}/comments`, { headers: { Cookie: cookie } })).status).toBe(200);
  });

  it('rejects password attempts on expired videos', async () => {
    const shareCode = await protectedShare();
    await env.DB.prepare(
      "UPDATE videos SET expires_at = datetime('now', '-1 day') WHERE share_code = ?"
    ).bind(shareCode).run();

    const res = await SELF.fetch(`${BASE}/s/${shareCode}/verify-password`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password }),
    });
    expect(res.status).toBe(404);
  });

  it('rejects a wrong password, accepts the right one, sets an HttpOnly cookie', async () => {
    const shareCode = await protectedShare();

    const bad = await SELF.fetch(`${BASE}/s/${shareCode}/verify-password`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password: 'wrong' }),
    });
    expect(bad.status).toBe(403);

    const good = await SELF.fetch(`${BASE}/s/${shareCode}/verify-password`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password }),
    });
    expect(good.status).toBe(200);
    const cookie = good.headers.get('Set-Cookie');
    expect(cookie).toContain(`voom_auth_${shareCode}=`);
    expect(cookie).toContain('HttpOnly');
    expect(cookie).toContain('Secure');

    const authed = await SELF.fetch(`${BASE}/s/${shareCode}/data`, {
      headers: { Cookie: cookie.split(';')[0] },
    });
    expect(authed.status).toBe(200);
  });

  it('stores passwords salted — never the bare client hash', async () => {
    const shareCode = await protectedShare();
    const row = await env.DB.prepare('SELECT password_hash, password_salt FROM videos WHERE share_code = ?')
      .bind(shareCode).first();
    expect(row.password_salt).toMatch(/^[0-9a-f]{32}$/);
    expect(row.password_hash).not.toBe(clientHash);
  });

  it('lazily upgrades legacy unsalted rows on successful verify', async () => {
    const shareCode = await protectedShare();
    // Regress the row to the legacy (pre-salt) format.
    await env.DB.prepare('UPDATE videos SET password_hash = ?, password_salt = NULL WHERE share_code = ?')
      .bind(clientHash, shareCode).run();

    const res = await SELF.fetch(`${BASE}/s/${shareCode}/verify-password`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password }),
    });
    expect(res.status).toBe(200);

    const row = await env.DB.prepare('SELECT password_hash, password_salt FROM videos WHERE share_code = ?')
      .bind(shareCode).first();
    expect(row.password_salt).toMatch(/^[0-9a-f]{32}$/);
    expect(row.password_hash).not.toBe(clientHash); // re-stored salted
  });

  it('rate-limits brute-force attempts (429 after 10 failures)', async () => {
    const shareCode = await protectedShare();
    for (let i = 0; i < 10; i++) {
      const res = await SELF.fetch(`${BASE}/s/${shareCode}/verify-password`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '203.0.113.7' },
        body: JSON.stringify({ password: `wrong-${i}` }),
      });
      expect(res.status).toBe(403);
    }
    const blocked = await SELF.fetch(`${BASE}/s/${shareCode}/verify-password`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '203.0.113.7' },
      body: JSON.stringify({ password }),
    });
    expect(blocked.status).toBe(429);
  });

  it('hides title and thumbnail from the OG page and image', async () => {
    const shareCode = await protectedShare();
    const og = await SELF.fetch(`${BASE}/s/${shareCode}`, { headers: { 'User-Agent': 'Twitterbot/1.0' } });
    expect(og.status).toBe(200);
    const html = await og.text();
    expect(html).toContain('Protected video');
    expect(html).not.toContain('Test Recording');

    const img = await SELF.fetch(`${BASE}/og/${shareCode}`);
    expect(img.status).toBe(200);
    expect(img.headers.get('Content-Type')).toContain('svg');
    const svg = await img.text();
    expect(svg).toContain('Protected video');
    expect(svg).not.toContain('Test Recording');
  });
});

describe('OG page (public video)', () => {
  it('escapes the title in meta tags', async () => {
    const { shareCode } = await createShare({ title: '<script>alert("x")</script>' });
    await completeUpload(shareCode);
    const res = await SELF.fetch(`${BASE}/s/${shareCode}`, { headers: { 'User-Agent': 'Slackbot 1.0' } });
    const html = await res.text();
    expect(html).not.toContain('<script>alert');
    expect(html).toContain('&lt;script&gt;');
  });
});

describe('delete', () => {
  it('removes the video row, children, and R2 objects', async () => {
    const { shareCode } = await createShare();
    await completeUpload(shareCode);

    const del = await SELF.fetch(`${BASE}/api/delete/${shareCode}`, { method: 'DELETE', headers: AUTH });
    expect(del.status).toBe(200);

    expect((await SELF.fetch(`${BASE}/s/${shareCode}/data`)).status).toBe(404);
    expect((await SELF.fetch(`${BASE}/v/${shareCode}`)).status).toBe(404);
    const segs = await env.DB.prepare(
      'SELECT COUNT(*) AS cnt FROM transcript_segments ts WHERE NOT EXISTS (SELECT 1 FROM videos v WHERE v.id = ts.video_id)'
    ).first();
    expect(segs.cnt).toBe(0); // no orphaned children
    expect(await env.VIDEOS_BUCKET.get(`videos/${shareCode}.mp4`)).toBeNull();
  });
});

describe('check-views', () => {
  it('caps the shareCodes array', async () => {
    const res = await SELF.fetch(`${BASE}/api/check-views`, {
      method: 'POST',
      headers: { ...AUTH, 'Content-Type': 'application/json' },
      body: JSON.stringify({ shareCodes: Array.from({ length: 91 }, (_, i) => `code${i}`) }),
    });
    expect(res.status).toBe(400);
  });
});

describe('error middleware', () => {
  it('returns JSON 500 instead of an opaque error on handler crashes', async () => {
    // Malformed JSON body → request.json() throws inside handleUpload.
    const res = await SELF.fetch(`${BASE}/api/upload`, {
      method: 'POST',
      headers: { ...AUTH, 'Content-Type': 'application/json' },
      body: '{not json',
    });
    expect(res.status).toBe(500);
    expect(res.headers.get('Content-Type')).toContain('application/json');
    expect((await res.json()).error).toBe('Internal error');
  });
});
