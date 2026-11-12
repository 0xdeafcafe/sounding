import { MIX } from './data.js';

export const SCREENS = { phone: { w: 300, h: 652.4 }, friend: { w: 300, h: 652.4 }, tv: { w: 800, h: 442.9 }, watch: { w: 160, h: 195.9 }, pad: { w: 820, h: 590 }, mac: { w: 960, h: 600 } };
const PX = { phone: 600, friend: 600, tv: 1600, watch: 512, pad: 1640, mac: 1920 };
const CORNER = { phone: 40, friend: 40, tv: 2.4, watch: 37, pad: 22, mac: 10 };
const FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", "Helvetica Neue", Helvetica, Arial, sans-serif';
const TINT = '#ff6b1a', TINT_T = '#ff8a45', ON_TINT = '#1a0a00';
let F = 3;
const TAU = Math.PI * 2;
const T = MIX.tracks, D = MIX.duration;
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const fmt = s => { s = Math.max(0, Math.round(s)); const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60; return h ? `${h}:${String(m).padStart(2, '0')}:${String(x).padStart(2, '0')}` : `${m}:${String(x).padStart(2, '0')}`; };

// MARK: Content
const PARIAH = 'music/essy-wildeburg.webp', BACKDROP = 'music/essy-backdrop.webp', TRANS = 'music/paul-renard-transmissions.webp', ICON = 'app-icon.webp';
const small = f => `music/s/${f}.webp`;
const LIKES = [
  ['pegassi-jump-4-joy', 'Jump 4 Joy', 'Pegassi'],
  ['hearthug-computerized-souls', 'HearThuG - Computerized Souls (Sex Tapes From Mars) (STFM004)', 'HearThuG'],
  ['kyle-starkey-boom-boom-jam', 'Boom Boom Jam', 'Kyle Starkey'],
  ['benwal-just-go', 'Benwal - Just Go *FREE DOWNLOAD*', 'Benwal'],
  ['pegassi-227kg', '227Kg', 'Pegassi'],
  ['hearthug-buzz-look-an-alien', 'Premiere: B1 - HearThuG - Buzz! Look An Alien (Oh no-no Mix) [SEXTAPE004]', 'trommel'],
  ['kyle-starkey-tryton', 'Kyle Starkey - Tryton [Agrio Tracks]', 'Kyle Starkey'],
  ['pegassi-style', 'Style', 'Pegassi'],
  ['benwal-wildeburg', 'Benwal - Wildeburg 2024', 'Wildeburg'],
  ['paul-renard-transmissions', 'Paul Renard - Transmissions', 'Zodiak Commune Records'],
  ['hearthug-alien', 'HearThuG - Alien, All Too Alien', 'HearThuG'],
  ['pegassi-forest-walk', 'Forest Walk', 'Pegassi'],
  ['kyle-starkey-the-way-it-is', 'The Way It Is (ft. Lisa Moorish)', 'Kyle Starkey'],
  ['benwal-final-dance', 'Final Dance', 'Benwal'],
  ['hearthug-3310', 'HearThuG - Fight Like A 3310 (Are You Alien)', 'HearThuG'],
  ['pegassi-twinflame', 'Twinflame', 'Pegassi'],
  ['essy-wildeburg', MIX.title, 'Wildeburg'],
  ['kyle-starkey-love-euphoria', 'Love Euphoria (I Feel Good)', 'Kyle Starkey'],
  ['benwal-dive', 'Benwal - Dive', 'Benwal'],
  ['pegassi-strangers', 'Strangers (Pegassi Remix)', 'Pegassi'],
  ['hearthug-lost-in-tokyo', 'HearThuG - I’m Lost In Tokyo ( 侍 Mix)', 'Are You Alien'],
  ['kyle-starkey-wildeburg', 'Entasia & Kyle Starkey - Wildeburg 2025', 'Wildeburg'],
  ['benwal-dgtl-ade', 'BENWAL | FULL SET | DGTL ADE 2025 | 23.10.25', 'DGTL'],
  ['obskur-luuk-van-dijk', 'Obskür B2B Luuk van Dijk | Audio Obscura at the Van Nelle Fabriek', 'Audio Obscura'],
  ['andre-zimmer-invisible-sandwich', 'Andre Zimmer - Invisible Sandwich', 'Big Trouble Records'],
  ['summer-junkies-hey-yall', 'Summer Junkies - Hey Y’All (Ashley D’s Piano Rave House Reboot)', 'Ashley D'],
  ['jungle-by-night-oog-om-oog', 'Oog om Oog (feat. Spinvis) (D Stone Remix)', 'Jungle By Night'],
  ['angel-dlite-club-smut', 'Angel D’lite live from Club Smut - Pleasure Palace 12.07.25', 'angel d’lite'],
  ['kyle-starkey-milion', 'Kyle Starkey b2b Milion at Intercell × Glitch Festival 2026', 'Intercell'],
  ['mees-visser', 'Mees Visser - I Just Can’t Get Enough', 'Mees Visser'],
  ['young-marco-dekmantel', 'Young Marco at Dekmantel Radar 2024', 'Sakke'],
  ['benwal-dgtl', 'BENWAL | FULL CLOSING SET | DGTL AMSTERDAM 2026 | 5.4.26', 'DGTL'],
  ['pegassi-essential-mix', 'BBC Radio 1’s Essential Mix Pegassi', 'Pegassi'],
];
const at = n => LIKES.findIndex(l => l[0] === n);
const RECENT = ['benwal-dgtl', 'essy-wildeburg', 'benwal-wildeburg', 'kyle-starkey-wildeburg', 'pegassi-essential-mix', 'hearthug-lost-in-tokyo'].map(at);
const LIKED = ['pegassi-jump-4-joy', 'hearthug-computerized-souls', 'kyle-starkey-boom-boom-jam', 'benwal-just-go', 'pegassi-227kg', 'hearthug-buzz-look-an-alien'].map(at);
const NEXT = ['pegassi-style', 'kyle-starkey-tryton', 'pegassi-227kg', 'hearthug-buzz-look-an-alien'].map(at);
const FILES = [PARIAH, BACKDROP, TRANS, ICON, ...LIKES.map(l => small(l[0]))];

// MARK: Shapes
const C = (x, y, r) => `M${x - r} ${y}a${r} ${r} 0 1 0 ${2 * r} 0a${r} ${r} 0 1 0 ${-2 * r} 0z`;
const R = (x, y, w, h, r) => `M${x + r} ${y}h${w - 2 * r}a${r} ${r} 0 0 1 ${r} ${r}v${h - 2 * r}a${r} ${r} 0 0 1 ${-r} ${r}h${2 * r - w}a${r} ${r} 0 0 1 ${-r} ${-r}v${2 * r - h}a${r} ${r} 0 0 1 ${r} ${-r}z`;
const ICON_SRC = {
  play: [['f', 'M7 4.7v14.6c0 .8.9 1.3 1.6.9l11.6-7.3c.6-.4.6-1.4 0-1.8L8.6 3.8C7.9 3.4 7 3.9 7 4.7z']],
  pause: [['f', R(5.5, 4, 4.4, 16, 1.2) + R(14.1, 4, 4.4, 16, 1.2)]],
  rw: [['f', 'M11.6 6.3v11.4c0 .7-.8 1.1-1.3.7l-7.6-5.7a.9.9 0 0 1 0-1.4l7.6-5.7c.5-.4 1.3 0 1.3.7zm10 0v11.4c0 .7-.8 1.1-1.3.7l-7.6-5.7a.9.9 0 0 1 0-1.4l7.6-5.7c.5-.4 1.3 0 1.3.7z']],
  ff: [['f', 'M12.4 6.3v11.4c0 .7.8 1.1 1.3.7l7.6-5.7a.9.9 0 0 0 0-1.4l-7.6-5.7c-.5-.4-1.3 0-1.3.7zm-10 0v11.4c0 .7.8 1.1 1.3.7l7.6-5.7a.9.9 0 0 0 0-1.4L3.7 5.6c-.5-.4-1.3 0-1.3.7z']],
  heart: [['s', 'M12 20s-7.6-4.6-7.6-10.3A4.3 4.3 0 0 1 12 7.1a4.3 4.3 0 0 1 7.6 2.6C19.6 15.4 12 20 12 20z']],
  more: [['f', C(5.5, 12, 1.9) + C(12, 12, 1.9) + C(18.5, 12, 1.9)]],
  comment: [['s', 'M6 4.5h12A2.5 2.5 0 0 1 20.5 7v7.5A2.5 2.5 0 0 1 18 17h-6.5L7 20.5V17H6a2.5 2.5 0 0 1-2.5-2.5V7A2.5 2.5 0 0 1 6 4.5z']],
  list: [['s', 'M9.5 6.5h11M9.5 12h11M9.5 17.5h11'], ['f', C(4.6, 6.5, 1.4) + C(4.6, 12, 1.4) + C(4.6, 17.5, 1.4)]],
  queue: [['s', 'M2.5 6h11M2.5 10.5h11M2.5 15h6.5M19.6 16V4.4l2.6 1'], ['f', C(16.9, 16.4, 2.8)]],
  airplay: [['s', 'M6.6 17.2a8 8 0 1 1 10.8 0M9.3 14.5a4.2 4.2 0 1 1 5.4 0'], ['f', 'M12 13.6l4.6 6.4H7.4z']],
  home: [['s', 'M4 10.4 12 4l8 6.4V19a1 1 0 0 1-1 1h-4.5v-5.5h-5V20H5a1 1 0 0 1-1-1z']],
  search: [['s', C(10.5, 10.5, 6.2) + 'M15.2 15.2 20 20']],
  decks: [['s', 'M4 7h9M18 7h2M4 12h3M12 12h8M4 17h11' + C(15.5, 7, 2.3) + C(9.5, 12, 2.3) + C(17.5, 17, 2.3)]],
  hw: [['s', R(6, 2.8, 12, 18.4, 2.4) + C(12, 14.2, 3.4) + C(12, 7.4, 1.1)]],
  lock: [['s', R(5.5, 10.5, 13, 10, 2) + 'M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5']],
  mic: [['s', C(15, 9, 4.5) + 'M12 12.4 4.6 19.4l1 1 7.2-7.2']],
  sets: [['s', 'M4.5 12A7.5 7.5 0 1 0 6.7 6.7M4.5 4v4h4M12 8v4.2l2.8 1.8']],
  person: [['s', C(12, 12, 8.6) + C(12, 10, 3) + 'M6.6 18.4a6.2 6.2 0 0 1 10.8 0']],
  people: [['s', C(9, 8.5, 3.2) + 'M3 19a6 6 0 0 1 12 0M15.5 5.6a3 3 0 0 1 0 5.8M17.5 13.6A6 6 0 0 1 21 19']],
  sidebar: [['s', R(3, 4.5, 18, 15, 3) + 'M9.5 4.5v15M5.6 8.5h1.4M5.6 11.5h1.4']],
  bell: [['s', 'M6.2 16.5v-5.3a5.8 5.8 0 0 1 11.6 0v5.3l1.6 2H4.6zM10 21h4']],
  grab: [['s', 'M4 8.5h16M4 12h16M4 15.5h16', 1.3]],
  shuffle: [['s', 'M3 7h3c4.5 0 6.5 10 11 10h3.5M3 17h3c1.6 0 2.7-1.2 3.7-2.9M13.6 9.6C14.5 8 15.6 7 17 7h3.5M18 4.5 20.5 7 18 9.5M18 14.5l2.5 2.5-2.5 2.5']],
  repeat: [['s', 'M4 11.5v-2A2.5 2.5 0 0 1 6.5 7h13.5M17.5 4.5 20 7l-2.5 2.5M20 12.5v2a2.5 2.5 0 0 1-2.5 2.5H4M6.5 19.5 4 17l2.5-2.5']],
  identify: [['s', 'M4.5 10v4M8.2 7v10M12 4.5v15M15.8 8v8M19.5 10.5v3']],
  vol0: [['f', 'M5 9.2h3.2L13 5v14l-4.8-4.2H5z']],
  vol: [['f', 'M2.5 9.2h3.2L10.5 5v14l-4.8-4.2H2.5z'], ['s', 'M14 9.2a4 4 0 0 1 0 5.6M16.8 6.6a7.6 7.6 0 0 1 0 10.8M19.6 4a11.4 11.4 0 0 1 0 16']],
  tv: [['s', R(2.5, 4, 19, 13, 1.8) + 'M8 20.5h8']],
  phone: [['s', R(6.8, 2.5, 10.4, 19, 2.4) + 'M10.6 18.6h2.8']],
  shareplay: [['s', C(9, 9, 3) + 'M3.2 19.5a5.8 5.8 0 0 1 11.6 0M16 6.6a4 4 0 0 1 0 5.8M18.7 4a7.6 7.6 0 0 1 0 11']],
  check: [['s', 'M5 12.6l4.4 4.4L19 7.4', 2.6]],
  back: [['s', 'M14.5 5 7.5 12l7 7', 2.4]],
  chev: [['s', 'M9.5 5l7 7-7 7', 2.6]],
  gear: [['g', C(12, 12, 8)], ['s', C(12, 12, 5.6) + C(12, 12, 2.2)]],
};
const WF_A = [83,101,107,124,136,128,242,287,239,227,263,227,247,231,248,228,270,297,282,301,296,249,288,266,236,211,252,226,242,257,257,282,260,297,279,315,309,248,242,237,127,112,117,108,114,111,110,345,345,372,353,374,368,379,353,310,368,377,372,344,356,314,366,344,320,302,368,379,304,363,331,309,321,361,369,300,348,300,356,324,273,279,250,280,237,223,255,220,231,244,256,228,221,243,185,184,149,104,78,54];
const WF_B = [102,104,126,115,137,138,134,157,146,169,191,192,210,231,194,199,220,237,218,208,239,190,233,202,195,193,203,230,197,218,103,97,101,89,89,92,342,322,312,334,324,311,351,344,307,334,330,358,346,310,366,297,321,348,299,327,290,341,349,333,358,312,343,335,334,324,355,364,325,341,292,344,339,367,354,304,304,316,260,284,255,244,232,269,221,220,220,237,187,198,194,200,188,181,148,145,135,144,136,104];
const WAVE_D = 'M-10 14C30 4 62 24 104 15S170 2 214 13 300 27 338 14 392 6 410 12';
const WAVE_OFF = [[0, 0], [0, 7], [-14, 14], [-6, 22], [-20, 31], [-10, 40]];
const RINGS = [7, 12.5, 18, 23.5, 29, 34.5, 40, 45, 49.5];

