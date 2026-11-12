import { VERT, FRAG, DEPTH_VERT, DEPTH_FRAG, POST_VERT, BRIGHT_FRAG, BLUR_FRAG, DOF_FRAG, FINAL_FRAG } from './shaders.js';

export const M = {
  id: () => new Float32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
  mul(a, b, o = new Float32Array(16)) {
    for (let c = 0; c < 4; c++) {
      const b0 = b[c * 4], b1 = b[c * 4 + 1], b2 = b[c * 4 + 2], b3 = b[c * 4 + 3];
      o[c * 4] = a[0] * b0 + a[4] * b1 + a[8] * b2 + a[12] * b3;
      o[c * 4 + 1] = a[1] * b0 + a[5] * b1 + a[9] * b2 + a[13] * b3;
      o[c * 4 + 2] = a[2] * b0 + a[6] * b1 + a[10] * b2 + a[14] * b3;
      o[c * 4 + 3] = a[3] * b0 + a[7] * b1 + a[11] * b2 + a[15] * b3;
    }
    return o;
  },
  chain(...ms) { return ms.reduce((a, b) => M.mul(a, b)); },
  t: (x, y, z) => new Float32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1]),
  s: k => new Float32Array([k, 0, 0, 0, 0, k, 0, 0, 0, 0, k, 0, 0, 0, 0, 1]),
  rx(a) { const c = Math.cos(a), s = Math.sin(a); return new Float32Array([1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1]); },
  ry(a) { const c = Math.cos(a), s = Math.sin(a); return new Float32Array([c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1]); },
  rz(a) { const c = Math.cos(a), s = Math.sin(a); return new Float32Array([c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]); },
  persp(fovy, aspect, near, far, ox = 0, oy = 0) {
    const f = 1 / Math.tan(fovy / 2), nf = 1 / (near - far);
    return new Float32Array([f / aspect, 0, 0, 0, 0, f, 0, 0, -ox, -oy, (far + near) * nf, -1, 0, 0, 2 * far * near * nf, 0]);
  },
  ortho(l, r, b, t, n, f) {
    return new Float32Array([2 / (r - l), 0, 0, 0, 0, 2 / (t - b), 0, 0, 0, 0, -2 / (f - n), 0, -(r + l) / (r - l), -(t + b) / (t - b), -(f + n) / (f - n), 1]);
  },
  look(e, c, u) {
    let zx = e[0] - c[0], zy = e[1] - c[1], zz = e[2] - c[2];
    let l = Math.hypot(zx, zy, zz) || 1; zx /= l; zy /= l; zz /= l;
    let xx = u[1] * zz - u[2] * zy, xy = u[2] * zx - u[0] * zz, xz = u[0] * zy - u[1] * zx;
    l = Math.hypot(xx, xy, xz) || 1; xx /= l; xy /= l; xz /= l;
    const yx = zy * xz - zz * xy, yy = zz * xx - zx * xz, yz = zx * xy - zy * xx;
    return new Float32Array([xx, yx, zx, 0, xy, yy, zy, 0, xz, yz, zz, 0, -(xx * e[0] + xy * e[1] + xz * e[2]), -(yx * e[0] + yy * e[1] + yz * e[2]), -(zx * e[0] + zy * e[1] + zz * e[2]), 1]);
  },
  inv(m) {
    const o = new Float32Array(16);
    const a00 = m[0], a01 = m[1], a02 = m[2], a03 = m[3], a10 = m[4], a11 = m[5], a12 = m[6], a13 = m[7], a20 = m[8], a21 = m[9], a22 = m[10], a23 = m[11], a30 = m[12], a31 = m[13], a32 = m[14], a33 = m[15];
    const b00 = a00 * a11 - a01 * a10, b01 = a00 * a12 - a02 * a10, b02 = a00 * a13 - a03 * a10, b03 = a01 * a12 - a02 * a11, b04 = a01 * a13 - a03 * a11, b05 = a02 * a13 - a03 * a12, b06 = a20 * a31 - a21 * a30, b07 = a20 * a32 - a22 * a30, b08 = a20 * a33 - a23 * a30, b09 = a21 * a32 - a22 * a31, b10 = a21 * a33 - a23 * a31, b11 = a22 * a33 - a23 * a32;
    let det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
    det = 1 / det;
    o[0] = (a11 * b11 - a12 * b10 + a13 * b09) * det; o[1] = (a02 * b10 - a01 * b11 - a03 * b09) * det; o[2] = (a31 * b05 - a32 * b04 + a33 * b03) * det; o[3] = (a22 * b04 - a21 * b05 - a23 * b03) * det;
    o[4] = (a12 * b08 - a10 * b11 - a13 * b07) * det; o[5] = (a00 * b11 - a02 * b08 + a03 * b07) * det; o[6] = (a32 * b02 - a30 * b05 - a33 * b01) * det; o[7] = (a20 * b05 - a22 * b02 + a23 * b01) * det;
    o[8] = (a10 * b10 - a11 * b08 + a13 * b06) * det; o[9] = (a01 * b08 - a00 * b10 - a03 * b06) * det; o[10] = (a30 * b04 - a31 * b02 + a33 * b00) * det; o[11] = (a21 * b02 - a20 * b04 - a23 * b00) * det;
    o[12] = (a11 * b07 - a10 * b09 - a12 * b06) * det; o[13] = (a00 * b09 - a01 * b07 + a02 * b06) * det; o[14] = (a31 * b01 - a30 * b03 - a32 * b00) * det; o[15] = (a20 * b03 - a21 * b01 + a22 * b00) * det;
    return o;
  },
  pt(m, x, y, z) {
    const w = m[3] * x + m[7] * y + m[11] * z + m[15];
    return [(m[0] * x + m[4] * y + m[8] * z + m[12]) / w, (m[1] * x + m[5] * y + m[9] * z + m[13]) / w, (m[2] * x + m[6] * y + m[10] * z + m[14]) / w, w];
  },
};

