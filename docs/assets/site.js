(() => {
  const root = document.documentElement;
  const main = document.querySelector('main');
  if (!main) return;
  const NS = 'http://www.w3.org/2000/svg';
  const HIDE = 1.001;
  const SDA = window.CSS && CSS.supports('animation-timeline: view()');
  if (!SDA) root.classList.add('no-sda');

  const mq = {
    dark: matchMedia('(prefers-color-scheme: dark)'),
    reduce: matchMedia('(prefers-reduced-motion: reduce)'),
    pin: matchMedia('(min-width: 1000px) and (min-height: 620px) and (prefers-reduced-motion: no-preference)'),
    mobile: matchMedia('(max-width: 899px)'),
  };

  const rgb = (r, g, b) => `rgb(${Math.round(r * 255)} ${Math.round(g * 255)} ${Math.round(b * 255)})`;
  const PALETTES = {
    light: {
      masses: [rgb(0.99, 0.79, 0.64), rgb(0.92, 0.82, 0.88), rgb(0.77, 0.89, 0.84)],
      inks: [rgb(0.86, 0.33, 0.06), rgb(0.70, 0.50, 0.12), rgb(0.08, 0.46, 0.41), rgb(0.66, 0.21, 0.24), rgb(0.27, 0.18, 0.14)],
    },
    dark: {
      masses: [rgb(0.42, 0.18, 0.08), rgb(0.24, 0.13, 0.22), rgb(0.09, 0.25, 0.23)],
      inks: [rgb(1, 0.42, 0.10), rgb(0.96, 0.75, 0.40), rgb(0.43, 0.80, 0.70), rgb(0.98, 0.60, 0.56), rgb(0.95, 0.90, 0.82)],
    },
  };
  const REACH = 2.4;
  const PROFILE = [
    [0.000, 0.000], [0.014, 0.022], [0.036, 0.030], [0.070, 0.030], [0.076, 0.019], [0.094, 0.019],
    [0.100, 0.031], [0.170, 0.031], [0.176, 0.019], [0.196, 0.019], [0.202, 0.034], [0.440, 0.034],
    [0.446, 0.052], [0.490, 0.052], [0.496, 0.064], [0.860, 0.064], [0.930, 0.046], [1.000, 0.026],
  ];
  const LINE = 1.5;
  const ECHO = 4.5;
  const EASE = 'cubic-bezier(.22,1,.36,1)';

  const MIX = {
    title: 'Pariah @ Freerotation 2024, Baskerville Hall, UK (06/07/24)',
    duration: 5300,
    wave: [76, 78, 78, 83, 88, 87, 87, 83, 88, 87, 86, 88, 87, 91, 93, 94, 94, 99, 98, 97, 95, 94, 91, 93, 93, 93, 93, 93, 92, 93, 93, 93, 91, 92, 64, 93, 91, 85, 91, 89, 87, 89, 87, 88, 86, 87, 95, 95, 97, 97, 95, 94, 95, 97, 97, 97, 97, 95, 92, 91, 91, 92, 92, 96, 94, 96, 88, 93, 93, 93, 91, 93, 95, 91, 91, 91, 88, 90, 93, 91, 90, 88, 92, 93, 88, 89, 89, 88, 84, 87, 87, 85, 93, 95, 95, 94, 96, 93, 94, 93, 95, 95, 91, 90, 93, 89, 90, 88, 93, 91, 93, 93, 87, 91, 93, 94, 93, 93, 93, 86, 89, 86, 86, 87, 87, 89, 90, 89, 89, 88, 81, 79, 80, 77, 76, 92, 91, 90, 90, 91, 87, 86, 89, 88, 89, 84, 86, 76, 83, 81, 81, 88, 88, 88, 86, 86, 83, 87, 89, 86],
    tracks: [[0, 'Xhaxché', 'Maōh'], [344, 'Waggle', 'Harba'], [936, 'Slingshot', 'Pearson Sound'], [1158, 'Cyber Funk', 'Doctor Jeep'], [1354, 'La Mera (feat. CHZTER) [RMX]', 'El Nick DGO'], [1481, 'Zarbak', 'Pocz & Pacheko'], [1554, 'Neon Pulse', 'megwhite'], [1717, 'H Meets T', 'eaRWaX'], [1881, 'Let There Be Rock (Extended Mix)', 'Clubbstars'], [2050, 'Basic Maneuvers', 'Verraco'], [2463, 'Akanum', 'Hypho'], [2681, 'Thistle', 'Skrillex, Randomer, Blawan & MC Dricka'], [2866, 'Djédjé', 'Toma Kami & Amor Satyr'], [2995, 'Bacoungana', 'DJ Sandji'], [3092, 'Lose No Time', 'Darren Price'], [3220, 'Rare Record 2005', 'G. LO'], [3364, 'Badungdeng (DieMantle Remix)', "Sleepin' Giantz"], [3512, 'The Ooba', 'Qube Honey'], [3784, "Hornz For '23", 'Bow Street Runner'], [4104, 'Pinger 6', 'Siu Mata & Amor Satyr'], [4231, 'FI3AC2036060', 'Aleksi Perälä'], [4441, 'Belleview (dBridge Belle Reviewed Remix)', 'Commix'], [4679, 'Murderer', 'Spirit'], [4886, "Can't Punish Me", 'Dom & Roland']],
  };

  const f = v => (Math.round(v * 10) / 10).toString();
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const lerp = (a, b, t) => a + (b - a) * t;
  const poly = pts => pts.map((p, i) => `${i ? 'L' : 'M'}${f(p.x)} ${f(p.y)}`).join('');
  const lengths = pts => {
    const out = [0];
    for (let i = 1; i < pts.length; i++) out.push(out[i - 1] + Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y));
    return out;
  };
  const el = (tag, attrs = {}, parent) => {
    const n = document.createElementNS(NS, tag);
    for (const k in attrs) n.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(n);
    return n;
  };
  const palette = () => PALETTES[mq.dark.matches ? 'dark' : 'light'];
  const ground = () => getComputedStyle(document.body).backgroundColor;
  const rectIn = (node, box) => {
    const r = node.getBoundingClientRect();
    return { x: r.left - box.left, y: r.top - box.top, w: r.width, h: r.height, get r() { return this.x + this.w; }, get b() { return this.y + this.h; }, get cx() { return this.x + this.w / 2; }, get cy() { return this.y + this.h / 2; } };
  };

  function spline(way, step = 6) {
    const out = [];
    const P = [way[0], ...way, way[way.length - 1]];
    for (let i = 1; i < P.length - 2; i++) {
      const p0 = P[i - 1], p1 = P[i], p2 = P[i + 1], p3 = P[i + 2];
      const n = Math.max(2, Math.ceil(Math.hypot(p2.x - p1.x, p2.y - p1.y) / step));
      for (let k = i === 1 ? 0 : 1; k <= n; k++) {
        const t = k / n, t2 = t * t, t3 = t2 * t;
        out.push({
          x: 0.5 * (2 * p1.x + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3),
          y: 0.5 * (2 * p1.y + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3),
        });
      }
    }
    return out;
  }

  function normals(pts) {
    return pts.map((p, i) => {
      const a = pts[Math.max(0, i - 1)], b = pts[Math.min(pts.length - 1, i + 1)];
      const m = Math.hypot(b.x - a.x, b.y - a.y) || 1;
      return { x: -(b.y - a.y) / m, y: (b.x - a.x) / m };
    });
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

  function mass(g, cx, cy, r, tone, seed, pal) {
    const pts = Array.from({ length: 9 }, (_, j) => {
      const h = Math.sin(seed * 12.9898 + j * 78.233) * 43758.5453;
      const k = 0.8 + 0.36 * (h - Math.floor(h));
      const a = (j / 9) * Math.PI * 2 + seed;
      return { x: cx + Math.cos(a) * r * k, y: cy + Math.sin(a) * r * k };
    });
    return el('path', { d: smoothClosed(pts), fill: pal.masses[tone], class: 'mass' }, g);
  }

  function rings(g, c, heading, start, gap, count, pal, spanDeg = 200) {
    const out = [];
    for (let i = 0; i < count; i++) {
      const r = start + i * gap;
      const span = ((spanDeg - i * 7) * Math.PI) / 180;
      const arc = sign => {
        const pts = [];
        for (let k = 0; k <= 40; k++) {
          const a = heading + sign * (span / 2) * (k / 40);
          pts.push({ x: c.x + Math.cos(a) * r, y: c.y + Math.sin(a) * r });
        }
        return pts;
      };
      const grp = el('g', { class: 'ring' }, g);
      [arc(-1), arc(1)].forEach(p => el('path', { d: poly(p), stroke: pal.inks[i % 4], 'stroke-width': LINE, pathLength: 1 }, grp));
      out.push(grp);
    }
    return out;
  }

  function waves(g, x0, x1, top, pal, count = 5, gap = ECHO * 1.6, amp = 9, wavelength = 300) {
    const out = [];
    for (let i = 0; i < count; i++) {
      const pts = [];
      const k = (2 * Math.PI) / wavelength, shift = i * 0.32, a = amp * (1 - i * 0.07), base = top + i * gap;
      for (let x = x0; x <= x1 + 8; x += 8) pts.push({ x, y: base + a * (Math.sin(k * x + shift) + 0.38 * Math.sin(2 * k * x + shift * 1.7)) });
      out.push(el('path', { d: poly(pts), stroke: pal.inks[(i + 2) % 5], 'stroke-width': LINE, pathLength: 1, class: 'wave' }, g));
    }
    return out;
  }

  function plug(g, tip, dir, L, pal, levels, gnd, reach = 1) {
    const nrm = { x: -dir.y, y: dir.x };
    const along = x => (x <= 0.202 ? x : x <= 0.44 ? 0.202 + (x - 0.202) * reach : 0.202 + 0.238 * reach + x - 0.44);
    const world = (x, y) => ({ x: tip.x - dir.x * along(x) * L + nrm.x * y * L, y: tip.y - dir.y * along(x) * L + nrm.y * y * L });
    const outline = [...PROFILE.map(([x, y]) => world(x, y)), ...PROFILE.slice(0, -1).reverse().map(([x, y]) => world(x, -y))];
    el('path', { d: poly(outline) + 'Z', fill: gnd }, g);
    const lines = [];
    for (let i = 0; i < levels; i++) {
      const off = (i * ECHO) / L;
      const local = PROFILE.map(([x, y], k) => [x - off * (k < 2 ? 1.1 - k * 0.5 : 0), y + (k === 0 ? 0 : off)]);
      const pts = [...local.slice().reverse().map(([x, y]) => world(x, y)), ...local.slice(1).map(([x, y]) => world(x, -y))];
      lines.push(el('path', { d: poly(pts), stroke: pal.inks[i], 'stroke-width': LINE * (i ? 1 : 1.15), pathLength: 1 }, g));
    }
    const knurl = [];
    for (let x = 0.53; x < 0.84; x += 0.042) knurl.push(`M${f(world(x, 0.064).x)} ${f(world(x, 0.064).y)}L${f(world(x + 0.04, -0.064).x)} ${f(world(x + 0.04, -0.064).y)}`);
    lines.push(el('path', { d: knurl.join(''), stroke: pal.inks[4], 'stroke-width': LINE * 0.8, pathLength: 1 }, g));
    return { lines, back: world(1, 0), half: 0.026 * L };
  }

  function cable(g, pts, opts, pal) {
    const { levels, from = 0, to = 0, startHalf, endHalf, chunk = 520 } = opts;
    const cum = lengths(pts);
    const total = cum[cum.length - 1];
    const nr = normals(pts);
    const base = h => h;
    const half = (k, s) => {
      const thin = (mq.mobile.matches ? 2.5 : 3) + k * ECHO;
      let v = thin;
      if (startHalf != null && s < from) v = lerp(startHalf + k * ECHO, thin, smooth(s / from));
      if (endHalf != null && total - s < to) v = lerp(endHalf + k * ECHO, thin, smooth((total - s) / to));
      return base(v);
    };
    const sides = [];
    for (let k = 0; k < levels; k++) {
      for (const sg of [1, -1]) {
        sides.push({ tone: k, pts: pts.map((p, i) => { const h = half(k, cum[i]) * sg; return { x: p.x + nr[i].x * h, y: p.y + nr[i].y * h }; }) });
      }
    }
    const chunks = [];
    let a = 0;
    while (a < pts.length - 1) {
      let b = a + 1;
      while (b < pts.length - 1 && cum[b] - cum[a] < chunk) b++;
      const paths = sides.map(s => {
        const part = s.pts.slice(a, b + 1);
        const c = lengths(part);
        const p = el('path', { d: poly(part), stroke: pal.inks[s.tone], 'stroke-width': LINE, pathLength: 1, 'stroke-dasharray': '1 2', 'stroke-dashoffset': HIDE }, g);
        return { el: p, cum: c, total: c[c.length - 1] || 1, at: -1 };
      });
      chunks.push({ a, b, paths });
      a = b;
    }
    return { pts, cum, total, chunks };
  }
  const smooth = t => { t = clamp(t); return t * t * (3 - 2 * t); };
  const easeOut = t => 1 - Math.pow(1 - clamp(t), 3);

  function bezier(a, b, c, d, out, skipFirst) {
    const n = Math.max(4, Math.ceil((Math.hypot(b.x - a.x, b.y - a.y) + Math.hypot(c.x - b.x, c.y - b.y) + Math.hypot(d.x - c.x, d.y - c.y)) / 5));
    for (let i = skipFirst ? 1 : 0; i <= n; i++) {
      const t = i / n, u = 1 - t, k0 = u * u * u, k1 = 3 * u * u * t, k2 = 3 * u * t * t, k3 = t * t * t;
      out.push({ x: k0 * a.x + k1 * b.x + k2 * c.x + k3 * d.x, y: k0 * a.y + k1 * b.y + k2 * c.y + k3 * d.y });
    }
    return out;
  }

  function looped(A, B, C, r) {
    const dx = B.x - A.x, dy = (B.y - A.y) * 0.3, m = Math.hypot(dx, dy) || 1;
    const u = { x: dx / m, y: dy / m };
    const n = u.x >= 0 ? { x: u.y, y: -u.x } : { x: -u.y, y: u.x };
    const a = r / 3, b = r;
    const at = t => { const along = a * t - b * Math.sin(t), up = b * Math.cos(t); return { x: C.x + along * u.x + up * n.x, y: C.y + along * u.y + up * n.y }; };
    const L0 = at(-Math.PI), L1 = at(Math.PI);
    const out = [];
    const h0 = Math.hypot(L0.x - A.x, L0.y - A.y) * 0.45;
    bezier(A, { x: A.x, y: A.y + h0 }, { x: L0.x - u.x * h0, y: L0.y - u.y * h0 }, L0, out);
    const steps = Math.ceil((r * 8) / 5);
    for (let i = 1; i <= steps; i++) out.push(at(-Math.PI + (2 * Math.PI * i) / steps));
    const h1 = Math.hypot(B.x - L1.x, B.y - L1.y) * 0.45;
    return bezier(L1, { x: L1.x + u.x * h1, y: L1.y + u.y * h1 }, { x: B.x, y: B.y - h1 }, B, out, true);
  }

  function drawTo(c, idx, frac = 0) {
    for (const ch of c.chunks) {
      for (const p of ch.paths) {
        let v;
        if (idx >= ch.b) v = 1;
        else if (idx < ch.a) v = 0;
        else {
          const k = idx - ch.a;
          const here = p.cum[k], next = p.cum[Math.min(k + 1, p.cum.length - 1)];
          v = (here + (next - here) * frac) / p.total;
        }
        v = v > 0.9995 ? 1 : Math.round(v * 2000) / 2000;
        if (v === p.at) continue;
        p.at = v;
        p.el.style.strokeDashoffset = v <= 0 ? HIDE : 1 - v;
      }
    }
  }
  const drawLength = (c, len) => {
    if (len <= 0) return drawTo(c, -1);
    if (len >= c.total) return drawTo(c, c.pts.length);
    let lo = 0, hi = c.cum.length - 1;
    while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (c.cum[mid] <= len) lo = mid; else hi = mid - 1; }
    const seg = (c.cum[lo + 1] - c.cum[lo]) || 1;
    drawTo(c, lo, (len - c.cum[lo]) / seg);
  };

  const LAG = 0.5;
  function timeline(chain) {
    const knots = [];
    let cursor = -Infinity, base = 0;
    for (const pc of chain) {
      const c = pc.c;
      pc.base = base;
      if (pc.scene) {
        const s = pc.scene;
        const a = Math.max(cursor, s.top + c.pts[0].y);
        const b = Math.max(a + 1, s.top + s.span + c.pts[c.pts.length - 1].y);
        knots.push([a, base], [b, base + c.total]);
        cursor = b;
      } else {
        let v = 0, low = -Infinity;
        c.pts.forEach((p, i) => {
          low = Math.max(low, p.y);
          v = i ? Math.max(v + LAG * (c.cum[i] - c.cum[i - 1]), low) : Math.max(cursor, p.y);
          knots.push([v, base + c.cum[i]]);
        });
        cursor = v;
      }
      base += c.total;
    }
    const STEP = 4, R = 12;
    const p0 = knots[0][0] - STEP * R * 2;
    const n = Math.ceil((cursor + STEP * R * 2 - p0) / STEP) + 1;
    const raw = new Float64Array(n);
    let k = 0;
    for (let i = 0; i < n; i++) {
      const p = p0 + i * STEP;
      while (k < knots.length - 1 && knots[k + 1][0] <= p) k++;
      const a = knots[k], b = knots[Math.min(k + 1, knots.length - 1)];
      raw[i] = p <= knots[0][0] ? 0 : p >= cursor ? base : b[0] > a[0] ? a[1] + ((b[1] - a[1]) * (p - a[0])) / (b[0] - a[0]) : b[1];
    }
    const box = src => {
      const sum = new Float64Array(n + 1);
      for (let i = 0; i < n; i++) sum[i + 1] = sum[i] + src[i];
      const out = new Float64Array(n);
      for (let i = 0; i < n; i++) {
        const lo = Math.max(0, i - R), hi = Math.min(n - 1, i + R);
        const pad = (R - (i - lo)) * src[0] + (R - (hi - i)) * src[n - 1];
        out[i] = (sum[hi + 1] - sum[lo] + pad) / (2 * R + 1);
      }
      return out;
    };
    return { p0, step: STEP, vals: box(box(raw)), total: base };
  }
  const lookup = (tl, P) => {
    const x = (P - tl.p0) / tl.step;
    if (x <= 0) return 0;
    const i = Math.floor(x);
    if (i >= tl.vals.length - 1) return tl.total;
    return tl.vals[i] + (tl.vals[i + 1] - tl.vals[i]) * (x - i);
  };
  const penAt = (y, vh) => vh * (0.66 + 0.3 * (1 - smooth(y / (vh * 0.9))));

  const drawOn = (paths, delay, duration, easing = 'cubic-bezier(.45,.05,.2,1)') => paths.forEach(p => {
    p.style.strokeDasharray = '1 2';
    p.animate([{ strokeDashoffset: HIDE }, { strokeDashoffset: 0 }], { delay, duration, easing, fill: 'both' });
  });

  const np = document.querySelector('[data-np]');
  const T = MIX.tracks;
  const fmt = s => { s = Math.max(0, Math.round(s)); const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60; return h ? `${h}:${String(m).padStart(2, '0')}:${String(x).padStart(2, '0')}` : `${m}:${String(x).padStart(2, '0')}`; };
  let npState = { idx: -1, sec: -1 };
  let rows = [];
  let override = null;
  if (np) {
    const list = np.querySelector('[data-tracklist]');
    list.innerHTML = T.map(([s, t, a], i) => `<li><button type="button" tabindex="-1" data-i="${i}"><time>${fmt(s)}</time><span><b></b><small></small></span></button></li>`).join('');
    rows = [...list.children];
    rows.forEach((li, i) => { li.querySelector('b').textContent = T[i][1]; li.querySelector('small').textContent = T[i][2]; });
    const bars = MIX.wave.map((v, i) => { const h = 18 + ((v - 60) / 40) * 82; const y = (100 - clamp(h, 14, 100)) / 2; return `M${i * 2 + 0.3} ${f(y)}h1.3v${f(100 - 2 * y)}h-1.3z`; }).join('');
    np.querySelectorAll('.wave-bars').forEach(w => { w.innerHTML = `<svg viewBox="0 0 320 100" preserveAspectRatio="none" aria-hidden="true"><path d="${bars}"/></svg>`; });
    const showRow = li => { list.style.transform = `translateY(${-Math.max(0, li.offsetTop - li.offsetHeight)}px)`; };
    const rove = btn => { list.querySelectorAll('button[tabindex="0"]').forEach(b => { if (b !== btn) b.tabIndex = -1; }); btn.tabIndex = 0; };
    list.addEventListener('focusin', e => { const b = e.target.closest('button'); if (b) { rove(b); showRow(b.parentElement); } });
    list.addEventListener('keydown', e => {
      const b = e.target.closest('button');
      if (!b) return;
      const i = +b.dataset.i;
      const to = { ArrowDown: i + 1, ArrowUp: i - 1, Home: 0, End: T.length - 1 }[e.key];
      if (to == null) return;
      e.preventDefault();
      rows[clamp(to, 0, T.length - 1)].querySelector('button').focus();
    });
    list.addEventListener('click', e => {
      const b = e.target.closest('button');
      if (!b) return;
      const sec = T[+b.dataset.i][0] + 1;
      const s = scenes.listen;
      if (mode === 'pin' && s) {
        const p = pFromSec(sec);
        scrollTo({ top: s.top + p * s.span, behavior: mq.reduce.matches ? 'auto' : 'smooth' });
      } else {
        override = sec;
        renderTime(sec);
      }
    });
  }
  const wave = np && np.querySelector('[data-wave]');
  const nowText = np && np.querySelector('[data-now]');
  const elapsed = np && np.querySelector('[data-elapsed]');
  const remain = np && np.querySelector('[data-remain]');
  const listOl = np && np.querySelector('[data-tracklist]');

  function renderTime(sec) {
    if (!np) return;
    sec = clamp(sec, 0, MIX.duration);
    const whole = Math.round(sec);
    if (whole === npState.sec) return;
    npState.sec = whole;
    wave.style.setProperty('--played', `${((sec / MIX.duration) * 100).toFixed(2)}%`);
    elapsed.textContent = fmt(sec);
    {
      let k = 0;
      while (k < T.length - 1 && T[k + 1][0] <= sec) k++;
      const end = k < T.length - 1 ? T[k + 1][0] : MIX.duration;
      rows[k].style.setProperty('--row', ((sec - T[k][0]) / (end - T[k][0])).toFixed(3));
    }
    remain.textContent = `-${fmt(MIX.duration - sec)}`;
    let idx = 0;
    while (idx < T.length - 1 && T[idx + 1][0] <= sec) idx++;
    if (idx !== npState.idx) {
      if (npState.idx >= 0) rows[npState.idx].removeAttribute('aria-current');
      rows[idx].setAttribute('aria-current', 'true');
      npState.idx = idx;
      nowText.textContent = `${T[idx][2]} - ${T[idx][1]}`;
      if (!listOl.contains(document.activeElement)) {
        const li = rows[idx];
        listOl.querySelectorAll('button').forEach((b, i) => { b.tabIndex = i === idx ? 0 : -1; });
        listOl.style.transform = `translateY(${-Math.max(0, li.offsetTop - li.offsetHeight)}px)`;
      }
    }
  }
  const secFromP = p => p < 0.47 ? 0 : p < 0.74 ? lerp(0, 1500, (p - 0.47) / 0.27) : lerp(1500, MIX.duration - 20, (p - 0.74) / 0.26);
  const pFromSec = s => s <= 1500 ? 0.47 + (s / 1500) * 0.27 : 0.74 + ((s - 1500) / (MIX.duration - 20 - 1500)) * 0.26;

  let mode = 'flat';
  let scenes = {};
  let page = null;
  let built = false;

  function sceneInfo(name) {
    const sec = document.querySelector(`[data-scene="${name}"]`);
    if (!sec) return null;
    const mr = main.getBoundingClientRect();
    const r = sec.getBoundingClientRect();
    return { sec, stage: sec.querySelector('.stage'), top: r.top - mr.top, height: r.height, span: Math.max(1, r.height - innerHeight), anims: [] };
  }

  function stageMeasure(stage, fn) {
    stage.classList.add('measuring');
    const all = stage.querySelectorAll('*');
    const saved = [];
    all.forEach(n => { if (n.style) { saved.push([n, n.style.animation]); n.style.animation = 'none'; } });
    const out = fn();
    saved.forEach(([n, v]) => { n.style.animation = v; });
    stage.classList.remove('measuring');
    return out;
  }

  function buildListen(s, pal, gnd) {
    const st = s.stage;
    const box = st.getBoundingClientRect();
    const W = box.width, H = box.height;
    const m = stageMeasure(st, () => ({
      phone: rectIn(st.querySelector('.phone'), box),
      copy: rectIn(st.querySelector('.copy'), box),
    }));
    const P = m.phone, C = m.copy;
    const cq = P.w / 100;
    const cs = clamp(W * 0.075, 88, 132);
    const spots = [[0.47, 0.13, -4], [0.585, 0.07, 3], [0.80, 0.10, -2], [0.92, 0.27, 5], [0.475, 0.40, 2], [0.86, 0.47, -3], [0.94, 0.68, 4], [0.48, 0.70, -5], [0.82, 0.84, 2], [0.62, 0.95, 3], [0.94, 0.92, -4], [0.465, 0.93, 2]];
    st.querySelectorAll('.covers li').forEach((li, i) => {
      const [fx, fy, r] = spots[i];
      const x0 = Math.max(C.r + 24, fx * W - cs / 2), y0 = fy * H - cs / 2;
      const tx = P.x + 3.3 * cq + 6 * cq, ty = P.y + 3.3 * cq + 30 * cq + i * 15 * cq + 1.75 * cq;
      li.style.cssText = `--i:${i};--cs:${f(cs)}px;--x0:${f(x0)}px;--y0:${f(y0)}px;--r0:${r}deg;--x1:${f(tx)}px;--y1:${f(ty)}px;--s1:${(11.5 * cq / cs).toFixed(4)};transform-origin:0 0`;
    });
    st.classList.add('ready');

    const svg = el('svg', { class: 'cable-stage', 'aria-hidden': 'true', width: W, height: H, viewBox: `0 0 ${W} ${H}` });
    st.prepend(svg);
    mass(svg, P.cx - P.w * 0.1, P.cy + P.h * 0.12, P.w * 0.95, 0, 1.3, pal);
    mass(svg, Math.min(W - 60, P.r + P.w * 0.62), P.y + P.h * 0.16, P.w * 0.38, 1, 2.1, pal);
    mass(svg, C.r + (P.x - C.r) * 0.35, H * 0.86, P.w * 0.3, 2, 3.7, pal);

    const xe = C.r + (P.x - C.r) * 0.42;
    const xo = Math.min(W - 70, P.r + (W - P.r) * 0.62);
    const way = [
      { x: xe, y: -2 }, { x: xe, y: H * 0.12 }, { x: xe + 24, y: H * 0.3 }, { x: P.cx - P.w * 0.1, y: P.y + P.h * 0.48 },
      { x: P.r + 40, y: P.y + P.h * 0.66 }, { x: P.r + (xo - P.r) * 0.4, y: P.y + P.h * 0.5 }, { x: xo - 30, y: P.y + P.h * 0.62 },
      { x: xo, y: H * 0.86 }, { x: xo, y: H + 2 },
    ];
    const c = cable(svg, spline(way), { levels: 4 }, pal);
    return { ...s, svg, c, entry: { x: xe }, exit: { x: xo }, W, H };
  }

  function buildOutput(s, pal) {
    const st = s.stage;
    const box = st.getBoundingClientRect();
    const W = box.width, H = box.height;
    const m = stageMeasure(st, () => ({
      copy: rectIn(st.querySelector('.copy'), box),
      phone: rectIn(st.querySelector('.d-phone .glass'), box),
      watch: rectIn(st.querySelector('.d-watch'), box),
      mac: rectIn(st.querySelector('.d-mac'), box),
      tv: rectIn(st.querySelector('.d-tv'), box),
    }));
    st.classList.add('ready');

    const svg = el('svg', { class: 'cable-stage', 'aria-hidden': 'true', width: W, height: H, viewBox: `0 0 ${W} ${H}` });
    st.prepend(svg);
    const { copy: C, phone: Ph, watch: Wt, mac: M, tv: TV } = m;
    mass(svg, TV.cx + TV.w * 0.12, TV.cy - TV.h * 0.05, TV.w * 0.5, 2, 4.2, pal);
    mass(svg, M.cx - M.w * 0.1, M.cy + M.h * 0.1, M.w * 0.42, 0, 5.1, pal);
    mass(svg, (Ph.cx + Wt.cx) / 2, Ph.cy + Ph.h * 0.1, Ph.w * 0.95, 1, 6.6, pal);

    const ring = 20;
    const xe = (C.r + Ph.x - ring) / 2;
    const lane = Math.min(H - 40, Math.max(Ph.b + ring, Wt.b, M.b + M.w * 0.09) + 40);
    const gx = Math.min(W - 26, TV.r + (W - TV.r) / 2);
    const way = [
      { x: xe, y: -2 }, { x: xe, y: H * 0.3 }, { x: xe + 4, y: lane - 80 }, { x: xe + 56, y: lane },
      { x: lerp(xe, gx, 0.5), y: lane + 10 }, { x: gx - 90, y: lane - 2 }, { x: gx - 4, y: lane + 56 },
      { x: gx, y: H * 0.95 }, { x: gx, y: H + 2 },
    ];
    const c = cable(svg, spline(way), { levels: 4 }, pal);
    return { ...s, svg, c, entry: { x: xe }, exit: { x: gx }, W, H };
  }

  function build() {
    teardown();
    const pal = palette();
    const gnd = ground();
    mode = mq.pin.matches ? 'pin' : mq.mobile.matches ? 'mobile' : 'flat';
    root.classList.toggle('cable-mobile', mode === 'mobile');
    const mr = main.getBoundingClientRect();
    const W = mr.width, H = main.scrollHeight;
    const svg = el('svg', { class: 'cable-page', 'aria-hidden': 'true', width: W, height: H, viewBox: `0 0 ${W} ${H}` });
    main.prepend(svg);
    const back = el('g', {}, svg);
    const front = el('g', {}, svg);
    const R = q => { const n = document.querySelector(q); return n ? rectIn(n, mr) : null; };
    const btn = R('[data-socket]');
    const pad = parseFloat(getComputedStyle(document.querySelector('.hero')).paddingLeft) || 24;
    page = { svg, segs: [], plugEnd: null, mode, W, H, mainTop: mr.top + scrollY, shown: null, t: 0 };

    let start, startHalf = null, heroPlug = null;
    {
      const A = R('[data-hero-art]');
      const hero = R('.hero');
      const s = Math.min(A.w, A.h);
      const L = mode === 'mobile' ? s * 0.66 : clamp(s * 0.6, 220, 390);
      const tip = { x: A.x + A.w * 0.74, y: A.y + A.h * 0.27 };
      const ang = -Math.PI / 4 - 0.06;
      const dir = { x: Math.cos(ang), y: Math.sin(ang) };
      const masses = [mass(back, A.x + A.w * 0.42, A.y + A.h * 0.62, s * 0.3, 0, 0.7, pal), mass(back, A.x + A.w * 0.86, A.y + A.h * 0.2, s * 0.15, 1, 1.9, pal), mass(back, A.x + A.w * 0.16, A.y + A.h * 0.18, s * 0.13, 2, 2.8, pal)];
      const ringC = { x: tip.x + dir.x * L * 0.05, y: tip.y + dir.y * L * 0.05 };
      const rg = rings(back, ringC, Math.atan2(dir.y, dir.x), s * 0.07, s * 0.045, 6, pal);
      const wv = waves(back, 0, W, hero.b - 66, pal, 5, ECHO * 1.5, 8, 340);
      const sock = el('g', {}, front);
      const sc = { x: tip.x - dir.x * L * 0.075, y: tip.y - dir.y * L * 0.075 };
      const sockR = [0.072, 0.098, 0.124].map(k => k * L);
      el('circle', { cx: f(sc.x), cy: f(sc.y), r: f(sockR[0]), fill: gnd }, sock);
      const sockLines = sockR.map((r, i) => el('path', { d: `M${f(sc.x + r)} ${f(sc.y)}A${f(r)} ${f(r)} 0 1 1 ${f(sc.x - r)} ${f(sc.y)}A${f(r)} ${f(r)} 0 1 1 ${f(sc.x + r)} ${f(sc.y)}`, stroke: pal.inks[[0, 1, 4][i]], 'stroke-width': LINE, pathLength: 1 }, sock));
      const pg = el('g', {}, front);
      const pl = plug(pg, tip, dir, L, pal, mode === 'mobile' ? 2 : 4, gnd, REACH);
      heroPlug = { g: pg, lines: pl.lines, masses, rings: rg, waves: wv, sock, sockLines, dir, L, centre: sc };
      start = pl.back;
      startHalf = pl.half - 3;
      const L1 = scenes.listen;
      const xe = L1 && L1.entry ? L1.entry.x : W * 0.5;
      const y1 = L1 && L1.entry ? L1.top : hero.b + 200;
      const tail = { x: start.x - dir.x * L * 0.35, y: start.y - dir.y * L * 0.35 };
      if (mode === 'pin') page.segs.push(cable(back, spline([start, tail, { x: lerp(tail.x, xe, 0.4), y: lerp(tail.y, y1, 0.55) }, { x: xe, y: y1 - (L1 && L1.entry ? 60 : 0) }, { x: xe, y: y1 + 2 }]), { levels: 4, from: 110, startHalf }, pal));
    }

    const plugL = mode === 'mobile' ? 70 : 150;
    const endTip = { x: btn.r + 3, y: btn.cy };
    const endBack = { x: endTip.x + plugL, y: endTip.y };
    const dirEnd = { x: -1, y: 0 };

    if (mode === 'pin') {
      const L1 = scenes.listen, O = scenes.output;
      const deck = R('.mixer'), rig = R('.rig');
      const gapTop = L1.top + L1.height, gapBot = O.top;
      const gap = gapBot - gapTop;
      const r = clamp(gap * 0.26, 56, 120);
      const ax = L1.exit.x, bx = O.entry.x;
      const C = { x: lerp(ax, bx, 0.5), y: gapTop + gap * 0.42 };
      page.segs.push(cable(back, looped({ x: ax, y: gapTop - 2 }, { x: bx, y: gapBot + 2 }, C, r), { levels: 4 }, pal));
      waves(back, 0, W, lerp(C.y + r, gapBot, 0.5), pal, 5, ECHO * 1.5, 8, 340);
      const oy = O.top + O.height;
      page.segs.push(cable(back, spline([
        { x: O.exit.x, y: oy - 2 }, { x: O.exit.x, y: oy + 60 }, { x: O.exit.x - 20, y: lerp(oy, rig.y, 0.45) }, { x: lerp(O.exit.x, deck.cx, 0.7), y: lerp(oy, rig.y, 0.82) }, { x: deck.cx, y: rig.y + 20 }, { x: deck.cx, y: deck.cy },
        { x: deck.cx, y: rig.b + 30 }, { x: Math.min(W - pad * 0.5, endBack.x + 120), y: lerp(rig.b, endTip.y, 0.55) },
        { x: endBack.x + 70, y: endTip.y - 6 }, endBack,
      ]), { levels: 4, to: 100, endHalf: plugL * 0.026 - 3 }, pal));
      mass(back, rig.x + rig.w * 0.2, rig.cy, rig.w * 0.24, 1, 7.7, pal);
      mass(back, rig.r - rig.w * 0.16, rig.cy + rig.h * 0.1, rig.w * 0.2, 2, 8.9, pal);
      page.chain = [{ c: page.segs[0] }, { c: L1.c, scene: L1 }, { c: page.segs[1] }, { c: O.c, scene: O }, { c: page.segs[2] }];
    } else {
      const gx = mode === 'mobile' ? W - 12 : W - Math.max(26, (W - Math.min(W, 1240 + pad * 2)) / 2 + pad * 0.5);
      const hb = R('.hero').b;
      const way = [start, { x: start.x - heroPlug.dir.x * 90, y: start.y - heroPlug.dir.y * 90 }, { x: gx, y: hb + (mode === 'mobile' ? 40 : 0) }];
      const endY = endTip.y - 160;
      for (let y = way[way.length - 1].y + 260, k = 0; y < endY; y += 260, k++) way.push({ x: gx + (k % 2 ? 1 : -1) * (mode === 'mobile' ? 2 : 10), y });
      way.push({ x: gx, y: endY }, { x: endBack.x + (mode === 'mobile' ? 26 : 60), y: endTip.y - 4 }, endBack);
      page.segs.push(cable(back, spline(way), { levels: mode === 'mobile' ? 2 : 4, from: 110, startHalf, to: 80, endHalf: plugL * 0.026 - (mode === 'mobile' ? 2.5 : 3) }, pal));
      [['.phone', 0], ['.d-tv', 2], ['.rig', 1]].forEach(([q, t], i) => { const r = R(q); if (r) mass(back, r.cx, r.cy, Math.min(r.w, 520) * 0.48, t, 9 + i, pal); });
      page.chain = [{ c: page.segs[0] }];
    }
    page.tl = timeline(page.chain);
    page.total = page.tl.total;

    const eg = el('g', { class: 'end-plug' }, front);
    const ep = plug(eg, endTip, dirEnd, plugL, pal, mode === 'mobile' ? 2 : 4, gnd);
    page.plugEnd = { g: eg, lines: ep.lines, btn: document.querySelector('[data-socket]'), seated: null };

    built = true;
    intro(heroPlug);
    collect();
    update(true);
  }

  function intro(h) {
    if (!h) return;
    if (mq.reduce.matches || introDone) return;
    introDone = true;
    if (scrollY > innerHeight * 0.5) return;
    const total = 1150, click = 880;
    h.masses.forEach((m, i) => { m.style.transformBox = 'fill-box'; m.style.transformOrigin = 'center'; m.animate([{ opacity: 0, transform: 'scale(.94)' }, { opacity: 1, transform: 'none' }], { duration: 700, delay: i * 80, easing: EASE, fill: 'both' }); });
    h.waves.forEach((w, i) => drawOn([w], 120 + i * 50, 700));
    drawOn(h.sockLines, 220, 520, EASE);
    drawOn(h.lines, 80, 720);
    heroDraw = { from: performance.now() + 180, dur: 900 };
    const d = h.L * 0.12;
    const back = `translate(${f(-h.dir.x * d)}px, ${f(-h.dir.y * d)}px)`;
    h.g.animate([
      { transform: back, offset: 0 }, { transform: back, offset: 640 / total, easing: 'cubic-bezier(.55,0,.9,.55)' },
      { transform: `translate(${f(h.dir.x * 3)}px, ${f(h.dir.y * 3)}px)`, offset: click / total, easing: 'cubic-bezier(.2,.8,.3,1)' },
      { transform: 'none', offset: 1 },
    ], { duration: total, fill: 'both' });
    h.sock.style.transformBox = 'view-box';
    h.sock.style.transformOrigin = `${f(h.centre.x)}px ${f(h.centre.y)}px`;
    h.sock.animate([{ transform: 'none' }, { transform: 'scale(1.12)', offset: 0.25 }, { transform: 'none' }], { delay: click, duration: 380, easing: 'ease-out' });
    h.rings.forEach((r, i) => {
      r.style.opacity = 0;
      r.animate([{ opacity: 0 }, { opacity: 1 }], { delay: click + i * 40, duration: 380, easing: EASE, fill: 'both' });
      drawOn([...r.children], click + i * 40, 420, EASE);
    });
  }
  let introDone = false;
  let heroDraw = null;

  function teardown() {
    document.querySelectorAll('.cable-page').forEach(n => n.remove());
    page = null;
  }

  function collect() {
    for (const k in scenes) {
      const s = scenes[k];
      s.anims = !SDA && mode === 'pin' ? s.sec.getAnimations({ subtree: true }).filter(a => a instanceof CSSAnimation) : [];
      s.lastP = -1;
    }
  }

  function setupScenes() {
    scenes = {};
    document.querySelectorAll('.cable-stage').forEach(n => n.remove());
    document.querySelectorAll('.stage.ready').forEach(n => n.classList.remove('ready'));
    if (mq.pin.matches) {
      const pal = palette(), gnd = ground();
      const l = sceneInfo('listen');
      const o = sceneInfo('output');
      if (l) scenes.listen = buildListen(l, pal, gnd);
      if (o) scenes.output = buildOutput(o, pal);
    }
  }

  function rebuild() {
    setupScenes();
    build();
  }

  const listenPlay = document.querySelector('.listen .view.play');
  const listenList = document.querySelector('.listen .np-list');
  const setInert = (n, v) => { if (n && n.inert !== v) n.inert = v; };

  function update(force) {
    if (!page) return;
    const reduced = mq.reduce.matches;
    const mtop = main.getBoundingClientRect().top;
    const vh = innerHeight;
    const now = performance.now();
    const sy = scrollY;
    const target = reduced ? page.total : lookup(page.tl, sy + penAt(sy, vh) - page.mainTop);
    const dt = Math.min(34, now - (page.t || now));
    page.t = now;
    let shown = page.shown;
    if (force || reduced || shown == null) shown = target;
    else {
      shown += (target - shown) * (1 - Math.exp(-dt / 60));
      if (Math.abs(target - shown) < 0.5) shown = target;
    }
    page.shown = shown;
    let drawn = shown;
    if (heroDraw) {
      const t = reduced ? 1 : (now - heroDraw.from) / heroDraw.dur;
      drawn = shown * easeOut(t);
      if (t >= 1) heroDraw = null;
    }
    for (const pc of page.chain) drawLength(pc.c, drawn - pc.base);

    for (const k in scenes) {
      const s = scenes[k];
      const p = clamp((-mtop - s.top) / s.span);
      if (s.anims.length && p !== s.lastP) s.anims.forEach(a => { a.currentTime = p * 1000; });
      s.lastP = p;
      if (k === 'listen') {
        if (override == null) renderTime(secFromP(p));
        setInert(listenPlay, mode === 'pin' && p < 0.42);
        setInert(listenList, mode === 'pin' && p < 0.79);
      }
    }
    if (!scenes.listen) { setInert(listenPlay, false); setInert(listenList, false); }

    if (!scenes.listen && np && override == null) {
      if (reduced) renderTime(1700);
      else {
        const r = np.getBoundingClientRect();
        renderTime(lerp(300, 4600, clamp((vh - r.top) / (vh + r.height))));
      }
    }

    const e = page.plugEnd;
    if (e) {
      const seated = reduced || drawn >= page.total - 1;
      if (seated !== e.seated) {
        const first = e.seated === null;
        e.seated = seated;
        const instant = reduced || first;
        e.g.getAnimations().forEach(a => a.cancel());
        e.g.animate(seated ? [{ opacity: 0, transform: 'translateX(18px)' }, { opacity: 1, transform: 'none' }] : [{ opacity: 1, transform: 'none' }, { opacity: 0, transform: 'translateX(18px)' }], { duration: instant ? 0 : 420, easing: EASE, fill: 'both' });
        e.btn.classList.toggle('seated', seated);
      }
    }
    if (shown !== target || heroDraw) schedule();
  }

  let frame = 0;
  const schedule = () => { if (!frame) frame = requestAnimationFrame(() => { frame = 0; update(false); }); };
  addEventListener('scroll', schedule, { passive: true });

  let timer = 0, lastW = innerWidth, lastH = innerHeight;
  const soon = () => { clearTimeout(timer); timer = setTimeout(rebuild, 160); };
  addEventListener('resize', () => {
    if (innerWidth === lastW && Math.abs(innerHeight - lastH) < 120 && mode === 'mobile') return;
    lastW = innerWidth; lastH = innerHeight;
    soon();
  });
  Object.values(mq).forEach(m => m.addEventListener('change', soon));
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => { if (built) soon(); });
  new ResizeObserver(() => { if (page && Math.abs(main.scrollHeight - page.H) > 2) soon(); }).observe(main);

  setupScenes();
  build();
})();
