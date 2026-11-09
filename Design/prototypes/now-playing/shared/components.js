(function () {
  'use strict';
  const NP = window.NP;
  const D = NP.data;
  const P = NP.player;
  const { h, esc, icon, fmt, clamp } = NP;

  NP.Background = function (host, { drift = true } = {}) {
    host.classList.add('npbg');
    const scrim = h('<div class="npbg-scrim"></div>');
    host.appendChild(scrim);
    let cur = null;
    function set(track, instant) {
      const L = h(`<div class="npbg-layer${drift ? '' : ' still'}"><img class="npbg-art" alt="" src="${track.blurURL}"><i class="npbg-blob b1"></i><i class="npbg-blob b2"></i><i class="npbg-blob b3"></i></div>`);
      L.style.setProperty('--c1', track.palette.c1);
      L.style.setProperty('--c2', track.palette.c2);
      L.style.setProperty('--c3', track.palette.c3);
      host.insertBefore(L, scrim);
      if (cur && !instant) {
        const old = cur;
        L.classList.add('enter');
        requestAnimationFrame(() => requestAnimationFrame(() => L.classList.remove('enter')));
        setTimeout(() => old.remove(), 1400);
      } else if (cur) cur.remove();
      cur = L;
    }
    return { set };
  };

  function roundedBars(values, W, H, pitch, barW, minH) {
    let d = '';
    const n = values.length;
    const r = barW / 2;
    for (let i = 0; i < n; i++) {
      const v = Math.max(minH, values[i]);
      const bh = Math.max(barW, v * H);
      const x = i * pitch + (pitch - barW) / 2;
      const y = (H - bh) / 2;
      d += `M${(x + r).toFixed(2)} ${y.toFixed(2)}a${r} ${r} 0 0 1 ${r} ${r}v${(bh - barW).toFixed(2)}a${r} ${r} 0 0 1 -${r} ${r}a${r} ${r} 0 0 1 -${r} -${r}v-${(bh - barW).toFixed(2)}a${r} ${r} 0 0 1 ${r} -${r}z`;
    }
    return d;
  }

  function resample(wave, n) {
    const out = new Float32Array(n);
    const step = wave.length / n;
    for (let i = 0; i < n; i++) {
      let m = 0;
      let s = 0;
      const a = Math.floor(i * step);
      const b = Math.max(a + 1, Math.floor((i + 1) * step));
      for (let k = a; k < b; k++) {
        m = Math.max(m, wave[k]);
        s += wave[k];
      }
      out[i] = m * 0.55 + (s / (b - a)) * 0.45;
    }
    return out;
  }
  NP.resample = resample;

  NP.Waveform = function (host, opts = {}) {
    const o = Object.assign({ pitch: 3.5, barW: 2, height: 36, minH: 0.1, scrub: true, bubble: false, label: null, onScrub: null }, opts);
    host.classList.add('wf');
    host.style.setProperty('--wf-h', o.height + 'px');
    host.innerHTML = `<div class="wf-track"><svg class="wf-svg wf-base"><path/></svg><div class="wf-clip"><div class="wf-clip-in"><svg class="wf-svg wf-played"><path/></svg></div></div><div class="wf-marks"></div><i class="wf-head"></i></div><div class="wf-time"><span></span></div><div class="wf-cbubble"></div>`;
    const track = host.querySelector('.wf-track');
    const clip = host.querySelector('.wf-clip');
    const clipIn = host.querySelector('.wf-clip-in');
    const head = host.querySelector('.wf-head');
    const marks = host.querySelector('.wf-marks');
    const tbub = host.querySelector('.wf-time');
    const tbubText = tbub.querySelector('span');
    const cb = host.querySelector('.wf-cbubble');
    let W = 0;
    let lastF = -1;
    let scrubbing = false;
    let scrubF = 0;
    let marksType = null;
    let active = true;
    let lastBubble = -1e9;
    let bubbleTimer = 0;
    let bubbleOn = !!o.bubble;

    function draw() {
      W = host.offsetWidth || o.width || 300;
      const n = Math.max(20, Math.floor(W / o.pitch));
      const vals = resample(P.track.wave, n);
      const d = roundedBars(vals, n * o.pitch, o.height, o.pitch, o.barW, o.minH);
      host.querySelectorAll('.wf-svg').forEach((s) => {
        s.setAttribute('viewBox', `0 0 ${n * o.pitch} ${o.height}`);
        s.setAttribute('width', n * o.pitch);
        s.setAttribute('height', o.height);
        s.querySelector('path').setAttribute('d', d);
      });
      lastF = -1;
      renderMarks();
    }
    function renderMarks() {
      const t = P.track;
      let html = '';
      if (marksType === 'segments' && t.setlist) html = t.setlist.slice(1).map((s) => `<i class="wf-seg" style="left:${((s.t / t.duration) * 100).toFixed(3)}%"></i>`).join('');
      if (marksType === 'comments') html = t.comments.map((c) => `<i class="wf-dot" style="left:${((c.t / t.duration) * 100).toFixed(3)}%"></i>`).join('');
      marks.innerHTML = html;
      marks.classList.toggle('on', !!html);
    }
    function setMarks(type) {
      if (type === marksType) return;
      marksType = type;
      if (!type) {
        marks.classList.remove('on');
        return;
      }
      renderMarks();
    }
    function fAt(e) {
      const r = track.getBoundingClientRect();
      return clamp((e.clientX - r.left) / r.width, 0, 1);
    }
    function showTime(f) {
      tbubText.textContent = fmt(f * P.track.duration);
      const x = clamp(f * W, 26, W - 26);
      tbub.style.transform = `translate3d(${x}px,0,0)`;
    }
    if (o.scrub) {
      host.addEventListener('pointerdown', (e) => {
        if (e.button !== 0) return;
        e.stopPropagation();
        host.setPointerCapture(e.pointerId);
        scrubbing = true;
        scrubF = fAt(e);
        host.classList.add('scrubbing');
        showTime(scrubF);
        if (o.onScrub) o.onScrub(scrubF * P.track.duration);
      });
      host.addEventListener('pointermove', (e) => {
        if (!scrubbing) return;
        scrubF = fAt(e);
        showTime(scrubF);
        if (o.onScrub) o.onScrub(scrubF * P.track.duration);
      });
      const end = () => {
        if (!scrubbing) return;
        scrubbing = false;
        host.classList.remove('scrubbing');
        P.seek(scrubF * P.track.duration);
        if (o.onScrub) o.onScrub(null);
      };
      host.addEventListener('pointerup', end);
      host.addEventListener('pointercancel', end);
    }
    function nudge(dt) {
      const f = clamp((P.pos() + dt) / P.track.duration, 0, 1);
      showTime(f);
      host.classList.add('nudging');
      clearTimeout(nudge.t);
      nudge.t = setTimeout(() => host.classList.remove('nudging'), 900);
      P.seek(f * P.track.duration);
    }
    NP.onFrame((p) => {
      if (!active) return;
      const f = scrubbing ? scrubF : p / P.track.duration;
      if (Math.abs(f - lastF) < 0.00002) return;
      lastF = f;
      clip.style.transform = `translate3d(${((f - 1) * 100).toFixed(4)}%,0,0)`;
      clipIn.style.transform = `translate3d(${((1 - f) * 100).toFixed(4)}%,0,0)`;
      head.style.transform = `translate3d(${(f * W).toFixed(2)}px,0,0)`;
    });
    P.on('comment', (c) => {
      if (!bubbleOn || !active) return;
      const now = performance.now();
      if (now - lastBubble < 7000) return;
      lastBubble = now;
      cb.innerHTML = `${NP.avatar(c.user, 'xs')}<span class="cb-text">${esc(c.text)}</span>`;
      const inset = o.bubbleInset != null ? o.bubbleInset : Math.round(W * 0.12);
      cb.style.maxWidth = Math.min(W - inset * 2, o.bubbleMax || 300) + 'px';
      const bw = cb.offsetWidth;
      const x = clamp((c.t / P.track.duration) * W, inset + bw / 2, W - inset - bw / 2);
      cb.style.setProperty('--x', x + 'px');
      cb.classList.add('on');
      clearTimeout(bubbleTimer);
      bubbleTimer = setTimeout(() => cb.classList.remove('on'), 3600);
    });
    P.on('track', () => {
      cb.classList.remove('on');
      draw();
    });
    requestAnimationFrame(draw);
    addEventListener('resize', () => requestAnimationFrame(draw));
    return {
      el: host, draw, setMarks, nudge, showTime,
      setActive(v) { active = v; if (v) lastF = -1; },
      setBubble(v) { bubbleOn = v; if (!v) cb.classList.remove('on'); },
      get scrubbing() { return scrubbing; },
    };
  };

  function rpoly(pts, r) {
    let d = '';
    const n = pts.length;
    for (let i = 0; i < n; i++) {
      const p0 = pts[(i - 1 + n) % n];
      const p1 = pts[i];
      const p2 = pts[(i + 1) % n];
      const v1x = p0[0] - p1[0];
      const v1y = p0[1] - p1[1];
      const v2x = p2[0] - p1[0];
      const v2y = p2[1] - p1[1];
      const l1 = Math.hypot(v1x, v1y) || 1;
      const l2 = Math.hypot(v2x, v2y) || 1;
      const rr = Math.min(r, l1 / 2, l2 / 2);
      const ax = p1[0] + (v1x / l1) * rr;
      const ay = p1[1] + (v1y / l1) * rr;
      const bx = p1[0] + (v2x / l2) * rr;
      const by = p1[1] + (v2y / l2) * rr;
      d += `${i ? 'L' : 'M'}${ax.toFixed(3)} ${ay.toFixed(3)}Q${p1[0]} ${p1[1]} ${bx.toFixed(3)} ${by.toFixed(3)}`;
    }
    return d + 'Z';
  }
  const SHAPES = {
    pause: [[[5.6, 4.2], [10, 4.2], [10, 19.8], [5.6, 19.8]], [[14, 4.2], [18.4, 4.2], [18.4, 19.8], [14, 19.8]]],
    play: [[[6.6, 3.9], [13.7, 8.1], [13.7, 15.9], [6.6, 20.1]], [[13.3, 7.86], [20.4, 11.85], [20.4, 12.15], [13.3, 16.14]]],
  };
  NP.PlayGlyph = function (cls = '') {
    const el = h(`<svg class="ic pp ${cls}" viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor"/><path fill="currentColor"/></svg>`);
    const paths = el.querySelectorAll('path');
    let state = null;
    let cur = null;
    let stop = null;
    function paint(shape) {
      paths[0].setAttribute('d', rpoly(shape[0], 1.5));
      paths[1].setAttribute('d', rpoly(shape[1], 1.5));
    }
    function set(playing, instant) {
      const target = playing ? SHAPES.pause : SHAPES.play;
      if (state === playing) return;
      state = playing;
      el.setAttribute('aria-label', playing ? 'Pause' : 'Play');
      if (instant || !cur) {
        cur = target.map((q) => q.map((p) => p.slice()));
        paint(cur);
        return;
      }
      const from = cur.map((q) => q.map((p) => p.slice()));
      if (stop) stop();
      stop = NP.animate(0, 1, (x) => {
        cur = from.map((q, qi) => q.map((p, pi) => [p[0] + (target[qi][pi][0] - p[0]) * x, p[1] + (target[qi][pi][1] - p[1]) * x]));
        paint(cur);
      }, { response: 0.34, damping: 0.78 });
    }
    return { el, set };
  };

  NP.Transport = function (host, { cls = '' } = {}) {
    host.classList.add('transport');
    if (cls) host.classList.add(cls);
    const pp = NP.PlayGlyph();
    host.innerHTML = `<button class="tp tp-prev" aria-label="Previous">${icon('prev')}</button><button class="tp tp-play"></button><button class="tp tp-next" aria-label="Next">${icon('next')}</button>`;
    host.querySelector('.tp-play').appendChild(pp.el);
    host.querySelector('.tp-prev').onclick = (e) => { e.stopPropagation(); P.prev(); };
    host.querySelector('.tp-next').onclick = (e) => { e.stopPropagation(); P.next(); };
    host.querySelector('.tp-play').onclick = (e) => { e.stopPropagation(); P.toggle(); };
    host.querySelectorAll('.tp').forEach((b) => b.addEventListener('pointerdown', (e) => e.stopPropagation()));
    pp.set(P.playing, true);
    P.on('playstate', (v) => pp.set(v));
    return { pp };
  };

  NP.Slider = function (host, { get, set, left = 'volLow', right = 'volHigh', evt = 'volume' } = {}) {
    host.classList.add('slider');
    host.innerHTML = `${left ? icon(left, 'sl-l') : ''}<div class="sl-track"><div class="sl-bar"><i class="sl-fill"></i></div></div>${right ? icon(right, 'sl-r') : ''}`;
    const tr = host.querySelector('.sl-track');
    const fill = host.querySelector('.sl-fill');
    let drag = false;
    const paint = () => (fill.style.transform = `scaleX(${get()})`);
    const at = (e) => {
      const r = tr.getBoundingClientRect();
      return clamp((e.clientX - r.left) / r.width, 0, 1);
    };
    tr.addEventListener('pointerdown', (e) => {
      e.stopPropagation();
      tr.setPointerCapture(e.pointerId);
      drag = true;
      host.classList.add('active');
      set(at(e));
    });
    tr.addEventListener('pointermove', (e) => drag && set(at(e)));
    const end = () => {
      drag = false;
      host.classList.remove('active');
    };
    tr.addEventListener('pointerup', end);
    tr.addEventListener('pointercancel', end);
    P.on(evt, paint);
    paint();
    return { paint };
  };

  NP.flip = function (container, sel, mutate) {
    const before = new Map();
    container.querySelectorAll(sel).forEach((el) => before.set(el.dataset.id, el.getBoundingClientRect().top));
    mutate();
    if (NP.reduceMotion) return;
    container.querySelectorAll(sel).forEach((el) => {
      const b = before.get(el.dataset.id);
      if (b == null) return;
      const dy = (b - el.getBoundingClientRect().top) / (NP.stageScale || 1);
      if (Math.abs(dy) < 1) return;
      el.style.transition = 'none';
      el.style.transform = `translate3d(0,${dy}px,0)`;
      requestAnimationFrame(() => requestAnimationFrame(() => {
        el.style.transition = '';
        el.style.transform = '';
      }));
    });
  };

  function trackRow(t, { handle = true, cls = '' } = {}) {
    return `<div class="qrow ${cls}" data-id="${t.id}" tabindex="-1"><img class="qart" src="${t.artURL}" alt=""><div class="qtext"><div class="qt">${esc(t.short || t.title)}</div><div class="qa">${esc(t.artist)}</div></div><span class="qdur">${fmt(t.duration)}</span>${handle ? `<span class="handle" aria-label="Reorder">${icon('handle')}</span>` : ''}</div>`;
  }
  NP.trackRow = trackRow;

  function UpNextPane(el, ctx) {
    let dirty = true;
    let activeNow = false;
    function render() {
      const t = P.track;
      const up = P.upcoming();
      const next = up.filter((x) => P.playNext.has(x.id));
      const rest = up.filter((x) => !P.playNext.has(x.id));
      const opt = { handle: ctx.handles !== false };
      el.innerHTML = `<div class="pane-head"><div class="pane-titles"><div class="eyebrow">Playing from</div><div class="pane-title">${esc(t.playlist)}</div></div><div class="pane-acts"><button class="tog${P.shuffle ? ' on' : ''}" data-a="shuffle" aria-label="Shuffle">${icon('shuffle')}</button><button class="tog${P.repeat !== 'off' ? ' on' : ''}" data-a="repeat" aria-label="Repeat">${icon(P.repeat === 'one' ? 'repeat1' : 'repeat')}</button></div></div>
<div class="pane-scroll">${next.length ? `<div class="sec">Playing Next</div><div class="qlist" data-sec="next">${next.map((x) => trackRow(x, opt)).join('')}</div>` : ''}<div class="sec">Continue Playing<span class="sec-sub">${P.automix ? 'Auto Mix on' : ''}</span></div><div class="qlist" data-sec="rest">${rest.map((x) => trackRow(x, opt)).join('')}</div></div>`;
      dirty = false;
    }
    el.addEventListener('click', (e) => {
      const tog = e.target.closest('.tog');
      if (tog) {
        const scroll = el.querySelector('.pane-scroll');
        NP.flip(el, '.qrow', () => {
          tog.dataset.a === 'shuffle' ? P.toggleShuffle() : P.cycleRepeat();
        });
        const s2 = el.querySelector('.pane-scroll');
        if (scroll && s2) s2.scrollTop = scroll.scrollTop;
        return;
      }
      const row = e.target.closest('.qrow');
      if (row && !e.target.closest('.handle')) P.playId(row.dataset.id);
    });
    el.addEventListener('pointerdown', (e) => {
      const hd = e.target.closest('.handle');
      if (!hd) return;
      e.preventDefault();
      e.stopPropagation();
      const row = hd.closest('.qrow');
      const list = row.parentElement;
      const rows = Array.from(list.children);
      const idx = rows.indexOf(row);
      const s = NP.stageScale || 1;
      const rh = row.getBoundingClientRect().height / s;
      const y0 = e.clientY;
      let target = idx;
      row.classList.add('dragging');
      hd.setPointerCapture(e.pointerId);
      const move = (ev) => {
        const dy = (ev.clientY - y0) / s;
        row.style.transform = `translate3d(0,${dy}px,0) scale(1.02)`;
        target = clamp(idx + Math.round(dy / rh), 0, rows.length - 1);
        rows.forEach((r, i) => {
          if (r === row) return;
          let off = 0;
          if (idx < target && i > idx && i <= target) off = -rh;
          if (idx > target && i < idx && i >= target) off = rh;
          r.style.transform = off ? `translate3d(0,${off}px,0)` : '';
        });
      };
      const up = () => {
        hd.removeEventListener('pointermove', move);
        hd.removeEventListener('pointerup', up);
        hd.removeEventListener('pointercancel', up);
        row.classList.remove('dragging');
        row.style.transform = `translate3d(0,${(target - idx) * rh}px,0)`;
        setTimeout(() => {
          if (target !== idx) {
            const scroll = el.querySelector('.pane-scroll').scrollTop;
            P.move(row.dataset.id, rows[target].dataset.id);
            el.querySelector('.pane-scroll').scrollTop = scroll;
          } else rows.forEach((r) => (r.style.transform = ''));
        }, NP.reduceMotion ? 0 : 220);
      };
      hd.addEventListener('pointermove', move);
      hd.addEventListener('pointerup', up);
      hd.addEventListener('pointercancel', up);
    });
    const mark = () => {
      dirty = true;
      if (activeNow) render();
    };
    P.on('track', mark);
    P.on('queue', () => { dirty = true; render(); });
    P.on('automix', mark);
    return {
      activate() { activeNow = true; if (dirty) render(); },
      deactivate() { activeNow = false; },
    };
  }

  function commentRow(c, cls = '') {
    return `<div class="crow ${cls}${c.mine ? ' mine' : ''}" data-id="${c.id}" data-t="${c.t}">${NP.avatar(c.user)}<div class="cbody"><div class="cmeta"><span class="cname">${esc(c.user)}</span><span class="ctime">${fmt(c.t)}</span></div><div class="ctext">${esc(c.text)}</div></div></div>`;
  }

  function CommentsPane(el, ctx) {
    let activeNow = false;
    let lastSec = -1;
    let userScrollAt = -1e9;
    let curId = null;
    el.innerHTML = `<div class="pane-head"><div class="pane-titles"><div class="eyebrow follow"><i></i>Following playback</div><div class="pane-title"></div></div></div><div class="pane-scroll"><div class="clist"></div><div class="cmore"></div></div>${ctx.compose === false ? '' : `<form class="compose">${NP.avatar('You', 'sm')}<input type="text" enterkeyhint="send" autocomplete="off" aria-label="Add a comment"><button class="send" type="submit" aria-label="Post">${icon('send')}</button></form>`}`;
    const list = el.querySelector('.clist');
    const more = el.querySelector('.cmore');
    const title = el.querySelector('.pane-title');
    const scroll = el.querySelector('.pane-scroll');
    const form = el.querySelector('.compose');
    const input = form && form.querySelector('input');
    scroll.addEventListener('wheel', () => (userScrollAt = performance.now()), { passive: true });
    scroll.addEventListener('touchmove', () => (userScrollAt = performance.now()), { passive: true });
    function counts(pos) {
      const t = P.track;
      const later = t.comments.filter((c) => c.t > pos).length;
      title.textContent = `${t.comments.length} comments`;
      more.textContent = later ? `${later} more later in this ${t.kind === 'mix' ? 'mix' : 'track'}` : '';
    }
    function current(pos) {
      const vis = P.track.comments.filter((c) => c.t <= pos + 0.5);
      const last = vis[vis.length - 1];
      const id = last && pos - last.t < 25 ? last.id : null;
      if (id === curId) return;
      curId = id;
      list.querySelectorAll('.crow.current').forEach((r) => r.classList.remove('current'));
      if (id) {
        const r = list.querySelector(`[data-id="${CSS.escape(id)}"]`);
        if (r) r.classList.add('current');
      }
    }
    function toBottom(smooth) {
      if (performance.now() - userScrollAt < 4000) return;
      scroll.scrollTo({ top: scroll.scrollHeight, behavior: smooth && !NP.reduceMotion ? 'smooth' : 'auto' });
    }
    function render() {
      const pos = P.pos();
      const vis = P.track.comments.filter((c) => c.t <= pos + 0.5);
      list.innerHTML = vis.length ? vis.map((c) => commentRow(c)).join('') : `<div class="empty">No comments yet at this point.<br>Be the first.</div>`;
      curId = undefined;
      current(pos);
      counts(pos);
      requestAnimationFrame(() => toBottom(false));
    }
    function append(c) {
      if (!activeNow) return;
      const empty = list.querySelector('.empty');
      if (empty) empty.remove();
      if (list.querySelector(`[data-id="${CSS.escape(c.id)}"]`)) return;
      const row = h(commentRow(c, 'enter'));
      list.appendChild(row);
      requestAnimationFrame(() => requestAnimationFrame(() => row.classList.remove('enter')));
      curId = undefined;
      current(P.pos() + 1);
      counts(P.pos());
      toBottom(true);
    }
    list.addEventListener('click', (e) => {
      const r = e.target.closest('.crow');
      if (r) P.seek(+r.dataset.t);
    });
    if (form) {
      form.addEventListener('submit', (e) => {
        e.preventDefault();
        const v = input.value.trim();
        if (!v) return;
        input.value = '';
        userScrollAt = -1e9;
        const c = P.addComment(v);
        append(c);
        if (input.blur) input.blur();
      });
      form.addEventListener('pointerdown', (e) => e.stopPropagation());
    }
    P.on('comment', append);
    P.on('seek', () => activeNow && render());
    P.on('track', () => activeNow && render());
    NP.onFrame((p) => {
      if (!activeNow) return;
      const s = Math.floor(p);
      if (s === lastSec) return;
      lastSec = s;
      if (input) input.placeholder = `Comment at ${fmt(p)}`;
      current(p);
    });
    return {
      activate() { activeNow = true; render(); },
      deactivate() { activeNow = false; },
    };
  }

  function SetlistPane(el, ctx) {
    let activeNow = false;
    let userScrollAt = -1e9;
    let idState = 'idle';
    let found = null;
    let bar = null;
    let curRow = null;
    el.innerHTML = `<div class="pane-head"><div class="pane-titles"><div class="eyebrow sl-sub"></div><div class="pane-title"></div></div><div class="pane-acts"><button class="identify" aria-label="Identify"><span class="id-rings"><i></i><i></i></span>${icon('identify')}<span class="id-l">Identify</span></button></div></div><div class="pane-stack"><div class="idcard"></div><div class="pane-scroll"><div class="slist"></div></div></div>`;
    const list = el.querySelector('.slist');
    const scroll = el.querySelector('.pane-scroll');
    const title = el.querySelector('.pane-title');
    const btn = el.querySelector('.identify');
    const card = el.querySelector('.idcard');
    scroll.addEventListener('wheel', () => (userScrollAt = performance.now()), { passive: true });
    scroll.addEventListener('touchmove', () => (userScrollAt = performance.now()), { passive: true });
    function render() {
      const t = P.track;
      const sl = t.setlist;
      el.classList.toggle('no-setlist', !sl);
      if (!sl) {
        title.textContent = 'No tracklist';
        el.querySelector('.sl-sub').textContent = 'Single track';
        list.innerHTML = `<div class="empty">Tracklists appear for DJ mixes and long sets.<br>Identify still works on anything playing.</div>`;
        bar = null;
        curRow = null;
        return;
      }
      title.textContent = `${sl.length} tracks`;
      const unk = sl.filter((x) => x.unknown).length;
      el.querySelector('.sl-sub').textContent = unk ? `${sl.length - unk} identified · ${unk} unknown` : 'All identified';
      list.innerHTML = sl.map((s, i) => `<div class="srow${s.unknown ? ' unknown' : ''}" data-i="${i}" tabindex="-1"><span class="stime">${fmt(s.t)}</span><div class="stext"><div class="st">${s.unknown ? 'ID' : esc(s.title)}</div><div class="sa">${s.unknown ? 'Unidentified' : esc(s.artist)}</div></div><span class="snow">${icon('speakerNow')}</span><i class="sprog"></i></div>`).join('');
      mark(P.seg, false);
    }
    function mark(i, smooth) {
      list.querySelectorAll('.srow.current').forEach((r) => r.classList.remove('current'));
      curRow = list.querySelector(`.srow[data-i="${i}"]`);
      bar = curRow ? curRow.querySelector('.sprog') : null;
      if (!curRow) return;
      curRow.classList.add('current');
      if (performance.now() - userScrollAt > 5000) {
        const top = curRow.offsetTop - scroll.clientHeight * 0.28;
        scroll.scrollTo({ top: Math.max(0, top), behavior: smooth && !NP.reduceMotion ? 'smooth' : 'auto' });
      }
    }
    list.addEventListener('click', (e) => {
      const r = e.target.closest('.srow');
      if (!r) return;
      userScrollAt = -1e9;
      P.seek(P.track.setlist[+r.dataset.i].t + 0.05);
    });
    function setId(state) {
      idState = state;
      btn.dataset.state = state;
      btn.querySelector('.id-l').textContent = state === 'listening' ? 'Listening…' : 'Identify';
    }
    function identify() {
      if (idState === 'listening') return;
      setId('listening');
      card.innerHTML = `<div class="idc listening"><div class="idc-art"><span class="id-rings big"><i></i><i></i><i></i></span>${icon('identify')}</div><div class="idc-text"><div class="idc-t">Listening…</div><div class="idc-s">Hold on while we match ${fmt(P.pos())}</div></div></div>`;
      card.classList.add('on');
      const at = P.pos();
      setTimeout(() => {
        const t = P.track;
        const sl = t.setlist;
        const i = P.seg;
        const s = sl && sl[i];
        let res;
        if (s && s.unknown) res = { ...s.match, fill: i };
        else if (s) res = { artist: s.artist, title: s.title, note: 'Already in this tracklist', known: true };
        else res = { artist: t.artist, title: t.title, note: 'Matches the uploaded track', known: true };
        found = res;
        setId('idle');
        const art = D.tracks.find((x) => x.artist === res.artist && x.kind === 'song') || D.byId[{ 'Ardent Fields': 'f2', 'Moss Atlas': 'f4' }[res.artist]] || t;
        card.innerHTML = `<div class="idc found"><img class="idc-img" src="${art.artURL}" alt=""><div class="idc-text"><div class="idc-k">${icon('check')} Found at ${fmt(at)}</div><div class="idc-t">${esc(res.title)}</div><div class="idc-s">${esc(res.artist)} · ${esc(res.note)}</div></div>${res.known ? '<button class="idc-btn ghost" data-a="dismiss">Done</button>' : '<button class="idc-btn" data-a="add">Add</button>'}</div>`;
      }, NP.shot ? (NP.params.get('identify') === 'listening' ? 1e9 : 0) : 2600);
    }
    btn.onclick = (e) => { e.stopPropagation(); identify(); };
    card.addEventListener('click', (e) => {
      const b = e.target.closest('.idc-btn');
      if (!b) return;
      if (b.dataset.a === 'add' && found && found.fill != null) {
        const s = P.track.setlist[found.fill];
        Object.assign(s, { artist: found.artist, title: found.title, unknown: false, added: true });
        render();
        const r = list.querySelector(`.srow[data-i="${found.fill}"]`);
        if (r) {
          r.classList.add('filled');
          setTimeout(() => r.classList.remove('filled'), 1600);
        }
      }
      card.classList.remove('on');
      found = null;
    });
    P.on('segment', (i) => activeNow && mark(i, true));
    P.on('track', () => {
      card.classList.remove('on');
      setId('idle');
      if (activeNow) render();
    });
    NP.onFrame((p) => {
      if (!activeNow || !bar) return;
      const sl = P.track.setlist;
      const i = P.seg;
      if (!sl || i < 0) return;
      const end = i < sl.length - 1 ? sl[i + 1].t : P.track.duration;
      const f = clamp((p - sl[i].t) / (end - sl[i].t), 0, 1);
      bar.style.transform = `scaleX(${f.toFixed(4)})`;
    });
    return {
      activate() { activeNow = true; render(); },
      deactivate() { activeNow = false; },
      identify,
    };
  }

  function AboutPane(el) {
    let activeNow = false;
    function render() {
      const t = P.track;
      el.innerHTML = `<div class="pane-head"><div class="pane-titles"><div class="eyebrow">About</div><div class="pane-title">${esc(t.artist)}</div></div></div><div class="pane-scroll about"><p class="desc">${esc(t.description)}</p>
<div class="stats"><div><b>${t.plays}</b><span>Plays</span></div><div><b>${t.likes}</b><span>Likes</span></div><div><b>${t.reposts}</b><span>Reposts</span></div><div><b>${t.comments.length}</b><span>Comments</span></div></div>
<div class="facts"><div><span>BPM</span><b>${t.bpm}</b></div><div><span>Key</span><b>${esc(t.key)}</b></div><div><span>Genre</span><b>${esc(t.genre)}</b></div><div><span>Length</span><b>${fmt(t.duration)}</b></div><div><span>Posted</span><b>${esc(t.posted)}</b></div></div>
<div class="tags">${t.tags.map((x) => `<span>#${esc(x)}</span>`).join('')}</div></div>`;
    }
    P.on('track', () => activeNow && render());
    return {
      activate() { activeNow = true; render(); },
      deactivate() { activeNow = false; },
    };
  }

  const PANES = { upnext: UpNextPane, comments: CommentsPane, setlist: SetlistPane, about: AboutPane };
  NP.TAB_LABELS = { upnext: 'Up Next', comments: 'Comments', setlist: 'Tracklist', about: 'About' };

  NP.Segmented = function (host, items, onPick) {
    host.classList.add('seg');
    host.innerHTML = `<i class="seg-thumb"></i>${items.map(([id, l]) => `<button data-id="${id}">${esc(l)}</button>`).join('')}`;
    const thumb = host.querySelector('.seg-thumb');
    const btns = Array.from(host.querySelectorAll('button'));
    host.style.setProperty('--n', items.length);
    btns.forEach((b) => (b.onclick = (e) => { e.stopPropagation(); onPick(b.dataset.id); }));
    return {
      set(id) {
        const i = btns.findIndex((b) => b.dataset.id === id);
        btns.forEach((b, k) => b.classList.toggle('on', k === i));
        thumb.style.transform = `translate3d(${i * 100}%,0,0)`;
        thumb.style.opacity = i < 0 ? 0 : 1;
      },
    };
  };

  NP.Panes = function (host, { tabs, tabBar = true, variant = 'phone', compose = true, handles = true, initial = null }) {
    host.classList.add('panes', 'v-' + variant);
    host.innerHTML = `${tabBar ? '<div class="panes-tabs"></div>' : ''}<div class="panes-body"></div>`;
    const body = host.querySelector('.panes-body');
    const map = {};
    let seg = null;
    let active = null;
    if (tabBar) seg = NP.Segmented(host.querySelector('.panes-tabs'), tabs.map((t) => [t, NP.TAB_LABELS[t]]), (id) => api.show(id));
    tabs.forEach((id) => {
      const el = h(`<section class="pane pane-${id}" data-pane="${id}"></section>`);
      body.appendChild(el);
      map[id] = { el, ctl: PANES[id](el, { variant, compose, handles }) };
    });
    const subs = [];
    const api = {
      show(id) {
        if (id === active) return;
        Object.entries(map).forEach(([k, v]) => {
          const on = k === id;
          v.el.classList.toggle('on', on);
          v.el.inert = !on;
          if (on) v.ctl.activate();
          else v.ctl.deactivate();
        });
        active = id;
        if (seg) seg.set(id);
        subs.forEach((f) => f(id));
      },
      get active() { return active; },
      onChange(f) { subs.push(f); },
      pane(id) { return map[id] && map[id].ctl; },
      el: host,
    };
    if (initial) api.show(initial);
    return api;
  };

  NP.Sheet = function (host, { title = '', body, cls = '', onClose } = {}) {
    const scrim = h('<div class="sheet-scrim"></div>');
    const sheet = h(`<div class="sheet glass ${cls}" role="dialog"><div class="sheet-grab"><i></i></div>${title ? `<div class="sheet-head"><div class="sheet-title">${esc(title)}</div><button class="sheet-x" aria-label="Close">${icon('close')}</button></div>` : ''}<div class="sheet-body"></div></div>`);
    sheet.querySelector('.sheet-body').appendChild(body);
    host.appendChild(scrim);
    host.appendChild(sheet);
    requestAnimationFrame(() => requestAnimationFrame(() => {
      scrim.classList.add('on');
      sheet.classList.add('on');
    }));
    let closed = false;
    function close() {
      if (closed) return;
      closed = true;
      scrim.classList.remove('on');
      sheet.classList.remove('on');
      sheet.style.transform = '';
      sheet.classList.add('closing');
      setTimeout(() => {
        scrim.remove();
        sheet.remove();
      }, NP.reduceMotion ? 50 : 520);
      if (onClose) onClose();
    }
    scrim.addEventListener('pointerdown', (e) => { e.stopPropagation(); close(); });
    sheet.addEventListener('pointerdown', (e) => e.stopPropagation());
    const x = sheet.querySelector('.sheet-x');
    if (x) x.onclick = close;
    const grab = sheet.querySelector('.sheet-grab');
    const headEl = sheet.querySelector('.sheet-head') || grab;
    [grab, headEl].forEach((g) => g.addEventListener('pointerdown', (e) => {
      if (e.target.closest('button')) return;
      const s = NP.stageScale || 1;
      const y0 = e.clientY;
      g.setPointerCapture(e.pointerId);
      sheet.style.transition = 'none';
      let dy = 0;
      const mv = (ev) => {
        dy = Math.max(0, (ev.clientY - y0) / s);
        sheet.style.transform = `translate3d(0,${dy}px,0)`;
      };
      const up = () => {
        g.removeEventListener('pointermove', mv);
        g.removeEventListener('pointerup', up);
        sheet.style.transition = '';
        if (dy > 90) close();
        else sheet.style.transform = '';
      };
      g.addEventListener('pointermove', mv);
      g.addEventListener('pointerup', up);
    }));
    return { close, el: sheet };
  };

  NP.Menu = function (host, anchor, items, { align = 'right', below = true, cls = '' } = {}) {
    const s = NP.stageScale || 1;
    const hr = host.getBoundingClientRect();
    const ar = anchor.getBoundingClientRect();
    const menu = h(`<div class="menu glass ${cls}" role="menu"></div>`);
    items.forEach((it) => {
      if (it === '-') return menu.appendChild(h('<div class="menu-sep"></div>'));
      const b = h(`<button class="menu-item${it.on ? ' on' : ''}" role="menuitem"><span class="mi-check">${it.check ? icon('check') : ''}</span><span class="mi-l">${esc(it.label)}${it.sub ? `<small>${esc(it.sub)}</small>` : ''}</span>${it.icon ? icon(it.icon, 'mi-ic') : ''}</button>`);
      b.onclick = (e) => {
        e.stopPropagation();
        close();
        if (it.fn) setTimeout(it.fn, 60);
      };
      menu.appendChild(b);
    });
    const catcher = h('<div class="menu-catch"></div>');
    host.appendChild(catcher);
    host.appendChild(menu);
    const x = (ar.left - hr.left) / s;
    const y = (ar.top - hr.top) / s;
    const aw = ar.width / s;
    const ahh = ar.height / s;
    const mw = menu.offsetWidth;
    const mh = menu.offsetHeight;
    const hw = hr.width / s;
    const hh = hr.height / s;
    let left = align === 'right' ? x + aw - mw : align === 'center' ? x + aw / 2 - mw / 2 : x;
    left = clamp(left, 12, hw - mw - 12);
    let top = below ? y + ahh + 8 : y - mh - 8;
    if (top + mh > hh - 12) top = y - mh - 8;
    top = Math.max(12, top);
    menu.style.left = left + 'px';
    menu.style.top = top + 'px';
    menu.style.transformOrigin = `${x + aw / 2 - left}px ${y + ahh / 2 - top}px`;
    requestAnimationFrame(() => requestAnimationFrame(() => menu.classList.add('on')));
    const onKey = (e) => {
      if (e.key !== 'Escape') return;
      e.stopImmediatePropagation();
      close();
    };
    addEventListener('keydown', onKey, true);
    function close() {
      removeEventListener('keydown', onKey, true);
      menu.classList.remove('on');
      catcher.remove();
      setTimeout(() => menu.remove(), NP.reduceMotion ? 30 : 320);
    }
    catcher.addEventListener('pointerdown', (e) => { e.stopPropagation(); close(); });
    return { close, el: menu };
  };


  NP.Popover = function (host, anchor, content, { align = 'right', below = true, cls = '', width = 340 } = {}) {
    const s = NP.stageScale || 1;
    const hr = host.getBoundingClientRect();
    const ar = anchor.getBoundingClientRect();
    const pop = h(`<div class="menu popover ${cls}" role="dialog"></div>`);
    pop.style.width = width + 'px';
    pop.appendChild(content);
    const catcher = h('<div class="menu-catch"></div>');
    host.appendChild(catcher);
    host.appendChild(pop);
    const x = (ar.left - hr.left) / s;
    const y = (ar.top - hr.top) / s;
    const aw = ar.width / s;
    const ahh = ar.height / s;
    const mw = pop.offsetWidth;
    const mh = pop.offsetHeight;
    const hw = hr.width / s;
    const hh = hr.height / s;
    let left = align === 'right' ? x + aw - mw : align === 'center' ? x + aw / 2 - mw / 2 : x;
    left = clamp(left, 12, hw - mw - 12);
    let top = below ? y + ahh + 10 : y - mh - 10;
    if (top + mh > hh - 12) top = y - mh - 10;
    top = Math.max(12, top);
    pop.style.left = left + 'px';
    pop.style.top = top + 'px';
    pop.style.transformOrigin = `${x + aw / 2 - left}px ${y + ahh / 2 - top}px`;
    requestAnimationFrame(() => requestAnimationFrame(() => pop.classList.add('on')));
    let closed = false;
    const onKey = (e) => {
      if (e.key !== 'Escape') return;
      e.stopImmediatePropagation();
      close();
    };
    addEventListener('keydown', onKey, true);
    function close() {
      if (closed) return;
      closed = true;
      removeEventListener('keydown', onKey, true);
      pop.classList.remove('on');
      catcher.remove();
      setTimeout(() => pop.remove(), NP.reduceMotion ? 30 : 320);
    }
    catcher.addEventListener('pointerdown', (e) => { e.stopPropagation(); close(); });
    pop.addEventListener('pointerdown', (e) => e.stopPropagation());
    return { close, el: pop };
  };

  NP.ArtCarousel = function (slot, { gap = 48, enabled = () => true, radius = 14 } = {}) {
    slot.classList.add('acar');
    slot.innerHTML = '<div class="acar-strip"></div>';
    const strip = slot.firstChild;
    let pending = null;
    let revealT = 0;
    const ms = () => parseInt(getComputedStyle(document.documentElement).getPropertyValue('--spring-ms'), 10) || 600;
    const W = () => slot.offsetWidth + gap;
    function render() {
      strip.innerHTML = [-1, 0, 1].map((k) => `<div class="acar-slide" data-k="${k}" style="left:${k * W()}px;border-radius:${radius}px"><img src="${P.neighbour(k).artURL}" alt=""></div>`).join('');
    }
    render();
    P.on('track', ({ dir }) => {
      render();
      const start = pending != null ? pending : dir * W();
      pending = null;
      if (NP.reduceMotion || !enabled()) {
        strip.classList.remove('anim', 'reveal');
        strip.style.transform = '';
        return;
      }
      strip.classList.remove('anim');
      strip.classList.add('reveal');
      strip.style.transform = `translate3d(${start}px,0,0)`;
      void strip.offsetWidth;
      strip.classList.add('anim');
      strip.style.transform = '';
      clearTimeout(revealT);
      revealT = setTimeout(() => strip.classList.remove('reveal'), ms());
    });
    let g = null;
    slot.addEventListener('pointerdown', (e) => {
      if (e.button !== 0 || !enabled()) return;
      g = { id: e.pointerId, x: e.clientX, lx: e.clientX, lt: performance.now(), vx: 0, on: false };
      slot.setPointerCapture(e.pointerId);
    });
    slot.addEventListener('pointermove', (e) => {
      if (!g || e.pointerId !== g.id) return;
      const s = NP.stageScale || 1;
      const dx = (e.clientX - g.x) / s;
      const now = performance.now();
      g.vx = (e.clientX - g.lx) / s / Math.max(1, now - g.lt);
      g.lx = e.clientX;
      g.lt = now;
      if (!g.on && Math.abs(dx) < 6) return;
      if (!g.on) {
        g.on = true;
        clearTimeout(revealT);
        strip.classList.remove('anim');
        strip.classList.add('reveal');
      }
      strip.style.transform = `translate3d(${dx}px,0,0)`;
    });
    const end = (e) => {
      if (!g || e.pointerId !== g.id) return;
      const s = NP.stageScale || 1;
      const dx = (e.clientX - g.x) / s;
      if (g.on) {
        const commit = Math.abs(dx) > slot.offsetWidth * 0.28 || (Math.abs(g.vx) > 0.45 && Math.sign(g.vx) === Math.sign(dx));
        if (commit) {
          const dir = dx < 0 ? 1 : -1;
          pending = dx + dir * W();
          P.setIndex(P.index + dir, dir);
        } else {
          strip.classList.add('anim');
          strip.style.transform = '';
          revealT = setTimeout(() => strip.classList.remove('reveal'), ms());
        }
      }
      g = null;
    };
    slot.addEventListener('pointerup', end);
    slot.addEventListener('pointercancel', end);
    return { render };
  };


  NP.bindMeta = function (o) {
    const overflow = (el) => el && el.classList.toggle('over', el.scrollWidth > el.clientWidth + 1);
    let lastSec = -1;
    let scrubT = null;
    function paintLike(pop) {
      if (!o.like) return;
      const on = P.liked.has(P.track.id);
      o.like.innerHTML = icon(on ? 'heartFill' : 'heart');
      o.like.setAttribute('aria-pressed', on);
      o.like.classList.toggle('on', on);
      if (pop) {
        o.like.classList.remove('pop');
        void o.like.offsetWidth;
        o.like.classList.add('pop');
      }
    }
    function segText() {
      const sl = P.track.setlist;
      const s = sl && sl[P.seg];
      if (!s) return '';
      return s.unknown ? 'ID — Unidentified' : `${s.artist} — ${s.title}`;
    }
    function paintSeg(anim) {
      if (!o.seg) return;
      const has = !!P.track.setlist;
      o.seg.classList.toggle('none', !has);
      const text = segText();
      if (!anim || NP.reduceMotion) {
        o.segL.textContent = text;
        return;
      }
      o.seg.classList.add('swap');
      setTimeout(() => {
        o.segL.textContent = text;
        o.seg.classList.remove('swap');
      }, 260);
    }
    function paintTitle(anim) {
      const apply = () => {
        const t = P.track;
        o.title.textContent = o.short ? t.short || t.title : t.title;
        o.artist.textContent = t.artist;
        overflow(o.title);
        overflow(o.artist);
        paintLike();
        paintSeg(false);
        if (o.onTrack) o.onTrack(t);
      };
      if (!anim || NP.reduceMotion || !o.titles) return apply();
      o.titles.classList.add('swap');
      setTimeout(() => {
        apply();
        o.titles.classList.remove('swap');
      }, 170);
    }
    function paintTimes(p) {
      if (o.el) o.el.textContent = fmt(p);
      if (o.rem) o.rem.textContent = '−' + fmt(P.track.duration - p);
      if (o.onSecond) o.onSecond(p);
    }
    NP.onFrame((p) => {
      if (scrubT != null) return;
      const sec = Math.floor(p);
      if (sec === lastSec) return;
      lastSec = sec;
      paintTimes(p);
    });
    P.on('seek', () => (lastSec = -1));
    P.on('track', () => {
      lastSec = -1;
      paintTitle(true);
    });
    P.on('segment', () => paintSeg(true));
    P.on('like', () => paintLike(true));
    if (o.like) o.like.onclick = (e) => { e.stopPropagation(); P.toggleLike(); };
    paintTitle(false);
    return {
      segText,
      scrub(t) {
        scrubT = t;
        if (o.root) o.root.classList.toggle('scrubbing', t != null);
        paintTimes(t != null ? t : P.pos());
        lastSec = -1;
      },
    };
  };

  NP.bindMini = function (o) {
    const pp = NP.PlayGlyph();
    o.play.appendChild(pp.el);
    pp.set(P.playing, true);
    o.next.innerHTML = icon('next');
    o.play.onclick = (e) => { e.stopPropagation(); P.toggle(); };
    o.next.onclick = (e) => { e.stopPropagation(); P.next(); };
    function paint() {
      const t = P.track;
      o.art.src = t.artURL;
      o.title.textContent = t.short || t.title;
      const remote = P.output !== P.self;
      o.sub.classList.toggle('remote', remote);
      o.sub.innerHTML = remote ? `${icon(D.devices.find((d) => d.id === P.output).kind)}<span>Playing on ${esc(NP.deviceName(P.output, P.self))}</span>` : esc(t.artist);
    }
    paint();
    P.on('playstate', (v) => pp.set(v));
    P.on('track', paint);
    P.on('output', paint);
  };

  NP.bindRoute = function (o) {
    function paint(anim) {
      const remote = P.output !== P.self;
      const dev = D.devices.find((d) => d.id === P.output);
      if (o.root) o.root.classList.toggle('remote', remote);
      if (o.badge) o.badge.innerHTML = `${icon(dev.kind)}<b>${esc(NP.deviceName(P.output, P.self))}</b>`;
      if (o.icon) o.icon.innerHTML = icon(remote ? dev.kind : 'route');
      if (o.label) o.label.textContent = NP.deviceName(P.output, P.self);
      if (!anim || NP.reduceMotion) return;
      if (o.art) {
        o.art.classList.add('moving');
        setTimeout(() => o.art.classList.remove('moving'), 420);
      }
      if (o.button) {
        o.button.classList.remove('bounce');
        void o.button.offsetWidth;
        o.button.classList.add('bounce');
      }
    }
    paint(false);
    P.on('output', () => paint(true));
  };

  NP.toast = function (host, text, ic = 'check') {
    const t = h(`<div class="toast glass">${icon(ic)}<span>${esc(text)}</span></div>`);
    host.appendChild(t);
    requestAnimationFrame(() => requestAnimationFrame(() => t.classList.add('on')));
    setTimeout(() => {
      t.classList.remove('on');
      setTimeout(() => t.remove(), 500);
    }, 2000);
  };

  NP.RouteContent = function (self, { onPick } = {}) {
    const el = h(`<div class="route"><div class="route-vol"></div><div class="route-list"></div></div>`);
    NP.Slider(el.querySelector('.route-vol'), { get: () => P.volume, set: (v) => P.setVolume(v) });
    const list = el.querySelector('.route-list');
    let pending = null;
    function render() {
      list.innerHTML = D.devices.map((d) => {
        const on = P.output === d.id;
        const sub = pending === d.id ? 'Connecting…' : d.id === self ? '' : d.sub || '';
        return `<button class="route-row${on ? ' on' : ''}${pending === d.id ? ' pending' : ''}" data-id="${d.id}"><span class="route-ic">${icon(d.kind)}</span><span class="route-l"><b>${esc(NP.deviceName(d.id, self))}</b>${sub ? `<small>${esc(sub)}</small>` : ''}</span><span class="route-check">${on ? icon('check') : pending === d.id ? '<i class="spin"></i>' : ''}</span></button>`;
      }).join('');
    }
    list.addEventListener('click', (e) => {
      const b = e.target.closest('.route-row');
      if (!b || b.dataset.id === P.output) return;
      pending = b.dataset.id;
      render();
      setTimeout(() => {
        const id = pending;
        pending = null;
        P.setOutput(id);
        render();
        if (onPick) onPick(id);
      }, NP.shot ? 0 : 650);
    });
    render();
    P.on('output', render);
    return el;
  };

  NP.CueContent = function ({ onDone } = {}) {
    const el = h('<div class="cues"><div class="cue-list"></div><button class="wide-btn glass-btn"></button></div>');
    const list = el.querySelector('.cue-list');
    const add = el.querySelector('.wide-btn');
    function render() {
      list.innerHTML = P.track.cues.map((c, i) => `<button class="cue-row" data-i="${i}"><i class="cue-dot c-${c.color}"></i><span class="cue-l">${esc(c.label)}</span><span class="cue-t">${fmt(c.t)}</span></button>`).join('');
      add.innerHTML = `${icon('plus')}Add Cue at ${fmt(P.pos())}`;
    }
    list.addEventListener('click', (e) => {
      const r = e.target.closest('.cue-row');
      if (!r) return;
      P.seek(P.track.cues[+r.dataset.i].t);
      if (onDone) onDone();
    });
    add.onclick = () => {
      const t = Math.floor(P.pos());
      P.track.cues.push({ t, label: `Cue ${P.track.cues.length + 1}`, color: ['teal', 'violet', 'amber', 'rose'][P.track.cues.length % 4] });
      P.track.cues.sort((a, b) => a.t - b.t);
      render();
    };
    render();
    const off = NP.onFrame((p) => {
      if (!el.isConnected) return;
      const label = `Add Cue at ${fmt(p)}`;
      if (add.lastChild && add.lastChild.textContent !== label) add.lastChild.textContent = label;
    });
    return el;
  };

  NP.ShareContent = function (host) {
    const t = P.track;
    const el = h(`<div class="share"><div class="share-card"><img src="${t.artURL}" alt=""><div><b>${esc(t.title)}</b><span>${esc(t.artist)}</span><small>${esc(t.url)}</small></div></div>
<label class="share-at"><span>Start at ${fmt(P.pos())}</span><button class="switch" aria-label="Start at current time"><i></i></button></label>
<div class="share-targets">${[['message', 'Messages'], ['mail', 'Mail'], ['link', 'Copy Link'], ['more', 'More']].map(([i, l]) => `<button data-l="${l}"><span>${icon(i)}</span>${l}</button>`).join('')}</div></div>`);
    const sw = el.querySelector('.switch');
    sw.onclick = () => sw.classList.toggle('on');
    el.querySelector('.share-targets').addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (b && host) NP.toast(host, b.dataset.l === 'Copy Link' ? 'Link copied' : `Shared to ${b.dataset.l}`);
    });
    return el;
  };

  NP.DecksContent = function () {
    const a = P.track;
    const b = P.neighbour(1);
    const deck = (t, k, live) => `<div class="deck deck-${k}"><div class="deck-k">Deck ${k.toUpperCase()}${live ? ' · Live' : ''}</div><img src="${t.artURL}" alt=""><b>${esc(t.short || t.title)}</b><span>${esc(t.artist)}</span><div class="deck-m"><span>${t.bpm} BPM</span><span>${esc(t.key.split(' · ')[0])}</span></div></div>`;
    const el = h(`<div class="decks"><div class="deck-row">${deck(a, 'a', true)}${deck(b, 'b', false)}</div><label class="share-at"><span>Auto Mix<small>Matches tempo and key between tracks</small></span><button class="switch${P.automix ? ' on' : ''}"><i></i></button></label><button class="wide-btn glass-btn">${icon('decks')}Open Decks</button></div>`);
    const sw = el.querySelector('.switch');
    sw.onclick = () => {
      P.setAutomix(!P.automix);
      sw.classList.toggle('on', P.automix);
    };
    return el;
  };

  NP.moreItems = function ({ onSetlist, onCues, onDecks, onShare, host }) {
    const t = P.track;
    return [
      { label: 'Share…', icon: 'share', fn: onShare },
      { label: 'Add to Playlist…', icon: 'playlist', fn: () => NP.toast(host, 'Added to Late Night Mixes') },
      '-',
      { label: 'Tracklist', icon: 'setlist', sub: t.setlist ? `${t.setlist.length} tracks · Identify` : 'Identify what’s playing', fn: onSetlist },
      { label: 'Cue Points', icon: 'cue', sub: `${t.cues.length} cues`, fn: onCues },
      '-',
      { label: 'Auto Mix', icon: 'automix', check: P.automix, fn: () => { P.setAutomix(!P.automix); NP.toast(host, P.automix ? 'Auto Mix on' : 'Auto Mix off', 'automix'); } },
      { label: 'Decks', icon: 'decks', fn: onDecks },
    ];
  };

  NP.Breathe = function (el, { amount = 0.012 } = {}) {
    let last = 0;
    NP.onFrame((p, now) => {
      if (NP.reduceMotion || !P.playing) {
        if (last !== 1) {
          el.style.transform = '';
          last = 1;
        }
        return;
      }
      const t = P.track;
      const i = Math.min(t.wave.length - 1, Math.floor((p / t.duration) * t.wave.length));
      const energy = t.wave[i];
      const period = (60 / t.bpm) * 4;
      const ph = (now / 1000 / period) * Math.PI * 2;
      const s = 1 + amount * energy * (0.5 - 0.5 * Math.cos(ph));
      if (Math.abs(s - last) < 0.00005) return;
      last = s;
      el.style.transform = `scale(${s.toFixed(5)})`;
    });
  };
})();
