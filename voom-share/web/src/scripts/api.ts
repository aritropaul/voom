export interface VideoInfo {
  title: string;
  duration: number;
  width: number;
  height: number;
  summary: string | null;
  has_webcam: number;
  cta_url: string | null;
  cta_text: string | null;
  created_at: string;
  view_count: number;
  is_meeting: number;
}

export interface Segment {
  start_time: number;
  end_time: number;
  text: string;
  speaker: string | null;
}

export interface Chapter {
  timestamp: number;
  title: string;
}

export interface ShareData {
  video: VideoInfo;
  segments: Segment[];
  chapters: Chapter[];
  shareCode: string;
}

export interface PasswordRequired {
  password_protected: true;
  title: string;
}

export interface Expired {
  expired: true;
}

export interface Comment {
  timestamp: number;
  author_name: string;
  text: string;
  created_at: string;
}

export interface CommentsResponse {
  comments: Comment[];
  total: number;
  page: number;
  limit: number;
}

export interface Reaction {
  timestamp: number;
  emoji: string;
  created_at: string;
}

export type ShareResponse = ShareData | PasswordRequired | Expired;

export function isShareData(r: ShareResponse): r is ShareData {
  return 'video' in r;
}

export function isPasswordRequired(r: ShareResponse): r is PasswordRequired {
  return 'password_protected' in r;
}

export function isExpired(r: ShareResponse): r is Expired {
  return 'expired' in r;
}

export async function fetchShareData(shareCode: string): Promise<ShareResponse> {
  const res = await fetch(`/s/${shareCode}/data`, { credentials: 'include' });
  return res.json();
}

export async function verifyPassword(shareCode: string, password: string): Promise<boolean> {
  const res = await fetch(`/s/${shareCode}/verify-password`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'include',
    body: JSON.stringify({ password }),
  });
  return res.ok;
}

export async function fetchReactions(shareCode: string): Promise<Reaction[]> {
  const res = await fetch(`/s/${shareCode}/reactions`);
  const data = await res.json();
  return data.reactions || [];
}

export async function postReaction(shareCode: string, timestamp: number, emoji: string): Promise<boolean> {
  const res = await fetch(`/s/${shareCode}/react`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'include',
    body: JSON.stringify({ timestamp, emoji }),
  });
  return res.ok;
}

export async function fetchComments(shareCode: string, page = 1, limit = 50): Promise<CommentsResponse> {
  const res = await fetch(`/s/${shareCode}/comments?page=${page}&limit=${limit}`);
  return res.json();
}

export async function postComment(
  shareCode: string,
  timestamp: number,
  authorName: string,
  text: string
): Promise<boolean> {
  const res = await fetch(`/s/${shareCode}/comment`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'include',
    body: JSON.stringify({ timestamp, author_name: authorName, text }),
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

export function formatTimestamp(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${String(s).padStart(2, '0')}`;
}

export function formatDate(isoString: string): string {
  const d = new Date(isoString + 'Z');
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

export function escapeHTML(str: string): string {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
