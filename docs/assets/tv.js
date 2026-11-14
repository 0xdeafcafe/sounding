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
  ['hero', 'wide', 'np', null, 0, 1],
  ['ear', 'pair', 'sign', OUT],
  ['chime', 'pair', 'sign', { ...OUT, out: 'toast' }, 0, 1],
  ['qr', 'pair', 'sign', { ...OUT, out: 'toast' }],
  ['away', 'pair', 'sign', { ...OUT, out: 'toast' }],
  ['send', 'pair', 'np', { ...OUT, out: 'sheet' }],
  ['hand', 'pair', 'np', { ...OUT, out: 'tv', picked: true }, 0, 1],
  ['wrist', 'pair', 'np', null, 1],
  ['link', 'pair', 'np', { ...OUT, out: 'tv', picked: true }],
  ['art', 'tv', 'np', null, 0, 1],
  ['tape', 'tv', 'np'],
  ['scrub', 'tv', 'upnext'],
  ['ambient', 'tv', 'amb'],
  ['mix', 'tv', 'mixup', null, 0, 1],
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
].map(([id, cam, tv, phone = null, watch = 0, rest = 0]) => ({ id, cam, tv, phone, watch, rest: !!rest }));

const CAM = {
  wide: { tw: 0.7, cx: 0.47, cy: 0.4, d: 1 },
  pair: { tw: 0.6, cx: 0.4, cy: 0.4, d: 0.55 },
  tv: { tw: 0.95, cx: 0.5, cy: 0.46, d: 0 },
};
const CAM_M = {
  wide: { tw: 0.8, cx: 0.5, cy: 0.42, d: 1 },
  pair: { tw: 0.66, cx: 0.36, cy: 0.4, d: 0 },
  tv: { tw: 1, cx: 0.5, cy: 0.5, d: 0 },
};
const FOCUS = { np: [1.7, 0.27, 0.3], upnext: [1.7, 0.74, 0.32], amb: [1.15, 0.5, 0.5], mixup: [1.6, 0.33, 0.52], mixblend: [1.45, 0.5, 0.5], decks: [1.45, 0.5, 0.45], trackmap: [1.6, 0.4, 0.32], cues: [1.7, 0.7, 0.38], lyrics: [1.5, 0.36, 0.5], sign: [1, 0.5, 0.5] };
const CANVAS = { sign: { tv: 'sign' }, amb: { tv: 'play', tvb: 'amb' } };
const GLOW = { sign: [120, 52, 20], amb: [110, 70, 60] };

const still = !root.classList.contains('room');
const coarse = matchMedia('(pointer: coarse)').matches;
const panes = createScreens({ base, opaque: true, budget: coarse ? 1 : 0 });
if (coarse) { panes.resize('tv', 960); panes.resize('phone', 480); panes.resize('watch', 320); }
panes.time(4);

const audio = createAudio(base);
wireSound(audio);

if (still) stillPage(); else roomPage();

function stillPage() {
  const slot = $('.still-sign');
  if (!slot) return;
  slot.replaceWith(panes.canvas('tv'));
  panes.set('tv', CANVAS.sign);
  panes.ready.then(() => { for (let i = 0; i < 4; i++) panes.step(2); });
}

