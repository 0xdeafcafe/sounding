export const BPM = 124;
const BEATS = 16;
const SPB = 60 / BPM;

const midi = n => 440 * Math.pow(2, (n - 69) / 12);

function noiseBuffer(ctx, seconds) {
  const b = ctx.createBuffer(1, Math.floor(ctx.sampleRate * seconds), ctx.sampleRate);
  const d = b.getChannelData(0);
  let s = 22222;
  for (let i = 0; i < d.length; i++) { s = (s * 16807) % 2147483647; d[i] = (s / 2147483647) * 2 - 1; }
  return b;
}

function kit(ctx, out, noise) {
  const env = (g, t, a, peak, d) => { g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(peak, t + a); g.gain.exponentialRampToValueAtTime(0.0001, t + a + d); };
  const burst = (t, type, freq, q, peak, d, a = 0.002, off = 0) => {
    const s = ctx.createBufferSource(); s.buffer = noise;
    const f = ctx.createBiquadFilter(); f.type = type; f.frequency.value = freq; f.Q.value = q;
    const g = ctx.createGain(); env(g, t, a, peak, d);
    s.connect(f).connect(g).connect(out); s.start(t, off, a + d + 0.05);
  };
  return {
    kick(t, level = 1, deep = 48) {
      const o = ctx.createOscillator(); const g = ctx.createGain();
      o.frequency.setValueAtTime(165, t); o.frequency.exponentialRampToValueAtTime(deep, t + 0.085);
      g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(level, t + 0.003); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.34);
      o.connect(g).connect(out); o.start(t); o.stop(t + 0.4);
      burst(t, 'highpass', 2400, 0.7, 0.16 * level, 0.012, 0.001);
    },
    hat(t, level = 0.2, d = 0.035) { burst(t, 'highpass', 7800, 0.8, level, d, 0.001, (t * 7.3) % 1); },
    clap(t, level = 0.5) { for (let k = 0; k < 3; k++) burst(t + k * 0.011, 'bandpass', 1500, 1.1, level * 0.7, 0.02, 0.001, k * 0.21); burst(t + 0.03, 'bandpass', 1300, 0.9, level, 0.14, 0.001, 0.5); },
    rim(t, level = 0.3) {
      const o = ctx.createOscillator(); o.type = 'triangle'; o.frequency.value = 1720;
      const g = ctx.createGain(); env(g, t, 0.001, level, 0.03);
      o.connect(g).connect(out); o.start(t); o.stop(t + 0.06);
    },
    shaker(t, level = 0.06) { burst(t, 'bandpass', 5200, 1.4, level, 0.05, 0.012, (t * 3.1) % 1); },
    bass(t, note, d, level = 0.5, bright = 700) {
      const o = ctx.createOscillator(); o.type = 'sawtooth'; o.frequency.value = midi(note);
      const s = ctx.createOscillator(); s.frequency.value = midi(note);
      const f = ctx.createBiquadFilter(); f.type = 'lowpass'; f.Q.value = 5;
      f.frequency.setValueAtTime(bright, t); f.frequency.exponentialRampToValueAtTime(110, t + d);
      const g = ctx.createGain(); env(g, t, 0.004, level, d);
      const sg = ctx.createGain(); env(sg, t, 0.004, level * 0.9, d * 1.1);
      o.connect(f).connect(g).connect(out); s.connect(sg).connect(out);
      o.start(t); o.stop(t + d + 0.05); s.start(t); s.stop(t + d * 1.1 + 0.05);
    },
    keys(t, notes, d = 0.5, level = 0.12) {
      const f = ctx.createBiquadFilter(); f.type = 'lowpass'; f.frequency.setValueAtTime(2600, t); f.frequency.exponentialRampToValueAtTime(700, t + d); f.Q.value = 0.6;
      f.connect(out);
      notes.forEach((n, i) => {
        const o = ctx.createOscillator(); o.type = 'triangle'; o.frequency.value = midi(n);
        const h = ctx.createOscillator(); h.frequency.value = midi(n) * 4; const hg = ctx.createGain(); env(hg, t, 0.002, level * 0.25, 0.09);
        const g = ctx.createGain(); env(g, t + i * 0.004, 0.006, level, d);
        o.connect(g).connect(f); h.connect(hg).connect(f);
        o.start(t); o.stop(t + d + 0.1); h.start(t); h.stop(t + 0.15);
      });
    },
    pad(t, notes, d, level = 0.035) {
      const f = ctx.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = 1100; f.Q.value = 0.4;
      const g = ctx.createGain(); g.gain.setValueAtTime(0.0001, t); g.gain.linearRampToValueAtTime(level, t + d * 0.35); g.gain.linearRampToValueAtTime(level * 0.8, t + d * 0.8); g.gain.linearRampToValueAtTime(0.0001, t + d);
      f.connect(g).connect(out);
      notes.forEach(n => [-6, 7].forEach(c => { const o = ctx.createOscillator(); o.type = 'sawtooth'; o.frequency.value = midi(n); o.detune.value = c; o.connect(f); o.start(t); o.stop(t + d + 0.02); }));
    },
  };
}

