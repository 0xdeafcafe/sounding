(() => {
  const MASK = (1n << 64n) - 1n;
  const GOLDEN = 0x9E3779B97F4A7C15n;

  function Random(seed) {
    let state = (BigInt(seed) + GOLDEN) & MASK;
    const next = () => {
      state = (state + GOLDEN) & MASK;
      let z = state;
      z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK;
      z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK;
      return z ^ (z >> 31n);
    };
    const unit = () => Number(next() >> 11n) / 9007199254740992;
    return { next, unit, in: (a, b) => a + (b - a) * unit(), chance: p => unit() < p };
  }

  const rgb = (r, g, b) => `rgb(${Math.round(r * 255)} ${Math.round(g * 255)} ${Math.round(b * 255)})`;
  const accent = rgb(1, 0.42, 0.10);

  const palettes = {
    dark: {
      ground: rgb(0.063, 0.051, 0.047),
      masses: [rgb(0.42, 0.18, 0.08), rgb(0.24, 0.13, 0.22), rgb(0.09, 0.25, 0.23)],
      inks: [accent, rgb(0.96, 0.75, 0.40), rgb(0.43, 0.80, 0.70), rgb(0.98, 0.60, 0.56), rgb(0.95, 0.90, 0.82)],
      signal: rgb(1, 0.86, 0.62),
    },
    light: {
      ground: rgb(0.985, 0.962, 0.930),
      masses: [rgb(0.99, 0.79, 0.64), rgb(0.92, 0.82, 0.88), rgb(0.77, 0.89, 0.84)],
      inks: [rgb(0.86, 0.33, 0.06), rgb(0.70, 0.50, 0.12), rgb(0.08, 0.46, 0.41), rgb(0.66, 0.21, 0.24), rgb(0.27, 0.18, 0.14)],
      signal: accent,
    },
  };

  const profile = [
    [0.000, 0.000], [0.014, 0.022], [0.036, 0.030], [0.070, 0.030], [0.076, 0.019], [0.094, 0.019],
    [0.100, 0.031], [0.170, 0.031], [0.176, 0.019], [0.196, 0.019], [0.202, 0.034], [0.440, 0.034],
    [0.446, 0.052], [0.490, 0.052], [0.496, 0.064], [0.860, 0.064], [0.930, 0.046], [1.000, 0.026],
  ];

  function heroLayout(w, h, r) {
    const s = Math.min(w, h);
    const L = {};
    L.tip = { x: w * r.in(0.60, 0.70), y: h * r.in(0.30, 0.38) };
    L.angle = -Math.PI / 4 + r.in(-0.18, 0.14);
    L.plugLength = s * r.in(0.60, 0.68);
    L.ringStart = s * 0.075;
    L.ringGap = s * 0.062;
    L.ringCount = 8;
    L.contourCount = 5;
    L.echoGap = s * 0.016;
    L.weight = Math.min(Math.max(s * 0.0046, 1.3), 2.4);
    L.cableBend = { x: w * r.in(0.05, 0.30), y: h * 1.02 };
    L.cableEnd = { x: w * 1.2, y: h * r.in(0.80, 0.95) };
    const waves = r.chance(0.5);
    L.waves = waves ? { top: h * 0.06, gap: s * 0.022, count: 5, amplitude: s * 0.018, wavelength: s * 0.42 } : null;
    L.cone = waves ? null : { centre: { x: w * r.in(0.06, 0.16), y: h * r.in(0.10, 0.20) }, radius: s * 0.24, lean: { x: 0.7, y: 0.7 } };
    L.massAnchors = [];
    const ranges = [[0.22, 0.36, 0.58, 0.70, 0.40, 0.48], [0.86, 0.98, 0.10, 0.24, 0.32, 0.40], [0.02, 0.14, 0.02, 0.14, 0.26, 0.32]];
    for (const [x0, x1, y0, y1, r0, r1] of ranges) {
      const x = w * r.in(x0, x1);
      const y = h * r.in(y0, y1);
      L.massAnchors.push({ x, y, r: s * r.in(r0, r1) });
    }
    return L;
  }

  function smoothClosed(points) {
    const n = points.length;
    let d = `M${f(points[0].x)} ${f(points[0].y)}`;
    for (let i = 0; i < n; i++) {
      const p0 = points[(i - 1 + n) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n];
      d += `C${f(p1.x + (p2.x - p0.x) / 6)} ${f(p1.y + (p2.y - p0.y) / 6)} ${f(p2.x - (p3.x - p1.x) / 6)} ${f(p2.y - (p3.y - p1.y) / 6)} ${f(p2.x)} ${f(p2.y)}`;
    }
    return d + 'Z';
  }

  const f = v => (Math.round(v * 10) / 10).toString();
  const poly = pts => pts.map((p, i) => `${i ? 'L' : 'M'}${f(p.x)} ${f(p.y)}`).join('');

  function bounds(pts, pad = 0) {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const p of pts) { x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y); x1 = Math.max(x1, p.x); y1 = Math.max(y1, p.y); }
    return { x: x0 - pad, y: y0 - pad, w: x1 - x0 + pad * 2, h: y1 - y0 + pad * 2 };
  }

  function arcPoints(c, r, a0, a1, steps = 48) {
    const out = [];
    for (let i = 0; i <= steps; i++) {
      const a = a0 + (a1 - a0) * (i / steps);
      out.push({ x: c.x + Math.cos(a) * r, y: c.y + Math.sin(a) * r });
    }
    return out;
  }

  function cableCentre(start, heading, L, s) {
    const reach = s * 0.42;
    const c1 = { x: start.x + heading.x * reach, y: start.y + heading.y * reach };
    const c2 = L.cableBend, end = L.cableEnd;
    const out = [];
    for (let i = 0; i <= 72; i++) {
      const t = i / 72, mt = 1 - t;
      const a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t;
      const p = { x: a * start.x + b * c1.x + c * c2.x + d * end.x, y: a * start.y + b * c1.y + c * c2.y + d * end.y };
      const tx = 3 * mt * mt * (c1.x - start.x) + 6 * mt * t * (c2.x - c1.x) + 3 * t * t * (end.x - c2.x);
      const ty = 3 * mt * mt * (c1.y - start.y) + 6 * mt * t * (c2.y - c1.y) + 3 * t * t * (end.y - c2.y);
      const m = Math.max(1e-4, Math.hypot(tx, ty));
      out.push({ p, n: { x: ty / m, y: -tx / m } });
    }
    return out;
  }

  function plugFrame(tip, angle, length) {
    const dir = { x: Math.cos(angle), y: Math.sin(angle) };
    const nrm = { x: -dir.y, y: dir.x };
    const world = (x, y) => ({ x: tip.x - dir.x * x * length + nrm.x * y * length, y: tip.y - dir.y * x * length + nrm.y * y * length });
    return { dir, nrm, world };
  }

  function contourPoints(frame, cable, length, contour, echoGap) {
    const { world } = frame;
    const offset = contour * (echoGap / length);
    const topLocal = profile.map(([x, y], i) => [x - offset * (i < 2 ? 1.1 - i * 0.5 : 0), y + (i === 0 ? 0 : offset)]);
    const topSide = topLocal.map(([x, y]) => world(x, y));
    const bottomSide = topLocal.map(([x, y]) => world(x, -y));
    const half = profile[profile.length - 1][1] + offset;
    const cableTop = cable.map(c => ({ x: c.p.x + c.n.x * half * length, y: c.p.y + c.n.y * half * length }));
    const cableBottom = cable.map(c => ({ x: c.p.x - c.n.x * half * length, y: c.p.y - c.n.y * half * length }));
    const a = [...cableTop.slice().reverse(), ...topSide.slice().reverse()];
    const b = [...cableBottom.slice().reverse(), ...bottomSide.slice().reverse()];
    const plugLine = [...topSide.slice().reverse(), ...bottomSide.slice(1)];
    return { a, b, cableCount: cable.length, cableTop: cableTop.slice().reverse(), cableBottom: cableBottom.slice().reverse(), plugLine };
  }

  function plugOutline(frame) {
    const top = profile.map(([x, y]) => frame.world(x, y));
    const bottom = profile.slice().reverse().slice(1).map(([x, y]) => frame.world(x, -y));
    return [...top, ...bottom];
  }

  function knurlSegments(frame) {
    const segs = [];
    for (let x = 0.53; x < 0.84; x += 0.042) segs.push([frame.world(x, 0.064), frame.world(x + 0.04, -0.064)]);
    return segs;
  }

  function lengths(pts) {
    const out = [0];
    for (let i = 1; i < pts.length; i++) out.push(out[i - 1] + Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y));
    return out;
  }

  function compose({ w, h, seed = 7, adjust }) {
    const r = Random(seed);
    const s = Math.min(w, h), l = Math.max(w, h);
    const L = heroLayout(w, h, r);
    const toneShift = Number(r.next() % 5n);
    const sweeps = [{ x: -l * 0.30, y: l * 0.25 }, { x: l * 0.35, y: -l * 0.10 }, { x: -l * 0.10, y: -l * 0.35 }];
    const massSeeds = L.massAnchors.map(() => {
      const rest = Array.from({ length: 10 }, () => r.in(0.84, 1.12));
      const flood = Array.from({ length: 10 }, () => r.in(0.80, 1.30));
      const phase = r.in(0, Math.PI * 2);
      return { rest, flood, phase };
    });
    if (adjust) adjust(L, { w, h, s, l });
    const weight = L.weight;
    const masses = L.massAnchors.map((a, i) => {
      const { rest, phase } = massSeeds[i];
      const pts = rest.map((k, j) => {
        const ang = (j / 10) * Math.PI * 2 + phase;
        return { x: a.x + Math.cos(ang) * a.r * k, y: a.y + Math.sin(ang) * a.r * k };
      });
      return { center: { x: a.x, y: a.y }, radius: a.r, phase, tone: i, d: smoothClosed(pts), box: bounds(pts, 4), sweep: sweeps[i], floodScale: [3.2, 2.4, 2.0][i] };
    });

    const frame = plugFrame(L.tip, L.angle, L.plugLength);
    const { dir, world } = frame;
    const length = L.plugLength;
    const cable = cableCentre(world(1, 0), { x: -dir.x, y: -dir.y }, L, s);

    let cone = null;
    if (L.cone) {
      const c = L.cone;
      cone = Array.from({ length: 5 }, (_, i) => {
        const radius = c.radius * (1 - i * 0.17);
        const centre = { x: c.centre.x + c.lean.x * i * c.radius * 0.10, y: c.centre.y + c.lean.y * i * c.radius * 0.10 };
        return { centre, radius, tone: (i + toneShift + 3) % 5, width: weight * 0.9 };
      });
    }

    let waves = null;
    if (L.waves) {
      const W = L.waves;
      waves = Array.from({ length: W.count }, (_, i) => {
        const amp = W.amplitude * (1 - i * 0.07), shift = i * 0.32, base = W.top + i * W.gap;
        const k = (2 * Math.PI) / W.wavelength, step = Math.max(3, W.wavelength / 28);
        const pts = [];
        for (let x = -W.wavelength; x < w + W.wavelength * 2; x += step) pts.push({ x, y: base + amp * (Math.sin(k * x + shift) + 0.38 * Math.sin(2 * k * x + shift * 1.7)) });
        return { d: poly(pts), tone: (i + toneShift + 2) % 5, width: weight * 0.85, wavelength: W.wavelength, speed: W.wavelength / (9 + i), box: bounds(pts, 6) };
      });
    }

    const ringCentre = { x: L.tip.x + dir.x * length * 0.05, y: L.tip.y + dir.y * length * 0.05 };
    const heading = Math.atan2(dir.y, dir.x);
    const rings = Array.from({ length: L.ringCount }, (_, i) => {
      const radius = L.ringStart + i * L.ringGap;
      const span = ((205 - i * 7) * Math.PI) / 180;
      const up = arcPoints(ringCentre, radius, heading, heading - span / 2);
      const down = arcPoints(ringCentre, radius, heading, heading + span / 2);
      return { centre: ringCentre, radius, tone: (i + toneShift) % 4, width: weight, halves: [poly(up), poly(down)], box: bounds([...up, ...down], weight + 4) };
    });

    const contours = Array.from({ length: L.contourCount }, (_, i) => {
      const { a, b, cableTop, cableBottom, plugLine } = contourPoints(frame, cable, length, i, L.echoGap);
      const la = lengths(a), lb = lengths(b);
      const ca = lengths(cableTop), cb = lengths(cableBottom);
      return {
        cableHalves: [poly(cableTop), poly(cableBottom)],
        cablePoints: [cableTop, cableBottom],
        cableFrac: [ca.map(v => v / ca[ca.length - 1]), cb.map(v => v / cb[cb.length - 1])],
        cableBox: bounds([...cableTop, ...cableBottom], weight * 2 + 4),
        plugD: poly(plugLine),
        plugPoints: plugLine,
        plugBox: bounds(plugLine, weight * 2 + 4),
        tone: (i + toneShift + 4) % 5,
        width: weight * (i === 0 ? 1.15 : 0.9),
        halves: [poly(a), poly(b)],
        points: [a, b],
        cableFraction: [la.map(v => v / la[la.length - 1]), lb.map(v => v / lb[lb.length - 1])],
        box: bounds([...a, ...b], weight * 2 + 4),
      };
    });

    const outline = plugOutline(frame);
    const knurl = knurlSegments(frame);
    const signalPts = cable.slice().reverse().map(c => c.p);
    const route = signalPts;
    const routeLen = lengths(route);
    const routeTotal = routeLen[routeLen.length - 1];
    const back = world(1, 0);

    return {
      w, h, s, l, seed, toneShift, weight, layout: L, frame, length, tip: L.tip, angle: L.angle, heading, dir,
      masses, cone, waves, rings, ringCentre, contours, cable, back,
      route: { points: route, cum: routeLen.map(v => v / routeTotal), total: routeTotal },
      plug: { d: poly(outline) + 'Z', box: bounds(outline, 4) },
      knurl: { d: knurl.map(([p, q]) => `M${f(p.x)} ${f(p.y)}L${f(q.x)} ${f(q.y)}`).join(''), tone: toneShift % 5, width: weight * 0.8, box: bounds(knurl.flat(), 4) },
      signal: { d: poly(signalPts), width: weight * 2.2, box: bounds(signalPts, 6) },
    };
  }

  const NS = 'http://www.w3.org/2000/svg';

  function svgLayer(parent, box, inner, cls = '') {
    const svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('class', `layer ${cls}`.trim());
    svg.setAttribute('viewBox', `${f(box.x)} ${f(box.y)} ${f(box.w)} ${f(box.h)}`);
    svg.setAttribute('aria-hidden', 'true');
    svg.style.left = `${box.x}px`;
    svg.style.top = `${box.y}px`;
    svg.style.width = `${box.w}px`;
    svg.style.height = `${box.h}px`;
    svg.innerHTML = inner;
    svg.box = box;
    svg.origin = (x, y) => { svg.style.transformOrigin = `${x - box.x}px ${y - box.y}px`; return svg; };
    parent.appendChild(svg);
    return svg;
  }

  function clip(box, w, h, margin = 0.35) {
    const x0 = Math.max(box.x, -w * margin), y0 = Math.max(box.y, -h * margin);
    const x1 = Math.min(box.x + box.w, w * (1 + margin)), y1 = Math.min(box.y + box.h, h * (1 + margin));
    return { x: x0, y: y0, w: Math.max(1, x1 - x0), h: Math.max(1, y1 - y0) };
  }

  const stroke = (d, colour, width, extra = '') =>
    `<path d="${d}" fill="none" stroke="${colour}" stroke-width="${f(width)}" stroke-linecap="round" stroke-linejoin="round" pathLength="1" ${extra}/>`;

  function build(host, geo, palette, opts = {}) {
    host.innerHTML = '';
    host.style.setProperty('--ground', palette.ground);
    const { w, h } = geo;
    const root = opts.root ? opts.root(host) : host;
    const L = { masses: [], cone: [], waves: [], rings: [], contours: [] };
    const massOpacity = opts.massOpacity ?? 1;
    geo.masses.forEach(m => {
      const el = svgLayer(root, clip(m.box, w, h, 0.6), `<path d="${m.d}" fill="${palette.masses[m.tone]}" fill-opacity="${massOpacity}"/>`, 'mass');
      el.origin(m.center.x, m.center.y);
      L.masses.push(el);
    });
    if (geo.cone) {
      geo.cone.forEach(c => {
        const box = clip({ x: c.centre.x - c.radius - 4, y: c.centre.y - c.radius - 4, w: c.radius * 2 + 8, h: c.radius * 2 + 8 }, w, h, 0.4);
        const d = `M${f(c.centre.x + c.radius)} ${f(c.centre.y)}A${f(c.radius)} ${f(c.radius)} 0 1 1 ${f(c.centre.x - c.radius)} ${f(c.centre.y)}A${f(c.radius)} ${f(c.radius)} 0 1 1 ${f(c.centre.x + c.radius)} ${f(c.centre.y)}`;
        const el = svgLayer(root, box, stroke(d, palette.inks[c.tone], c.width), 'cone');
        el.origin(c.centre.x, c.centre.y);
        L.cone.push(el);
      });
    }
    if (geo.waves) {
      geo.waves.forEach(v => L.waves.push(svgLayer(root, v.box, stroke(v.d, palette.inks[v.tone], v.width), 'wave')));
    }
    geo.rings.forEach(r => {
      const el = svgLayer(root, clip(r.box, w, h, 0.2), r.halves.map(d => stroke(d, palette.inks[r.tone], r.width)).join(''), 'ring');
      el.origin(r.centre.x, r.centre.y);
      L.rings.push(el);
    });
    if (opts.socket) L.socket = opts.socket(root, geo, palette);
    L.signal = svgLayer(root, clip(geo.signal.box, w, h, 0.3), stroke(geo.signal.d, palette.signal, geo.signal.width, 'class="pulse" stroke-dasharray="0.12 3" stroke-dashoffset="0.12"'), 'signal');
    const assembly = opts.assembly ? opts.assembly(root) : root;
    if (opts.split) {
      L.cables = geo.contours.map(c => svgLayer(root, clip(c.cableBox, w, h, 0.35), c.cableHalves.map(d => stroke(d, palette.inks[c.tone], c.width)).join(''), 'cable'));
      L.plug = svgLayer(assembly, geo.plug.box, `<path d="${geo.plug.d}" fill="${palette.ground}"/>`, 'plug').origin(geo.back.x, geo.back.y);
      L.plugs = geo.contours.map(c => svgLayer(assembly, c.plugBox, stroke(c.plugD, palette.inks[c.tone], c.width), 'plugline').origin(geo.back.x, geo.back.y));
      L.knurl = svgLayer(assembly, geo.knurl.box, stroke(geo.knurl.d, palette.inks[geo.knurl.tone], geo.knurl.width), 'knurl').origin(geo.back.x, geo.back.y);
    } else {
      L.plug = svgLayer(assembly, geo.plug.box, `<path d="${geo.plug.d}" fill="${palette.ground}"/>`, 'plug').origin(geo.tip.x, geo.tip.y);
      geo.contours.forEach(c => {
        const el = svgLayer(assembly, clip(c.box, w, h, 0.35), c.halves.map(d => stroke(d, palette.inks[c.tone], c.width)).join(''), 'contour');
        el.origin(geo.tip.x, geo.tip.y);
        L.contours.push(el);
      });
      L.knurl = svgLayer(assembly, geo.knurl.box, stroke(geo.knurl.d, palette.inks[geo.knurl.tone], geo.knurl.width), 'knurl').origin(geo.tip.x, geo.tip.y);
    }
    L.assembly = assembly;
    L.root = root;
    return L;
  }

  window.SoundingArt = { Random, palettes, profile, compose, build, svgLayer, stroke, clip, poly, bounds, lengths, plugFrame, contourPoints, plugOutline, knurlSegments, f, NS };
})();
