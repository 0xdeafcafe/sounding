(function () {
  'use strict';
  const NP = window.NP;
  const P = NP.player;
  const D = NP.data;
  const { h, icon, esc, fmt, $ } = NP;

  D.devices.splice(0, D.devices.length, { id: 'tv', name: 'Living Room', kind: 'tv' }, { id: 'iphone', name: 'iPhone', kind: 'iphone' }, { id: 'mac', name: 'MacBook Pro', kind: 'mac' });
  NP.initFromParams('tv');
  document.body.classList.toggle('shot', NP.shot);
  document.querySelectorAll('[data-ic]').forEach((s) => (s.innerHTML = icon(s.dataset.ic)));

  const tv = $('#tv');
  const panelEl = $('#panel');
  const art = $('#art');
  NP.stage($('#device'), 1952, 1112);

  const bg = NP.Background($('#npBg'));
  NP.applyPalette(tv, P.track);
  bg.set(P.track, true);
  art.src = P.track.artURL;
  P.on('track', () => {
    NP.applyPalette(tv, P.track);
    bg.set(P.track);
    if (NP.reduceMotion) art.src = P.track.artURL;
    else {
      art.classList.add('swap');
      setTimeout(() => {
        art.src = P.track.artURL;
        art.classList.remove('swap');
      }, 260);
    }
  });
  NP.Breathe($('#artBreathe'), { amount: 0.01 });

  const meta = NP.bindMeta({
    titles: $('#titles'), title: $('#tTitle'), artist: $('#tArtist'), like: $('#likeBtn'), seg: $('#tSeg'), segL: $('#tSegL'),
    el: $('#tEl'), rem: $('#tRem'), root: $('#progress'),
    onTrack: (t) => {
      $('#eyebrow').textContent = `From ${t.playlist}`;
      $('#ambTitle').textContent = t.short || t.title;
      $('#ambArtist').textContent = t.artist;
    },
  });
  const wave = NP.Waveform($('#wave'), { height: 76, pitch: 6.2, barW: 3.4, minH: 0.08, bubble: true, bubbleInset: 110, bubbleMax: 640, onScrub: (t) => meta.scrub(t) });
  NP.bindRoute({ root: tv, badge: $('#artRoute'), icon: $('#routeIc'), art: $('#artPause'), button: $('#routeBtn') });

  const pp = NP.PlayGlyph();
  $('#playBtn').appendChild(pp.el);
  pp.set(P.playing, true);
  tv.dataset.playing = P.playing;
  P.on('playstate', (v) => {
    pp.set(v);
    tv.dataset.playing = v;
    $('#playBtn').dataset.label = v ? 'Pause' : 'Play';
  });
  $('#playBtn').dataset.label = P.playing ? 'Pause' : 'Play';
  P.on('like', () => ($('#likeBtn').dataset.label = P.liked.has(P.track.id) ? 'Liked' : 'Like'));

  const panes = NP.Panes($('#panes'), { tabs: ['upnext', 'comments', 'setlist', 'about'], variant: 'tv', compose: false, handles: false });
  let panel = { refresh() {} };
  let scope = 'main';
  let cur = null;
  let lastMain = null;
  let panelKind = null;
  panes.onChange((id) => {
    wave.setMarks(id === 'setlist' ? 'segments' : id === 'comments' ? 'comments' : null);
    panelKind = id;
    syncOn();
    panel.refresh();
  });

  function syncOn() {
    document.querySelectorAll('.tvb[data-act]').forEach((b) => b.classList.toggle('on', tv.classList.contains('panel-open') && b.dataset.act === panelKind));
  }

  function altRows(kind) {
    const alt = $('#alt');
    if (kind === 'output') {
      alt.innerHTML = `<div class="alt-head"><div class="eyebrow">Output</div><div class="pane-title">Play On</div></div><div class="alt-list">${D.devices.map((d) => `<button class="tv-row" data-dev="${d.id}"><span class="r-ic">${icon(d.kind)}</span><span>${esc(NP.deviceName(d.id, P.self))}${d.id === P.self ? '<small>Apple TV</small>' : ''}</span><span class="r-end">${P.output === d.id ? icon('check') : ''}</span></button>`).join('')}</div>`;
    } else if (kind === 'more') {
      const t = P.track;
      alt.innerHTML = `<div class="alt-head"><div class="eyebrow">${esc(t.short || t.title)}</div><div class="pane-title">More</div></div><div class="alt-list">
<button class="tv-row" data-go="setlist"><span class="r-ic">${icon('setlist')}</span><span>Tracklist<small>${t.setlist ? t.setlist.length + ' tracks · Identify' : 'Identify what’s playing'}</small></span><span class="r-end">${icon('chevronRight')}</span></button>
<button class="tv-row" data-go="cues"><span class="r-ic">${icon('cue')}</span><span>Cue Points<small>${t.cues.length} cues</small></span><span class="r-end">${icon('chevronRight')}</span></button>
<button class="tv-row" data-go="automix"><span class="r-ic">${icon('automix')}</span><span>Auto Mix<small>Matches tempo and key between tracks</small></span><span class="r-end">${P.automix ? 'On' : 'Off'}</span></button>
<button class="tv-row" data-go="decks"><span class="r-ic">${icon('decks')}</span><span>Decks<small>Open the DJ console</small></span><span class="r-end">${icon('chevronRight')}</span></button>
<button class="tv-row" data-go="about"><span class="r-ic">${icon('info')}</span><span>About<small>${esc(t.artist)} · ${esc(t.genre)}</small></span><span class="r-end">${icon('chevronRight')}</span></button></div>`;
    } else if (kind === 'cues') {
      alt.innerHTML = `<div class="alt-head"><div class="eyebrow">${esc(P.track.short || P.track.title)}</div><div class="pane-title">Cue Points</div></div><div class="alt-list">${P.track.cues.map((c, i) => `<button class="tv-row" data-cue="${i}"><span><i class="cue-dot c-${c.color}"></i></span><span>${esc(c.label)}</span><span class="r-end">${fmt(c.t)}</span></button>`).join('')}</div>`;
    }
  }
  $('#alt').addEventListener('click', (e) => {
    const r = e.target.closest('.tv-row');
    if (!r) return;
    if (r.dataset.dev) {
      P.setOutput(r.dataset.dev);
      altRows('output');
      focusFirst();
    } else if (r.dataset.cue) {
      P.seek(P.track.cues[+r.dataset.cue].t);
      closePanel();
    } else if (r.dataset.go === 'automix') {
      P.setAutomix(!P.automix);
      const i = focusables().indexOf(cur);
      altRows('more');
      setFocus(focusables()[i]);
    } else if (r.dataset.go === 'decks') {
      NP.toast(tv, 'Decks opens the DJ console', 'decks');
    } else if (r.dataset.go === 'cues') openPanel('cues');
    else openPanel(r.dataset.go);
  });

  function openPanel(kind) {
    if (scope === 'main') lastMain = cur;
    tv.classList.add('panel-open');
    tv.dataset.idle = 'false';
    scope = 'panel';
    if (['upnext', 'comments', 'setlist', 'about'].includes(kind)) {
      panelEl.dataset.kind = 'panes';
      panes.show(kind);
    } else {
      panelEl.dataset.kind = 'alt';
      panelKind = kind;
      altRows(kind);
      syncOn();
    }
    setTimeout(focusFirst, 40);
    panel.refresh();
  }
  function closePanel() {
    tv.classList.remove('panel-open');
    scope = 'main';
    panelKind = null;
    syncOn();
    wave.setMarks(null);
    setFocus(lastMain && lastMain.isConnected ? lastMain : $('#playBtn'));
    panel.refresh();
  }
  function focusFirst() {
    if (scope !== 'panel') return;
    let el = null;
    if (panelEl.dataset.kind === 'panes') {
      const pane = panelEl.querySelector('.pane.on');
      el = pane.querySelector('.srow.current') || (pane.querySelectorAll('.crow').length ? [...pane.querySelectorAll('.crow')].pop() : null) || pane.querySelector('.qrow') || panelEl.querySelector('.seg button.on');
    } else el = panelEl.querySelector('.tv-row');
    if (el) setFocus(el);
  }

  function visible(e) {
    if (e.offsetParent === null) return false;
    if (e.closest('.pane:not(.on)') || e.closest('.idcard:not(.on)')) return false;
    if (panelEl.dataset.kind === 'alt' && e.closest('.tvp-panes')) return false;
    if (panelEl.dataset.kind === 'panes' && e.closest('.tvp-alt')) return false;
    return true;
  }
  function focusables() {
    const root = scope === 'main' ? $('#main') : panelEl;
    return [...root.querySelectorAll('[data-focus], .tvb, .seg button, .qrow, .crow, .srow, .tog, .identify, .idc-btn, .tv-row')].filter(visible);
  }
  function scrollParent(el) {
    return el.closest('.pane-scroll, .alt-list');
  }
  function setFocus(el) {
    if (!el) return;
    if (cur) cur.classList.remove('focus');
    cur = el;
    el.classList.add('focus');
    const sp = scrollParent(el);
    if (sp) {
      const top = el.offsetTop - sp.offsetTop;
      const pad = 90;
      if (top - pad < sp.scrollTop) sp.scrollTo({ top: top - pad, behavior: NP.reduceMotion ? 'auto' : 'smooth' });
      else if (top + el.offsetHeight + pad > sp.scrollTop + sp.clientHeight) sp.scrollTo({ top: top + el.offsetHeight + pad - sp.clientHeight, behavior: NP.reduceMotion ? 'auto' : 'smooth' });
    }
  }
  function move(dir) {
    const list = focusables();
    if (!cur || !list.includes(cur)) return setFocus(list[0]);
    const a = cur.getBoundingClientRect();
    const ac = { x: a.left + a.width / 2, y: a.top + a.height / 2 };
    let best = null;
    let bestScore = Infinity;
    list.forEach((e) => {
      if (e === cur) return;
      const b = e.getBoundingClientRect();
      const bc = { x: b.left + b.width / 2, y: b.top + b.height / 2 };
      const dx = bc.x - ac.x;
      const dy = bc.y - ac.y;
      let primary;
      let secondary;
      if (dir === 'right') { if (b.left < a.right - 8 && dx <= 8) return; primary = Math.max(0, b.left - a.right); secondary = Math.abs(dy); }
      if (dir === 'left') { if (b.right > a.left + 8 && dx >= -8) return; primary = Math.max(0, a.left - b.right); secondary = Math.abs(dy); }
      if (dir === 'down') { if (dy <= 8) return; primary = Math.max(0, b.top - a.bottom); secondary = Math.abs(dx) * 0.5; }
      if (dir === 'up') { if (dy >= -8) return; primary = Math.max(0, a.top - b.bottom); secondary = Math.abs(dx) * 0.5; }
      const score = primary + secondary * 2;
      if (score < bestScore) {
        bestScore = score;
        best = e;
      }
    });
    if (best) setFocus(best);
  }

  const acts = {
    prev: () => P.prev(),
    next: () => P.next(),
    play: () => P.toggle(),
    like: () => {},
    comments: () => openPanel('comments'),
    upnext: () => openPanel('upnext'),
    setlist: () => openPanel('setlist'),
    output: () => openPanel('output'),
    more: () => openPanel('more'),
  };
  document.querySelectorAll('.tvb[data-act]').forEach((b) => b.addEventListener('click', () => acts[b.dataset.act]()));
  $('#progress').addEventListener('click', () => {});

  const IDLE_MS = 20000;
  let lastInput = performance.now();
  function wake() {
    lastInput = performance.now();
    if (tv.dataset.idle === 'true') {
      tv.dataset.idle = 'false';
      panel.refresh();
      return true;
    }
    return false;
  }
  function goIdle() {
    if (scope === 'panel') closePanel();
    tv.dataset.idle = 'true';
    panel.refresh();
  }
  setInterval(() => {
    if (NP.shot) return;
    const d = new Date();
    $('#clock').textContent = `${d.getHours()}:${String(d.getMinutes()).padStart(2, '0')}`;
    if (tv.dataset.idle !== 'true' && scope === 'main' && P.playing && performance.now() - lastInput > IDLE_MS) goIdle();
  }, 1000);
  ['pointermove', 'pointerdown', 'wheel'].forEach((ev) => addEventListener(ev, () => wake(), { passive: true }));

  addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey) return;
    if (wake()) {
      e.preventDefault();
      return;
    }
    const k = e.key;
    const onWave = cur && cur.dataset.focus === 'wave';
    if (k === 'ArrowLeft' || k === 'ArrowRight') {
      e.preventDefault();
      if (onWave) {
        const step = P.track.duration > 900 ? 30 : 10;
        wave.nudge(k === 'ArrowRight' ? step : -step);
        return;
      }
      move(k === 'ArrowRight' ? 'right' : 'left');
    } else if (k === 'ArrowUp' || k === 'ArrowDown') {
      e.preventDefault();
      move(k === 'ArrowDown' ? 'down' : 'up');
    } else if (k === 'Enter') {
      e.preventDefault();
      if (!cur) return;
      if (onWave) P.toggle();
      else cur.click();
    } else if (k === ' ') {
      e.preventDefault();
      P.toggle();
    } else if (k === 'Escape' || k === 'Backspace') {
      e.preventDefault();
      if (scope === 'panel') closePanel();
    }
  });
  addEventListener('pointerover', (e) => {
    const t = e.target.closest('[data-focus], .tvb, .seg button, .qrow, .crow, .srow, .tog, .identify, .idc-btn, .tv-row');
    if (t && focusables().includes(t)) setFocus(t);
  });
  $('#main').addEventListener('pointerdown', (e) => {
    if (scope === 'panel' && !e.target.closest('.tv-panel')) closePanel();
  });
  ['track', 'seek', 'comment', 'queue', 'segment'].forEach((ev) => P.on(ev, () => setTimeout(() => {
    if (cur && !cur.isConnected) {
      cur = null;
      focusFirst();
    }
  }, 30)));

  function nextComment() {
    const p = P.pos();
    const c = P.track.comments.find((x) => x.t > p + 2) || P.track.comments[0];
    P.seek(Math.max(0, c.t - (NP.shot ? 0 : 1.6)));
    if (NP.shot) setTimeout(() => P.emit("comment", c), 50);
    P.play();
  }
  panel = NP.panel({
    title: 'Apple TV',
    footer: 'Arrows move focus · Enter selects · Esc closes panels · on the waveform ◀ ▶ scrub',
    sections: [
      { label: 'Side panel', type: 'seg', options: [['none', 'None'], ['upnext', 'Up Next'], ['comments', 'Comments'], ['setlist', 'Tracklist']], get: () => (tv.classList.contains('panel-open') ? panelKind : 'none'), set: (v) => (v === 'none' ? closePanel() : openPanel(v)) },
      { label: 'More panels', type: 'seg', options: [['output', 'Output'], ['more', 'More'], ['cues', 'Cue Points'], ['about', 'About']], get: () => (tv.classList.contains('panel-open') ? panelKind : ''), set: (v) => openPanel(v) },
      { label: 'Ambient', type: 'seg', options: [['false', 'Awake'], ['true', 'Ambient (idle 20 s)']], get: () => tv.dataset.idle, set: (v) => (v === 'true' ? goIdle() : wake()) },
      {
        label: 'Actions', type: 'buttons', items: [
          ['Identify', () => { openPanel('setlist'); panes.pane('setlist').identify(); }],
          ['Next comment', () => { if (scope === 'panel') closePanel(); nextComment(); }],
        ],
      },
    ],
  });

  const q = NP.params;
  tv.classList.add('boot');
  setFocus($('#playBtn'));
  if (q.has('focus')) setFocus(document.querySelector(`.tvb[data-act="${q.get('focus')}"]`) || ($('[data-focus="' + q.get('focus') + '"]')));
  if (q.has('panel')) openPanel(q.get('panel'));
  if (q.get('identify')) setTimeout(() => panes.pane('setlist').identify(), 30);
  if (q.get('idle') === '1') goIdle();
  if (q.get('bubble') === '1') setTimeout(nextComment, 30);
  requestAnimationFrame(() => requestAnimationFrame(() => tv.classList.remove('boot')));
  NP.start();
})();