const CHORDS = [[57, 60, 64, 67, 71], [53, 57, 60, 64, 67], [60, 64, 67, 71, 62], [52, 55, 59, 62, 66]];
const ROOTS = [33, 29, 36, 28];

async function renderLoop(sr, side) {
  const n = Math.round(BEATS * SPB * sr);
  const ctx = new OfflineAudioContext(1, n * 2, sr);
  const noise = noiseBuffer(ctx, 2);
  const bus = ctx.createGain(); bus.gain.value = side ? 0.82 : 0.9;
  bus.connect(ctx.destination);
  const k = kit(ctx, bus, noise);
  for (let rep = 0; rep < 2; rep++) {
    const T0 = rep * n / sr;
    for (let b = 0; b < BEATS; b++) {
      if (!(b & 3)) await new Promise(r => setTimeout(r));
      const t = T0 + b * SPB, bar = b >> 2, q = b & 3;
      if (!side) {
        k.kick(t, 0.5, 44);
        k.hat(t + SPB / 2, 0.07, 0.05);
        for (let s = 0; s < 4; s++) k.shaker(t + s * SPB / 4 + (s & 1 ? 0.012 : 0), s === 2 ? 0.07 : 0.035);
        if (q === 1 || q === 3) k.rim(t, 0.1);
        if (q === 0) { k.pad(t, CHORDS[bar].slice(0, 4).map(x => x + 12), SPB * 4.2); k.keys(t, CHORDS[bar], 0.9, 0.1); k.bass(t, ROOTS[bar] + 12, 0.5, 0.3, 320); }
        if (q === 1) k.keys(t + SPB / 2, CHORDS[bar], 0.45, 0.085);
        if (q === 2) { k.keys(t + SPB * 0.75, CHORDS[bar].map(x => x + (x > 62 ? 0 : 12)), 0.6, 0.075); k.bass(t + SPB / 2, ROOTS[bar] + 12, 0.36, 0.24, 300); }
        if (q === 3 && bar === 3) [76, 74, 71, 69].forEach((m, i) => k.keys(t + i * SPB / 4, [m], 0.3, 0.07));
      } else {
        k.kick(t, 0.95, 46);
        k.hat(t + SPB / 2, 0.2, 0.16);
        for (let s = 0; s < 4; s++) k.hat(t + s * SPB / 4, s === 0 ? 0.04 : 0.075, 0.022);
        if (q === 1 || q === 3) k.clap(t, 0.42);
        const pat = [0, 12, 0, 7][q];
        k.bass(t + SPB / 4, ROOTS[0] + 12, 0.11, 0.42, 900);
        k.bass(t + SPB / 2, ROOTS[0] + 12 + pat, 0.13, 0.46, 1500);
        k.bass(t + SPB * 0.75, ROOTS[0] + 12 + (q === 3 ? 10 : 0), 0.1, 0.38, 1100);
        if (q === 2 && (bar & 1)) k.rim(t + SPB * 0.75, 0.22);
        if (q === 0 && bar === 2) k.rim(t + SPB / 4, 0.16);
        if (bar === 3 && q === 3) for (let s = 0; s < 4; s++) k.hat(t + s * SPB / 4 + SPB / 8, 0.1, 0.03);
      }
    }
  }
  const buf = await ctx.startRendering();
  return buf.getChannelData(0).slice(n, n * 2);
}