function roomPage() {
  const stage = $('.stage'), set = $('.set', stage);
  const phone = $('.hand.phone', stage), watch = $('.hand.watch', stage);
  const decor = $$('.print, .lamp', set);
  const layers = Object.fromEntries($$('.layer', set).map(el => [el.dataset.screen, el]));
  layers.canvas.append(panes.canvas('tv'));
  $('.slot', phone).append(panes.canvas('phone'));
  $('.slot', watch).append(panes.canvas('watch'));
  panes.set('watch', { w: 'remote' });
  panes.set('phone', OUT);
  const beats = $$('[data-stop]').map(el => ({ el, stop: STOPS.findIndex(s => s.id === el.dataset.stop), y: 0 }));
  if (beats.some(b => b.stop < 0) || beats.length !== STOPS.length) console.warn('tv: stops and beats differ');
  for (const b of beats) if (STOPS[b.stop].rest) { const r = document.createElement('i'); r.className = 'rest'; b.el.append(r); }
  const glow = {};
  for (const [name, el] of Object.entries(layers)) {
    if (el.tagName !== 'IMG') continue;
    const take = () => { glow[name] = average(el); };
    if (el.complete && el.naturalWidth) take(); else el.addEventListener('load', take, { once: true });
  }
  Object.assign(glow, GLOW);

  const mobileQ = matchMedia('(max-width: 860px), (max-aspect-ratio: 1/1)');
  let mobile = false, vw = 1, vh = 1, head = 64, line = 400, art = { x: 0, y: 0, w: 1, h: 1 };
  let p = 0, pe = 0, raf = 0, last = performance.now(), settleAt = 0, canvasMode = '', phoneKey = '', active = -1, xf = -1;

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
    draw();
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
    const f = FOCUS[s.tv] || [1, 0.5, 0.5];
    const z = lerp(f[0], 1, clamp((art.w - 420) / 320));
    const tvW = z * art.w, tvH = tvW * 0.5625;
    const cx = 0.5 - (f[1] - 0.5) * tvW / art.w, cy = 0.5 - (f[2] - 0.5) * tvH / art.h;
    const fitX = Math.max(0, (tvW - art.w) / 2 / art.w), fitY = Math.max(0, (tvH - art.h) / 2 / art.h);
    return { tw: z, cx: clamp(cx, 0.5 - fitX, 0.5 + fitX), cy: clamp(cy, 0.5 - fitY, 0.5 + fitY), d: 0 };
  }

  function draw() {
    const n = STOPS.length;
    const i = Math.min(n - 1, Math.floor(pe)), j = Math.min(n - 1, i + 1), t = pe - i;
    const A = STOPS[i], B = STOPS[j];
    const ca = camAt(i), cb = camAt(j), k = smooth((t - 0.22) / 0.56);
    const tw = lerp(ca.tw, cb.tw, k), cx = lerp(ca.cx, cb.cx, k), cy = lerp(ca.cy, cb.cy, k), d = lerp(ca.d, cb.d, k);
    const scale = tw * art.w / 1024;
    const X = art.x + cx * art.w, Y = art.y + cy * art.h;
    set.style.transform = `translate3d(${X.toFixed(2)}px, ${Y.toFixed(2)}px, 0) scale(${scale.toFixed(5)})`;
    decor.forEach(el => { el.style.opacity = d.toFixed(3); });

    const w = A.tv === B.tv ? 0 : smooth((t - 0.4) / 0.2);
    for (const [name, el] of Object.entries(layers)) {
      const key = name === 'canvas' ? null : name;
      const isA = key ? A.tv === key : !!CANVAS[A.tv], isB = key ? B.tv === key : !!CANVAS[B.tv];
      const o = isB && w > 0 ? (isA ? 1 : w) : isA ? 1 : 0;
      el.style.opacity = o;
      el.style.zIndex = isB && !isA ? 2 : isA ? 1 : 0;
    }
    const mode = CANVAS[B.tv] && w > 0 ? B.tv : CANVAS[A.tv] ? A.tv : CANVAS[B.tv] ? B.tv : '';
    if (mode && mode !== canvasMode) { canvasMode = mode; panes.set('tv', CANVAS[mode]); }
    panes.show('tv', !!mode);
    const ga = glow[A.tv] || [40, 70, 200], gb = glow[B.tv] || ga;
    root.style.setProperty('--glow', `rgb(${ga.map((c, q) => Math.round(lerp(c, gb[q], w))).join(' ')})`);

    const pk = smooth((t - 0.3) / 0.4);
    const pv = lerp(A.phone ? 1 : 0, B.phone ? 1 : 0, pk), wv = lerp(A.watch, B.watch, pk);
    const ps = STOPS[Math.round(pe)].phone || A.phone || B.phone;
    if (ps) { const key = JSON.stringify(ps); if (key !== phoneKey) { phoneKey = key; panes.set('phone', ps); } }
    const ph = mobile ? art.h * 0.84 : Math.min(art.h * 0.64, 600);
    const pw = ph * 300 / 652.4;
    phone.style.width = `${pw}px`;
    const px = art.x + art.w * (mobile ? 0.8 : 0.83) - pw / 2, py = art.y + art.h * (mobile ? 0.5 : 0.58) - ph / 2;
    phone.style.transform = `translate3d(${px.toFixed(1)}px, ${(py + (1 - pv) * (art.h * 0.9 + 60)).toFixed(1)}px, 0) rotate(${lerp(9, mobile ? -3 : -5, pv).toFixed(2)}deg)`;
    phone.style.opacity = pv > 0.001 ? 1 : 0;
    panes.show('phone', pv > 0.001);
    const wh = mobile ? art.h * 0.6 : Math.min(art.h * 0.36, 300);
    const ww = wh * 160 / 195.9;
    watch.style.width = `${ww}px`;
    const wx = art.x + art.w * (mobile ? 0.78 : 0.82) - ww / 2, wy = art.y + art.h * (mobile ? 0.48 : 0.56) - wh / 2;
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
  }

  function frame(now) {
    raf = 0;
    const dt = clamp((now - last) / 1000, 0, 0.1);
    last = now;
    const gap = p - pe;
    pe = Math.abs(gap) < 0.0006 ? p : pe + gap * (1 - Math.exp(-dt * 11));
    draw();
    const painted = panes.step(dt);
    const moving = pe !== p;
    if (moving) settleAt = now;
    stage.classList.toggle('moving', now - settleAt < 250);
    if (moving || painted.length || canvasMode === 'sign' && layers.canvas.style.opacity > 0 || now - settleAt < 300) kick();
  }
  const kick = () => { if (!raf) { last = performance.now(); raf = requestAnimationFrame(frame); } };

  addEventListener('scroll', () => { read(); kick(); }, { passive: true });
  let rt = 0;
  addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(measure, 80); });
  mobileQ.addEventListener('change', measure);
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(measure);
  measure();
  root.classList.add('ready', 'snap');
  panes.ready.then(kick);
  kick();
  matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', e => { if (e.matches) location.replace(location.pathname + '?still' + location.hash); });
  window.__tv = { state: () => ({ p: +p.toFixed(3), pe: +pe.toFixed(3), stop: STOPS[Math.round(p)].id, mobile, art, line }) };
}

function average(img) {
  try {
    const c = document.createElement('canvas');
    c.width = 24; c.height = 14;
    const x = c.getContext('2d', { willReadFrequently: true });
    x.drawImage(img, 0, 0, 24, 14);
    const d = x.getImageData(0, 0, 24, 14).data;
    let r = 0, g = 0, b = 0, n = 0;
    for (let i = 0; i < d.length; i += 4) {
      const mx = Math.max(d[i], d[i + 1], d[i + 2]), mn = Math.min(d[i], d[i + 1], d[i + 2]);
      const wgt = 0.2 + (mx - mn) / 255 * 2;
      r += d[i] * wgt; g += d[i + 1] * wgt; b += d[i + 2] * wgt; n += wgt;
    }
    const c0 = [r / n, g / n, b / n], top = Math.max(...c0) || 1;
    const k = 150 / top;
    return c0.map(v => Math.min(255, v * k));
  } catch (e) { return [60, 60, 80]; }
}