let G = null;
function shapes() {
  if (G) return G;
  const icons = {};
  for (const k in ICON_SRC) icons[k] = ICON_SRC[k].map(([m, d, w]) => [m, new Path2D(d), w]);
  const mix = new Path2D();
  MIX.wave.forEach((v, i) => { const h = clamp(18 + ((v - 60) / 40) * 82, 14, 100); mix.rect(i * 2 + 0.3, (100 - h) / 2, 1.3, h); });
  const cue = hs => { const p = new Path2D(); hs.forEach((h, i) => { h /= 10; p.rect(i * 2, (40 - h) / 2, 1.24, h); }); return p; };
  const wave = new Path2D(), base = new Path2D(WAVE_D);
  WAVE_OFF.forEach(([x, y]) => wave.addPath(base, new DOMMatrix([1, 0, 0, 1, x, y])));
  const ticks = new Path2D();
  for (let x = 0; x < 48.7; x += 0.5) ticks.rect(x, 0, 0.2, 0.9);
  G = { icons, mix, wfa: cue(WF_A), wfb: cue(WF_B), wave, ticks };
  return G;
}

// MARK: Easing
function bezier(x1, y1, x2, y2) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx, cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const X = t => ((ax * t + bx) * t + cx) * t, Y = t => ((ay * t + by) * t + cy) * t;
  return x => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let lo = 0, hi = 1, t = x;
    for (let i = 0; i < 22; i++) { t = (lo + hi) / 2; if (X(t) < x) lo = t; else hi = t; }
    return Y(t);
  };
}
const ease = bezier(0.45, 0.05, 0.2, 1), easeIO = bezier(0.42, 0, 0.58, 1), easeOut = bezier(0, 0, 0.58, 1);

// MARK: Text
let M = null;
const widths = new Map(), fits = new Map(), wraps = new Map();
const font = (f, w) => `${w} ${+(f * F).toFixed(2)}px ${FONT}`;
function tw(s, f, w = 400) {
  const k = `${F}|${w}|${f}|${s}`;
  let v = widths.get(k);
  if (v === undefined) { M ||= document.createElement('canvas').getContext('2d'); M.font = font(f, w); v = M.measureText(s).width / F; widths.set(k, v); }
  return v;
}
function fit(s, f, w, max) {
  if (tw(s, f, w) <= max) return s;
  const k = `${F}|${w}|${f}|${max}|${s}`;
  let v = fits.get(k);
  if (v === undefined) {
    let lo = 0, hi = s.length;
    while (lo < hi) { const m = (lo + hi + 1) >> 1; if (tw(s.slice(0, m).trimEnd() + '…', f, w) <= max) lo = m; else hi = m - 1; }
    v = s.slice(0, lo).trimEnd() + '…';
    fits.set(k, v);
  }
  return v;
}
function wrap(s, f, w, max, n) {
  const k = `${F}|${w}|${f}|${max}|${n}|${s}`;
  let v = wraps.get(k);
  if (v) return v;
  const words = s.split(' ');
  v = [];
  let cur = '';
  for (let i = 0; i < words.length; i++) {
    const t = cur ? `${cur} ${words[i]}` : words[i];
    if (!cur || tw(t, f, w) <= max) { cur = t; continue; }
    v.push(cur);
    if (v.length === n - 1) { cur = words.slice(i).join(' '); break; }
    cur = words[i];
  }
  v.push(cur);
  v[v.length - 1] = fit(v[v.length - 1], f, w, max);
  wraps.set(k, v);
  return v;
}
function text(ctx, s, x, y, f, o = {}) {
  const w = o.w || 400, lh = o.lh || 1.25, sx = o.sx || 1;
  const str = o.max ? fit(s, f, w, o.max) : s;
  const base = o.base ?? y + f * (lh / 2 + 0.36);
  ctx.save();
  ctx.scale(sx / F, 1 / F);
  ctx.font = font(f, w);
  ctx.textAlign = o.align || 'left';
  ctx.textBaseline = 'alphabetic';
  if (o.fade) {
    const g = ctx.createLinearGradient((x + o.fade * 0.78) * F, 0, (x + o.fade) * F, 0);
    g.addColorStop(0, '#fff');
    g.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = g;
  } else ctx.fillStyle = o.c || '#fff';
  ctx.fillText(str, x * F / sx, base * F);
  ctx.restore();
  return str;
}

// MARK: Drawing
function rr(ctx, x, y, w, h, r) {
  const [a, b, c, d] = Array.isArray(r) ? r : [r, r, r, r];
  const m = Math.min(w, h) / 2;
  ctx.beginPath();
  ctx.moveTo(x + Math.min(a, m), y);
  ctx.arcTo(x + w, y, x + w, y + h, Math.min(b, m));
  ctx.arcTo(x + w, y + h, x, y + h, Math.min(c, m));
  ctx.arcTo(x, y + h, x, y, Math.min(d, m));
  ctx.arcTo(x, y, x + w, y, Math.min(a, m));
  ctx.closePath();
}
function box(ctx, x, y, w, h, r, fill) { rr(ctx, x, y, w, h, r); ctx.fillStyle = fill; ctx.fill(); }
function line(ctx, w, c) { ctx.lineWidth = w; ctx.strokeStyle = c; ctx.stroke(); }
function dot(ctx, x, y, r, fill) { ctx.beginPath(); ctx.arc(x, y, r, 0, TAU); ctx.fillStyle = fill; ctx.fill(); }
function icon(ctx, n, x, y, s, c, lw) {
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(s / 24, s / 24);
  ctx.fillStyle = ctx.strokeStyle = c;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  for (const [m, p, w] of G.icons[n]) {
    if (m === 'f') { ctx.fill(p); continue; }
    if (m === 'g') { ctx.lineWidth = 3; ctx.lineCap = 'butt'; ctx.setLineDash([2.3, 1.89]); ctx.stroke(p); ctx.setLineDash([]); ctx.lineCap = 'round'; continue; }
    ctx.lineWidth = lw || w || 1.8;
    ctx.stroke(p);
  }
  ctx.restore();
}
function cover(ctx, im, x, y, w, h) {
  const iw = im.naturalWidth || im.width, ih = im.naturalHeight || im.height, k = Math.max(w / iw, h / ih), sw = w / k, sh = h / k;
  ctx.drawImage(im, (iw - sw) / 2, (ih - sh) / 2, sw, sh, x, y, w, h);
}
function cssLinear(ctx, deg, x, y, w, h, stops) {
  const a = deg * Math.PI / 180, dx = Math.sin(a), dy = -Math.cos(a), len = Math.abs(w * dx) + Math.abs(h * dy), cx = x + w / 2, cy = y + h / 2;
  const g = ctx.createLinearGradient(cx - dx * len / 2, cy - dy * len / 2, cx + dx * len / 2, cy + dy * len / 2);
  for (const [o, c] of stops) g.addColorStop(o, c);
  return g;
}
function ellipse(ctx, W, H, px, py, rx, ry, rgb, a, stop) {
  ctx.save();
  ctx.translate(W * px, H * py);
  ctx.scale(W * rx, H * ry);
  const g = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);
  g.addColorStop(0, `rgba(${rgb},${a})`);
  g.addColorStop(stop, `rgba(${rgb},0)`);
  ctx.fillStyle = g;
  ctx.fillRect(-px / rx, -py / ry, 1 / rx, 1 / ry);
  ctx.restore();
}
function waves(ctx, sc, x, y, w, h, c) {
  const p = new Path2D();
  p.addPath(G.wave, new DOMMatrix([w / 400, 0, 0, h / 60, x, y]));
  ctx.lineWidth = 100 / sc.w;
  ctx.strokeStyle = c;
  ctx.stroke(p);
}
function rings(ctx, sc, x, y, s, c) {
  ctx.lineWidth = 100 / sc.w;
  ctx.strokeStyle = c;
  ctx.beginPath();
  for (const r of RINGS) { const k = r * s / 100; ctx.moveTo(x + s / 2 + k, y + s / 2); ctx.arc(x + s / 2, y + s / 2, k, 0, TAU); }
  ctx.stroke();
}
function shadow(ctx, sc, x, y, w, h, r, oy, blur, c) {
  ctx.save();
  ctx.shadowColor = c;
  ctx.shadowBlur = blur * sc.K;
  ctx.shadowOffsetX = 1000 * sc.K;
  ctx.shadowOffsetY = oy * sc.K;
  box(ctx, x - 1000, y, w, h, r, '#000');
  ctx.restore();
}
function mixWave(ctx, x, y, w, h, p) {
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(w / 320, h / 100);
  ctx.fillStyle = 'rgba(255,255,255,.3)';
  ctx.fill(G.mix);
  ctx.beginPath();
  ctx.rect(0, 0, 320 * p, 100);
  ctx.clip();
  ctx.fillStyle = '#fff';
  ctx.fill(G.mix);
  ctx.restore();
}
function cueWave(ctx, path, x, y, w, h, c) {
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(w / 200, h / 40);
  ctx.fillStyle = c;
  ctx.fill(path);
  ctx.restore();
}
function pills(ctx, x, y, labels, on, f, px, py, gap, centre) {
  const ws = labels.map(l => tw(l, f, 600) + 2 * px), h = f * 1.25 + 2 * py;
  if (centre !== undefined) x = centre - (ws.reduce((a, b) => a + b, 0) + gap * (labels.length - 1)) / 2;
  labels.forEach((l, i) => {
    const o = i === on;
    box(ctx, x, y, ws[i], h, h / 2, o ? '#fff' : 'rgba(255,255,255,.14)');
    if (!o) line(ctx, 0.25, 'rgba(255,255,255,.08)');
    text(ctx, l, x + ws[i] / 2, y + py, f, { w: 600, c: o ? '#111' : '#fff', align: 'center' });
    x += ws[i] + gap;
  });
}
function chip(ctx, x, y, h, ic, label, f, is, pl, pr, gap, c, centre) {
  const w = pl + is + gap + tw(label, f, 600) + pr;
  if (centre !== undefined) x = centre - w / 2;
  box(ctx, x, y, w, h, h / 2, 'rgba(255,255,255,.14)');
  line(ctx, h / 40, 'rgba(255,255,255,.08)');
  icon(ctx, ic, x + pl, y + (h - is) / 2, is, c);
  text(ctx, label, x + pl + is + gap, y + (h - f * 1.25) / 2, f, { w: 600, c });
}
function slider(ctx, x, y, w, ih, bh, f) {
  icon(ctx, 'vol0', x, y, ih, 'rgba(255,255,255,.62)');
  icon(ctx, 'vol', x + w - ih, y, ih, 'rgba(255,255,255,.62)');
  const bx = x + ih + f, bw = w - 2 * (ih + f), by = y + (ih - bh) / 2;
  box(ctx, bx, by, bw, bh, bh / 2, 'rgba(255,255,255,.22)');
  box(ctx, bx, by, bw * 0.6, bh, bh / 2, 'rgba(255,255,255,.88)');
  return [bx, bw, by];
}
function art(ctx, sc, file, x, y, w, h, r) {
  const im = sc.img(file);
  if (!im) { box(ctx, x, y, w, h, r, '#2a2622'); return; }
  ctx.save();
  rr(ctx, x, y, w, h, r);
  ctx.clip();
  cover(ctx, im, x, y, w, h);
  ctx.restore();
}
function npBg(ctx, sc, top, ring, dj) {
  const H = sc.H;
  ctx.fillStyle = cssLinear(ctx, 172, 0, 0, 100, H, dj ? [[0, '#3a3a3e'], [0.4, '#26262a'], [0.76, '#161618'], [1, '#0f0f10']] : [[0, '#3d4d5b'], [0.4, '#263440'], [0.76, '#141d25'], [1, '#0e151b']]);
  ctx.fillRect(0, 0, 100, H);
  const im = !dj && sc.img(BACKDROP);
  if (im) { ctx.globalAlpha = 0.16; cover(ctx, im, -10, -0.1 * H, 120, 1.2 * H); ctx.globalAlpha = 1; }
  waves(ctx, sc, -4, top[0], 108, top[1], 'rgba(255,255,255,.12)');
  rings(ctx, sc, ring[1], ring[2], ring[0], 'rgba(255,255,255,.09)');
}
function times(ctx, sc, x0, x1, y, f, c, w) {
  text(ctx, sc.S.el, x0, y, f, { c, w });
  text(ctx, sc.S.left, x1, y, f, { c, w, align: 'right' });
}

