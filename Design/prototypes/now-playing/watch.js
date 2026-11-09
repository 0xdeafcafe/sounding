(function () {
  'use strict';
  const NP = window.NP;
  const P = NP.player;
  const D = NP.data;
  const { icon, esc, fmt, clamp, $ } = NP;

  NP.initFromParams('iphone');
  document.body.classList.toggle('shot', NP.shot);
  document.querySelectorAll('[data-ic]').forEach((s) => (s.innerHTML = icon(s.dataset.ic)));

  const screen = $('#screen');
  NP.stage($('#device'), 300, 470, { max: 2.1 });

  const bg = NP.Background($('#npBg'));
  NP.applyPalette(screen, P.track);
  bg.set(P.track, true);
  P.on('track', () => {
    NP.applyPalette(screen, P.track);
    bg.set(P.track);
  });

  NP.bindMeta({ titles: $('#titles'), title: $('#tTitle'), artist: $('#tArtist'), short: true });
  const pp = NP.PlayGlyph();
  $('#play').appendChild(pp.el);
  pp.set(P.playing, true);
  P.on('playstate', (v) => pp.set(v));
  $('#play').onclick = () => P.toggle();
  $('#prev').onclick = () => P.prev();
  $('#next').onclick = () => P.next();

  const C = 2 * Math.PI * 33;
  let lastOff = -1;
  const ring = $('#ring');
  NP.onFrame((p) => {
    const off = C * (1 - p / P.track.duration);
    if (Math.abs(off - lastOff) < 0.25) return;
    lastOff = off;
    ring.style.strokeDashoffset = off.toFixed(2);
  });

  function paintSrc() {
    const d = D.devices.find((x) => x.id === P.output);
    $('#src').innerHTML = `${icon(d.kind)}<span>${esc(d.name)}</span>`;
    $('#routeIc').innerHTML = icon(P.output === P.self ? 'route' : d.kind);
    $('#routeBtn').classList.toggle('remote', P.output !== P.self);
  }
  paintSrc();
  P.on('output', () => {
    paintSrc();
    renderOutput();
  });

  const vol = $('#vol');
  const volFill = $('#volFill');
  let volT = 0;
  function showVol() {
    volFill.style.transform = `scaleY(${P.volume})`;
    vol.classList.add('on');
    clearTimeout(volT);
    if (!NP.shot) volT = setTimeout(() => vol.classList.remove('on'), 1600);
  }
  P.on('volume', showVol);
  $('#volBtn').onclick = showVol;

  let page = 'np';
  let panel = { refresh() {} };
  function show(p) {
    page = p;
    screen.dataset.page = p;
    document.querySelectorAll('.page').forEach((el) => el.classList.toggle('on', el.dataset.p === p));
    if (p === 'upnext') renderUp();
    if (p === 'setlist') renderSet(true);
    if (p === 'more') renderMore();
    if (p === 'output') renderOutput();
    panel.refresh();
  }
  document.querySelectorAll('[data-back]').forEach((b) => (b.onclick = () => show('np')));
  $('#routeBtn').onclick = () => show('output');
  $('#moreBtn').onclick = () => show('more');

  const row = (t, cls = '') => `<button class="w-row ${cls}" data-id="${t.id}"><img src="${t.artURL}" alt=""><span><b>${esc(t.short || t.title)}</b><span>${esc(t.artist)}</span></span></button>`;
  function renderUp() {
    const up = P.upcoming();
    $('#upList').innerHTML = `<div class="w-sec">Playing from ${esc(P.track.playlist)}</div>${row(P.track, 'cur')}<div class="w-sec">Up Next</div>${up.map((t) => row(t)).join('')}`;
  }
  $('#upList').addEventListener('click', (e) => {
    const r = e.target.closest('.w-row');
    if (!r) return;
    P.playId(r.dataset.id);
    show('np');
  });
  function renderSet(scroll) {
    const sl = P.track.setlist;
    const list = $('#slList');
    if (!sl) {
      list.innerHTML = '<div class="w-sec" style="padding-top:20px;text-align:center">No tracklist for this track.</div>';
      return;
    }
    list.innerHTML = sl.map((s, i) => `<button class="w-row set${i === P.seg ? ' cur' : ''}" data-i="${i}"><span class="tm">${fmt(s.t)}</span><span><b>${s.unknown ? 'ID' : esc(s.title)}</b><span>${s.unknown ? 'Unidentified' : esc(s.artist)}</span></span></button>`).join('');
    if (scroll) {
      const c = list.querySelector('.cur');
      if (c) list.scrollTop = c.offsetTop - 60;
    }
  }
  $('#slList').addEventListener('click', (e) => {
    const r = e.target.closest('.w-row');
    if (r) P.seek(P.track.setlist[+r.dataset.i].t + 0.05);
  });
  P.on('segment', () => page === 'setlist' && renderSet(false));
  P.on('track', () => {
    if (page === 'upnext') renderUp();
    if (page === 'setlist') renderSet(true);
  });
  function renderOutput() {
    $('#outList').innerHTML = D.devices.map((d) => `<button class="w-row${P.output === d.id ? ' cur' : ''}" data-dev="${d.id}"><span class="w-ic">${icon(d.kind)}</span><span><b>${esc(d.name)}</b><span>${P.output === d.id ? 'Playing' : d.sub || ''}</span></span></button>`).join('');
  }
  $('#outList').addEventListener('click', (e) => {
    const r = e.target.closest('.w-row');
    if (r) {
      P.setOutput(r.dataset.dev);
      setTimeout(() => show('np'), 350);
    }
  });
  function renderMore() {
    const t = P.track;
    const liked = P.liked.has(t.id);
    $('#moreList').innerHTML = `
<button class="w-row" data-go="upnext"><span class="w-ic">${icon('upnext')}</span><span><b>Up Next</b><span>${P.upcoming().length} tracks</span></span></button>
${t.setlist ? `<button class="w-row" data-go="setlist"><span class="w-ic">${icon('setlist')}</span><span><b>Tracklist</b><span>${t.setlist.length} tracks</span></span></button>` : ''}
<button class="w-row" data-go="like"><span class="w-ic">${icon(liked ? 'heartFill' : 'heart')}</span><span><b>${liked ? 'Liked' : 'Like'}</b><span>${esc(t.likes)} likes</span></span></button>
<button class="w-row" data-go="automix"><span class="w-ic">${icon('automix')}</span><span><b>Auto Mix</b><span>${P.automix ? 'On' : 'Off'}</span></span></button>`;
  }
  $('#moreList').addEventListener('click', (e) => {
    const r = e.target.closest('.w-row');
    if (!r) return;
    const g = r.dataset.go;
    if (g === 'like') { P.toggleLike(); renderMore(); }
    else if (g === 'automix') { P.setAutomix(!P.automix); renderMore(); }
    else show(g);
  });

  let ridge = 0;
  function turn(delta) {
    ridge = (ridge + delta * 0.25) % 8;
    $('#ridges').style.transform = `translate3d(0,${ridge}px,0)`;
    if (page === 'np') P.setVolume(P.volume - delta * 0.004);
    else {
      const sc = document.querySelector('.page.on .w-scroll');
      if (sc) sc.scrollTop += delta * 0.6;
    }
  }
  $('#device').addEventListener('wheel', (e) => {
    e.preventDefault();
    turn(e.deltaY);
  }, { passive: false });
  let cg = null;
  $('#crown').addEventListener('pointerdown', (e) => {
    cg = { y: e.clientY };
    $('#crown').setPointerCapture(e.pointerId);
  });
  $('#crown').addEventListener('pointermove', (e) => {
    if (!cg) return;
    const d = (e.clientY - cg.y) / (NP.stageScale || 1);
    cg.y = e.clientY;
    turn(d * 6);
  });
  $('#crown').addEventListener('pointerup', () => (cg = null));

  NP.keys({
    Escape: () => show('np'),
    ArrowUp: () => { turn(-12); },
    ArrowDown: () => { turn(12); },
  });

  panel = NP.panel({
    title: 'Apple Watch Ultra 49mm',
    footer: 'Scroll over the watch or drag the crown · ↑ ↓ turn the crown',
    sections: [
      { label: 'Screen', type: 'seg', options: [['np', 'Playing'], ['upnext', 'Up Next'], ['setlist', 'Tracklist'], ['output', 'Output']], get: () => page, set: (v) => show(v) },
      { label: 'Actions', type: 'buttons', items: [['More', () => show('more')], ['Show volume', () => { show('np'); showVol(); }]] },
    ],
  });

  const q = NP.params;
  screen.classList.add('boot');
  show(q.get('page') || 'np');
  if (q.get('vol') === '1') showVol();
  requestAnimationFrame(() => requestAnimationFrame(() => screen.classList.remove('boot')));
  NP.start();
})();
