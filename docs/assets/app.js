import { createStage } from './stage.js';
import { createAudio, BPM } from './audio.js';
import { MIX } from './data.js';
import { SCREENS, createScreens } from './screens.js';
import { padAt } from './world.js';

const root = document.documentElement;
const base = new URL('.', import.meta.url).href;
const qs = new URLSearchParams(location.search);
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const lerp = (a, b, t) => a + (b - a) * t;
const smooth = t => { t = clamp(t); return t * t * (3 - 2 * t); };
const smoother = t => { t = clamp(t); return t * t * t * (t * (t * 6 - 15) + 10); };
const ss = (a, b, x) => smooth((x - a) / (b - a));
const toward = (v, goal, up, down, dt) => (goal > v ? Math.min(goal, v + dt / up) : Math.max(goal, v - dt / down));


const range = $('[data-xf-range]') || document.createElement('input');
const xfButtons = $$('[data-xf]');
const soundButtons = $$('[data-sound]');
const plugButtons = $$('[data-plug]');
const theme = $('meta[name="theme-color"]');
const PAGE = document.body.dataset.page;
const HOME = PAGE === 'home';
const SIDE_KEY = 'sounding.side';
const remember = b => { try { localStorage.setItem(SIDE_KEY, b ? 'b' : 'a'); } catch (e) {} };
const stored = () => { try { return localStorage.getItem(SIDE_KEY); } catch (e) { return null; } };
const startB = qs.has('side') ? ['b', 'dj'].includes(qs.get('side')) : HOME ? stored() === 'b' : root.dataset.side === 'b';
const REST = PAGE === 'tv' ? { 'sign-in': 1, 'play-on': 1, 'now-playing': 0, 'auto-mix': 0 } : {};
const PAGES = {
  tv: { spots: [['phone', 'phone'], ['tv', 'tv'], ['watch', 'watch']] },
  features: { spots: [['phone', 'phone'], ['tv', 'tv'], ['watch', 'watch'], ['pad', 'ipad'], ['mac', 'mac']] },
};

// MARK: Still
function still() {
  root.classList.add('still');
  const setSide = b => {
    root.dataset.side = b ? 'b' : 'a';
    xfButtons.forEach(x => x.setAttribute('aria-pressed', String((x.dataset.xf === '1') === b)));
    range.value = b ? 1000 : 0;
    if (theme) theme.setAttribute('content', b ? '#110e0c' : '#f6f1e8');
    remember(b);
  };
  range.addEventListener('change', () => setSide(+range.value > 500));
  xfButtons.forEach(x => x.addEventListener('click', () => setSide(x.dataset.xf === '1')));
  setSide(startB);
}

// MARK: Shots
const SHOT = {
  open0: { l: [0.035, 0.158, -0.14, 13, 27, 0.4, 0, -0.08], p: [0.026, 0.155, -0.14, 10, 30, 0.215, 0, -0.4], sx: 0.2 },
  open1: { l: [0.014, 0.14, -0.14, 11, 29, 0.31, 0, 0.02], p: [0.006, 0.138, -0.14, 6, 31, 0.15, 0, -0.42], sx: 0.2 },
  hero: { l: [0, 0.03, 0, 0, 42, 1.63, 0, -0.58], p: [0, 0.05, 0, 0, 58, 0.66, 0, -0.42], yawX: 10, px: 0.44 },
  crate: { l: [-0.33, 0, 1.23, 0, 62, 2.4, 0.06, 0], p: [-0.4, 0, 1.23, 0, 76, 1.35, 0, 0.34], sx: 0.33, pw: 0.5 },
  phone: { l: [0.42, 0.008, 1.0, 0, 74, 0.3, 0, 0.03], p: [0.42, 0.008, 1.0, 0, 82, 0.135, 0, 0.24], sx: 0.24, pw: 0.35, ww: 1.05 },
  tv1: { l: [2.15, 0.26, 1.4, -8, 16, 1.6, 0, 0], p: [2.15, 0.285, 1.35, 0, 10, 0.88, 0, 0.36], sx: 0.3, pw: 0.36 },
  tv2: { l: [1.9, 0.007, 1.785, -5, 57, 0.4, 0, 0.02], p: [1.9, 0.02, 1.765, -8, 57, 0.165, 0, 0.3], sx: 0.2 },
  tv3: { l: [2.17, 0.012, 1.8, 0, 82, 0.12, 0, 0], p: [2.17, 0.012, 1.8, 0, 82, 0.09, 0, 0.36], sx: 0.32 },
  tv4: { l: [2.15, 0.26, 1.4, -8, 16, 1.6, 0, 0], p: [2.15, 0.285, 1.35, 0, 10, 0.88, 0, 0.36], sx: 0.3 },
  tvc: { l: [2.15, 0.27, 1.4, -12, 17, 1.25, 0, -0.02], p: [2.15, 0.285, 1.35, 0, 10, 1.0, 0, 0.36], pw: 0.2 },
  tvf: { l: [2.15, 0.27, 1.4, -26, 17, 1.25, 0.12, -0.02], p: [2.15, 0.285, 1.35, 0, 10, 1.0, 0, 0.36], pw: 0.5, ww: 1.5 },
  rigA: { l: [0, 0.06, 0, -20, 34, 1.5, 0, 0.34], p: [-0.14, 0.06, 0, -24, 62, 0.74, 0, 0.22], sx: 0.08, yawX: 24 },
  rigC: { l: [0, 0.05, 0, 0, 39, 1.5, 0, 0.3], p: [0, 0.05, 0, 40, 40, 0.62, 0, 0.3], yawX: 14 },
  out: { l: [0.035, 0.158, -0.14, 13, 27, 0.4, 0.2, -0.08], p: [0.026, 0.155, -0.14, 10, 30, 0.215, 0, 0.36] },
  dj: { l: [0.1, 0.03, -0.1, 14, 40, 1.95, -0.5, -0.82], p: [0.31, 0.05, 0, 0, 58, 0.55, 0, -0.6] },
  pad: { l: [3.2, 0.01, 0.25, 0, 64, 0.7, 0.2, 0.05], p: [3.2, 0.01, 0.25, 0, 70, 0.3, 0, 0.3], pw: 0.2, ww: 1 },
  mac: { l: [3.45, 0.1, 1.55, -15, 39, 0.68, 0.2, 0.05], p: [3.45, 0.1, 1.55, -15, 40, 0.36, 0, 0.3], pw: 0.5 },
  macc: { l: [3.45, 0.105, 1.55, 13, 14, 0.44, 0, -0.02], p: [3.45, 0.105, 1.55, 13, 20, 0.3, 0, 0.3], pw: 0.27 },
  amp: { l: [0.035, 0.158, -0.14, 13, 27, 0.6, 0.5, -0.04], p: [0.026, 0.155, -0.14, 10, 30, 0.215, 0, 0.36], pw: 0.55 },
  watch: { l: [2.17, 0.012, 1.8, 0, 62, 0.34, 0.3, 0.02], pw: 0.3, p: [2.17, 0.012, 1.8, 0, 66, 0.17, 0, 0.3] },
  room: { l: [1.2, 0.05, 0.6, 24, 46, 2.3, 0.3, -0.1], p: [1.2, 0.05, 0.6, 24, 50, 1.2, 0, 0.3] },
  boothw: { l: [0.3, 0.07, -0.22, 30, 30, 1.55, -0.4, -0.06], p: [0.25, 0.07, -0.2, 24, 40, 0.8, -0.1, 0.3] },
  boothb: { l: [0.05, 0.06, -0.1, -26, 50, 1.5, -0.46, 0.26], p: [0.1, 0.06, -0.1, -26, 50, 0.7, 0, 0.3] },
  macb: { l: [0.52, 0.11, -0.47, -15, 17, 0.44, -0.42, -0.02], p: [0.52, 0.105, -0.47, 5, 22, 0.3, 0, 0.3] },
  macb2: { l: [0.52, 0.1, -0.47, -20, 19, 0.5, -0.44, -0.2], p: [0.52, 0.1, -0.47, 16, 24, 0.3, 0, 0.3] },
  tvcb: { l: [2.15, 0.27, 1.4, 0, 12, 1.25, -0.3, -0.02], p: [2.15, 0.285, 1.35, 0, 10, 0.88, 0, 0.36] },
  tvd: { l: [2.15, 0.27, 1.4, -9, 15, 1.18, -0.3, -0.02], p: [2.15, 0.285, 1.35, -6, 12, 0.88, 0, 0.36] },
};
const OPEN = 1.2;
const SEAT = 0.9;
const LIGHT = 0.3;
const HERO = 0.3;
const OUT = 9.55;
const END = 10.85;
const HOLD = 0.11;
const EDGE = 0.045;
const STOPS_A = [
  ['hero', HERO, 'hero', 'hero', 1],
  ['likes', 0.9, 'crate', 'listen', 1],
  ['set', 1.6, 'phone', 'listen'],
  ['list', 2.02, 'phone', 'listen', 1],
  ['tap', 2.44, 'phone', 'listen'],
  ['sign', 3.25, 'tv1', 'output'],
  ['playon', 3.95, 'tv2', 'output', 1],
  ['watch', 4.65, 'tv3', 'output'],
  ['share', 5.35, 'tv4', 'output'],
  ['automix', 6.2, 'rigA', 'decks', 1],
  ['persona', 6.65, 'rigA', 'decks'],
  ['energy', 7.35, 'rigC', 'decks'],
  ['honest', 7.85, 'rigC', 'decks'],
  ['party', 8.35, 'rigC', 'decks'],
];
const STOPS_B = [
  ['hero', HERO, 'dj', 'hero', 1],
  ['decks', 0.9, 'boothw', 'listen', 1],
  ['eq', 1.45, 'macb', 'listen'],
  ['hot', 1.83, 'macb', 'listen'],
  ['ddj', 2.21, 'macb', 'listen'],
  ['cue', 2.85, 'macb2', 'output', 1],
  ['learn', 3.23, 'macb2', 'output'],
  ['tvcues', 3.8, 'tvcb', 'output'],
  ['reads', 4.18, 'tvcb', 'output'],
  ['tvmix', 4.82, 'tvd', 'decks'],
  ['watchit', 5.2, 'tvd', 'decks'],
  ['cdjs', 5.9, 'boothb', 'booth', 1],
  ['setlist', 6.45, 'macb', 'booth'],
  ['virtual', 6.83, 'macb', 'booth'],
  ['fake', 7.21, 'macb', 'booth'],
  ['rb', 7.75, 'macb2', 'rekordbox', 1],
  ['prep', 8.12, 'macb2', 'rekordbox'],
  ['export', 8.49, 'macb2', 'rekordbox'],
  ['usb', 8.86, 'macb2', 'rekordbox'],
];
function timeline(rows) {
  const stops = rows.map(([id, at, shot, scene, rest]) => ({ id, at, shot, scene, rest: !!rest }));
  const by = Object.fromEntries(stops.map(s => [s.id, s.at]));
  const keys = [];
  stops.forEach((s, i) => {
    const prev = stops[i - 1], next = stops[i + 1];
    if (!prev || prev.shot !== s.shot) keys.push([i ? s.at - HOLD : 0, s.shot]);
    if (!next || next.shot !== s.shot) keys.push([s.at + HOLD, s.shot]);
  });
  keys.push([stops[stops.length - 1].at + HOLD + 0.55, 'out'], [99, 'out']);
  const scenes = {};
  for (const s of stops) (scenes[s.scene] ||= []).push(s.at);
  const windows = {}, caps = {}, anchor = { top: -OPEN };
  const order = Object.keys(scenes), SWAP = 0.1;
  order.forEach((id, i) => {
    const at = scenes[id], prev = scenes[order[i - 1]], next = scenes[order[i + 1]];
    const lo = prev ? (prev[prev.length - 1] + at[0]) / 2 : -8, hi = next ? (at[at.length - 1] + next[0]) / 2 : at[at.length - 1] + 0.4;
    windows[id] = [lo, lo + SWAP, hi - SWAP, hi];
  });
  for (const id in scenes) {
    const at = scenes[id], a = at[0];
    caps[id] = at.slice(1).map((x, i) => (at[i] + x) / 2);
    anchor[id] = a;
  }
  windows.join = [-9, -8, 99, 100];
  const mid = (a, b) => (by[a] + by[b]) / 2;
  return { stops, by, keys, windows, caps, anchor, mid, last: stops[stops.length - 1].at, rests: stops.filter(s => s.rest).map(s => s.at) };
}
const TA = timeline(STOPS_A), TB = timeline(STOPS_B);
const capFade = (marks, n, at, e = EDGE) => Array.from({ length: n }, (_, i) => (i ? ss(marks[i - 1], marks[i - 1] + e, at) : 1) * (i < marks.length ? 1 - ss(marks[i] - e, marks[i], at) : 1));
const MAC_B = at => at < TB.mid('ddj', 'cue') ? 'shots/mac-decks.webp' : at < TB.mid('watchit', 'cdjs') ? 'shots/mac-cues.webp' : at < TB.mid('fake', 'rb') ? 'shots/mac-players.webp' : 'shots/mac-review.webp';
const TV_B = at => at < TB.mid('tvcues', 'reads') ? 'shots/tv-cues.webp' : at < TB.mid('reads', 'tvmix') ? 'shots/tv-trackmap.webp' : at < TB.mid('tvmix', 'watchit') ? 'shots/tv-mixup.webp' : 'shots/tv-mixblend.webp';
const SHOTS_B = ['shots/mac-decks.webp', 'shots/mac-cues.webp', 'shots/mac-players.webp', 'shots/mac-review.webp', 'shots/tv-cues.webp', 'shots/tv-trackmap.webp', 'shots/tv-mixup.webp', 'shots/tv-mixblend.webp'];

