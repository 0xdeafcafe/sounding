(function () {
  'use strict';
  const NP = window.NP;
  const P = NP.player;
  const D = NP.data;
  const { icon, esc, $ } = NP;

  D.devices[0] = { id: 'ipad', name: 'iPad', kind: 'ipad' };
  NP.initFromParams('ipad');
  document.body.classList.toggle('shot', NP.shot);
  document.querySelectorAll('[data-ic]').forEach((s) => (s.innerHTML = icon(s.dataset.ic)));

  const screen = $('#screen');
  const np = $('#np');
  NP.stage($('#device'), 1412, 1068);

  $('.st-r').innerHTML = `<svg width="18" height="12" viewBox="0 0 17 12"><path d="M8.5 2.2c2.4 0 4.6.9 6.3 2.5l1.2-1.2C14 1.5 11.4.5 8.5.5S3 1.5 1 3.5l1.2 1.2C3.9 3.1 6.1 2.2 8.5 2.2zm0 3.4c1.5 0 2.8.6 3.9 1.5l1.2-1.2C12.2 4.6 10.4 3.9 8.5 3.9S4.8 4.6 3.4 5.9l1.2 1.2c1.1-.9 2.4-1.5 3.9-1.5zm0 3.4c.6 0 1.1.2 1.5.6L8.5 11.1 7 9.6c.4-.4.9-.6 1.5-.6z" fill="currentColor"/></svg><span style="font-size:14px">84%</span><svg width="28" height="13" viewBox="0 0 28 13"><rect x=".5" y=".5" width="23" height="12" rx="3.8" fill="none" stroke="currentColor" opacity=".4"/><rect x="2.2" y="2.2" width="16" height="8.6" rx="2.3" fill="currentColor"/><path d="M25.2 4.4v4.2c.8-.3 1.4-1.1 1.4-2.1s-.6-1.8-1.4-2.1z" fill="currentColor" opacity=".45"/></svg>`;
  const tile = (id) => {
    const t = D.byId[id];
    return `<div class="tile" data-id="${id}"><img src="${t.artURL}" alt=""><b>${esc(t.short || t.title)}</b><span>${esc(t.artist)}</span></div>`;
  };
  $('#shelf1').innerHTML = ['lowtide', 'paper', 'north', 'sodium', 'f0'].map(tile).join('');
  $('#shelf2').innerHTML = ['f1', 'f2', 'f3', 'f4', 'f5'].map(tile).join('');
  document.querySelectorAll('.shelf').forEach((s) => s.addEventListener('click', (e) => {
    const t = e.target.closest('.tile');
    if (t) P.playId(t.dataset.id);
  }));

  const bg = NP.Background($('#npBg'));
  NP.applyPalette(screen, P.track);
  bg.set(P.track, true);
  P.on('track', () => {
    NP.applyPalette(screen, P.track);
    bg.set(P.track);
  });

  NP.ArtCarousel($('#art'), { gap: 80, radius: 16, enabled: () => screen.dataset.state === 'np' });
  NP.Breathe($('#artBreathe'), { amount: 0.012 });
  NP.Transport($('#transport'));
  NP.Slider($('#volume'), { get: () => P.volume, set: (v) => P.setVolume(v) });

  const meta = NP.bindMeta({
    root: np, titles: $('#titles'), title: $('#tTitle'), artist: $('#tArtist'), like: $('#likeBtn'),
    seg: $('#tSeg'), segL: $('#tSegL'), el: $('#tEl'), rem: $('#tRem'),
  });
  const wave = NP.Waveform($('#wave'), { height: 40, pitch: 4, barW: 2.4, bubble: true, onScrub: (t) => meta.scrub(t) });
  NP.bindMini({ art: $('#miniArt'), title: $('#miniTitle'), sub: $('#miniSub'), play: $('#miniPlay'), next: $('#miniNext') });
  NP.bindRoute({ root: np, badge: $('#artRoute'), icon: $('#routeIc'), label: $('#routeL'), art: $('#artPause'), button: $('#routeBtn') });

  np.dataset.playing = P.playing;
  P.on('playstate', (v) => (np.dataset.playing = v));

  const panes = NP.Panes($('#panes'), { tabs: ['upnext', 'comments', 'setlist', 'about'], variant: 'ipad' });
  let panel = { refresh() {} };
  panes.onChange((id) => {
    wave.setMarks(id === 'setlist' ? 'segments' : id === 'comments' ? 'comments' : null);
    wave.setBubble(id !== 'comments');
    panel.refresh();
  });
  $('#tSeg').onclick = () => panes.show('setlist');

  let pop = null;
  function popover(kind, anchor) {
    if (pop) pop.close();
    const map = {
      output: ['Output', () => NP.RouteContent('ipad', { onPick: () => setTimeout(() => pop && pop.close(), 380) })],
      cues: ['Cue Points', () => NP.CueContent({ onDone: () => pop && pop.close() })],
      share: ['Share', () => NP.ShareContent(screen)],
      decks: ['Decks', () => NP.DecksContent()],
    }[kind];
    const wrap = NP.h(`<div><div class="pop-title">${map[0]}</div></div>`);
    wrap.appendChild(map[1]());
    pop = NP.Popover(screen, anchor || $('#moreBtn'), wrap, { align: kind === 'output' ? 'center' : 'right', below: kind !== 'output', width: kind === 'decks' ? 380 : 340 });
  }
  function openMenu() {
    NP.Menu(screen, $('#moreBtn'), NP.moreItems({
      host: screen,
      onShare: () => popover('share'),
      onSetlist: () => panes.show('setlist'),
      onCues: () => popover('cues'),
      onDecks: () => popover('decks'),
    }), { align: 'right', below: true });
  }
  $('#moreBtn').onclick = openMenu;
  $('#routeBtn').onclick = () => popover('output', $('#routeBtn'));

  const open = () => { screen.dataset.state = 'np'; panel.refresh(); };
  const close = () => { screen.dataset.state = 'shell'; panel.refresh(); };
  $('#grab').onclick = close;
  $('#mini').addEventListener('click', (e) => !e.target.closest('.mini-btn') && open());
  let g = null;
  $('#grab').addEventListener('pointerdown', (e) => { g = { y: e.clientY }; });
  addEventListener('pointerup', (e) => {
    if (g && (e.clientY - g.y) / (NP.stageScale || 1) > 80) close();
    g = null;
  });
  NP.keys({ Escape: () => close() });

  function nextComment() {
    const p = P.pos();
    const c = P.track.comments.find((x) => x.t > p + 2) || P.track.comments[0];
    P.seek(Math.max(0, c.t - (NP.shot ? 0 : 1.6)));
    if (NP.shot) setTimeout(() => P.emit("comment", c), 50);
    P.play();
  }
  panel = NP.panel({
    title: 'iPad Pro 13″',
    footer: 'Esc closes',
    sections: [
      { label: 'Presentation', type: 'seg', options: [['shell', 'App + mini player'], ['np', 'Now Playing']], get: () => screen.dataset.state, set: (v) => (v === 'np' ? open() : close()) },
      { label: 'Pane', type: 'seg', options: [['upnext', 'Up Next'], ['comments', 'Comments'], ['setlist', 'Tracklist'], ['about', 'About']], get: () => panes.active, set: (v) => { open(); panes.show(v); } },
      {
        label: 'Popovers & actions', type: 'buttons', items: [
          ['Output', () => { open(); popover('output', $('#routeBtn')); }],
          ['••• Menu', () => { open(); setTimeout(openMenu, 30); }],
          ['Cue Points', () => { open(); popover('cues'); }],
          ['Share', () => { open(); popover('share'); }],
          ['Decks', () => { open(); popover('decks'); }],
          ['Identify', () => { open(); panes.show('setlist'); panes.pane('setlist').identify(); }],
          ['Next comment', () => { open(); nextComment(); }],
          ['Like', () => P.toggleLike(), () => P.liked.has(P.track.id)],
        ],
      },
    ],
  });

  const q = NP.params;
  screen.classList.add('boot');
  if (q.get('state') === 'shell') close();
  panes.show(q.get('pane') || 'setlist');
  if (q.get('identify')) setTimeout(() => panes.pane('setlist').identify(), 30);
  if (q.get('bubble') === '1') setTimeout(nextComment, 30);
  if (q.has('pop')) setTimeout(() => (q.get('pop') === 'menu' ? openMenu() : popover(q.get('pop'), q.get('pop') === 'output' ? $('#routeBtn') : null)), 80);
  requestAnimationFrame(() => requestAnimationFrame(() => screen.classList.remove('boot')));
  NP.start();
})();