// MARK: iPhone
function phone(ctx, sc, friend) {
  const H = sc.H, lib = friend ? 0 : sc.v('lib'), pl = friend ? 0 : sc.v('play'), out = friend ? 1 : sc.v('out'), b = friend ? 0 : sc.v('b');
  ctx.fillStyle = '#0b0a09';
  ctx.fillRect(0, 0, 100, H);
  if (b < 1) {
    sc.view(ctx, lib, { s: 0.96 + 0.04 * lib, direct: true }, x => phLib(x, sc));
    sc.view(ctx, pl, { s: 1.04 - 0.04 * pl }, x => phPlay(x, sc));
    sc.view(ctx, out, null, x => phOut(x, sc, friend));
  }
  sc.view(ctx, b, { s: 1.03 - 0.03 * b, direct: true }, x => sc.layer(x, 'cues', y => phCues(y, sc)));
  const k = Math.round(255 * (1 - (friend ? 0 : sc.v('sbd')))), c = `rgb(${k},${k},${k})`;
  text(ctx, '21:47', 12.5, 4.8, 4.7, { w: 600, c });
  box(ctx, 82.9, 4.8 + (5.875 - 3.6) / 2, 7.6, 3.6, 1.2, c);
}
function phLib(ctx, sc) {
  sc.layer(ctx, 'lib', x => {
    const H = sc.H;
    x.fillStyle = '#fff';
    x.fillRect(0, 0, 100, H);
    dot(x, 10.75, 19.75, 5.75, '#f4f4f6');
    line(x, 0.3, 'rgba(0,0,0,.07)');
    icon(x, 'back', 7.95, 16.95, 5.6, '#000');
    text(x, 'Likes', 5.5, 28, 9.6, { w: 700, lh: 1.1, c: '#000' });
    text(x, `${LIKES.length} tracks`, 5.5, 39.6, 3.6, { c: '#8a8a8e' });
    LIKES.forEach(([f, t, s], i) => {
      const y = 46 + i * 17;
      if (y > H) return;
      if (i) { x.fillStyle = 'rgba(60,60,67,.14)'; x.fillRect(22.8, y, 77.2, 0.3); }
      art(x, sc, small(f), 5.5, y + 1.75, 13.5, 13.5, 1.8);
      text(x, t, 22.8, y + 3.3, 4.3, { c: '#000', max: 71.7 });
      text(x, s, 22.8, y + 9.075, 3.7, { c: '#8a8a8e', max: 71.7 });
    });
    const y = H - 24.5, cw = 21.7;
    shadow(x, sc, 5, y, 90, 18, 9, 1.5, 5, 'rgba(0,0,0,.14)');
    box(x, 5, y, 90, 18, 9, 'rgba(250,250,252,.95)');
    line(x, 0.3, 'rgba(0,0,0,.05)');
    [['home', 'Home'], ['queue', 'Library'], ['gear', 'Settings'], ['search', 'Search']].forEach(([ic, l], j) => {
      const on = j === 1, cx = 6.6 + cw * (j + 0.5), c = on ? TINT : '#1c1c1e';
      if (on) box(x, 6.6 + cw * j, y + 1.5, cw, 15, 7.5, '#e9e9ee');
      icon(x, ic, cx - 3.3, y + 3.05, 6.6, c);
      text(x, l, cx, y + 10.45, 3.6, { w: 600, c, align: 'center' });
    });
  });
  const p = sc.v('pick');
  if (p > 0) {
    ctx.save();
    ctx.globalCompositeOperation = 'darken';
    ctx.globalAlpha *= p;
    ctx.fillStyle = '#e6e6eb';
    ctx.fillRect(0, 46 + 7 * 17, 100, 17);
    ctx.restore();
  }
}
function transport(ctx, xs, y, s, sp) {
  icon(ctx, 'rw', xs[0], y + (sp - s) / 2, s, '#fff');
  icon(ctx, 'pause', xs[1], y, sp, '#fff');
  icon(ctx, 'ff', xs[2], y + (sp - s) / 2, s, '#fff');
}
function phPlay(ctx, sc) {
  const L = sc.v('L');
  if (L === 0 || L === 1) sc.layer(ctx, 'play' + L, x => phPlayStill(x, sc, L, true));
  else phPlayStill(ctx, sc, L, false);
  phPlayLive(ctx, sc, L);
}
function phPlayStill(ctx, sc, L, rest) {
  const o = clamp(1 - L * 1.7);
  if (rest) npBg(ctx, sc, [9, 18], [150, 6, 132]);
  else sc.layer(ctx, 'npbg', x => npBg(x, sc, [9, 18], [150, 6, 132]));
  if (o > 0) {
    ctx.globalAlpha = o;
    box(ctx, 44.5, 14, 11, 1.4, 0.7, 'rgba(255,255,255,.3)');
    if (rest) shadow(ctx, sc, 5.5, 20, 89, 89, 3.2, 3, 8, 'rgba(0,0,0,.35)');
    else sc.layer(ctx, 'artsh', x => shadow(x, sc, 5.5, 20, 89, 89, 3.2, 3, 8, 'rgba(0,0,0,.35)'));
    ctx.globalAlpha = 1;
  }
  ctx.save();
  ctx.translate(5.5, 20 - 6 * L);
  ctx.scale(1 - 0.81 * L, 1 - 0.81 * L);
  art(ctx, sc, PARIAH, 0, 0, 89, 89, 3.2);
  ctx.restore();
  ctx.save();
  ctx.translate(5.5 + 19.5 * L, 114.5 - 98.6 * L);
  ctx.scale(1 - 0.2 * L, 1 - 0.2 * L);
  text(ctx, MIX.title, 0, 0, 5.3, { w: 650, fade: 63 });
  text(ctx, 'Wildeburg', 0, 6.625, 4.9, { c: TINT_T, max: 63 });
  ctx.restore();
  ctx.save();
  ctx.translate(95, 115.5 - 99.6 * L);
  ctx.scale(1 - 0.2 * L, 1 - 0.2 * L);
  ctx.translate(-95, -115.5);
  dot(ctx, 77.5, 120.7, 4.5, 'rgba(255,255,255,.16)');
  dot(ctx, 89.8, 120.7, 5.2, 'rgba(255,255,255,.16)');
  icon(ctx, 'heart', 75.1, 118.3, 4.8, '#fff');
  icon(ctx, 'more', 87.4, 118.3, 4.8, '#fff');
  ctx.restore();
  if (o > 0) {
    ctx.globalAlpha = o;
    icon(ctx, 'queue', 5.5, 130.04, 4.8, 'rgba(255,255,255,.8)');
    slider(ctx, 5.5, 180, 89, 4.6, 1.6, 3);
    ctx.globalAlpha = 1;
  }
  ctx.save();
  ctx.translate(50, 165 + 22 * L);
  ctx.scale(1 - 0.2 * L, 1 - 0.2 * L);
  ctx.translate(-50, -165);
  transport(ctx, [8.8, 44, 80.2], 159, 11, 12);
  ctx.restore();
  icon(ctx, 'queue', 13, 196, 7.6, 'rgba(255,255,255,.78)');
  icon(ctx, 'airplay', 46.2, 196, 7.6, 'rgba(255,255,255,.78)');
  if (L < 1) { ctx.globalAlpha = 1 - L; icon(ctx, 'list', 79.4, 196, 7.6, 'rgba(255,255,255,.78)'); }
  if (L > 0) { ctx.globalAlpha = L; icon(ctx, 'list', 79.4, 196, 7.6, TINT_T); }
  ctx.globalAlpha = 1;
  if (L > 0) phListHead(ctx, L, 8 * (1 - L));
}
function phPlayLive(ctx, sc, L) {
  const S = sc.S, o = clamp(1 - L * 1.7), dy = 26 * L;
  if (o > 0) {
    ctx.globalAlpha = o;
    text(ctx, S.now, 12.5, 130, 3.9, { c: 'rgba(255,255,255,.8)', max: 82 });
    ctx.globalAlpha = 1;
  }
  mixWave(ctx, 5.5, 138 + dy, 89, 9.5, S.p);
  box(ctx, 5.5 + 89 * S.p - 0.3, 138 + dy - 0.57, 0.6, 10.64, 0.3, '#fff');
  times(ctx, sc, 5.5, 94.5, 149.5 + dy, 3.6, 'rgba(255,255,255,.62)');
  if (L > 0) phList(ctx, sc, L, 8 * (1 - L));
}
function phListHead(ctx, L, dy) {
  ctx.globalAlpha = L;
  pills(ctx, 5.5, 35 + dy, ['Comments', 'Tracklist', 'Up Next'], 1, 3.7, 3.6, 1.6, 2);
  const cy = 46.825 + dy;
  text(ctx, `${MIX.tracks.length} identified`, 5.5, cy + (7.7 - 4.75) / 2, 3.8, { w: 600, c: 'rgba(255,255,255,.7)' });
  const iw = 3.4 + 4.4 + 1.4 + tw('Identify', 3.6, 600) + 3.4, ix = 94.5 - iw;
  box(ctx, ix, cy, iw, 7.7, 3.85, 'rgba(255,255,255,.14)');
  icon(ctx, 'identify', ix + 3.4, cy + 1.65, 4.4, '#fff');
  text(ctx, 'Identify', ix + 9.2, cy + 1.6, 3.6, { w: 600 });
  ctx.globalAlpha = 1;
}
function phList(ctx, sc, L, dy) {
  const S = sc.S;
  ctx.save();
  const y0 = 57 + dy, wh = 101, off = sc.v('scroll') * 13.4;
  ctx.beginPath();
  ctx.rect(0, y0, 100, wh);
  ctx.clip();
  for (let i = 0; i < T.length; i++) {
    const ry = y0 + i * 13.4 - off;
    if (ry + 13.4 < y0 || ry > y0 + wh) continue;
    const t = (ry + 6.7 - y0) / wh, a = clamp(Math.min(t / 0.05, (1 - t) / 0.14));
    if (a <= 0) continue;
    ctx.globalAlpha = L * a;
    if (i === S.idx) {
      box(ctx, 3, ry, 94, 13.4, 3, 'rgba(255,255,255,.12)');
      box(ctx, 20.5, ry + 12.15, 72.5 * S.row, 0.45, 0.22, 'rgba(255,255,255,.55)');
    }
    text(ctx, fmt(T[i][0]), 5.5, ry + 4.45, 3.6, { c: 'rgba(255,255,255,.62)' });
    text(ctx, T[i][1], 20.5, ry + 1.89, 4.1, { w: 600, max: 74 });
    text(ctx, T[i][2], 20.5, ry + 7.015, 3.6, { c: 'rgba(255,255,255,.62)', max: 74 });
  }
  ctx.restore();
}
function phOut(ctx, sc, friend) {
  const S = sc.S, H = sc.H;
  sc.layer(ctx, 'out', x => {
    npBg(x, sc, [9, 18], [150, 6, 132]);
    shadow(x, sc, 5.5, 20, 89, 89, 3.2, 3, 8, 'rgba(0,0,0,.35)');
    art(x, sc, PARIAH, 5.5, 20, 89, 89, 3.2);
    text(x, MIX.title, 5.5, 114.5, 5.3, { w: 650, fade: 89 });
    text(x, 'Wildeburg', 5.5, 121.125, 4.9, { c: TINT_T });
    transport(x, [8.8, 44, 80.2], 150, 11, 12);
    slider(x, 5.5, 171, 89, 4.6, 1.6, 3);
  });
  box(ctx, 5.5, 133, 89, 1.4, 0.7, 'rgba(255,255,255,.22)');
  box(ctx, 5.5, 133, Math.max(1, 89 * S.p), 1.4, 0.7, '#fff');
  times(ctx, sc, 5.5, 94.5, 137.5, 3.6, 'rgba(255,255,255,.62)');
  const routes = [['r1', 'airplay', 'iPhone', '#f4efe8'], ['r2', 'tv', 'Living Room', TINT_T], ['r3', 'shareplay', 'SharePlay', TINT_T]];
  for (const [k, ic, l, c] of routes) {
    const a = friend ? +(k === 'r3') : sc.v(k);
    if (a <= 0) continue;
    ctx.globalAlpha = a;
    chip(ctx, 0, 183, 12, ic, l, 4.6, 5.8, 4.4, 5.4, 2.2, c, 50);
  }
  ctx.globalAlpha = 1;
  if (friend) return;
  const sv = sc.v('sheet'), tv = sc.v('toast');
  if (sv > 0) { ctx.fillStyle = `rgba(0,0,0,${0.5 * sv})`; ctx.fillRect(0, 0, 100, H); }
  if (tv > 0) phToast(ctx, sc, clamp(tv * 1.7), -38 * (1 - tv));
  if (sv > 0) phSheet(ctx, sc, sv);
}
function phToast(ctx, sc, a, dy) {
  const x = 3.5, w = 93, y = 14 + dy, lines = wrap('Sign in to Sounding on this Apple TV?', 4.2, 400, 68.7, 3), r1 = 4.6 * 1.28 + lines.length * 4.2 * 1.28, h = 4.6 + r1 + 4 + 11.9 + 4.6;
  ctx.save();
  ctx.globalAlpha = a;
  box(ctx, x, y, w, h, 8.5, 'rgba(46,50,56,.97)');
  line(ctx, 0.3, 'rgba(255,255,255,.09)');
  art(ctx, sc, ICON, x + 4.6, y + 4.6 + (r1 - 11.5) / 2, 11.5, 11.5, 2.6);
  text(ctx, 'Living Room', x + 19.7, y + 4.6, 4.6, { w: 650, lh: 1.28 });
  lines.forEach((l, i) => text(ctx, l, x + 19.7, y + 4.6 + 5.888 + i * 5.376, 4.2, { lh: 1.28, c: 'rgba(255,255,255,.75)' }));
  const by = y + 4.6 + r1 + 4;
  box(ctx, x + 4.6, by, w - 9.2, 11.9, 5.95, TINT);
  text(ctx, 'Sign In', 50, by + 3, 4.6, { w: 650, lh: 1.28, c: ON_TINT, align: 'center' });
  ctx.restore();
}
function phSheet(ctx, sc, sv) {
  const sh = 61.75, y = sc.H - 2 - sh + 1.12 * sh * (1 - sv), pk = sc.v('picked'), uy = y + 19.75;
  box(ctx, 2, y, 96, sh, 12, '#202327');
  line(ctx, 0.3, 'rgba(255,255,255,.07)');
  box(ctx, 44.5, y + 2.6, 11, 1.4, 0.7, 'rgba(255,255,255,.28)');
  text(ctx, 'Play On', 50, y + 8, 5.4, { w: 700, align: 'center' });
  box(ctx, 6.6, uy, 86.8, 34, 6, 'rgba(255,255,255,.08)');
  icon(ctx, 'phone', 11.6, uy + 5.1, 6.8, 'rgba(255,255,255,.85)');
  text(ctx, 'This iPhone', 22.4, uy + 5.5, 4.8, { w: 500 });
  ctx.fillStyle = 'rgba(255,255,255,.09)';
  ctx.fillRect(6.6, uy + 17, 86.8, 0.3);
  icon(ctx, 'tv', 11.6, uy + 22.1, 6.8, 'rgba(255,255,255,.85)');
  text(ctx, 'Living Room', 22.4, uy + 17 + 3.19, 4.8, { w: 500 });
  text(ctx, 'Apple TV', 22.4, uy + 17 + 9.19, 3.7, { c: 'rgba(255,255,255,.55)' });
  if (pk < 1) { ctx.globalAlpha = 1 - pk; icon(ctx, 'check', 82.4, uy + 5.5, 6, TINT_T); }
  if (pk > 0) { ctx.globalAlpha = pk; icon(ctx, 'check', 82.4, uy + 22.5, 6, TINT_T); }
  ctx.globalAlpha = 1;
}
function flag(ctx, x, top, bottom, lw, f, px, py, c, label, extra) {
  ctx.fillStyle = c;
  ctx.fillRect(x, top, lw, bottom - top);
  const w = tw(label, f, 700) + 2 * px, h = f * 1.25 + 2 * py;
  box(ctx, x + lw, top, w, h, [0, f * 0.2, f * 0.2, 0], c);
  text(ctx, label, x + lw + px, top + py, f, { w: 700, c: '#000' });
  if (extra) text(ctx, extra, x + lw + w + f * 0.27, top + py, f, { w: 600, c: '#f4efe8' });
}
function memCue(ctx, x, base, hw, h) {
  ctx.beginPath();
  ctx.moveTo(x - hw, base);
  ctx.lineTo(x + hw, base);
  ctx.lineTo(x, base - h);
  ctx.closePath();
  ctx.fillStyle = '#e9e2d8';
  ctx.fill();
}
const CUES = [['#ff5a5a', 4, 'A'], ['#ff9f43', 14, 'B'], ['#3fd28a', 44, 'C']];
function phCues(ctx, sc) {
  npBg(ctx, sc, [9, 18], [150, 6, 132], true);
  shadow(ctx, sc, 5.5, 20, 23, 23, 2.2, 2, 5, 'rgba(0,0,0,.35)');
  art(ctx, sc, small('paul-renard-transmissions'), 5.5, 20, 23, 23, 2.2);
  text(ctx, 'Transmissions', 33, 24, 6.2, { w: 650, max: 61.5 });
  text(ctx, 'Paul Renard', 33, 32.35, 4.9, { c: TINT_T });
  cueWave(ctx, G.wfa, 5.5, 56, 89, 30, 'rgba(255,255,255,.62)');
  for (const [c, x, l] of CUES) flag(ctx, 5.5 + 0.89 * x, 55, 86, 1.2, 4, 1.6, 0.3, c, l);
  memCue(ctx, 5.5 + 0.89 * 76, 88.5, 3.4, 5);
  text(ctx, 'Hot Cues', 5.5, 100, 5.4, { w: 700 });
  box(ctx, 5.5, 109, 89, 49.5, 6, 'rgba(255,255,255,.09)');
  [['Hot cue', '0:16'], ['Hot cue', '0:57'], ['Drop', '2:59']].forEach(([l, t], i) => {
    const y = 109 + i * 16.5;
    if (i) { ctx.fillStyle = 'rgba(255,255,255,.09)'; ctx.fillRect(5.5, y, 89, 0.3); }
    box(ctx, 10.5, y + 4.25, 8, 8, 1.8, CUES[i][0]);
    text(ctx, CUES[i][2], 14.5, y + 5.5, 4.4, { w: 700, c: '#000', align: 'center' });
    text(ctx, l, 22.5, y + 5.25, 4.8, { w: 500 });
    text(ctx, t, 89.5, y + 5.25, 4.8, { w: 500, c: 'rgba(255,255,255,.62)', align: 'right' });
  });
  transport(ctx, [8.8, 44, 80.2], 177, 11, 12);
}

