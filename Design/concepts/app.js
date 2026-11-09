(() => {
  const params = new URLSearchParams(location.search);
  const root = document.documentElement;
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches || params.has("still");

  const setTheme = (t) => {
    if (t === "auto") root.removeAttribute("data-theme"); else root.setAttribute("data-theme", t);
    document.querySelectorAll(".theme-switch button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.theme === t)));
    try { localStorage.setItem("concept-theme", t); } catch (e) {}
  };
  let stored = "auto";
  try { stored = localStorage.getItem("concept-theme") || "auto"; } catch (e) {}
  setTheme(params.get("theme") || stored);
  document.querySelectorAll(".theme-switch button").forEach((b) => b.addEventListener("click", () => setTheme(b.dataset.theme)));

  const part = params.get("part");
  if (part) document.querySelectorAll("section.part").forEach((s) => { if (s.dataset.part !== part) s.hidden = true; });
  if (part) { const h = document.querySelector(".board-hero"); if (h && part !== "a") h.hidden = true; }

  function rng(seed) {
    let a = seed >>> 0;
    return () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  }

  const PAL = {
    light: { ground: "#fbf5ed", masses: ["#fcc9a3", "#ebd1e0", "#c4e3d6"], lines: ["#db5410", "#b3801f", "#147569", "#a8363d", "#452e24"] },
    dark: { ground: "#100d0c", masses: ["#6b2e14", "#3d2138", "#17403b"], lines: ["#f5bf66", "#6ecbb3", "#fa998f", "#f2e6d1"] },
  };
  const PROFILE = [[0,0],[.014,.022],[.036,.030],[.070,.030],[.076,.019],[.094,.019],[.100,.031],[.170,.031],[.176,.019],[.196,.019],[.202,.034],[.440,.034],[.446,.052],[.490,.052],[.496,.064],[.860,.064],[.930,.046],[1,.026]];
  const LAYOUTS = {
    hero: { w: 420, h: 380, tip: [345, 52], angle: 135, L: 270, n: 6, gap: 5.5, c1: 90, c2: [10, 430], end: [470, 340],
      masses: [[200, 215, 150, 0], [410, 10, 95, 1], [150, -20, 62, 2]], rings: [[410, 10, 9, 22, 7], [150, -20, 4, 14, 9]], waves: [[0, 330, 420, 3]] },
    banner: { w: 1200, h: 320, tip: [1120, 60], angle: 158, L: 400, n: 7, gap: 6, c1: 160, c2: [520, 420], end: [140, 330],
      masses: [[960, 190, 170, 0], [1180, 0, 110, 1], [700, 40, 70, 2]], rings: [[1180, 0, 10, 26, 8], [700, 40, 4, 14, 9]], waves: [] },
    square: { w: 300, h: 300, tip: [250, 46], angle: 132, L: 210, n: 5, gap: 5, c1: 70, c2: [0, 330], end: [330, 280],
      masses: [[150, 170, 120, 0], [300, 0, 80, 1], [30, 30, 50, 2]], rings: [[300, 0, 7, 18, 7]], waves: [] },
  };
  const f = (n) => n.toFixed(1);

  function blob(cx, cy, r, rnd) {
    const k = 7, pts = [];
    for (let i = 0; i < k; i++) { const a = (i / k) * Math.PI * 2 + rnd() * .3; const rr = r * (.82 + rnd() * .3); pts.push([cx + Math.cos(a) * rr, cy + Math.sin(a) * rr]); }
    let d = `M${f(pts[0][0])},${f(pts[0][1])}`;
    for (let i = 0; i < k; i++) {
      const p0 = pts[(i - 1 + k) % k], p1 = pts[i], p2 = pts[(i + 1) % k], p3 = pts[(i + 2) % k];
      const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6], c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6];
      d += ` C${f(c1[0])},${f(c1[1])} ${f(c2[0])},${f(c2[1])} ${f(p2[0])},${f(p2[1])}`;
    }
    return d + "Z";
  }

  function lineArt(svg) {
    const lay = LAYOUTS[svg.dataset.lineart || "hero"];
    let mode = svg.dataset.palette || "light";
    if (mode === "auto") {
      const t = root.getAttribute("data-theme");
      mode = t === "dark" || (!t && matchMedia("(prefers-color-scheme: dark)").matches) ? "dark" : "light";
    }
    const pal = PAL[mode];
    const rnd = rng(+(svg.dataset.seed || 7));
    const { w, h, L } = lay;
    const th = lay.angle * Math.PI / 180, u = [Math.cos(th), Math.sin(th)], v = [-Math.sin(th), Math.cos(th)];
    const T = lay.tip;
    const W = (x, y) => [T[0] + u[0] * x + v[0] * y, T[1] + u[1] * x + v[1] * y];
    const S = W(L, 0);
    const c1 = [S[0] + u[0] * lay.c1, S[1] + u[1] * lay.c1], c2 = lay.c2, E = lay.end;
    const samples = [];
    for (let i = 0; i <= 60; i++) {
      const t = i / 60, m = 1 - t;
      const p = [m*m*m*S[0] + 3*m*m*t*c1[0] + 3*m*t*t*c2[0] + t*t*t*E[0], m*m*m*S[1] + 3*m*m*t*c1[1] + 3*m*t*t*c2[1] + t*t*t*E[1]];
      const tx = 3*m*m*(c1[0]-S[0]) + 6*m*t*(c2[0]-c1[0]) + 3*t*t*(E[0]-c2[0]);
      const ty = 3*m*m*(c1[1]-S[1]) + 6*m*t*(c2[1]-c1[1]) + 3*t*t*(E[1]-c2[1]);
      const len = Math.hypot(tx, ty) || 1;
      samples.push({ p, n: [-ty / len, tx / len] });
    }
    const cw = .026 * L;
    let out = `<rect width="${w}" height="${h}" fill="${svg.dataset.ground === "none" ? "none" : pal.ground}"/>`;
    lay.masses.forEach(([cx, cy, r, ci]) => { out += `<path d="${blob(cx, cy, r, rnd)}" fill="${pal.masses[ci]}" opacity="${mode === "dark" ? .85 : .9}"/>`; });
    let idx = 0;
    const stroke = (d, c, sw = 1.5) => `<path class="dl" style="--i:${idx++}" pathLength="1" d="${d}" stroke="${c}" stroke-width="${sw}" fill="none" stroke-linejoin="round" stroke-linecap="round"/>`;
    lay.rings.forEach(([cx, cy, n, r0, g]) => { for (let i = 0; i < n; i++) out += stroke(`M${cx + r0 + i * g},${cy} a${r0 + i * g},${r0 + i * g} 0 1,0 ${-2 * (r0 + i * g)},0 a${r0 + i * g},${r0 + i * g} 0 1,0 ${2 * (r0 + i * g)},0`, pal.lines[(i + 1) % pal.lines.length], 1.2); });
    for (let k = 0; k < lay.n; k++) {
      const d = k * lay.gap, pts = [];
      for (let i = samples.length - 1; i >= 0; i--) { const s = samples[i]; pts.push([s.p[0] + s.n[0] * (cw + d), s.p[1] + s.n[1] * (cw + d)]); }
      for (let i = PROFILE.length - 1; i >= 1; i--) pts.push(W(PROFILE[i][0] * L, PROFILE[i][1] * L + d));
      pts.push(W(-d * .9, 0));
      for (let i = 1; i < PROFILE.length; i++) pts.push(W(PROFILE[i][0] * L, -(PROFILE[i][1] * L + d)));
      for (let i = 0; i < samples.length; i++) { const s = samples[i]; pts.push([s.p[0] - s.n[0] * (cw + d), s.p[1] - s.n[1] * (cw + d)]); }
      out += stroke("M" + pts.map((p) => f(p[0]) + "," + f(p[1])).join(" L"), pal.lines[k % pal.lines.length], k === 0 ? 1.8 : 1.4);
    }
    let hatch = "";
    for (let x = .52; x < .85; x += .016) { const a = W(x * L, -.064 * L), b = W((x + .03) * L, .064 * L); hatch += `M${f(a[0])},${f(a[1])} L${f(b[0])},${f(b[1])} `; }
    out += stroke(hatch, pal.lines[1], 1);
    lay.waves.forEach(([x0, y0, x1, n]) => {
      for (let j = 0; j < n; j++) {
        let d = "";
        for (let x = x0; x <= x1; x += 6) { const y = y0 + j * 7 + Math.sin(x * .035 + j) * 5; d += (d ? " L" : "M") + f(x) + "," + f(y); }
        out += stroke(d, pal.lines[(j + 2) % pal.lines.length], 1.1);
      }
    });
    svg.setAttribute("viewBox", `0 0 ${w} ${h}`);
    svg.innerHTML = out;
    svg.classList.add("lineart");
  }

  const style = document.createElement("style");
  style.textContent = `.lineart .dl{stroke-dasharray:1;stroke-dashoffset:1}.lineart.go .dl{animation:dl 2.6s var(--ease) forwards;animation-delay:calc(var(--i) * 70ms)}.lineart.still .dl{stroke-dashoffset:0}@keyframes dl{to{stroke-dashoffset:0}}`;
  document.head.appendChild(style);

  const playArt = (svg) => {
    if (reduced) { svg.classList.add("still"); return; }
    svg.classList.remove("go"); void svg.getBoundingClientRect(); svg.classList.add("go");
  };
  const io = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { playArt(e.target); io.unobserve(e.target); } }), { threshold: .2 });
  document.querySelectorAll("svg[data-lineart]").forEach((s) => { lineArt(s); if (params.has("still")) s.classList.add("still"); else io.observe(s); });
  const refreshAuto = () => document.querySelectorAll('svg[data-palette="auto"]').forEach((sv) => { lineArt(sv); sv.classList.add("still"); });
  document.querySelectorAll(".theme-switch button").forEach((b) => b.addEventListener("click", refreshAuto));
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", refreshAuto);
  document.querySelectorAll("[data-replay]").forEach((b) => b.addEventListener("click", () => document.querySelectorAll(b.dataset.replay).forEach(playArt)));

  function bars(n, seed) {
    const r = rng(seed), out = [];
    let prev = .5;
    for (let i = 0; i < n; i++) {
      const env = .55 + .45 * Math.sin(i / n * Math.PI * 3.2 + seed) * Math.sin(i / n * Math.PI);
      prev = prev * .45 + r() * .55;
      out.push(Math.max(.12, Math.min(1, env * (.45 + prev * .7))));
    }
    return out;
  }
  document.querySelectorAll(".wave[data-n]").forEach((el) => {
    const hs = bars(+el.dataset.n, +(el.dataset.seed || 3));
    el.innerHTML = hs.map((v) => `<i style="height:${(v * 100).toFixed(0)}%"></i>`).join("");
  });
  document.querySelectorAll(".played > .wave").forEach((w) => { w.style.width = w.parentElement.parentElement.clientWidth + "px"; });
  document.querySelectorAll("svg[data-bigwave]").forEach((svg) => {
    const n = 150, hs = bars(n, 11), W = 558, H = 150, bw = W / n;
    const id = "g" + Math.random().toString(36).slice(2, 7);
    let s = `<defs><linearGradient id="${id}" x1="0" x2="1"><stop offset="0" stop-color="#ffdb9e"/><stop offset=".4" stop-color="#e0915a"/><stop offset=".75" stop-color="#c25a4a"/><stop offset="1" stop-color="#6ecbb3"/></linearGradient></defs>`;
    hs.forEach((v, i) => { const bh = v * (H - 30); s += `<rect x="${(i * bw).toFixed(1)}" y="${((H - bh) / 2 + 6).toFixed(1)}" width="${(bw - 1.2).toFixed(1)}" height="${bh.toFixed(1)}" rx="1.2" fill="url(#${id})" opacity="${i / n < .42 ? 1 : .32}"/>`; });
    svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
    svg.setAttribute("preserveAspectRatio", "none");
    svg.innerHTML = s;
  });

  const lp = document.getElementById("lp");
  if (lp) {
    const TL = [[0,"Tide Tables (Intro)","Maren Holt"],[232,"Saltwater","Teodora"],[510,"Lanterns (Maren Holt Edit)","Pale Harbour"],[785,"Undertow","Kōji Aren"],[1068,"ID","Unidentified"],[1330,"Glass Tide","Nilu & Brask"],[1655,"Northbound (Dub)","Cassia Moor"],[1940,"Halfway House","Sennet"],[2222,"ID","Unidentified"],[2500,"Sodium Lights (Club Mix)","Okari"],[2835,"Long Exposure","Fen Ashby"],[3210,"Paper Satellites (Rework)","Juno Vale"]];
    const CM = [[960,"K","#3a8f86","sounds like unreleased Ardent Fields to me"],[1012,"M","#8b4fb3","that bassline at 16:50"],[1050,"J","#c0603a","ID? anyone?"],[1090,"R","#2f6db3","Pier Nine never misses"],[1140,"S","#a8363d","saved this to my Sunday set"],[1190,"T","#7a8a2f","the switch into Glass Tide is perfect"],[1240,"L","#3a8f86","heard this live, the room went quiet"],[1300,"N","#8b4fb3","Nilu & Brask again"],[1380,"P","#c0603a","keys on this one"],[1460,"E","#2f6db3","volume up for this bit"]];
    const UN = [["Low Tide 042 — Harbour Lights","Maren Holt"],["Northbound (Dub)","Cassia Moor"],["Glasshouse Session 7","Teodora"]];
    const D = 3600;
    let t = 1020, playing = false, tab = "tracklist", last = 0;
    const $ = (s) => lp.querySelector(s);
    const fmt = (s) => { s = Math.max(0, Math.round(s)); return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0"); };
    const wv = $(".wv"), played = $(".played"), panel = $(".panel");
    played.querySelector(".wave").style.width = wv.clientWidth + "px";
    const cur = () => { let i = 0; TL.forEach((e, j) => { if (e[0] <= t) i = j; }); return i; };
    const render = () => {
      played.style.width = (t / D * 100) + "%";
      $(".el").textContent = fmt(t);
      $(".rem").textContent = "−" + fmt(D - t);
      const c = cur();
      $(".now").innerHTML = `<span aria-hidden="true">≡</span> ${TL[c][2]} — ${TL[c][1]}`;
      const cm = CM.filter((x) => x[0] <= t).pop() || CM[0];
      const b = $(".bubble");
      if (b.dataset.k !== String(cm[0])) { b.dataset.k = cm[0]; b.innerHTML = `<i style="background:${cm[2]}">${cm[1]}</i>${cm[3]}`; }
      if (tab === "tracklist") {
        const start = Math.max(0, Math.min(c - 1, TL.length - 5));
        panel.innerHTML = TL.slice(start, start + 5).map((e, j) => `<div class="row${start + j === c ? " on" : ""}"><span>${fmt(e[0])}</span><div><b>${e[1]}</b>${e[2]}</div></div>`).join("");
      } else if (tab === "comments") {
        const near = CM.filter((x) => x[0] <= t).slice(-5).reverse();
        panel.innerHTML = near.map((x) => `<div class="cm"><i style="background:${x[2]}">${x[1]}</i><div>${x[3]}</div><span>${fmt(x[0])}</span></div>`).join("");
      } else {
        panel.innerHTML = UN.map((x, j) => `<div class="row"><span>${j + 1}</span><div><b>${x[0]}</b>${x[1]}</div></div>`).join("");
      }
      $(".pp").innerHTML = playing ? '<svg viewBox="0 0 24 24"><rect x="6" y="4" width="4" height="16" rx="1"/><rect x="14" y="4" width="4" height="16" rx="1"/></svg>' : '<svg viewBox="0 0 24 24"><path d="M7 4.5v15a1 1 0 0 0 1.5.86l12.4-7.5a1 1 0 0 0 0-1.72L8.5 3.64A1 1 0 0 0 7 4.5z"/></svg>';
      $(".pp").setAttribute("aria-label", playing ? "Pause" : "Play");
    };
    let timer = 0, visible = false, wanted = false;
    const step = () => { const now = performance.now(); if (last) t = Math.min(D, t + (now - last) / 1000 * 8); last = now; if (t >= D) setPlaying(false); render(); };
    const setPlaying = (p) => {
      playing = p; last = 0; clearInterval(timer);
      if (p) timer = setInterval(step, 40);
      render();
    };
    $(".pp").addEventListener("click", () => { wanted = !playing; setPlaying(wanted); });
    $(".prev").addEventListener("click", () => { const c = cur(); t = TL[Math.max(0, t - TL[c][0] > 5 ? c : c - 1)][0]; render(); });
    $(".next").addEventListener("click", () => { const c = cur(); t = TL[Math.min(TL.length - 1, c + 1)][0]; render(); });
    wv.addEventListener("click", (e) => { const r = wv.getBoundingClientRect(); t = (e.clientX - r.left) / r.width * D; render(); });
    wv.addEventListener("keydown", (e) => { if (e.key === "ArrowRight") { t = Math.min(D, t + 30); render(); } if (e.key === "ArrowLeft") { t = Math.max(0, t - 30); render(); } });
    lp.querySelectorAll(".tabs button").forEach((b) => b.addEventListener("click", () => {
      tab = b.dataset.tab; lp.querySelectorAll(".tabs button").forEach((x) => x.setAttribute("aria-selected", String(x === b))); render();
    }));
    render();
    wanted = !reduced && !params.has("still");
    new IntersectionObserver((es) => es.forEach((e) => { visible = e.isIntersecting; setPlaying(visible && wanted); }), { threshold: .4 }).observe(lp);
  }

  const CRIT = [
    ["Brand fit", "copper jack"], ["Clarity", "first visit"], ["App Store", "readiness"], ["Wow", "first impression"],
    ["Performance", "5 = lightest"], ["Accessibility", "as designed"], ["Build effort", "5 = cheapest"], ["Maintenance", "5 = least upkeep"],
  ];
  const WEIGHTS = {
    balanced: [1, 1, 1, 1, 1, 1, 1, 1],
    launch: [1, 2, 2, .5, 1, 1, 2, 1.5],
    brand: [2.5, 1, 1, 2, .5, 1, .5, .5],
  };
  const CONCEPTS = [
    ["1", "Copper line-art", true, [[5,"It is the onboarding art, now moving"],[4,"Headline says it; product shown just below the fold"],[4,"Same art as the welcome screenshot"],[4,"Draw-on is memorable, not loud"],[4,"~40 SVG paths, no hero image"],[4,"Decorative SVG, static under reduced motion"],[3,"Port the Swift generator to JS"],[4,"Procedural: nothing to re-render"]]],
    ["2", "Product-first, Apple-style", false, [[3,"Calm and premium, copper only as accent"],[5,"Shows the app on every device at once"],[5,"Device shots mirror the store listing"],[3,"Expected; polished, not surprising"],[3,"4–6 device images, ~150 KB each"],[5,"Plain sections, real text, simple tabs"],[4,"Layout is simple; framing takes care"],[2,"Every UI change stales five platforms of shots"]]],
    ["3", "Live player", false, [[3,"Now Playing is dark and warm; no jack"],[4,"You use the product before reading about it"],[3,"Must be labelled a demo with fixture music"],[5,"Moving playhead, comments, tracklist"],[2,"Most JS on the page; must lazy-start"],[2,"Custom controls need full keyboard and ARIA"],[2,"A mini player in JS is real work"],[2,"Must track every Now Playing redesign"]]],
    ["4", "Editorial zine", false, [[3,"DJ culture fits; the jack is absent"],[3,"Style first, product second"],[3,"Fine, but tone differs from the listing"],[4,"Distinctive in a sea of app sites"],[5,"Type and a few small images"],[4,"Good contrast; giant type needs care"],[3,"Responsive big type takes craft"],[4,"Copy edits only"]]],
    ["5", "Dark club", false, [[4,"Copper on black echoes the icon's felt"],[3,"Reads as a DJ tool; undersells listening"],[3,"Dark-only clashes with light listing shots"],[4,"Glowing waveform hero lands"],[3,"Glow and blur cost on low-end phones"],[3,"Low-contrast greys must be fixed"],[3,"Waveform and decks art to build"],[4,"Procedural waveform, few assets"]]],
    ["6", "Minimal one-pager", false, [[2,"Only the icon carries the brand"],[4,"One sentence, one button"],[4,"Fast, honest, badge-ready"],[1,"Forgettable"],[5,"Under 100 KB"],[5,"Text and a list"],[5,"An afternoon"],[5,"Nothing to maintain"]]],
    ["7", "Felt & copper photo", false, [[5,"The actual icon photography, full bleed"],[3,"Beautiful object, says little until you scroll"],[4,"Matches the icon on the store page"],[4,"Macro photo of the jack is striking"],[2,"Full-bleed photo is the heaviest hero"],[4,"Text on photo needs a scrim"],[4,"Masters already exist in Branding/"],[4,"Photos don't go stale"]]],
    ["8", "One session, every screen", false, [[3,"Copper cable motif ties devices together"],[4,"Tells the multi-device story at once"],[4,"Device-led, like the listing"],[4,"A track moving between screens"],[3,"Three device images plus motion"],[3,"Narrative motion needs a static version"],[2,"Choreography across three frames"],[2,"Three device UIs to keep current"]]],
    ["9", "The page is a tracklist", false, [[3,"DJ-native; copper as the highlight"],[3,"Clever; some visitors miss the conceit"],[3,"Fine, but the gimmick doesn't carry to the store"],[4,"Scroll position as mix position"],[4,"Mostly text, one waveform"],[3,"Must never hijack scroll"],[3,"Scroll-linked chapters to tune"],[4,"Sections are rows; easy to add"]]],
    ["10", "astra draft", false, [[5,"Welcome art and copper, done well"],[4,"Clear headline; phones early"],[4,"CTA says Get Sounding, not TestFlight"],[4,"Draw-on hero"],[4,"148 KB images, 1.5 KB JS"],[3,"Own check: FAQ and toggle not keyboard"],[5,"Already built"],[3,"Phone and Mac shots to keep fresh"]]],
    ["11", "sol draft", false, [[3,"Copper type only; no jack"],[5,"Product working above the fold"],[4,"Labelled preview; CTA is email"],[4,"Scrubbable player"],[4,"100 KB images, 13 KB JS"],[3,"Player ARIA unverified"],[5,"Already built"],[2,"Player must track Now Playing"]]],
  ];
  const tbody = document.getElementById("crit-body");
  if (tbody) {
    document.getElementById("crit-head").innerHTML = "<th>Concept</th>" + CRIT.map((c) => `<th>${c[0]}<small>${c[1]}</small></th>`).join("") + "<th>Total<small>weighted, of 5</small></th>";
    const draw = (wkey) => {
      const w = WEIGHTS[wkey], ws = w.reduce((a, b) => a + b, 0);
      const totals = CONCEPTS.map((c) => c[3].reduce((a, s, i) => a + s[0] * w[i], 0) / ws);
      const order = totals.map((v, i) => [v, i]).sort((a, b) => b[0] - a[0]).map((x) => x[1]);
      tbody.innerHTML = CONCEPTS.map((c, i) => `<tr class="${c[2] ? "recommended" : ""}"><th scope="row">${c[0]} · ${c[1]}</th>${c[3].map((s) => `<td><div class="score s${s[0]}"><b>${s[0]}</b><span>${s[1]}</span></div></td>`).join("")}<td><div class="total">${totals[i].toFixed(2)}<small class="rank">#${order.indexOf(i) + 1} of ${CONCEPTS.length}</small></div></td></tr>`).join("");
      document.querySelectorAll("[data-weights]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.weights === wkey)));
    };
    document.querySelectorAll("[data-weights]").forEach((b) => b.addEventListener("click", () => draw(b.dataset.weights)));
    draw("balanced");
  }

  const SECTIONS = ["Hero", "Now Playing", "Tracklists & Identify", "Decks & Auto Mix", "Output", "Analysis", "Downloads", "Watch & Polyphony", "Platforms", "Privacy", "TestFlight CTA", "FAQ", "Support", "Footer line", "Signature element"];
  const SEC = [
    ["1 · Copper line-art", "ffffffffffffff", "Draw-on jack and cable"],
    ["2 · Product-first", "ffffffffffffff", "Device line-up, bento tiles"],
    ["3 · Live player", "ffflllllffflff", "Playable Now Playing"],
    ["4 · Editorial zine", "fffflllllff-lf", "Masthead, typeset tracklist"],
    ["5 · Dark club", "flfffflllff-lf", "Waveform hero, decks"],
    ["6 · Minimal", "flllllllllfflf", "One column, one button"],
    ["7 · Felt & copper", "fllllfflffflff", "Macro photo of the jack"],
    ["8 · Every screen", "flllfllfffffff", "Track travels device to device"],
    ["9 · Tracklist page", "ffffffffffflff", "Scroll = mix position"],
    ["10 · astra draft", "fflfflflfffflf", "Drawn jack, dark room bands"],
    ["11 · sol draft", "ffffflflfffflf", "Playable Now Playing under the headline"],
  ];
  const sb = document.getElementById("sec-body");
  if (sb) {
    document.getElementById("sec-head").innerHTML = "<th>Concept</th>" + SECTIONS.map((s) => `<th>${s}</th>`).join("");
    const sym = { f: ['<span class="has" title="Featured">●</span>'], l: ['<span class="lite" title="Brief">◐</span>'], "-": ['<span class="none" title="Absent">—</span>'] };
    sb.innerHTML = SEC.map((r) => `<tr${r[0].startsWith("1 ") ? ' class="recommended"' : ""}><th scope="row">${r[0]}</th>${[...r[1]].map((c) => `<td class="dot-cell">${sym[c][0]}</td>`).join("")}<td>${r[2]}</td></tr>`).join("");
  }

  const quad = document.getElementById("quad");
  if (quad) {
    const PTS = [
      ["5 Siri + entities", "M", 46, 15, false, "High: voice control with no user-made shortcut, plus the entities unlock controls, model tools, Scout and alarms."],
      ["8 Scout", "L", 86, 13, true, "Highest: unique, and the right fit for a no-server app. The CloudKit relay is the risky piece."],
      ["2 Controls", "S", 15, 27, false, "Visible on every Lock Screen and the Action button; small once the widget target is back."],
      ["3 Widgets", "S–M", 27, 41, false, "Lock Screen and StandBy are nice and expected, but passive."],
      ["4 Model: tags, summaries", "M", 55, 36, false, "Tags help sorting and DJ prep. Summaries are pleasant. Both need fallbacks."],
      ["7 TipKit", "S", 12, 68, false, "Low glamour, but it surfaces Comments, Tracklist and Output to new users before launch."],
      ["6 Wake + sleep", "M", 41, 60, true, "Sleep timer is a common ask; wake-to-mix is charming but niche, and the tone can't be the mix."],
      ["1 SharePlay: playback", "M", 58, 64, false, "Fun with friends, but niche for a SoundCloud client; a terms question hangs over it."],
      ["1 SharePlay: DJ-synced", "L", 86, 80, true, "Impressive, but needs a shared clock across MixEngines, for a small audience."],
    ];
    quad.insertAdjacentHTML("beforeend", PTS.map((p) => `<div class="pt${p[4] ? " l" : ""}" tabindex="0" style="left:${p[2]}%;top:${p[3]}%"><i></i><span>${p[0]} <em>${p[1]}</em></span><span class="tip">${p[5]}</span></div>`).join(""));
  }

  const deps = document.getElementById("deps");
  if (deps) {
    const N = {
      ent: [20, 44, 116, "App entities", "4 entity types", true],
      api: [142, 44, 116, "Play intents", "exist: 3", false],
      grp: [264, 44, 116, "App Group", "mix + position", true],
      wdg: [386, 44, 116, "Widget target", "restore from main", true],
      bon: [508, 44, 116, "Bonjour to TV", "exists", false],
      spot: [630, 44, 116, "Spotlight", "IndexedEntity", true],
      fm: [752, 44, 116, "Model gate", "+ non-AI fallback", true],
      ck: [874, 44, 106, "CloudKit inbox", "exists", false],
      f1: [20, 236, 116, "1 SharePlay", "", false], f2: [142, 236, 116, "2 Controls", "", false], f3: [264, 236, 116, "3 Widgets", "", false],
      f4: [386, 236, 116, "4 Model", "", false], f5: [508, 236, 116, "5 Siri", "", false], f6: [630, 236, 116, "6 Alarm, sleep", "", false],
      f7: [752, 236, 116, "7 TipKit", "", false], f8: [874, 236, 106, "8 Scout", "", false],
    };
    const E = [
      ["ent", "f5"], ["ent", "f2"], ["ent", "f4"], ["ent", "f8"], ["ent", "f6"],
      ["api", "f2"], ["api", "f5"], ["api", "f6"],
      ["grp", "f2"], ["grp", "f3"], ["grp", "f6", 1],
      ["wdg", "f2"], ["wdg", "f3"], ["wdg", "f6", 1],
      ["fm", "f4"], ["fm", "f8", 1],
      ["ck", "f8"], ["ck", "f7", 1], ["ck", "f4", 1],
      ["spot", "f5", 1], ["spot", "f4", 1],
      ["bon", "f2", 1], ["bon", "f5", 1],
    ];
    const H = (k) => (N[k][4] ? 52 : 44);
    let s = `<text class="lane" x="20" y="30">FOUNDATIONS · copper = to build, grey = exists</text><text class="lane" x="20" y="224">FEATURES</text>`;
    E.forEach(([a, b, soft]) => {
      const A = N[a], B = N[b];
      const sx = A[0] + A[2] / 2, sy = A[1] + H(a), tx = B[0] + B[2] / 2, ty = B[1];
      s += `<path class="edge${soft ? " soft" : ""}" d="M${sx},${sy} C${sx},${sy + 70} ${tx},${ty - 70} ${tx},${ty}"/>`;
    });
    Object.entries(N).forEach(([k, n]) => {
      const h = H(k);
      s += `<g class="node${n[5] ? " found" : ""}"><rect x="${n[0]}" y="${n[1]}" width="${n[2]}" height="${h}" rx="10"/><text x="${n[0] + 12}" y="${n[1] + (n[4] ? 21 : 27)}">${n[3]}</text>${n[4] ? `<text class="small" x="${n[0] + 12}" y="${n[1] + 38}">${n[4]}</text>` : ""}</g>`;
    });
    deps.innerHTML = s;
  }

  const toc = [...document.querySelectorAll(".toc a[href^='#']")];
  const targets = toc.map((a) => document.querySelector(a.getAttribute("href"))).filter(Boolean);
  const spy = () => {
    let active = null;
    for (const t of targets) { if (t.getBoundingClientRect().top < 140) active = t; }
    toc.forEach((a) => a.classList.toggle("active", active && a.getAttribute("href") === "#" + active.id));
    if (active) {
      const top = active.closest("section.part");
      if (top) toc.forEach((a) => { if (a.getAttribute("href") === "#" + top.id) a.classList.add("active"); });
    }
  };
  addEventListener("scroll", spy, { passive: true });
  spy();

  const dec = document.querySelectorAll(".decision");
  const ans = document.getElementById("answer-text");
  const build = () => {
    const parts = [];
    dec.forEach((d) => {
      const on = [...d.querySelectorAll(".choice[aria-pressed='true']")].map((b) => b.dataset.v);
      parts.push(`${d.dataset.key}: ${on.length ? on.join("+") : "?"}`);
    });
    if (ans) ans.textContent = parts.join(", ");
  };
  const reset = () => { dec.forEach((d) => d.querySelectorAll(".choice").forEach((b) => b.setAttribute("aria-pressed", String(b.hasAttribute("data-rec"))))); build(); };
  dec.forEach((d) => d.querySelectorAll(".choice").forEach((b) => b.addEventListener("click", () => {
    if (d.dataset.multi === "true") b.setAttribute("aria-pressed", String(b.getAttribute("aria-pressed") !== "true"));
    else d.querySelectorAll(".choice").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
    build();
  })));
  reset();
  const copyBtn = document.getElementById("copy-answer");
  if (copyBtn) copyBtn.addEventListener("click", async () => {
    try { await navigator.clipboard.writeText(ans.textContent); copyBtn.textContent = "Copied"; } catch (e) { copyBtn.textContent = "Select and copy"; }
    setTimeout(() => (copyBtn.textContent = "Copy answer"), 1600);
  });
  const resetBtn = document.getElementById("reset-answer");
  if (resetBtn) resetBtn.addEventListener("click", reset);
})();
