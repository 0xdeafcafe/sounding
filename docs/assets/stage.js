import { M, createRenderer } from './gl.js';
import { buildWorld, L } from './world.js';

const RAD = Math.PI / 180;
const LD = [-0.4196, 0.7993, 0.4296];

export function createStage(canvas, base, opts = {}) {
  const R = createRenderer(canvas, opts);
  if (!R) return null;
  let world;
  try { world = buildWorld(R, base); } catch (e) { console.error(e); return null; }
  const cam = { t: [0, 0, 0], yaw: 0, pitch: 50, w: 1.4, fov: 28, ox: 0, oy: 0 };
  let W = 1, H = 1, dpr = 1;
  let vp = M.id(), eye = [0, 1, 1], near = 0.1, far = 40;
  let fresh = false, ticks = 0;
  const fx = { dof: 1, bloom: 1, vig: 1 };
  const light = { k: 1, cx: 0, cy: 0, rx: 1e9, ry: 1e9, u: new Float32Array([0, 0, 1e9, 1e9]) };
  const lightView = M.look([LD[0] * 6, LD[1] * 6, LD[2] * 6], [0, 0, 0], [0, 1, 0]);

  function resize(w, h, ratio) {
    W = w; H = h;
    dpr = Math.min(ratio, 2);
    R.resize(w, h, dpr);
  }

  const quint = t => { t = Math.max(0, Math.min(1, t)); return t * t * t * (t * (t * 6 - 15) + 10); };

  function matrices() {
    const aspect = W / H;
    const vf = cam.fov * RAD;
    const hf = 2 * Math.atan(Math.tan(vf / 2) * aspect);
    const dist = cam.w / 2 / Math.tan(hf / 2);
    const cp = Math.cos(cam.pitch * RAD), sp = Math.sin(cam.pitch * RAD), cy = Math.cos(cam.yaw * RAD), sy = Math.sin(cam.yaw * RAD);
    const fit = quint((0.55 - cam.w) / 0.15) * (1 - quint((Math.hypot(cam.t[0] - L.socket[0], cam.t[2] - L.socket[2]) - 0.12) / 0.18)) * quint((world.S.jack.tip[1] + L.jack.depth - L.jack.rim) / (0.044 + L.jack.depth));
    const target = [cam.t[0] + 0.055 * world.S.jack.axis[0] * fit, cam.t[1] + 0.055 * fit, cam.t[2]];
    eye = [target[0] + dist * sy * cp, target[1] + dist * sp, target[2] + dist * cy * cp];
    const view = M.look(eye, target, [0, 1, 0]);
    near = Math.max(0.02, dist * 0.05); far = dist * 6 + 30;
    const proj = M.persp(vf, aspect, near, far, cam.ox, cam.oy);
    vp = M.mul(proj, view);
    return dist;
  }

  function render(time) {
    if (document.hidden) { fresh = false; return 0; }
    const dist = matrices();
    world.update();
    let half = 0.3;
    const need = Math.max(cam.w * 0.72, 0.3) + (cam.pitch < 40 ? (cam.w < 0.5 ? 0.16 : 0.5) : 0);
    while (half < need) half *= 1.3;
    const texel = (2 * half) / (opts.shadowSize || 2048);
    const c = M.pt(lightView, cam.t[0], 0, cam.t[2]);
    const cx = Math.round(c[0] / texel) * texel, cy2 = Math.round(c[1] / texel) * texel;
    const shadowVP = M.mul(M.ortho(cx - half, cx + half, cy2 - half, cy2 + half, 0.5, 14), lightView);
    const soft = Math.min(0.008, Math.max(0.0008, cam.w * 0.004));
    const f = world.frame(cam.t);
    const k = Math.min(1, Math.max(0, light.k));
    if (k >= 1) { light.rx = light.ry = 1e9; light.u.set([0, 0, 1e9, 1e9]); }
    else if (k <= 0) { light.rx = light.ry = 0; light.u.set([0, 0, 0, 0]); }
    else {
      const s = project(L.socket[0], L.socket[1], L.socket[2]);
      const cw = Math.cos(cam.yaw * RAD), sw = Math.sin(cam.yaw * RAD);
      const a = project(L.socket[0] + cw * 0.05, L.socket[1], L.socket[2] - sw * 0.05), b = project(L.socket[0] + sw * 0.05, L.socket[1], L.socket[2] + cw * 0.05);
      const reach = (0.4 * k + 4 * Math.pow(k, 3.4) + 12 * Math.pow(k, 12)) * 1.74 / (1 - 0.999 * Math.pow(k, 20));
      const rx = reach * Math.hypot(a[0] - s[0], a[1] - s[1]) / 0.05, ry = reach * Math.hypot(b[0] - s[0], b[1] - s[1]) / 0.05;
      light.cx = s[0]; light.cy = s[1]; light.rx = rx; light.ry = ry;
      light.u.set([s[0] * dpr, (H - s[1]) * dpr, Math.max(1, rx * dpr), Math.max(1, ry * dpr)]);
    }
    const night = 1 + (world.S.fade - 1) * k;
    const macro = cam.w < 0.55 && Math.hypot(cam.t[0] - L.socket[0], cam.t[2] - L.socket[2]) < 0.3;
    ticks++;
    fresh = R.render(world.items, { vp, shadowVP, eye, fade: world.S.fade, time, spot: cam.t, shadowR: soft / (2 * half), bias: 0.0009 + texel * 1.2, beat: world.S.beat, beats: world.S.beats || 0, live: world.S.live || 0, clear: [0.1, 0.1, 0.1], dof: [dist, (macro ? fx.dof : 0) * 30 * dpr * Math.min(1, 0.62 / cam.w), near, far], fx: [fx.bloom * (0.55 + 0.75 * night), (0.1 + 0.22 * night) * fx.vig, 13 * dpr], occA: f.occA, occB: f.occB, occH: f.occH, occN: f.occN, lamps: f.lamps, lampC: f.lampC, lit: light.u, dark: f.dark, front: f.front });
    return dist;
  }

  const tap = { buf: null, sync: null, size: 0, px: null, w: 0, rows: [], out: null, id: 0, dead: false };
  function probe(rows) {
    const gl = R.gl;
    if (tap.dead || R.lost) return null;
    try {
      const w = canvas.width, h = canvas.height, size = w * 4 * rows.length;
      if (size !== tap.size) {
        if (tap.sync) { gl.deleteSync(tap.sync); tap.sync = null; }
        tap.buf = tap.buf || gl.createBuffer();
        gl.bindBuffer(gl.PIXEL_PACK_BUFFER, tap.buf);
        gl.bufferData(gl.PIXEL_PACK_BUFFER, size, gl.STREAM_READ);
        gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
        tap.size = size; tap.px = new Uint8Array(size); tap.out = null;
      }
      if (tap.sync) {
        const state = gl.clientWaitSync(tap.sync, 0, 0);
        if (state === gl.TIMEOUT_EXPIRED) return tap.out;
        gl.deleteSync(tap.sync); tap.sync = null;
        if (state !== gl.WAIT_FAILED) {
          gl.bindBuffer(gl.PIXEL_PACK_BUFFER, tap.buf);
          gl.getBufferSubData(gl.PIXEL_PACK_BUFFER, 0, tap.px);
          gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
          tap.out = { px: tap.px, w: tap.w, n: tap.rows.length, rows: tap.rows, id: ++tap.id };
        }
      }
      if (!fresh) return tap.out;
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.bindBuffer(gl.PIXEL_PACK_BUFFER, tap.buf);
      for (let i = 0; i < rows.length; i++) gl.readPixels(0, Math.max(0, h - 1 - Math.round(rows[i] * h / H)), w, 1, gl.RGBA, gl.UNSIGNED_BYTE, i * w * 4);
      gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
      tap.sync = gl.fenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0);
      gl.flush();
      tap.w = w; tap.rows = rows;
    } catch (err) { tap.dead = true; return null; }
    return tap.out;
  }

  function css(model, pw, ph, ww) {
    const s = ww / pw;
    const wh = s * ph;
    const l = M.chain(vp, model, M.t(-ww / 2, wh / 2, 0));
    const m = new Float32Array(16);
    for (let c = 0; c < 4; c++) {
      const k = c === 0 ? s : c === 1 ? -s : 1;
      const x = l[c * 4] * k, y = l[c * 4 + 1] * k, w = l[c * 4 + 3] * k;
      m[c * 4] = (x + w) * W / 2;
      m[c * 4 + 1] = (w - y) * H / 2;
      m[c * 4 + 2] = 0;
      m[c * 4 + 3] = w;
    }
    m[10] = 1;
    return m;
  }

  function project(x, y, z) {
    const p = M.pt(vp, x, y, z);
    return [(p[0] * 0.5 + 0.5) * W, (0.5 - p[1] * 0.5) * H, p[3]];
  }

  function ray(px, py) {
    const inv = M.inv(vp);
    const nx = (px / W) * 2 - 1, ny = 1 - (py / H) * 2;
    const a = M.pt(inv, nx, ny, -1), b = M.pt(inv, nx, ny, 1);
    const d = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
    const l = Math.hypot(d[0], d[1], d[2]);
    return { o: [a[0], a[1], a[2]], d: [d[0] / l, d[1] / l, d[2] / l] };
  }

  function hitY(px, py, y) {
    const r = ray(px, py);
    if (Math.abs(r.d[1]) < 1e-5) return null;
    const t = (y - r.o[1]) / r.d[1];
    if (t < 0) return null;
    return [r.o[0] + r.d[0] * t, r.o[2] + r.d[2] * t];
  }

  return { R, world, cam, fx, light, resize, render, css, project, probe, ray, hitY, L, get size() { return [W, H, dpr]; }, get fresh() { return fresh; }, get frames() { return R.drawn; }, get ticks() { return ticks; } };
}
