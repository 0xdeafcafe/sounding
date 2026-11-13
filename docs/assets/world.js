import { M, lathe, disc, rbox, tube, quad, merge, knurl, slab, tubeFill, tubeIndex } from './gl.js';

const srgb = v => (v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
const C = (r, g, b) => [srgb(r), srgb(g), srgb(b)];
const C8 = (r, g, b) => C(r / 255, g / 255, b / 255);
const HX = h => C8(parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16));

export const PAL = {
  paper: HX('#f6f1e8'),
  felt: [0.0105, 0.0088, 0.0075],
  massA: [C(0.99, 0.79, 0.64), C(0.92, 0.82, 0.88), C(0.77, 0.89, 0.84)],
  massB: [C(0.42, 0.18, 0.08), C(0.24, 0.13, 0.22), C(0.09, 0.25, 0.23)],
  inkA: [C8(219, 84, 15), C8(179, 128, 31), C8(20, 117, 105), C8(168, 54, 61), C8(69, 46, 36)],
  inkB: [C8(255, 107, 26), C8(245, 191, 102), C8(110, 204, 179), C8(250, 153, 143), C8(242, 230, 209)],
  body: HX('#1d1a18'),
  face: HX('#161412'),
  rubber: [0.02, 0.018, 0.017],
  cream: HX('#e9e2d8'),
  copper: [0.95, 0.60, 0.44],
  jack: [0.87, 0.34, 0.16],
  jackHi: [0.93, 0.41, 0.2],
  alu: [0.78, 0.77, 0.75],
  steel: [0.62, 0.62, 0.63],
  titan: [0.20, 0.19, 0.18],
};

export const L = {
  deckX: 0.365, platterDX: -0.03, yPlinth: 0.074, yPlatter: 0.0905, yRecord: 0.0933, recordR: 0.1505, labelR: 0.05,
  mixerY: 0.093, mixerW: 0.26, mixerD: 0.355, knobX: 0.066, knobZ: [-0.094, -0.056, -0.018, 0.024], knobR: 0.0125,
  chanZ: 0.124, chanTravel: 0.054, xfZ: 0.154, xfTravel: 0.074, socket: [0, 0.111, -0.140], jackL: 0.118, padH: 0.003,
  pitchX: 0.198, pitchZ: 0.075, pitchTravel: 0.045,
  phone: { w: 0.0716, d: 0.1496, h: 0.0082, sw: 0.0664, sh: 0.1444 },
  ipad: { x: 3.2, z: 0.25, a: 0.1, w: 0.2476, d: 0.1785, h: 0.0061, sw: 0.235, sh: 0.166 },
  mac: { x: 3.45, z: 1.55, a: 0.25, w: 0.304, d: 0.215, h: 0.0113, sw: 0.286, sh: 0.179 },
  macB: { x: 0.52, z: -0.47, a: 0.1 }, ipadB: { x: 2.3, z: -0.35 }, crateB: [-1.25, 0.45],
  watch: { w: 0.038, d: 0.04634, h: 0.0105, sw: 0.0312, sh: 0.0382 },
  tv: { x: 2.15, z: 1.33, w: 0.82, hgt: 0.46125, t: 0.02, lift: 0.055, sw: 0.8036, sh: 0.44485 },
  phoneHome: [0.42, 1.0, 0], phoneTV: [1.9, 1.775, -0.14], watchPos: [2.17, 1.8, 0.16], friendPos: [2.36, 1.81, 0.2], friendOff: [3.5, 2.05, 0.9],
  endTip: [-0.076, 2.146], endBack: [-0.1633, 2.2333],
};

const JL = L.jackL, RT = 0.0269 * JL;
L.sock = { ri: RT * 1.5, ro: RT * 2.5, h: RT * 0.6 };
L.jack = { len: 1.56 * JL, back: 1.59 * JL, rim: L.socket[1] + L.sock.h, depth: 0.84 * JL, grip: 0.0528 * JL };

export const PADS = [
  [-0.375, 0.0, 0.3, 0, 0.7], [0.385, 0.01, 0.295, 2, 2.8],
];

export const SLEEVES = ['paul-renard-transmissions', 'obskur-luuk-van-dijk', 'pegassi-jump-4-joy', 'hearthug-computerized-souls', 'jungle-by-night-oog-om-oog', 'angel-dlite-club-smut', 'kyle-starkey-milion', 'essy-wildeburg', 'kyle-starkey-boom-boom-jam', 'benwal-just-go', 'benwal-dgtl', 'pegassi-essential-mix'];

const sm01 = t => { t = Math.min(1, Math.max(0, t)); return t * t * (3 - 2 * t); };
const norm = v => { const l = Math.hypot(v[0], v[1], v[2]) || 1; return [v[0] / l, v[1] / l, v[2] / l]; };
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];

function catmull(way, step = 0.012) {
  const out = [];
  const P = [way[0], ...way, way[way.length - 1]];
  for (let i = 1; i < P.length - 2; i++) {
    const p0 = P[i - 1], p1 = P[i], p2 = P[i + 1], p3 = P[i + 2];
    const n = Math.max(2, Math.ceil(Math.hypot(p2[0] - p1[0], p2[1] - p1[1], p2[2] - p1[2]) / step));
    for (let k = i === 1 ? 0 : 1; k <= n; k++) {
      const t = k / n, t2 = t * t, t3 = t2 * t;
      out.push([0, 1, 2].map(a => 0.5 * (2 * p1[a] + (-p0[a] + p2[a]) * t + (2 * p0[a] - 5 * p1[a] + 4 * p2[a] - p3[a]) * t2 + (-p0[a] + 3 * p1[a] - 3 * p2[a] + p3[a]) * t3)));
    }
  }
  return out;
}

function blobK(seed, turn) {
  const f = (((turn % 1) + 1) % 1) * 9, j = Math.floor(f), t = f - j;
  const key = q => { const h = Math.sin(seed * 12.9898 + (((q % 9) + 9) % 9) * 78.233) * 43758.5453; return 0.8 + 0.36 * (h - Math.floor(h)); };
  const k0 = key(j - 1), k1 = key(j), k2 = key(j + 1), k3 = key(j + 2);
  return 0.5 * (2 * k1 + (-k0 + k2) * t + (2 * k0 - 5 * k1 + 4 * k2 - k3) * t * t + (-k0 + 3 * k1 - 3 * k2 + k3) * t * t * t);
}

function blob(cx, cz, r, seed, n = 120) {
  const pts = [];
  for (let i = 0; i < n; i++) {
    const a = (i / n) * Math.PI * 2 + seed;
    const k = blobK(seed, i / n);
    pts.push([cx + Math.cos(a) * r * k, cz + Math.sin(a) * r * k]);
  }
  return pts;
}

export function padAt(x, z, soft = 0.012) {
  let h = 0;
  for (const [cx, cz, r, , seed] of PADS) {
    const dx = x - cx, dz = z - cz, d = Math.hypot(dx, dz);
    if (d > r * 1.2 + soft) continue;
    const edge = r * blobK(seed, (Math.atan2(dz, dx) - seed) / (Math.PI * 2));
    h = Math.max(h, L.padH * sm01((edge + soft * 0.4 - d) / soft));
  }
  return h;
}