// MARK: Live
function live(stage) {
  root.classList.add('live');
  if (!HOME) root.classList.add('page');
  if (matchMedia('(pointer: coarse)').matches) root.classList.add('coarse');
  const canvas = stage.R.gl.canvas;
  const world = stage.world, S = world.S, L = stage.L;
  const audio = createAudio(base);
  const home = HOME;
  const PG = PAGES[PAGE] || { spots: [] };
  const lead = home ? OPEN : 0;
  const np = { sec: 0, tapped: false, set(sec) { np.sec = clamp(sec, 0, MIX.duration - 1); }, jump(i) { np.set(MIX.tracks[clamp(i, 0, MIX.tracks.length - 1)][0] + 1); } };
  const main = $('main'), topBar = $('.top');
  const mobileQuery = matchMedia('(max-width: 860px), (max-aspect-ratio: 1/1)');
  const scenes = Object.fromEntries($$('.scene').map(el => [el.dataset.scene, { el, a: $('.side.a', el), b: $('.side.b', el), vis: $('.visual', el), capsA: $$('.side.a .cap', el), capsB: $$('.side.b .cap', el) }]));
  const chapters = home ? [] : $$('.scene.chapter').map((el, i) => {
    const n = $$('.cap', el).length;
    const span = +el.dataset.span || 1.6 + 0.8 * n;
    el.style.setProperty('--span', span);
    const tag = (el.classList.contains('flip') || el.classList.contains('right') ? '!' : '') + (el.classList.contains('wide') ? '>' : el.classList.contains('hero') ? '+' : '') + ($('.visual', el) || el.classList.contains('screen') ? '~' : '');
    return { id: el.dataset.scene, el, first: i === 0, n, span, shots: (el.dataset.shot || 'dj').split(',').map(s => s + tag), states: JSON.parse(el.dataset.states || '[]'), flow: el.classList.contains('flow'), s: 0, len: 1, alpha: 0, cap: 0, near: 1e9 };
  });
  const inks = $$('.ink').filter(el => !home || !topBar.contains(el)).map(el => ({ el, side: el.closest('.side'), d0: null, ex: null, ey: null }));
  const coarse = matchMedia('(pointer: coarse)').matches;
  const panes = home || PG.spots.length ? createScreens({ base, opaque: true, budget: coarse ? 1 : 0 }) : null;
  if (panes && coarse) { panes.resize('phone', 420); panes.resize('friend', 420); panes.resize('tv', 960); panes.resize('watch', 320); panes.resize('pad', 820); panes.resize('mac', 960); }
  else if (panes && matchMedia('(max-width: 860px), (max-aspect-ratio: 1/1)').matches) { panes.resize('tv', 1280); panes.resize('pad', 1024); panes.resize('mac', 1280); }
  if (panes && !home) panes.preload([...new Set(chapters.flatMap(c => c.states.flatMap(st => ['macShot', 'tvShot', 'phoneShot', 'padShot'].map(k => st[k]).filter(Boolean))))]);
  const spots = (home ? [['phone', 'phone'], ['tv', 'tv'], ['watch', 'watch'], ['friend', 'phone'], ['pad', 'ipad'], ['mac', 'mac']] : PG.spots).map(([name, body]) => ({ name, pw: SCREENS[name].w, ph: SCREENS[name].h, ww: L[body].sw, vis: null, m: null, cx: 0, cy: 0, rev: 0 }));
  const spot = name => spots.find(s => s.name === name);
  const manual = qs.has('manual');
  const plate = qs.has('plate');
  let pageKeys = [], pageSeen = true, deepNow = false, phoneU = 0, phoneGoal = 0;

  let vw = 1, vh = 1, svh = 1, aspect = 1.6, mobile = false, dpr = 1;
  const rulers = coarse && CSS.supports('height', '100lvh') ? ['100lvh', '100svh'].map(h => { const i = document.createElement('i'); i.style.cssText = `position:fixed;top:0;left:0;width:0;height:${h};visibility:hidden;pointer-events:none`; document.body.append(i); return i; }) : null;
  const viewport = () => { if (!rulers) return [innerWidth, innerHeight, innerHeight]; const l = rulers[0].offsetHeight, s = rulers[1].offsetHeight; return [innerWidth, l ? Math.max(l, innerHeight) : innerHeight, s ? Math.min(s, innerHeight) : innerHeight]; };
  let p = 0, pe = 0, pv = 0, lastY = scrollY, bend = 0;
  let beats = 0, clock = 0, last = performance.now(), step = 0.016;
  const X = { pos: 0, vel: 0, target: null, held: false };
  let fade = 0;
  const deck = [0, 1].map(() => ({ w: 3.49, held: false, hand: 0, phi: 0, user: 0 }));
  const W0 = 3.49;
  const want = {}, shown = {};
  let slow = 0, quality = 1, burst = 1;
  let period = 16.7, every = 1, beatAt = 0, hot = 0, calm = 0, roomy = 0, wait = 4, raisedAt = -99, coolUntil = 0;
  let plateAt = 0, loadedB = false;
  let demoAt = -1;
  const arm = [0, 0];
  let liveK = 0, crown = 0;
  let open = !home, lit = !home;
  let seatK = home ? 0 : 1, seatV = 0, outT = 0, lightT = home ? 0 : 1, revT = home ? 0 : 1, litAge = 0;
  let soundWanted = home, starting = false, gestured = false;
  let glide = null, dim = null, themeNow = '', rests = [], drawn = false, dead = false;
  const LIN = Float32Array.from({ length: 256 }, (_, i) => { const v = i / 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
  const INK = [0.0092, 0.871], PASS = 4.5, GO = [0.13, 0.22];
  const heads = home ? $$('.ink', topBar).map(el => ({ el, inset: el.classList.contains('brand') ? 38 : 0, gated: !!el.closest('.xf, .snd'), box: null, lo: -1, hi: -1, mid: -1, l0: 0, l1: 0, m: 0, light: true, at: -9, since: 0, block: 1.5, home: true })) : [];
  const shadeImage = rgb => `linear-gradient(${Array.from({ length: 13 }, (_, i) => `rgb(${rgb} / ${(1 - smooth(i / 12)).toFixed(3)}) ${(i / 0.12).toFixed(1)}%`).join(', ')})`;
  const SHADE = [shadeImage('246 241 232'), shadeImage('11 9 8')];
  const shade = { el: null, o: 0, shown: 0, dark: null, on: false, t: 0, peak: 0, hit: 0 };
  if (home) {
    shade.el = document.createElement('i');
    shade.el.className = 'scrim';
    shade.el.setAttribute('aria-hidden', 'true');
    topBar.prepend(shade.el);
    heads.forEach(q => { q.el.dataset.ink = 'light'; });
    root.classList.add('hud');
  }
  const lums = new Float32Array(8192);
  let tapId = -1, tapRows = [], drift = 0, camWas = null;

  function measure() {
    [vw, vh, svh] = viewport(); aspect = vw / vh; mobile = mobileQuery.matches;
    dpr = Math.min(devicePixelRatio || 1, coarse ? 1.5 : mobile ? 2 : 1.5, Math.sqrt((coarse ? 1.5e6 : 3.4e6) / (vw * vh))) * quality * burst;
    stage.resize(vw, vh, dpr);
    if (home) main.style.paddingTop = `${(OPEN + END) * vh}px`;
    root.style.setProperty('--ih', vh + 'px'); root.style.setProperty('--svh', svh + 'px'); root.style.setProperty('--head', Math.round(topBar.getBoundingClientRect().bottom) + 'px'); root.style.setProperty('--foot', $('.foot').offsetHeight + 'px');
    inks.forEach(k => { k.d0 = null; k.ex = null; });
    heads.forEach(q => { q.box = null; });
    placeRests();
  }

  function placeRests(later) {
    if (dead) return;
    const fz = 0.12 * vh;
    const list = home ? (fade > 0.5 ? TB : TA).rests.map(at => [main, (lead + at) * vh]) : chapters.filter(c => c.id in REST && c.n).map(c => { const hold = Math.max(1, c.el.offsetHeight - vh - 2 * fz); return [c.el, fz + (REST[c.id] + 0.5) * hold / c.n]; });
    rests.forEach(r => r.remove());
    rests = list.map(([parent, top]) => { const i = document.createElement('i'); i.className = 'rest'; i.setAttribute('aria-hidden', 'true'); i.style.top = Math.round(top) + 'px'; parent.append(i); return i; });
    if (later) root.classList.remove('snap'); else root.classList.toggle('snap', rests.length > 0);
  }

  function shot(name) {
    const key = name.replace(/[!>+~]+$/, ''), tag = name.slice(key.length);
    const flip = tag.includes('!'), s = SHOT[key], push = tag.includes('>') ? (s.pw ?? 0.5) : tag.includes('+') ? 0.2 : tag.includes('~') ? (s.pw ?? 0.5) : 0, wide = tag.includes('~') ? 1.3 : tag.includes('>') ? (s.ww ?? 1.3) : 1;
    const c = (mobile ? s.p : s.l).slice();
    if (mobile) {
      c[5] *= clamp(aspect / 0.462, 1, 3.2);
      if (s.px && home) c[0] += (fade - 0.5) * s.px;
    } else {
      c[5] *= Math.max(1, aspect / 1.6) * wide;
      if (s.sx && !plate) c[6] += home ? (0.5 - fade) * 2 * s.sx : (flip ? -1 : 1) * s.sx;
      if (!home) c[6] += (flip ? -1 : 1) * (0.14 + push);
      if (plate) c[7] *= 0.4;
    }
    if (s.yawX && home) c[3] += (fade - 0.5) * s.yawX * (mobile ? 0.4 : 1);
    return c;
  }

  const blend = (a, b, e) => a.map((v, i) => (i === 5 ? Math.exp(lerp(Math.log(v), Math.log(b[i]), e)) : lerp(v, b[i], e)));
  const aim = c => Object.assign(stage.cam, { t: [c[0], c[1], c[2]], yaw: c[3], pitch: c[4], w: c[5], ox: c[6], oy: c[7] });

  function along(keys, on) {
    let i = 0;
    while (i < keys.length - 2 && keys[i + 1][0] <= on) i++;
    const [p0, n0] = keys[i], [p1, n1] = keys[i + 1];
    const a = shot(n0), b = shot(n1);
    return blend(a, b, smoother(p1 > p0 ? (on - p0) / (p1 - p0) : 1));
  }

  function camera(at) {
    if (!home && pageKeys.length < 2) { const c = shot(chapters[0] ? chapters[0].shots[0] : 'dj'); c[7] += pe * 2; aim(c); return; }
    const on = home ? Math.max(0, at) : at;
    let c = home ? (fade <= 0 ? along(TA.keys, on) : fade >= 1 ? along(TB.keys, on) : blend(along(TA.keys, on), along(TB.keys, on), smooth(fade))) : along(pageKeys, on);
    if (home && revT < 1) c = blend(at > OUT - 1 ? shot('out') : blend(shot('open0'), shot('open1'), smooth(pe / SEAT)), c, smoother(revT));
    aim(c);
  }

  // MARK: Chapters
  function chapterScript(dt) {
    const fz = 0.12 * vh, z = 0.2;
    pageKeys = [];
    pageSeen = false;
    let best = null;
    for (const c of chapters) {
      const r = c.el.getBoundingClientRect();
      const s = -r.top, len = Math.max(1, r.height - vh);
      c.s = s; c.len = len;
      c.near = s < 0 ? -s : s > len ? s - len : 0;
      if (s > -vh * 1.05 && s < len + vh * 1.05) pageSeen = true;
      if (!best || c.near < best.near) best = c;
      const flowing = c.flow && mobile;
      const half = vh / 2, e = EDGE * vh;
      c.alpha = flowing ? (r.bottom > 0 && r.top < vh ? 1 : 0) : (c.first ? 1 : ss(-half, -half + e, s)) * (1 - ss(len + half - e, len + half, s));
      const hold = Math.max(1, len - 2 * fz);
      c.cap = c.n ? clamp(Math.floor((s - fz) / (hold / c.n)), 0, c.n - 1) : 0;
      const a = (scrollY + r.top) / vh, b = a + len / vh;
      const open = c.first ? -9 : a + 0.2, close = b + 0.05;
      if (c.shots.length < 2 || !c.n) pageKeys.push([open, c.shots[0]], [close, c.shots[0]]);
      else {
        const step = hold / vh / c.n;
        for (let i = 0; i < c.n; i++) {
          const sh = c.shots[Math.min(i, c.shots.length - 1)], prev = c.shots[Math.max(0, Math.min(i - 1, c.shots.length - 1))];
          const s0 = a + fz / vh + i * step, s1 = s0 + step;
          if (i === 0) pageKeys.push([open, sh]);
          else if (sh !== prev) pageKeys.push([s0 - z, prev], [s0 + z, sh]);
          if (i === c.n - 1) pageKeys.push([close, sh]);
        }
      }
      want['cap-' + c.id] = flowing ? Array.from({ length: c.n }, (_, i) => +(i === c.n - 1)) : capFade(Array.from({ length: Math.max(0, c.n - 1) }, (_, i) => fz + (i + 1) * hold / c.n), c.n, s, EDGE * vh);
    }
    const state = { ph: 'play', out: 'idle', tv: 'off', tvb: 'np', w: 'clock', pad: 'home', mac: 'home', pick: false, picked: false, phone: 'home', macShot: null, tvShot: null, phoneShot: null, padShot: null };
    if (best) for (let i = 0; i <= Math.min(best.cap, best.states.length - 1); i++) Object.assign(state, best.states[i]);
    Object.assign(want, state);
    want.pad = state.pad; want.mac = state.mac;
    phoneGoal = state.phone === 'tv' ? 1 : 0;
    phoneU = toward(phoneU, phoneGoal, 1.1, 1.1, dt);
    S.phone = carry(L.phoneHome, L.phoneTV, phoneU, 0.06, 0.14);
    S.friend = carry(L.friendOff, L.friendPos, state.out === 'share' ? 1 : 0, 0.04, -0.06);
  }

  const wipeEdge = () => lerp(1.4, -0.4, fade);
  const wipeAt = (x, y) => ss(wipeEdge() - 0.3, wipeEdge() + 0.3, x / vw + (0.5 - y / vh) * 0.18);

  function carry(from, to, u, lift, swing) {
    const e = smoother(u), arc = Math.sin(Math.PI * e);
    const x = lerp(from[0], to[0], e), z = lerp(from[1], to[1], e) + arc * swing;
    return [x, z, lerp(from[2], to[2], e) + arc * 0.3, lerp(padAt(from[0], from[1]), padAt(to[0], to[1]), e) + arc * lift, -arc * 0.2];
  }

  function script(at) {
    const A = TA.by, m = TA.mid;
    S.phone = carry(L.phoneHome, L.phoneTV, (at - A.tap - 0.2) / 0.5, 0.06, 0.14);
    S.friend = carry(L.friendOff, L.friendPos, (at - A.share + 0.42) / 0.3, 0.04, -0.06);
    want.ph = at < m('likes', 'set') ? 'lib' : at < m('set', 'list') ? 'play' : at < A.tap + 0.2 ? 'list' : 'out';
    want.pick = at > m('likes', 'set') - 0.14 && at < m('likes', 'set');
    want.out = at < A.sign - 0.2 ? 'idle' : at < m('sign', 'playon') ? 'toast' : at < m('sign', 'playon') + 0.2 ? 'sheet' : at < m('watch', 'share') ? 'tv' : 'share';
    want.picked = at > m('sign', 'playon') + 0.1;
    want.tv = at < A.sign - 0.32 ? 'off' : at < m('sign', 'playon') + 0.1 ? 'sign' : 'play';
    want.tvb = 'np';
    want.w = at > A.watch - 0.16 ? 'remote' : at > m('playon', 'watch') - 0.1 ? 'home' : 'clock';
    want.pad = want.mac = at < m('watch', 'share') ? 'home' : 'play';
    want.demo = at > A.tap - 0.12 && at < A.tap + 0.18;
    if (fade > 0.5) {
      const B = TB.by, n = TB.mid;
      want.mac = at > 0.5 && at < OUT ? 'play' : 'home';
      want.macShot = want.mac === 'play' ? MAC_B(at) : null;
      want.tv = at > n('learn', 'tvcues') && at < n('watchit', 'cdjs') ? 'play' : 'off';
      want.tvShot = want.tv === 'play' ? TV_B(at) : null;
      want.demo = false;
    } else want.macShot = want.tvShot = null;
    for (const id in TA.caps) want['cap-' + id] = capFade(TA.caps[id], TA.caps[id].length + 1, at);
    for (const id in TB.caps) want['capb-' + id] = capFade(TB.caps[id], TB.caps[id].length + 1, at);
  }

  function commit() {
    if (panes) {
      if (shown.ph !== want.ph || shown.pick !== want.pick || shown.out !== want.out || shown.picked !== want.picked || shown.phoneShot !== want.phoneShot) { shown.ph = want.ph; shown.pick = want.pick; shown.out = want.out; shown.picked = want.picked; shown.phoneShot = want.phoneShot; panes.set('phone', { ph: want.ph, pick: want.pick, out: want.out, picked: want.picked, shot: want.phoneShot || null }); }
      if (shown.tv !== want.tv || shown.tvb !== want.tvb || shown.tvShot !== want.tvShot) { shown.tv = want.tv; shown.tvb = want.tvb; shown.tvShot = want.tvShot; panes.set('tv', { tv: want.tv, tvb: want.tvb, shot: want.tvShot || null }); }
      if (shown.w !== want.w) { shown.w = want.w; panes.set('watch', { w: want.w }); }
      if (shown.pad !== want.pad || shown.padShot !== want.padShot) { shown.pad = want.pad; shown.padShot = want.padShot; panes.set('pad', { pad: want.pad, shot: want.padShot || null }); }
      if (shown.mac !== want.mac || shown.macShot !== want.macShot) { shown.mac = want.mac; shown.macShot = want.macShot; panes.set('mac', { mac: want.mac, shot: want.macShot || null }); }
    }
    if (want.demo && !shown.demo && !np.tapped) demoAt = clock;
    shown.demo = want.demo;
    for (const id in scenes) {
      const sc = scenes[id];
      for (const [k, list] of [['cap-' + id, sc.capsA], ['capb-' + id, sc.capsB]]) {
        const os = want[k];
        if (!os) continue;
        list.forEach((c, i) => {
          const o = Math.round((os[i] ?? 0) * 1000) / 1000;
          if (c._co === o) return;
          c._co = o;
          c.style.setProperty('--co', o);
          const on = o > 0.5;
          if (on !== c.classList.contains('on')) { c.classList.toggle('on', on); inks.forEach(q => { q.d0 = null; }); }
        });
      }
    }
  }

  function header(head) {
    const n = Math.max(2, Math.round((head - 8) / 3));
    if (tapRows.length !== n || tapRows[n - 1] !== head - 4) tapRows = Array.from({ length: n }, (_, i) => 4 + (head - 8) * i / (n - 1));
    const g = stage.probe(tapRows);
    const fresh = !!g && g.id !== tapId;
    if (fresh) tapId = g.id;
    const span = head * 2.4;
    const night = lightT < 0.5 || fade > 0.5;
    if (shade.dark !== night && shade.o < 0.02) { shade.dark = night; shade.el.style.backgroundImage = SHADE[night ? 1 : 0]; }
    const enc = l => Math.pow(l, 0.4545), base = enc(shade.dark ? 0.004 : 0.87);
    const wash = (l, a) => Math.pow(lerp(enc(l), base, a), 2.2);
    const floor = 5.2 * (INK[0] + 0.05) - 0.05, roof = (INK[1] + 0.05) / 5.2 - 0.05;
    let need = 0, worst = 99, worn = 99;
    for (const q of heads) {
      if (!q.box) { const r = q.el.getBoundingClientRect(); q.box = [r.left + q.inset, r.right, r.top + r.height * 0.2, r.bottom - r.height * 0.2]; q.fall = 1 - smooth((q.box[2] + q.box[3]) / 2 / span); }
      const [x0, x1, y0, y1] = q.box;
      q.live = x1 > x0;
      if (!q.live) continue;
      if (fresh) {
        const k = g.w / vw, stride = Math.max(1, Math.round(k * 2));
        let c = 0;
        for (let i = 0; i < g.n; i++) {
          if (g.rows[i] < y0 || g.rows[i] > y1) continue;
          for (let x = Math.max(0, Math.round(x0 * k)), end = Math.min(g.w, Math.round(x1 * k)); x < end && c < lums.length; x += stride) {
            const p = (i * g.w + x) * 4;
            lums[c++] = 0.2126 * LIN[g.px[p]] + 0.7152 * LIN[g.px[p + 1]] + 0.0722 * LIN[g.px[p + 2]];
          }
        }
        if (c) {
          const v = lums.subarray(0, c).sort(), cut = Math.max(1, c / 5 | 0);
          let lo = 0, hi = 0;
          for (let i = 0; i < cut; i++) { lo += v[i]; hi += v[c - 1 - i]; }
          q.lo = lo / cut; q.hi = hi / cut; q.mid = v[c >> 1];
        }
      }
      if (q.lo >= 0) { q.l0 = q.lo; q.l1 = q.hi; q.m = q.mid; }
      else q.l0 = q.l1 = q.m = lightT < 0.5 || wipeAt((x0 + x1) / 2, (y0 + y1) / 2) > 0.5 ? 0.01 : 0.87;
      if (q.gated && !lit) continue;
      q.home = lightT < 0.5 || wipeAt((x0 + x1) / 2, (y0 + y1) / 2) > 0.5;
      const best = Math.max((q.l0 + 0.05) / (INK[0] + 0.05), (INK[1] + 0.05) / (q.l1 + 0.05));
      worst = Math.min(worst, best);
      worn = Math.min(worn, q.light ? (INK[1] + 0.05) / (q.l1 + 0.05) : (q.l0 + 0.05) / (INK[0] + 0.05));
      if (best < PASS) need = Math.max(need, (shade.dark ? (q.l1 > roof ? (enc(q.l1) - enc(roof)) / (enc(q.l1) - base) : 0) : q.l0 < floor ? (enc(floor) - enc(q.l0)) / (base - enc(q.l0)) : 0) / q.fall);
    }
    const still = 1 - clamp((drift - 0.1) / 0.25);
    const mixed = worst < (shade.on ? 5 : PASS) && (lightT <= 0 || lightT >= 1) && revT >= 1 && (fade < 0.02 || fade > 0.98);
    shade.t = mixed === shade.on ? 0 : shade.t + step * (mixed && worn > 3 ? 1 - clamp((drift - 0.2) / 0.4) : 1);
    if (shade.t > (shade.on ? 0.6 : 0.3)) { shade.on = mixed; shade.t = 0; }
    if (need >= shade.peak - 0.02) shade.hit = clock;
    shade.peak = !shade.on || need > shade.peak ? need : clock - shade.hit > 1 ? shade.peak + (need - shade.peak) * (1 - Math.exp(-step / 0.5)) : shade.peak;
    const goal = shade.on && shade.dark === night ? Math.min(shade.dark ? 0.6 : 0.45, shade.peak * 1.15) : 0;
    shade.o += (goal - shade.o) * (1 - Math.exp(-step / (goal > shade.o ? 0.18 : 0.4)));
    const o = shade.o < 0.004 ? 0 : +shade.o.toFixed(3);
    if (o !== shade.shown) { shade.shown = o; shade.el.style.opacity = o; }
    for (const q of heads) {
      if (!q.live) continue;
      const a = o * q.fall;
      const dark = (wash(q.l0, a) + 0.05) / (INK[0] + 0.05) >= PASS, pale = (INK[1] + 0.05) / (wash(q.l1, a) + 0.05) >= PASS;
      const light = dark !== pale ? pale : wash(q.m, a) < GO[q.light ? 1 : 0];
      const back = light === q.home, clear = dark !== pale;
      if (light === q.light || (!back && !clear)) { q.since = 0; continue; }
      // Going home is quick. Leaving home needs the other ink to pass outright (above),
      // the camera to have stopped for a moment, and the label's lock to have run out,
      // unless the ink it has is unreadable (under 3:1): then 0.15 s of it is enough.
      const bad = (q.light ? (INK[1] + 0.05) / (wash(q.l1, a) + 0.05) : (wash(q.l0, a) + 0.05) / (INK[0] + 0.05)) < 3;
      q.since += step * (back || bad ? 1 : still);
      if ((q.at >= 0 && q.since < 0.08) || (!back && (bad ? q.since < 0.15 : q.since < 0.25 || clock - q.at < q.block))) continue;
      if (q.at >= 0) q.block = back ? (clock - q.at < 3 ? Math.min(30, q.block * 2) : 1.5) : q.block;
      q.at = clock;
      q.since = 0;
      q.light = light;
      q.el.dataset.ink = light ? 'light' : 'dark';
    }
  }

  function copy(at) {
    const e = wipeEdge();
    const gl = Math.hypot(1 / vw, 0.18 / vh);
    const lk = smooth(lightT);
    const follow = 1 - Math.exp(-step / 0.1);
    for (const id in scenes) {
      const sc = scenes[id];
      const w = TA.windows[id], wB = TB.windows[id];
      const ch = home ? null : chapters.find(c => c.id === id);
      const alpha = ch ? ch.alpha : (w ? ss(w[0], w[1], at) * (1 - ss(w[2], w[3], at)) : 1);
      const alphaB = ch ? ch.alpha : wB ? ss(wB[0], wB[1], at) * (1 - ss(wB[2], wB[3], at)) : 0;
      [sc.a, sc.b, sc.vis].forEach((el, k) => {
        if (!el) return;
        const bSide = k === 1;
        let o = bSide && home ? alphaB : alpha;
        if (o > 0.001 && home) {
          let s;
          if (mobile || id === 'join') { const t = id === 'join' || !!bSide === fade > 0.5 ? 1 : 0; el._x = lerp(el._x ?? t, t, follow); s = el._x < 0.004 ? 0 : el._x > 0.996 ? 1 : el._x; }
          else { const r = el.getBoundingClientRect(); const m = wipeAt(r.left + r.width / 2, r.top + r.height / 2); s = bSide ? ss(0.6, 0.95, m) : 1 - ss(0.5, 0.9, m); }
          o *= id === 'hero' ? lerp(bSide === fade > 0.5 ? 1 : 0, s, lk) : s;
        }
        const keep = !home || k === 2 || id === 'join' || bSide === fade > 0.5;
        if (el._o !== o || el._k !== keep) {
          el._o = o; el._k = keep;
          el.style.setProperty('--o', o.toFixed(3));
          el.style.setProperty('--v', o > 0.004 || keep ? 'visible' : 'hidden');
          el.classList.toggle('on', o > 0.5);
        }
      });
    }
    const head = topBar.getBoundingClientRect().bottom;
    if (home) header(head);
    if (home) [scenes.join.a].forEach(el => { if (!(el._o > 0.004)) return; const cut = Math.round(head - 8 - el.getBoundingClientRect().top); if (cut !== el._cut) { el._cut = cut; el.style.setProperty('--cut', cut + 'px'); } });
    const dimNow = lightT < 1;
    if (dimNow !== dim) { dim = dimNow; root.classList.toggle('dim', dim); }
    if (dim) {
      const g = stage.light;
      root.style.setProperty('--lx', g.cx.toFixed(1) + 'px');
      root.style.setProperty('--ly', g.cy.toFixed(1) + 'px');
      root.style.setProperty('--lrx', Math.max(1, g.rx).toFixed(1) + 'px');
      root.style.setProperty('--lry', Math.max(1, g.ry).toFixed(1) + 'px');
    }
    if (home) for (const k of inks) {
      if (k.side && !(k.side._o > 0.004)) { k.r = null; continue; }
      k.r = k.el.getBoundingClientRect();
    }
    if (home) for (const k of inks) {
      const r = k.r;
      if (!r || r.bottom < -40 || r.top > vh + 40 || !r.width) continue;
      if (dim) {
        const ex = Math.round(r.left * 2) / 2, ey = Math.round(r.top * 2) / 2;
        if (ex !== k.ex || ey !== k.ey) { k.ex = ex; k.ey = ey; k.el.style.setProperty('--ex', ex + 'px'); k.el.style.setProperty('--ey', ey + 'px'); }
      }
      const sc = (r.left + r.width / 2) / vw + (0.5 - (r.top + r.height / 2) / vh) * 0.18;
      const d0 = Math.round((e + 0.07 - sc) / gl), d1 = Math.round((e + 0.19 - sc) / gl);
      if (d0 === k.d0) continue;
      k.d0 = d0;
      k.el.style.setProperty('--d0', d0 + 'px');
      k.el.style.setProperty('--d1', d1 + 'px');
    }
    const tc = lightT < 0.5 ? '#0b0908' : fade > 0.5 ? '#110e0c' : '#f6f1e8';
    if (tc !== themeNow) { themeNow = tc; if (theme) theme.setAttribute('content', tc); }
  }

  function screens(dt) {
    if (!panes) return;
    for (const s of spots) {
      const m = stage.css(world.screens[s.name](), s.pw, s.ph, s.ww);
      let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9, front = true;
      for (let k = 0; k < 4; k++) {
        const X = k & 1 ? s.pw : 0, Y = k & 2 ? s.ph : 0, w = m[3] * X + m[7] * Y + m[15];
        if (w <= 0.0001) { front = false; break; }
        const x = (m[0] * X + m[4] * Y + m[12]) / w, y = (m[1] * X + m[5] * Y + m[13]) / w;
        x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y);
      }
      const vis = front && x1 > -vw * 0.15 && x0 < vw * 1.15 && y1 > -vh * 0.15 && y0 < vh * 1.15;
      if (vis !== s.vis) { s.vis = vis; panes.show(s.name, vis); }
      const w = m[3] * s.pw / 2 + m[7] * s.ph / 2 + m[15];
      s.m = m;
      s.cx = (m[0] * s.pw / 2 + m[4] * s.ph / 2 + m[12]) / w;
      s.cy = (m[1] * s.pw / 2 + m[5] * s.ph / 2 + m[13]) / w;
    }
    const ph = spot('phone'), tv = spot('tv');
    if (ph) { const pb = home && (ph.vis ? (shown.ph === 'play' || shown.ph === 'list') && wipeAt(ph.cx, ph.cy) > 0.5 : !!shown.pb); if (pb !== shown.pb) { shown.pb = pb; panes.set('phone', { b: pb }); } }
    if (tv) { const tb = home && (tv.vis ? shown.tv !== 'off' && wipeAt(tv.cx, tv.cy) > 0.5 : !!shown.tb); if (tb !== shown.tb) { shown.tb = tb; panes.set('tv', { b: tb }); } }
    for (const s of [spot('pad'), spot('mac')]) { if (!s) continue; const k = 'b' + s.name, v = home && (s.vis ? wipeAt(s.cx, s.cy) > 0.5 : !!shown[k]); if (v !== shown[k]) { shown[k] = v; panes.set(s.name, { b: v }); } }
    panes.time(np.sec);
    for (const name of panes.step(dt)) { const s = spot(name); if (s) world.setScreen(name, panes.canvas(name), ++s.rev); }
  }

  function track(x, y) {
    const s = spot('phone');
    if (!s || !s.vis || !s.m || shown.ph !== 'list') return null;
    const [a, d, , g, b, e, , h, , , , , c, f, , i] = s.m;
    const W = (d * h - e * g) * x + (b * g - a * h) * y + (a * e - b * d);
    const hit = panes.hit('phone', ((e * i - f * h) * x + (c * h - b * i) * y + (b * f - c * e)) / W, ((f * g - d * i) * x + (a * i - c * g) * y + (c * d - a * f)) / W);
    return hit ? hit.track : null;
  }

  // MARK: Instrument
  const ppm = () => vw / stage.cam.w;
  function pick(x, y) {
    const slop = 9 / ppm();
    const { tip, axis } = S.jack;
    const j0 = stage.project(tip[0] + axis[0] * 0.02, tip[1] + axis[1] * 0.02, tip[2] + axis[2] * 0.02), j1 = stage.project(tip[0] + axis[0] * L.jack.back, tip[1] + axis[1] * L.jack.back, tip[2] + axis[2] * L.jack.back);
    const jl = Math.hypot(j1[0] - j0[0], j1[1] - j0[1]) || 1;
    const jt = clamp(((x - j0[0]) * (j1[0] - j0[0]) + (y - j0[1]) * (j1[1] - j0[1])) / (jl * jl));
    const onJack = Math.hypot(x - lerp(j0[0], j1[0], jt), y - lerp(j0[1], j1[1], jt)) < Math.max(16, 0.014 * ppm());
    if (!lit) return onJack ? { type: 'jack' } : null;
    const m = stage.hitY(x, y, L.mixerY + 0.012);
    if (m && Math.abs(m[0]) < L.mixerW / 2 + slop && Math.abs(m[1]) < L.mixerD / 2 + slop) {
      if (Math.abs(m[1] - L.xfZ) < 0.02 + slop && Math.abs(m[0]) < L.xfTravel / 2 + 0.014 + slop) return { type: 'xf' };
      for (let c = 0; c < 2; c++) {
        const cx = (c ? 1 : -1) * L.knobX;
        if (Math.abs(m[0] - cx) < 0.016 + slop && m[1] > L.chanZ - L.chanTravel - 0.01 - slop && m[1] < L.chanZ + 0.01) return { type: 'chan', i: c };
      }
      let best = null, bd = 1;
      for (let n = 0; n < 8; n++) {
        const d = Math.hypot(m[0] - (n < 4 ? -1 : 1) * L.knobX, m[1] - L.knobZ[n % 4]);
        if (d < bd) { bd = d; best = n; }
      }
      if (bd < 0.0125 * (best % 4 === 3 ? 1.3 : 1) + slop) return { type: 'knob', i: best };
    }
    if (onJack) return { type: 'jack' };
    const d = stage.hitY(x, y, L.yRecord + 0.002);
    if (d) for (let i = 0; i < 2; i++) {
      const dk = world.decks[i];
      if (Math.hypot(d[0] - dk.px, d[1]) < 0.159) return { type: 'deck', i };
      if (Math.abs(d[0] - (dk.ox - 0.185)) < 0.03 + slop && Math.abs(d[1] - 0.151) < 0.019 + slop) return { type: 'start', i };
      if (Math.abs(d[0] - (dk.ox + L.pitchX)) < 0.018 + slop && Math.abs(d[1] - L.pitchZ) < 0.06) return { type: 'pitch', i };
    }
    return null;
  }

  const drags = new Map();
  const axis = (a, b) => { const p0 = stage.project(...a), p1 = stage.project(...b); const dx = p1[0] - p0[0], dy = p1[1] - p0[1]; const len = Math.hypot(dx, dy) || 1; const k = Math.max(1, 130 / len); return [dx / (len * len * k), dy / (len * len * k)]; };
  const deckPhi = (i, x, y) => { const d = stage.hitY(x, y, L.yRecord + 0.002); return d ? Math.atan2(d[1], d[0] - world.decks[i].px) : null; };

  // MARK: Sound
  const allowed = () => gestured || !!(navigator.userActivation && navigator.userActivation.hasBeenActive);
  function label() {
    soundButtons.forEach(b => { b.setAttribute('aria-pressed', String(audio.on)); $('span', b).textContent = b.classList.contains('plug') ? (audio.on ? 'Lift the needles' : 'Drop the needles') : (audio.on ? 'Sound on' : 'Sound off'); });
  }
  function tryStart(force) {
    if (audio.on || starting || !soundWanted || !(open || force) || !allowed()) return;
    starting = true;
    audio.start().then(() => {
      starting = false;
      if (!soundWanted || !(open || glide)) { audio.stop(); label(); return; }
      audio.sync(((beats % 16) * 60 / BPM) * audio.ctx.sampleRate);
      if (lit && litAge < 0.5) audio.thunk();
      label();
    }).catch(() => { starting = false; soundWanted = false; label(); });
  }
  function setSound(on) {
    gestured = true;
    soundWanted = on;
    if (on) { audio.warm(); tryStart(); } else if (audio.on) audio.stop();
    label();
  }
  soundButtons.forEach(b => b.addEventListener('click', () => setSound(!audio.on)));

  function glideTo(target) {
    const from = scrollY / vh;
    const d = Math.abs(target - from);
    if (d < 0.01) return;
    glide = { from, to: target, t: 0, dur: clamp(0.9 + d * 0.55, 1.2, 3.4) };
  }
  function togglePlug() {
    gestured = true;
    if (!home) { setSound(!audio.on); return; }
    const T = fade > 0.5 ? TB : TA, late = pe - OPEN > T.last + 0.3;
    if (open) { glideTo(late ? OPEN + END : 0); return; }
    soundWanted = true;
    tryStart(true);
    glideTo(OPEN + (late ? T.last : HERO));
  }
  plugButtons.forEach(b => b.addEventListener('click', e => { e.preventDefault(); togglePlug(); }));
  if (home) $$('a[href="?side=dj"]').forEach(a => a.addEventListener('click', e => { e.preventDefault(); X.target = 1; glideTo(0); }));

  function down(e) {
    if (e.button) return;
    const hit = pick(e.clientX, e.clientY);
    if (!hit) return;
    if (hit.type === 'jack') { togglePlug(); return; }
    if (hit.type === 'start') { S.motor[hit.i] = S.motor[hit.i] ? 0 : 1; return; }
    const g = { ...hit, x: e.clientX, y: e.clientY, t: performance.now(), x0: e.clientX, y0: e.clientY, touch: e.pointerType !== 'mouse', armed: e.pointerType === 'mouse', save: { pos: X.pos, chan: [...S.chan], knob: [...S.knob], user: deck.map(d => d.user) } };
    if (hit.type === 'deck') { const dk = deck[hit.i]; dk.held = true; dk.hand = 0; g.phi = deckPhi(hit.i, e.clientX, e.clientY); }
    if (hit.type === 'xf') { X.held = true; X.target = null; g.ax = axis([-L.xfTravel / 2, L.mixerY, L.xfZ], [L.xfTravel / 2, L.mixerY, L.xfZ]); }
    if (hit.type === 'chan') { const cx = (hit.i ? 1 : -1) * L.knobX; g.ax = axis([cx, L.mixerY, L.chanZ], [cx, L.mixerY, L.chanZ - L.chanTravel]); }
    if (hit.type === 'pitch') { const cx = world.decks[hit.i].ox + L.pitchX; g.ax = axis([cx, L.yPlinth, L.pitchZ - L.pitchTravel], [cx, L.yPlinth, L.pitchZ + L.pitchTravel]); }
    if (hit.type === 'knob') g.raw = S.knob[hit.i];
    drags.set(e.pointerId, g);
    try { canvas.setPointerCapture(e.pointerId); } catch (err) { drags.delete(e.pointerId); }
    canvas.style.cursor = 'grabbing';
    e.preventDefault();
  }

  function move(e) {
    const g = drags.get(e.pointerId);
    if (!g) {
      if (e.pointerType === 'mouse') { const h = pick(e.clientX, e.clientY); canvas.style.cursor = h ? (h.type === 'jack' || h.type === 'start' ? 'pointer' : 'grab') : track(e.clientX, e.clientY) != null ? 'pointer' : ''; }
      return;
    }
    if (!g.armed) {
      const ax = Math.abs(e.clientX - g.x0), ay = Math.abs(e.clientY - g.y0);
      if (Math.max(ax, ay) < 8) return;
      if (ay > ax) { release(e.pointerId, g, true); return; }
      g.armed = true; g.x = e.clientX; g.y = e.clientY; g.t = performance.now();
      return;
    }
    const dx = e.clientX - g.x, dy = e.clientY - g.y;
    const now = performance.now(), dt = Math.max(1, now - g.t) / 1000;
    if (g.type === 'deck') {
      const phi = deckPhi(g.i, e.clientX, e.clientY);
      if (phi != null && g.phi != null) {
        let d = phi - g.phi;
        if (d > Math.PI) d -= Math.PI * 2; else if (d < -Math.PI) d += Math.PI * 2;
        const dk = deck[g.i];
        S.angle[g.i] += d;
        dk.hand = lerp(dk.hand, d / dt, clamp(dt / 0.03));
      }
      g.phi = phi;
    } else if (g.type === 'knob') {
      g.raw = clamp(g.raw + (dx - dy) / 190);
      S.knob[g.i] = Math.abs(g.raw - 0.5) < 0.035 ? 0.5 : g.raw;
    } else {
      const dv = dx * g.ax[0] + dy * g.ax[1];
      if (g.type === 'xf') { const prev = X.pos; X.pos = clamp(X.pos + dv); X.vel = lerp(X.vel, (X.pos - prev) / dt, 0.5); }
      if (g.type === 'chan') S.chan[g.i] = clamp(S.chan[g.i] + dv);
      if (g.type === 'pitch') { const v = clamp(deck[g.i].user + dv * 2, -1, 1); deck[g.i].user = Math.abs(v) < 0.06 ? 0 : v; }
    }
    g.x = e.clientX; g.y = e.clientY; g.t = now;
  }

  function release(id, g, cancel) {
    drags.delete(id);
    try { canvas.releasePointerCapture(id); } catch (err) {}
    if (cancel) {
      X.pos = g.save.pos; X.vel = 0;
      g.save.chan.forEach((v, i) => { S.chan[i] = v; });
      g.save.knob.forEach((v, i) => { S.knob[i] = v; });
      g.save.user.forEach((v, i) => { deck[i].user = v; });
    }
    if (g.type === 'deck') { const dk = deck[g.i]; dk.held = false; if (!cancel) dk.w = performance.now() - g.t > 90 ? 0 : dk.hand; }
    if (g.type === 'xf') { X.held = false; if (cancel || performance.now() - g.t > 90) X.vel = 0; }
    canvas.style.cursor = '';
  }

  function up(e) {
    const g = drags.get(e.pointerId);
    if (g) release(e.pointerId, g, e.type === 'pointercancel');
  }

  canvas.addEventListener('pointerdown', down);
  canvas.addEventListener('pointermove', move);
  canvas.addEventListener('pointerup', up);
  canvas.addEventListener('pointercancel', up);
  canvas.addEventListener('click', e => { const i = track(e.clientX, e.clientY); if (i != null) { np.tapped = true; np.jump(i); } });
  canvas.addEventListener('dblclick', e => { const h = pick(e.clientX, e.clientY); if (h && h.type === 'knob') S.knob[h.i] = 0.5; if (h && h.type === 'pitch') deck[h.i].user = 0; });

  range.addEventListener('input', () => { X.target = null; X.vel = 0; X.pos = +range.value / 1000; });
  xfButtons.forEach(b => b.addEventListener('click', () => { X.target = +b.dataset.xf; }));

  // MARK: Plug
  function opening(dt, at) {
    const inside = pe >= SEAT && at < OUT;
    if (inside !== open) {
      open = inside;
      if (open) tryStart(); else if (audio.on) { audio.stop(); label(); }
    }
    const rise = (pe - SEAT) / LIGHT, gone = clamp((at - OUT) / 0.3);
    outT = smooth(gone);
    const u = clamp(pe / SEAT) * Math.pow(1 - outT, 2.2);
    const goal = inside ? 1 : 0;
    const w = 30, x = seatK - goal, e = Math.exp(-w * dt), q = (seatV + w * x) * dt;
    seatK = goal + (x + q) * e;
    seatV = (seatV - q * w) * e;
    if (inside !== lit) {
      lit = inside;
      root.dataset.plug = lit ? '1' : '0';
      if (lit) { if (audio.on) audio.thunk(); if (gestured && navigator.vibrate) navigator.vibrate(10); }
    }
    litAge = lit ? litAge + dt : 0;
    lightT = pe < SEAT ? 0 : at < OUT ? clamp(rise) : 1 - gone;
    revT = pe < SEAT ? 0 : at < OUT ? clamp((pe - SEAT - 0.05) / (OPEN + HERO - SEAT - 0.05)) : 1 - gone;
    stage.light.k = lightT;
    S.power += ((lit ? 1 : 0) - S.power) * (1 - Math.exp(-dt / 0.3));
    const glow = lit ? 0.8 : (0.32 + 0.68 * smooth(u)) * (0.95 + 0.05 * Math.sin(clock * 1.3));
    S.glow += (glow - S.glow) * (1 - Math.exp(-dt / 0.25));
    S.front = lit ? 0.15 + (0.4 * lightT + 4 * Math.pow(lightT, 3.4) + 12 * Math.pow(lightT, 12)) * 0.9 + 45 * clamp(rise - 1) : at >= OUT ? lerp(3, -1, gone) : -1;
    world.pose(u, clamp(seatK), clock);
  }

  function physics(dt) {
    if (!X.held) {
      if (X.target != null) {
        X.vel += ((X.target - X.pos) * 22 - X.vel * 9.4) * dt;
        if (Math.abs(X.target - X.pos) < 0.002 && Math.abs(X.vel) < 0.02) { X.pos = X.target; X.target = null; X.vel = 0; }
      } else X.vel *= Math.exp(-dt * 7);
      X.pos += X.vel * dt;
      if (X.pos < 0 || X.pos > 1) { X.pos = clamp(X.pos); X.vel = 0; }
    }
    S.xf = X.pos;
    fade += (X.pos - fade) * (1 - Math.exp(-dt / (X.held ? 0.16 : 0.3)));
    if (Math.abs(fade - X.pos) < 0.0005) fade = X.pos;
    S.fade = fade;
    const side = fade > 0.5 ? 'b' : 'a';
    if (root.dataset.side !== side) { root.dataset.side = side; xfButtons.forEach(b => b.setAttribute('aria-pressed', String((b.dataset.xf === '1') === (side === 'b')))); remember(side === 'b'); if (home) placeRests(true); }
    if (!drags.size || !X.held) { const v = Math.round(X.pos * 1000); if (document.activeElement !== range && +range.value !== v) range.value = v; }
    S.room = home ? fade : 0;
    if (panes && home && !loadedB && fade > 0.02) { loadedB = true; panes.preload(SHOTS_B); }

    const master = 1 + bend;
    const powered = lightT > 0.3;
    const rate = [1, 1], slip = [0, 0];
    for (let i = 0; i < 2; i++) {
      const dk = deck[i];
      const own = master * (1 + dk.user * 0.08);
      const run = S.motor[i] && powered;
      if (dk.held) { dk.hand *= Math.exp(-dt * 14); dk.w = dk.hand; }
      else {
        const target = run ? W0 * own : 0;
        const tau = run ? (Math.abs(dk.w) < W0 * 0.5 ? 0.6 : 0.2) : 1.15;
        dk.w += (target - dk.w) * (1 - Math.exp(-dt / tau));
        S.angle[i] += dk.w * dt;
      }
      rate[i] = dk.w / W0;
      slip[i] = dk.held || Math.abs(rate[i] - master) > 0.015 ? 1 : 0;
      S.pitch[i] = clamp(dk.user + bend * 4, -1, 1);
    }
    const needles = home ? lit && revT >= 0.98 : audio.on || starting;
    for (let i = 0; i < 2; i++) {
      const was = arm[i];
      arm[i] = clamp(arm[i] + (needles ? dt / (1.1 + i * 0.3) : -dt / 0.7));
      if (was <= 0.97 && arm[i] > 0.97 && audio.on) audio.drop();
    }
    S.arm = arm; S.w = [deck[0].w, deck[1].w]; S.dt = dt;
    liveK += ((arm[0] > 0.97 || arm[1] > 0.97 ? 1 : 0) - liveK) * (1 - Math.exp(-dt / 0.6));
    S.live = liveK;
    audio.set({ rate, masterRate: master, slip, scratch: [deck[0].held ? 1 : 0, deck[1].held ? 1 : 0], knob: S.knob, chan: [arm[0] > 0.97 ? S.chan[0] : 0, arm[1] > 0.97 ? S.chan[1] : 0], xf: X.pos });
    const lv = audio.levels();
    S.level[0] = lv[0]; S.level[1] = lv[1];
    beats += dt * BPM / 60 * master;
    if (audio.on && audio.beat) {
      const expect = (audio.beat.ref / audio.ctx.sampleRate + (audio.ctx.currentTime - audio.beat.at) * master) * BPM / 60;
      let err = (expect - beats) % 16;
      if (err > 8) err -= 16; else if (err < -8) err += 16;
      beats += err * 0.08;
    }
    S.beat = Math.pow(1 - (beats - Math.floor(beats)), 3);
    S.beats = beats % 64;
    const on = shown.tv === 'play' ? 1 : shown.tv === 'sign' ? 0.45 : 0;
    S.tvGlow = [0.5 * on * fade, 0.34 * on * fade, 0.2 * on * fade];
  }

  function tune(dt) {
    const cost = stage.R.cost, target = period * every;
    if (period >= 11.5) every = 1;
    else if (every === 1) { if (!(cost > 0) || cost > period * 0.62 || quality < 1) every = 2; }
    else if (cost > 0 && cost < period * 0.42 && quality >= 1) { roomy += dt; if (roomy > 4) { roomy = 0; every = 1; } }
    else roomy = 0;
    if (clock < coolUntil) return;
    const load = cost > 0 ? cost / (target * 0.72) : slow * 1000 / (target * 1.22);
    if (load > 1) { hot += dt; calm = 0; }
    else { hot = Math.max(0, hot - dt); calm = load < (cost > 0 ? 0.72 : 0.9) ? calm + dt : 0; }
    if (hot > 0.5) {
      hot = 0; calm = 0; coolUntil = clock + 0.7; slow = target / 1000;
      if (quality > 0.6) {
        if (clock - raisedAt < 5) wait = Math.min(120, wait * 2);
        quality = Math.max(0.6, quality * clamp(1 / Math.sqrt(Math.max(load, 1.05)), 0.8, 0.96));
        measure();
      } else if (stage.fx.dof) stage.fx.dof = 0;
    } else if (calm > wait && quality < 1) {
      calm = 0; coolUntil = clock + 0.7; raisedAt = clock;
      quality = Math.min(1, quality * 1.07);
      measure();
    }
  }

  function tick(now) {
    if (dead) return;
    if (!manual) {
      requestAnimationFrame(tick);
      if (document.hidden) { last = now; beatAt = now; return; }
      const raw = now - beatAt;
      beatAt = now;
      if (raw > 3 && raw < period * 1.4) period += (raw - period) * 0.08;
      else if (raw >= period * 1.4 && raw < 40) period += (raw - period) * 0.004;
      if (every > 1 && now - last < period * (every - 0.5)) return;
    }
    const dt = Math.min(0.05, Math.max(0, (now - last) / 1000)) || 0.016;
    last = now;
    step = dt;
    clock += dt;
    slow = lerp(slow, dt, 0.05);
    if (!manual && now > 3000) tune(dt);
    if (glide) {
      glide.t += dt;
      scrollTo(0, lerp(glide.from, glide.to, smoother(glide.t / glide.dur)) * vh);
      if (glide.t >= glide.dur) glide = null;
    }
    if (!!glide !== root.classList.contains('glide')) root.classList.toggle('glide', !!glide);
    const y = scrollY;
    p = plate ? plateAt + lead : y / vh;
    const v = (y - lastY) / vh / dt;
    lastY = y;
    bend += (clamp(v / 16, -0.05, 0.05) - bend) * (1 - Math.exp(-dt / 0.4));
    if (plate) { pe = p; pv = 0; }
    else {
      const was = pe;
      pe += (p - pe) * (1 - Math.exp(-dt / 0.075));
      if (Math.abs(pe - p) < 0.0004) pe = p;
      pv = (pe - was) / dt;
    }
    if (panes) panes.pace(Math.abs(pv) > 3 ? 0 : 1);
    const at = pe - lead;
    if (home) opening(dt, at);
    if (home && !manual) {
      const b = lightT > 0 && lightT < 1 ? 0.75 : 1;
      if (b !== burst) { burst = b; hot = 0; calm = 0; coolUntil = clock + 0.7; measure(); }
    }
    physics(dt);
    if (home) {
      script(at);
      commit();
      if (demoAt > 0 && clock >= demoAt) { demoAt = -1; if (!np.tapped && shown.ph === 'list') np.jump(3); }
      if (shown.ph !== 'lib') np.set(np.sec + dt * (1 + bend));
      if (shown.w === 'remote' && Math.abs(at - TA.by.watch) < 0.2 && pv) { crown += pv * dt * 16; np.set(clamp(np.sec + pv * dt * 1500, 0, MIX.duration - 1)); }
      S.crown = crown;
    } else {
      chapterScript(dt);
      commit();
      np.set(np.sec + dt);
      const deep = y > 24;
      if (deep !== deepNow) { deepNow = deep; root.classList.toggle('deep', deep); }
    }
    camera(at);
    if (home && p > OPEN + END) stage.cam.oy += (p - OPEN - END) * 2;
    if (home) {
      const c = stage.cam, was = camWas || [c.t[0], c.t[1], c.t[2], c.w, c.yaw, c.pitch, c.ox, c.oy];
      const moved = (Math.hypot(c.t[0] - was[0], c.t[1] - was[1], c.t[2] - was[2]) / c.w + Math.abs(Math.log(c.w / was[3])) + (Math.abs(c.yaw - was[4]) + Math.abs(c.pitch - was[5])) * 0.02 + Math.hypot(c.ox - was[6], c.oy - was[7])) / dt;
      drift += (moved - drift) * (1 - Math.exp(-dt / 0.08));
      camWas = [c.t[0], c.t[1], c.t[2], c.w, c.yaw, c.pitch, c.ox, c.oy];
    }
    if (home || pageSeen) stage.render(clock);
    if (!drawn && stage.fresh) { drawn = true; root.classList.add('drawn'); }
    screens(dt);
    copy(at);
  }

  const act = () => { gestured = true; if (soundWanted) audio.warm(); tryStart(); };
  const resume = () => { glide = null; if (rests.length && !root.classList.contains('snap')) root.classList.add('snap'); };
  ['pointerdown', 'keydown', 'touchend'].forEach(t => addEventListener(t, act, { passive: true, capture: true }));
  ['wheel', 'touchstart'].forEach(t => addEventListener(t, resume, { passive: true, capture: true }));
  addEventListener('keydown', e => { if (['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '].includes(e.key)) resume(); }, { capture: true });
  addEventListener('resize', () => { const [w, h] = viewport(); if (w !== vw || h !== vh) measure(); });
  mobileQuery.addEventListener('change', measure);
  document.addEventListener('focusin', e => {
    if (!home) return;
    const sc = e.target.closest && e.target.closest('.scene');
    if (!sc || sc.dataset.scene === 'join' || sc.dataset.scene === 'hero') return;
    const T = fade > 0.5 ? TB : TA, w = T.windows[sc.dataset.scene];
    const at = pe - lead;
    if (w && (at < w[1] || at > w[2])) scrollTo({ top: (T.anchor[sc.dataset.scene] + lead) * vh });
  });
  const hash = () => { if (!home) return; const id = location.hash.slice(1), T = fade > 0.5 ? TB : TA, key = id === 'top' ? 'top' : id; if (key in T.anchor) scrollTo({ top: (T.anchor[key] + lead) * vh }); };
  addEventListener('hashchange', hash);

  measure();
  if (plate) {
    root.classList.add('plate-mode');
    stage.fx.vig = 0;
    const [at, f] = qs.get('plate').split(',').map(Number);
    X.pos = fade = f || 0;
    plateAt = at;
  } else if (qs.has('xf')) X.pos = fade = clamp(+qs.get('xf') || 0);
  else if (startB) X.pos = fade = 1;
  S.room = home ? fade : 0;
  placeRests();
  hash();
  pe = p = plate ? plateAt + lead : scrollY / vh;
  if (home) {
    const at = pe - OPEN;
    open = lit = pe >= SEAT && at < OUT;
    seatK = open ? 1 : 0;
    litAge = open ? 9 : 0;
    arm[0] = arm[1] = open ? 1 : 0;
    deck[0].w = deck[1].w = open ? W0 : 0;
    S.power = open ? 1 : 0;
    S.glow = open ? 0.8 : 0.32;
    root.dataset.plug = open ? '1' : '0';
    opening(0, at); script(at); commit();
  } else if (plate) arm[0] = arm[1] = 1;
  if (!home) {
    if (qs.has('scroll')) scrollTo(0, +qs.get('scroll') * vh);
    pe = p = scrollY / vh;
    chapterScript(0); phoneU = phoneGoal; commit();
  }
  label();
  setTimeout(() => world.loadSleeves(), 400);
  if (panes) setTimeout(() => panes.warm(), 1400);
  if (panes && home && !coarse) setTimeout(() => { if (!loadedB) { loadedB = true; panes.preload(SHOTS_B); } }, 3500);
  if (home && !manual) ('requestIdleCallback' in window ? requestIdleCallback : setTimeout)(() => { if (soundWanted && !audio.on) audio.warm(); }, 'requestIdleCallback' in window ? { timeout: 5000 } : 2600);
  function settle() {
    if (dead) return;
    dead = true;
    glide = null;
    soundWanted = false;
    if (audio.on) audio.stop();
    const at = pe - lead;
    let id = 'top';
    if (home) {
      const T = fade > 0.5 ? TB : TA;
      const near = T.stops.reduce((a, s) => Math.abs(s.at - at) < Math.abs(a.at - at) ? s : a, T.stops[0]);
      id = at > OUT ? 'join' : near.scene === 'hero' ? 'top' : near.scene;
    } else if (chapters.length) id = chapters.reduce((a, c) => c.near < a.near ? c : a, chapters[0]).el.id || 'top';
    rests.forEach(r => r.remove());
    rests = [];
    if (shade.el) shade.el.remove();
    root.classList.remove('live', 'page', 'coarse', 'hud', 'dim', 'deep', 'snap', 'glide', 'drawn');
    main.style.paddingTop = '';
    still();
    const el = document.getElementById(id);
    if (el && id !== 'top') el.scrollIntoView(); else scrollTo(0, 0);
  }
  matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', e => { if (e.matches) settle(); });
  window.sounding = {
    seek: at => { glide = null; scrollTo(0, (at + lead) * vh); },
    fade: f => { X.target = null; X.vel = 0; X.pos = f; },
    sound: setSound,
    plug: togglePlug,
    settle,
    step: (dt = 1 / 60) => { tick(last + dt * 1000); },
    state: () => ({ p: +(pe - lead).toFixed(4), raw: +(p - lead).toFixed(4), sec: +np.sec.toFixed(2), fade, head: { shade: +shade.o.toFixed(3), dark: shade.dark, inks: heads.map(q => q.light ? 1 : 0), drift: +drift.toFixed(3), back: heads.map(q => [+q.l0.toFixed(3), +q.m.toFixed(3), +q.l1.toFixed(3)]) }, quality: +quality.toFixed(3), cost: +stage.R.cost.toFixed(2), every, period: +period.toFixed(2), dt: slow, open, lit, light: +lightT.toFixed(3), rev: +revT.toFixed(3), arm: arm[0], audio: audio.ctx ? audio.ctx.state : null }),
    stage,
  };
  if (manual) tick(last + 16); else requestAnimationFrame(tick);
  if (soundWanted && !mobile && !manual) setTimeout(() => audio.prime(), 900);
}

const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
const stage = reduce || qs.has('still') ? null : createStage($('#gl'), base, { shadowSize: matchMedia('(pointer: coarse)').matches ? 1024 : 2048 });
if (stage) live(stage); else still();