const G = () => ({ p: [], n: [], u: [], i: [] });
const V = (g, px, py, pz, nx, ny, nz, u = 0, v = 0) => { g.p.push(px, py, pz); g.n.push(nx, ny, nz); g.u.push(u, v); return g.p.length / 3 - 1; };

export function lathe(profile, segs = 48, smoothDeg = 38) {
  const g = G();
  const sn = [];
  for (let k = 0; k < profile.length - 1; k++) {
    const dr = profile[k + 1][0] - profile[k][0], dy = profile[k + 1][1] - profile[k][1];
    const l = Math.hypot(dr, dy) || 1;
    sn.push([dy / l, -dr / l]);
  }
  const cosT = Math.cos((smoothDeg * Math.PI) / 180);
  const blend = (a, b) => { if (!a || !b) return null; if (a[0] * b[0] + a[1] * b[1] < cosT) return null; const x = a[0] + b[0], y = a[1] + b[1], l = Math.hypot(x, y) || 1; return [x / l, y / l]; };
  let acc = 0;
  const lens = [0];
  for (let k = 0; k < profile.length - 1; k++) { acc += Math.hypot(profile[k + 1][0] - profile[k][0], profile[k + 1][1] - profile[k][1]); lens.push(acc); }
  for (let k = 0; k < profile.length - 1; k++) {
    const n0 = blend(sn[k - 1], sn[k]) || sn[k], n1 = blend(sn[k], sn[k + 1]) || sn[k];
    const base = g.p.length / 3;
    for (let j = 0; j <= segs; j++) {
      const a = (j / segs) * Math.PI * 2, c = Math.cos(a), s = Math.sin(a);
      V(g, profile[k][0] * c, profile[k][1], profile[k][0] * s, n0[0] * c, n0[1], n0[0] * s, j / segs, lens[k] / acc);
      V(g, profile[k + 1][0] * c, profile[k + 1][1], profile[k + 1][0] * s, n1[0] * c, n1[1], n1[0] * s, j / segs, lens[k + 1] / acc);
    }
    for (let j = 0; j < segs; j++) { const a = base + j * 2; g.i.push(a, a + 1, a + 2, a + 1, a + 3, a + 2); }
  }
  return g;
}

export function disc(r0, r1, segs = 96, y = 0) {
  const g = G();
  for (let j = 0; j <= segs; j++) {
    const a = (j / segs) * Math.PI * 2, c = Math.cos(a), s = Math.sin(a);
    V(g, r0 * c, y, r0 * s, 0, 1, 0, 0.5 + (0.5 * r0 * c) / r1, 0.5 + (0.5 * r0 * s) / r1);
    V(g, r1 * c, y, r1 * s, 0, 1, 0, 0.5 + 0.5 * c, 0.5 + 0.5 * s);
  }
  for (let j = 0; j < segs; j++) { const a = j * 2; g.i.push(a, a + 1, a + 2, a + 1, a + 3, a + 2); }
  return g;
}

export function outline(w, d, r, cs = 8) {
  const pts = [];
  const hw = w / 2, hd = d / 2;
  r = Math.min(r, hw, hd);
  const corners = [[hw - r, hd - r, 0], [-(hw - r), hd - r, 1], [-(hw - r), -(hd - r), 2], [hw - r, -(hd - r), 3]];
  for (const [cx, cz, q] of corners) {
    for (let k = 0; k <= cs; k++) {
      const a = (q + k / cs) * Math.PI / 2;
      const nx = Math.cos(a), nz = Math.sin(a);
      pts.push([cx + nx * r, cz + nz * r, nx, nz]);
    }
  }
  return pts;
}

export function rbox(w, h, d, r = 0.01, b = 0.003, cs = 8, bs = 4) {
  const g = G();
  b = Math.min(b, h * 0.48);
  const o = outline(w, d, Math.max(r, b + 0.0001), cs);
  const N = o.length;
  const rings = [];
  for (let k = 0; k <= bs; k++) { const a = -Math.PI / 2 + k / bs * Math.PI / 2; rings.push({ inset: b * (1 - Math.cos(a)), y: b + b * Math.sin(a), ca: Math.cos(a), sa: Math.sin(a) }); }
  rings.push({ inset: 0, y: h - b, ca: 1, sa: 0 });
  for (let k = 1; k <= bs; k++) { const a = (k / bs) * Math.PI / 2; rings.push({ inset: b * (1 - Math.cos(a)), y: h - b + b * Math.sin(a), ca: Math.cos(a), sa: Math.sin(a) }); }
  const start = [];
  for (const R of rings) {
    start.push(g.p.length / 3);
    for (let j = 0; j <= N; j++) {
      const [px, pz, nx, nz] = o[j % N];
      const x = px - nx * R.inset, z = pz - nz * R.inset;
      V(g, x, R.y, z, nx * R.ca, R.sa, nz * R.ca, x / w + 0.5, z / d + 0.5);
    }
  }
  for (let k = 0; k < rings.length - 1; k++) for (let j = 0; j < N; j++) { const a = start[k] + j, c = start[k + 1] + j; g.i.push(a, c, a + 1, a + 1, c, c + 1); }
  const top = g.p.length / 3;
  V(g, 0, h, 0, 0, 1, 0, 0.5, 0.5);
  for (let j = 0; j <= N; j++) { const [px, pz, nx, nz] = o[j % N]; const x = px - nx * b, z = pz - nz * b; V(g, x, h, z, 0, 1, 0, x / w + 0.5, z / d + 0.5); }
  for (let j = 0; j < N; j++) g.i.push(top, top + 1 + j + 1, top + 1 + j);
  const bottom = g.p.length / 3;
  V(g, 0, 0, 0, 0, -1, 0, 0.5, 0.5);
  for (let j = 0; j <= N; j++) { const [px, pz, nx, nz] = o[j % N]; const x = px - nx * b, z = pz - nz * b; V(g, x, 0, z, 0, -1, 0, x / w + 0.5, z / d + 0.5); }
  for (let j = 0; j < N; j++) g.i.push(bottom, bottom + 1 + j, bottom + 2 + j);
  return g;
}

