(() => {
  const { M, plugAt, routeAt, HIDE } = Cable;
  const A = window.SoundingArt;
  const { ripple } = window.CableV1;

  function pickMid(geo) {
    const target = { x: geo.w * 0.36, y: geo.h * 0.8 };
    let best = 0.5, bestD = Infinity;
    for (let u = 0.25; u <= 0.8; u += 0.005) {
      const { p } = routeAt(geo, u);
      if (p.x < geo.w * 0.08 || p.x > geo.w * 0.92 || p.y > geo.h * 0.92) continue;
      const d = Math.hypot(p.x - target.x, p.y - target.y);
      if (d < bestD) { bestD = d; best = u; }
    }
    return best;
  }

  function segFrac(pts) {
    const l = A.lengths(pts);
    const t = l[l.length - 1] || 1;
    return l.map(v => v / t);
  }

  function play(ctx) {
    const { geo, layers, palette } = ctx;
    const um = pickMid(geo);
    const rm = routeAt(geo, um);
    const km = rm.k;
    const R = geo.s * 0.085;
    const nrm = { x: Math.sin(rm.angle), y: -Math.cos(rm.angle) };
    const side = nrm.y < 0 ? 1 : -1;
    const C = { x: rm.p.x + nrm.x * R * side, y: rm.p.y + nrm.y * R * side };

    const t0 = 420, layDur = 1350, farDur = 1000;
    const nearFracs = [];
    geo.contours.forEach((c, i) => {
      const paths = [];
      nearFracs[i] = [];
      c.cablePoints.forEach((pts, h) => {
        const far = pts.slice(0, km + 1).reverse();
        const near = pts.slice(km);
        nearFracs[i][h] = segFrac(near);
        paths.push(A.stroke(A.poly(far), palette.inks[c.tone], c.width, 'data-seg="far"'));
        paths.push(A.stroke(A.poly(near), palette.inks[c.tone], c.width, 'data-seg="near"'));
      });
      layers.cables[i].innerHTML = paths.join('');
    });

    const turns = 3.4, coilLines = geo.contours.map((c, i) => {
      const pts = [];
      const Θ = turns * Math.PI * 2;
      for (let s = 0; s <= 220; s++) {
        const th = (s / 220) * Θ;
        const r = R * (0.16 + 0.84 * (th / Θ)) + (i - 2) * geo.layout.echoGap * 0.45;
        pts.push({ x: C.x + Math.cos(th + rm.angle) * r, y: C.y + Math.sin(th + rm.angle) * r });
      }
      return A.stroke(A.poly(pts), palette.inks[c.tone], c.width);
    }).join('');
    const pad = R * 1.4;
    const coil = A.svgLayer(layers.root, { x: C.x - pad, y: C.y - pad, w: pad * 2, h: pad * 2 }, coilLines, 'coil').origin(C.x, C.y);

    M.animate(coil, [
      { opacity: 0, transform: 'scale(.15) rotate(-200deg)' },
      { opacity: 1, transform: 'scale(1.06) rotate(-20deg)', offset: 0.7 },
      { opacity: 1, transform: 'scale(1) rotate(0deg)' },
    ], { duration: t0 + 80, easing: M.ease.out });
    M.animate(coil, [
      { transform: 'scale(1) rotate(0deg)', opacity: 1 },
      { transform: 'scale(.55) rotate(-540deg)', opacity: 1, offset: 0.6 },
      { transform: 'scale(.08) rotate(-900deg)', opacity: 0 },
    ], { delay: t0 + 80, duration: layDur - 80, easing: M.ease.inOut, fill: 'forwards' });

    const fps = 60, settle = 650, total = layDur + settle, n = Math.ceil((total / 1000) * fps);
    const tf = [], dash = geo.contours.map(() => [[], []]);
    for (let s = 0; s <= n; s++) {
      const tms = (s / n) * total, offset = s / n;
      const x = Math.min(1, tms / layDur);
      const e = M.easeFn.inOutCubic(x);
      const u = um + (1 - um) * e;
      const after = Math.max(0, tms - layDur) / 1000;
      const wob = after > 0 ? 3 * Math.exp(-after * 7) * Math.sin(after * 2 * Math.PI * 2.4) : 0;
      const { transform, r } = plugAt(geo, u, wob, 0.06);
      tf.push({ transform, offset });
      const idx = r.k + r.t - km;
      geo.contours.forEach((c, i) => [0, 1].forEach(h => {
        const fr = nearFracs[i][h];
        const k = Math.max(0, Math.min(fr.length - 2, Math.floor(idx)));
        const v = idx <= 0 || s === 0 ? 0 : fr[k] + (fr[k + 1] - fr[k]) * Math.min(1, idx - k);
        dash[i][h].push({ strokeDashoffset: 1 - v, offset });
      }));
    }
    const opts = { delay: t0, duration: total, easing: 'linear' };
    [layers.plug, layers.knurl, ...layers.plugs].forEach(el => M.animate(el, tf, opts));
    [...layers.plugs, layers.plug].forEach(el => M.animate(el, [{ opacity: 0, transform: tf[0].transform }, { opacity: 1, transform: tf[0].transform }], { delay: t0 - 120, duration: 200, fill: 'backwards', composite: 'replace' }));
    ctx.draw(layers.knurl, { delay: t0 + layDur - 250, duration: 450, easing: M.ease.out });

    layers.cables.forEach((el, i) => {
      el.querySelectorAll('path').forEach(p => (p.style.strokeDasharray = '1 2'));
      const near = el.querySelectorAll('[data-seg="near"]');
      near.forEach((p, h) => M.animate(p, dash[i][h], opts));
      el.querySelectorAll('[data-seg="far"]').forEach(p => M.animate(p, [{ strokeDashoffset: 1 }, { strokeDashoffset: 0 }], { delay: t0 + i * 25, duration: farDur, easing: M.ease.out }));
    });

    layers.masses.forEach((el, i) => {
      const m = geo.masses[i];
      const dx = (C.x - m.center.x) * 0.85, dy = (C.y - m.center.y) * 0.85;
      const sp = M.springEasing({ zeta: 0.62, response: 0.9 });
      M.animate(el, [
        { opacity: 0, transform: `translate(${dx.toFixed(1)}px, ${dy.toFixed(1)}px) scale(.08)` },
        { opacity: 1, transform: 'none' },
      ], { delay: t0 + 150 + i * 170, duration: sp.duration, easing: sp.easing });
    });
    layers.cone.forEach((el, i) => ctx.draw(el, { delay: t0 + 700 + i * 90, duration: 1100 }));
    layers.waves.forEach((el, i) => ctx.draw(el, { delay: t0 + 700 + i * 70, duration: 1300 }));
    ripple(ctx, t0 + layDur - 120, { stagger: 55, duration: 720 });
    ctx.idle(ctx, { delay: t0 + total + 400 });
  }

  Cable.page({
    id: 'v3',
    title: 'Unspool',
    shells: ['zine', 'calm', 'club'],
    buildOptions: () => ({ split: true }),
    play,
  });
})();