// MARK: Apple TV
function tvBg(ctx, sc, kind) {
  const H = sc.H, dj = kind === 'dj';
  ctx.fillStyle = dj ? '#0b0b0c' : '#0b0b0a';
  ctx.fillRect(0, 0, 100, H);
  ellipse(ctx, 100, H, 0.1, 0.92, 0.6, 0.75, dj ? '70,70,74' : '84,96,52', dj ? 0.45 : 0.5, 0.7);
  ellipse(ctx, 100, H, 0.88, 0.06, 0.55, 0.7, dj ? '60,66,78' : '64,82,104', dj ? 0.4 : 0.45, 0.72);
  const im = kind === 'np' && sc.img(BACKDROP);
  if (im) { ctx.globalAlpha = 0.12; cover(ctx, im, -10, -0.1 * H, 120, 1.2 * H); ctx.globalAlpha = 1; }
  const ring = kind === 'np' ? 'rgba(205,222,178,.1)' : 'rgba(255,255,255,.075)';
  waves(ctx, sc, -4, 1, 108, 9, ring);
  waves(ctx, sc, -4, 44, 108, 10, ring);
  rings(ctx, sc, 62, 16, 62, ring);
  rings(ctx, sc, -19, -18, 84, ring);
}
function tvHead(ctx, sc, file, title, artist, lines) {
  shadow(ctx, sc, 7.6, 10.4, 31.2, 31.2, 1.1, 1.6, 4, 'rgba(0,0,0,.45)');
  art(ctx, sc, file, 7.6, 10.4, 31.2, 31.2, 1.1);
  const ls = wrap(title, 3.2, 700, 48.7, lines);
  ls.forEach((l, i) => text(ctx, l, 43.5, 10.4 + i * 3.744, 3.2, { w: 700, lh: 1.17 }));
  text(ctx, artist, 43.5, 10.4 + ls.length * 3.744 + 0.5, 2.6, { c: TINT_T, max: 48.7 });
}
function tvCtl(ctx, sc, top) {
  const cy = top + 3;
  [[45.5, 'rw'], [56.5, 'ff'], [63.5, 'heart'], [68.5, 'comment'], [73.5, 'list'], [78.5, 'queue'], [83.5, 'airplay'], [88.5, 'more']].forEach(([x, n]) => {
    dot(ctx, x, cy, 2, 'rgba(255,255,255,.14)');
    icon(ctx, n, x - 1, cy - 1, 2, '#fff');
  });
  ctx.save();
  ctx.shadowColor = 'rgba(0,0,0,.4)';
  ctx.shadowBlur = 2 * sc.K;
  ctx.shadowOffsetY = 0.8 * sc.K;
  dot(ctx, 51, cy, 3, '#f4f4f4');
  ctx.restore();
  icon(ctx, 'pause', 49.7, cy - 1.3, 2.6, '#111');
  text(ctx, 'Pause', 51, top + 6.8, 2.2, { w: 600, align: 'center' });
}
function tv(ctx, sc) {
  const on = sc.v('on'), sign = sc.v('sign'), np = sc.v('np'), dj = sc.v('dj'), H = sc.H;
  if (on <= 0 && sign <= 0 && np <= 0 && dj <= 0) return;
  ctx.fillStyle = `rgba(11,10,9,${on})`;
  ctx.fillRect(0, 0, 100, H);
  sc.view(ctx, sign, { direct: true }, x => tvSign(x, sc));
  if (dj < 1) sc.view(ctx, np, null, x => tvNp(x, sc));
  sc.view(ctx, dj, { s: 1.03 - 0.03 * dj }, x => tvDj(x, sc));
}
const QR = '/kwRfj90W/wQ5hoLCxzQboN1u+2b3rt0Ts/R9a1V26jcQfy9xy7BGk3kYdQxB/qqqqqqqq/gESDNFUQ4ADPuCY+gIjaEJisjJnqOOi/cSJWHNITZcDou40o5v2r1d2oQZRnXuhTOqK9GcBvuPslzsMe9vpaAFz+lTNFjFU2LEH5ts8M9VAyK8MpcnTmO3GauRqua2+8TA/aPc0OLovdzRLT5XSKZkIMRyB1pjCP6Gcgx5XsiL5c9V+m8i7J3/iyBzCQieOOC7YwS9uXYfq2qQax+XdDzNvw03f2lwP58SFY0X+/sZCowsmrUGiolE9BbEyb1Gp+dS9/OAE+QbhBvWtviuYnf/OE3HLRomdgml4ELJ+JsEilaLh8vSPrlnJhOXv9OofLoZNH11CSWW7n1TCEOEsX20zpKL88rBHiKpuNW5y5Yx0VPy6jA2y1TbX6lLh6Pad5GWCyiVzJHOqkhfy1hO6TMQIqC3qpFL4bOkslA9vpjWPairnT2vC9PT6xvokBbbQXRqJ+gG1TSPzk97/1wgPoAX1bsZANsb/oFgaszzOvwQIwzGhJzGboE/q/Ix0/d1vRHmBMOdW6ib1hxS6RtBL35+1g/WE/lZ2yHpR4PgA==';
const QN = 61, QZ = 4, CREAM = '246,240,231';
const JACK = [[0, 0], [0.014, 0.022], [0.036, 0.03], [0.07, 0.03], [0.076, 0.019], [0.094, 0.019], [0.1, 0.031], [0.17, 0.031], [0.176, 0.019], [0.196, 0.019], [0.202, 0.034], [0.44, 0.034], [0.446, 0.052], [0.49, 0.052], [0.496, 0.064], [0.86, 0.064], [0.93, 0.046], [1, 0.026]];
function signShapes() {
  if (G.sign) return G.sign;
  const bits = atob(QR), n = QN + 2 * QZ, mid = n / 2, clear = Math.max(2.8, QN * 0.155), on = new Uint8Array(n * n), e = 0.5 - 0.5523 * 0.5;
  for (let r = 0; r < QN; r++) for (let c = 0; c < QN; c++) {
    const i = r * QN + c;
    if (!(bits.charCodeAt(i >> 3) & (128 >> (i & 7))) || ((r < 8 || r >= QN - 8) && c < 8) || (r < 8 && c >= QN - 8)) continue;
    if (Math.hypot(c + QZ + 0.5 - mid, r + QZ + 0.5 - mid) > clear) on[(r + QZ) * n + c + QZ] = 1;
  }
  const f = (r, c) => r >= 0 && r < n && c >= 0 && c < n && on[r * n + c] === 1;
  const qr = new Path2D();
  for (let y = QZ; y < n - QZ; y++) for (let x = QZ; x < n - QZ; x++) {
    if (f(y, x)) {
      const u = f(y - 1, x), d = f(y + 1, x), l = f(y, x - 1), t = f(y, x + 1);
      if (!u && !l) { qr.moveTo(x, y + 0.5); qr.bezierCurveTo(x, y + e, x + e, y, x + 0.5, y); } else qr.moveTo(x, y);
      if (!u && !t) { qr.lineTo(x + 0.5, y); qr.bezierCurveTo(x + 1 - e, y, x + 1, y + e, x + 1, y + 0.5); } else qr.lineTo(x + 1, y);
      if (!d && !t) { qr.lineTo(x + 1, y + 0.5); qr.bezierCurveTo(x + 1, y + 1 - e, x + 1 - e, y + 1, x + 0.5, y + 1); } else qr.lineTo(x + 1, y + 1);
      if (!d && !l) { qr.lineTo(x + 0.5, y + 1); qr.bezierCurveTo(x + e, y + 1, x, y + 1 - e, x, y + 0.5); } else qr.lineTo(x, y + 1);
      qr.closePath();
      continue;
    }
    for (const dr of [-1, 1]) for (const dc of [-1, 1]) {
      if (!f(y + dr, x) || !f(y, x + dc) || !f(y + dr, x + dc)) continue;
      const px = dc > 0 ? x + 1 : x, py = dr > 0 ? y + 1 : y;
      qr.moveTo(px, py);
      if (dc * dr > 0) { qr.lineTo(px - dc * 0.5, py); qr.bezierCurveTo(px - dc * e, py, px, py - dr * e, px, py - dr * 0.5); }
      else { qr.lineTo(px, py - dr * 0.5); qr.bezierCurveTo(px, py - dr * e, px - dc * e, py, px - dc * 0.5, py); }
      qr.closePath();
    }
  }
  const round = (p, x, y, w, h, r) => { p.moveTo(x + r, y); p.arcTo(x + w, y, x + w, y + h, r); p.arcTo(x + w, y + h, x, y + h, r); p.arcTo(x, y + h, x, y, r); p.arcTo(x, y, x + w, y, r); p.closePath(); };
  const eyes = new Path2D(), pupils = new Path2D(), mark = new Path2D();
  for (const [x, y] of [[QZ, QZ], [QZ + QN - 7, QZ], [QZ, QZ + QN - 7]]) { round(eyes, x, y, 7, 7, 2.2); round(eyes, x + 1, y + 1, 5, 5, 1.35); round(pupils, x + 2, y + 2, 3, 3, 1.1); }
  const side = Math.max((clear - 1.2) / 0.45, 1), bw = side * 0.8 / 7.25, gap = (side * 0.8 - bw * 5) / 4;
  for (let i = 0; i < 5; i++) { const h = Math.max((1 - Math.abs(i - 2) * 0.31) * side * 0.86, side * 0.18); round(mark, mid - side * 0.4 + i * (bw + gap), mid - h / 2, bw, h, bw / 2); }
  const a = -0.12, dx = Math.cos(a), dy = Math.sin(a), len = 330;
  const world = (x, y) => [690 - (dx * x + dy * y) * len, 529 - (dy * x - dx * y) * len];
  const s0 = world(1, 0), c1 = [s0[0] - dx * 422.4, s0[1] - dy * 422.4], c2 = [153.6, 727], end = [-80, 647], cable = [];
  for (let i = 0; i <= 72; i++) {
    const t = i / 72, m = 1 - t;
    const at = k => m * m * m * s0[k] + 3 * m * m * t * c1[k] + 3 * m * t * t * c2[k] + t * t * t * end[k], go = k => 3 * m * m * (c1[k] - s0[k]) + 6 * m * t * (c2[k] - c1[k]) + 3 * t * t * (end[k] - c2[k]);
    const vx = go(0), vy = go(1), mag = Math.max(1e-4, Math.hypot(vx, vy));
    cable.push([at(0), at(1), vy / mag, -vx / mag]);
  }
  const poly = pts => { const p = new Path2D(); pts.forEach(([x, y], i) => (i ? p.lineTo(x, y) : p.moveTo(x, y))); return p; };
  const plug = poly([...JACK.map(([x, y]) => world(x, y)), ...JACK.slice(0, -1).reverse().map(([x, y]) => world(x, -y))]);
  plug.closePath();
  const lines = [0, 1, 2].map(i => {
    const off = i * 5 / len, half = (0.026 + off) * len, top = JACK.map(([x, y], j) => [x - off * (j < 2 ? 1.1 - j * 0.5 : 0), y + (j ? off : 0)]);
    return poly([...cable.map(([x, y, nx, ny]) => [x + nx * half, y + ny * half]).reverse(), ...top.map(([x, y]) => world(x, y)).reverse(), ...top.slice(1).map(([x, y]) => world(x, -y)), ...cable.map(([x, y, nx, ny]) => [x - nx * half, y - ny * half])]);
  });
  const knurl = new Path2D();
  for (let x = 0.53; x < 0.84; x += 0.042) { knurl.moveTo(...world(x, 0.064)); knurl.lineTo(...world(x + 0.04, -0.064)); }
  G.sign = { qr, eyes, pupils, mark, n, clear, plug, lines, knurl };
  return G.sign;
}
function smooth(ctx, x, y, s, r) {
  const m = s / 2;
  ctx.save();
  ctx.translate(x + m, y + m);
  ctx.beginPath();
  for (let i = 0; i < 4; i++) {
    ctx.lineTo(m - 1.5287 * r, -m);
    ctx.bezierCurveTo(m - 1.0885 * r, -m, m - 0.8684 * r, -m, m - 0.6315 * r, 0.0749 * r - m);
    ctx.bezierCurveTo(m - 0.3728 * r, 0.1691 * r - m, m - 0.1691 * r, 0.3728 * r - m, m - 0.0749 * r, 0.6315 * r - m);
    ctx.bezierCurveTo(m, 0.8684 * r - m, m, 1.0885 * r - m, m, 1.5287 * r - m);
    ctx.rotate(Math.PI / 2);
  }
  ctx.closePath();
  ctx.restore();
}
function points(ctx, sc, fn) {
  ctx.save();
  ctx.scale(100 / 1920, 100 / 1920);
  ctx.translate(0, sc.H * 9.6 - 540);
  fn(ctx, sc.K * 100 / 1920);
  ctx.restore();
}
function signBack(ctx, P, sc) {
  const S = G.sign, soft = `rgba(${CREAM},.7)`;
  ctx.fillStyle = '#100d0c';
  ctx.fillRect(0, -20, 1920, 1120);
  for (const [x, y, rx, rgb] of [[480, 597, 672, '255,107,26'], [1440, 457, 672, '245,191,102'], [1000, 667, 480, '255,107,26']]) {
    ctx.save();
    ctx.translate(x, y);
    ctx.scale(rx, 486);
    const g = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);
    g.addColorStop(0, `rgba(${rgb},.094)`);
    g.addColorStop(1, `rgba(${rgb},0)`);
    ctx.fillStyle = g;
    ctx.fillRect(-1, -1, 2, 2);
    ctx.restore();
  }
  const tmp = document.createElement('canvas');
  tmp.width = sc.cv.width;
  tmp.height = sc.cv.height;
  const t = tmp.getContext('2d');
  t.setTransform(ctx.getTransform());
  t.save();
  t.shadowColor = 'rgba(0,0,0,.35)';
  t.shadowBlur = 36 * P;
  t.shadowOffsetY = 12 * P;
  t.fillStyle = '#100d0c';
  t.fill(S.plug);
  t.restore();
  t.lineCap = t.lineJoin = 'round';
  for (const [p, c, w, a] of [[S.lines[0], TINT, 2.07, 0.85], [S.lines[1], TINT, 1.62, 0.24], [S.lines[2], '#f5bf66', 1.62, 0.12], [S.knurl, TINT, 1.44, 0.65]]) { t.globalAlpha = a; t.strokeStyle = c; t.lineWidth = w; t.stroke(p); }
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.globalAlpha = 0.48;
  ctx.drawImage(tmp, 0, 0);
  ctx.restore();
  text(ctx, 'Plug in. Turn it up.', 960, 0, 58, { w: 800, c: `rgb(${CREAM})`, align: 'center', base: 239.4, sx: 1.019 });
  text(ctx, 'Your SoundCloud on Apple TV, iPhone and Mac.', 960, 0, 29, { c: soft, align: 'center', base: 297.6, sx: 1.026 });
  const note = 'iPhone is nearby: open Sounding on it to sign in.', x = 961.5 - (tw(note, 29) * 1.032 + 34) / 2;
  box(ctx, x + 4.1, 730.6, 14.3, 25.3, 1.1, `rgba(${CREAM},.17)`);
  rr(ctx, x + 2.8, 729.3, 16.9, 27.9, 2.4);
  line(ctx, 2.6, soft);
  ctx.lineCap = 'round';
  ctx.beginPath();
  ctx.moveTo(x + 9.4, 733.2);
  ctx.lineTo(x + 13.1, 733.2);
  line(ctx, 2.3, soft);
  ctx.beginPath();
  ctx.moveTo(x + 8.4, 753.5);
  ctx.lineTo(x + 14.1, 753.5);
  line(ctx, 1.8, soft);
  text(ctx, note, x + 34, 0, 29, { c: soft, base: 753.5, sx: 1.032 });
}
function signPlate(ctx, P) {
  const S = G.sign, cell = 316.8 / S.n;
  ctx.save();
  ctx.shadowColor = 'rgba(0,0,0,.2)';
  ctx.shadowBlur = 72 * P;
  ctx.shadowOffsetY = 14 * P;
  smooth(ctx, 780, 337, 360, 44);
  ctx.fillStyle = '#fff';
  ctx.fill();
  ctx.restore();
  ctx.translate(801.6, 358.6);
  ctx.scale(cell, cell);
  const g = ctx.createLinearGradient(0, 0, S.n, S.n);
  g.addColorStop(0, '#170f0d');
  g.addColorStop(0.38, '#170f0d');
  g.addColorStop(1, '#993608');
  ctx.fillStyle = g;
  ctx.fill(S.qr);
  ctx.fill(S.eyes, 'evenodd');
  ctx.fillStyle = '#993608';
  ctx.fill(S.pupils);
  ctx.beginPath();
  ctx.arc(S.n / 2, S.n / 2, S.clear - 0.9, 0, TAU);
  line(ctx, 0.12, 'rgba(255,107,26,.4)');
  ctx.fillStyle = TINT;
  ctx.fill(S.mark);
}
function signRing(ctx, P, glow, spread) {
  ctx.globalAlpha *= glow;
  ctx.translate(960, 517);
  ctx.scale(spread, spread);
  ctx.shadowColor = 'rgba(255,107,26,.6)';
  ctx.shadowBlur = 44 * P;
  smooth(ctx, -180, -180, 360, 44);
  line(ctx, 2, TINT);
}
function signButton(ctx, P, press) {
  const s = 1.06 - 0.09 * press, ink = '#0f0d0b';
  ctx.translate(960.25, 863.25);
  ctx.scale(s, s);
  ctx.save();
  ctx.shadowColor = 'rgba(0,0,0,.22)';
  ctx.shadowBlur = 36 * P;
  ctx.shadowOffsetY = 10 * P;
  box(ctx, -128, -32.8, 256, 65.6, 32.8, `rgb(${CREAM})`);
  ctx.restore();
  ctx.translate(-98.3, -11.6);
  ctx.fillStyle = ink;
  ctx.fill(new Path2D('M1.8 7.4H6.2L14.6.9Q17.9-1.2 17.9 2.6V21Q17.9 24.8 14.6 22.7L6.2 16.2H1.8Q0 16.2 0 14.4V9.2Q0 7.4 1.8 7.4Z'));
  ctx.lineCap = 'round';
  ctx.beginPath();
  ctx.arc(17.5, 11.8, 6, -0.75, 0.75);
  ctx.moveTo(17.5 + 14.2 * Math.cos(0.74), 11.8 - 14.2 * Math.sin(0.74));
  ctx.arc(17.5, 11.8, 14.2, -0.74, 0.74);
  line(ctx, 3, ink);
  text(ctx, 'Play Sound', 58.4, 0, 28, { w: 600, c: ink, base: 21, sx: 1.017 });
}
function tvSign(ctx, sc) {
  signShapes();
  const [glow, spread, press] = sc.bell;
  sc.layer(ctx, 'signA', x => points(x, sc, (y, P) => signBack(y, P, sc)));
  if (glow > 0) points(ctx, sc, (y, P) => signRing(y, P, glow, spread));
  sc.layer(ctx, 'signB', x => points(x, sc, signPlate));
  points(ctx, sc, (y, P) => signButton(y, P, press));
}
function chime(sc, dt) {
  const on = sc.st.tv === 'sign' && sc.vis && sc.v('sign') >= 1;
  sc.wait = on ? sc.wait + dt : -1.2;
  const t = sc.wait < 0 ? -1 : sc.wait % 7, live = t >= 0 && t < 1.56;
  if (!live) {
    if (sc.rang) { sc.rang = false; sc.bell = [0, 1, 0]; sc.dirty = true; }
    return;
  }
  sc.tick += dt;
  if (sc.rang && sc.tick < 1 / 31) return;
  const u = t - 0.14, w = u * TAU / 0.45;
  sc.rang = true;
  sc.tick = 0;
  sc.bell = [u < 0 ? 0 : u < 0.3 ? 0.45 * easeIO(u / 0.25) : 0.45 * (1 - easeOut((u - 0.3) / 1.1)), u < 0 ? 1 : 1 + 0.13 * (1 - (1 + w) * Math.exp(-w)), t < 0.1 ? easeIO(t / 0.1) : t < 0.18 ? 1 : 1 - easeOut((t - 0.18) / 0.32)];
  sc.dirty = true;
}
function tvNp(ctx, sc) {
  const S = sc.S;
  sc.layer(ctx, 'np', x => { tvBg(x, sc, 'np'); tvHead(x, sc, PARIAH, MIX.title, 'Wildeburg', 2); tvCtl(x, sc, 34.6); });
  ctx.save();
  ctx.translate(43.5, 28.4);
  ctx.fillStyle = 'rgba(255,255,255,.34)';
  ctx.fill(G.ticks);
  ctx.beginPath();
  ctx.rect(0, 0, 48.7 * S.p, 1);
  ctx.clip();
  ctx.fillStyle = '#fff';
  ctx.fill(G.ticks);
  ctx.restore();
  times(ctx, sc, 43.5, 92.2, 31, 2.2, 'rgba(255,255,255,.6)');
}
function tvDj(ctx, sc) {
  const am = sc.v('am');
  sc.layer(ctx, 'dj', x => { tvBg(x, sc, 'dj'); tvHead(x, sc, TRANS, 'Transmissions', 'Paul Renard', 1); });
  if (am < 1) {
    ctx.globalAlpha = 1 - am;
    cueWave(ctx, G.wfa, 43.5, 21, 48.7, 9, 'rgba(255,255,255,.55)');
    for (const [c, x, l] of CUES) flag(ctx, 43.5 + 0.487 * x, 20, 30, 0.35, 2.2, 0.6, 0.1, c, l, l === 'C' ? 'Drop' : '');
    memCue(ctx, 43.5 + 0.487 * 76, 31, 1.2, 1.8);
  }
  if (am > 0) { ctx.globalAlpha = am; tvAm(ctx); }
  ctx.globalAlpha = 1;
  tvCtl(ctx, sc, 34.6 + 8.6 * am);
}
function meters(ctx, x, y, on) {
  'HMLF'.split('').forEach((l, j) => {
    const mx = x + j * 2.15;
    box(ctx, mx, y, 1.7, 2.4, 0.2, j < on ? '#f2f2f2' : 'rgba(255,255,255,.14)');
    text(ctx, l, mx + 0.85, y + 2.7, 2.2, { lh: 1, c: 'rgba(255,255,255,.62)', align: 'center' });
  });
}
function amDeck(ctx, top, k, name, path, on) {
  const aw = tw(k, 2.2, 650);
  text(ctx, k, 43.5, top, 2.2, { w: 650 });
  text(ctx, name, 43.5 + aw + 0.6, top, 2.2, { c: 'rgba(255,255,255,.55)' });
  const y = top + 3.15, w = 39.15;
  cueWave(ctx, path, 43.5, y, w, 4.9, 'rgba(255,255,255,.34)');
  ctx.save();
  ctx.beginPath();
  ctx.rect(43.5, y, w / 2, 4.9);
  ctx.clip();
  cueWave(ctx, path, 43.5, y, w, 4.9, '#f08a5d');
  ctx.restore();
  ctx.fillStyle = '#fff';
  ctx.fillRect(43.5 + w / 2 - 0.125, y - 0.4, 0.25, 5.7);
  meters(ctx, 84.05, y, on);
}
function tvAm(ctx) {
  const base = 18.6 + 3 * (1.25 / 2 + 0.36);
  text(ctx, 'Bass swap', 43.5, 18.6, 3, { w: 600, base });
  text(ctx, 'Bar 9 of 16', 92.2, 0, 2.4, { c: 'rgba(255,255,255,.55)', align: 'right', base });
  box(ctx, 43.5, 22.8, 48.7, 0.5, 0.25, 'rgba(255,255,255,.18)');
  box(ctx, 43.5, 22.8, 48.7 * 0.5625, 0.5, 0.25, TINT_T);
  amDeck(ctx, 23.9, 'A', 'Transmissions', G.wfa, 3);
  const aw = tw('A', 2.2, 600), bw = tw('B', 2.2, 600), x0 = 43.5 + aw + 1.2, x1 = 92.2 - bw - 1.2, cy = 31.4 + 1.375;
  text(ctx, 'A', 43.5, 31.4, 2.2, { w: 600, c: 'rgba(255,255,255,.5)' });
  text(ctx, 'B', 92.2, 31.4, 2.2, { w: 600, align: 'right' });
  box(ctx, x0, cy - 0.175, x1 - x0, 0.35, 0.175, 'rgba(255,255,255,.25)');
  box(ctx, x0 + (x1 - x0) * 0.58 - 1.5, cy - 0.75, 3, 1.5, 0.75, '#fff');
  amDeck(ctx, 34.2, 'B', 'Invisible Sandwich', G.wfb, 2);
}

