(() => {
  const { M, HIDE } = Cable;
  const A = window.SoundingArt;
  const { ripple } = window.CableV1;

  function socket(root, geo, palette) {
    const c = geo.frame.world(0.075, 0);
    const L = geo.length;
    const radii = [0.072, 0.098, 0.124].map(k => k * L);
    const tones = [0, 1, 4];
    const box = { x: c.x - radii[2] - 8, y: c.y - radii[2] - 8, w: radii[2] * 2 + 16, h: radii[2] * 2 + 16 };
    const ring = (r, tone, wdt) => A.stroke(`M${A.f(c.x + r)} ${A.f(c.y)}A${A.f(r)} ${A.f(r)} 0 1 1 ${A.f(c.x - r)} ${A.f(c.y)}A${A.f(r)} ${A.f(r)} 0 1 1 ${A.f(c.x + r)} ${A.f(c.y)}`, palette.inks[tone], wdt);
    const el = A.svgLayer(root, box, `<circle cx="${A.f(c.x)}" cy="${A.f(c.y)}" r="${A.f(radii[0])}" fill="${palette.ground}"/>` + radii.map((r, i) => ring(r, tones[i], geo.weight * (i ? 0.9 : 1.2))).join(''), 'socket').origin(c.x, c.y);
    const spark = A.svgLayer(root, box, `<circle cx="${A.f(c.x)}" cy="${A.f(c.y)}" r="${A.f(radii[1])}" fill="none" stroke="${palette.signal}" stroke-width="${A.f(geo.weight * 2)}"/>`, 'spark').origin(c.x, c.y);
    spark.style.opacity = 0;
    return { el, spark, centre: c };
  }

  function play(ctx) {
    const { geo, layers } = ctx;
    const d = geo.length * 0.11;
    const back = { x: -geo.dir.x * d, y: -geo.dir.y * d };
    const fwd = geo.weight * 2.4;
    const drawEnd = 1500 + 4 * 90;
    const slideAt = drawEnd + 140, slideDur = 300, clickAt = slideAt + slideDur;
    const total = clickAt + 420;
    const k = t => t / total;
    const tr = (x, y) => `translate(${x.toFixed(2)}px, ${y.toFixed(2)}px)`;
    const assemblyFrames = [
      { transform: tr(back.x, back.y), offset: 0 },
      { transform: tr(back.x, back.y), offset: k(slideAt), easing: 'cubic-bezier(.55,0,.9,.55)' },
      { transform: tr(geo.dir.x * fwd, geo.dir.y * fwd), offset: k(clickAt), easing: 'cubic-bezier(.2,.8,.3,1)' },
      { transform: tr(-geo.dir.x * fwd * 0.35, -geo.dir.y * fwd * 0.35), offset: k(clickAt + 140), easing: 'ease-in-out' },
      { transform: 'none', offset: 1 },
    ];
    [layers.plug, layers.knurl, ...layers.contours].forEach(el => M.animate(el, assemblyFrames, { duration: total, easing: 'linear' }));

    layers.masses.forEach((el, i) => M.animate(el, [{ opacity: 0, transform: 'scale(.94)' }, { opacity: 1, transform: 'none' }], { duration: 1600, delay: i * 140, easing: M.ease.out }));
    layers.masses.forEach((el, i) => M.animate(el, [{ transform: 'none' }, { transform: 'scale(1.035)', offset: 0.25 }, { transform: 'none' }], { duration: 900, delay: clickAt + i * 50, easing: 'ease-out', fill: 'none', composite: 'add' }));
    layers.cone.forEach((el, i) => ctx.draw(el, { delay: 300 + i * 100, duration: 1300 }));
    layers.waves.forEach((el, i) => ctx.draw(el, { delay: 300 + i * 70, duration: 1500 }));

    layers.contours.forEach((el, i) => el.querySelectorAll('path').forEach(p => {
      p.style.strokeDasharray = '1 2';
      M.animate(p, [{ strokeDashoffset: 1 }, { strokeDashoffset: 0 }], { delay: i * 90, duration: 1500, easing: M.ease.draw });
    }));
    ctx.draw(layers.knurl, { delay: 1150, duration: 500, easing: M.ease.out });
    M.animate(layers.plug, [{ opacity: 0 }, { opacity: 1 }], { delay: 1000, duration: 500, composite: 'replace' });

    const s = layers.socket;
    ctx.draw(s.el, { delay: 700, duration: 900, easing: M.ease.out });
    M.animate(s.el, [{ transform: 'none' }, { transform: 'scale(1.16)', offset: 0.18 }, { transform: 'none' }], { delay: clickAt, duration: 520, easing: 'ease-out' });
    M.animate(s.spark, [{ opacity: 0.95, transform: 'scale(.6)' }, { opacity: 0, transform: 'scale(2.6)' }], { delay: clickAt, duration: 620, easing: M.ease.out, fill: 'forwards' });

    ripple(ctx, clickAt + 30, { stagger: 60, duration: 760 });
    const glow = document.querySelector('.glow');
    if (glow) M.animate(glow, [{ opacity: 0.25 }, { opacity: 0.25, offset: k(clickAt) }, { opacity: 1.4, offset: k(clickAt + 120) }, { opacity: 1 }], { duration: total + 600 });
    ctx.idle(ctx, { delay: clickAt + 900 });
  }

  Cable.page({
    id: 'v2',
    title: 'Patch in',
    shells: ['club', 'calm', 'zine'],
    buildOptions: () => ({ socket }),
    play,
  });
})();
