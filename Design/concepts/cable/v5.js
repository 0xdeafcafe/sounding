(() => {
  const { M, HIDE } = Cable;
  const A = window.SoundingArt;
  const { ripple } = window.CableV1;
  const N = 30;

  function resample(pts, n) {
    const cum = A.lengths(pts), total = cum[cum.length - 1];
    const out = [];
    let k = 0;
    for (let i = 0; i < n; i++) {
      const d = (i / (n - 1)) * total;
      while (k < pts.length - 2 && cum[k + 1] < d) k++;
      const t = (d - cum[k]) / (cum[k + 1] - cum[k] || 1);
      out.push({ x: pts[k].x + (pts[k + 1].x - pts[k].x) * t, y: pts[k].y + (pts[k + 1].y - pts[k].y) * t });
    }
    return out;
  }

  function smoothLine(pts) {
    const out = [];
    for (let i = 0; i < pts.length - 1; i++) {
      const p0 = pts[Math.max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[Math.min(pts.length - 1, i + 2)];
      for (let s = 0; s < 4; s++) {
        const t = s / 4, t2 = t * t, t3 = t2 * t;
        out.push({
          x: 0.5 * (2 * p1.x + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3),
          y: 0.5 * (2 * p1.y + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3),
        });
      }
    }
    out.push(pts[pts.length - 1]);
    return out;
  }

  function setup(ctx) {
    const { geo, layers, host, palette } = ctx;
    const canvas = document.createElement('canvas');
    const dpr = Math.min(2, devicePixelRatio || 1);
    canvas.width = Math.round(geo.w * dpr);
    canvas.height = Math.round(geo.h * dpr);
    canvas.setAttribute('aria-hidden', 'true');
    host.appendChild(canvas);
    const g = canvas.getContext('2d');
    g.scale(dpr, dpr);

    const rest = resample(geo.route.points, N);
    const anchor = rest[0];
    const seg = (geo.route.total * 0.8) / (N - 1);
    const start = { x: geo.w * 0.52, y: geo.h * 0.42 };
    const pts = rest.map((p, i) => {
      const t = i / (N - 1);
      return { x: anchor.x + (start.x - anchor.x) * t, y: anchor.y + (start.y - anchor.y) * t + Math.sin(t * Math.PI) * geo.h * 0.25 };
    });
    const prev = pts.map(p => ({ ...p }));

    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'plug-btn';
    btn.textContent = 'Plug in';
    host.parentElement.appendChild(btn);
    const hint = document.createElement('p');
    hint.className = 'hint';
    hint.textContent = matchMedia('(pointer: fine)').matches ? 'Move to swing the lead. Click to plug it in.' : 'Tap to plug it in.';
    host.parentElement.appendChild(hint);

    const hide = [...layers.contours, layers.plug, layers.knurl, ...layers.rings];
    hide.forEach(el => (el.style.opacity = 0));
    layers.masses.forEach(el => (el.style.opacity = 0.55));
    layers.cone.forEach(el => (el.style.opacity = 0.5));

    return { canvas, g, pts, prev, rest, anchor, seg, angle: -0.4, head: { ...start }, target: { ...start }, lastPointer: -1e9, mode: 'loose', t: 0, tween: 0, from: null, btn, hint, hide, fine: matchMedia('(pointer: fine)').matches };
  }

  function step(ctx, S, dt) {
    const { geo } = ctx;
    S.t += dt;
    const L = geo.length;
    const pts = S.pts, prev = S.prev;
    if (S.mode === 'loose') {
      const idle = S.t - S.lastPointer > 1.6 || !S.fine;
      if (idle) {
        const cx = geo.w * (ctx.mobile ? 0.55 : 0.6), cy = geo.h * (ctx.mobile && ctx.shell === 'club' ? 0.26 : 0.42);
        S.target = { x: cx + Math.sin(S.t * 0.9) * geo.w * 0.14, y: cy + Math.sin(S.t * 1.3 + 0.6) * geo.h * 0.12 };
      }
      const dir = { x: Math.cos(S.angle), y: Math.sin(S.angle) };
      const want = { x: S.target.x - dir.x * L * 0.3, y: S.target.y - dir.y * L * 0.3 };
      const k = 1 - Math.exp(-dt * 9);
      S.head.x += (want.x - S.head.x) * k;
      S.head.y += (want.y - S.head.y) * k;
      const grav = 2200 * dt * dt;
      for (let i = 1; i < N - 1; i++) {
        const p = pts[i], q = prev[i];
        const vx = (p.x - q.x) * 0.985, vy = (p.y - q.y) * 0.985;
        q.x = p.x; q.y = p.y;
        p.x += vx; p.y += vy + grav;
      }
      for (let it = 0; it < 24; it++) {
        pts[0].x = S.anchor.x; pts[0].y = S.anchor.y;
        pts[N - 1].x = S.head.x; pts[N - 1].y = S.head.y;
        for (let i = 0; i < N - 1; i++) {
          const a = pts[i], b = pts[i + 1];
          const dx = b.x - a.x, dy = b.y - a.y, d = Math.hypot(dx, dy) || 1e-3;
          if (d <= S.seg) continue;
          const diff = (d - S.seg) / d * 0.5;
          const wa = i === 0 ? 0 : 1, wb = i + 1 === N - 1 ? 0 : 1;
          const s = wa + wb || 1;
          a.x += dx * diff * (2 * wa / s); a.y += dy * diff * (2 * wa / s);
          b.x -= dx * diff * (2 * wb / s); b.y -= dy * diff * (2 * wb / s);
        }
      }
      const tail = pts[N - 4];
      const want2 = Math.atan2(S.head.y - tail.y, S.head.x - tail.x);
      let da = want2 - S.angle;
      while (da > Math.PI) da -= 2 * Math.PI;
      while (da < -Math.PI) da += 2 * Math.PI;
      S.angle += da * (1 - Math.exp(-dt * 10));
    } else if (S.mode === 'tween') {
      S.tween = Math.min(1, S.tween + dt / 0.95);
      const e = M.easeFn.inOutCubic(S.tween);
      const over = S.tween < 1 ? 0 : 0;
      pts.forEach((p, i) => {
        p.x = S.from.pts[i].x + (S.rest[i].x - S.from.pts[i].x) * e + over;
        p.y = S.from.pts[i].y + (S.rest[i].y - S.from.pts[i].y) * e;
      });
      let da = geo.angle - S.from.angle;
      while (da > Math.PI) da -= 2 * Math.PI;
      while (da < -Math.PI) da += 2 * Math.PI;
      S.angle = S.from.angle + da * e;
      S.head = pts[N - 1];
      if (S.tween >= 1) { S.mode = 'done'; finish(ctx, S); }
    }
  }

  function render(ctx, S) {
    const { geo, palette } = ctx;
    const g = S.g;
    g.clearRect(0, 0, geo.w, geo.h);
    const L = geo.length;
    const tipDir = { x: Math.cos(S.angle), y: Math.sin(S.angle) };
    const tip = { x: S.head.x + tipDir.x * L, y: S.head.y + tipDir.y * L };
    const frame = A.plugFrame(tip, S.angle, L);
    const line = smoothLine(S.pts).reverse();
    const cable = line.map((p, i) => {
      const a = line[Math.max(0, i - 1)], b = line[Math.min(line.length - 1, i + 1)];
      const tx = b.x - a.x, ty = b.y - a.y, m = Math.hypot(tx, ty) || 1;
      return { p, n: { x: ty / m, y: -tx / m } };
    });
    cable[0].n = { ...frame.nrm };
    g.lineCap = g.lineJoin = 'round';
    const outline = A.plugOutline(frame);
    g.fillStyle = palette.ground;
    g.beginPath();
    outline.forEach((p, i) => (i ? g.lineTo(p.x, p.y) : g.moveTo(p.x, p.y)));
    g.closePath();
    g.fill();
    geo.contours.forEach((c, i) => {
      const { a, b } = A.contourPoints(frame, cable, L, i, geo.layout.echoGap);
      g.strokeStyle = palette.inks[c.tone];
      g.lineWidth = c.width;
      g.beginPath();
      a.forEach((p, k) => (k ? g.lineTo(p.x, p.y) : g.moveTo(p.x, p.y)));
      for (let k = b.length - 1; k >= 0; k--) g.lineTo(b[k].x, b[k].y);
      g.stroke();
    });
    g.strokeStyle = palette.inks[geo.knurl.tone];
    g.lineWidth = geo.knurl.width;
    g.beginPath();
    A.knurlSegments(frame).forEach(([p, q]) => { g.moveTo(p.x, p.y); g.lineTo(q.x, q.y); });
    g.stroke();
  }

  function plugIn(ctx, S) {
    if (S.mode !== 'loose') return;
    S.mode = 'tween';
    S.tween = 0;
    S.from = { pts: S.pts.map(p => ({ ...p })), angle: S.angle };
    S.hint.style.opacity = 0;
    S.btn.disabled = true;
    S.btn.textContent = 'Plugged in';
  }

  function finish(ctx, S) {
    const { layers } = ctx;
    S.hide.forEach(el => { if (!layers.rings.includes(el)) el.style.opacity = 1; });
    layers.rings.forEach(el => (el.style.opacity = ''));
    S.canvas.style.opacity = 0;
    ripple(ctx, 0, { stagger: 55, duration: 700 });
    layers.masses.forEach((el, i) => M.animate(el, [{ opacity: 0.55, transform: 'scale(.97)' }, { opacity: 1, transform: 'none' }], { duration: 900, delay: i * 90, easing: M.ease.out }));
    layers.cone.forEach((el, i) => M.animate(el, [{ opacity: 0.5 }, { opacity: 1 }], { duration: 700, delay: i * 60 }));
    const glow = document.querySelector('.glow');
    if (glow) M.animate(glow, [{ opacity: 0.4 }, { opacity: 1.3, offset: 0.2 }, { opacity: 1 }], { duration: 1200 });
    ctx.idle(ctx, { delay: 900 });
  }

  let current = null;
  function start(ctx, opts = {}) {
    const S = setup(ctx);
    current = S;
    const glow = document.querySelector('.glow');
    if (glow) glow.style.opacity = 0.4;
    const hero = document.querySelector('.hero');
    const onMove = e => {
      const r = ctx.host.getBoundingClientRect();
      S.target = { x: e.clientX - r.left, y: e.clientY - r.top };
      S.lastPointer = S.t;
    };
    const onClick = e => { if (e.target.closest('a, button:not(.plug-btn)')) return; plugIn(ctx, S); };
    hero.onpointermove = e => { if (e.pointerType === 'mouse') onMove(e); };
    hero.onclick = onClick;
    S.btn.onclick = e => { e.stopPropagation(); plugIn(ctx, S); };
    if (opts.demo) {
      const path = t => ({ x: ctx.geo.w * ((ctx.mobile ? 0.25 : 0.5) + (ctx.mobile ? 0.5 : 0.3) * t), y: ctx.geo.h * (ctx.mobile ? 0.34 - 0.12 * Math.sin(t * Math.PI) : 0.62 - 0.4 * Math.sin(t * Math.PI) + 0.08 * t) });
      let dt0 = 0;
      M.loop(dt => {
        dt0 += dt;
        if (S.mode !== 'loose') return false;
        S.target = path(Math.min(1, dt0 / 1.6));
        S.lastPointer = S.t;
      });
      M.after(1900, () => plugIn(ctx, S));
    }
    M.loop(dt => {
      step(ctx, S, dt);
      if (S.mode !== 'done') render(ctx, S);
      return S.mode !== 'done';
    });
  }

  function still(ctx) {
    const b = document.querySelector('.plug-btn');
    if (b) b.remove();
    const h = document.querySelector('.hero .hint');
    if (h) h.remove();
  }

  let demoFlag = false;
  Cable.page({
    id: 'v5',
    title: 'Loose lead',
    shells: ['club', 'calm'],
    play: ctx => { still(ctx); start(ctx, { demo: demoFlag || Cable.params.has('demo') }); },
    still,
    demo: (ctx, play) => { demoFlag = true; play(); demoFlag = false; },
  });
})();