// MARK: Apple Watch
function watch(ctx, sc) {
  const H = sc.H, home = sc.v('home'), rem = sc.v('remote');
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, 100, H);
  const c = 1 - Math.max(home, rem);
  if (c > 0) { ctx.globalAlpha = c; text(ctx, '21:47', 50, H * 0.36, 33, { w: 600, lh: 1, align: 'center', c: '#f4efe8' }); ctx.globalAlpha = 1; }
  sc.view(ctx, home, { direct: true }, x => sc.layer(x, 'home', y => wHome(y, sc)));
  sc.view(ctx, rem, null, x => wRemote(x, sc));
}
function wHome(ctx, sc) {
  text(ctx, '21:47', 87, 9.5, 8.6, { w: 600, align: 'right' });
  text(ctx, 'Sounding', 8.5, 19, 12.5, { w: 500, c: 'rgba(255,255,255,.66)' });
  box(ctx, 2.5, 36, 95, 26, 8, '#222224');
  art(ctx, sc, small('essy-wildeburg'), 8.5, 42.5, 13, 13, 3);
  text(ctx, 'Essy - Wildeburg 2025', 25.9, 40.2, 8, { w: 500, lh: 1.15, max: 52.8 });
  text(ctx, 'Living Room', 25.9, 49.4, 7.2, { lh: 1.15, c: 'rgba(255,255,255,.55)' });
  icon(ctx, 'vol', 83.1, 44.8, 8.4, 'rgba(255,255,255,.6)');
  box(ctx, 2.5, 65, 95, 26, 8, '#222224');
  dot(ctx, 14.25, 78, 5.75, '#fff');
  icon(ctx, 'play', 11.85, 75, 6, '#000');
  text(ctx, 'Listen Now', 24.4, 72.75, 8.4, { w: 500 });
  box(ctx, 6, 94, 88, 26, 8, '#222224');
  icon(ctx, 'queue', 12, 102, 10, '#fff');
  text(ctx, 'Library', 26.4, 101.75, 8.4, { w: 500 });
}
function wRemote(ctx, sc) {
  const ry = sc.H - 47, cx = 50, cy = ry + 19, r = 16.15;
  sc.layer(ctx, 'remote', x => {
    text(x, '21:47', 87, 9.5, 8.6, { w: 600, align: 'right' });
    icon(x, 'tv', 9, 22.1, 10, TINT_T);
    text(x, 'Living Room', 21.6, 22, 8.2, { w: 600, c: TINT_T });
    const ls = wrap('Essy - Wildeburg 2025', 10.5, 650, 82, 2);
    ls.forEach((l, i) => text(x, l, 9, 34 + i * 11.97, 10.5, { w: 650, lh: 1.14 }));
    text(x, 'Wildeburg', 9, 34 + ls.length * 11.97 + 0.8, 8.6, { c: 'rgba(255,255,255,.6)' });
    icon(x, 'rw', 7, ry + 11, 16, '#fff');
    icon(x, 'ff', 77, ry + 11, 16, '#fff');
    x.beginPath();
    x.arc(cx, cy, r, 0, TAU);
    line(x, 2.85, 'rgba(255,255,255,.2)');
    icon(x, 'pause', cx - 8.36, cy - 8.36, 16.72, '#fff');
  });
  const p = sc.S.p;
  if (p <= 0) return;
  ctx.beginPath();
  ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + TAU * p);
  ctx.lineCap = 'round';
  line(ctx, 2.85, TINT_T);
}