export function tube(pts, radius, rs = 8, taper = null) {
  const g = G();
  const n = pts.length;
  let ux = 0, uy = 1, uz = 0;
  let prevT = null;
  let acc = 0;
  for (let i = 0; i < n; i++) {
    const a = pts[Math.max(0, i - 1)], b = pts[Math.min(n - 1, i + 1)];
    let tx = b[0] - a[0], ty = b[1] - a[1], tz = b[2] - a[2];
    const tl = Math.hypot(tx, ty, tz) || 1; tx /= tl; ty /= tl; tz /= tl;
    if (i === 0) {
      if (Math.abs(ty) > 0.9) { ux = 1; uy = 0; uz = 0; }
      const d0 = ux * tx + uy * ty + uz * tz; ux -= tx * d0; uy -= ty * d0; uz -= tz * d0;
    } else {
      const d0 = ux * tx + uy * ty + uz * tz; ux -= tx * d0; uy -= ty * d0; uz -= tz * d0;
      acc += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1], pts[i][2] - pts[i - 1][2]);
    }
    const ul = Math.hypot(ux, uy, uz) || 1; ux /= ul; uy /= ul; uz /= ul;
    const vx = ty * uz - tz * uy, vy = tz * ux - tx * uz, vz = tx * uy - ty * ux;
    const rr = radius * (taper ? taper(i / (n - 1)) : 1);
    for (let j = 0; j <= rs; j++) {
      const ang = (j / rs) * Math.PI * 2, c = Math.cos(ang), s = Math.sin(ang);
      const nx = ux * c + vx * s, ny = uy * c + vy * s, nz = uz * c + vz * s;
      V(g, pts[i][0] + nx * rr, pts[i][1] + ny * rr, pts[i][2] + nz * rr, nx, ny, nz, j / rs, acc);
    }
    prevT = [tx, ty, tz];
  }
  for (let i = 0; i < n - 1; i++) for (let j = 0; j < rs; j++) { const a = i * (rs + 1) + j, c = a + rs + 1; g.i.push(a, c, a + 1, a + 1, c, c + 1); }
  return g;
}

export function fan(points, y = 0) {
  const g = G();
  let cx = 0, cz = 0;
  for (const p of points) { cx += p[0]; cz += p[1]; }
  cx /= points.length; cz /= points.length;
  V(g, cx, y, cz, 0, 1, 0, 0.5, 0.5);
  for (const p of points) V(g, p[0], y, p[1], 0, 1, 0, 0, 0);
  for (let j = 0; j < points.length; j++) g.i.push(0, 1 + ((j + 1) % points.length), 1 + j);
  return g;
}

export function quad(w, d, y = 0) {
  const g = G();
  V(g, -w / 2, y, -d / 2, 0, 1, 0, 0, 0); V(g, w / 2, y, -d / 2, 0, 1, 0, 1, 0); V(g, w / 2, y, d / 2, 0, 1, 0, 1, 1); V(g, -w / 2, y, d / 2, 0, 1, 0, 0, 1);
  g.i.push(0, 2, 1, 0, 3, 2);
  return g;
}

export function knurl(y0, y1, r, depth, count, per = 4) {
  const g = G();
  const cols = count * per;
  const pitch = (2 * Math.PI * r) / count;
  const rows = Math.max(2, Math.round(((y1 - y0) / pitch) * per));
  const rad = (i, j) => {
    const y = y0 + ((y1 - y0) * j) / rows;
    const edge = Math.min(1, Math.min(j, rows - j) / (per * 0.75));
    const u = i / per, w = (y - y0) / pitch;
    const a = u + w, b = u - w;
    const k = 1 - Math.max(Math.abs((a - Math.floor(a)) - 0.5) * 2, Math.abs((b - Math.floor(b)) - 0.5) * 2);
    return r - depth + depth * 1.6 * Math.min(1, k * 1.25) * edge + depth * (1 - edge) * 0.6;
  };
  const at = (i, j) => { const th = (i / cols) * Math.PI * 2, rr = rad(i, Math.min(rows, Math.max(0, j))); return [rr * Math.cos(th), y0 + ((y1 - y0) * j) / rows, rr * Math.sin(th)]; };
  for (let j = 0; j <= rows; j++) for (let i = 0; i <= cols; i++) {
    const p = at(i, j), a = at(i - 0.5, j), b = at(i + 0.5, j), c = at(i, j - 0.5), d = at(i, j + 0.5);
    const ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2], vx = d[0] - c[0], vy = d[1] - c[1], vz = d[2] - c[2];
    let nx = vy * uz - vz * uy, ny = vz * ux - vx * uz, nz = vx * uy - vy * ux;
    const l = Math.hypot(nx, ny, nz) || 1;
    V(g, p[0], p[1], p[2], nx / l, ny / l, nz / l, i / cols, j / rows);
  }
  for (let j = 0; j < rows; j++) for (let i = 0; i < cols; i++) { const a = j * (cols + 1) + i, c = a + cols + 1; g.i.push(a, c, a + 1, a + 1, c, c + 1); }
  return g;
}

