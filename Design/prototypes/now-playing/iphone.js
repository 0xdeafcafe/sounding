(function () {
  'use strict';
  const NP = window.NP;
  const P = NP.player;
  const D = NP.data;
  const { h, icon, fmt, esc, $ } = NP;

  NP.initFromParams('iphone');
  document.body.classList.toggle('shot', NP.shot);
  document.querySelectorAll('[data-ic]').forEach((s) => (s.innerHTML = icon(s.dataset.ic)));

  const screen = $('#screen');
  const np = $('#np');
  const strip = $('#artStrip');
  const artSlot = $('#artSlot');
  const artPause = $('#artPause');
  const titleBlock = $('#titleBlock');
  const tTitle = $('#tTitle');
  const tArtist = $('#tArtist');
  const tSeg = $('#tSeg');
  const tSegL = $('#tSegL');
  const tMid = $('#tMid');
  const likeBtn = $('#likeBtn');
  const moreBtn = $('#moreBtn');
  const routeBtn = $('#routeBtn');
  const routeL = $('#routeL');
  const SLIDE = 392 + 44;
  const springMs = () => parseInt(getComputedStyle(document.documentElement).getPropertyValue('--spring-ms'), 10) || 600;

  NP.stage($('#device'), 470, 986);

  $('.st-r').innerHTML = `<svg width="19" height="12" viewBox="0 0 19 12"><rect x="0" y="8" width="3.2" height="4" rx="1" fill="currentColor"/><rect x="5" y="5.5" width="3.2" height="6.5" rx="1" fill="currentColor"/><rect x="10" y="3" width="3.2" height="9" rx="1" fill="currentColor"/><rect x="15" y="0" width="3.2" height="12" rx="1" fill="currentColor"/></svg><svg width="17" height="12" viewBox="0 0 17 12"><path d="M8.5 2.2c2.4 0 4.6.9 6.3 2.5l1.2-1.2C14 1.5 11.4.5 8.5.5S3 1.5 1 3.5l1.2 1.2C3.9 3.1 6.1 2.2 8.5 2.2zm0 3.4c1.5 0 2.8.6 3.9 1.5l1.2-1.2C12.2 4.6 10.4 3.9 8.5 3.9S4.8 4.6 3.4 5.9l1.2 1.2c1.1-.9 2.4-1.5 3.9-1.5zm0 3.4c.6 0 1.1.2 1.5.6L8.5 11.1 7 9.6c.4-.4.9-.6 1.5-.6z" fill="currentColor"/></svg><svg width="28" height="13" viewBox="0 0 28 13"><rect x=".5" y=".5" width="23" height="12" rx="3.8" fill="none" stroke="currentColor" opacity=".4"/><rect x="2.2" y="2.2" width="17" height="8.6" rx="2.3" fill="currentColor"/><path d="M25.2 4.4v4.2c.8-.3 1.4-1.1 1.4-2.1s-.6-1.8-1.4-2.1z" fill="currentColor" opacity=".45"/></svg>`;

  $('#libList').innerHTML = [['playlist', 'Playlists'], ['person', 'Artists'], ['heart', 'Likes'], ['download', 'Downloaded'], ['setlist', 'Setlists']]
    .map(([i, l]) => `<div class="lrow">${icon(i)}<span>${l}</span>${icon('chevronRight', 'chev')}</div>`).join('');
  $('#libGrid').innerHTML = ['lowtide', 'paper', 'north', 'sodium', 'f0', 'f1', 'f2', 'f3']
    .map((id) => {
      const t = D.byId[id];
      return `<div class="tile" data-id="${id}"><img src="${t.artURL}" alt=""><b>${esc(t.short || t.title)}</b><span>${esc(t.artist)}</span></div>`;
    }).join('');
  $('#libGrid').addEventListener('click', (e) => {
    const t = e.target.closest('.tile');
    if (t) P.playId(t.dataset.id);
  });

  const bg = NP.Background($('#npBg'));
  NP.applyPalette(screen, P.track);
  bg.set(P.track, true);

  function renderSlides() {
    strip.innerHTML = [-1, 0, 1].map((k) => `<div class="slide" data-k="${k}"><img src="${P.neighbour(k).artURL}" alt=""></div>`).join('');
  }
  renderSlides();
  NP.Breathe($('#artBreathe'), { amount: 0.014 });

  NP.Transport($('#transport'));
  NP.Slider($('#volume'), { get: () => P.volume, set: (v) => P.setVolume(v) });

  let scrubT = null;
  let lastSec = -1;
  const tEl = $('#tEl');
  const tRem = $('#tRem');
  function paintTimes(p) {
    tEl.textContent = fmt(p);
    tRem.textContent = '−' + fmt(P.track.duration - p);
  }
  const wave = NP.Waveform($('#wave'), {
    height: 36, pitch: 3.6, barW: 2.2, bubble: true,
    onScrub: (t) => {
      scrubT = t;
      np.classList.toggle('scrubbing', t != null);
      paintTimes(t != null ? t : P.pos());
      lastSec = -1;
    },
  });
  NP.onFrame((p) => {
    if (scrubT != null) return;
    const s = Math.floor(p);
    if (s === lastSec) return;
    lastSec = s;
    paintTimes(p);
  });
  P.on('seek', () => (lastSec = -1));

  const LIST = ['upnext', 'comments', 'setlist'];
  let mode = 'playing';
  const panes = NP.Panes($('#panes'), { tabs: LIST, tabBar: false, variant: 'phone' });
  const seg = NP.Segmented($('#modebar'), LIST.map((m) => [m, NP.TAB_LABELS[m]]), (id) => setMode(id));
  let panel = { refresh() {} };

  function setMode(m) {
    mode = m;
    np.dataset.mode = m;
    const list = m !== 'playing';
    np.classList.toggle('list', list);
    if (list) {
      panes.show(m);
      seg.set(m);
    }
    wave.setMarks(m === 'setlist' ? 'segments' : m === 'comments' ? 'comments' : null);
    wave.setBubble(!list);
    document.querySelectorAll('.bb[data-mode]').forEach((b) => b.classList.toggle('on', b.dataset.mode === m));
    updateMid();
    panel.refresh();
  }

  function overflow(el) {
    el.classList.toggle('over', el.scrollWidth > el.clientWidth + 1);
  }
  function paintLike() {
    const on = P.liked.has(P.track.id);
    likeBtn.innerHTML = icon(on ? 'heartFill' : 'heart');
    likeBtn.setAttribute('aria-pressed', on);
  }
  function segText() {
    const sl = P.track.setlist;
    const s = sl && sl[P.seg];
    if (!s) return '';
    return s.unknown ? 'ID — Unidentified' : `${s.artist} — ${s.title}`;
  }
  function paintSeg(animate) {
    const sl = P.track.setlist;
    tSeg.hidden = !sl;
    if (!sl) return;
    const text = segText();
    if (!animate || NP.reduceMotion) {
      tSegL.textContent = text;
      return;
    }
    tSeg.classList.add('swap');
    setTimeout(() => {
      tSegL.textContent = text;
      tSeg.classList.remove('swap');
    }, 260);
  }
  function updateMid() {
    tMid.textContent = mode !== 'playing' && P.track.setlist ? segText() : '';
  }
  function paintTitle(dir, animate) {
    const apply = () => {
      const t = P.track;
      tTitle.textContent = t.title;
      tArtist.textContent = t.artist;
      overflow(tTitle);
      overflow(tArtist);
      paintLike();
      paintSeg(false);
      updateMid();
    };
    if (!animate || NP.reduceMotion) return apply();
    titleBlock.style.setProperty('--dir', dir);
    titleBlock.classList.add('swap');
    setTimeout(() => {
      apply();
      titleBlock.classList.remove('swap');
    }, 170);
  }
  paintTitle(1, false);
  P.on('segment', () => {
    paintSeg(true);
    updateMid();
  });
  P.on('like', () => {
    paintLike();
    likeBtn.classList.remove('pop');
    void likeBtn.offsetWidth;
    likeBtn.classList.add('pop');
  });

  const miniPP = NP.PlayGlyph();
  $('#miniPlay').appendChild(miniPP.el);
  miniPP.set(P.playing, true);
  $('#miniNext').innerHTML = icon('next');
  function paintMini() {
    const t = P.track;
    $('#miniArt').src = t.artURL;
    $('#miniTitle').textContent = t.short || t.title;
    const sub = $('#miniSub');
    const remote = P.output !== P.self;
    sub.classList.toggle('remote', remote);
    sub.innerHTML = remote ? `${icon(D.devices.find((d) => d.id === P.output).kind)}<span>Playing on ${esc(NP.deviceName(P.output, P.self))}</span>` : esc(t.artist);
  }
  paintMini();
  function paintRoute() {
    const remote = P.output !== P.self;
    np.classList.toggle('remote', remote);
    routeL.textContent = remote ? NP.deviceName(P.output, P.self) : '';
    const dev = D.devices.find((d) => d.id === P.output);
    $('#artRoute').innerHTML = `${icon(dev.kind)}<b>${esc(NP.deviceName(P.output, P.self))}</b>`;
    routeBtn.querySelector('.bb-ic').innerHTML = icon(remote ? dev.kind : 'route');
  }
  paintRoute();

  np.dataset.playing = P.playing;
  P.on('playstate', (v) => {
    np.dataset.playing = v;
    miniPP.set(v);
  });
  P.on('output', () => {
    paintRoute();
    paintMini();
    if (NP.reduceMotion) return;
    artPause.classList.add('moving');
    routeBtn.classList.remove('bounce');
    void routeBtn.offsetWidth;
    routeBtn.classList.add('bounce');
    setTimeout(() => artPause.classList.remove('moving'), 420);
  });

  let pendingOffset = null;
  let revealT = 0;
  P.on('track', ({ dir }) => {
    NP.applyPalette(screen, P.track);
    bg.set(P.track);
    paintTitle(dir, true);
    paintMini();
    renderSlides();
    lastSec = -1;
    const start = pendingOffset != null ? pendingOffset : dir * SLIDE;
    pendingOffset = null;
    if (NP.reduceMotion || screen.dataset.state !== 'np' || np.classList.contains('list')) {
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
    revealT = setTimeout(() => strip.classList.remove('reveal'), springMs());
  });

  function artRectIn(state) {
    if (mode !== 'playing') return { x: 24, y: 70, w: 64, r: 8 };
    if (!P.playing) return { x: 24 + 392 * 0.08, y: 92 + 392 * 0.08, w: 392 * 0.84, r: 12 };
    return { x: 24, y: 92, w: 392, r: 14 };
  }
  function rectOf(el) {
    const sr = screen.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    const s = NP.stageScale || 1;
    return { x: (r.left - sr.left) / s, y: (r.top - sr.top) / s, w: r.width / s };
  }
  function fly(from, to, hideEls) {
    if (NP.reduceMotion) return;
    const f = h(`<img class="fly" src="${P.track.artURL}" alt="" width="392" height="392">`);
    const T = (r) => `translate3d(${r.x}px,${r.y}px,0) scale(${r.w / 392})`;
    const R = (r) => `${(r.r * 392) / r.w}px`;
    f.style.transform = T(from);
    f.style.borderRadius = R(from);
    screen.appendChild(f);
    hideEls.forEach((e) => (e.style.visibility = 'hidden'));
    void f.offsetWidth;
    f.classList.add('go');
    f.style.transform = T(to);
    f.style.borderRadius = R(to);
    setTimeout(() => {
      f.remove();
      hideEls.forEach((e) => (e.style.visibility = ''));
    }, Math.min(springMs(), 760));
  }
  function open(instant) {
    if (screen.dataset.state === 'np') return;
    if (!instant) {
      const m = rectOf($('#miniArt'));
      fly({ ...m, r: 10 }, artRectIn(), [artSlot, $('#miniArt')]);
    }
    screen.dataset.state = 'np';
    panel.refresh();
  }
  function collapse() {
    if (screen.dataset.state !== 'np') return;
    const cur = rectOf(mode === 'playing' ? strip.querySelector('[data-k="0"]') : artSlot);
    screen.dataset.state = 'mini';
    np.style.transform = '';
    const m = rectOf($('#miniArt'));
    fly({ ...cur, r: mode === 'playing' ? 14 : 8 }, { ...m, r: 10 }, [artSlot, $('#miniArt')]);
    panel.refresh();
  }

  $('#mini').addEventListener('click', (e) => {
    if (e.target.closest('.mini-btn')) return;
    open();
  });
  $('#miniPlay').onclick = (e) => { e.stopPropagation(); P.toggle(); };
  $('#miniNext').onclick = (e) => { e.stopPropagation(); P.next(); };
  $('#headHit').onclick = () => setMode('playing');
  tSeg.onclick = () => setMode('setlist');
  likeBtn.onclick = () => P.toggleLike();
  document.querySelectorAll('.bb[data-mode]').forEach((b) => (b.onclick = () => setMode(mode === b.dataset.mode ? 'playing' : b.dataset.mode)));

  let sheet = null;
  function openSheet(kind) {
    if (sheet) sheet.close();
    const close = () => sheet && sheet.close();
    const opts = {
      output: { title: 'Output', body: () => NP.RouteContent('iphone', { onPick: () => setTimeout(close, 380) }) },
      cues: { title: 'Cue Points', body: () => NP.CueContent({ onDone: close }) },
      share: { title: 'Share', body: () => NP.ShareContent(screen) },
      decks: { title: 'Decks', body: () => NP.DecksContent() },
    }[kind];
    const s = NP.Sheet(screen, { title: opts.title, body: opts.body(), onClose: () => { if (sheet === s) sheet = null; } });
    sheet = s;
  }
  function openMenu() {
    NP.Menu(screen, moreBtn, NP.moreItems({
      host: screen,
      onShare: () => openSheet('share'),
      onSetlist: () => setMode('setlist'),
      onCues: () => openSheet('cues'),
      onDecks: () => openSheet('decks'),
    }), { align: 'right', below: false });
  }
  moreBtn.onclick = openMenu;
  routeBtn.onclick = () => openSheet('output');

  let g = null;
  np.addEventListener('pointerdown', (e) => {
    if (screen.dataset.state !== 'np' || e.button !== 0) return;
    if (e.target.closest('button, .wf, .slider, .np-panes, .np-modebar, input, .np-head-hit')) return;
    const now = performance.now();
    g = { id: e.pointerId, x: e.clientX, y: e.clientY, lx: e.clientX, ly: e.clientY, lt: now, vx: 0, vy: 0, kind: null, onArt: !!e.target.closest('.art-slot') && mode === 'playing', grab: !!e.target.closest('.np-grab') };
  });
  addEventListener('pointermove', (e) => {
    if (!g || e.pointerId !== g.id) return;
    const s = NP.stageScale || 1;
    const dx = (e.clientX - g.x) / s;
    const dy = (e.clientY - g.y) / s;
    const now = performance.now();
    const dt = Math.max(1, now - g.lt);
    g.vx = (e.clientX - g.lx) / s / dt;
    g.vy = (e.clientY - g.ly) / s / dt;
    g.lx = e.clientX;
    g.ly = e.clientY;
    g.lt = now;
    if (!g.kind) {
      if (Math.hypot(dx, dy) < 8) return;
      if (g.onArt && Math.abs(dx) > Math.abs(dy)) {
        g.kind = 'swipe';
        clearTimeout(revealT);
        strip.classList.remove('anim');
        strip.classList.add('reveal');
      } else if (dy > 0 && Math.abs(dy) > Math.abs(dx) && (mode === 'playing' || g.grab)) {
        g.kind = 'collapse';
        np.classList.add('dragging');
      } else {
        g = null;
        return;
      }
    }
    if (g.kind === 'swipe') strip.style.transform = `translate3d(${dx}px,0,0)`;
    if (g.kind === 'collapse') {
      const d = Math.max(0, dy);
      np.style.transform = `translate3d(0,${d}px,0) scale(${1 - d / 5000})`;
    }
  });
  function endGesture(e) {
    if (!g || e.pointerId !== g.id) return;
    const s = NP.stageScale || 1;
    const dx = (e.clientX - g.x) / s;
    const dy = (e.clientY - g.y) / s;
    if (g.kind === 'swipe') {
      const commit = Math.abs(dx) > 110 || (Math.abs(g.vx) > 0.45 && Math.sign(g.vx) === Math.sign(dx));
      if (commit) {
        const dir = dx < 0 ? 1 : -1;
        pendingOffset = dx + dir * SLIDE;
        P.setIndex(P.index + dir, dir);
      } else {
        strip.classList.add('anim');
        strip.style.transform = '';
        revealT = setTimeout(() => strip.classList.remove('reveal'), springMs());
      }
    } else if (g.kind === 'collapse') {
      np.classList.remove('dragging');
      if (dy > 150 || g.vy > 0.7) collapse();
      else np.style.transform = '';
    }
    g = null;
  }
  addEventListener('pointerup', endGesture);
  addEventListener('pointercancel', endGesture);

  NP.keys({
    Escape: () => {
      if (sheet) sheet.close();
      else if (mode !== 'playing') setMode('playing');
      else collapse();
    },
  });

  function ensureOpen() {
    if (screen.dataset.state !== 'np') open();
  }
  function nextComment() {
    const p = P.pos();
    const c = P.track.comments.find((x) => x.t > p + 2) || P.track.comments[0];
    P.seek(Math.max(0, c.t - (NP.shot ? 0 : 1.6)));
    if (NP.shot) setTimeout(() => P.emit("comment", c), 50);
    P.play();
  }
  panel = NP.panel({
    title: 'iPhone 17 Pro Max',
    footer: 'Esc back',
    sections: [
      { label: 'Presentation', type: 'seg', options: [['mini', 'Mini player'], ['np', 'Now Playing']], get: () => screen.dataset.state, set: (v) => (v === 'np' ? open() : collapse()) },
      { label: 'Mode', type: 'seg', options: [['playing', 'Playing'], ['upnext', 'Up Next'], ['comments', 'Comments'], ['setlist', 'Tracklist']], get: () => mode, set: (v) => { ensureOpen(); setMode(v); } },
      {
        label: 'Sheets & actions', type: 'buttons', items: [
          ['Output', () => { ensureOpen(); openSheet('output'); }],
          ['••• Menu', () => { ensureOpen(); setTimeout(openMenu, 50); }],
          ['Cue Points', () => { ensureOpen(); openSheet('cues'); }],
          ['Share', () => { ensureOpen(); openSheet('share'); }],
          ['Decks', () => { ensureOpen(); openSheet('decks'); }],
          ['Identify', () => { ensureOpen(); setMode('setlist'); panes.pane('setlist').identify(); }],
          ['Next comment', () => { ensureOpen(); nextComment(); }],
          ['Like', () => P.toggleLike(), () => P.liked.has(P.track.id)],
        ],
      },
    ],
  });

  const q = NP.params;
  screen.classList.add('boot');
  if (q.get('state') === 'np' || q.has('mode') || q.has('sheet')) open(true);
  if (q.has('mode')) setMode(q.get('mode'));
  else setMode('playing');
  if (q.get('identify')) setTimeout(() => panes.pane('setlist').identify(), 30);
  if (q.get('bubble') === '1') setTimeout(nextComment, 30);
  if (q.has('sheet')) {
    const sh = q.get('sheet');
    setTimeout(() => (sh === 'menu' ? openMenu() : openSheet(sh)), 60);
  }
  if (q.get('scrub')) {
    const f = +q.get('scrub');
    setTimeout(() => {
      $('#wave').classList.add('scrubbing');
      np.classList.add('scrubbing');
      wave.showTime(f);
    }, 60);
  }
  requestAnimationFrame(() => requestAnimationFrame(() => screen.classList.remove('boot')));
  NP.start();
})();
