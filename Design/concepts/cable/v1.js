(() => {
  const { M, plugAt, cableFracAt, HIDE } = Cable;

  function massFlood(ctx, { duration = 1500, stagger = 160, delay = 0 } = {}) {
    ctx.layers.masses.forEach((el, i) => {
      const m = ctx.geo.masses[i];
      M.animate(el, [
        { opacity: 0, transform: `translate(${m.sweep.x.toFixed(1)}px, ${m.sweep.y.toFixed(1)}px) rotate(52deg) scale(${m.floodScale})` },
        { opacity: 1, offset: 0.62 },
        { opacity: 1, transform: 'none' },
      ], { duration, delay: delay + i * stagger, easing: M.ease.inOut });
    });
  }

  function ripple(ctx, at, { stagger = 55, duration = 700 } = {}) {
    ctx.layers.rings.forEach((el, i) => {
      M.animate(el, [{ opacity: 0, transform: 'scale(.86)' }, { opacity: 1, transform: 'none' }], { delay: at + i * stagger, duration, easing: M.ease.outQuart });
      el.querySelectorAll('path').forEach(p => {
        p.style.strokeDasharray = '1 2';
        M.animate(p, [{ strokeDashoffset: HIDE }, { strokeDashoffset: 0 }], { delay: at + i * stagger, duration: duration * 0.8, easing: M.ease.out });
      });
    });
  }

  function fly(ctx, { lead = 1450, lag = 60, shrink = 22, power = 2.7, wobble = 3.2 } = {}) {
    const { geo, layers } = ctx;
    const fps = 60;
    const arrivals = [];
    geo.contours.forEach((c, i) => {
      const delay = i * lag, dur = lead - i * shrink;
      const settleDur = 700;
      const total = dur + settleDur;
      const n = Math.ceil((total / 1000) * fps);
      const tf = [], da = [], db = [];
      for (let s = 0; s <= n; s++) {
        const tms = (s / n) * total;
        const x = Math.min(1, tms / dur);
        const u = 1 - Math.pow(1 - x, power);
        const after = Math.max(0, tms - dur) / 1000;
        const wob = after > 0 ? wobble * (1 - i * 0.12) * Math.exp(-after * 7.5) * Math.sin(after * 2 * Math.PI * 2.6) : 0;
        const { transform, r } = plugAt(geo, u, wob);
        const offset = s / n;
        tf.push({ transform, offset });
        da.push({ strokeDashoffset: 1 - cableFracAt(c, 0, r), offset });
        db.push({ strokeDashoffset: 1 - cableFracAt(c, 1, r), offset });
      }
      const opts = { delay, duration: total, easing: 'linear' };
      M.animate(layers.plugs[i], tf, opts);
      if (i === 0) {
        M.animate(layers.plug, tf, opts);
        M.animate(layers.knurl, tf, opts);
      }
      const [pa, pb] = layers.cables[i].querySelectorAll('path');
      pa.style.strokeDasharray = pb.style.strokeDasharray = '1 2';
      M.animate(pa, da, opts);
      M.animate(pb, db, opts);
      M.animate(layers.plugs[i], [{ opacity: 0 }, { opacity: 1, offset: 0.06 }, { opacity: 1 }], { delay, duration: total });
      arrivals.push(delay + dur);
    });
    return arrivals;
  }

  function play(ctx) {
    const { layers } = ctx;
    massFlood(ctx);
    layers.cone.forEach((el, i) => ctx.draw(el, { delay: 200 + i * 90, duration: 1200 }));
    layers.waves.forEach((el, i) => ctx.draw(el, { delay: 380 + i * 70, duration: 1400 }));
    const arrivals = fly(ctx);
    M.animate(layers.knurl, [{ opacity: 0 }, { opacity: 0, offset: 0.7 }, { opacity: 1 }], { duration: arrivals[0] + 200 });
    ripple(ctx, arrivals[0] * 0.7);
    ctx.idle(ctx, { delay: arrivals[4] + 500 });
  }

  window.CableV1 = { massFlood, ripple, fly };

  if (document.currentScript && document.currentScript.dataset.page === 'v1') {
    Cable.page({
      id: 'v1',
      title: 'Thrown lead',
      shells: ['club', 'calm', 'zine'],
      buildOptions: () => ({ split: true }),
      play,
    });
  }
})();
