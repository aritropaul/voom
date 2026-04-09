import { fetchReactions, postReaction } from './api';

const EMOJI_LIST = ['👍', '❤️', '😂', '😮', '🔥', '👏'];

export function initReactions(shareCode: string, getTimestamp: () => number) {
  const counts = [0, 0, 0, 0, 0, 0];

  function updateCounts() {
    EMOJI_LIST.forEach((_, i) => {
      const el = document.getElementById('rc-' + i);
      if (el) el.textContent = counts[i] > 0 ? String(counts[i]) : '';
    });
  }

  // Load initial counts
  fetchReactions(shareCode).then(reactions => {
    reactions.forEach(r => {
      const idx = EMOJI_LIST.indexOf(r.emoji);
      if (idx >= 0) counts[idx]++;
    });
    updateCounts();
  }).catch(() => {});

  // Bind click handlers
  document.querySelectorAll('.react-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      const emoji = (btn as HTMLElement).dataset.emoji!;
      const t = getTimestamp();

      postReaction(shareCode, t, emoji).then(ok => {
        if (ok) {
          const idx = EMOJI_LIST.indexOf(emoji);
          if (idx >= 0) {
            counts[idx]++;
            updateCounts();
          }
          // Float bubble animation
          const bubble = document.createElement('div');
          bubble.className = 'reaction-bubble';
          bubble.textContent = emoji;
          const rect = btn.getBoundingClientRect();
          bubble.style.left = rect.left + 'px';
          bubble.style.top = (rect.top - 10) + 'px';
          document.body.appendChild(bubble);
          setTimeout(() => bubble.remove(), 1500);
        }
      }).catch(() => {});
    });
  });
}
