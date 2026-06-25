export interface LibraryVideo {
  share_code: string;
  title: string;
  duration: number;
  width: number;
  height: number;
  file_size: number;
  created_at: string;
  expires_at: string;
  view_count: number;
  is_meeting: number;
  summary: string | null;
  is_protected: number;
}

export async function fetchVideos(): Promise<LibraryVideo[]> {
  const res = await fetch('/api/videos', { credentials: 'include' });
  if (res.status === 401) {
    window.location.href = '/library/login';
    return [];
  }
  if (!res.ok) throw new Error(`Failed to load videos (${res.status})`);
  const data = await res.json();
  return data.videos || [];
}

export async function renewVideo(shareCode: string): Promise<string | null> {
  const res = await fetch(`/api/renew/${shareCode}`, {
    method: 'POST',
    credentials: 'include',
  });
  if (!res.ok) return null;
  const data = await res.json();
  return data.expiresAt || null;
}

export async function deleteVideo(shareCode: string): Promise<boolean> {
  const res = await fetch(`/api/delete/${shareCode}`, {
    method: 'DELETE',
    credentials: 'include',
  });
  return res.ok;
}

export function formatDuration(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  return `${m}:${String(s).padStart(2, '0')}`;
}

export function formatDate(isoString: string): string {
  const d = new Date(isoString + 'Z');
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

export function daysUntilExpiry(expiresAt: string): number {
  const now = Date.now();
  const exp = new Date(expiresAt + 'Z').getTime();
  return Math.max(0, Math.round((exp - now) / (24 * 60 * 60 * 1000)));
}

export function escapeHTML(str: string): string {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