export function slab(points, h, b = 0.001, bs = 4) {
  const g = G();
  const N = points.length;
  let cx = 0, cz = 0;
  for (const p of points) { cx += p[0]; cz += p[1]; }
  cx /= N; cz /= N;
  const o = points.map((p, i) => {
    const a = points[(i + N - 1) % N], c = points[(i + 1) % N];
    let nx = c[1] - a[1], nz = -(c[0] - a[0]);
    const l = Math.hypot(nx, nz) || 1; nx /= l; nz /= l;
    if (nx * (p[0] - cx) + nz * (p[1] - cz) < 0) { nx = -nx; nz = -nz; }
    return [p[0], p[1], nx, nz];
  });
  const rings = [{ inset: 0, y: 0, ca: 1, sa: 0 }, { inset: 0, y: h - b, ca: 1, sa: 0 }];
  for (let k = 1; k <= bs; k++) { const a = (k / bs) * Math.PI / 2; rings.push({ inset: b * (1 - Math.cos(a)), y: h - b + b * Math.sin(a), ca: Math.cos(a), sa: Math.sin(a) }); }
  const start = [];
  rings.forEach((R, k) => {
    start.push(g.p.length / 3);
    for (let j = 0; j <= N; j++) { const [px, pz, nx, nz] = o[j % N]; V(g, px - nx * R.inset, R.y, pz - nz * R.inset, nx * R.ca, R.sa, nz * R.ca, 0, k / (rings.length - 1)); }
  });
  for (let k = 0; k < rings.length - 1; k++) for (let j = 0; j < N; j++) { const a = start[k] + j, c = start[k + 1] + j; g.i.push(a, c, a + 1, a + 1, c, c + 1); }
  const top = g.p.length / 3;
  V(g, cx, h, cz, 0, 1, 0, 1, 1);
  for (let j = 0; j <= N; j++) { const [px, pz, nx, nz] = o[j % N]; V(g, px - nx * b, h, pz - nz * b, 0, 1, 0, 0, 1); }
  for (let j = 0; j < N; j++) g.i.push(top, top + 1 + j + 1, top + 1 + j);
  return g;
}

export function tubeFill(out, at, pts, radius, rs, accEnd, upRef) {
  const n = pts.length;
  let ux = upRef[0], uy = upRef[1], uz = upRef[2];
  let acc = accEnd;
  for (let i = n - 1; i > 0; i--) acc -= Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1], pts[i][2] - pts[i - 1][2]);
  let k = at * (rs + 1) * 3, q = at * (rs + 1) * 2;
  for (let i = 0; i < n; i++) {
    const a = pts[Math.max(0, i - 1)], b = pts[Math.min(n - 1, i + 1)];
    let tx = b[0] - a[0], ty = b[1] - a[1], tz = b[2] - a[2];
    const tl = Math.hypot(tx, ty, tz) || 1; tx /= tl; ty /= tl; tz /= tl;
    if (i > 0) acc += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1], pts[i][2] - pts[i - 1][2]);
    const d0 = ux * tx + uy * ty + uz * tz; ux -= tx * d0; uy -= ty * d0; uz -= tz * d0;
    const ul = Math.hypot(ux, uy, uz) || 1; ux /= ul; uy /= ul; uz /= ul;
    const vx = ty * uz - tz * uy, vy = tz * ux - tx * uz, vz = tx * uy - ty * ux;
    for (let j = 0; j <= rs; j++) {
      const ang = (j / rs) * Math.PI * 2, c = Math.cos(ang), s = Math.sin(ang);
      const nx = ux * c + vx * s, ny = uy * c + vy * s, nz = uz * c + vz * s;
      out.p[k] = pts[i][0] + nx * radius; out.p[k + 1] = pts[i][1] + ny * radius; out.p[k + 2] = pts[i][2] + nz * radius;
      out.n[k] = nx; out.n[k + 1] = ny; out.n[k + 2] = nz;
      out.u[q] = j / rs; out.u[q + 1] = acc;
      k += 3; q += 2;
    }
  }
}

export function tubeIndex(n, rs, strands = 1) {
  const idx = [];
  for (let s = 0; s < strands; s++) {
    const base = s * n * (rs + 1);
    for (let i = 0; i < n - 1; i++) for (let j = 0; j < rs; j++) { const a = base + i * (rs + 1) + j, c = a + rs + 1; idx.push(a, c, a + 1, a + 1, c, c + 1); }
  }
  return idx;
}

export function merge(parts) {
  const g = G();
  for (const [src, m] of parts) {
    const base = g.p.length / 3;
    for (let k = 0; k < src.p.length; k += 3) {
      const x = src.p[k], y = src.p[k + 1], z = src.p[k + 2];
      const nx = src.n[k], ny = src.n[k + 1], nz = src.n[k + 2];
      if (m) {
        g.p.push(m[0] * x + m[4] * y + m[8] * z + m[12], m[1] * x + m[5] * y + m[9] * z + m[13], m[2] * x + m[6] * y + m[10] * z + m[14]);
        g.n.push(m[0] * nx + m[4] * ny + m[8] * nz, m[1] * nx + m[5] * ny + m[9] * nz, m[2] * nx + m[6] * ny + m[10] * nz);
      } else { g.p.push(x, y, z); g.n.push(nx, ny, nz); }
    }
    for (const u of src.u) g.u.push(u);
    for (const i of src.i) g.i.push(base + i);
  }
  return g;
}

function compile(gl, type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
  return s;
}

function program(gl, vs, fs) {
  const p = gl.createProgram();
  gl.attachShader(p, compile(gl, gl.VERTEX_SHADER, vs));
  gl.attachShader(p, compile(gl, gl.FRAGMENT_SHADER, fs));
  gl.bindAttribLocation(p, 0, 'aPos');
  gl.bindAttribLocation(p, 1, 'aNor');
  gl.bindAttribLocation(p, 2, 'aUv');
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
  const u = {};
  const n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
  for (let i = 0; i < n; i++) { const info = gl.getActiveUniform(p, i); const name = info.name.replace(/\[0\]$/, ''); u[name] = gl.getUniformLocation(p, info.name); }
  return { p, u };
}

