(function () {
  'use strict';
  const NP = (window.NP = window.NP || {});
  const D = NP.data;

  NP.$ = (s, r = document) => r.querySelector(s);
  NP.$$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  NP.h = (html) => {
    const t = document.createElement('template');
    t.innerHTML = html.trim();
    return t.content.firstElementChild;
  };
  NP.esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  NP.clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  NP.fmt = (s) => {
    s = Math.max(0, Math.floor(s));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    return h ? `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}` : `${m}:${String(sec).padStart(2, '0')}`;
  };
  NP.params = new URLSearchParams(location.search);
  NP.shot = NP.params.get('shot') === '1';
  if (NP.shot) document.documentElement.classList.add('boot');

  const I = {
    play: ['f', 'M7.2 4.9v14.2c0 1 1.1 1.6 1.9 1.1l11-7.1c.8-.5.8-1.7 0-2.2l-11-7.1c-.8-.5-1.9.1-1.9 1.1z'],
    pause: ['f', 'M6.6 4h2.8c.6 0 1.1.5 1.1 1.1v13.8c0 .6-.5 1.1-1.1 1.1H6.6c-.6 0-1.1-.5-1.1-1.1V5.1C5.5 4.5 6 4 6.6 4zm8 0h2.8c.6 0 1.1.5 1.1 1.1v13.8c0 .6-.5 1.1-1.1 1.1h-2.8c-.6 0-1.1-.5-1.1-1.1V5.1c0-.6.5-1.1 1.1-1.1z'],
    next: ['f', 'M2.6 6.6v10.8c0 .9 1 1.4 1.7.9l7.6-5.4c.6-.4.6-1.4 0-1.8L4.3 5.7c-.7-.5-1.7 0-1.7.9zm9.8 0v10.8c0 .9 1 1.4 1.7.9l7.6-5.4c.6-.4.6-1.4 0-1.8l-7.6-5.4c-.7-.5-1.7 0-1.7.9z'],
    prev: ['f', 'M21.4 6.6v10.8c0 .9-1 1.4-1.7.9l-7.6-5.4c-.6-.4-.6-1.4 0-1.8l7.6-5.4c.7-.5 1.7 0 1.7.9zm-9.8 0v10.8c0 .9-1 1.4-1.7.9l-7.6-5.4c-.6-.4-.6-1.4 0-1.8l7.6-5.4c.7-.5 1.7 0 1.7.9z'],
    heart: ['s', 'M12 20.2s-7.6-4.5-9.2-9.1C1.6 7.6 3.7 4.4 7.1 4.4c2 0 3.6 1.1 4.9 2.9 1.3-1.8 2.9-2.9 4.9-2.9 3.4 0 5.5 3.2 4.3 6.7-1.6 4.6-9.2 9.1-9.2 9.1z'],
    heartFill: ['f', 'M12 20.2s-7.6-4.5-9.2-9.1C1.6 7.6 3.7 4.4 7.1 4.4c2 0 3.6 1.1 4.9 2.9 1.3-1.8 2.9-2.9 4.9-2.9 3.4 0 5.5 3.2 4.3 6.7-1.6 4.6-9.2 9.1-9.2 9.1z'],
    more: ['f', 'M5.5 10.3a1.7 1.7 0 1 1 0 3.4 1.7 1.7 0 0 1 0-3.4zm6.5 0a1.7 1.7 0 1 1 0 3.4 1.7 1.7 0 0 1 0-3.4zm6.5 0a1.7 1.7 0 1 1 0 3.4 1.7 1.7 0 0 1 0-3.4z'],
    comments: ['s', 'M12 4C7 4 3.2 7.2 3.2 11.2c0 2.2 1.2 4.2 3.1 5.5-.2 1.3-.8 2.5-1.7 3.4 1.9 0 3.6-.6 4.9-1.7.8.2 1.6.3 2.5.3 5 0 8.8-3.2 8.8-7.5S17 4 12 4z'],
    route: ['s', 'M6.2 17.2a8.2 8.2 0 1 1 11.6 0M8.7 14.6a4.6 4.6 0 1 1 6.6 0', 'M12 14.4l4.4 5.8H7.6z'],
    upnext: ['s', 'M9 6.5h11M9 12h11M9 17.5h11', 'M4.6 5.2a1.3 1.3 0 1 1 0 2.6 1.3 1.3 0 0 1 0-2.6zm0 5.5a1.3 1.3 0 1 1 0 2.6 1.3 1.3 0 0 1 0-2.6zm0 5.5a1.3 1.3 0 1 1 0 2.6 1.3 1.3 0 0 1 0-2.6z'],
    setlist: ['s', 'M3.5 6.5h10M3.5 11h10M3.5 15.5h6', 'M17 5.2v9.6a2.4 2.4 0 1 1-1.4-2.2V6.4l5-1.2v2.4z'],
    shuffle: ['s', 'M3.5 7h3.2c2.3 0 3.6 1.1 4.8 3.2l1 1.6c1.2 2.1 2.5 3.2 4.8 3.2h3.2M3.5 17h3.2c1.4 0 2.4-.4 3.2-1.2M13.3 8.2c.8-.8 1.8-1.2 3.2-1.2h3.2M17.6 4.6L20 7l-2.4 2.4M17.6 14.6L20 17l-2.4 2.4'],
    repeat: ['s', 'M4 11V9.5A2.5 2.5 0 0 1 6.5 7H19M16.5 4.5L19 7l-2.5 2.5M20 13v1.5a2.5 2.5 0 0 1-2.5 2.5H5M7.5 19.5L5 17l2.5-2.5'],
    repeat1: ['s', 'M4 11V9.5A2.5 2.5 0 0 1 6.5 7H19M16.5 4.5L19 7l-2.5 2.5M20 13v1.5a2.5 2.5 0 0 1-2.5 2.5H5M7.5 19.5L5 17l2.5-2.5M11.2 10.6l1.3-.8v4.6'],
    handle: ['s', 'M5 8.5h14M5 12h14M5 15.5h14'],
    identify: ['s', 'M12 3.2a8.8 8.8 0 1 1 0 17.6 8.8 8.8 0 0 1 0-17.6zM8 10.5v3M10.7 8.5v7M13.3 9.5v5M16 11v2'],
    tv: ['s', 'M4.2 5.5h15.6c.7 0 1.2.5 1.2 1.2v9.1c0 .7-.5 1.2-1.2 1.2H4.2c-.7 0-1.2-.5-1.2-1.2V6.7c0-.7.5-1.2 1.2-1.2zM8.5 20h7'],
    iphone: ['s', 'M8.4 2.8h7.2c1 0 1.8.8 1.8 1.8v14.8c0 1-.8 1.8-1.8 1.8H8.4c-1 0-1.8-.8-1.8-1.8V4.6c0-1 .8-1.8 1.8-1.8zM10.8 5.2h2.4'],
    ipad: ['s', 'M5.6 3.4h12.8c1 0 1.8.8 1.8 1.8v13.6c0 1-.8 1.8-1.8 1.8H5.6c-1 0-1.8-.8-1.8-1.8V5.2c0-1 .8-1.8 1.8-1.8zM10.8 17.7h2.4'],
    mac: ['s', 'M5 5.5h14c.6 0 1 .4 1 1V16H4V6.5c0-.6.4-1 1-1zM2 18.2h20'],
    watch: ['s', 'M8.5 6.5h7c1 0 1.8.8 1.8 1.8v7.4c0 1-.8 1.8-1.8 1.8h-7c-1 0-1.8-.8-1.8-1.8V8.3c0-1 .8-1.8 1.8-1.8zM9.5 6.5l.6-3.3h3.8l.6 3.3M9.5 17.5l.6 3.3h3.8l.6-3.3'],
    share: ['s', 'M12 3.5v11M8.2 7.2L12 3.5l3.8 3.7M8 10.5H6.5c-.8 0-1.5.7-1.5 1.5v7c0 .8.7 1.5 1.5 1.5h11c.8 0 1.5-.7 1.5-1.5v-7c0-.8-.7-1.5-1.5-1.5H16'],
    cue: ['s', 'M5.5 21V4M5.5 4.5h11l-2.4 4 2.4 4h-11'],
    automix: ['s', 'M7.3 8.2c-2.1 0-3.8 1.7-3.8 3.8s1.7 3.8 3.8 3.8c3.6 0 5.8-7.6 9.4-7.6 2.1 0 3.8 1.7 3.8 3.8s-1.7 3.8-3.8 3.8c-3.6 0-5.8-7.6-9.4-7.6z'],
    decks: ['s', 'M10 4.5a7.5 7.5 0 1 1 0 15 7.5 7.5 0 0 1 0-15zM20.5 3.5v9.5l-3.2 3.2', 'M10 10.6a1.4 1.4 0 1 1 0 2.8 1.4 1.4 0 0 1 0-2.8z'],
    chevronDown: ['s', 'M6 9.5l6 6 6-6'],
    chevronRight: ['s', 'M9.5 6l6 6-6 6'],
    check: ['s', 'M5 12.5l4.3 4.3L19 7.2'],
    close: ['s', 'M6.5 6.5l11 11M17.5 6.5l-11 11'],
    plus: ['s', 'M12 5v14M5 12h14'],
    search: ['s', 'M10.5 4a6.5 6.5 0 1 1 0 13 6.5 6.5 0 0 1 0-13zM15.4 15.4L20 20'],
    home: ['s', 'M4 10.5L12 4l8 6.5V19c0 .6-.4 1-1 1h-4.5v-5.5h-5V20H5c-.6 0-1-.4-1-1z'],
    library: ['s', 'M5 4v16M9.5 4v16M14 5l4.8 14.6'],
    gear: ['s', 'M12 9a3 3 0 1 1 0 6 3 3 0 0 1 0-6zM12 2.8v2.6M12 18.6v2.6M21.2 12h-2.6M5.4 12H2.8M18.5 5.5l-1.8 1.8M7.3 16.7l-1.8 1.8M18.5 18.5l-1.8-1.8M7.3 7.3L5.5 5.5'],
    info: ['s', 'M12 3.2a8.8 8.8 0 1 1 0 17.6 8.8 8.8 0 0 1 0-17.6zM12 11v5.5', 'M12 7a1.2 1.2 0 1 1 0 2.4A1.2 1.2 0 0 1 12 7z'],
    volLow: ['f', 'M3.5 9.3h3l4.1-3.6c.5-.4 1.2-.1 1.2.6v11.4c0 .7-.7 1-1.2.6l-4.1-3.6h-3c-.6 0-1-.4-1-1V10.3c0-.6.4-1 1-1z'],
    volHigh: ['f', 'M3.5 9.3h3l4.1-3.6c.5-.4 1.2-.1 1.2.6v11.4c0 .7-.7 1-1.2.6l-4.1-3.6h-3c-.6 0-1-.4-1-1V10.3c0-.6.4-1 1-1z', 'M14.5 9.2c.8.8 1.2 1.7 1.2 2.8s-.4 2-1.2 2.8M17.1 6.8c1.4 1.4 2.2 3.2 2.2 5.2s-.8 3.8-2.2 5.2M19.6 4.4c2 2 3.1 4.7 3.1 7.6s-1.1 5.6-3.1 7.6'],
    send: ['f', 'M12 2.8a9.2 9.2 0 1 1 0 18.4 9.2 9.2 0 0 1 0-18.4zm0 4.5c-.3 0-.5.1-.7.3l-3.6 3.6a1 1 0 1 0 1.4 1.4L11 10.7V16a1 1 0 1 0 2 0v-5.3l1.9 1.9a1 1 0 1 0 1.4-1.4l-3.6-3.6c-.2-.2-.4-.3-.7-.3z'],
    playlist: ['s', 'M4 6.5h11M4 11h11M4 15.5h7', 'M18.5 9.5v7.3a2.2 2.2 0 1 1-1.4-2V9.5z'],
    person: ['s', 'M12 4a3.8 3.8 0 1 1 0 7.6A3.8 3.8 0 0 1 12 4zM4.5 20c.8-3.6 3.8-5.6 7.5-5.6s6.7 2 7.5 5.6'],
    download: ['s', 'M12 4v11M7.5 10.8L12 15.3l4.5-4.5M5 19.5h14'],
    expand: ['s', 'M14 4.5h5.5V10M10 19.5H4.5V14M19.5 4.5L13.5 10.5M4.5 19.5l6-6'],
    collapse: ['s', 'M19.5 10H14V4.5M4.5 14H10v5.5M14 10l5.8-5.8M10 14l-5.8 5.8'],
    sidebar: ['s', 'M4.5 5h15c.8 0 1.5.7 1.5 1.5v11c0 .8-.7 1.5-1.5 1.5h-15c-.8 0-1.5-.7-1.5-1.5v-11C3 5.7 3.7 5 4.5 5zM9 5v14'],
    note: ['f', 'M18 3.6v11.6a3 3 0 1 1-1.8-2.8V8.1l-7.4 1.8v7.3a3 3 0 1 1-1.8-2.8V6.4c0-.5.3-.9.8-1l9-2.2c.6-.1 1.2.3 1.2.9z'],
    speakerNow: ['f', 'M3.5 9.3h3l4.1-3.6c.5-.4 1.2-.1 1.2.6v11.4c0 .7-.7 1-1.2.6l-4.1-3.6h-3c-.6 0-1-.4-1-1V10.3c0-.6.4-1 1-1z', 'M15 9c.8.8 1.2 1.9 1.2 3s-.4 2.2-1.2 3M17.8 6.5c1.4 1.5 2.2 3.4 2.2 5.5s-.8 4-2.2 5.5'],
    sparkle: ['f', 'M12 3c.4 3.9 2.1 5.6 6 6-3.9.4-5.6 2.1-6 6-.4-3.9-2.1-5.6-6-6 3.9-.4 5.6-2.1 6-6zM18.5 14c.2 1.8 1 2.6 2.8 2.8-1.8.2-2.6 1-2.8 2.8-.2-1.8-1-2.6-2.8-2.8 1.8-.2 2.6-1 2.8-2.8z'],
    link: ['s', 'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1'],
    message: ['f', 'M12 3.5c5.2 0 9.4 3.5 9.4 7.8s-4.2 7.8-9.4 7.8c-1 0-1.9-.1-2.8-.4-1.4 1.1-3.2 1.8-5 1.8.9-1 1.5-2.2 1.7-3.4-2-1.4-3.3-3.5-3.3-5.8 0-4.3 4.2-7.8 9.4-7.8z'],
    mail: ['s', 'M4.5 6h15c.8 0 1.5.7 1.5 1.5v9c0 .8-.7 1.5-1.5 1.5h-15c-.8 0-1.5-.7-1.5-1.5v-9C3 6.7 3.7 6 4.5 6zM3.5 7l8.5 6.5L20.5 7'],
  };
  NP.icon = (name, cls = '') => {
    const d = I[name];
    if (!d) return '';
    const [mode, a, b] = d;
    const p1 = mode === 'f'
      ? `<path d="${a}" fill="currentColor"/>`
      : `<path d="${a}" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>`;
    const p2 = b ? (!/[zZ]\s*$/.test(b) ? `<path d="${b}" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>` : `<path d="${b}" fill="currentColor"/>`) : '';
    return `<svg class="ic ${cls}" viewBox="0 0 24 24" aria-hidden="true">${p1}${p2}</svg>`;
  };

  function springCurve(response, damping) {
    const k = Math.pow((2 * Math.PI) / response, 2);
    const c = (4 * Math.PI * damping) / response;
    let x = 0;
    let v = 0;
    let t = 0;
    const dt = 1 / 240;
    const pts = [0];
    while (t < 3) {
      const a = -k * (x - 1) - c * v;
      v += a * dt;
      x += v * dt;
      t += dt;
      pts.push(x);
      if (t > 0.08 && Math.abs(x - 1) < 0.002 && Math.abs(v) < 0.02) break;
    }
    const n = Math.min(56, pts.length);
    const s = [];
    for (let i = 0; i < n; i++) s.push(+pts[Math.round((i * (pts.length - 1)) / (n - 1))].toFixed(4));
    s[n - 1] = 1;
    return { ease: `linear(${s.join(', ')})`, ms: Math.round(t * 1000) };
  }
  NP.springCurve = springCurve;
  const supportsLinear = CSS.supports('transition-timing-function', 'linear(0, 1)');
  const springs = { spring: [0.5, 0.86], bouncy: [0.46, 0.7], soft: [0.75, 1], snappy: [0.32, 0.92] };
  const rootStyle = document.documentElement.style;
  Object.entries(springs).forEach(([name, [r, d]]) => {
    const c = springCurve(r, d);
    rootStyle.setProperty(`--${name}`, supportsLinear ? c.ease : 'cubic-bezier(.2,.9,.25,1)');
    rootStyle.setProperty(`--${name}-ms`, c.ms + 'ms');
  });

  NP.animate = (from, to, onUpdate, { response = 0.42, damping = 0.82, onDone } = {}) => {
    const k = Math.pow((2 * Math.PI) / response, 2);
    const c = (4 * Math.PI * damping) / response;
    let x = 0;
    let v = 0;
    let last = performance.now();
    let raf;
    const step = (now) => {
      const dt = Math.min(0.032, (now - last) / 1000);
      last = now;
      for (let i = 0; i < 4; i++) {
        const a = -k * (x - 1) - c * v;
        v += (a * dt) / 4;
        x += (v * dt) / 4;
      }
      const done = Math.abs(x - 1) < 0.001 && Math.abs(v) < 0.01;
      onUpdate(done ? 1 : x, from, to);
      if (done) {
        if (onDone) onDone();
      } else raf = requestAnimationFrame(step);
    };
    if (NP.reduceMotion) {
      onUpdate(1, from, to);
      if (onDone) onDone();
      return () => {};
    }
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  };

  class Player {
    constructor() {
      this.l = {};
      this.queue = D.queue.slice();
      this.playNext = new Set(D.playNext);
      this.index = 0;
      this.base = 0;
      this.baseT = performance.now();
      this.playing = true;
      this.speed = 1;
      this.self = 'iphone';
      this.output = 'iphone';
      this.volume = 0.72;
      this.shuffle = false;
      this.repeat = 'off';
      this.automix = true;
      this.liked = new Set(['paper']);
      this.lastPos = 0;
      this.seg = -1;
    }
    on(type, fn) {
      (this.l[type] = this.l[type] || []).push(fn);
      return () => (this.l[type] = this.l[type].filter((f) => f !== fn));
    }
    emit(type, d) {
      (this.l[type] || []).forEach((f) => f(d));
      (this.l['*'] || []).forEach((f) => f(type, d));
    }
    get track() {
      return D.byId[this.queue[this.index]];
    }
    pos(now = performance.now()) {
      const p = this.playing ? this.base + ((now - this.baseT) / 1000) * this.speed : this.base;
      return Math.min(p, this.track.duration);
    }
    rebase() {
      const now = performance.now();
      this.base = this.pos(now);
      this.baseT = now;
    }
    play() {
      if (this.playing) return;
      this.baseT = performance.now();
      this.playing = true;
      this.emit('playstate', true);
    }
    pause() {
      if (!this.playing) return;
      this.rebase();
      this.playing = false;
      this.emit('playstate', false);
    }
    toggle() {
      this.playing ? this.pause() : this.play();
    }
    seek(t) {
      this.base = NP.clamp(t, 0, this.track.duration - 0.5);
      this.baseT = performance.now();
      this.lastPos = this.base;
      this.emit('seek', this.base);
      this.updateSeg(this.base, true);
    }
    setIndex(i, dir = 1) {
      const n = this.queue.length;
      this.index = ((i % n) + n) % n;
      this.playNext.delete(this.queue[this.index]);
      this.base = 0;
      this.baseT = performance.now();
      this.lastPos = 0;
      this.emit('track', { track: this.track, dir });
      this.updateSeg(0, true);
    }
    next() {
      this.setIndex(this.index + 1, 1);
    }
    prev() {
      if (this.pos() > 3) this.seek(0);
      else this.setIndex(this.index - 1, -1);
    }
    playId(id) {
      const i = this.queue.indexOf(id);
      if (i >= 0) this.setIndex(i, i > this.index ? 1 : -1);
      this.play();
    }
    neighbour(d) {
      const n = this.queue.length;
      return D.byId[this.queue[(((this.index + d) % n) + n) % n]];
    }
    upcoming() {
      return this.queue.slice(this.index + 1).map((id) => D.byId[id]);
    }
    move(fromId, toId) {
      const q = this.queue;
      const a = q.indexOf(fromId);
      const b = q.indexOf(toId);
      if (a < 0 || b < 0 || a === b) return;
      q.splice(a, 1);
      q.splice(b, 0, fromId);
      this.emit('queue');
    }
    toggleShuffle() {
      this.shuffle = !this.shuffle;
      const head = this.queue.slice(0, this.index + 1);
      const rest = this.queue.slice(this.index + 1);
      const pinned = rest.filter((id) => this.playNext.has(id));
      let others = rest.filter((id) => !this.playNext.has(id));
      if (this.shuffle) {
        const r = NP.rng(Date.now() & 0xffff);
        for (let i = others.length - 1; i > 0; i--) {
          const j = Math.floor(r() * (i + 1));
          [others[i], others[j]] = [others[j], others[i]];
        }
      } else {
        others = D.queue.filter((id) => others.includes(id));
      }
      this.queue = head.concat(pinned, others);
      this.emit('queue');
    }
    cycleRepeat() {
      this.repeat = { off: 'all', all: 'one', one: 'off' }[this.repeat];
      this.emit('queue');
    }
    setSpeed(s) {
      this.rebase();
      this.speed = s;
      this.emit('speed', s);
    }
    setOutput(o) {
      if (o === this.output) return;
      this.output = o;
      this.emit('output', o);
    }
    setVolume(v) {
      this.volume = NP.clamp(v, 0, 1);
      this.emit('volume', this.volume);
    }
    toggleLike(id = this.track.id) {
      this.liked.has(id) ? this.liked.delete(id) : this.liked.add(id);
      this.emit('like', id);
    }
    setAutomix(v) {
      this.automix = v;
      this.emit('automix', v);
    }
    addComment(text) {
      const t = this.track;
      const c = { id: t.id + '-u' + Date.now(), t: Math.max(0, Math.floor(this.pos())), user: 'You', text, mine: true };
      t.comments.push(c);
      t.comments.sort((a, b) => a.t - b.t);
      this.emit('comments', c);
      return c;
    }
    updateSeg(p, force) {
      const sl = this.track.setlist;
      let i = -1;
      if (sl) for (let k = 0; k < sl.length; k++) if (sl[k].t <= p) i = k;
      if (i !== this.seg || force) {
        this.seg = i;
        this.emit('segment', i);
      }
    }
    tick(now) {
      const t = this.track;
      const p = this.pos(now);
      if (this.playing) {
        if (p > this.lastPos && p - this.lastPos < 2 * this.speed + 1) {
          for (const c of t.comments) if (c.t > this.lastPos && c.t <= p && !c.mine) this.emit('comment', c);
        }
        this.updateSeg(p);
        if (p >= t.duration) {
          if (this.repeat === 'one') this.seek(0);
          else this.next();
          return 0;
        }
      }
      this.lastPos = p;
      return p;
    }
  }
  NP.Player = Player;
  NP.player = new Player();

  const subs = new Set();
  NP.onFrame = (fn) => {
    subs.add(fn);
    return () => subs.delete(fn);
  };
  let started = false;
  NP.start = () => {
    if (started) return;
    started = true;
    const loop = (now) => {
      const p = NP.player.tick(now);
      subs.forEach((f) => f(p, now));
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  };

  NP.settings = { theme: NP.params.get('theme') || 'auto', motion: NP.params.get('motion') || 'auto' };
  const mqDark = matchMedia('(prefers-color-scheme: dark)');
  const mqReduce = matchMedia('(prefers-reduced-motion: reduce)');
  const settingsSubs = new Set();
  NP.onSettings = (fn) => settingsSubs.add(fn);
  NP.applySettings = () => {
    const s = NP.settings;
    const theme = s.theme === 'auto' ? (mqDark.matches ? 'dark' : 'light') : s.theme;
    document.documentElement.dataset.theme = theme;
    NP.theme = theme;
    NP.reduceMotion = s.motion === 'reduce' || (s.motion === 'auto' && mqReduce.matches);
    document.documentElement.dataset.motion = NP.reduceMotion ? 'reduce' : 'full';
    settingsSubs.forEach((f) => f(s));
  };
  mqDark.addEventListener('change', NP.applySettings);
  mqReduce.addEventListener('change', NP.applySettings);
  NP.applySettings();

  NP.applyPalette = (el, track) => {
    const p = track.palette;
    el.style.setProperty('--p-base', p.base);
    el.style.setProperty('--p-1', p.c1);
    el.style.setProperty('--p-2', p.c2);
    el.style.setProperty('--p-3', p.c3);
    el.style.setProperty('--p-tint-dark', p.tintDark);
    el.style.setProperty('--p-tint-light', p.tintLight);
    el.style.setProperty('--p-glass', p.glass);
  };

  NP.deviceName = (id, self) => {
    const d = D.devices.find((x) => x.id === id);
    if (id === self) return 'This ' + ({ mac: 'Mac', tv: 'Apple TV', iphone: 'iPhone', ipad: 'iPad' }[d.kind] || d.name);
    return d.name;
  };

  NP.initFromParams = (self) => {
    const P = NP.player;
    const q = NP.params;
    P.self = self;
    P.output = q.get('output') || self;
    const tid = q.get('track') || 'lowtide';
    const idx = Math.max(0, P.queue.indexOf(tid));
    P.index = idx;
    P.queue = P.queue.slice(idx).concat(P.queue.slice(0, idx));
    P.index = 0;
    const startDefault = { lowtide: 1020, paper: 52, north: 80, sodium: 70 }[tid] || 20;
    P.base = q.has('pos') ? +q.get('pos') : startDefault;
    P.baseT = performance.now();
    P.lastPos = P.base;
    P.playing = q.get('paused') !== '1';
    if (q.has('speed')) P.speed = +q.get('speed');
    if (q.get('liked') === '1') P.liked.add(P.track.id);
    P.updateSeg(P.base, true);
  };

  NP.stage = (device, w, h, { pad = 40, max = 1 } = {}) => {
    const wrap = device.parentElement;
    const fit = () => {
      const panel = NP.shot ? 0 : 300;
      const aw = innerWidth - panel - pad * 2;
      const ah = innerHeight - pad * 2;
      const s = NP.shot ? Math.min(innerWidth / w, innerHeight / h) : Math.min(aw / w, ah / h, max);
      NP.stageScale = s;
      device.style.transform = `scale(${s})`;
      wrap.style.width = w * s + 'px';
      wrap.style.height = h * s + 'px';
    };
    fit();
    addEventListener('resize', fit);
  };

  NP.panel = (cfg) => {
    if (NP.shot) return { refresh() {} };
    const P = NP.player;
    const el = NP.h(`<aside class="ctl"><div class="ctl-head"><a href="index.html" class="ctl-back">‹ Devices</a><div class="ctl-title">${NP.esc(cfg.title)}</div></div><div class="ctl-body"></div><div class="ctl-foot">Space play/pause · ← → skip${cfg.footer ? ' · ' + cfg.footer : ''}</div></aside>`);
    const body = el.querySelector('.ctl-body');
    const refreshers = [];
    const sections = [
      {
        label: 'Track', type: 'tracks',
      },
      ...(cfg.sections || []),
      {
        label: 'Output', type: 'seg', options: D.devices.map((d) => [d.id, d.id === P.self ? 'This' : d.kind === 'tv' ? 'TV' : d.name.split(' ')[0]]),
        get: () => P.output, set: (v) => P.setOutput(v),
      },
      { label: 'Appearance', type: 'seg', options: [['auto', 'Auto'], ['light', 'Light'], ['dark', 'Dark']], get: () => NP.settings.theme, set: (v) => { NP.settings.theme = v; NP.applySettings(); } },
      { label: 'Reduce Motion', type: 'toggle', get: () => NP.reduceMotion, set: (v) => { NP.settings.motion = v ? 'reduce' : 'full'; NP.applySettings(); } },
      { label: 'Playback', type: 'seg', options: [['1', '1×'], ['8', '8×'], ['30', '30×']], get: () => String(P.speed), set: (v) => P.setSpeed(+v) },
    ];
    sections.forEach((s) => {
      const sec = NP.h(`<div class="ctl-sec"><div class="ctl-label">${NP.esc(s.label)}</div></div>`);
      if (s.type === 'tracks') {
        const row = NP.h('<div class="ctl-tracks"></div>');
        D.heroes.forEach((id) => {
          const t = D.byId[id];
          const b = NP.h(`<button class="ctl-track" title="${NP.esc(t.title)}"><img src="${t.artURL}" alt=""><span>${NP.esc(t.kind === 'mix' ? 'DJ set' : t.title)}</span></button>`);
          b.onclick = () => P.playId(id);
          row.appendChild(b);
          refreshers.push(() => b.classList.toggle('on', P.track.id === id));
        });
        sec.appendChild(row);
        const pp = NP.h('<button class="ctl-btn wide"></button>');
        pp.onclick = () => P.toggle();
        refreshers.push(() => (pp.textContent = P.playing ? 'Pause' : 'Play'));
        sec.appendChild(pp);
      } else if (s.type === 'seg') {
        const row = NP.h('<div class="ctl-seg"></div>');
        s.options.forEach(([v, l]) => {
          const b = NP.h(`<button>${NP.esc(l)}</button>`);
          b.onclick = () => { s.set(v); refresh(); };
          row.appendChild(b);
          refreshers.push(() => b.classList.toggle('on', s.get() === v));
        });
        sec.appendChild(row);
      } else if (s.type === 'toggle') {
        const b = NP.h('<button class="ctl-switch"><i></i></button>');
        b.onclick = () => { s.set(!s.get()); refresh(); };
        sec.querySelector('.ctl-label').appendChild(b);
        sec.classList.add('inline');
        refreshers.push(() => b.classList.toggle('on', !!s.get()));
      } else if (s.type === 'buttons') {
        const row = NP.h('<div class="ctl-grid"></div>');
        s.items.forEach(([l, fn, isOn]) => {
          const b = NP.h(`<button class="ctl-btn">${NP.esc(l)}</button>`);
          b.onclick = () => { fn(); refresh(); };
          row.appendChild(b);
          if (isOn) refreshers.push(() => b.classList.toggle('on', !!isOn()));
        });
        sec.appendChild(row);
      }
      body.appendChild(sec);
    });
    document.body.appendChild(el);
    const refresh = () => refreshers.forEach((f) => f());
    P.on('*', refresh);
    NP.onSettings(refresh);
    refresh();
    return { refresh, el };
  };

  NP.keys = (extra = {}) => {
    addEventListener('keydown', (e) => {
      if (e.target.closest && e.target.closest('input, textarea')) return;
      if (extra[e.key] && extra[e.key](e) !== false) return;
      if (e.key === ' ') { e.preventDefault(); NP.player.toggle(); }
      else if (e.key === 'ArrowRight' && !extra.noArrows) NP.player.next();
      else if (e.key === 'ArrowLeft' && !extra.noArrows) NP.player.prev();
    });
  };

  NP.avatar = (name, cls = '') => {
    const hue = NP.personHue(name);
    const initial = name === 'You' ? D.me.initial : name.replace(/[^A-Za-zÀ-ž]/g, '').charAt(0).toUpperCase();
    return `<span class="avatar ${cls}" style="--h:${hue}">${NP.esc(initial)}</span>`;
  };
})();
