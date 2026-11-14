import { createScreens } from './screens.js';
import { createAudio } from './audio.js';
import { wireSound } from './sound.js';

const root = document.documentElement;
const base = new URL('.', import.meta.url).href;
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const lerp = (a, b, t) => a + (b - a) * t;
const smooth = t => { t = clamp(t); return t * t * (3 - 2 * t); };

const OUT = { ph: 'out', out: 'idle', picked: false };
const STOPS = [
  ['hero', 'wide', 'np'],
  ['ear', 'pair', 'sign', OUT],
  ['chime', 'pair', 'sign', { ...OUT, out: 'toast' }],
  ['qr', 'pair', 'sign', { ...OUT, out: 'toast' }],
  ['away', 'pair', 'sign', { ...OUT, out: 'toast' }],
  ['send', 'pair', 'home', { ...OUT, out: 'sheet' }],
  ['hand', 'pair', 'live', { ...OUT, out: 'tv', picked: true }],
  ['wrist', 'pair', 'live', null, 1],
  ['link', 'pair', 'live', { ...OUT, out: 'tv', picked: true }],
  ['art', 'tv', 'np'],
  ['tape', 'tv', 'np'],
  ['scrub', 'tv', 'upnext'],
  ['ambient', 'tv', 'amb'],
  ['mix', 'tv', 'mixup'],
  ['blend', 'tv', 'mixblend'],
  ['decks', 'tv', 'decks'],
  ['style', 'tv', 'decks'],
  ['cue', 'tv', 'trackmap'],
  ['jump', 'tv', 'cues'],
  ['fix', 'tv', 'trackmap'],
  ['where', 'tv', 'trackmap'],
  ['lrclib', 'tv', 'lyrics'],
  ['full', 'tv', 'lyrics'],
  ['sets', 'wide', 'lyrics'],
].map(([id, cam, tv, phone = null, watch = 0]) => ({ id, cam, tv, phone, watch }));

const CAM = {
  wide: { tw: 0.62, cx: 0.43, cy: 0.44, d: 1 },
  pair: { tw: 0.58, cx: 0.36, cy: 0.38, d: 0.55 },
  tv: { tw: 0.95, cx: 0.5, cy: 0.46, d: 0 },
};
const CAM_M = {
  wide: { tw: 0.8, cx: 0.5, cy: 0.42, d: 1 },
  pair: { tw: 0.6, cx: 0.33, cy: 0.38, d: 0 },
  tv: { tw: 0.94, cx: 0.5, cy: 0.47, d: 0 },
};
const CANVAS = { sign: { tv: 'sign' }, home: { tv: 'home' }, live: { tv: 'play', tvb: 'np' }, amb: { tv: 'play', tvb: 'amb' } };
const GLOW = { np: [18, 66, 150], upnext: [20, 66, 150], mixup: [150, 110, 95], mixblend: [150, 111, 100], decks: [54, 84, 150], trackmap: [150, 121, 105], cues: [21, 67, 150], sign: [120, 52, 20], home: [96, 70, 52], live: [70, 84, 64], amb: [110, 70, 60], lyrics: [40, 70, 200] };
const FADE = 160;

const still = !root.classList.contains('room');
const coarse = matchMedia('(pointer: coarse)').matches;
const audio = createAudio(base);
wireSound(audio);

if (!still) roomPage();

