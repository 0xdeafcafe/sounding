(() => {
  "use strict";

  const doc = document.documentElement;
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  // Progressive enhancement: only hide .reveal elements (for the scroll-in
  // animation) once we know JS is actually running. No-JS visitors get the
  // full page with no motion at all.
  doc.classList.add("js-ready");

  /* ---------------- Scroll reveal ---------------- */

  const revealTargets = document.querySelectorAll("[data-reveal]");

  if ("IntersectionObserver" in window && revealTargets.length) {
    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            io.unobserve(entry.target);
          }
        }
      },
      { threshold: 0.14, rootMargin: "0px 0px -8% 0px" }
    );
    revealTargets.forEach((el) => io.observe(el));
  } else {
    revealTargets.forEach((el) => el.classList.add("is-visible"));
  }

  /* ---------------- Deterministic PRNG ----------------
     Small seeded generator so the waveform / QR mockup look the same on
     every load and every reload, rather than reshuffling like noise. */

  function mulberry32(seed) {
    let a = seed >>> 0;
    return function () {
      a |= 0;
      a = (a + 0x6d2b79f5) | 0;
      let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  const SVGNS = "http://www.w3.org/2000/svg";
  function svgEl(tag, attrs) {
    const el = document.createElementNS(SVGNS, tag);
    for (const k in attrs) el.setAttribute(k, attrs[k]);
    return el;
  }

  /* ---------------- Waveform ---------------- */

  function buildWaveform() {
    const mount = document.getElementById("waveform-mount");
    if (!mount) return;

    const rand = mulberry32(1337);
    const bars = 130;
    const viewW = 1000;
    const viewH = 160;
    const mid = viewH / 2;
    const gap = viewW / bars;
    const barW = Math.max(1.6, gap * 0.55);

    // Playhead position (fraction through the track) — matches the "3
    // timed comments" copy: track is mid-scrub, well past the first two
    // comments and approaching the third.
    const playFrac = 0.42;

    const svg = svgEl("svg", {
      viewBox: `0 0 ${viewW} ${viewH + 20}`,
      preserveAspectRatio: "none",
      role: "presentation",
    });

    const playedColor = "var(--accent)";
    const unplayedColor = "rgba(255,255,255,0.22)";

    for (let i = 0; i < bars; i++) {
      const t = i / bars;
      // A loose envelope so the waveform reads like a real track (a build
      // toward the middle) rather than uniform noise, plus per-bar jitter.
      const envelope = 0.28 + 0.62 * Math.sin(t * Math.PI * 0.92 + 0.1);
      const jitter = 0.35 + rand() * 0.65;
      const amp = Math.max(0.06, Math.min(1, envelope * jitter));
      const h = amp * (viewH / 2 - 6);
      const x = i * gap + (gap - barW) / 2;
      const isPlayed = t <= playFrac;

      const rect = svgEl("rect", {
        x: x.toFixed(2),
        y: (mid - h).toFixed(2),
        width: barW.toFixed(2),
        height: (h * 2).toFixed(2),
        rx: Math.min(barW / 2, 2),
        fill: isPlayed ? playedColor : unplayedColor,
      });
      svg.appendChild(rect);
    }

    // Playhead line
    const playX = playFrac * viewW;
    svg.appendChild(
      svgEl("line", {
        x1: playX.toFixed(2),
        x2: playX.toFixed(2),
        y1: 4,
        y2: viewH - 4,
        stroke: "var(--accent)",
        "stroke-width": 2,
        "stroke-linecap": "round",
        opacity: 0.9,
      })
    );
    svg.appendChild(
      svgEl("circle", {
        cx: playX.toFixed(2),
        cy: mid,
        r: 5,
        fill: "var(--accent)",
      })
    );

    mount.appendChild(svg);

    // Timed comment pins — positioned as real interactive buttons layered
    // over the SVG, so they stay keyboard/screen-reader accessible rather
    // than being baked into the drawing.
    const comments = [
      {
        frac: 0.16,
        time: "1:47",
        who: "jules_m",
        text: "this intro is criminal, running it back already",
      },
      {
        frac: 0.31,
        time: "3:12",
        who: "reeceh",
        text: "what's this transition into?? need the ID",
        search: true,
      },
      {
        frac: 0.63,
        time: "5:08",
        who: "kaydotcom",
        text: "the drop right here, every time",
      },
    ];

    const pinLayer = document.createElement("div");
    pinLayer.style.position = "absolute";
    pinLayer.style.inset = "0";
    pinLayer.style.pointerEvents = "none";
    mount.style.position = "relative";

    comments.forEach((c) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "wave-pin";
      btn.style.position = "absolute";
      btn.style.left = (c.frac * 100).toFixed(2) + "%";
      btn.style.top = "8px";
      btn.style.transform = "translate(-50%, -100%)";
      btn.style.pointerEvents = "auto";
      btn.setAttribute(
        "aria-label",
        `Comment at ${c.time} from ${c.who}: ${c.text}`
      );

      const dotSvg = document.createElementNS(SVGNS, "svg");
      dotSvg.setAttribute("width", "14");
      dotSvg.setAttribute("height", "14");
      dotSvg.setAttribute("viewBox", "0 0 14 14");
      const dot = svgEl("circle", { cx: 7, cy: 7, r: 5 });
      dot.setAttribute("class", "wave-pin-dot");
      dotSvg.appendChild(dot);
      btn.appendChild(dotSvg);

      const tip = document.createElement("span");
      tip.className = "wave-tip";
      tip.innerHTML =
        `<strong>${c.time} · ${c.who}</strong>${c.text}` +
        (c.search
          ? `<span class="search-chip">Search this comment →</span>`
          : "");
      btn.appendChild(tip);

      pinLayer.appendChild(btn);
    });

    mount.appendChild(pinLayer);
  }

  /* ---------------- QR mockup ---------------- */

  function buildQR() {
    const mount = document.getElementById("qr-mount");
    if (!mount) return;

    const size = 21; // module grid
    const rand = mulberry32(9);
    const matrix = Array.from({ length: size }, () => new Array(size).fill(0));

    function stampFinder(ox, oy) {
      for (let y = 0; y < 7; y++) {
        for (let x = 0; x < 7; x++) {
          const onBorder = x === 0 || x === 6 || y === 0 || y === 6;
          const onCore = x >= 2 && x <= 4 && y >= 2 && y <= 4;
          matrix[oy + y][ox + x] = onBorder || onCore ? 1 : 0;
        }
      }
    }
    stampFinder(0, 0);
    stampFinder(size - 7, 0);
    stampFinder(0, size - 7);

    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        const inFinderZone =
          (x < 8 && y < 8) ||
          (x >= size - 8 && y < 8) ||
          (x < 8 && y >= size - 8);
        if (inFinderZone) continue;
        matrix[y][x] = rand() > 0.56 ? 1 : 0;
      }
    }

    const cell = 100 / size;
    const svg = svgEl("svg", {
      viewBox: `0 0 100 100`,
      role: "presentation",
    });
    svg.appendChild(
      svgEl("rect", { x: 0, y: 0, width: 100, height: 100, fill: "#ffffff", rx: 4 })
    );
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        if (!matrix[y][x]) continue;
        svg.appendChild(
          svgEl("rect", {
            x: (x * cell).toFixed(2),
            y: (y * cell).toFixed(2),
            width: (cell * 0.94).toFixed(2),
            height: (cell * 0.94).toFixed(2),
            fill: "#0a0a0d",
          })
        );
      }
    }
    mount.appendChild(svg);
  }

  /* ---------------- Subtle hero parallax / tilt ---------------- */

  function initHeroParallax() {
    if (reducedMotion.matches) return;
    const scene = document.getElementById("hero-scene");
    const tv = document.getElementById("hero-tv");
    const phone = document.getElementById("hero-phone");
    if (!scene || !tv) return;

    let ticking = false;
    function onScroll() {
      if (ticking) return;
      ticking = true;
      requestAnimationFrame(() => {
        const rect = scene.getBoundingClientRect();
        const progress = 1 - Math.min(1, Math.max(0, rect.top / window.innerHeight));
        const shift = (progress - 0.5) * 14;
        tv.style.transform = `translateY(${(-shift).toFixed(2)}px)`;
        if (phone) phone.style.transform = `translateY(${(shift * 0.6).toFixed(2)}px)`;
        ticking = false;
      });
    }
    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();

    // Gentle pointer tilt on the TV mockup for devices with a real pointer.
    if (window.matchMedia("(hover: hover) and (pointer: fine)").matches) {
      scene.addEventListener("pointermove", (e) => {
        const rect = scene.getBoundingClientRect();
        const px = (e.clientX - rect.left) / rect.width - 0.5;
        const py = (e.clientY - rect.top) / rect.height - 0.5;
        tv.style.transform += ` rotateX(${(py * -4).toFixed(2)}deg) rotateY(${(px * 6).toFixed(2)}deg)`;
        tv.style.transformStyle = "preserve-3d";
      });
      scene.addEventListener("pointerleave", () => {
        tv.style.transform = tv.style.transform.replace(/rotateX\([^)]*\)\s*rotateY\([^)]*\)/, "");
      });
    }
  }

  /* ---------------- Boot ---------------- */

  document.addEventListener("DOMContentLoaded", () => {
    buildWaveform();
    buildQR();
    initHeroParallax();
  });
})();
