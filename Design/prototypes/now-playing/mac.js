(function () {
  'use strict';
  const NP = window.NP;
  const P = NP.player;
  const D = NP.data;
  const { h, icon, esc, fmt, $ } = NP;

  D.devices.splice(0, D.devices.length, { id: 'mac', name: 'MacBook Pro', kind: 'mac' }, { id: 'tv', name: 'Living Room', sub: 'Apple TV', kind: 'tv' }, { id: 'iphone', name: 'iPhone', kind: 'iphone' });
  NP.initFromParams('mac');
  document.body.classList.toggle('shot', NP.shot);
  document.querySelectorAll('[data-ic]').forEach((s) => (s.innerHTML = icon(s.dataset.ic)));

  const win = $('#win');
  const take = $('#take');
  NP.stage($('#device'), 1440, 900);

  function renderTable() {
    $('#tbody').innerHTML = D.tracks.map((t, i) => {
      const cur = t.id === P.track.id;
      return `<div class="tr${cur ? ' cur' : ''}" data-id="${t.id}"><span class="no">${cur ? icon('speakerNow') : i + 1}</span><span class="tt"><img src="${t.artURL}" alt=""><b>${esc(t.title)}</b></span><span>${esc(t.artist)}</span><span class="r">${fmt(t.duration)}</span><span class="r">${t.bpm}</span><span>${esc(t.key)}</span><span>${esc(t.genre)}</span></div>`;
    }).join('');
  }
  renderTable();
  $('#tbody').addEventListener('dblclick', (e) => {
    const r = e.target.closest('.tr');
    if (r) P.playId(r.dataset.id);
  });
  P.on('track', renderTable);

  const bg = NP.Background($('#npBg'));
  NP.applyPalette(win, P.track);
  bg.set(P.track, true);
  P.on('track', () => {
    NP.applyPalette(win, P.track);
    bg.set(P.track);
  });

  NP.Transport($('#barTp'));
  NP.Transport($('#transport'));
  NP.Slider($('#barVol'), { get: () => P.volume, set: (v) => P.setVolume(v), left: null, right: null });
  NP.Slider($('#volume'), { get: () => P.volume, set: (v) => P.setVolume(v) });

  const barMeta = NP.bindMeta({ title: $('#barTitle'), artist: $('#barArtist'), like: $('#barLike'), el: $('#bEl'), rem: $('#bRem'), short: true, onTrack: () => paintBarSub() });
  NP.Waveform($('#barWave'), { height: 20, pitch: 3, barW: 1.8, onScrub: (t) => barMeta.scrub(t) });
  $('#barArt').src = P.track.artURL;
  P.on('track', () => ($('#barArt').src = P.track.artURL));
  function paintBarSub() {
    const remote = P.output !== P.self;
    $('#barArtist').innerHTML = remote ? `${icon('tv')}Playing on ${esc(NP.deviceName(P.output, P.self))}` : esc(P.track.artist);
  }
  P.on('output', paintBarSub);
  paintBarSub();

  const meta = NP.bindMeta({ root: take, titles: $('#titles'), title: $('#tTitle'), artist: $('#tArtist'), like: $('#likeBtn'), seg: $('#tSeg'), segL: $('#tSegL'), el: $('#tEl'), rem: $('#tRem') });
  const wave = NP.Waveform($('#wave'), { height: 36, pitch: 3.6, barW: 2.2, bubble: true, onScrub: (t) => meta.scrub(t) });
  NP.ArtCarousel($('#tArt'), { gap: 80, radius: 14, enabled: () => win.dataset.state === 'take' });
  NP.Breathe($('#artBreathe'), { amount: 0.012 });
  NP.bindRoute({ root: take, badge: $('#artRoute'), icon: $('#routeIc'), label: $('#routeL'), art: $('#artPause'), button: $('#routeBtn') });
  NP.bindRoute({ root: win, icon: $('#playOnIc'), button: $('#playOn') });
  take.dataset.playing = P.playing;
  P.on('playstate', (v) => (take.dataset.playing = v));

  const tpanes = NP.Panes($('#panes'), { tabs: ['upnext', 'comments', 'setlist', 'about'], variant: 'mac' });
  const ipanes = NP.Panes($('#inspPanes'), { tabs: ['upnext', 'comments', 'setlist', 'about'], variant: 'mac' });
  let panel = { refresh() {} };
  tpanes.onChange((id) => {
    wave.setMarks(id === 'setlist' ? 'segments' : id === 'comments' ? 'comments' : null);
    wave.setBubble(id !== 'comments');
    panel.refresh();
  });
  ipanes.onChange(() => paintBarBtns());
  $('#tSeg').onclick = () => tpanes.show('setlist');

  function paintBarBtns() {
    const open = win.classList.contains('insp');
    document.querySelectorAll('.bar-right .ib[data-pane]').forEach((b) => b.classList.toggle('on', open && ipanes.active === b.dataset.pane));
    $('#inspBtn').classList.toggle('on', open);
    panel.refresh();
  }
  function inspector(paneId) {
    const open = win.classList.contains('insp');
    if (open && (!paneId || ipanes.active === paneId)) win.classList.remove('insp');
    else {
      win.classList.add('insp');
      ipanes.show(paneId || ipanes.active || 'upnext');
    }
    paintBarBtns();
  }
  document.querySelectorAll('.bar-right .ib[data-pane]').forEach((b) => (b.onclick = () => inspector(b.dataset.pane)));
  $('#inspBtn').onclick = () => inspector();

  const springMs = () => parseInt(getComputedStyle(document.documentElement).getPropertyValue('--spring-ms'), 10) || 600;
  function rectOf(el) {
    const wr = win.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    const s = NP.stageScale || 1;
    return { x: (r.left - wr.left) / s, y: (r.top - wr.top) / s, w: r.width / s };
  }
  function fly(from, to, hide) {
    if (NP.reduceMotion) return;
    const f = h(`<img class="fly" src="${P.track.artURL}" alt="" width="440" height="440">`);
    const T = (r) => `translate3d(${r.x}px,${r.y}px,0) scale(${r.w / 440})`;
    f.style.transform = T(from);
    f.style.borderRadius = (from.r * 440) / from.w + 'px';
    win.appendChild(f);
    hide.forEach((e) => (e.style.visibility = 'hidden'));
    void f.offsetWidth;
    f.classList.add('go');
    f.style.transform = T(to);
    f.style.borderRadius = (to.r * 440) / to.w + 'px';
    setTimeout(() => {
      f.remove();
      hide.forEach((e) => (e.style.visibility = ''));
    }, Math.min(springMs(), 760));
  }
  function bigRect() {
    const k = P.playing ? 1 : 0.86;
    return { x: 110 + (440 * (1 - k)) / 2, y: 64 + (440 * (1 - k)) / 2, w: 440 * k, r: 14 };
  }
  function openTake(instant) {
    if (win.dataset.state === 'take') return;
    if (!instant) fly({ ...rectOf($('#barArt')), r: 8 }, bigRect(), [$('#artPause'), $('#barArt')]);
    win.dataset.state = 'take';
    panel.refresh();
  }
  function closeTake() {
    if (win.dataset.state !== 'take') return;
    fly(bigRect(), { ...rectOf($('#barArt')), r: 8 }, [$('#artPause'), $('#barArt')]);
    win.dataset.state = 'window';
    panel.refresh();
  }
  $('#barNP').onclick = () => openTake();
  $('#expandBtn').onclick = () => openTake();
  $('#takeClose').onclick = () => closeTake();

  let pop = null;
  function popover(kind, anchor, opts = {}) {
    if (pop) pop.close();
    const host = win;
    const map = {
      output: ['Play On', () => NP.RouteContent('mac', { onPick: () => setTimeout(() => pop && pop.close(), 380) })],
      cues: ['Cue Points', () => NP.CueContent({ onDone: () => pop && pop.close() })],
      share: ['Share', () => NP.ShareContent(win)],
      decks: ['Decks', () => NP.DecksContent()],
    }[kind];
    const wrap = h(`<div><div class="pop-title">${map[0]}</div></div>`);
    wrap.appendChild(map[1]());
    pop = NP.Popover(host, anchor, wrap, Object.assign({ align: 'right', below: false, width: kind === 'output' ? 280 : 340 }, opts));
  }
  function openMenu() {
    NP.Menu(win, $('#moreBtn'), NP.moreItems({
      host: win,
      onShare: () => popover('share', $('#moreBtn'), { below: true }),
      onSetlist: () => tpanes.show('setlist'),
      onCues: () => popover('cues', $('#moreBtn'), { below: true }),
      onDecks: () => popover('decks', $('#moreBtn'), { below: true }),
    }), { align: 'right', below: true });
  }
  $('#moreBtn').onclick = openMenu;
  $('#playOn').onclick = () => popover('output', $('#playOn'), { align: 'center' });
  $('#routeBtn').onclick = () => popover('output', $('#routeBtn'), { align: 'center' });

  NP.keys({ Escape: () => closeTake() });

  function nextComment() {
    const p = P.pos();
    const c = P.track.comments.find((x) => x.t > p + 2) || P.track.comments[0];
    P.seek(Math.max(0, c.t - (NP.shot ? 0 : 1.6)));
    if (NP.shot) setTimeout(() => P.emit("comment", c), 50);
    P.play();
  }
  panel = NP.panel({
    title: 'Mac',
    footer: 'Esc exits full window · double-click a row to play',
    sections: [
      { label: 'Window', type: 'seg', options: [['window', 'Library + bar'], ['take', 'Full Window']], get: () => win.dataset.state, set: (v) => (v === 'take' ? openTake() : closeTake()) },
      { label: 'Inspector', type: 'seg', options: [['off', 'Hidden'], ['upnext', 'Up Next'], ['comments', 'Comments'], ['setlist', 'Tracklist']], get: () => (win.classList.contains('insp') ? ipanes.active : 'off'), set: (v) => { if (v === 'off') { win.classList.remove('insp'); paintBarBtns(); } else { win.classList.add('insp'); ipanes.show(v); paintBarBtns(); } } },
      { label: 'Full-window pane', type: 'seg', options: [['upnext', 'Up Next'], ['comments', 'Comments'], ['setlist', 'Tracklist'], ['about', 'About']], get: () => tpanes.active, set: (v) => { openTake(); tpanes.show(v); } },
      {
        label: 'Menus & actions', type: 'buttons', items: [
          ['Play On', () => setTimeout(() => (win.dataset.state === 'take' ? $('#routeBtn') : $('#playOn')).click(), 30)],
          ['••• Menu', () => { openTake(); setTimeout(openMenu, 30); }],
          ['Cue Points', () => { openTake(); popover('cues', $('#moreBtn'), { below: true }); }],
          ['Decks', () => { openTake(); popover('decks', $('#moreBtn'), { below: true }); }],
          ['Identify', () => { openTake(); tpanes.show('setlist'); tpanes.pane('setlist').identify(); }],
          ['Next comment', () => { openTake(); nextComment(); }],
        ],
      },
    ],
  });

  const q = NP.params;
  win.classList.add('boot');
  tpanes.show(q.get('pane') || 'setlist');
  ipanes.show(q.get('insp') || 'upnext');
  if (q.has('insp')) win.classList.add('insp');
  paintBarBtns();
  if (q.get('state') === 'take') openTake(true);
  if (q.get('identify')) setTimeout(() => tpanes.pane('setlist').identify(), 30);
  if (q.get('bubble') === '1') setTimeout(nextComment, 30);
  if (q.get('pop') === 'output') setTimeout(() => (win.dataset.state === 'take' ? $('#routeBtn') : $('#playOn')).click(), 80);
  if (q.get('pop') === 'menu') setTimeout(openMenu, 80);
  requestAnimationFrame(() => requestAnimationFrame(() => win.classList.remove('boot')));
  NP.start();
})();