// MARK: iPad
function pad(ctx, sc) {
  const home = sc.v('home'), play = sc.v('play');
  ctx.fillStyle = play >= 1 ? '#0e151b' : '#fff';
  ctx.fillRect(0, 0, 100, sc.H);
  const b = sc.v('b');
  if (b < 1) {
    if (play < 1) sc.view(ctx, home, { direct: true }, x => sc.layer(x, 'home', y => padHome(y, sc)));
    sc.view(ctx, play, { dy: 5 * (1 - play) }, x => padPlay(x, sc));
  }
  sc.view(ctx, b, { s: 1.02 - 0.02 * b, direct: true }, x => sc.layer(x, 'cues', y => padCues(y, sc)));
}
// Night side: the same set-up as Now Playing, on a track with cues. The flags and the
// Hot Cues rows are the phone's (phCues), laid out for the wider screens.
function cueRows(ctx, x, y, w, rh, f) {
  [['Hot cue', '0:16'], ['Hot cue', '0:57'], ['Drop', '2:59']].forEach(([l, t], i) => {
    const ry = y + i * rh, s = f * 1.7;
    if (i) { ctx.fillStyle = 'rgba(255,255,255,.09)'; ctx.fillRect(x, ry, w, f * 0.07); }
    box(ctx, x + f, ry + (rh - s) / 2, s, s, s * 0.22, CUES[i][0]);
    text(ctx, CUES[i][2], x + f + s / 2, ry + (rh - f * 1.25) / 2, f * 0.92, { w: 700, c: '#000', align: 'center' });
    text(ctx, l, x + f * 2 + s, ry + (rh - f * 1.25) / 2, f, { w: 500 });
    text(ctx, t, x + w - f, ry + (rh - f * 1.25) / 2, f, { w: 500, c: 'rgba(255,255,255,.62)', align: 'right' });
  });
}
function cueStrip(ctx, x, y, w, h, f) {
  cueWave(ctx, G.wfa, x, y, w, h, 'rgba(255,255,255,.62)');
  for (const [c, cx, l] of CUES) flag(ctx, x + w * cx / 100, y - h * 0.03, y + h, w * 0.0135, f, f * 0.4, f * 0.08, c, l);
  memCue(ctx, x + w * 0.76, y + h * 1.08, w * 0.038, h * 0.17);
}
function padCues(ctx, sc) {
  npBg(ctx, sc, [6, 9], [70, -24, 40], true);
  box(ctx, 47.5, 1.3, 5, 0.7, 0.35, 'rgba(255,255,255,.3)');
  shadow(ctx, sc, 8.5, 4.4, 26, 26, 1.6, 1.6, 4, 'rgba(0,0,0,.35)');
  art(ctx, sc, TRANS, 8.5, 4.4, 26, 26, 1.6);
  text(ctx, 'Transmissions', 4.5, 32.6, 3.2, { w: 650, max: 23.5 });
  text(ctx, 'Paul Renard', 4.5, 36.6, 3, { c: TINT_T, max: 23.5 });
  circleBtn(ctx, 30.2, 35.5, 4.6, 'heart', 2.5);
  circleBtn(ctx, 36.2, 35.5, 4.6, 'more', 2.5);
  cueStrip(ctx, 4.5, 42.4, 34, 8.2, 1.8);
  transport(ctx, [7, 18.8, 30.6], 55.6, 5.4, 5.4);
  slider(ctx, 4.5, 65, 16, 2.6, 0.8, 1.2);
  chip(ctx, 22.6, 63, 4.8, 'airplay', 'This iPad', 2.6, 2.8, 1.4, 1.8, 1, '#fff');
  const gx = 41.4, gy = 3.4;
  glass(ctx, sc, gx, gy, 56.2, 65.15, 3.8);
  text(ctx, 'Hot Cues', gx + 2.8, gy + 3, 3.8, { w: 700 });
  box(ctx, gx + 2.8, gy + 9.6, 50.6, 30, 2.4, 'rgba(255,255,255,.08)');
  cueRows(ctx, gx + 2.8, gy + 9.6, 50.6, 10, 2.8);
}
function shelf(ctx, sc, x, y, items, s, gap, f, sub) {
  items.forEach((n, i) => {
    const ix = x + i * (s + gap);
    if (ix > 100) return;
    art(ctx, sc, small(LIKES[n][0]), ix, y, s, s, s * 0.084);
    text(ctx, LIKES[n][1], ix, y + s + f * 0.42, f, { w: 600, max: s, c: sub[0] });
    text(ctx, LIKES[n][2], ix, y + s + f * 0.42 + f * 1.25, f, { max: s, c: sub[1] });
  });
}
function padHome(ctx, sc) {
  const H = sc.H;
  ctx.fillStyle = '#fff';
  ctx.fillRect(0, 0, 100, H);
  const labels = ['Home', 'Library', 'Settings'], ws = labels.map(l => tw(l, 2.6, 600) + 4), total = 2 + 11.6 + ws.reduce((a, b) => a + b, 0) + 1.6;
  let x = 50 - total / 2;
  shadow(ctx, sc, x, 2.4, total, 6.6, 3.3, 0.6, 2.4, 'rgba(0,0,0,.1)');
  box(ctx, x, 2.4, total, 6.6, 3.3, '#f7f7f9');
  line(ctx, 0.15, 'rgba(0,0,0,.05)');
  x += 1;
  icon(ctx, 'sidebar', x + 1.3, 4.1, 3.2, '#000');
  x += 6.2;
  labels.forEach((l, i) => {
    if (!i) box(ctx, x, 2.4 + (6.6 - 5.45) / 2, ws[i], 5.45, 2.4, '#e9e9ee');
    text(ctx, l, x + ws[i] / 2, 2.4 + (6.6 - 3.25) / 2, 2.6, { w: 600, c: i ? '#000' : TINT, align: 'center' });
    x += ws[i] + 0.4;
  });
  icon(ctx, 'search', x + 1.3, 4.1, 3.2, '#000');
  text(ctx, 'Sounding', 3, 11, 5, { w: 700, lh: 1.1, c: '#000' });
  text(ctx, 'For You', 3, 16.6, 2.6, { c: '#8a8a8e' });
  text(ctx, 'Recently Played', 3, 21.6, 3.3, { w: 700, c: '#000' });
  shelf(ctx, sc, 3, 26.4, RECENT, 16.6, 2, 2.6, ['#000', '#8a8a8e']);
  text(ctx, 'Likes', 3, 52.6, 3.3, { w: 700, c: '#000' });
  icon(ctx, 'chev', 3 + tw('Likes', 3.3, 700) + 0.8, 53.26, 2.8, '#8a8a8e');
  shelf(ctx, sc, 3, 57.4, LIKED, 16.6, 2, 2.6, ['#000', '#8a8a8e']);
  const my = H - 9.8;
  shadow(ctx, sc, 2.2, my, 95.6, 8, 4, 0.8, 3, 'rgba(0,0,0,.16)');
  box(ctx, 2.2, my, 95.6, 8, 4, 'rgba(249,249,251,.97)');
  line(ctx, 0.15, 'rgba(0,0,0,.06)');
  art(ctx, sc, small('essy-wildeburg'), 3.6, my + 1.3, 5.4, 5.4, 1);
  text(ctx, MIX.title, 10.8, my + 1, 2.6, { w: 600, lh: 1.15, c: '#000', max: 72 });
  text(ctx, 'Wildeburg', 10.8, my + 4, 2.6, { lh: 1.15, c: '#8a8a8e' });
  icon(ctx, 'pause', 84.6, my + 2.2, 3.6, '#000');
  icon(ctx, 'ff', 91.4, my + 2.2, 3.6, '#000');
}
function glass(ctx, sc, x, y, w, h, r) {
  shadow(ctx, sc, x, y, w, h, r, 2, 5, 'rgba(0,0,0,.22)');
  rr(ctx, x, y, w, h, r);
  ctx.fillStyle = cssLinear(ctx, 168, x, y, w, h, [[0, 'rgba(150,172,194,.26)'], [0.46, 'rgba(118,140,162,.2)'], [1, 'rgba(90,110,130,.2)']]);
  ctx.fill();
  line(ctx, 0.15, 'rgba(255,255,255,.14)');
  ctx.save();
  ctx.clip();
  ctx.fillStyle = 'rgba(255,255,255,.12)';
  ctx.fillRect(x, y, w, 0.2);
  ctx.restore();
}
function circleBtn(ctx, cx, cy, d, n, is) {
  dot(ctx, cx, cy, d / 2, 'rgba(255,255,255,.16)');
  icon(ctx, n, cx - is / 2, cy - is / 2, is, '#fff');
}
function padPlay(ctx, sc) {
  const S = sc.S;
  sc.layer(ctx, 'play', x => {
    npBg(x, sc, [6, 9], [70, -24, 40]);
    box(x, 47.5, 1.3, 5, 0.7, 0.35, 'rgba(255,255,255,.3)');
    shadow(x, sc, 8.5, 4.4, 26, 26, 1.6, 1.6, 4, 'rgba(0,0,0,.35)');
    art(x, sc, PARIAH, 8.5, 4.4, 26, 26, 1.6);
    text(x, MIX.title, 4.5, 32.6, 3.2, { w: 650, fade: 23.5 });
    text(x, 'Wildeburg', 4.5, 36.6, 3, { c: TINT_T, max: 23.5 });
    circleBtn(x, 30.2, 35.5, 4.6, 'heart', 2.5);
    circleBtn(x, 36.2, 35.5, 4.6, 'more', 2.5);
    transport(x, [7, 18.8, 30.6], 55.6, 5.4, 5.4);
    slider(x, 4.5, 65, 16, 2.6, 0.8, 1.2);
    chip(x, 22.6, 63, 4.8, 'shareplay', 'SharePlay', 2.6, 2.8, 1.4, 1.8, 1, TINT_T);
    const gx = 41.4, gy = 3.4;
    glass(x, sc, gx, gy, 56.2, 65.15, 3.8);
    pills(x, gx + 2.4, gy + 2.6, ['Up Next', 'Comments', 'Tracklist', 'About'], 0, 2.6, 1.25, 1, 0.6);
    text(x, 'Playing from Likes', gx + 2.8, gy + 9.6, 2.6, { c: 'rgba(255,255,255,.62)' });
    text(x, 'Up Next', gx + 2.8, gy + 12.6, 3.8, { w: 700 });
    circleBtn(x, 86.6, 16.4, 4.8, 'shuffle', 2.6);
    circleBtn(x, 92.6, 16.4, 4.8, 'repeat', 2.6);
    text(x, 'Continue Playing', gx + 2.8, gy + 19.6, 2.6, { w: 600, c: 'rgba(255,255,255,.7)' });
    NEXT.forEach((n, i) => {
      const y = 27 + i * 9.4;
      art(x, sc, small(LIKES[n][0]), 44.2, y + 1.3, 6.8, 6.8, 0.9);
      text(x, LIKES[n][1], 53, y + 1.46, 2.8, { w: 600, lh: 1.2, max: 36.6 });
      text(x, LIKES[n][2], 53, y + 4.82, 2.6, { lh: 1.2, c: 'rgba(255,255,255,.62)', max: 36.6 });
      icon(x, 'grab', 91.6, y + 3, 3.4, 'rgba(255,255,255,.5)');
    });
  });
  icon(ctx, 'queue', 4.5, 41.53, 3, 'rgba(255,255,255,.8)');
  text(ctx, S.now, 8.7, 41.4, 2.6, { c: 'rgba(255,255,255,.8)', max: 29.8 });
  mixWave(ctx, 4.5, 45.6, 34, 4.6, S.p);
  box(ctx, 4.5 + 34 * S.p - 0.15, 45.6 - 0.28, 0.3, 5.16, 0.15, '#fff');
  times(ctx, sc, 4.5, 38.5, 51.2, 2.6, 'rgba(255,255,255,.62)');
}