export function createRenderer(canvas, opts = {}) {
  const gl = canvas.getContext('webgl2', { antialias: opts.post === false, alpha: false, powerPreference: 'high-performance', preserveDrawingBuffer: !!opts.preserve });
  if (!gl) return null;
  const main = program(gl, VERT, FRAG);
  const depth = program(gl, DEPTH_VERT, DEPTH_FRAG);
  const SM = opts.shadowSize || 2048;
  const shadowTex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, shadowTex);
  gl.texStorage2D(gl.TEXTURE_2D, 1, gl.DEPTH_COMPONENT24, SM, SM);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_COMPARE_MODE, gl.COMPARE_REF_TO_TEXTURE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_COMPARE_FUNC, gl.LEQUAL);
  const fbo = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, shadowTex, 0);
  gl.drawBuffers([gl.NONE]);
  gl.readBuffer(gl.NONE);
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  const white = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, white);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([255, 255, 255, 255]));
  const aniso = gl.getExtension('EXT_texture_filter_anisotropic');
  let lost = false;
  let texId = 0, sigMain = NaN, sigShadow = NaN, cost = 0, timing = null, hh = 0, drawn = 0, calls = 0, always = false;
  const timer = gl.getExtension('EXT_disjoint_timer_query_webgl2');
  const waiting = [];
  let warmup = 3, drawAt = -Infinity;
  const PV = new Float32Array(24), PS = new Float32Array(24);
  const hx = x => { hh = Math.imul(hh ^ (x * 65536 | 0), 16777619); };
  const ha = a => { for (let i = 0; i < a.length; i++) hx(a[i]); };
  function planes(m, out) {
    for (let i = 0; i < 6; i++) {
      const a = i >> 1, s = i & 1 ? -1 : 1;
      const x = m[3] + s * m[a], y = m[7] + s * m[4 + a], z = m[11] + s * m[8 + a], w = m[15] + s * m[12 + a];
      const l = Math.hypot(x, y, z) || 1;
      out[i * 4] = x / l; out[i * 4 + 1] = y / l; out[i * 4 + 2] = z / l; out[i * 4 + 3] = w / l;
    }
  }
  function inside(it, P, n) {
    const b = it.mesh.bs;
    if (!b) return true;
    const m = it.model;
    const x = m[0] * b[0] + m[4] * b[1] + m[8] * b[2] + m[12], y = m[1] * b[0] + m[5] * b[1] + m[9] * b[2] + m[13], z = m[2] * b[0] + m[6] * b[1] + m[10] * b[2] + m[14];
    const r = b[3] * Math.sqrt(Math.max(m[0] * m[0] + m[1] * m[1] + m[2] * m[2], m[4] * m[4] + m[5] * m[5] + m[6] * m[6], m[8] * m[8] + m[9] * m[9] + m[10] * m[10]));
    for (let i = 0; i < n; i += 4) if (P[i] * x + P[i + 1] * y + P[i + 2] * z + P[i + 3] < -r) return false;
    return true;
  }
  canvas.addEventListener('webglcontextlost', e => { e.preventDefault(); lost = true; if (opts.onLost) opts.onLost(); });

  const geometry = new WeakMap();
  function mesh(g) {
    const vao = gl.createVertexArray();
    gl.bindVertexArray(vao);
    const buf = (data, loc, size) => { const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(data), gl.STATIC_DRAW); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, size, gl.FLOAT, false, 0, 0); };
    buf(g.p, 0, 3); buf(g.n, 1, 3); buf(g.u, 2, 2);
    const ib = gl.createBuffer();
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ib);
    const big = g.p.length / 3 > 65535;
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, big ? new Uint32Array(g.i) : new Uint16Array(g.i), gl.STATIC_DRAW);
    gl.bindVertexArray(null);
    const n = g.p.length / 3;
    let cx = 0, cy = 0, cz = 0, r2 = 0;
    for (let i = 0; i < g.p.length; i += 3) { cx += g.p[i] / n; cy += g.p[i + 1] / n; cz += g.p[i + 2] / n; }
    for (let i = 0; i < g.p.length; i += 3) r2 = Math.max(r2, (g.p[i] - cx) ** 2 + (g.p[i + 1] - cy) ** 2 + (g.p[i + 2] - cz) ** 2);
    const out = { vao, count: g.i.length, type: big ? gl.UNSIGNED_INT : gl.UNSIGNED_SHORT, bs: [cx, cy, cz, Math.sqrt(r2)] };
    geometry.set(out, g);
    return out;
  }

  function dynamic(count, index) {
    const vao = gl.createVertexArray();
    gl.bindVertexArray(vao);
    const data = { p: new Float32Array(count * 3), n: new Float32Array(count * 3), u: new Float32Array(count * 2) };
    const make = (arr, loc, size) => { const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b); gl.bufferData(gl.ARRAY_BUFFER, arr, gl.DYNAMIC_DRAW); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, size, gl.FLOAT, false, 0, 0); return b; };
    const bp = make(data.p, 0, 3), bn = make(data.n, 1, 3), bu = make(data.u, 2, 2);
    const ib = gl.createBuffer();
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ib);
    const big = count > 65535;
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, big ? new Uint32Array(index) : new Uint16Array(index), gl.STATIC_DRAW);
    gl.bindVertexArray(null);
    const push = () => {
      gl.bindBuffer(gl.ARRAY_BUFFER, bp); gl.bufferSubData(gl.ARRAY_BUFFER, 0, data.p);
      gl.bindBuffer(gl.ARRAY_BUFFER, bn); gl.bufferSubData(gl.ARRAY_BUFFER, 0, data.n);
      gl.bindBuffer(gl.ARRAY_BUFFER, bu); gl.bufferSubData(gl.ARRAY_BUFFER, 0, data.u);
    };
    const out = { vao, count: index.length, type: big ? gl.UNSIGNED_INT : gl.UNSIGNED_SHORT, data, rev: 0 };
    out.push = () => { push(); out.rev++; };
    return out;
  }

  function texture(source, { srgb = true, mips = true, anisotropy = 8 } = {}) {
    const t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.texImage2D(gl.TEXTURE_2D, 0, srgb ? gl.SRGB8_ALPHA8 : gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, source);
    if (mips) gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, mips ? gl.LINEAR_MIPMAP_LINEAR : gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    if (aniso) gl.texParameterf(gl.TEXTURE_2D, aniso.TEXTURE_MAX_ANISOTROPY_EXT, Math.min(anisotropy, gl.getParameter(aniso.MAX_TEXTURE_MAX_ANISOTROPY_EXT)));
    t.id = ++texId;
    return t;
  }

  function updateTexture(t, source) {
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    if (t.w === source.width && t.h === source.height) gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, gl.RGBA, gl.UNSIGNED_BYTE, source);
    else { gl.texImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, gl.RGBA, gl.UNSIGNED_BYTE, source); t.w = source.width; t.h = source.height; }
    gl.generateMipmap(gl.TEXTURE_2D);
    t.id = ++texId;
  }

  function batch(items, fixed) {
    const groups = new Map();
    for (const it of items) {
      if (!fixed.has(it) || it.tex || it.p || it.q || it.kind || it.vis === false || !geometry.has(it.mesh)) continue;
      const key = JSON.stringify([it.baseA, it.baseB, it.metal, it.rough, it.cast, Math.floor(it.model[12] / 0.5), Math.floor(it.model[14] / 0.5)]);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(it);
    }
    for (const group of groups.values()) {
      if (group.length < 2) continue;
      const combined = { ...group[0], model: M.id(), mesh: mesh(merge(group.map(it => [geometry.get(it.mesh), it.model]))) };
      for (const it of group) items.splice(items.indexOf(it), 1);
      items.push(combined);
    }
  }

  function image(url, fallback = [40, 36, 32, 255]) {
    const t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(fallback));
    t.id = ++texId;
    const holder = { t, ready: false };
    const img = new Image();
    img.decoding = 'async';
    const fin = () => { if (lost) return; holder.t = texture(img); holder.ready = true; if (opts.onTexture) opts.onTexture(); };
    img.src = url;
    if (img.decode) img.decode().then(fin, () => {}); else img.onload = fin;
    return holder;
  }

  let renderW = 1, renderH = 1, cssW = 0, cssH = 0;
  const post = { ok: false, w: 0, h: 0 };
  let bright, blur, focus, final;
  try { bright = program(gl, POST_VERT, BRIGHT_FRAG); blur = program(gl, POST_VERT, BLUR_FRAG); focus = program(gl, POST_VERT, DOF_FRAG); final = program(gl, POST_VERT, FINAL_FRAG); } catch (e) { bright = null; }
  const emptyVao = gl.createVertexArray();
  const target = (w, h, depthTex, mips) => {
    const fb = gl.createFramebuffer();
    const color = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, color);
    gl.texStorage2D(gl.TEXTURE_2D, mips ? 5 : 1, gl.RGBA8, w, h);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, mips ? gl.LINEAR_MIPMAP_LINEAR : gl.LINEAR);
    if (mips) gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAX_LEVEL, 4);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, color, 0);
    let dtex = null;
    if (depthTex) {
      dtex = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, dtex);
      gl.texStorage2D(gl.TEXTURE_2D, 1, gl.DEPTH_COMPONENT24, w, h);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, dtex, 0);
    }
    const ok = gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE;
    return { fb, color, depth: dtex, ok, w, h };
  };
  const drop = t => { if (!t) return; gl.deleteFramebuffer(t.fb); gl.deleteTexture(t.color); if (t.depth) gl.deleteTexture(t.depth); if (t.rbs) t.rbs.forEach(r => gl.deleteRenderbuffer(r)); };

  function setupPost(W, H) {
    [post.ms, post.scene, post.a, post.b, post.focus].forEach(drop);
    post.ok = false; post.w = W; post.h = H;
    sigMain = NaN;
    if (!bright || opts.post === false) return;
    const samples = Math.min(2, gl.getParameter(gl.MAX_SAMPLES));
    const fb = gl.createFramebuffer();
    const rc = gl.createRenderbuffer(), rd = gl.createRenderbuffer();
    gl.bindRenderbuffer(gl.RENDERBUFFER, rc);
    gl.renderbufferStorageMultisample(gl.RENDERBUFFER, samples, gl.RGBA8, W, H);
    gl.bindRenderbuffer(gl.RENDERBUFFER, rd);
    gl.renderbufferStorageMultisample(gl.RENDERBUFFER, samples, gl.DEPTH_COMPONENT24, W, H);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, rc);
    gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, rd);
    post.ms = { fb, rbs: [rc, rd], ok: gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE };
    post.scene = target(W, H, true, W > 64 && H > 64);
    const bw = Math.max(2, W >> 2), bh = Math.max(2, H >> 2);
    post.a = target(bw, bh, false);
    post.b = target(bw, bh, false);
    post.focus = target(Math.max(2, W >> 1), Math.max(2, H >> 1), false);
    post.ok = post.focus.ok && post.ms.ok && post.scene.ok && post.a.ok && post.b.ok;
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  }

  function resize(w, h, dpr) {
    renderW = Math.max(4, Math.ceil(w * dpr / 4) * 4);
    renderH = Math.max(4, Math.ceil(h * dpr / 4) * 4);
    const resized = w !== cssW || h !== cssH;
    cssW = w; cssH = h;
    if (resized || renderW > post.w || renderH > post.h) setupPost(renderW, renderH);
    const display = Math.min(globalThis.devicePixelRatio || 1, 2);
    const outputW = post.ok ? Math.round(w * display) : renderW, outputH = post.ok ? Math.round(h * display) : renderH;
    if (canvas.width !== outputW || canvas.height !== outputH) { canvas.width = outputW; canvas.height = outputH; sigMain = NaN; }
  }

  function pass(prog, dst, w, h) {
    gl.bindFramebuffer(gl.FRAMEBUFFER, dst);
    gl.viewport(0, 0, w, h);
    gl.useProgram(prog.p);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  function finish(f) {
    const W = renderW, H = renderH;
    const sx = W / post.w, sy = H / post.h, bw = W / 4, bh = H / 4;
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, post.ms.fb);
    gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, post.scene.fb);
    gl.blitFramebuffer(0, 0, W, H, 0, 0, W, H, gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT, gl.NEAREST);
    gl.disable(gl.DEPTH_TEST);
    gl.bindVertexArray(emptyVao);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, post.scene.color);
    if (W > 64 && H > 64) gl.generateMipmap(gl.TEXTURE_2D);
    gl.useProgram(bright.p);
    gl.uniform1i(bright.u.uColor, 0);
    gl.uniform2f(bright.u.uTexel, 1 / post.w, 1 / post.h);
    gl.uniform2f(bright.u.uScale, sx, sy);
    pass(bright, post.a.fb, bw, bh);
    gl.useProgram(blur.p);
    gl.uniform1i(blur.u.uColor, 0);
    gl.uniform2f(blur.u.uScale, sx, sy);
    for (let i = 0; i < 2; i++) {
      const k = i ? 2.4 : 1;
      gl.bindTexture(gl.TEXTURE_2D, post.a.color);
      gl.uniform2f(blur.u.uDir, k / post.a.w, 0);
      pass(blur, post.b.fb, bw, bh);
      gl.bindTexture(gl.TEXTURE_2D, post.b.color);
      gl.uniform2f(blur.u.uDir, 0, k / post.a.h);
      pass(blur, post.a.fb, bw, bh);
    }
    if (f.dof[1] > 0) {
      gl.useProgram(focus.p);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, post.scene.color);
      gl.activeTexture(gl.TEXTURE1);
      gl.bindTexture(gl.TEXTURE_2D, post.scene.depth);
      gl.uniform1i(focus.u.uColor, 0);
      gl.uniform1i(focus.u.uDepth, 1);
      gl.uniform2f(focus.u.uRes, post.w, post.h);
      gl.uniform2f(focus.u.uScale, sx, sy);
      gl.uniform4fv(focus.u.uDof, f.dof);
      gl.uniform3fv(focus.u.uFx, f.fx);
      pass(focus, post.focus.fb, W / 2, H / 2);
    }
    gl.useProgram(final.p);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, post.scene.color);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, post.scene.depth);
    gl.activeTexture(gl.TEXTURE2);
    gl.bindTexture(gl.TEXTURE_2D, post.a.color);
    gl.activeTexture(gl.TEXTURE3);
    gl.bindTexture(gl.TEXTURE_2D, post.focus.color);
    gl.uniform1i(final.u.uBlur, 3);
    gl.uniform1i(final.u.uColor, 0);
    gl.uniform1i(final.u.uDepth, 1);
    gl.uniform1i(final.u.uBloom, 2);
    gl.uniform2f(final.u.uRes, post.w, post.h);
    gl.uniform2f(final.u.uScale, sx, sy);
    gl.uniform4fv(final.u.uDof, f.dof);
    gl.uniform3fv(final.u.uFx, f.fx);
    pass(final, null, canvas.width, canvas.height);
    gl.activeTexture(gl.TEXTURE0);
  }

  function finishScreens(items, f) {
    const screens = items.filter(it => it.inV && it.kind === 10 && it.tex);
    if (!screens.length) return;
    let left = canvas.width, bottom = canvas.height, right = 0, top = 0;
    for (const it of screens) {
      const data = geometry.get(it.mesh), clip = M.mul(f.vp, it.model);
      for (let i = 0; i < data.p.length; i += 3) {
        const p = M.pt(clip, data.p[i], data.p[i + 1], data.p[i + 2]);
        if (p[3] <= 0) continue;
        const x = (p[0] * 0.5 + 0.5) * canvas.width, y = (p[1] * 0.5 + 0.5) * canvas.height;
        left = Math.min(left, x); right = Math.max(right, x); bottom = Math.min(bottom, y); top = Math.max(top, y);
      }
    }
    left = Math.max(0, Math.floor(left) - 2); bottom = Math.max(0, Math.floor(bottom) - 2);
    right = Math.min(canvas.width, Math.ceil(right) + 2); top = Math.min(canvas.height, Math.ceil(top) + 2);
    if (right <= left || top <= bottom) return;
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.enable(gl.SCISSOR_TEST); gl.scissor(left, bottom, right - left, top - bottom);
    gl.enable(gl.DEPTH_TEST); gl.depthMask(true); gl.clearDepth(1); gl.clear(gl.DEPTH_BUFFER_BIT);
    gl.colorMask(false, false, false, false);
    gl.useProgram(depth.p); gl.uniformMatrix4fv(depth.u.uVP, false, f.vp);
    for (const it of items) {
      if (!it.inV || it.kind === 10) continue;
      gl.uniformMatrix4fv(depth.u.uModel, false, it.model);
      gl.bindVertexArray(it.mesh.vao); gl.drawElements(gl.TRIANGLES, it.mesh.count, it.mesh.type, 0); calls++;
    }
    gl.colorMask(true, true, true, true);
    gl.useProgram(main.p);
    gl.uniform2f(main.u.uRes, canvas.width, canvas.height);
    const lit = f.lit || LIT, sx = canvas.width / renderW, sy = canvas.height / renderH;
    gl.uniform4f(main.u.uLit, lit[0] * sx, lit[1] * sy, lit[2] * sx, lit[3] * sy);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, shadowTex);
    for (const it of screens) {
      gl.uniformMatrix4fv(main.u.uModel, false, it.model); gl.uniform1i(main.u.uKind, 10);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, it.tex.t || it.tex);
      gl.bindVertexArray(it.mesh.vao); gl.drawElements(gl.TRIANGLES, it.mesh.count, it.mesh.type, 0); calls++;
    }
    gl.disable(gl.SCISSOR_TEST); gl.disable(gl.DEPTH_TEST);
  }

  function drawList(prog, items, shadowPass) {
    const u = prog.u;
    for (const it of items) {
      if (shadowPass ? !it.inS : !it.inV) continue;
      gl.uniformMatrix4fv(u.uModel, false, it.model);
      if (!shadowPass) {
        gl.uniform1i(u.uKind, it.kind || 0);
        gl.uniform3fv(u.uBaseA, it.baseA);
        gl.uniform3fv(u.uBaseB, it.baseB || it.baseA);
        gl.uniform3fv(u.uEmitA, it.emitA || ZERO);
        gl.uniform3fv(u.uEmitB, it.emitB || it.emitA || ZERO);
        gl.uniform1f(u.uMetal, it.metal || 0);
        gl.uniform1f(u.uRough, it.rough == null ? 0.6 : it.rough);
        gl.uniform4fv(u.uP, it.p || ZERO4);
        gl.uniform4fv(u.uQ, it.q || ZERO4);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, it.tex ? (it.tex.t || it.tex) : white);
      }
      gl.bindVertexArray(it.mesh.vao);
      gl.drawElements(gl.TRIANGLES, it.mesh.count, it.mesh.type, 0);
      calls++;
    }
  }
  const ZERO = new Float32Array(3), ZERO4 = new Float32Array(4), LIT = new Float32Array([0, 0, 1e9, 1e9]);

  function render(items, f) {
    if (lost || document.hidden) return false;
    if (timer) {
      while (waiting.length && gl.getQueryParameter(waiting[0], gl.QUERY_RESULT_AVAILABLE)) {
        const q = waiting.shift();
        if (!gl.getParameter(timer.GPU_DISJOINT_EXT) && warmup-- <= 0) { const ms = gl.getQueryParameter(q, gl.QUERY_RESULT) / 1e6; cost = cost ? cost + (ms - cost) * 0.15 : ms; }
        gl.deleteQuery(q);
      }
    }
    const fx = post.ok && f.post !== false;
    planes(f.vp, PV);
    planes(f.shadowVP, PS);
    hh = 2166136261;
    ha(f.shadowVP);
    for (const it of items) {
      it.inS = it.vis !== false && it.cast !== false && inside(it, PS, 16);
      if (!it.inS) continue;
      if (it.spin) hx(7); else ha(it.model);
      hx(it.mesh.rev || 0); hx(it.mesh.count);
    }
    const sigS = hh;
    let cable = false;
    hx(canvas.width); hx(canvas.height); hx(renderW); hx(renderH); hx(fx ? 1 : 0);
    ha(f.vp); ha(f.eye); hx(f.fade); ha(f.spot); hx(f.shadowR * 4096); hx(f.bias * 4096); hx(f.live || 0);
    ha(f.lit || LIT); ha(f.dark || ZERO4); hx(f.front == null ? 1e6 : f.front);
    ha(f.occA); ha(f.occB); ha(f.occH); hx(f.occN); ha(f.lamps); ha(f.lampC); ha(f.dof); ha(f.fx); ha(f.clear);
    for (const it of items) {
      it.inV = it.vis !== false && inside(it, PV, 24);
      if (!it.inV) continue;
      ha(it.model); hx(it.kind || 0); hx(it.mesh.rev || 0);
      if (it.p) ha(it.p);
      if (it.q) ha(it.q);
      if (it.emitA) ha(it.emitA);
      if (it.emitB) ha(it.emitB);
      ha(it.baseA);
      if (it.baseB) ha(it.baseB);
      hx(it.metal || 0); hx(it.rough == null ? 0.6 : it.rough);
      const tx = it.tex ? (it.tex.t || it.tex) : null;
      hx(tx ? tx.id || 0 : 0);
      if (it.kind === 9) cable = true;
    }
    if (cable && f.live > 0.001) hx(f.beats || 0);
    if (hh === sigMain && !always) return false;
    sigMain = hh;
    calls = 0;
    if (timer && !timing && waiting.length < 3) { timing = gl.createQuery(); gl.beginQuery(timer.TIME_ELAPSED_EXT, timing); }
    gl.enable(gl.DEPTH_TEST);
    gl.disable(gl.CULL_FACE);
    if (sigS !== sigShadow) {
      sigShadow = sigS;
      gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
      gl.viewport(0, 0, SM, SM);
      gl.clearDepth(1);
      gl.clear(gl.DEPTH_BUFFER_BIT);
      gl.useProgram(depth.p);
      gl.uniformMatrix4fv(depth.u.uVP, false, f.shadowVP);
      gl.enable(gl.POLYGON_OFFSET_FILL);
      gl.polygonOffset(1.5, 2);
      drawList(depth, items, true);
      gl.disable(gl.POLYGON_OFFSET_FILL);
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, fx ? post.ms.fb : null);
    gl.viewport(0, 0, renderW, renderH);
    gl.clearColor(f.clear[0], f.clear[1], f.clear[2], fx ? 0 : 1);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.useProgram(main.p);
    const u = main.u;
    gl.uniformMatrix4fv(u.uVP, false, f.vp);
    gl.uniformMatrix4fv(u.uShadowVP, false, f.shadowVP);
    gl.uniform3fv(u.uCam, f.eye);
    gl.uniform2f(u.uRes, renderW, renderH);
    gl.uniform1f(u.uFade, f.fade);
    gl.uniform1f(u.uTime, f.time);
    gl.uniform3fv(u.uSpot, f.spot);
    gl.uniform1f(u.uShadowR, f.shadowR);
    gl.uniform1f(u.uBias, f.bias);
    gl.uniform1f(u.uBeat, f.beat || 0);
    gl.uniform1f(u.uBeats, f.beats || 0);
    gl.uniform1f(u.uLive, f.live || 0);
    gl.uniform4fv(u.uLit, f.lit || LIT);
    gl.uniform4fv(u.uDark, f.dark || ZERO4);
    gl.uniform1f(u.uFront, f.front == null ? 1e6 : f.front);
    gl.uniform4fv(u.uOccA, f.occA);
    gl.uniform4fv(u.uOccB, f.occB);
    gl.uniform1fv(u.uOccH, f.occH);
    gl.uniform1i(u.uOccN, f.occN);
    gl.uniform4fv(u.uLamp, f.lamps);
    gl.uniform3fv(u.uLampC, f.lampC);
    gl.uniform1i(u.uTex, 0);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, shadowTex);
    gl.uniform1i(u.uShadow, 1);
    gl.colorMask(true, true, true, fx);
    drawList(main, items, false);
    gl.colorMask(true, true, true, true);
    if (fx) { finish(f); finishScreens(items, f); }
    gl.bindVertexArray(null);
    if (timing) { gl.endQuery(timer.TIME_ELAPSED_EXT); waiting.push(timing); timing = null; }
    drawAt = performance.now();
    drawn++;
    return true;
  }

  return { gl, mesh, dynamic, texture, updateTexture, batch, image, resize, render, get cost() { return performance.now() - drawAt < 300 ? cost : 0; }, get drawn() { return drawn; }, get calls() { return calls; }, set always(v) { always = !!v; }, get lost() { return lost; }, get post() { return post.ok; }, get resolution() { return [renderW, renderH]; } };
}
