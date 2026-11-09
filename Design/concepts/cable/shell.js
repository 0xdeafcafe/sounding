(() => {
  const A = window.SoundingArt;
  const params = new URLSearchParams(location.search);
  const reduceQuery = matchMedia('(prefers-reduced-motion: reduce)');
  const MAIL = 'mailto:sounding@alex.forbes.red?subject=Sounding%20TestFlight';
  const SHELLS = { calm: 'Calm', club: 'Club', zine: 'Zine' };
  const VERSIONS = [
    ['v1', 'v1-thrown.html', 'Thrown lead'],
    ['v2', 'v2-patch.html', 'Patch in'],
    ['v3', 'v3-unspool.html', 'Unspool'],
    ['v4', 'v4-scroll.html', 'The long lead'],
    ['v5', 'v5-loose.html', 'Loose lead'],
    ['v6', 'v6-press.html', 'Press'],
  ];

  const M = {
    anims: new Set(),
    loops: new Set(),
    paused: false,
    animate(el, keyframes, options) {
      const a = el.animate(keyframes, { fill: 'both', ...options });
      a._born = M.simTime || 0;
      M.anims.add(a);
      if (options.iterations !== Infinity && M.simTime == null) {
        a.finished.then(() => {
          if (!M.anims.has(a)) return;
          try { a.commitStyles(); } catch (e) {}
          a.cancel();
          M.anims.delete(a);
        }).catch(() => {});
      }
      if (M.paused) a.pause();
      return a;
    },
    loop(step) {
      const loop = { step, id: 0, last: 0, alive: true };
      const tick = now => {
        if (!loop.alive) return;
        const dt = loop.last ? Math.min(0.05, (now - loop.last) / 1000) : 1 / 60;
        loop.last = now;
        if (step(dt, now) === false) { loop.alive = false; M.loops.delete(loop); return; }
        loop.id = requestAnimationFrame(tick);
      };
      M.loops.add(loop);
      if (!M.paused) loop.id = requestAnimationFrame(tick);
      loop.tick = tick;
      return loop;
    },
    simTime: null,
    seek(ms) {
      M.simTime = 0;
      const pending = [...M.timers].sort((a, b) => a.ms - b.ms);
      M.timers.forEach(t => clearTimeout(t.id));
      M.timers.clear();
      const loops = [...M.loops];
      M.loops.forEach(l => cancelAnimationFrame(l.id));
      const dt = 1 / 60;
      for (let sim = 0; sim <= ms; sim += dt * 1000) {
        M.simTime = sim;
        while (pending.length && pending[0].ms <= sim) pending.shift().fn();
        M.timers.forEach(t => { t.ms += sim; pending.push(t); clearTimeout(t.id); });
        M.timers.clear();
        pending.sort((a, b) => a.ms - b.ms);
        [...M.loops].forEach(l => { if (!loops.includes(l)) loops.push(l); });
        loops.forEach(l => { if (l.alive && l.step(dt, sim) === false) l.alive = false; });
      }
      M.anims.forEach(a => { a.pause(); a.currentTime = Math.max(0, ms - a._born); });
      M.loops.forEach(l => { l.alive = false; cancelAnimationFrame(l.id); });
      M.simTime = null;
    },
    after(ms, fn) {
      const t = { ms, fn, start: performance.now(), id: 0 };
      t.id = setTimeout(() => { M.timers.delete(t); fn(); }, ms);
      M.timers.add(t);
      return t;
    },
    timers: new Set(),
    stop() {
      M.anims.forEach(a => a.cancel());
      M.anims.clear();
      M.loops.forEach(l => { l.alive = false; cancelAnimationFrame(l.id); });
      M.loops.clear();
      M.timers.forEach(t => clearTimeout(t.id));
      M.timers.clear();
    },
    pause() {
      if (M.paused) return;
      M.paused = true;
      M.anims.forEach(a => a.pause());
      M.loops.forEach(l => { cancelAnimationFrame(l.id); l.last = 0; });
    },
    resume() {
      if (!M.paused) return;
      M.paused = false;
      M.anims.forEach(a => a.play());
      M.loops.forEach(l => { if (l.alive) l.id = requestAnimationFrame(l.tick); });
    },
    spring({ zeta = 0.6, response = 0.8 } = {}) {
      const w0 = (2 * Math.PI) / response;
      const sample = t => {
        if (t <= 0) return 0;
        if (zeta < 1) {
          const wd = w0 * Math.sqrt(1 - zeta * zeta);
          return 1 - Math.exp(-zeta * w0 * t) * (Math.cos(wd * t) + ((zeta * w0) / wd) * Math.sin(wd * t));
        }
        return 1 - Math.exp(-w0 * t) * (1 + w0 * t);
      };
      let duration = 0.1;
      for (let t = 0; t < 6; t += 1 / 120) {
        if (Math.abs(sample(t) - 1) > 0.002) duration = t + 1 / 120;
      }
      return { sample, duration };
    },
    springEasing(opts) {
      const s = M.spring(opts);
      const n = 48;
      const stops = [];
      for (let i = 0; i <= n; i++) {
        const t = (i / n) * s.duration;
        stops.push(`${(i === n ? 1 : s.sample(t)).toFixed(4)} ${((i / n) * 100).toFixed(2)}%`);
      }
      return { easing: `linear(${stops.join(',')})`, duration: s.duration * 1000 };
    },
    ease: {
      out: 'cubic-bezier(.22,1,.36,1)',
      outQuart: 'cubic-bezier(.25,1,.5,1)',
      inOut: 'cubic-bezier(.65,0,.35,1)',
      in: 'cubic-bezier(.55,0,1,.45)',
      draw: 'cubic-bezier(.45,.05,.2,1)',
    },
    easeFn: {
      inOutCubic: x => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2),
      outCubic: x => 1 - Math.pow(1 - x, 3),
      inOutSine: x => -(Math.cos(Math.PI * x) - 1) / 2,
    },
  };

  const HIDE = 1.001;

  function draw(el, { from = 'start', delay = 0, duration = 1000, easing = M.ease.draw } = {}) {
    const paths = el.querySelectorAll ? el.querySelectorAll('path') : [el];
    paths.forEach(p => {
      p.style.strokeDasharray = '1 2';
      M.animate(p, [{ strokeDashoffset: from === 'start' ? HIDE : -HIDE }, { strokeDashoffset: 0 }], { delay, duration, easing });
    });
  }

  function idle(ctx, { masses = true, signal = true, waves = true, delay = 0 } = {}) {
    const { layers, geo } = ctx;
    if (signal) {
      const p = layers.signal.querySelector('path');
      M.animate(p, [
        { strokeDashoffset: 0.12, opacity: 1, offset: 0 },
        { strokeDashoffset: -0.92, opacity: 1, offset: 0.33 },
        { strokeDashoffset: -1.05, opacity: 0, offset: 0.38 },
        { strokeDashoffset: -1.05, opacity: 0, offset: 1 },
      ], { duration: 4800, delay, iterations: Infinity, easing: 'linear' });
    }
    if (masses) {
      layers.masses.forEach((el, i) => {
        const ph = geo.masses[i].phase;
        const a = 4 * Math.sin(ph), b = 1 + 0.03 * Math.cos(ph * 1.7);
        M.animate(el, [
          { transform: `rotate(${(-a).toFixed(2)}deg) scale(${(2 - b).toFixed(4)})` },
          { transform: `rotate(${a.toFixed(2)}deg) scale(${b.toFixed(4)})` },
        ], { duration: 8500 + i * 1700, delay, iterations: Infinity, direction: 'alternate', easing: 'ease-in-out', fill: 'none', composite: 'add' });
      });
    }
    if (waves && layers.waves.length) {
      layers.waves.forEach((el, i) => {
        const g = geo.waves[i];
        M.animate(el, [{ transform: 'translateX(0)' }, { transform: `translateX(${-g.wavelength}px)` }], { duration: (g.wavelength / g.speed) * 1000, iterations: Infinity, easing: 'linear', fill: 'none' });
      });
    }
  }

  function routeAt(geo, u) {
    const { points, cum } = geo.route;
    const n = points.length;
    u = Math.min(1, Math.max(0, u));
    let lo = 0, hi = n - 2;
    while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (cum[mid] <= u) lo = mid; else hi = mid - 1; }
    const k = lo, span = cum[k + 1] - cum[k] || 1, t = Math.min(1, (u - cum[k]) / span);
    const p = { x: points[k].x + (points[k + 1].x - points[k].x) * t, y: points[k].y + (points[k + 1].y - points[k].y) * t };
    const a = points[Math.max(0, k - 1)], b = points[Math.min(n - 1, k + 2)];
    return { p, angle: Math.atan2(b.y - a.y, b.x - a.x), k, t };
  }

  function wrapDeg(d) { while (d > 180) d -= 360; while (d < -180) d += 360; return d; }

  function plugAt(geo, u, extraDeg = 0, blendEnd = 0.04) {
    const r = routeAt(geo, u);
    let delta = wrapDeg(((r.angle - geo.angle) * 180) / Math.PI);
    const settle = Math.min(1, Math.max(0, (1 - u) / blendEnd));
    delta *= settle * settle * (3 - 2 * settle);
    return { transform: `translate(${(r.p.x - geo.back.x).toFixed(2)}px, ${(r.p.y - geo.back.y).toFixed(2)}px) rotate(${(delta + extraDeg).toFixed(3)}deg)`, r };
  }

  function cableFracAt(contour, half, r) {
    const f = contour.cableFrac[half];
    return f[r.k] + (f[r.k + 1] - f[r.k]) * r.t;
  }

  const copy = {
    eyebrow: 'For iPhone, iPad, Apple Watch, Apple TV and Mac',
    sub: 'An independent SoundCloud player that feels at home on every Apple device you own.',
    cta: 'Ask about TestFlight',
    note: 'Free. No ads. Coming to the App Store.',
    features: [
      ['Now Playing', 'Big artwork, a clean waveform, and timed comments that follow the playhead. Always dark, always calm.', '../assets/np-iphone.jpg'],
      ['Tracklists for DJ mixes', 'The current track lights up as the mix plays. Identify names the rest, and saved tracklists live in Setlists.', '../assets/np-iphone-tracklist.jpg'],
      ['Decks', 'Two decks, a crossfader, EQ, filter, hot cues and loops. Auto Mix beat-matches the next track for you.', '../assets/decks.jpg'],
    ],
    more: [
      ['output', 'Output', 'Move playback between iPhone, Mac and Apple TV at the same position. Control the TV from your phone or Mac.', '../assets/np-output.jpg'],
      ['analysis', 'Music analysis', 'Tempo, key and genre, worked out on the device and shown on every track row.', '../assets/np-mac.jpg'],
      ['privacy', 'Privacy', 'No servers, no accounts of its own, no analytics. Sync goes through your own iCloud.', null],
    ],
  };

  const feat = (cls) => copy.features.map(([t, d, img], i) => `
      <article class="${cls}" id="f-${i}">
        <figure><img src="${img}" alt="" loading="lazy"></figure>
        <p class="num">0${i + 1}</p><h3>${t}</h3><p>${d}</p>
      </article>`).join('');

  const moreSections = () => copy.more.map(([id, t, d, img], i) => `
    <section class="more more-${i % 2 ? 'r' : 'l'}" id="${id}">
      <div class="more-copy"><p class="num">0${i + 4}</p><h2>${t}</h2><p>${d}</p></div>
      ${img ? `<figure><img src="${img}" alt="" loading="lazy"></figure>` : '<div class="privacy-mark" aria-hidden="true"><span>0</span><small>servers</small></div>'}
    </section>`).join('') + `
    <section class="closing" id="closing">
      <h2>Make yourself at home.</h2>
      <p>${copy.note}</p>
      <a class="button" id="closing-cta" href="${MAIL}">${copy.cta} <span aria-hidden="true">↗</span></a>
    </section>`;

  const nav = `
    <header class="nav">
      <a class="brand" href="#"><img src="../assets/icon.jpg" alt="" width="28" height="28"><span>Sounding</span></a>
      <nav aria-label="Primary"><a href="#features">Features</a><a href="#">Privacy</a><a href="#">Support</a></nav>
      <a class="nav-cta" href="${MAIL}">TestFlight</a>
    </header>`;

  const footer = `<footer class="foot"><p>Sounding is an independent app and is not affiliated with SoundCloud.</p></footer>`;

  const templates = {
    calm: long => `${nav}
    <main>
      <section class="hero" aria-labelledby="h">
        <div class="hero-copy">
          <p class="eyebrow">${copy.eyebrow}</p>
          <h1 id="h">Plug in. Turn it up.</h1>
          <p class="sub">${copy.sub}</p>
          <div class="cta"><a class="button" href="${MAIL}">${copy.cta} <span aria-hidden="true">↗</span></a><span class="note">${copy.note}</span></div>
        </div>
        <div class="art" id="art"></div>
      </section>
      <section class="first" id="features" aria-labelledby="fh">
        <div class="first-head"><h2 id="fh">Made for listening.</h2><p>Every screen is built around the music, with the rest kept quietly out of the way.</p></div>
        <div class="cards">${feat('card')}</div>
      </section>
      ${long ? moreSections() : ''}
    </main>${footer}`,
    club: long => `${nav}
    <main>
      <section class="hero" aria-labelledby="h">
        <div class="art" id="art"></div>
        <div class="glow" aria-hidden="true"></div>
        <div class="hero-copy">
          <p class="eyebrow"><span class="live" aria-hidden="true"></span>${copy.eyebrow}</p>
          <h1 id="h">Plug in.<br><em>Turn it up.</em></h1>
          <p class="sub">${copy.sub}</p>
          <div class="cta"><a class="button" href="${MAIL}">${copy.cta} <span aria-hidden="true">↗</span></a><span class="note">${copy.note}</span></div>
        </div>
        <svg class="wavebar" aria-hidden="true" preserveAspectRatio="none" viewBox="0 0 1200 60">${waveBars()}</svg>
      </section>
      <section class="first" id="features" aria-labelledby="fh">
        <div class="first-head"><p class="eyebrow">Side A</p><h2 id="fh">Made for the long set.</h2></div>
        <div class="cards">${feat('card')}</div>
      </section>
      ${long ? moreSections() : ''}
    </main>${footer}`,
    zine: long => `${nav}
    <main>
      <section class="hero" aria-labelledby="h">
        <div class="mast" aria-hidden="true"><span>Sounding</span><span>No. 01</span><span>Autumn 2026</span><span>An independent SoundCloud player</span></div>
        <h1 id="h"><span class="l1">Plug in.</span><span class="l2">Turn it up.</span></h1>
        <figure class="plate"><div class="art" id="art"></div><figcaption>Fig. 1 — The lead. 3.5 mm, copper, five contours.</figcaption></figure>
        <div class="hero-copy">
          <p class="sub">${copy.sub}</p>
          <div class="cta"><a class="button" href="${MAIL}">${copy.cta} <span aria-hidden="true">↗</span></a><span class="note">${copy.note}</span></div>
        </div>
      </section>
      <section class="first" id="features" aria-labelledby="fh">
        <h2 id="fh">Made for <em>listening</em>.</h2>
        <blockquote>“The waveform. The comments. The track inside the mix.”</blockquote>
        <div class="cards">${feat('card')}</div>
      </section>
      ${long ? moreSections() : ''}
    </main>${footer}`,
  };

  function waveBars() {
    const r = A.Random(42);
    let out = '';
    for (let i = 0; i < 150; i++) {
      const env = 0.35 + 0.65 * Math.abs(Math.sin(i / 11)) * (0.6 + 0.4 * Math.sin(i / 3.1));
      const h = Math.max(3, 56 * env * r.in(0.55, 1));
      out += `<rect x="${i * 8}" y="${(60 - h) / 2}" width="4" height="${h.toFixed(1)}" rx="2"/>`;
    }
    return out;
  }

  const shellArt = {
    calm: { palette: 'light', adjust: (L, { w, h, s }) => {
      if (w > h * 1.3) {
        L.tip = { x: w * 0.64, y: h * 0.40 };
        L.plugLength = s * 0.74;
        L.cableBend = { x: w * 0.26, y: h * 1.06 };
        L.massAnchors[0] = { x: w * 0.42, y: h * 0.70, r: s * 0.52 };
        L.massAnchors[1] = { x: w * 0.86, y: h * 0.24, r: s * 0.40 };
        L.massAnchors[2] = { x: w * 0.14, y: h * 0.30, r: s * 0.34 };
        if (L.cone) L.cone.centre = { x: w * 0.16, y: h * 0.26 };
      }
    } },
    club: { palette: 'dark', adjust: (L, { w, h, s }) => {
      if (w > h) {
        L.tip = { x: w * 0.74, y: h * 0.34 };
        L.plugLength = s * 0.62;
        L.cableBend = { x: w * 0.40, y: h * 1.08 };
        L.cableEnd = { x: w * 1.2, y: h * 0.80 };
        L.massAnchors[0] = { x: w * 0.56, y: h * 0.70, r: s * 0.46 };
        L.massAnchors[1] = { x: w * 0.94, y: h * 0.16, r: s * 0.36 };
        L.massAnchors[2] = { x: w * 0.08, y: h * 0.10, r: s * 0.30 };
        if (L.cone) L.cone.centre = { x: w * 0.44, y: h * 0.16 };
      } else {
        L.tip = { x: w * 0.74, y: h * 0.22 };
        L.plugLength = s * 0.78;
        L.cableBend = { x: w * 0.0, y: h * 0.62 };
        L.cableEnd = { x: w * 1.3, y: h * 0.56 };
        L.massAnchors[0] = { x: w * 0.40, y: h * 0.40, r: s * 0.50 };
        L.massAnchors[1] = { x: w * 0.96, y: h * 0.08, r: s * 0.36 };
        L.massAnchors[2] = { x: w * 0.04, y: h * 0.06, r: s * 0.30 };
        if (L.cone) L.cone.centre = { x: w * 0.12, y: h * 0.12 };
      }
    } },
    zine: { palette: 'light', adjust: (L, { w, h, s }) => {
      L.tip = { x: w * 0.68, y: h * 0.30 };
      L.plugLength = s * 0.70;
      L.cableBend = { x: w * 0.04, y: h * 1.04 };
      L.cableEnd = { x: w * 1.2, y: h * 0.86 };
    } },
  };

  function page(spec) {
    const shell = SHELLS[params.get('shell')] ? params.get('shell') : spec.shells[0];
    const thumb = params.has('thumb');
    document.documentElement.dataset.shell = shell;
    document.documentElement.classList.toggle('thumb', thumb);
    document.body.innerHTML = templates[shell](!!spec.long) + (thumb ? '' : toolbar(spec, shell));
    document.title = `${spec.id.toUpperCase()} ${spec.title} · ${SHELLS[shell]} — Sounding cable concepts`;
    const host = document.getElementById('art');
    const sa = shellArt[shell];
    const palette = A.palettes[sa.palette];
    let forceStill = params.has('still');
    let ctx = null;

    const make = () => {
      const r = host.getBoundingClientRect();
      const w = Math.round(r.width), h = Math.round(r.height);
      const geo = A.compose({ w, h, seed: 11, adjust: (L, d) => { sa.adjust(L, d); spec.adjust && spec.adjust(L, d, shell); } });
      const layers = (spec.build || A.build)(host, geo, palette, spec.buildOptions ? spec.buildOptions(shell) : {});
      ctx = { host, geo, palette, layers, shell, M, draw, idle, mobile: w < 600, params, spec, thumb };
      const glow = document.querySelector('.glow');
      if (glow) { glow.style.setProperty('--x', `${geo.tip.x}px`); glow.style.setProperty('--y', `${geo.tip.y}px`); }
      return ctx;
    };

    const still = () => {
      M.stop();
      make();
      document.documentElement.classList.add('is-still');
      spec.still && spec.still(ctx);
    };
    const play = () => {
      if (forceStill || reduceQuery.matches) return still();
      M.stop();
      document.documentElement.classList.remove('is-still');
      make();
      spec.play(ctx);
      if (params.has('t') && !thumb) M.seek(parseFloat(params.get('t')));
    };

    const io = new IntersectionObserver(entries => {
      entries.forEach(e => (e.isIntersecting ? M.resume() : M.pause()));
    }, { threshold: 0 });
    io.observe(spec.observe ? document.querySelector(spec.observe) : host);

    let lastW = innerWidth;
    let resizeTimer = 0;
    addEventListener('resize', () => {
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => {
        if (Math.abs(innerWidth - lastW) < 2) return;
        lastW = innerWidth;
        spec.onResize ? spec.onResize(ctx, still) : still();
      }, 200);
    });
    reduceQuery.addEventListener('change', () => (reduceQuery.matches ? still() : play()));

    const bar = document.querySelector('.toolbar');
    if (bar) {
      bar.querySelector('[data-replay]').addEventListener('click', () => { forceStill = false; syncStill(); scrollTo({ top: 0 }); play(); });
      const stillBtn = bar.querySelector('[data-still]');
      const syncStill = () => stillBtn.setAttribute('aria-pressed', String(forceStill));
      stillBtn.addEventListener('click', () => { forceStill = !forceStill; syncStill(); forceStill ? still() : play(); });
      syncStill();
    }

    addEventListener('message', e => {
      const cmd = e.data && e.data.cmd;
      if (cmd === 'play') { forceStill = false; spec.demo ? spec.demo(ctx, play) : play(); }
      if (cmd === 'still') { forceStill = true; scrollTo({ top: 0 }); still(); }
    });

    const start = () => (thumb ? still() : play());
    if (document.readyState === 'complete') start(); else addEventListener('load', start, { once: true });
    window.Cable.current = () => ctx;
  }

  function toolbar(spec, shell) {
    const shells = Object.entries(SHELLS).map(([k, v]) => {
      const fit = spec.shells.includes(k);
      return `<a href="?shell=${k}" class="${k === shell ? 'on' : ''}${fit ? '' : ' off-fit'}" ${k === shell ? 'aria-current="page"' : ''} title="${fit ? 'Recommended shell' : 'Works, but not a recommended pairing'}">${v}</a>`;
    }).join('');
    const i = VERSIONS.findIndex(v => v[0] === spec.id);
    const prev = VERSIONS[(i + VERSIONS.length - 1) % VERSIONS.length], next = VERSIONS[(i + 1) % VERSIONS.length];
    return `
    <div class="toolbar" role="toolbar" aria-label="Concept controls">
      <a class="tb-index" href="index.html" aria-label="All concepts">◂ All</a>
      <a class="tb-nav" href="${prev[1]}?shell=${shell}" aria-label="Previous: ${prev[2]}">‹</a>
      <span class="tb-title"><b>${spec.id.toUpperCase()}</b> ${spec.title}</span>
      <a class="tb-nav" href="${next[1]}?shell=${shell}" aria-label="Next: ${next[2]}">›</a>
      <span class="tb-shells">${shells}</span>
      <button type="button" data-replay>Replay</button>
      <button type="button" data-still aria-pressed="false" title="Preview the Reduce Motion frame">Still</button>
    </div>`;
  }

  window.Cable = { page, M, draw, idle, copy, VERSIONS, SHELLS, HIDE, params, routeAt, plugAt, cableFracAt, wrapDeg };
})();
