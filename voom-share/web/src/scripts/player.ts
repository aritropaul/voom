import type { Segment, Chapter } from './api';

export interface PlayerOptions {
  shareCode: string;
  segments: Segment[];
  chapters: Chapter[];
  hasCTA: boolean;
}

export function initPlayer(opts: PlayerOptions) {
  const vid = document.getElementById('player') as HTMLVideoElement;
  const section = document.getElementById('player-section')!;
  const controls = document.getElementById('controls')!;
  const cap = document.getElementById('captions');
  const capSpan = cap?.querySelector('span');
  const ccBtn = document.getElementById('cc-btn');

  const segs = opts.segments.map(s => ({
    start: s.start_time,
    end: s.end_time,
    text: s.text,
    speaker: s.speaker,
  }));
  const chaps = opts.chapters;

  let ccOn = segs.length > 0;

  // --- Toast ---
  const toastEl = document.getElementById('toast')!;
  let toastTimer: ReturnType<typeof setTimeout> | null = null;

  function showToast(msg?: string) {
    toastEl.textContent = msg || 'Copied!';
    toastEl.classList.add('show');
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toastEl.classList.remove('show'), 1800);
  }

  // Expose for other modules
  (window as any).__voomToast = showToast;

  // --- Play/Pause ---
  const iconPlay = document.getElementById('icon-play')!;
  const iconPause = document.getElementById('icon-pause')!;

  function togglePlay() {
    if (vid.paused) vid.play();
    else vid.pause();
  }

  section.addEventListener('click', (e) => {
    if ((e.target as Element).closest('.controls') || (e.target as Element).closest('button')) return;
    togglePlay();
  });

  function updatePlayState() {
    const playing = !vid.paused;
    section.classList.toggle('playing', playing);
    iconPlay.style.display = playing ? 'none' : 'block';
    iconPause.style.display = playing ? 'block' : 'none';
  }

  vid.addEventListener('play', updatePlayState);
  vid.addEventListener('pause', updatePlayState);
  document.getElementById('ctrl-play')!.addEventListener('click', (e) => {
    e.stopPropagation();
    togglePlay();
  });

  // --- Controls visibility ---
  let hideTimer: ReturnType<typeof setTimeout> | null = null;

  function showControls() {
    controls.classList.add('visible');
    section.classList.remove('hide-cursor');
    if (hideTimer) clearTimeout(hideTimer);
    if (!vid.paused) {
      hideTimer = setTimeout(() => {
        controls.classList.remove('visible');
        section.classList.add('hide-cursor');
      }, 2000);
    }
  }

  section.addEventListener('mousemove', showControls);
  section.addEventListener('mouseleave', () => {
    if (!vid.paused) {
      if (hideTimer) clearTimeout(hideTimer);
      hideTimer = setTimeout(() => {
        controls.classList.remove('visible');
        section.classList.add('hide-cursor');
      }, 500);
    }
  });
  vid.addEventListener('pause', () => {
    controls.classList.add('visible');
    section.classList.remove('hide-cursor');
  });
  vid.addEventListener('play', showControls);
  controls.classList.add('visible');

  // --- Time + Progress ---
  const timeDisplay = document.getElementById('time-display')!;
  const progressFill = document.getElementById('progress-fill')!;
  const seekbarFill = document.getElementById('seekbar-fill')!;
  const seekbarBuffered = document.getElementById('seekbar-buffered')!;
  const seekbarThumb = document.getElementById('seekbar-thumb')!;

  function fmtTime(s: number): string {
    s = Math.floor(s || 0);
    const m = Math.floor(s / 60);
    const sec = s % 60;
    return m + ':' + String(sec).padStart(2, '0');
  }

  vid.addEventListener('loadedmetadata', () => {
    timeDisplay.textContent = fmtTime(0) + ' / ' + fmtTime(vid.duration);

    // Handle ?t= param
    const params = new URLSearchParams(window.location.search);
    const t = parseFloat(params.get('t') || '0');
    if (t > 0 && t < vid.duration) vid.currentTime = t;

    // Chapter markers on seekbar
    const seekTrack = document.querySelector('.seekbar-track');
    if (seekTrack && chaps.length > 0 && vid.duration > 0) {
      chaps.forEach(c => {
        const marker = document.createElement('div');
        marker.className = 'seekbar-marker';
        marker.style.left = (c.timestamp / vid.duration) * 100 + '%';
        seekTrack.appendChild(marker);
      });
    }

    // Suppress native VTT rendering
    const tracks = vid.textTracks;
    for (let i = 0; i < tracks.length; i++) {
      tracks[i].mode = 'hidden';
    }
  });

  const rows = document.querySelectorAll('.transcript-row');
  const chapRows = document.querySelectorAll('.chapter-row');

  vid.addEventListener('timeupdate', () => {
    const t = vid.currentTime;
    const d = vid.duration || 1;
    const pct = (t / d) * 100;
    progressFill.style.width = pct + '%';
    seekbarFill.style.width = pct + '%';
    seekbarThumb.style.left = pct + '%';
    timeDisplay.textContent = fmtTime(t) + ' / ' + fmtTime(d);

    // Captions + transcript highlight
    let found = false;
    rows.forEach((el, i) => {
      if (!segs[i]) return;
      const s = segs[i];
      const active = t >= s.start && t < s.end;
      el.classList.toggle('active', active);
      if (active && capSpan && ccOn) {
        capSpan.textContent = s.speaker ? s.speaker + ': ' + s.text : s.text;
        cap!.classList.remove('hidden');
        found = true;
      }
    });
    if (!found && capSpan) cap!.classList.add('hidden');

    // Chapter highlight
    chapRows.forEach((el, i) => {
      if (!chaps[i]) return;
      const next = chaps[i + 1];
      const active = t >= chaps[i].timestamp && (!next || t < next.timestamp);
      el.classList.toggle('active', active);
    });
  });

  vid.addEventListener('progress', () => {
    if (vid.buffered.length > 0) {
      const buffEnd = vid.buffered.end(vid.buffered.length - 1);
      seekbarBuffered.style.width = (buffEnd / (vid.duration || 1)) * 100 + '%';
    }
  });

  // --- Seekbar ---
  const seekbar = document.getElementById('seekbar')!;
  let seeking = false;

  function seekFromEvent(e: MouseEvent | Touch) {
    const rect = seekbar.getBoundingClientRect();
    const pct = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
    vid.currentTime = pct * (vid.duration || 0);
  }

  seekbar.addEventListener('mousedown', (e) => {
    e.stopPropagation();
    seeking = true;
    seekFromEvent(e);
  });
  document.addEventListener('mousemove', (e) => { if (seeking) seekFromEvent(e); });
  document.addEventListener('mouseup', () => { seeking = false; });
  seekbar.addEventListener('touchstart', (e) => {
    e.stopPropagation();
    seeking = true;
    seekFromEvent(e.touches[0]);
  }, { passive: true });
  document.addEventListener('touchmove', (e) => {
    if (seeking) seekFromEvent(e.touches[0]);
  }, { passive: true });
  document.addEventListener('touchend', () => { seeking = false; });

  // --- Volume ---
  const volRange = document.getElementById('volume-range') as HTMLInputElement;
  const iconVol = document.getElementById('icon-vol')!;
  const iconMute = document.getElementById('icon-mute')!;
  let savedVol = 1;

  function updateVolIcons() {
    const muted = vid.muted || vid.volume === 0;
    iconVol.style.display = muted ? 'none' : 'block';
    iconMute.style.display = muted ? 'block' : 'none';
  }

  document.getElementById('ctrl-mute')!.addEventListener('click', (e) => {
    e.stopPropagation();
    if (vid.muted || vid.volume === 0) {
      vid.muted = false;
      vid.volume = savedVol || 1;
      volRange.value = String(vid.volume);
    } else {
      savedVol = vid.volume;
      vid.muted = true;
      volRange.value = '0';
    }
    updateVolIcons();
  });

  volRange.addEventListener('input', (e) => {
    e.stopPropagation();
    vid.volume = parseFloat(volRange.value);
    vid.muted = vid.volume === 0;
    savedVol = vid.volume || savedVol;
    updateVolIcons();
  });

  // --- Speed ---
  const speedBtn = document.getElementById('ctrl-speed')!;
  const speedMenu = document.getElementById('speed-menu')!;

  speedBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    speedMenu.classList.toggle('open');
  });

  speedMenu.querySelectorAll('button').forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const s = parseFloat((btn as HTMLElement).dataset.speed || '1');
      vid.playbackRate = s;
      speedBtn.textContent = s === 1 ? '1x' : s + 'x';
      speedMenu.querySelectorAll('button').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      speedMenu.classList.remove('open');
    });
  });

  document.addEventListener('click', () => speedMenu.classList.remove('open'));

  // --- CC toggle ---
  if (ccBtn) {
    ccBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      ccOn = !ccOn;
      ccBtn.classList.toggle('on', ccOn);
      if (cap) cap.classList.toggle('hidden', !ccOn);
    });
  }

  // --- Fullscreen ---
  document.getElementById('ctrl-fs')!.addEventListener('click', (e) => {
    e.stopPropagation();
    if (document.fullscreenElement) document.exitFullscreen();
    else section.requestFullscreen().catch(() => {});
  });

  // --- Keyboard shortcuts ---
  document.addEventListener('keydown', (e) => {
    if ((e.target as Element).tagName === 'INPUT' || (e.target as Element).tagName === 'TEXTAREA') return;
    switch (e.key.toLowerCase()) {
      case ' ':
      case 'k':
        e.preventDefault();
        togglePlay();
        break;
      case 'arrowleft':
        e.preventDefault();
        vid.currentTime = Math.max(0, vid.currentTime - 5);
        break;
      case 'arrowright':
        e.preventDefault();
        vid.currentTime = Math.min(vid.duration, vid.currentTime + 5);
        break;
      case 'm':
        vid.muted = !vid.muted;
        volRange.value = vid.muted ? '0' : String(vid.volume);
        updateVolIcons();
        break;
      case 'f':
        if (document.fullscreenElement) document.exitFullscreen();
        else section.requestFullscreen().catch(() => {});
        break;
      case 'c':
        if (ccBtn) {
          ccOn = !ccOn;
          ccBtn.classList.toggle('on', ccOn);
          if (cap) cap.classList.toggle('hidden', !ccOn);
        }
        break;
    }
  });

  // --- Copy timestamp buttons ---
  document.querySelectorAll('.copy-ts').forEach(btn => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const t = Math.floor(parseFloat((btn as HTMLElement).dataset.time || '0'));
      const url = window.location.origin + window.location.pathname + '?t=' + t;
      navigator.clipboard.writeText(url).then(() => showToast('Copied!')).catch(() => {});
    });
  });

  // --- Copy link button ---
  document.getElementById('copy-link-btn')?.addEventListener('click', () => {
    let url = window.location.origin + window.location.pathname;
    const t = Math.floor(vid.currentTime || 0);
    if (t > 0) url += '?t=' + t;
    navigator.clipboard.writeText(url).then(() => showToast('Copied!')).catch(() => {});
  });

  // --- CTA overlay ---
  if (opts.hasCTA) {
    const ctaOverlay = document.getElementById('cta-overlay');
    const ctaReplay = document.getElementById('cta-replay');
    if (ctaOverlay) {
      vid.addEventListener('ended', () => ctaOverlay.classList.add('visible'));
      vid.addEventListener('play', () => ctaOverlay.classList.remove('visible'));
      if (ctaReplay) {
        ctaReplay.addEventListener('click', (e) => {
          e.stopPropagation();
          vid.currentTime = 0;
          vid.play();
        });
      }
    }
  }
}