// MARK: Mac
function lights(ctx) {
  ['#ff5f57', '#febc2e', '#28c840'].forEach((c, i) => dot(ctx, 1.9 + 0.675 + i * 2.2, 2.575, 0.675, c));
}
function mac(ctx, sc) {
  const home = sc.v('home'), play = sc.v('play');
  ctx.fillStyle = '#1e1e20';
  ctx.fillRect(0, 0, 100, sc.H);
  const b = sc.v('b');
  if (b < 1) {
    if (play < 1) sc.view(ctx, home, { direct: true }, x => sc.layer(x, 'home', y => macHome(y, sc)));
    sc.view(ctx, play, { s: 1.02 - 0.02 * play }, x => macPlay(x, sc));
  }
  sc.view(ctx, b, { s: 1.02 - 0.02 * b, direct: true }, x => sc.layer(x, 'cues', y => macCues(y, sc)));
}
function macCues(ctx, sc) {
  npBg(ctx, sc, [1, 8], [56, 14, 36], true);
  lights(ctx);
  shadow(ctx, sc, 9.5, 4.6, 25, 25, 1.2, 1.4, 3.6, 'rgba(0,0,0,.35)');
  art(ctx, sc, TRANS, 9.5, 4.6, 25, 25, 1.2);
  text(ctx, 'Transmissions', 5.5, 31.2, 2.8, { w: 650, max: 24 });
  text(ctx, 'Paul Renard', 5.5, 34.7, 2.6, { c: TINT_T, max: 24 });
  circleBtn(ctx, 31.7, 33.5, 3.8, 'heart', 2.1);
  circleBtn(ctx, 36.6, 33.5, 3.8, 'more', 2.1);
  cueStrip(ctx, 5.5, 39.6, 33, 6.4, 1.6);
  transport(ctx, [9, 19.8, 30.6], 50.4, 4.4, 4.4);
  slider(ctx, 5.5, 57.4, 18, 2.2, 0.6, 1);
  chip(ctx, 25.4, 56.2, 4, 'airplay', 'This Mac', 2.2, 2.4, 1.1, 1.5, 0.8, '#fff');
  glass(ctx, sc, 43, 3.6, 53.6, 55.3, 2.8);
  text(ctx, 'Hot Cues', 45.6, 6.4, 2.8, { w: 700 });
  box(ctx, 45.6, 11.2, 48.4, 24, 1.6, 'rgba(255,255,255,.08)');
  cueRows(ctx, 45.6, 11.2, 48.4, 8, 2.2);
}
function macHome(ctx, sc) {
  const H = sc.H;
  ctx.fillStyle = '#1e1e20';
  ctx.fillRect(0, 0, 100, H);
  ctx.fillStyle = '#2b2b2e';
  ctx.fillRect(0, 0, 22, H);
  ctx.fillStyle = 'rgba(0,0,0,.5)';
  ctx.fillRect(21.88, 0, 0.12, H);
  lights(ctx);
  let y = 6.4;
  const item = (n, l, on) => {
    if (on) box(ctx, 1, y, 20, 3.9, 1, 'rgba(255,107,26,.26)');
    icon(ctx, n, 2.1, y + 0.7, 2.5, TINT_T);
    text(ctx, l, 5.8, y + (3.9 - 2.75) / 2, 2.2, { w: 500, c: '#ececec' });
    y += 3.9;
  };
  const head = l => { text(ctx, l, 2.1, y + 1.5, 2.2, { w: 600, c: 'rgba(255,255,255,.42)' }); y += 4.75; };
  item('home', 'Home', true); item('search', 'Search'); item('decks', 'Decks'); item('hw', 'Hardware');
  head('Library'); item('heart', 'Likes'); item('lock', 'Private Shares'); item('mic', 'Artists'); item('sets', 'Sets');
  head('Social'); item('person', 'Profile'); item('comment', 'Messages'); item('people', 'Followers');
  box(ctx, 23.8, 1.3, 13, 4.4, 2.2, 'rgba(255,255,255,.08)');
  ['rw', 'pause', 'ff'].forEach((n, i) => icon(ctx, n, 25.4 + i * 3.6, 2.2, 2.6, 'rgba(255,255,255,.75)'));
  box(ctx, 38.6, 1.2, 46.8, 4.6, 2.3, 'rgba(255,255,255,.08)');
  const t = fit(MIX.title, 2.2, 600, 46.8 - 4 - 4.2), cw = 3 + 1.2 + tw(t, 2.2, 600), lx = 62 - cw / 2;
  art(ctx, sc, small('essy-wildeburg'), lx, 2, 3, 3, 0.5);
  text(ctx, t, lx + 4.2, 1.2 + (4.6 - 2.75) / 2, 2.2, { w: 600 });
  ['airplay', 'list', 'bell'].forEach((n, i) => icon(ctx, n, 87.2 + i * 4.2, 2.2, 2.6, 'rgba(255,255,255,.75)'));
  text(ctx, 'Home', 24.6, 8.8, 3.8, { w: 700 });
  const fw = tw('For You', 2.2, 600) + 3.6, gw = tw('Following', 2.2, 600) + 3.6, sx = 97.6 - gw - 0.6 - fw;
  box(ctx, sx, 9.2, fw, 4.35, 2.175, '#e6e6ea');
  text(ctx, 'For You', sx + fw / 2, 10, 2.2, { w: 600, c: '#111', align: 'center' });
  box(ctx, sx + fw + 0.6, 9.2, gw, 4.35, 2.175, 'rgba(255,255,255,.1)');
  text(ctx, 'Following', sx + fw + 0.6 + gw / 2, 10, 2.2, { w: 600, align: 'center' });
  text(ctx, 'Recently Played', 24.6, 15.4, 2.8, { w: 700 });
  shelf(ctx, sc, 24.6, 19.8, RECENT.slice(0, 5), 15.2, 1.6, 2.2, ['#fff', 'rgba(255,255,255,.55)']);
  text(ctx, 'Likes', 24.6, 43.6, 2.8, { w: 700 });
  shelf(ctx, sc, 24.6, 48, LIKED.slice(0, 5), 15.2, 1.6, 2.2, ['#fff', 'rgba(255,255,255,.55)']);
}
function macPlay(ctx, sc) {
  const S = sc.S;
  sc.layer(ctx, 'play', x => {
    npBg(x, sc, [1, 8], [56, 14, 36]);
    lights(x);
    shadow(x, sc, 9.5, 4.6, 25, 25, 1.2, 1.4, 3.6, 'rgba(0,0,0,.35)');
    art(x, sc, PARIAH, 9.5, 4.6, 25, 25, 1.2);
    text(x, MIX.title, 5.5, 31.2, 2.8, { w: 650, fade: 24 });
    text(x, 'Wildeburg', 5.5, 34.7, 2.6, { c: TINT_T, max: 24 });
    circleBtn(x, 31.7, 33.5, 3.8, 'heart', 2.1);
    circleBtn(x, 36.6, 33.5, 3.8, 'more', 2.1);
    x.fillStyle = 'rgba(255,255,255,.45)';
    for (const [s] of T.slice(1)) x.fillRect(5.5 + 33 * s / D, 46.4, 0.16, 0.9);
    transport(x, [9, 19.8, 30.6], 50.4, 4.4, 4.4);
    const [bx, bw, by] = slider(x, 5.5, 57.4, 18, 2.2, 0.6, 1);
    x.save();
    x.shadowColor = 'rgba(0,0,0,.3)';
    x.shadowBlur = 0.6 * sc.K;
    x.shadowOffsetY = 0.2 * sc.K;
    dot(x, bx + bw * 0.6, by + 0.3, 1, '#fff');
    x.restore();
    chip(x, 25.4, 56.2, 4, 'shareplay', 'SharePlay', 2.2, 2.4, 1.1, 1.5, 0.8, TINT_T);
    glass(x, sc, 43, 3.6, 53.6, 55.3, 2.8);
    pills(x, 0, 5.8, ['Up Next', 'Comments', 'Tracklist', 'About'], 2, 2.2, 1.6, 0.8, 0.8, 69.8);
    text(x, 'All identified', 45.6, 11.6, 2.2, { c: 'rgba(255,255,255,.62)' });
    text(x, '24 tracks', 45.6, 14.2, 2.8, { w: 700 });
    const iw = 1.2 + 2.4 + 0.8 + tw('Identify', 2.2, 600) + 1.6, ix = 94.2 - iw;
    box(x, ix, 12.6, iw, 4.35, 2.175, 'rgba(255,255,255,.14)');
    icon(x, 'identify', ix + 1.2, 13.575, 2.4, '#fff');
    text(x, 'Identify', ix + 4.4, 13.4, 2.2, { w: 600 });
  });
  icon(ctx, 'queue', 5.5, 38.53, 2.5, 'rgba(255,255,255,.8)');
  text(ctx, S.now, 9, 38.4, 2.2, { c: 'rgba(255,255,255,.8)', max: 29.5 });
  mixWave(ctx, 5.5, 41.8, 33, 4, S.p);
  box(ctx, 5.5 + 33 * S.p - 0.15, 41.8 - 0.24, 0.3, 4.48, 0.15, '#fff');
  times(ctx, sc, 5.5, 38.5, 47, 2.2, 'rgba(255,255,255,.7)', 600);
  const y0 = 19, wh = 38.7, off = sc.v('scroll') * 5.4, sep = ' — ';
  ctx.save();
  ctx.beginPath();
  ctx.rect(44.2, y0, 51.2, wh);
  ctx.clip();
  for (let i = 0; i < T.length; i++) {
    const ry = y0 + i * 5.4 - off;
    if (ry + 5.4 < y0 || ry > y0 + wh) continue;
    const a = clamp((1 - (ry + 2.7 - y0) / wh) / 0.14);
    if (a <= 0) continue;
    ctx.globalAlpha = a;
    if (i === S.idx) {
      box(ctx, 44.2, ry, 51.2, 5.4, 1.2, 'rgba(255,255,255,.12)');
      box(ctx, 45.6, ry + 4.6, 48.4 * S.row, 0.3, 0.15, 'rgba(255,255,255,.55)');
    }
    text(ctx, fmt(T[i][0]), 45.6, ry + 1.325, 2.2, { c: 'rgba(255,255,255,.62)' });
    const ar = fit(T[i][2], 2.4, 600, 21.9), rest = 39.8 - tw(ar, 2.4, 600) - tw(sep, 2.4, 600);
    text(ctx, ar + sep + fit(T[i][1], 2.4, 600, rest), 54.2, ry + 1.2, 2.4, { w: 600 });
  }
  ctx.restore();
}