function faceplate() {
  const k = 6000;
  const W = Math.round(L.mixerW * k), H = Math.round(L.mixerD * k);
  const cv = document.createElement('canvas');
  cv.width = W; cv.height = H;
  const x = cv.getContext('2d');
  const X = m => (m / L.mixerW + 0.5) * W, Z = m => (m / L.mixerD + 0.5) * H, S = m => m * k;
  const ink = 'rgba(233,226,216,0.92)', dim = 'rgba(233,226,216,0.5)';
  const font = (mm, w = 600) => { x.font = `${w} ${S(mm / 1000)}px -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif`; };
  x.textBaseline = 'middle';
  x.lineCap = 'round';
  for (const sx of [-1, 1]) {
    L.knobZ.forEach((z, r) => {
      const big = r === 3;
      const rad = big ? 0.0205 : 0.0175;
      x.strokeStyle = dim; x.lineWidth = S(0.0005);
      for (let t = 0; t <= 10; t++) {
        const a = (-135 + t * 27) * Math.PI / 180;
        const s = Math.sin(a), c = -Math.cos(a);
        const l = t % 5 === 0 ? 0.003 : 0.0016;
        x.beginPath(); x.moveTo(X(sx * L.knobX + s * rad), Z(z + c * rad)); x.lineTo(X(sx * L.knobX + s * (rad + l)), Z(z + c * (rad + l))); x.stroke();
      }
    });
    x.strokeStyle = dim; x.lineWidth = S(0.0004);
    for (let t = 0; t <= 10; t++) {
      const z = L.chanZ - (t / 10) * L.chanTravel;
      const l = t % 5 === 0 ? 0.006 : 0.0035;
      x.beginPath(); x.moveTo(X(sx * L.knobX - 0.016), Z(z)); x.lineTo(X(sx * L.knobX - 0.016 + l), Z(z)); x.stroke();
      x.beginPath(); x.moveTo(X(sx * L.knobX + 0.016), Z(z)); x.lineTo(X(sx * L.knobX + 0.016 - l), Z(z)); x.stroke();
    }
  }
  x.fillStyle = ink; x.textAlign = 'center';
  font(5.6);
  ['High', 'Mid', 'Low', 'Filter'].forEach((t, r) => x.fillText(t, X(0), Z(L.knobZ[r] + (r === 3 ? 0.03 : 0.022))));
  font(11, 700);
  x.fillText('A', X(-L.knobX), Z(-0.142));
  x.fillText('B', X(L.knobX), Z(-0.142));
  font(4.2);
  x.fillStyle = dim;
  x.fillText('Aux', X(0), Z(-0.112));
  x.fillStyle = ink;
  font(8, 700);
  x.textAlign = 'right'; x.fillText('Listening', X(-0.049), Z(L.xfZ + 0.0005));
  x.textAlign = 'left'; x.fillText('DJing', X(0.05), Z(L.xfZ + 0.0005));
  x.strokeStyle = dim; x.lineWidth = S(0.0004);
  for (let t = 0; t <= 8; t++) { const px = (t / 8 - 0.5) * L.xfTravel; const l = t % 4 === 0 ? 0.005 : 0.003; x.beginPath(); x.moveTo(X(px), Z(L.xfZ - 0.011)); x.lineTo(X(px), Z(L.xfZ - 0.011 - l)); x.stroke(); }
  return cv;
}

