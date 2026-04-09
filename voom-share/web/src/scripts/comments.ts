import { fetchComments, postComment, escapeHTML, formatTimestamp } from './api';
import type { Comment } from './api';

export function initComments(shareCode: string, getTimestamp: () => number, seekTo: (t: number) => void) {
  const commentList = document.getElementById('comment-list')!;
  const commentName = document.getElementById('comment-name') as HTMLInputElement;
  const commentText = document.getElementById('comment-text') as HTMLTextAreaElement;
  const commentSubmit = document.getElementById('comment-submit') as HTMLButtonElement;

  // Restore saved name
  commentName.value = localStorage.getItem('voom_comment_name') || '';

  function renderComment(c: Comment): HTMLDivElement {
    const div = document.createElement('div');
    div.className = 'comment';
    const timeStr = formatTimestamp(c.timestamp);
    div.innerHTML =
      '<div class="comment-header">' +
      '<span class="comment-author">' + escapeHTML(c.author_name) + '</span>' +
      '<span class="comment-ts" data-time="' + c.timestamp + '">' + timeStr + '</span>' +
      '</div>' +
      '<div class="comment-text">' + escapeHTML(c.text) + '</div>';
    div.querySelector('.comment-ts')!.addEventListener('click', () => seekTo(c.timestamp));
    return div;
  }

  // Load comments
  fetchComments(shareCode).then(data => {
    data.comments.forEach(c => commentList.appendChild(renderComment(c)));
  }).catch(() => {});

  // Submit comment
  commentSubmit.addEventListener('click', () => {
    const text = commentText.value.trim();
    if (!text) return;
    const name = commentName.value.trim() || 'Anonymous';
    localStorage.setItem('voom_comment_name', name);
    commentSubmit.disabled = true;
    commentSubmit.textContent = 'Posting...';

    const showToast = (window as any).__voomToast as (msg: string) => void;

    postComment(shareCode, getTimestamp(), name, text).then(ok => {
      if (ok) {
        commentList.appendChild(renderComment({
          timestamp: getTimestamp(),
          author_name: name,
          text,
          created_at: new Date().toISOString(),
        }));
        commentText.value = '';
        if (showToast) showToast('Comment posted');
      } else {
        if (showToast) showToast('Failed to post');
      }
      commentSubmit.disabled = false;
      commentSubmit.textContent = 'Post Comment';
    }).catch(() => {
      commentSubmit.disabled = false;
      commentSubmit.textContent = 'Post Comment';
    });
  });
}