function roomPage() {
  const panes = createScreens({ base, opaque: true, budget: coarse ? 1 : 0, only: ['tv', 'phone', 'watch'] });
  if (coarse) { panes.resize('tv', 960); panes.resize('phone', 480); panes.resize('watch', 320); }
  panes.time(4);
  const stage = $('.stage'), set = $('.set', stage);
  const phone = $('.hand.phone', stage), watch = $('.hand.watch', stage);
  const decor = $$('.print, .lamp', set);
  const layers = Object.fromEntries($$('.layer', set).map(el => [el.dataset.screen, el]));
  layers.canvas.append(panes.canvas('tv'));
  $('.slot', phone).append(panes.canvas('phone'));
  $('.slot', watch).append(panes.canvas('watch'));
  panes.set('watch', { w: 'remote' });
  panes.set('phone', OUT);
  panes.show('phone', false);
  panes.show('watch', false);
  panes.show('tv', false);
  const beats = $$('[data-stop]').map(el => ({ el, stop: STOPS.findIndex(s => s.id === el.dataset.stop), y: 0 }));
  if (beats.some(b => b.stop < 0) || beats.length !== STOPS.length) console.warn('tv: stops and beats differ');
  const layerOf = s => CANVAS[s] ? 'canvas' : s;

  const mobileQ = matchMedia('(max-width: 860px), (max-aspect-ratio: 1/1)');
  let mobile = false, vw = 1, vh = 1, head = 64, line = 400, art = { x: 0, y: 0, w: 1, h: 1 };
  let p = 0, pe = 0, raf = 0, last = performance.now(), settleAt = 0, phoneKey = '', active = -1, xf = -1;
  let shown = '', from = '', swapAt = -1e9;

  function measure() {
    mobile = mobileQ.matches;
    vw = innerWidth; vh = innerHeight;
    head = $('.top').offsetHeight;
    const sr = stage.getBoundingClientRect();
    if (mobile) {
      art = { x: 0, y: 0, w: sr.width, h: sr.height };
      line = head + sr.height + (vh - head - sr.height) * 0.3;
    } else {
      const copy = $('.copy').getBoundingClientRect();
      const gap = clamp(vw * 0.035, 24, 64);
      const x = copy.right + gap;
      art = { x, y: head + 8, w: vw - x - clamp(vw * 0.03, 16, 56), h: vh - head - 28 };
      line = vh * 0.5;
    }
    root.style.setProperty('--line', `${line}px`);
    for (const b of beats) { const r = b.el.getBoundingClientRect(); b.y = r.top + scrollY + r.height / 2; }
    beats.sort((a, b) => a.stop - b.stop);
    read();
    pe = p;
    draw(performance.now());
  }

  function read() {
    const L = scrollY + line;
    if (L <= beats[0].y) { p = 0; return; }
    for (let i = 0; i < beats.length - 1; i++) {
      const a = beats[i].y, b = beats[i + 1].y;
      if (L < b) { p = i + (L - a) / (b - a); return; }
    }
    p = beats.length - 1;
  }

  function camAt(i) {
    const s = STOPS[i];
    if (!mobile) return CAM[s.cam];
    const c = CAM_M[s.cam];
    if (s.cam !== 'tv') return c;
    const tw = Math.min(c.tw, (art.h - 24) / 0.62 / art.w);
    return { ...c, tw };
  }

  function screen(now) {
    const n = STOPS.length;
    const cur = STOPS[clamp(Math.round(pe), 0, n - 1)].tv;
    if (cur !== shown) {
      const before = shown;
      if (!before || layerOf(before) === layerOf(cur)) swapAt = before ? swapAt : -1e9;
      else { from = before; swapAt = now; }
      shown = cur;
      if (CANVAS[cur]) panes.set('tv', CANVAS[cur]);
    }
    const f = clamp((now - swapAt) / FADE);
    const top = layerOf(shown), under = f < 1 && from ? layerOf(from) : '';
    for (const [name, el] of Object.entries(layers)) {
      const o = name === top ? f < 1 && under ? f : 1 : name === under ? 1 : 0;
      el.style.opacity = o;
      el.style.zIndex = name === top ? 2 : name === under ? 1 : 0;
    }
    panes.show('tv', top === 'canvas' || under === 'canvas');
    const gb = GLOW[shown] || GLOW.lyrics, ga = under ? GLOW[from] || gb : gb, k = under ? smooth(f) : 1;
    root.style.setProperty('--glow', `rgb(${ga.map((c, q) => Math.round(lerp(c, gb[q], k))).join(' ')})`);
    return f < 1;
  }

  function draw(now) {
    const n = STOPS.length;
    const i = Math.min(n - 1, Math.floor(pe)), j = Math.min(n - 1, i + 1), t = pe - i;
    const A = STOPS[i], B = STOPS[j];
    const ca = camAt(i), cb = camAt(j), k = smooth((t - 0.22) / 0.56);
    const tw = lerp(ca.tw, cb.tw, k), cx = lerp(ca.cx, cb.cx, k), cy = lerp(ca.cy, cb.cy, k), d = lerp(ca.d, cb.d, k);
    const scale = tw * art.w / 1024;
    const X = art.x + cx * art.w, Y = art.y + cy * art.h;
    set.style.transform = `translate3d(${X.toFixed(2)}px, ${Y.toFixed(2)}px, 0) scale(${scale.toFixed(5)})`;
    decor.forEach(el => { el.style.opacity = d.toFixed(3); });
    const fading = screen(now);

    const swap = (a, b) => a === b ? a : a > b ? lerp(a, b, smooth((t - 0.1) / 0.35)) : lerp(a, b, smooth((t - 0.55) / 0.35));
    const pv = swap(A.phone ? 1 : 0, B.phone ? 1 : 0), wv = swap(A.watch, B.watch);
    const ps = STOPS[Math.round(pe)].phone || A.phone || B.phone;
    if (ps) { const key = JSON.stringify(ps); if (key !== phoneKey) { phoneKey = key; panes.set('phone', ps); } }
    const ph = mobile ? art.h * 0.78 : Math.min(art.h * 0.62, 580);
    const pw = ph * 0.48;
    phone.style.width = `${pw}px`;
    const edge = clamp(art.w * 0.04, 14, 28);
    const px = mobile ? art.x + art.w - pw - edge : Math.min(art.x + art.w * 0.86 - pw / 2, art.x + art.w - pw - edge), py = art.y + art.h * (mobile ? 0.52 : 0.62) - ph / 2;
    phone.style.transform = `translate3d(${px.toFixed(1)}px, ${(py + (1 - pv) * (art.h * 0.9 + 60)).toFixed(1)}px, 0) rotate(${lerp(9, mobile ? -3 : -5, pv).toFixed(2)}deg)`;
    phone.style.opacity = pv > 0.001 ? 1 : 0;
    panes.show('phone', pv > 0.001);
    const wh = ph * 0.4;
    const ww = wh * 0.837;
    watch.style.width = `${ww}px`;
    const wx = px + pw / 2 - ww / 2 - ww * 0.06, wy = art.y + art.h * (mobile ? 0.5 : 0.56) - wh / 2;
    watch.style.transform = `translate3d(${wx.toFixed(1)}px, ${(wy + (1 - wv) * (art.h * 0.8 + 60)).toFixed(1)}px, 0) rotate(${lerp(-10, 4, wv).toFixed(2)}deg)`;
    watch.style.opacity = wv > 0.001 ? 1 : 0;
    panes.show('watch', wv > 0.001);

    const on = Math.round(p);
    if (on !== active) {
      active = on;
      beats.forEach((b, q) => b.el.classList.toggle('on', q === on && b.el.classList.contains('cap')));
    }
    const mi = STOPS.findIndex(s => s.id === 'mix'), di = STOPS.findIndex(s => s.id === 'decks');
    const x = clamp((pe - mi) / (di - mi));
    if (Math.abs(x - xf) > 0.002) { xf = x; audio.set({ xf: x }); }
    return fading;
  }

  function frame(now) {
    raf = 0;
    const dt = clamp((now - last) / 1000, 0, 0.1);
    last = now;
    const gap = p - pe;
    pe = Math.abs(gap) < 0.0006 ? p : pe + gap * (1 - Math.exp(-dt * 11));
    const fading = draw(now);
    const painted = panes.step(dt);
    const moving = pe !== p;
    if (moving) settleAt = now;
    stage.classList.toggle('moving', now - settleAt < 250);
    if (moving || fading || painted.length || shown === 'sign' || now - settleAt < 300) kick();
  }
  const kick = () => { if (!raf) { last = performance.now(); raf = requestAnimationFrame(frame); } };

  let restT = 0, touching = false, focusAt = -1e9;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  function rest() {
    if (touching || reduce.matches || performance.now() - focusAt < 1200) return;
    const L = scrollY + line;
    let best = null;
    beats.forEach((b, q) => {
      const prev = q > 0 ? b.y - beats[q - 1].y : Infinity, next = q < beats.length - 1 ? beats[q + 1].y - b.y : Infinity;
      const reach = Math.min(40, 0.12 * Math.min(prev, next)), off = b.y - L;
      if (Math.abs(off) > 1 && Math.abs(off) <= reach && (best === null || Math.abs(off) < Math.abs(best))) best = off;
    });
    if (best !== null) scrollTo({ top: scrollY + best, behavior: 'smooth' });
  }
  addEventListener('touchstart', () => { touching = true; }, { passive: true });
  addEventListener('touchend', () => { touching = false; clearTimeout(restT); restT = setTimeout(rest, 220); }, { passive: true });
  addEventListener('focusin', () => { focusAt = performance.now(); });
  addEventListener('scroll', () => { read(); kick(); clearTimeout(restT); restT = setTimeout(rest, 220); }, { passive: true });
  let rt = 0;
  addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(measure, 80); });
  mobileQ.addEventListener('change', measure);
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(measure);
  measure();
  root.classList.add('ready');
  panes.ready.then(kick);
  kick();
  reduce.addEventListener('change', e => { if (e.matches) location.replace(location.pathname + '?still' + location.hash); });
  window.__tv = { state: () => ({ p: +p.toFixed(3), pe: +pe.toFixed(3), stop: STOPS[Math.round(p)].id, shown, mobile, art, line }), beats: () => beats.map(b => ({ id: STOPS[b.stop].id, y: b.y })) };
}