export function buildWorld(R, base) {
  const items = [];
  const add = (geo, model, mat) => { const it = { mesh: geo.vao ? geo : R.mesh(geo), model: model || M.id(), kind: 0, baseA: [1, 1, 1], rough: 0.6, ...mat }; items.push(it); return it; };
  const S = {
    fade: 0, xf: 0, angle: [0, 0], pitch: [0, 0], knob: [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5], knobShown: [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5], chan: [1, 1], plug: 0, level: [0, 0], beat: 0,
    phone: [...L.phoneHome, 0, 0], friend: [...L.friendOff, 0, 0], motor: [1, 1], tvGlow: [0, 0, 0], phoneGlow: 0, time: 0,
    arm: [0, 0], w: [3.49, 3.49], dt: 0.016, crown: 0, beats: 0, live: 0,
    room: 0, power: 1, glow: 1, front: 1e6, jack: { tip: [L.socket[0], L.jack.rim - L.jack.depth, L.socket[2]], axis: [0, 1, 0] },
  };
  const details = [];
  const detail = (parent, geo, local, mat) => { const it = add(geo, M.chain(parent.model, local), mat); details.push([it, parent, local]); return it; };
  const dyn = [];
  const occ = [];
  const OC = (x, z, hx, hz, r, h, a = 0, s = 1) => { const o = { x, z, hx, hz, r, h, a, s }; occ.push(o); return o; };

  add(quad(90, 90), M.id(), { kind: 1, baseA: PAL.paper, baseB: PAL.felt, cast: false });
  PADS.forEach(([x, z, r, tone, seed], i) => add(slab(blob(x, z, r, seed), L.padH + i * 0.0004, 0.0014, 4), M.id(), { kind: 7, baseA: PAL.massA[tone], baseB: PAL.massB[tone], rough: 0.98 }));

  const plinthG = R.mesh(rbox(0.45, 0.062, 0.355, 0.024, 0.005, 8, 4));
  const footG = R.mesh(lathe([[0.024, 0], [0.028, 0.004], [0.028, 0.012]], 24));
  const platterG = R.mesh(lathe([[0.158, 0], [0.166, 0.0015], [0.166, 0.013], [0.1638, 0.0152], [0.157, 0.0165], [0, 0.0165]], 128));
  const matG = R.mesh(disc(0.004, 0.1548, 96, 0.0006));
  const recEdgeG = R.mesh(lathe([[0.1496, 0.0010], [0.1508, 0.0019], [0.1496, 0.0028]], 128));
  const recTopG = R.mesh(disc(0.0036, 0.1500, 160, 0.0028));
  const labelG = R.mesh(disc(0.0036, L.labelR, 72, 0.00296));
  const spindleG = R.mesh(lathe([[0.0034, 0], [0.0034, 0.0118], [0.0026, 0.0134], [0, 0.0136]], 20));
  const pivotG = R.mesh(lathe([[0.027, 0], [0.027, 0.006], [0.024, 0.008], [0.013, 0.008], [0.013, 0.040], [0.0175, 0.040], [0.0175, 0.055], [0.0145, 0.057], [0, 0.057]], 40));
  const cwG = R.mesh(lathe([[0, 0], [0.014, 0], [0.0165, 0.003], [0.0165, 0.031], [0.014, 0.034], [0, 0.034]], 36));
  const shellG = R.mesh(rbox(0.016, 0.003, 0.05, 0.003, 0.001, 4, 2));
  const cartG = R.mesh(rbox(0.013, 0.0105, 0.019, 0.0015, 0.0008, 3, 2));
  const btnG = R.mesh(rbox(0.052, 0.005, 0.03, 0.004, 0.0015, 5, 3));
  const smallBtnG = R.mesh(rbox(0.022, 0.004, 0.013, 0.003, 0.001, 4, 2));
  const lampG = R.mesh(lathe([[0.011, 0], [0.011, 0.010], [0.0078, 0.0165], [0, 0.0165]], 28));
  const slotG = R.mesh(rbox(0.006, 0.0006, 0.104, 0.003, 0.0002, 4, 1));
  const pcapG = R.mesh(rbox(0.026, 0.010, 0.012, 0.002, 0.0012, 4, 3));
  const ledG = R.mesh(disc(0, 0.0022, 16, 0));

  const labels = [R.image(base + 'music/essy-wildeburg.webp'), R.image(base + 'music/paul-renard-transmissions.webp')];
  const decks = [];
  for (let i = 0; i < 2; i++) {
    const ox = (i ? 1 : -1) * L.deckX;
    const T0 = M.t(ox, 0, 0);
    add(plinthG, M.t(ox, 0.012, 0), { baseA: PAL.body, rough: 0.56 });
    OC(ox, 0, 0.225, 0.1775, 0.024, 0.074);
    for (const [fx, fz] of [[-0.18, -0.135], [0.18, -0.135], [-0.18, 0.135], [0.18, 0.135]]) add(footG, M.t(ox + fx, 0, fz), { baseA: PAL.rubber, rough: 0.7 });
    const px = ox + L.platterDX;
    const lampX = px + 0.178 * Math.cos(215 * Math.PI / 180), lampZ = -0.178 * Math.sin(215 * Math.PI / 180);
    const platter = add(platterG, null, { kind: 4, baseA: PAL.alu, metal: 1, rough: 0.34, p: [0, 0, 0, 0], q: [0, 0, lampX, lampZ], spin: true });
    const mat = add(matG, null, { baseA: PAL.massA[i ? 2 : 0], baseB: PAL.massB[i ? 2 : 0], rough: 0.95, cast: false });
    const edge = add(recEdgeG, null, { baseA: [0.012, 0.012, 0.012], rough: 0.25, spin: true });
    const top = add(recTopG, null, { kind: 2, baseA: [0.011, 0.011, 0.011], cast: false });
    const label = add(labelG, null, { kind: 3, baseA: PAL.cream, rough: 0.55, tex: labels[i], cast: false, p: [0, 0.08, 0, 0] });
    add(spindleG, M.t(px, L.yPlatter, 0), { baseA: PAL.steel, metal: 1, rough: 0.25 });
    decks.push({ ox, px, parts: [platter, mat], rec: [edge, top, label], sp: [0, 0, 0, 0] });

    const P = [ox + 0.172, -0.105], Cc = [px, 0];
    const r1 = 0.118, r2 = 0.232;
    const dx = P[0] - Cc[0], dz = P[1] - Cc[1], d = Math.hypot(dx, dz);
    const a = (r1 * r1 - r2 * r2 + d * d) / (2 * d), h = Math.sqrt(r1 * r1 - a * a);
    const st = [Cc[0] + (a * dx) / d - (h * dz) / d, Cc[1] + (a * dz) / d + (h * dx) / d];
    add(pivotG, M.t(P[0], L.yPlinth, P[1]), { baseA: PAL.alu, metal: 1, rough: 0.3 });
    const wandPts = [[0, 0.002, -0.075], [0, 0, 0], [0, -0.0065, (r2 - 0.018) / 2], [0, -0.014, r2 - 0.018]].flatMap((p, k, arr) => { if (k === arr.length - 1) return [p]; const q = arr[k + 1]; return [p, [(p[0] + q[0]) / 2, (p[1] + q[1]) / 2, (p[2] + q[2]) / 2]]; });
    const wand = add(tube(catmull(wandPts, 0.006), 0.0032, 16), null, { baseA: PAL.copper, metal: 1, rough: 0.24 });
    const cw = add(cwG, null, { baseA: PAL.alu, metal: 1, rough: 0.28 });
    const shell = add(shellG, null, { baseA: PAL.body, rough: 0.4 });
    const cart = add(cartG, null, { baseA: PAL.copper, metal: 1, rough: 0.3 });
    decks[i].arm = { P, play: Math.atan2(st[0] - P[0], st[1] - P[1]), rest: Math.atan2(-0.052, 0.9986), parts: [[wand, M.id()], [cw, M.chain(M.t(0, 0.0013, -0.045), M.ry(Math.PI), M.rx(Math.PI / 2))], [shell, M.t(0, -0.0163, r2 - 0.006)], [cart, M.t(0, -0.0267, r2)]] };
    detail(cart, tube([[0, 0, 0.004], [0, -0.0028, 0.007]], 0.00045, 8), M.id(), { baseA: PAL.steel, metal: 1, rough: 0.18 });
    const screws = [];
    for (const x of [-0.208, 0.208]) for (const z of [-0.158, 0.158]) screws.push([lathe([[0.0024, 0], [0.0027, 0.0004], [0.0024, 0.001], [0, 0.001]], 12), M.t(ox + x, L.yPlinth, z)]);
    add(merge(screws), M.id(), { baseA: PAL.steel, metal: 0.9, rough: 0.34 });
    add(rbox(0.446, 0.003, 0.351, 0.023, 0.001, 8, 3), M.t(ox, 0.023, 0), { baseA: [0.007, 0.007, 0.007], rough: 0.8 });
    add(btnG, M.t(ox - 0.185, L.yPlinth, 0.151), { baseA: PAL.face, rough: 0.42 });
    decks[i].led = add(ledG, M.t(ox - 0.202, L.yPlinth + 0.0052, 0.143), { kind: 5, baseA: [0, 0, 0], emitA: [1.6, 0.5, 0.1], emitB: [3.2, 0.9, 0.16], p: [1, 0, 0, 0], cast: false });
    add(smallBtnG, M.t(ox - 0.14, L.yPlinth, 0.158), { baseA: PAL.face, rough: 0.42 });
    add(smallBtnG, M.t(ox - 0.113, L.yPlinth, 0.158), { baseA: PAL.face, rough: 0.42 });
    add(lampG, M.t(lampX, L.yPlinth, lampZ), { baseA: PAL.alu, metal: 1, rough: 0.3 });
    add(slotG, M.t(ox + L.pitchX, L.yPlinth, L.pitchZ), { baseA: [0.004, 0.004, 0.004], rough: 0.8, cast: false });
    const pcap = add(pcapG, null, { baseA: PAL.cream, rough: 0.45 });
    decks[i].pcap = pcap;
    decks[i].lamp = [lampX, L.yPlinth + 0.012, lampZ];
  }

  const face = R.texture(faceplate());
  add(rbox(L.mixerW, 0.083, L.mixerD, 0.012, 0.004, 6, 4), M.t(0, 0.010, 0), { kind: 3, baseA: PAL.face, rough: 0.46, tex: face, p: [0, 0.5, 0, 0], q: [L.socket[0], L.socket[2], L.sock.ri * 0.98, 0] });
  OC(0, 0, L.mixerW / 2, L.mixerD / 2, 0.012, 0.093);
  const knobG = R.mesh(lathe([[0.0125, 0], [0.0125, 0.003], [0.0104, 0.0046], [0.0098, 0.019], [0.0086, 0.0206], [0, 0.0206]], 40));
  const knobs = [];
  for (let c = 0; c < 2; c++) for (let r = 0; r < 4; r++) {
    const big = r === 3;
    knobs.push({ it: add(knobG, null, big ? { kind: 6, baseA: PAL.copper, metal: 1, rough: 0.3, p: [34, 0.0028, 0.005, 0.0011] } : { kind: 6, baseA: PAL.rubber, rough: 0.5, p: [30, 0.0028, 0.005, 0.0011] }), x: (c ? 1 : -1) * L.knobX, z: L.knobZ[r], s: big ? 1.3 : 1 });
  }
  const ledSegG = R.mesh(rbox(0.0085, 0.0012, 0.008, 0.001, 0.0004, 3, 1));
  const leds = [[], []];
  for (let c = 0; c < 2; c++) for (let k = 0; k < 9; k++) {
    const col = k < 6 ? [0.22, 1.5, 1.05] : k < 8 ? [2.2, 1.4, 0.35] : [2.6, 0.55, 0.1];
    leds[c].push(add(ledSegG, M.t((c ? 1 : -1) * 0.017, L.mixerY, 0.036 - k * 0.0142), { kind: 5, baseA: [0.02, 0.02, 0.02], emitA: col, p: [0, 0, 0, 0], cast: false }));
  }
  const chSlotG = R.mesh(rbox(0.0045, 0.0005, L.chanTravel + 0.008, 0.002, 0.0002, 3, 1));
  const capG = R.mesh(rbox(0.023, 0.0105, 0.0115, 0.002, 0.0014, 4, 3));
  const chans = [];
  for (let c = 0; c < 2; c++) {
    add(chSlotG, M.t((c ? 1 : -1) * L.knobX, L.mixerY, L.chanZ - L.chanTravel / 2), { baseA: [0.003, 0.003, 0.003], rough: 0.8, cast: false });
    chans.push(add(capG, null, { baseA: PAL.cream, rough: 0.42 }));
  }
  add(rbox(L.xfTravel + 0.012, 0.0005, 0.005, 0.002, 0.0002, 3, 1), M.t(0, L.mixerY, L.xfZ), { baseA: [0.003, 0.003, 0.003], rough: 0.8, cast: false });
  const xfCap = add(rbox(0.014, 0.015, 0.03, 0.0022, 0.002, 4, 4), null, { baseA: PAL.copper, metal: 1, rough: 0.26 });
  for (const cap of [...chans, xfCap, ...decks.map(d => d.pcap)]) {
    const ribs = [];
    for (let n = -2; n <= 2; n++) ribs.push([rbox(0.009, 0.0004, 0.00065, 0.0002, 0.0001, 2, 1), M.t(0, cap === xfCap ? 0.015 : 0.0105, n * 0.0018)]);
    detail(cap, merge(ribs), M.id(), { baseA: PAL.rubber, rough: 0.78, cast: false });
  }
  const SK = L.sock;
  const bush = [[SK.ro, L.mixerY - L.socket[1]]];
  for (let i = 0; i <= 18; i++) { const a = (i / 18) * Math.PI; bush.push([(SK.ri + SK.ro) / 2 + ((SK.ro - SK.ri) / 2) * Math.cos(a), SK.h * Math.pow(Math.sin(a), 0.72)]); }
  bush.push([SK.ri, L.mixerY - L.socket[1]]);
  add(lathe(bush, 72, 50), M.t(...L.socket), { kind: 8, baseA: PAL.jackHi, metal: 1, rough: 0.13, p: [0, 0, 0, 0] });
  const well = add(lathe([[SK.ri * 0.985, -0.0008], [SK.ri * 0.985, -0.098], [0, -0.098]], 48), M.t(...L.socket), { kind: 5, baseA: [0.05, 0.02, 0.01], emitA: [3.0, 0.78, 0.13], p: [0.3, 0.03, 0, 0], cast: false });

  const jy = y => y < 0.56 ? y * 1.5 : 0.84 + (y - 0.56) * (0.774 / 0.494);
  const P = pts => pts.map(([y, r]) => [r * JL, jy(y) * JL]);
  const rt = 0.0269;
  const tipG = lathe(P([[0, 0], [0.0015, 0.006], [0.005, 0.0115], [0.011, 0.0175], [0.018, 0.0222], [0.026, 0.0256], [0.034, 0.0272], [0.041, 0.0272], [0.047, 0.0258], [0.052, 0.0225], [0.056, 0.019], [0.060, 0.0172], [0.068, 0.0172], [0.072, 0.019], [0.077, 0.024], [0.082, 0.0282], [0.086, rt], [0.090, rt]]), 80, 42);
  const band = (y0, y1) => lathe(P([[y0, rt - 0.0006], [y0 + 0.0008, rt - 0.0016], [y1 - 0.0008, rt - 0.0016], [y1, rt - 0.0006]]), 64, 30);
  const ringP = (y0, y1) => lathe(P([[y0, rt - 0.0012], [y0 + 0.0012, rt], [y1 - 0.0012, rt], [y1, rt - 0.0012]]), 80, 30);
  const bootEnd = 0.036;
  const boot = [[0.930, 0.039]];
  for (let i = 0; i <= 48; i++) {
    const t = i / 48;
    const rib = t > 0.08 && t < 0.92 ? 0.0016 * (0.5 - 0.5 * Math.cos(t * 12 * Math.PI)) : 0;
    boot.push([0.934 + t * 0.118, 0.0385 + (bootEnd - 0.0385) * sm01(t) - rib]);
  }
  boot.push([1.054, bootEnd - 0.004], [1.054, 0.012]);
  const jackG = [
    [R.mesh(merge([[tipG], [ringP(0.099, 0.200)]])), { kind: 8, baseA: PAL.jackHi, metal: 1, rough: 0.12, p: [0, 0, 0, 0] }],
    [R.mesh(merge([[band(0.090, 0.099)], [band(0.200, 0.209)]])), { kind: 0, baseA: [0.012, 0.011, 0.01], rough: 0.36 }],
    [R.mesh(merge([[lathe(P([[0.209, rt - 0.0012], [0.2102, rt], [0.560, rt], [0.562, 0.033], [0.570, 0.0455], [0.573, 0.047], [0.597, 0.047], [0.600, 0.0455], [0.602, 0.0425], [0.611, 0.0425], [0.613, 0.045], [0.618, 0.0515], [0.621, 0.0528], [0.640, 0.0528]]), 96, 34)], [lathe(P([[0.888, 0.0528], [0.916, 0.0528], [0.922, 0.051], [0.932, 0.044], [0.934, 0.040], [0.934, 0.030]]), 96, 34)]])), { kind: 8, baseA: PAL.jack, metal: 1, rough: 0.24, p: [0.2, 0, 0, 0] }],
    [R.mesh(knurl(jy(0.640) * JL, jy(0.888) * JL, 0.0528 * JL, 0.0026 * JL, 44, 4)), { kind: 8, baseA: PAL.jack, metal: 1, rough: 0.3, p: [0, 0, 0, 0] }],
    [R.mesh(lathe(P(boot), 48, 40)), { kind: 0, baseA: [0.014, 0.013, 0.012], rough: 0.8 }],
  ];
  const jack = jackG.map(([mesh, mat]) => add(mesh, null, mat));
  const tb = [L.endTip[0], L.endTip[1]], bb = [L.endBack[0], L.endBack[1]];
  const endYaw = Math.atan2(bb[0] - tb[0], bb[1] - tb[1]);
  tb[0] -= Math.sin(endYaw) * 0.56 * JL; tb[1] -= Math.cos(endYaw) * 0.56 * JL;
  const endR = L.jack.grip;
  const endM = M.chain(M.t(tb[0], endR, tb[1]), M.ry(endYaw), M.rx(Math.PI / 2));
  jackG.forEach(([mesh, mat]) => add(mesh, endM, mat));
  OC((tb[0] + bb[0]) / 2 + Math.sin(endYaw) * 0.02, (tb[1] + bb[1]) / 2 + Math.cos(endYaw) * 0.02, endR * 0.8, 0.03, endR * 0.6, endR * 1.4, endYaw, 0.8);

  const RSF = 0.0016, RSB = 0.00125, RB = RSB / Math.sin(Math.PI / 5);
  const TH = [162, 234, 90, 306, 18].map(d => d * Math.PI / 180);
  const TW = (Math.PI * 2) / 0.05;
  const anchor = [1.08, 0.006, -0.38];
  const way = [
    anchor, [1.38, 0.0025, -0.49], [1.72, 0, -0.36], [1.75, 0, -0.02], [1.46, 0, 0.02], [1.04, 0, -0.02], [0.86, 0, -0.02], [0.80, 0, -0.19], [0.745, 0, -0.1], [0.775, 0, 0.2], [0.74, 0, 0.6], [0.77, 0, 0.95], [0.74, 0, 1.3], [0.95, 0, 1.72], [1.4, 0, 2.0],
    [1.9, 0, 2.1], [2.3, 0, 2.1], [2.65, 0, 2.04], [2.9, 0, 2.2], [2.66, 0, 2.5], [1.7, 0, 2.62], [0.75, 0, 2.52], [0.42, 0, 2.38], [0.18, 0, 2.31],
    [0.0, 0, 2.34], [-0.12, 0, 2.37], [-0.2, 0, 2.35], [-0.215, 0, 2.3], [bb[0] + Math.sin(endYaw) * 0.03, 0.003, bb[1] + Math.cos(endYaw) * 0.03], [bb[0] - Math.sin(endYaw) * 0.004, endR - RSB - RB, bb[1] - Math.cos(endYaw) * 0.004],
  ];
  const path = catmull(way, 0.011);
  const total = path.length;
  const anchorT = norm([path[1][0] - path[0][0], path[1][1] - path[0][1], path[1][2] - path[0][2]]);
  let air = 0;
  while (air < total - 1 && path[air][1] > 0.004) air++;
  const arc = [0];
  for (let i = 1; i < total; i++) arc.push(arc[i - 1] + Math.hypot(path[i][0] - path[i - 1][0], path[i][1] - path[i - 1][1], path[i][2] - path[i - 1][2]));
  const tan = path.map((p, i) => { const a = path[Math.max(0, i - 1)], b = path[Math.min(total - 1, i + 1)]; return norm([b[0] - a[0], b[1] - a[1], b[2] - a[2]]); });
  const lat = tan.map(t => { const l = Math.hypot(t[0], t[2]) || 1; return [t[2] / l, 0, -t[0] / l]; });
  const carryN = (n, t) => { const d = n[0] * t[0] + n[1] * t[1] + n[2] * t[2]; return norm([n[0] - t[0] * d, n[1] - t[1] * d, n[2] - t[2] * d]); };
  for (let i = air - 1; i >= 0; i--) lat[i] = carryN(lat[i + 1], tan[i]);
  const twistAt = d => { const x = Math.max(0, d); return TW * x * x / (x + 0.07); };
  const strand = (s, c, t, n, g, twist) => {
    let b = cross(n, t);
    if (b[1] < 0) b = [-b[0], -b[1], -b[2]];
    const th = TH[s] + twist, ca = Math.cos(th) * RB, sa = Math.sin(th) * RB;
    const fl = (s - 2) * RSF * 2;
    const low = 1 - sm01(c[1] / 0.03);
    const lift = (RB + RSB) * (1 - g) + RSF * g;
    return [c[0] + (n[0] * ca + b[0] * sa) * (1 - g) + n[0] * fl * g, c[1] + (n[1] * ca + b[1] * sa) * (1 - g) + n[1] * fl * g + lift * low, c[2] + (n[2] * ca + b[2] * sa) * (1 - g) + n[2] * fl * g];
  };
  const REST = 2.0;
  for (let s = 0; s < 5; s++) {
    const radii = [];
    const pts = path.map((p, i) => {
      const near = Math.min(Math.max(0, arc[i] - arc[air]), arc[total - 1] - arc[i] - 0.05);
      const g = 0;
      radii.push(RSB + (RSF - RSB) * g);
      const c = [p[0], Math.max(p[1], 0) + (i >= air ? padAt(p[0], p[2]) : 0), p[2]];
      return strand(s, c, tan[i], lat[i], g, twistAt(arc[air]) - arc[i] * TW);
    });
    const g = tube(pts, 1, 8, null);
    const rs = 9;
    for (let i = 0; i < total; i++) for (let j = 0; j < rs; j++) {
      const k = (i * rs + j) * 3;
      g.p[k] = pts[i][0] + g.n[k] * radii[i]; g.p[k + 1] = pts[i][1] + g.n[k + 1] * radii[i]; g.p[k + 2] = pts[i][2] + g.n[k + 2] * radii[i];
      g.u[(i * rs + j) * 2 + 1] += REST;
    }
    add(g, M.id(), { kind: 9, baseA: PAL.inkA[s], baseB: PAL.inkB[s], rough: 0.48 });
  }

  const LN = 144, LRS = 12;
  const lead = TH.map((_, s) => { const mesh = R.dynamic(LN * (LRS + 1), tubeIndex(LN, LRS)); return { mesh, it: add(mesh, M.id(), { kind: 9, baseA: PAL.inkA[s], baseB: PAL.inkB[s], rough: 0.48 }) }; });
  const leadC = Array.from({ length: LN }, () => [0, 0, 0]), leadT = Array.from({ length: LN }, () => [0, 0, 0]), leadN = Array.from({ length: LN }, () => [0, 0, 0]), leadD = new Float32Array(LN);
  const leadP = Array.from({ length: LN }, () => [0, 0, 0]);
  let leadKey = '';
  function layLead() {
    const { tip, axis } = S.jack;
    const key = tip.concat(axis).map(v => v.toFixed(5)).join();
    if (key === leadKey) return;
    leadKey = key;
    const B = [tip[0] + axis[0] * L.jack.back, tip[1] + axis[1] * L.jack.back, tip[2] + axis[2] * L.jack.back];
    const chord = Math.hypot(B[0] - anchor[0], B[1] - anchor[1], B[2] - anchor[2]);
    const k0 = 0.018 + chord * 0.14, k1 = 0.02 + chord * 0.25;
    const c1 = [B[0] + axis[0] * k0, B[1] + axis[1] * k0 - chord * 0.1, B[2] + axis[2] * k0 - chord * 0.4];
    const c2 = [anchor[0] - anchorT[0] * k1, anchor[1] - anchorT[1] * k1, anchor[2] - anchorT[2] * k1];
    const sample = (slack, write) => {
      let length = 0, px = 0, py = 0, pz = 0;
      for (let i = 0; i < LN; i++) {
        const t = i / (LN - 1), u = 1 - t;
        const a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
        const bow = Math.sin(Math.PI * t) ** 2;
        const x = a * B[0] + b * c1[0] + c * c2[0] + d * anchor[0] + slack * bow * 0.1;
        let y = a * B[1] + b * c1[1] + c * c2[1] + d * anchor[1] - slack * bow * 0.65;
        const z = a * B[2] + b * c1[2] + c * c2[2] + d * anchor[2] - slack * bow * 0.7;
        const onMixer = sm01((0.136 - Math.abs(x)) / 0.012) * sm01((z + 0.188) / 0.012);
        let floor = Math.max(padAt(x, z), L.mixerY * onMixer);
        for (const deckX of [-L.deckX, L.deckX]) floor = Math.max(floor, L.yPlinth * sm01((0.235 - Math.abs(x - deckX)) / 0.01) * sm01((0.1875 - Math.abs(z)) / 0.01));
        const gap = y - floor;
        y = floor + 0.5 * (gap + Math.sqrt(gap * gap + 0.000004));
        if (i) length += Math.hypot(x - px, y - py, z - pz);
        px = x; py = y; pz = z;
        if (write) { leadC[i][0] = x; leadC[i][1] = y; leadC[i][2] = z; }
      }
      return length;
    };
    let lo = 0, hi = 1.4;
    for (let j = 0; j < 16; j++) { const mid = (lo + hi) / 2; if (sample(mid, false) < 1.65) lo = mid; else hi = mid; }
    S.leadLength = sample((lo + hi) / 2, true);
    for (let i = 0; i < LN; i++) {
      const a = leadC[Math.max(0, i - 1)], b = leadC[Math.min(LN - 1, i + 1)];
      leadT[i] = norm(b.map((v, q) => v - a[q]));
    }
    leadN[LN - 1] = lat[0];
    leadD[LN - 1] = arc[air];
    for (let i = LN - 2; i >= 0; i--) {
      leadN[i] = carryN(leadN[i + 1], leadT[i]);
      leadD[i] = leadD[i + 1] + Math.hypot(leadC[i][0] - leadC[i + 1][0], leadC[i][1] - leadC[i + 1][1], leadC[i][2] - leadC[i + 1][2]);
    }
    lead.forEach(({ mesh }, s) => {
      for (let i = 0; i < LN; i++) leadP[i] = strand(s, leadC[i], leadT[i], leadN[i], 0, twistAt(leadD[i]));
      tubeFill(mesh.data, 0, leadP, RSB, LRS, REST, [0.3, 0.2, 0.93]);
      mesh.push();
    });
  }

  const sleeveG = R.mesh(rbox(0.31, 0.0034, 0.31, 0.003, 0.0006, 2, 1));
  const sleeves = [];
  const spots = [];
  for (let k = 0; k < 12; k++) {
    const col = k % 4, row = Math.floor(k / 4);
    const j1 = Math.sin(k * 12.9898) * 43758.5453, j2 = Math.sin(k * 78.233 + 2) * 43758.5453, j3 = Math.sin(k * 39.425 + 5) * 43758.5453;
    const x = -0.955 + col * 0.292 + ((j1 - Math.floor(j1)) - 0.5) * 0.05, z = 0.94 + row * 0.287 + ((j2 - Math.floor(j2)) - 0.5) * 0.05;
    const a = ((j3 - Math.floor(j3)) - 0.5) * 0.24;
    let layer = 0;
    for (const o of spots) if (Math.abs(o.x - x) < 0.325 && Math.abs(o.z - z) < 0.325) layer = Math.max(layer, o.layer + 1);
    spots.push({ x, z, a, layer });
    const tex = { t: null };
    const it = add(sleeveG, M.chain(M.t(x, 0.0002 + layer * 0.0035, z), M.ry(a)), { kind: 3, baseA: PAL.cream, rough: 0.5, tex: null, p: [0, 0.05, 0.8, 0] });
    sleeves.push({ it, x, z, a, layer, name: SLEEVES[k], o: OC(x, z, 0.155, 0.155, 0.003, 0.0036 + layer * 0.0035, a, 0.75) });
  }
  let sleevesLoaded = false;
  function loadSleeves() {
    if (sleevesLoaded) return;
    sleevesLoaded = true;
    sleeves.forEach(s => { s.it.tex = R.image(base + 'music/' + s.name + '.webp', [233, 226, 216, 255]); });
  }

  const PH = L.phone;
  const phoneBodyG = R.mesh(rbox(PH.w, PH.h - 0.0004, PH.d, 0.0115, 0.0018, 10, 4));
  const phoneGlassG = R.mesh(rbox(PH.w - 0.0022, 0.0005, PH.d - 0.0022, 0.0105, 0.0003, 10, 2));
  const mkPhone = () => ({ body: add(phoneBodyG, null, { baseA: PAL.titan, metal: 0.9, rough: 0.36 }), glass: add(phoneGlassG, null, { baseA: [0.004, 0.004, 0.004], rough: 0.07 }), o: OC(0, 0, PH.w / 2, PH.d / 2, 0.0115, PH.h, 0, 0.9) });
  const phone = mkPhone(), friend = mkPhone();
  for (const ph of [phone, friend]) {
    const rails = [];
    for (const [x, z, d] of [[-PH.w / 2, -0.025, 0.012], [-PH.w / 2, -0.008, 0.012], [PH.w / 2, -0.012, 0.019]]) rails.push([rbox(0.0012, 0.0022, d, 0.0005, 0.0003, 3, 2), M.t(x, 0.003, z)]);
    detail(ph.body, merge(rails), M.id(), { baseA: PAL.titan, metal: 0.85, rough: 0.28 });
    const bands = [];
    for (const x of [-PH.w / 2, PH.w / 2]) for (const z of [-0.055, 0.055]) bands.push([rbox(0.0004, 0.006, 0.0009, 0.0002, 0.0001, 2, 1), M.t(x, 0.001, z)]);
    detail(ph.body, merge(bands), M.id(), { baseA: [0.09, 0.085, 0.08], rough: 0.8, cast: false });
    detail(ph.body, rbox(0.0085, 0.0022, 0.0005, 0.001, 0.0002, 4, 2), M.t(0, 0.0027, PH.d / 2), { baseA: [0.002, 0.002, 0.002], rough: 0.6, cast: false });
  }

  const Wt = L.watch;
  const wm = M.chain(M.t(L.watchPos[0], padAt(L.watchPos[0], L.watchPos[1]), L.watchPos[1]), M.ry(L.watchPos[2]));
  const strap = side => {
    const g = rbox(0.03, 0.0024, 0.07, 0.008, 0.001, 10, 4);
    for (let i = 0; i < g.p.length; i += 3) {
      const u = (g.p[i + 2] * side + 0.035) / 0.07;
      g.p[i] *= 1 - 0.16 * u;
      g.p[i + 1] += 0.0015 * (1 - u) ** 3;
    }
    return g;
  };
  add(strap(-1), M.chain(wm, M.t(0, 0, -0.0505)), { baseA: PAL.inkA[4], baseB: C8(96, 70, 56), rough: 0.7 });
  add(strap(1), M.chain(wm, M.t(0, 0, 0.0505)), { baseA: PAL.inkA[4], baseB: C8(96, 70, 56), rough: 0.7 });
  add(rbox(Wt.w, Wt.h - 0.0004, Wt.d, 0.0105, 0.003, 10, 5), wm, { baseA: [0.10, 0.098, 0.095], metal: 0.9, rough: 0.34 });
  add(rbox(Wt.w - 0.003, 0.0005, Wt.d - 0.003, 0.0092, 0.0003, 10, 2), M.chain(wm, M.t(0, Wt.h - 0.0004, 0)), { baseA: [0.004, 0.004, 0.004], rough: 0.07 });
  const crownM = M.chain(wm, M.t(Wt.w / 2 - 0.0004, 0.0058, -0.006), M.rz(-Math.PI / 2));
  const crown = add(lathe([[0, 0], [0.0032, 0], [0.0036, 0.0006], [0.0036, 0.0026], [0.0032, 0.0032], [0, 0.0032]], 28), crownM, { kind: 6, baseA: PAL.copper, metal: 1, rough: 0.3, p: [22, 1, 0.0005, 0.0001] });
  OC(L.watchPos[0], L.watchPos[1], Wt.w / 2, Wt.d / 2, 0.01, Wt.h, L.watchPos[2], 0.8);
  for (const side of [-1, 1]) {
    const pt = M.pt(wm, 0, 0, side * 0.0505);
    OC(pt[0], pt[2], 0.014, 0.035, 0.007, 0.0024, L.watchPos[2], 0.65);
  }

  const strapHoles = [];
  for (let n = 0; n < 7; n++) strapHoles.push([lathe([[0.0014, 0], [0.0014, 0.0003], [0.0009, 0.0005], [0, 0.0005]], 16), M.t(0, 0.0024, 0.037 + n * 0.006)]);
  add(merge(strapHoles), wm, { baseA: [0.007, 0.006, 0.005], rough: 0.95, cast: false });
  add(rbox(0.025, 0.0034, 0.007, 0.002, 0.0008, 5, 3), M.chain(wm, M.t(0, 0.0023, -0.065)), { baseA: PAL.titan, metal: 0.9, rough: 0.32 });
  add(rbox(0.002, 0.0025, 0.01, 0.0008, 0.0004, 4, 2), M.chain(wm, M.t(Wt.w / 2, 0.003, 0.009)), { baseA: PAL.titan, metal: 0.9, rough: 0.32 });

  const IP = L.ipad, MC = L.mac, MB = L.macB, IB = L.ipadB;
  const roomMix = (a, b, r) => a + (b - a) * r;
  const ipadAt = r => M.chain(M.t(roomMix(IP.x, IB.x, r), 0, roomMix(IP.z, IB.z, r)), M.ry(IP.a + 0.5 * r));
  const macAt = r => M.chain(M.t(roomMix(MC.x, MB.x, r), 0.002 + 0.03 * Math.sin(Math.PI * r), roomMix(MC.z, MB.z, r)), M.ry(roomMix(MC.a, MB.a, r)));
  let ipm = ipadAt(0), mcm = macAt(0);
  const ipadParts = [], macParts = [];
  const ipadPart = (geo, local, mat) => { const it = add(geo, M.chain(ipm, local), mat); ipadParts.push([it, local]); return it; };
  const macPart = (geo, local, mat) => { const it = add(geo, M.chain(mcm, local), mat); macParts.push([it, local]); return it; };
  ipadPart(rbox(IP.w, IP.h, IP.d, 0.012, 0.0016, 10, 4), M.id(), { baseA: PAL.titan, metal: 0.9, rough: 0.32 });
  ipadPart(rbox(IP.w - 0.0014, 0.0005, IP.d - 0.0014, 0.0113, 0.0002, 10, 2), M.t(0, IP.h, 0), { baseA: [0.004, 0.005, 0.006], rough: 0.09 });
  const ipadOcc = OC(IP.x, IP.z, IP.w / 2, IP.d / 2, 0.012, IP.h, IP.a, 0.85);
  macPart(rbox(MC.w, MC.h, MC.d, 0.009, 0.0025, 8, 4), M.id(), { baseA: PAL.alu, metal: 0.9, rough: 0.38 });
  macPart(rbox(0.272, 0.0007, 0.088, 0.004, 0.0003, 6, 2), M.t(0, MC.h, -0.025), { baseA: [0.009, 0.009, 0.009], rough: 0.7 });
  const keys = [];
  for (let row = 0; row < 4; row++) for (let col = 0; col < 14; col++) keys.push([rbox(0.016, 0.0009, 0.012, 0.0018, 0.0004, 3, 2), M.t((col - 6.5) * 0.0187, MC.h + 0.0007, -0.057 + row * 0.0155)]);
  keys.push([rbox(0.11, 0.0009, 0.012, 0.0018, 0.0004, 3, 2), M.t(0, MC.h + 0.0007, 0.005)]);
  for (const side of [-1, 1]) for (let k = 0; k < 3; k++) keys.push([rbox(0.016, 0.0009, 0.012, 0.0018, 0.0004, 3, 2), M.t(side * (0.075 + k * 0.0187), MC.h + 0.0007, 0.005)]);
  for (let col = 0; col < 14; col++) keys.push([rbox(0.016, 0.0009, 0.007, 0.0015, 0.0004, 3, 2), M.t((col - 6.5) * 0.0187, MC.h + 0.0007, -0.073)]);
  const keyMesh = merge(keys), keyCanvas = document.createElement('canvas');
  keyCanvas.width = 768; keyCanvas.height = 320;
  const keyPaint = keyCanvas.getContext('2d');
  keyPaint.fillStyle = '#d0d0d2'; keyPaint.textAlign = 'center'; keyPaint.textBaseline = 'middle'; keyPaint.font = '9px sans-serif';
  const keyLabels = [['~', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 'delete'], ['tab', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '[', ']', '\u005c'], ['caps', 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ';', "'", '', 'return'], ['shift', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', ',', '.', '/', 'shift', '↑', '']];
  for (let row = 0; row < 4; row++) for (let col = 0; col < 14; col++) keyPaint.fillText(keyLabels[row][col], ((col - 6.5) * 0.0187 + 0.14) / 0.28 * 768, (-0.057 + row * 0.0155 + 0.08) / 0.1 * 320);
  for (let col = 0; col < 14; col++) keyPaint.fillText(col === 0 ? 'esc' : col === 13 ? '●' : 'F' + col, ((col - 6.5) * 0.0187 + 0.14) / 0.28 * 768, 0.007 / 0.1 * 320);
  for (let i = 0; i < keyMesh.p.length / 3; i++) { keyMesh.u[i * 2] = (keyMesh.p[i * 3] + 0.14) / 0.28; keyMesh.u[i * 2 + 1] = (keyMesh.p[i * 3 + 2] + 0.08) / 0.1; }
  macPart(keyMesh, M.id(), { kind: 3, tex: R.texture(keyCanvas), baseA: [0.021, 0.021, 0.022], rough: 0.62 });
  macPart(tube([[-0.11, MC.h + 0.001, -MC.d / 2 + 0.004], [0.11, MC.h + 0.001, -MC.d / 2 + 0.004]], 0.0032, 12), M.id(), { baseA: [0.015, 0.015, 0.015], rough: 0.4 });
  macPart(rbox(0.12, 0.0004, 0.066, 0.005, 0.0002, 6, 2), M.t(0, MC.h, 0.063), { baseA: [0.48, 0.48, 0.48], metal: 0.8, rough: 0.45, cast: false });
  const lidLocal = M.chain(M.t(0, MC.h, -MC.d / 2 + 0.004), M.rx(1.27), M.t(0, 0, -0.098));
  let lidm = M.chain(mcm, lidLocal);
  macPart(rbox(MC.w, 0.004, 0.196, 0.009, 0.0015, 8, 4), lidLocal, { baseA: PAL.alu, metal: 0.9, rough: 0.36 });
  macPart(rbox(MC.w - 0.004, 0.0005, 0.192, 0.007, 0.0002, 8, 2), M.chain(lidLocal, M.t(0, 0.004, 0)), { baseA: [0.004, 0.004, 0.004], rough: 0.09 });
  const macOcc = OC(MC.x, MC.z, MC.w / 2, MC.d / 2, 0.009, 0.014, MC.a, 0.9);
  function room() {
    const r = S.room;
    const e = r * r * r * (r * (r * 6 - 15) + 10);
    ipm = ipadAt(e); mcm = macAt(e); lidm = M.chain(mcm, lidLocal);
    for (const [it, local] of ipadParts) it.model = M.chain(ipm, local);
    for (const [it, local] of macParts) it.model = M.chain(mcm, local);
    ipadOcc.x = roomMix(IP.x, IB.x, e); ipadOcc.z = roomMix(IP.z, IB.z, e); ipadOcc.a = IP.a + 0.5 * e;
    macOcc.x = roomMix(MC.x, MB.x, e); macOcc.z = roomMix(MC.z, MB.z, e); macOcc.a = roomMix(MC.a, MB.a, e); macOcc.s = 0.9 * (1 - 0.6 * Math.sin(Math.PI * e));
    const [cx, cz] = L.crateB;
    for (const sl of sleeves) {
      const k = 1 - 0.18 * sl.layer;
      const x = sl.x + cx * e * k, z = sl.z + cz * e * k, a = sl.a + 0.35 * e;
      sl.it.model = M.chain(M.t(x, 0.0002 + sl.layer * 0.0035, z), M.ry(a));
      sl.o.x = x; sl.o.z = z; sl.o.a = a;
    }
  }

  const TV = L.tv;
  const tvm = M.t(TV.x, padAt(TV.x, TV.z), TV.z);
  add(rbox(TV.w, TV.t, TV.hgt, 0.007, 0.002, 4, 3), M.chain(tvm, M.t(0, TV.lift + TV.hgt / 2, 0), M.rx(Math.PI / 2)), { baseA: [0.012, 0.012, 0.012], rough: 0.3 });
  add(rbox(TV.sw, 0.0006, TV.sh, 0.002, 0.0002, 2, 1), M.chain(tvm, M.t(0, TV.lift + TV.hgt / 2, TV.t), M.rx(Math.PI / 2)), { baseA: [0.003, 0.003, 0.003], rough: 0.08, cast: false });
  add(rbox(0.06, 0.07, 0.018, 0.004, 0.001, 3, 2), M.chain(tvm, M.t(0, 0.008, -0.012)), { baseA: PAL.body, rough: 0.4 });
  add(rbox(0.3, 0.008, 0.17, 0.03, 0.003, 8, 3), M.chain(tvm, M.t(0, 0, 0)), { baseA: PAL.body, rough: 0.4 });
  OC(TV.x, TV.z, 0.15, 0.085, 0.03, 0.012, 0, 0.9);
  OC(TV.x, TV.z + 0.01, TV.w / 2, 0.012, 0.004, 0.2, 0, 0.5);
  add(rbox(0.093, 0.031, 0.093, 0.022, 0.006, 10, 5), M.t(TV.x - 0.39, 0, TV.z + 0.03), { baseA: [0.012, 0.012, 0.012], rough: 0.22 });
  OC(TV.x - 0.39, TV.z + 0.03, 0.0465, 0.0465, 0.022, 0.031);
  const remoteM = M.chain(M.t(TV.x + 0.4, 0, TV.z + 0.1), M.ry(-0.3));
  add(rbox(0.035, 0.0073, 0.136, 0.009, 0.002, 8, 3), remoteM, { baseA: PAL.alu, metal: 1, rough: 0.36 });
  add(disc(0.0025, 0.0125, 32, 0.0075), M.chain(remoteM, M.t(0, 0, -0.043)), { baseA: [0.01, 0.01, 0.01], rough: 0.3, cast: false });
  const remoteButtons = [];
  for (const [x, z] of [[-0.008, -0.012], [0.008, -0.012], [-0.008, 0.006], [-0.008, 0.024]]) remoteButtons.push([lathe([[0.0042, 0], [0.0045, 0.0006], [0.004, 0.0012], [0, 0.0012]], 20), M.t(x, 0.0073, z)]);
  remoteButtons.push([rbox(0.009, 0.0012, 0.028, 0.0045, 0.0004, 6, 2), M.t(0.008, 0.0073, 0.015)]);
  remoteButtons.push([lathe([[0.0022, 0], [0.0022, 0.0005], [0, 0.0005]], 16), M.t(0.010, 0.0073, -0.060)]);
  remoteButtons.push([lathe([[0.009, 0], [0.009, 0.0006], [0.0085, 0.001], [0, 0.001]], 32), M.t(0, 0.0073, -0.043)]);
  add(merge(remoteButtons), remoteM, { baseA: [0.008, 0.008, 0.008], rough: 0.36 });
  add(disc(0, 0.0012, 12), M.t(TV.x - 0.39, 0.012, TV.z + 0.0766), { baseA: [0.7, 0.7, 0.68], rough: 0.4, cast: false });
  OC(TV.x + 0.4, TV.z + 0.1, 0.0175, 0.068, 0.009, 0.0073, -0.3, 0.9);

  const lamps = new Float32Array(16), lampC = new Float32Array(12);
  const occA = new Float32Array(96), occB = new Float32Array(96), occH = new Float32Array(24), dark = new Float32Array(4);

  function place(ph, st) {
    const m = M.chain(M.t(st[0], st[3] || 0, st[1]), M.ry(st[2]), M.rx(st[4] || 0));
    ph.body.model = m;
    ph.glass.model = M.chain(m, M.t(0, PH.h - 0.0004, 0));
    ph.o.x = st[0]; ph.o.z = st[1]; ph.o.a = st[2]; ph.o.s = 0.9 * Math.max(0, 1 - (st[3] || 0) / 0.05);
  }

  const TAU = Math.PI * 2;
  const sm = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };

  const meter = [0, 0];
  function update() {
    if (S.power < 0.00001) S.glow = 0.32;
    for (let i = 0; i < 2; i++) {
      const d = decks[i];
      const base0 = M.chain(M.t(d.px, L.yPlinth, 0), M.ry(-S.angle[i]));
      d.parts[0].model = base0;
      const up = M.chain(M.t(d.px, L.yPlatter, 0), M.ry(-S.angle[i]));
      d.parts[1].model = up;
      const rec = M.chain(up, M.rx(0.0035), M.t(0.0004, 0, 0));
      d.rec.forEach(it => { it.model = rec; });
      d.pcap.model = M.t(d.ox + L.pitchX, L.yPlinth, L.pitchZ + S.pitch[i] * L.pitchTravel);
      d.led.p[0] = (0.12 + 0.88 * S.motor[i]) * S.power;
      const u = S.arm[i];
      const yaw = d.arm.rest + (d.arm.play - d.arm.rest) * sm(0.18, 0.8, u);
      const lift = 0.012 + 0.05 * sm(0, 0.2, u) - 0.062 * sm(0.82, 1, u);
      const am = M.chain(M.t(d.arm.P[0], 0.1225, d.arm.P[1]), M.ry(yaw), M.rx(-lift));
      d.arm.parts.forEach(([it, local]) => { it.model = M.chain(am, local); });
      const pl = d.parts[0];
      for (let r = 0; r < 4; r++) {
        const n = 176 + r * 4;
        const rate = n * S.w[i] / TAU;
        d.sp[r] = (d.sp[r] + (rate - 100 * Math.round(rate / 100)) * S.dt) % 1;
        const v = n * S.angle[i] / TAU - d.sp[r];
        pl.p[r] = v - Math.floor(v);
      }
      pl.q[0] = Math.min(1, Math.abs(S.w[i]) / 1.4);
      pl.q[1] = S.power;
    }
    crown.model = M.chain(crownM, M.ry(S.crown));
    knobs.forEach((k, n) => {
      S.knobShown[n] += (S.knob[n] - S.knobShown[n]) * 0.35;
      const a = (S.knobShown[n] - 0.5) * 270 * Math.PI / 180;
      k.it.model = M.chain(M.t(k.x, L.mixerY, k.z), M.ry(-a), M.s(k.s));
    });
    for (let c = 0; c < 2; c++) {
      chans[c].model = M.t((c ? 1 : -1) * L.knobX, L.mixerY, L.chanZ - S.chan[c] * L.chanTravel);
      meter[c] += (S.level[c] - meter[c]) * (1 - Math.exp(-Math.min(S.dt, 0.05) / (S.level[c] > meter[c] ? 0.065 : 0.16)));
      const lv = meter[c];
      leds[c].forEach((it, k) => { it.p[0] = Math.max(0.04, Math.min(1, lv * 9 - k)) * S.power; });
    }
    xfCap.model = M.t((S.xf - 0.5) * L.xfTravel, L.mixerY, L.xfZ);
    const { tip, axis } = S.jack;
    const side = norm(cross(axis, Math.abs(axis[2]) > 0.95 ? [1, 0, 0] : [0, 0, 1]));
    const fwd = cross(side, axis);
    const jm = new Float32Array([side[0], side[1], side[2], 0, axis[0], axis[1], axis[2], 0, fwd[0], fwd[1], fwd[2], 0, tip[0], tip[1], tip[2], 1]);
    jack.forEach(it => { it.model = jm; });
    well.p[0] = S.glow;
    room();
    layLead();
    place(phone, S.phone);
    place(friend, S.friend);
    for (const [it, parent, local] of details) it.model = M.chain(parent.model, local);
    if (typeof screenItems !== 'undefined') for (const [name, it] of Object.entries(screenItems)) it.model = M.chain(screens[name](), M.rx(Math.PI / 2));
  }

  function frame(focus) {
    lamps.set([L.socket[0], L.socket[1] + 0.012, L.socket[2], 0.05], 0);
    const g = S.glow * 0.62;
    lampC.set([3.0 * g, 0.78 * g, 0.13 * g], 0);
    const rm = S.room, pw = S.power * (1 + 1.8 * rm);
    for (let i = 0; i < 2; i++) { lamps.set([...decks[i].lamp, 0.03 + 0.07 * rm], 4 + i * 4); lampC.set([roomMix(0.5, 0.34, rm) * pw, roomMix(0.06, 0.5, rm) * pw, roomMix(0.015, 0.95, rm) * pw], 3 + i * 3); }
    lamps.set([TV.x, TV.lift + TV.hgt / 2, TV.z + 0.12, 0.4], 12);
    lampC.set(S.tvGlow, 9);
    const list = occ.map(o => ({ o, d: Math.hypot(o.x - focus[0], o.z - focus[2]) - Math.max(o.hx, o.hz) })).sort((a, b) => a.d - b.d).slice(0, 24);
    list.forEach(({ o }, i) => {
      occA.set([o.x, o.z, o.hx, o.hz], i * 4);
      occB.set([Math.cos(o.a), Math.sin(o.a), o.r, o.s], i * 4);
      occH[i] = o.h;
    });
    dark[0] = L.socket[0]; dark[1] = L.socket[2]; dark[2] = S.glow; dark[3] = S.power;
    return { lamps, lampC, occA, occB, occH, occN: list.length, dark, front: S.front };
  }

  const screens = {
    ipad: () => M.chain(ipm, M.t(0, IP.h + 0.0007, 0), M.rx(-Math.PI / 2)),
    mac: () => M.chain(lidm, M.t(0, 0.0047, 0), M.rx(-Math.PI / 2)),
    phone: () => M.chain(M.t(S.phone[0], S.phone[3], S.phone[1]), M.ry(S.phone[2]), M.rx(S.phone[4]), M.t(0, PH.h + 0.0002, 0), M.rx(-Math.PI / 2)),
    friend: () => M.chain(M.t(S.friend[0], S.friend[3], S.friend[1]), M.ry(S.friend[2]), M.rx(S.friend[4]), M.t(0, PH.h + 0.0002, 0), M.rx(-Math.PI / 2)),
    watch: () => M.chain(wm, M.t(0, Wt.h + 0.0002, 0), M.rx(-Math.PI / 2)),
    tv: () => M.chain(tvm, M.t(0, TV.lift + TV.hgt / 2, TV.t + 0.0008)),
  };

  screens.pad = screens.ipad;
  L.pad = L.ipad;
  const screenItems = {};
  const screenSizes = { phone: [PH.sw, PH.sh], friend: [PH.sw, PH.sh], watch: [Wt.sw, Wt.sh], tv: [TV.sw, TV.sh], ipad: [IP.sw, IP.sh], mac: [MC.sw, MC.sh] };
  for (const [name, [w, h]] of Object.entries(screenSizes)) screenItems[name] = add(rbox(w, 0.00005, h, name === 'tv' || name === 'mac' ? 0.002 : Math.min(w * 0.12, 0.009), 0.00001, 10, 1), M.chain(screens[name](), M.rx(Math.PI / 2)), { kind: 10, baseA: [1, 1, 1], rough: 0.12, cast: false, vis: false });
  function setScreen(name, source, revision = 0) {
    const it = screenItems[name === 'pad' ? 'ipad' : name];
    if (!it || !source || !source.width || !source.height) return false;
    if (it.source === source && it.revision === revision && it.tex) { it.vis = true; return false; }
    if (it.tex) R.updateTexture(it.tex, source); else it.tex = R.texture(source, { anisotropy: 16 });
    it.source = source; it.revision = revision; it.vis = true;
    return true;
  }
  const screenVisible = (name, visible) => { name = name === 'pad' ? 'ipad' : name; if (screenItems[name]) screenItems[name].vis = visible; };

  const SEAT = [L.socket[0], L.jack.rim - L.jack.depth, L.socket[2]];
  const HEAD = norm([0.97, 0, -0.24]);
  function pose(u, seat, time = 0) {
    const a = sm01(u / 0.52), idle = 1 - a;
    const tilt = 0.66 * idle;
    const turn = 0;
    const hx = HEAD[0] * Math.cos(turn) - HEAD[2] * Math.sin(turn), hz = HEAD[0] * Math.sin(turn) + HEAD[2] * Math.cos(turn);
    const v = Math.min(1, Math.max(0, (u - 0.52) / 0.48));
    const gap = 0.012;
    let h = u < 0.52 ? 0.044 + (gap - 0.044) * a : gap - (gap + L.jack.depth * 0.88) * v * v * (2 - v);
    h += (-L.jack.depth - h) * seat;
    S.jack.axis = norm([Math.sin(tilt) * hx, Math.cos(tilt), Math.sin(tilt) * hz]);
    S.jack.tip = [L.socket[0] + 0.022 * idle, L.jack.rim + h, L.socket[2] + 0.006 * idle];
    return h;
  }

  update();
  const stable = new Map(items.map(it => [it, it.model]));
  update();
  R.batch(items, new Set(items.filter(it => stable.get(it) === it.model)));
  return { setScreen, screenVisible, screenItems, items, S, update, frame, screens, decks, loadSleeves, sleeves, pose, seat: SEAT };
}