// MARK: Screens
const PAINT = { phone: (c, s) => phone(c, s, false), friend: (c, s) => phone(c, s, true), tv, watch, pad, mac };
const START = { phone: { ph: 'lib', out: 'idle', pick: false, picked: false, b: false }, friend: {}, tv: { tv: 'off', tvb: 'np', b: false }, watch: { w: 'clock' }, pad: { pad: 'home', b: false }, mac: { mac: 'home', b: false } };
function targets(sc) {
  const s = sc.st, go = (k, on, d) => sc.go(k, on ? 1 : 0, d);
  if (sc.name === 'phone') {
    go('lib', s.ph === 'lib', 0.45); go('play', s.ph === 'play' || s.ph === 'list', 0.45); go('L', s.ph === 'list', 0.6); go('out', s.ph === 'out', 0.4);
    go('b', s.b, 0.45); go('pick', s.pick, 0.25); go('picked', s.picked, 0.25); go('toast', s.out === 'toast', 0.6); go('sheet', s.out === 'sheet', 0.6);
    go('r1', s.out === 'idle' || s.out === 'toast' || s.out === 'sheet', 0.35); go('r2', s.out === 'tv', 0.35); go('r3', s.out === 'share', 0.35);
    go('sbd', s.ph === 'lib' && !s.b, 0.4);
  } else if (sc.name === 'tv') {
    const am = s.tvb === 'am';
    go('on', s.tv !== 'off', 0.6); go('sign', s.tv === 'sign', 0.4); go('np', s.tv === 'play', 0.4); go('dj', s.tv === 'play' && (am || s.b), 0.45); go('am', am, 0.5);
  } else if (sc.name === 'watch') {
    go('home', s.w === 'home', 0.35); go('remote', s.w === 'remote', 0.35);
  } else if (sc.name === 'pad') {
    go('home', s.pad === 'home', 0.4); go('play', s.pad === 'play', 0.5); go('b', s.b, 0.45);
  } else if (sc.name === 'mac') {
    go('home', s.mac === 'home', 0.4); go('play', s.mac === 'play', 0.5); go('b', s.b, 0.45);
  }
}
function live(sc) {
  switch (sc.name) {
    case 'phone': return (sc.v('play') > 0 || sc.v('out') > 0) && sc.v('b') < 1;
    case 'friend': return true;
    case 'tv': return sc.v('np') > 0 && sc.v('dj') < 1;
    case 'watch': return sc.v('remote') > 0;
    default: return sc.v('play') > 0 && sc.v('b') < 1;
  }
}

export function createScreens({ base = 'assets/', opaque = false } = {}) {
  shapes();
  const imgs = new Map();
  const S = { sec: 0, whole: -1, p: 0, idx: 0, row: 0, el: '0:00', left: `-${fmt(D)}`, now: `${T[0][2]} - ${T[0][1]}` };
  const all = {};
  const load = file => {
    const r = { im: new Image(), ok: false, users: new Set() };
    r.im.decoding = 'async';
    r.p = new Promise(done => {
      r.im.onload = () => { r.ok = true; for (const sc of r.users) { sc.L = {}; sc.dirty = true; } r.users.clear(); done(); };
      r.im.onerror = () => done();
    });
    r.im.src = base + file;
    imgs.set(file, r);
    return r.p;
  };
  const ready = Promise.all(FILES.map(load)).then(() => undefined);

  function make(name) {
    const { w, h } = SCREENS[name];
    const sc = { name, w, h, H: h / w * 100, st: { ...START[name] }, a: {}, L: {}, dirty: true, vis: true, used: new Set(), cut: null, S, cv: document.createElement('canvas'), tmp: null, bell: [0, 1, 0], wait: -1.2, rang: false, tick: 0 };
    sc.img = file => { const r = imgs.get(file); if (r && r.ok) return r.im; if (r) r.users.add(sc); return null; };
    sc.v = k => (sc.a[k] ? sc.a[k].v : 0);
    sc.go = (k, to, d) => {
      const a = sc.a[k];
      if (!a) { sc.a[k] = { v: to, f: to, to, t: 1, d }; return; }
      if (a.to === to) return;
      a.f = a.v; a.to = to; a.t = 0; a.d = d;
      sc.dirty = true;
    };
    sc.snap = (k, v) => {
      const a = sc.a[k];
      if (a && a.to === v && a.t >= 1) return;
      sc.a[k] = { v, f: v, to: v, t: 1, d: 0.45 };
    };
    sc.layer = (ctx, key, fn) => {
      sc.used.add(key);
      let c = sc.L[key];
      if (!c) {
        c = document.createElement('canvas');
        c.width = sc.cv.width;
        c.height = sc.cv.height;
        const x = c.getContext('2d');
        x.setTransform(sc.K, 0, 0, sc.K, 0, 0);
        fn(x);
        sc.L[key] = c;
      }
      ctx.drawImage(c, 0, 0, 100, sc.H);
    };
    sc.view = (ctx, a, tf, fn) => {
      if (a <= 0) return;
      const move = tf && ((tf.s !== undefined && tf.s !== 1) || tf.dy);
      const place = x => { if (!move) return; if (tf.dy) x.translate(0, tf.dy); if (tf.s !== undefined && tf.s !== 1) { x.translate(50, sc.H / 2); x.scale(tf.s, tf.s); x.translate(-50, -sc.H / 2); } };
      if (a >= 1 || (tf && tf.direct)) { ctx.save(); ctx.globalAlpha = Math.min(1, a); place(ctx); fn(ctx); ctx.restore(); return; }
      if (!sc.tmp || sc.tmp.width !== sc.cv.width || sc.tmp.height !== sc.cv.height) { sc.tmp = document.createElement('canvas'); sc.tmp.width = sc.cv.width; sc.tmp.height = sc.cv.height; }
      const x = sc.tmp.getContext('2d');
      x.setTransform(1, 0, 0, 1, 0, 0);
      x.clearRect(0, 0, sc.tmp.width, sc.tmp.height);
      x.setTransform(sc.K, 0, 0, sc.K, 0, 0);
      x.globalAlpha = 1;
      fn(x);
      ctx.save();
      ctx.globalAlpha = a;
      place(ctx);
      ctx.drawImage(sc.tmp, 0, 0, 100, sc.H);
      ctx.restore();
    };
    sc.size = px => {
      sc.cv.width = Math.max(1, Math.round(px));
      sc.cv.height = Math.max(1, Math.round(px * h / w));
      sc.K = sc.cv.width / 100;
      sc.L = {};
      sc.tmp = null;
      sc.dirty = true;
      const r = CORNER[name] / w * 100, H = sc.H, p = new Path2D();
      const wedge = (x, y, ax, ay, bx, by) => { p.moveTo(x, y); p.lineTo(ax, ay); p.arcTo(x, y, bx, by, r); p.closePath(); };
      wedge(0, 0, r, 0, 0, r);
      wedge(100, 0, 100, r, 100 - r, 0);
      if (name !== 'mac') { wedge(100, H, 100 - r, H, 100, H - r); wedge(0, H, 0, H - r, r, H); }
      sc.cut = p;
    };
    sc.size(PX[name]);
    targets(sc);
    return sc;
  }
  for (const name in SCREENS) all[name] = make(name);

  function paint(sc) {
    const ctx = sc.cv.getContext('2d');
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = 1;
    ctx.clearRect(0, 0, sc.cv.width, sc.cv.height);
    F = sc.w / 100;
    ctx.save();
    ctx.setTransform(sc.K, 0, 0, sc.K, 0, 0);
    sc.used.clear();
    PAINT[sc.name](ctx, sc);
    ctx.globalAlpha = 1;
    ctx.globalCompositeOperation = 'destination-out';
    ctx.fillStyle = '#000';
    ctx.fill(sc.cut);
    if (opaque) { ctx.globalCompositeOperation = 'destination-over'; ctx.fillRect(0, 0, 100, sc.H); }
    ctx.restore();
    let moving = false;
    for (const k in sc.a) if (sc.a[k].t < 1) { moving = true; break; }
    if (!moving) {
      for (const k in sc.L) if (!sc.used.has(k) && !k.startsWith('sign')) delete sc.L[k];
      sc.tmp = null;
    }
  }
  const get = name => { const sc = all[name]; if (!sc) throw new Error(`Unknown screen: ${name}`); return sc; };
  setTimeout(() => { F = all.tv.w / 100; tvSign(document.createElement('canvas').getContext('2d'), all.tv); }, 1800);

  return {
    ready,
    canvas: name => get(name).cv,
    resize(name, px) { get(name).size(px); },
    set(name, state) {
      const sc = get(name);
      Object.assign(sc.st, state);
      targets(sc);
    },
    time(sec) {
      sec = clamp(sec, 0, D - 1);
      S.sec = sec;
      const whole = Math.floor(sec);
      if (whole === S.whole) return;
      S.whole = whole;
      S.p = sec / D;
      S.el = fmt(sec);
      S.left = `-${fmt(D - sec)}`;
      let idx = 0;
      while (idx < T.length - 1 && T[idx + 1][0] <= sec) idx++;
      const end = idx < T.length - 1 ? T[idx + 1][0] : D;
      S.row = (sec - T[idx][0]) / (end - T[idx][0]);
      S.idx = idx;
      S.now = `${T[idx][2]} - ${T[idx][1]}`;
      const row = Math.max(0, idx - 1), ph = all.phone, mc = all.mac;
      if (ph.v('play') > 0 && ph.v('L') > 0 && ph.v('b') < 1 && ph.vis) ph.go('scroll', row, 0.45); else ph.snap('scroll', row);
      if (mc.v('play') > 0 && mc.vis) mc.go('scroll', row, 0.45); else mc.snap('scroll', row);
      for (const name in all) if (live(all[name])) all[name].dirty = true;
    },
    show(name, visible) { get(name).vis = !!visible; },
    step(dt) {
      const out = [];
      for (const name in all) {
        const sc = all[name];
        for (const k in sc.a) {
          const a = sc.a[k];
          if (a.t >= 1) continue;
          a.t = Math.min(1, a.t + dt / a.d);
          a.v = a.f + (a.to - a.f) * ease(a.t);
          sc.dirty = true;
        }
        if (name === 'tv') chime(sc, dt);
        if (sc.dirty && sc.vis) { paint(sc); sc.dirty = false; out.push(name); }
      }
      return out;
    },
    hit(name, x, y) {
      if (name !== 'phone') return null;
      const sc = all.phone;
      if (sc.st.ph !== 'list' || sc.st.b) return null;
      const cx = x / 3, cy = y / 3;
      if (cx < 3 || cx > 97 || cy < 57 || cy > 158) return null;
      const i = Math.floor((cy - 57 + sc.v('scroll') * 13.4) / 13.4);
      return i >= 0 && i < T.length ? { track: i } : null;
    },
  };
}