async function renderScratch(sr) {
  const ctx = new OfflineAudioContext(1, sr * 2, sr);
  const mix = ctx.createGain(); mix.gain.value = 0.5; mix.connect(ctx.destination);
  const src = ctx.createGain();
  [[220, 0.5], [330, 0.2], [110, 0.3]].forEach(([f, g]) => { const o = ctx.createOscillator(); o.type = 'sawtooth'; o.frequency.value = f; const og = ctx.createGain(); og.gain.value = g; o.connect(og).connect(src); o.start(0); });
  [[760, 9, 1], [1180, 10, 0.6], [2700, 12, 0.35]].forEach(([f, q, g]) => { const b = ctx.createBiquadFilter(); b.type = 'bandpass'; b.frequency.value = f; b.Q.value = q; const bg = ctx.createGain(); bg.gain.value = g * 3; src.connect(b).connect(bg).connect(mix); });
  const buf = await ctx.startRendering();
  return buf.getChannelData(0).slice(sr, sr * 2);
}

export function createAudio(base) {
  const A = { on: false, ready: false, ctx: null, loopLen: 0, beat: null, level: [0, 0] };
  let ctx, master, decks = [], booting = null, primed = false;
  let want = { rate: [1, 1], masterRate: 1, slip: [0, 0], scratch: [0, 0], knob: [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5], chan: [1, 1], xf: 0 };
  const data = new Float32Array(256);

  async function boot() {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC || !window.AudioWorkletNode) throw new Error('no audio');
    ctx = new AC({ latencyHint: 'interactive' });
    A.ctx = ctx;
    const sr = ctx.sampleRate;
    const [la, lb, sc] = await Promise.all([renderLoop(sr, 0), renderLoop(sr, 1), renderScratch(sr), ctx.audioWorklet.addModule(base + 'deck-worklet.js')]);
    A.loopLen = la.length;
    master = ctx.createGain(); master.gain.value = 0;
    const lim = ctx.createDynamicsCompressor();
    lim.threshold.value = -9; lim.knee.value = 4; lim.ratio.value = 14; lim.attack.value = 0.003; lim.release.value = 0.12;
    master.connect(lim).connect(ctx.destination);
    [la, lb].forEach((loop, i) => {
      const node = new AudioWorkletNode(ctx, 'deck', { numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [1] });
      node.port.postMessage({ loop, scr: sc.slice() });
      const lo = ctx.createBiquadFilter(); lo.type = 'lowshelf'; lo.frequency.value = 190;
      const mid = ctx.createBiquadFilter(); mid.type = 'peaking'; mid.frequency.value = 1000; mid.Q.value = 0.8;
      const hi = ctx.createBiquadFilter(); hi.type = 'highshelf'; hi.frequency.value = 4200;
      const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 20000; lp.Q.value = 1.2;
      const hp = ctx.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 12; hp.Q.value = 1.2;
      const ch = ctx.createGain();
      const an = ctx.createAnalyser(); an.fftSize = 256;
      const xg = ctx.createGain();
      node.connect(lo).connect(mid).connect(hi).connect(lp).connect(hp).connect(ch).connect(xg).connect(master);
      ch.connect(an);
      if (i === 0) node.port.onmessage = e => { A.beat = { ref: e.data.ref, at: e.data.at }; };
      decks.push({ node, lo, mid, hi, lp, hp, ch, an, xg });
    });
    A.ready = true;
    apply(0.001);
  }

  const eq = v => { const x = (v - 0.5) * 2; return x < 0 ? x * 26 : x * 8; };

  function apply(tc = 0.012) {
    if (!A.ready) return;
    const t = ctx.currentTime;
    decks.forEach((d, i) => {
      const p = d.node.parameters;
      p.get('rate').setTargetAtTime(want.rate[i], t, 0.004);
      p.get('master').setTargetAtTime(want.masterRate, t, 0.02);
      p.get('slip').setValueAtTime(want.slip[i], t);
      p.get('scratch').setTargetAtTime(want.scratch[i], t, 0.01);
      d.hi.gain.setTargetAtTime(eq(want.knob[i * 4]), t, tc);
      d.mid.gain.setTargetAtTime(eq(want.knob[i * 4 + 1]), t, tc);
      d.lo.gain.setTargetAtTime(eq(want.knob[i * 4 + 2]), t, tc);
      const f = (want.knob[i * 4 + 3] - 0.5) * 2;
      const dead = Math.abs(f) < 0.04;
      d.lp.frequency.setTargetAtTime(dead || f > 0 ? 20000 : 20000 * Math.pow(0.011, -f), t, tc);
      d.hp.frequency.setTargetAtTime(dead || f < 0 ? 12 : 12 * Math.pow(520, f), t, tc);
      const q = dead ? 0.7 : 0.7 + Math.abs(f) * 4.5;
      d.lp.Q.setTargetAtTime(q, t, tc); d.hp.Q.setTargetAtTime(q, t, tc);
      d.ch.gain.setTargetAtTime(want.chan[i] * want.chan[i], t, tc);
      const x = i ? want.xf : 1 - want.xf;
      d.xg.gain.setTargetAtTime(Math.min(1, Math.sin(x * Math.PI / 2) * 1.22), t, tc);
    });
  }

  A.set = next => { Object.assign(want, next); apply(); };

  A.prime = () => {
    if (primed || booting || !window.Audio) return;
    primed = true;
    const el = new Audio();
    el.muted = true;
    el.src = 'data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAgLsAAAB3AQACABAAZGF0YQAAAAA=';
    const p = el.play();
    if (p) p.catch(() => {});
  };

  A.warm = () => {
    if (booting) return;
    booting = boot();
    booting.catch(() => {});
  };

  A.start = async () => {
    if (!booting) booting = boot();
    await booting;
    if (ctx.state !== 'running') await ctx.resume();
    A.on = true;
    master.gain.cancelScheduledValues(ctx.currentTime);
    master.gain.setTargetAtTime(0.85, ctx.currentTime, 0.05);
  };

  A.stop = () => {
    A.on = false;
    if (!A.ready) return;
    master.gain.cancelScheduledValues(ctx.currentTime);
    master.gain.setTargetAtTime(0, ctx.currentTime, 0.03);
    setTimeout(() => { if (!A.on) ctx.suspend(); }, 260);
  };

  A.sync = samples => { if (A.ready) decks.forEach(d => d.node.port.postMessage({ ref: samples })); };

  A.levels = () => {
    if (!A.ready || !A.on) { A.level[0] *= 0.85; A.level[1] *= 0.85; return A.level; }
    decks.forEach((d, i) => {
      d.an.getFloatTimeDomainData(data);
      let peak = 0;
      for (let k = 0; k < data.length; k++) { const v = Math.abs(data[k]); if (v > peak) peak = v; }
      const v = Math.min(1, Math.pow(peak, 0.6) * 1.15);
      A.level[i] = v > A.level[i] ? v : A.level[i] * 0.9 + v * 0.1;
    });
    return A.level;
  };

  A.thunk = () => {
    if (!A.ready) return;
    const t = ctx.currentTime + 0.01;
    const o = ctx.createOscillator(); o.frequency.setValueAtTime(140, t); o.frequency.exponentialRampToValueAtTime(52, t + 0.07);
    const g = ctx.createGain(); g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(0.5, t + 0.004); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.16);
    const h = ctx.createOscillator(); h.type = 'sawtooth'; h.frequency.value = 50;
    const hg = ctx.createGain(); hg.gain.setValueAtTime(0.0001, t); hg.gain.exponentialRampToValueAtTime(0.09, t + 0.01); hg.gain.exponentialRampToValueAtTime(0.0001, t + 0.11);
    o.connect(g).connect(ctx.destination); h.connect(hg).connect(ctx.destination);
    o.start(t); o.stop(t + 0.2); h.start(t); h.stop(t + 0.14);
  };

  A.drop = () => {
    if (!A.ready) return;
    const t = ctx.currentTime + 0.01;
    const b = ctx.createBuffer(1, 2600, ctx.sampleRate), d = b.getChannelData(0);
    for (let i = 0; i < d.length; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / d.length, 2.6);
    const n = ctx.createBufferSource(); n.buffer = b;
    const f = ctx.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = 1100;
    const g = ctx.createGain(); g.gain.value = 0.42;
    n.connect(f).connect(g).connect(ctx.destination); n.start(t);
  };

  return A;
}
