(() => {
  const { M, HIDE } = Cable;
  const A = window.SoundingArt;
  const { ripple } = window.CableV1;
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const smooth = x => x * x * (3 - 2 * x);

  let state = null;

  function tangle(geo, palette) {
    const L = geo.length, B = geo.back, d = geo.dir, n = { x: -d.y, y: d.x };
    const pts = [];
    const N = 160;
    for (let i = 0; i <= N; i++) {
      const s = i / N;
      const along = s * 1.55 * L;
      const loop = Math.max(0, Math.min(1, (s - 0.06) / 0.7));
      const th = loop * Math.PI * 4.2;
      const r = L * 0.13 * Math.sin(loop * Math.PI);
      const sway = Math.sin(s * Math.PI * 1.3) * L * 0.18;
      pts.push({
        x: B.x - d.x * along + n.x * sway + (Math.cos(th) - 1) * r * -d.x + Math.sin(th) * r * n.x,
        y: B.y - d.y * along + n.y * sway + (Math.cos(th) - 1) * r * -d.y + Math.sin(th) * r * n.y,
      });
    }
    const norms = pts.map((p, i) => {
      const a = pts[Math.max(0, i - 1)], b = pts[Math.min(N, i + 1)];
      const m = Math.hypot(b.x - a.x, b.y - a.y) || 1;
      return { x: (b.y - a.y) / m, y: -(b.x - a.x) / m };
    });
    const half = 0.026 * L;
    return geo.contours.map((c, i) => {
      const off = half + i * geo.layout.echoGap;
      return [1, -1].map(sg => A.stroke(A.poly(pts.map((p, k) => ({ x: p.x + norms[k].x * off * sg, y: p.y + norms[k].y * off * sg }))), palette.inks[c.tone], c.width)).join('');
    }).join('');
  }

  function leadPath(main, after, palette, geo) {
    const old = main.querySelector('.lead');
    if (old) old.remove();
    const mr = main.getBoundingClientRect();
    const top = after.getBoundingClientRect().top - mr.top;
    const W = mr.width;
    const secs = [...main.querySelectorAll('.first, .more, .closing')].map(el => {
      const r = el.getBoundingClientRect();
      return { top: r.top - mr.top, bottom: r.bottom - mr.top, el };
    });
    const btn = main.querySelector('#closing-cta').getBoundingClientRect();
    const mobile = W < 600;
    const gx = mobile ? 12 : Math.max(34, W * 0.028);
    const left = gx, right = W - gx;
    const way = [{ x: right, y: top - 2 }];
    secs.forEach((s, i) => {
      if (s.el.classList.contains('closing')) return;
      const x = i % 2 ? left : right;
      const nx = i % 2 ? right : left;
      way.push({ x, y: s.bottom - (mobile ? 30 : 90) });
      way.push({ x: nx, y: s.bottom + (mobile ? 30 : 90) });
    });
    const k = mobile ? 18 : 30;
    const plugLen = k * 4;
    const last = way[way.length - 1];
    const sign = last.x < W / 2 ? 1 : -1;
    const by = btn.top + btn.height / 2 - mr.top;
    const end = { x: (sign > 0 ? btn.left - mr.left - 14 : btn.right - mr.left + 14) - sign * plugLen, y: by };
    way.push({ x: last.x, y: by - 220 });
    way.push(end);
    const pts = [];
    for (let i = 0; i < way.length - 1; i++) {
      const a = way[i], b = way[i + 1];
      const vertical = Math.abs(a.x - b.x) < 2;
      const c1 = vertical ? { x: a.x, y: a.y + (b.y - a.y) * 0.4 } : { x: a.x, y: a.y + (b.y - a.y) * 0.75 };
      const c2 = vertical ? { x: b.x, y: a.y + (b.y - a.y) * 0.6 } : { x: b.x, y: b.y - (b.y - a.y) * 0.75 };
      if (i === way.length - 2) { c1.x = a.x; c1.y = b.y; c2.x = b.x - sign * 140; c2.y = b.y; }
      const steps = 40;
      for (let s = i ? 1 : 0; s <= steps; s++) {
        const t = s / steps, mt = 1 - t;
        pts.push({ x: mt ** 3 * a.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t ** 3 * b.x, y: mt ** 3 * a.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t ** 3 * b.y });
      }
    }
    const norms = pts.map((p, i) => {
      const a = pts[Math.max(0, i - 1)], b = pts[Math.min(pts.length - 1, i + 1)];
      const m = Math.hypot(b.x - a.x, b.y - a.y) || 1;
      return { x: (b.y - a.y) / m, y: -(b.x - a.x) / m };
    });
    const gap = mobile ? 2.6 : 4.2, wdt = mobile ? 1.2 : 1.6;
    const tones = [4, 0, 1, 2, 3];
    const strands = tones.map((tone, i) => A.stroke(A.poly(pts.map((p, k) => ({ x: p.x + norms[k].x * (i - 2) * gap, y: p.y + norms[k].y * (i - 2) * gap }))), palette.inks[tone], wdt, `stroke-dasharray="1 2" stroke-dashoffset="1"`)).join('');
    const cum = A.lengths(pts).map((v, _, arr) => v / arr[arr.length - 1]);
    const head = [[0, 0], [0.014, 0.022], [0.036, 0.030], [0.07, 0.03], [0.076, 0.019], [0.094, 0.019], [0.1, 0.031], [0.17, 0.031], [0.176, 0.019], [0.196, 0.019], [0.202, 0.034], [0.44, 0.034], [0.446, 0.052], [0.49, 0.052], [0.496, 0.064], [0.86, 0.064], [0.93, 0.046], [1, 0.026]];
    const tip = { x: end.x + sign * plugLen, y: end.y };
    const plugPts = [...head.map(([x, y]) => ({ x: tip.x - sign * x * plugLen, y: tip.y - y * plugLen })).reverse(), ...head.slice(1).map(([x, y]) => ({ x: tip.x - sign * x * plugLen, y: tip.y + y * plugLen }))];
    const svg = document.createElementNS(A.NS, 'svg');
    const H = pts.reduce((m, p) => Math.max(m, p.y), 0) + plugLen + 40;
    svg.setAttribute('class', 'lead');
    svg.setAttribute('aria-hidden', 'true');
    svg.setAttribute('viewBox', `0 0 ${A.f(W)} ${A.f(H)}`);
    svg.style.cssText = `position:absolute;left:0;top:0;width:${W}px;height:${H}px;pointer-events:none;z-index:0;overflow:visible`;
    svg.innerHTML = `<g class="strands">${strands}</g><g class="leadplug" style="opacity:0;transform-box:fill-box;transform-origin:50% 0">${A.stroke(A.poly(plugPts), palette.inks[0], wdt * 1.3)}</g>`;
    main.style.position = 'relative';
    main.prepend(svg);
    return { svg, pts, cum, sign, paths: [...svg.querySelectorAll('.strands path')], plug: svg.querySelector('.leadplug'), endFrac: 1, H };
  }

  function setup(ctx, still) {
    const { geo, layers, palette } = ctx;
    const hero = document.querySelector('.hero');
    let track = document.querySelector('.v4-track');
    if (!track) {
      track = document.createElement('div');
      track.className = 'v4-track';
      hero.parentNode.insertBefore(track, hero);
      track.appendChild(hero);
    }
    const vh = innerHeight;
    const heroH = hero.offsetHeight;
    track.style.height = `${heroH + vh * (ctx.mobile ? 0.8 : 1)}px`;
    hero.style.position = 'sticky';
    hero.style.top = `${Math.min(0, vh - heroH)}px`;
    hero.style.zIndex = 1;

    const tg = A.svgLayer(layers.assembly, A.bounds(geo.contours[0].plugPoints, geo.length * 1.2), tangle(geo, palette), 'tangle').origin(geo.back.x, geo.back.y);
    layers.assembly.insertBefore(tg, layers.assembly.firstChild);
    const assembly = [layers.plug, tg, ...layers.plugs, layers.knurl];
    const cablePaths = layers.cables.flatMap(el => [...el.querySelectorAll('path')]);
    cablePaths.forEach(p => (p.style.strokeDasharray = '1 2'));
    const tanglePaths = [...tg.querySelectorAll('path')];
    tanglePaths.forEach(p => (p.style.strokeDasharray = '1 2'));
    const main = document.querySelector('main');
    const lead = leadPath(main, track.nextElementSibling, palette, geo);
    if (window.__v4ro) window.__v4ro.disconnect();
    let roTimer = 0, lastH = main.offsetHeight;
    window.__v4ro = new ResizeObserver(() => {
      if (Math.abs(main.offsetHeight - lastH) < 2) return;
      lastH = main.offsetHeight;
      clearTimeout(roTimer);
      roTimer = setTimeout(() => { state.lead = leadPath(main, track.nextElementSibling, palette, geo); state.leadY = -1; state.leadDone = undefined; renderLead(state); }, 120);
    });
    window.__v4ro.observe(main);
    const conePaths = layers.cone.flatMap(el => [...el.querySelectorAll('path')]);
    conePaths.forEach(p => (p.style.strokeDasharray = '1 2'));
    [...assembly, ...layers.masses].forEach(el => (el.style.willChange = 'transform'));

    state = { ctx, track, hero, tg, assembly, cablePaths, tanglePaths, lead, conePaths, plugged: false, still, p: -1, leadY: -1, t: 0 };
    const gl = document.querySelector('.glow');
    return state;
  }

  function progress(s) {
    const r = s.track.getBoundingClientRect();
    const span = r.height - s.hero.offsetHeight - Math.min(0, innerHeight - s.hero.offsetHeight);
    return clamp(-r.top / Math.max(1, span - (innerHeight - s.hero.offsetHeight > 0 ? 0 : 0)));
  }

  function render(s, time = 0) {
    const { geo, layers } = s.ctx;
    const p = s.still ? 1 : progress(s);
    const settle = smooth(clamp(p / 0.72));
    const slide = smooth(clamp((p - 0.72) / 0.1));
    const loose = 1 - settle;
    const drift = s.still ? { x: 0, y: 0, r: 0 } : { x: Math.sin(time * 0.0009) * 14, y: Math.cos(time * 0.0011) * 10, r: Math.sin(time * 0.0007) * 4 };
    const w = geo.w, h = geo.h;
    const lx = s.ctx.mobile ? -0.10 * w : -0.2 * w, ly = s.ctx.mobile ? -0.16 * h : -0.24 * h;
    const tx = (lx + drift.x) * loose - geo.dir.x * geo.length * 0.08 * (1 - slide);
    const ty = (ly + drift.y) * loose - geo.dir.y * geo.length * 0.08 * (1 - slide);
    const rot = (-16 + drift.r) * loose;
    const tf = `translate(${tx.toFixed(2)}px, ${ty.toFixed(2)}px) rotate(${rot.toFixed(3)}deg) scale(${(1 - 0.2 * loose).toFixed(4)})`;
    s.assembly.forEach(el => (el.style.transform = tf));
    const tangleOff = clamp(settle * 1.08);
    s.tanglePaths.forEach(pth => (pth.style.strokeDashoffset = tangleOff.toFixed(4)));
    const grow = smooth(clamp((p - 0.1) / 0.66));
    s.cablePaths.forEach(pth => (pth.style.strokeDashoffset = (1 - grow).toFixed(4)));
    const cone = smooth(clamp(p / 0.6));
    s.conePaths.forEach(pth => (pth.style.strokeDashoffset = (HIDE * (1 - cone)).toFixed(4)));
    layers.masses.forEach((el, i) => {
      const k = smooth(clamp((p - i * 0.08) / 0.6));
      el.style.opacity = (0.25 + 0.75 * k).toFixed(3);
      el.style.transform = `scale(${(0.86 + 0.14 * k).toFixed(4)}) rotate(${((1 - k) * (i ? -14 : 14)).toFixed(2)}deg)`;
    });
    layers.knurl.style.opacity = (0.35 + 0.65 * slide).toFixed(3);
    const plugged = p >= 0.8;
    if (plugged !== s.plugged) {
      s.plugged = plugged;
      if (plugged) {
        if (s.still) layers.rings.forEach(el => (el.style.opacity = 1));
        else ripple(s.ctx, 0, { stagger: 50, duration: 650 });
      } else {
        layers.rings.forEach(el => { M.animate(el, [{ opacity: getComputedStyle(el).opacity }, { opacity: 0 }], { duration: 260 }); });
      }
    }
    s.p = p;
  }

  function renderLead(s) {
    const L = s.lead;
    const mr = document.querySelector('main').getBoundingClientRect();
    const target = s.still ? Infinity : innerHeight * 0.72 - mr.top;
    let k = 0;
    while (k < L.pts.length - 1 && L.pts[k + 1].y <= target) k++;
    let f = L.cum[k];
    if (k < L.pts.length - 1 && L.pts[k + 1].y > L.pts[k].y) {
      const t = clamp((target - L.pts[k].y) / (L.pts[k + 1].y - L.pts[k].y));
      f += (L.cum[k + 1] - L.cum[k]) * t;
    }
    if (k === L.pts.length - 1) f = 1;
    if (Math.abs(f - s.leadY) < 1e-4) return;
    s.leadY = f;
    L.paths.forEach(p => (p.style.strokeDashoffset = (1 - f).toFixed(5)));
    const done = f > 0.999;
    if (done !== s.leadDone) {
      s.leadDone = done;
      L.plug.style.transition = s.still ? 'none' : 'opacity .4s, transform .5s cubic-bezier(.22,1,.36,1)';
      L.plug.style.opacity = done ? 1 : 0;
      L.plug.style.transform = done ? 'none' : `translateX(${-14 * L.sign}px)`;
      const btn = document.getElementById('closing-cta');
      btn.style.transition = 'box-shadow .5s';
      btn.style.boxShadow = done ? '0 0 0 6px rgb(255 107 26 / .18), 0 0 40px rgb(255 107 26 / .45)' : '';
    }
  }

  let scrollLoop = null;
  function start(ctx, still) {
    const s = setup(ctx, still);
    if (still) { render(s); renderLead(s); return; }
    layers0(ctx);
    let ticking = false;
    const onScroll = () => {
      if (ticking) return;
      ticking = true;
      requestAnimationFrame(() => { ticking = false; render(s, performance.now()); renderLead(s); });
    };
    removeEventListener('scroll', window.__v4scroll || (() => {}));
    window.__v4scroll = onScroll;
    addEventListener('scroll', onScroll, { passive: true });
    render(s, 0);
    renderLead(s);
    scrollLoop = M.loop((dt, now) => {
      if (s.p < 0.72) render(s, now);
    });
  }

  function layers0(ctx) {
    ctx.layers.rings.forEach(el => (el.style.opacity = 0));
    const { masses } = ctx.layers;
    masses.forEach((el, i) => M.animate(el, [{ opacity: 0 }, { opacity: 1 }], { duration: 900, delay: i * 120, fill: 'none', composite: 'accumulate' }));
  }

  function demo(ctx, play) {
    scrollTo({ top: 0 });
    play();
    const total = document.documentElement.scrollHeight - innerHeight;
    const t0 = performance.now(), dur = 9000;
    M.loop((dt, now) => {
      const x = clamp((now - t0) / dur);
      scrollTo({ top: total * M.easeFn.inOutSine(x), behavior: 'instant' });
      return x < 1;
    });
  }

  Cable.page({
    id: 'v4',
    title: 'The long lead',
    shells: ['calm', 'zine'],
    long: true,
    observe: 'main',
    buildOptions: () => ({ split: true }),
    play: ctx => {
      start(ctx, false);
      const y = Cable.params.get('y');
      if (y != null) {
        const total = document.documentElement.scrollHeight - innerHeight;
        scrollTo(0, parseFloat(y) <= 1 ? parseFloat(y) * total : parseFloat(y));
        render(state, 0);
        renderLead(state);
      }
    },
    still: ctx => start(ctx, true),
    demo,
    onResize: (ctx, still) => { still(); },
  });
})();
