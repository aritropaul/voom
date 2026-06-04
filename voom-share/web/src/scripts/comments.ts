import { fetchComments, postComment, escapeHTML, formatTimestamp, formatDate, linkifyTimestamps } from './api';
import type { Comment } from './api';

const PLAY_ICON =
  '<svg width="9" height="9" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><polygon points="6,4 20,12 6,20"/></svg>';

// Greedily group markers whose centres fall within MIN_GAP_PX of each other so
// nearby comments collapse into a single clickable "+N" badge instead of an
// unclickable pile of overlapping dots.
const MIN_GAP_PX = 14;

interface Cluster {
  time: number; // centroid, for positioning
  members: Comment[];
}

export function initComments(
  shareCode: string,
  vid: HTMLVideoElement,
  openModal: () => void,
) {
  const commentList = document.getElementById('comment-list')!;
  const commentName = document.getElementById('comment-name') as HTMLInputElement;
  const commentText = document.getElementById('comment-text') as HTMLTextAreaElement;
  const commentSubmit = document.getElementById('comment-submit') as HTMLButtonElement;
  const tsPill = document.getElementById('comment-ts-pill') as HTMLButtonElement | null;
  const tsPillLabel = document.getElementById('comment-ts-label');

  const showToast = () => (window as any).__voomToast as ((msg: string) => void) | undefined;

  // Restore saved name
  commentName.value = localStorage.getItem('voom_comment_name') || '';

  let comments: Comment[] = [];

  function seekTo(t: number) {
    vid.currentTime = t;
    openModal();
  }

  // ── Composer timestamp pill ─────────────────────────────────────────────
  // While the box is empty the pill tracks the playhead live; the moment the
  // viewer starts typing it locks, so the comment anchors to the frame they
  // were looking at — not to wherever the video drifted to before submit.
  let lockedTime: number | null = null;

  function pillTime(): number {
    return lockedTime ?? (vid.currentTime || 0);
  }

  function updatePill() {
    if (tsPillLabel) tsPillLabel.textContent = 'Commenting at ' + formatTimestamp(pillTime());
    if (tsPill) tsPill.classList.toggle('locked', lockedTime !== null);
  }

  if (tsPill) {
    updatePill();
    vid.addEventListener('timeupdate', () => { if (lockedTime === null) updatePill(); });
    vid.addEventListener('loadedmetadata', () => { if (lockedTime === null) updatePill(); });
    // Click the pill to drop the lock and re-grab the current playhead.
    tsPill.addEventListener('click', () => { lockedTime = null; updatePill(); });
    commentText.addEventListener('input', () => {
      const hasText = commentText.value.trim().length > 0;
      if (hasText && lockedTime === null) {
        lockedTime = vid.currentTime || 0;
        updatePill();
      } else if (!hasText && lockedTime !== null) {
        lockedTime = null;
        updatePill();
      }
    });
  }

  // ── Comment list ────────────────────────────────────────────────────────
  function renderList() {
    const duration = vid.duration || 0;
    if (comments.length === 0) {
      commentList.innerHTML = '<div class="comment-empty">No comments yet — be the first.</div>';
      return;
    }
    commentList.innerHTML = comments
      .map(c => {
        const ts = formatTimestamp(c.timestamp);
        const body = linkifyTimestamps(escapeHTML(c.text), duration);
        return (
          '<div class="comment" data-t="' + c.timestamp + '">' +
            '<div class="comment-header">' +
              '<span class="comment-author">' + escapeHTML(c.author_name) + '</span>' +
              '<button class="comment-ts" data-time="' + c.timestamp + '" title="Jump to ' + ts + '">' +
                PLAY_ICON + '<span>' + ts + '</span>' +
              '</button>' +
              (c.created_at ? '<span class="comment-date">' + formatDate(c.created_at) + '</span>' : '') +
            '</div>' +
            '<div class="comment-text">' + body + '</div>' +
          '</div>'
        );
      })
      .join('');
  }

  // Event delegation: timestamp chips and inline timestamp links both seek.
  commentList.addEventListener('click', (e) => {
    const target = e.target as HTMLElement;
    const chip = target.closest('.comment-ts') as HTMLElement | null;
    if (chip) { seekTo(parseFloat(chip.dataset.time || '0')); return; }
    const link = target.closest('.ts-link') as HTMLElement | null;
    if (link) { e.preventDefault(); seekTo(parseFloat(link.dataset.t || '0')); }
  });
  commentList.addEventListener('keydown', (e) => {
    const link = (e.target as HTMLElement).closest('.ts-link') as HTMLElement | null;
    if (link && (e.key === 'Enter' || e.key === ' ')) {
      e.preventDefault();
      seekTo(parseFloat(link.dataset.t || '0'));
    }
  });

  // ── Seekbar markers ─────────────────────────────────────────────────────
  function clusterComments(duration: number, trackWidth: number): Cluster[] {
    const sorted = [...comments].sort((a, b) => a.timestamp - b.timestamp);
    // Convert the pixel collision threshold into a time gap. When the track
    // isn't laid out yet (modal closed → width 0) fall back to 2% of duration.
    const gap = trackWidth > 0 ? (MIN_GAP_PX / trackWidth) * duration : duration * 0.02;
    const clusters: Cluster[] = [];
    for (const c of sorted) {
      const last = clusters[clusters.length - 1];
      if (last && c.timestamp - last.members[last.members.length - 1].timestamp < gap) {
        last.members.push(c);
        last.time = last.members.reduce((s, m) => s + m.timestamp, 0) / last.members.length;
      } else {
        clusters.push({ time: c.timestamp, members: [c] });
      }
    }
    return clusters;
  }

  function renderMarkers() {
    const track = document.querySelector('.seekbar-track') as HTMLElement | null;
    const duration = vid.duration || 0;
    if (!track || !duration || comments.length === 0) return;

    track.querySelectorAll('.comment-marker').forEach(el => el.remove());
    const trackWidth = track.getBoundingClientRect().width;

    clusterComments(duration, trackWidth).forEach(cluster => {
      const marker = document.createElement('button');
      marker.className = 'comment-marker' + (cluster.members.length > 1 ? ' cluster' : '');
      marker.style.left = (cluster.time / duration) * 100 + '%';
      marker.type = 'button';

      const first = cluster.members[0];
      const seekTime = first.timestamp;
      marker.setAttribute(
        'aria-label',
        cluster.members.length > 1
          ? cluster.members.length + ' comments around ' + formatTimestamp(cluster.time)
          : 'Comment by ' + first.author_name + ' at ' + formatTimestamp(seekTime),
      );

      if (cluster.members.length > 1) {
        marker.innerHTML = '<span class="cluster-count">' + cluster.members.length + '</span>';
      }

      // Tooltip
      const tip = document.createElement('span');
      tip.className = 'comment-marker-tip';
      tip.innerHTML = cluster.members
        .slice(0, 3)
        .map(m =>
          '<span class="tip-row"><span class="tip-meta">' +
          escapeHTML(m.author_name) + ' · ' + formatTimestamp(m.timestamp) +
          '</span><span class="tip-text">' + escapeHTML(m.text.slice(0, 80)) +
          (m.text.length > 80 ? '…' : '') + '</span></span>',
        )
        .join('') +
        (cluster.members.length > 3 ? '<span class="tip-more">+' + (cluster.members.length - 3) + ' more</span>' : '');
      marker.appendChild(tip);

      // Keep the tooltip inside the player frame horizontally.
      marker.addEventListener('mouseenter', () => {
        tip.style.transform = 'translateX(-50%)';
        const r = tip.getBoundingClientRect();
        const section = document.getElementById('player-section');
        if (!section) return;
        const b = section.getBoundingClientRect();
        let shift = 0;
        if (r.left < b.left + 8) shift = b.left + 8 - r.left;
        else if (r.right > b.right - 8) shift = b.right - 8 - r.right;
        if (shift) tip.style.transform = 'translateX(calc(-50% + ' + shift + 'px))';
      });

      const onActivate = (e: Event) => { e.stopPropagation(); seekTo(seekTime); };
      marker.addEventListener('click', onActivate);
      marker.addEventListener('mousedown', (e) => e.stopPropagation());

      track.appendChild(marker);
    });
  }

  // Re-cluster when the seekbar's width changes (modal opens, window resizes).
  const track = document.querySelector('.seekbar-track');
  if (track && 'ResizeObserver' in window) {
    let raf = 0;
    const ro = new ResizeObserver(() => {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(renderMarkers);
    });
    ro.observe(track);
  }
  vid.addEventListener('loadedmetadata', () => { renderList(); renderMarkers(); });

  // ── Load ─────────────────────────────────────────────────────────────────
  renderList();
  fetchComments(shareCode)
    .then(data => {
      comments = data.comments || [];
      renderList();
      renderMarkers();
    })
    .catch(() => {});

  // ── Submit ─────────────────────────────────────────────────────────────────
  function submit() {
    const text = commentText.value.trim();
    if (!text) return;
    const name = commentName.value.trim() || 'Anonymous';
    const t = pillTime();
    localStorage.setItem('voom_comment_name', name);
    commentSubmit.disabled = true;
    commentSubmit.textContent = 'Posting...';

    postComment(shareCode, t, name, text)
      .then(ok => {
        const toast = showToast();
        if (ok) {
          // formatDate() appends its own 'Z', so store a Z-less UTC string to match the server.
          const createdAt = new Date().toISOString().slice(0, 19);
          comments.push({ timestamp: t, author_name: name, text, created_at: createdAt });
          comments.sort((a, b) => a.timestamp - b.timestamp);
          renderList();
          renderMarkers();
          commentText.value = '';
          lockedTime = null;
          updatePill();
          if (toast) toast('Comment posted at ' + formatTimestamp(t));
        } else if (toast) {
          toast('Failed to post');
        }
      })
      .catch(() => {})
      .finally(() => {
        commentSubmit.disabled = false;
        commentSubmit.textContent = 'Post Comment';
      });
  }

  commentSubmit.addEventListener('click', submit);
  // Cmd/Ctrl+Enter submits from the textarea.
  commentText.addEventListener('keydown', (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') { e.preventDefault(); submit(); }
  });
}
