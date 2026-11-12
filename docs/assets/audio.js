export const BPM = 124;

const CHORDS = {
  main: [[57, 60, 64, 67, 71], [53, 57, 60, 64, 67], [55, 59, 60, 64, 67], [55, 59, 62, 64, 69]],
  alt: [[50, 53, 57, 60, 64], [52, 55, 59, 62, 64], [53, 57, 60, 64, 67], [55, 59, 62, 67, 69]],
};
const ROOTS = { main: [33, 29, 36, 31], alt: [38, 40, 29, 31] };

const DRUMS = {
  kick: { four: 'x...x...x...x...', push: 'x...x...x...x.x.', off: 'x...x.....x...x.' },
  hat: { off8: '..x...x...x...x.', six: 'o-x-o-x-o-x-o-x-', sixb: '-ox--ox--ox--ox-', sparse: '..x.......x.....' },
  ohat: { oh: '..x...x...x...x.', oh2: '......x.......x.' },
  ride: { rd: 'x.o.x.o.x.o.x.o.', rd2: '..x...x...x...x.' },
  clap: { two4: '....x.......x...', two4b: '....x......-x...', late: '....x.......x..-' },
  rim: { r1: '...x..x....x..x.', r2: '.x...x...x.x...x', r3: '......x.......x.' },
  shaker: { sh: 'o-x-o-x-o-x-o-x-', sh2: '-xo--xo--xo--xo-', sh3: 'x-o-x-o-x-o-x-o-' },
  perc: { c1: '..x..x.x...x..x.', c2: '.x..x..x.x..x..x', c3: '...x...x..x...x.' },
};

const SONG_A = {
  seed: 101, bpm: BPM, swing: 0.11, bassOct: 12,
  chords: CHORDS, roots: ROOTS,
  fills: ['hatroll', 'kickpush', 'bassrun', 'claproll', 'percburst', 'none', 'none'],
  pat: {
    ...DRUMS,
    bass: {
      r8: [[0, 0, 2, 1], [2, 0, 2], [4, 0, 2], [6, 0, 2], [8, 0, 2, 1], [10, 0, 2], [12, 0, 2], [14, 0, 2]],
      off: [[2, 0, 2], [6, 0, 2], [10, 0, 2, 1], [14, 0, 2]],
      long: [[0, 0, 6, 1], [8, 0, 4], [12, 12, 2]],
      walk: [[0, 0, 2, 1], [2, 0, 2], [4, 0, 2], [6, 7, 2], [8, 0, 2, 1], [10, 0, 2], [12, 12, 2], [14, 10, 2]],
      bump: [[2, 0, 2], [6, 0, 1], [7, 0, 1], [10, 0, 2, 1], [13, 7, 1], [14, 0, 1]],
    },
    stab: { sd: ['..X.............', '..........X.....'] },
    keys: { k1: ['x.....x.....x...', 'x.....x...x.....'], k2: ['..x.....x.......', '..x.....x.....x.'], k3: ['x.......x.......', 'x.......x...x...'] },
    arp: { a16: 'x-x-x-x-x-x-x-x-', a16b: '-x-x-x-x-x-x-x-x', a8: 'x.x.x.x.x.x.x.x.', a8b: 'x..x..x.x..x..x.' },
    lead: {
      m1: [[0, 76, 3], [4, 74, 2], [6, 72, 2], [8, 69, 4], [16, 72, 3], [20, 74, 2], [22, 76, 2], [24, 79, 6]],
      m2: [[0, 81, 2], [2, 79, 2], [4, 76, 4], [10, 74, 2], [12, 72, 4], [16, 74, 2], [18, 76, 2], [20, 79, 4], [26, 76, 2], [28, 74, 4]],
      m3: [[0, 72, 2], [2, 76, 2], [4, 79, 4], [8, 76, 2], [10, 74, 2], [12, 72, 4], [16, 69, 6], [24, 72, 2], [26, 74, 2], [28, 76, 4]],
    },
  },
  kit: {
    kick: { pitch: 150, deep: 48, glide: 14, decay: 290, click: 0.04, sat: 1.1, level: 0.58 },
    rumble: { decay: 300, lp: 120, freq: 42, level: 0.2 },
    hat: { decay: 28, tail: 0.25, hp: 5500, lp: 15000, metal: 0, level: 0.2 },
    ohat: { decay: 140, tail: 0.5, hp: 6000, lp: 14000, metal: 0, level: 0.16 },
    ride: { decay: 160, tail: 0.6, hp: 5000, lp: 13000, metal: 1, level: 0.12 },
    shaker: { decay: 35, tail: 0.2, hp: 4500, lp: 12000, metal: 0, level: 0.12 },
    clap: { freq: 1300, decay: 110, level: 0.3 },
    rim: { freq: 1700, decay: 20, ndecay: 12, tone: 0.6, level: 0.16 },
    perc: { freq: 210, decay: 70, ndecay: 8, tone: 0.9, level: 0.22 },
    bell: { decay: 900, level: 0.05 },
    bass: { cut: 700, cutEnd: 220, cdecay: 160, rel: 14, sub: 0.35, drive: 1.6, res: 1.1, level: 0.3, square: 0, accentAmt: 0 },
    stab: { det: 8, cut: 2200, cutEnd: 500, cdecay: 160, attack: 0.004, rel: 90, res: 0.9, wave: 'saw', drive: 1.2, level: 0.24, send: 0.5 },
    keys: { det: 4, cut: 3800, cutEnd: 1000, cdecay: 350, attack: 0.003, rel: 250, res: 0.7, wave: 'tri', drive: 1, level: 0.32, send: 0.4 },
    arp: { det: 5, cut: 2200, cutEnd: 600, cdecay: 120, attack: 0.002, rel: 40, res: 0.9, wave: 'saw', drive: 1, level: 0.17 },
    lead: { det: 6, cut: 2600, cutEnd: 1200, cdecay: 300, attack: 0.01, rel: 140, res: 0.8, wave: 'tri', drive: 1, level: 0.25 },
    pad: { det: 9, cut: 900, cutEnd: 900, cdecay: 1000, attack: 0.9, rel: 900, res: 0.6, lfo: 0.06, lfoAmt: 0.35, wave: 'saw', drive: 1, level: 0.13, drop: 0 },
    riser: { from: 300, to: 7000, level: 0.09 },
    impact: { decay: 900, lp: 5000, boom: 500, level: 0.3 },
  },
  fx: { decay: 0.62, damp: 0.45, delaySteps: 3, feedback: 0.42, delayLevel: 0.5, revLevel: 0.5, duck: 0.35, thr: 0.5, ratio: 2.5, makeup: 1.12, stabSend: 0.5, percSend: 0.25, arpSend: 0.45, leadSend: 0.6, percRev: 0.3, stabRev: 0.3, padRev: 0.25, hatRev: 0.04, kickRev: 0, arpRev: 0.3, leadRev: 0.5 },
  sections: [
    { name: 'intro', bars: 8, kick: 'four', shaker: 'sh', pad: 0.7, arp: 'a8', lp: [500, 4000], pings: 0.25 },
    { name: 'rise', bars: 8, kick: 'four', hat: 'off8', shaker: 'sh', bass: 'off', arp: 'a16', keys: 'k3', pad: 0.8, lp: [4000, 14000], pings: 0.2 },
    { name: 'groove', bars: 16, kick: 'four', hat: ['off8', 'six'], shaker: ['sh', 'sh2'], clap: 'two4', rim: ['r3', 0], bass: ['r8', 'off', 'walk'], arp: ['a16', 'a8'], keys: ['k1', 'k2'], pad: 0.7, pings: 0.15 },
    { name: 'break', bars: 8, shaker: 'sh2', bass: 'long', pad: 1, prog: 'alt', keys: 'k2', lead: 'm1', riser: 4, hp: [20, 180], pings: 0.4, fills: ['snareroll', 'claproll'] },
    { name: 'drop', bars: 16, impact: true, kick: 'four', hat: 'six', ohat: 'oh2', clap: 'two4', shaker: 'sh', perc: ['c1', 0], bass: ['r8', 'walk'], arp: 'a16', keys: 'k1', lead: ['m1', 'm2'], pad: 0.6, pings: 0.1 },
    { name: 'groove2', bars: 16, kick: 'four', hat: 'off8', shaker: 'sh', clap: ['two4', 0], rim: 'r1', bass: ['off', 'r8', 'bump'], arp: ['a8', 'a8b', 0], keys: 'k2', pad: 0.7, pings: 0.2 },
    { name: 'break2', bars: 8, kick: 'four', shaker: 'sh', bass: 'long', pad: 1, prog: 'alt', lead: 'm2', arp: 'a16', riser: 4, lp: [12000, 450], pings: 0.4, fills: ['snareroll'] },
    { name: 'drop2', bars: 16, impact: true, kick: 'four', hat: ['six', 'sixb'], ohat: 'oh', clap: 'two4b', shaker: 'sh', perc: ['c1', 'c3'], ride: [0, 'rd2'], bass: ['walk', 'r8'], arp: 'a16', keys: 'k1', lead: ['m2', 'm3', 'm1'], pad: 0.6, pings: 0.1 },
    { name: 'outro', bars: 4, kick: 'four', shaker: 'sh', pad: 0.7, arp: 'a8', lp: [14000, 600] },
  ],
};

const SONG_B = {
  seed: 202, bpm: BPM, swing: 0.07, bassOct: 12,
  chords: CHORDS, roots: ROOTS,
  acidNotes: [0, 0, 0, 0, 12, 12, 3, 7, 10, -2, -5],
  fills: ['hatroll', 'snareroll', 'kickpush', 'claproll', 'none', 'percburst'],
  pat: {
    ...DRUMS,
    bass: {},
    stab: { t1: ['..x..x.....x....', '..x..x.....x..x.'], t2: ['.x.....x..x.....', '.x.....x..x...x.'], sd: ['..X.............', '..........X.....'] },
    keys: {}, arp: {}, lead: {},
  },
  kit: {
    kick: { pitch: 190, deep: 52, glide: 10, decay: 230, click: 0.12, sat: 1.5, level: 0.64 },
    rumble: { decay: 320, lp: 130, freq: 44, level: 0.16 },
    hat: { decay: 22, tail: 0.2, hp: 6500, lp: 16000, metal: 1, level: 0.21 },
    ohat: { decay: 200, tail: 0.7, hp: 6000, lp: 15000, metal: 1, level: 0.18 },
    ride: { decay: 180, tail: 0.6, hp: 5000, lp: 13000, metal: 1, level: 0.14 },
    shaker: { decay: 30, tail: 0.2, hp: 4500, lp: 12000, metal: 0, level: 0.1 },
    clap: { freq: 1500, decay: 130, level: 0.34 },
    rim: { freq: 1800, decay: 15, ndecay: 10, tone: 0.5, level: 0.18 },
    perc: { freq: 160, decay: 120, ndecay: 6, tone: 1, level: 0.24 },
    bell: { decay: 700, level: 0.04 },
    bass: { cut: 600, cutEnd: 170, cdecay: 180, rel: 8, sub: 0.1, drive: 2.2, res: 4.5, level: 0.34, square: 0, accentAmt: 1.2 },
    stab: { det: 12, cut: 1400, cutEnd: 400, cdecay: 80, attack: 0.003, rel: 60, res: 1.2, wave: 'sq', drive: 1.5, level: 0.26, send: 0.55 },
    keys: { det: 4, cut: 3000, cutEnd: 900, cdecay: 300, attack: 0.003, rel: 200, res: 0.7, wave: 'tri', drive: 1, level: 0.2, send: 0.4 },
    arp: { det: 5, cut: 1800, cutEnd: 500, cdecay: 120, attack: 0.002, rel: 40, res: 0.9, wave: 'saw', drive: 1, level: 0.1 },
    lead: { det: 6, cut: 2400, cutEnd: 1100, cdecay: 300, attack: 0.01, rel: 140, res: 0.8, wave: 'tri', drive: 1, level: 0.15 },
    pad: { det: 10, cut: 600, cutEnd: 600, cdecay: 1000, attack: 1.2, rel: 1500, res: 0.6, lfo: 0.05, lfoAmt: 0.5, wave: 'saw', drive: 1, level: 0.12, drop: 1 },
    riser: { from: 250, to: 8000, level: 0.1 },
    impact: { decay: 700, lp: 6000, boom: 450, level: 0.32 },
  },
  fx: { decay: 0.5, damp: 0.5, delaySteps: 3, feedback: 0.35, delayLevel: 0.4, revLevel: 0.35, duck: 0.45, thr: 0.5, ratio: 2.5, makeup: 1.18, stabSend: 0.55, percSend: 0.3, arpSend: 0, leadSend: 0, percRev: 0.3, stabRev: 0.3, padRev: 0.3, hatRev: 0.03, kickRev: 0, arpRev: 0, leadRev: 0 },
  sections: [
    { name: 'intro', bars: 4, kick: 'four', rumble: 0.6, shaker: 'sh', pad: 0.5, lp: [1000, 3000] },
    { name: 'intro2', bars: 4, kick: 'four', rumble: 0.6, hat: 'off8', shaker: 'sh', pad: 0.5, acid: [0.2, 0.35, 'up'], lp: [3000, 12000] },
    { name: 'groove', bars: 16, kick: 'four', rumble: 0.5, hat: ['off8', 'sparse'], ohat: 'oh2', clap: ['two4', 'late'], shaker: ['sh', 'sh3'], rim: ['r3', 'r1'], acid: [0.35, 0.9, 'up'] },
    { name: 'groove2', bars: 8, kick: 'four', rumble: 0.5, hat: 'off8', ohat: 'oh', clap: 'two4', shaker: 'sh', perc: [0, 'c3'], stab: 't1', acid: [0.9, 1.8, 'up'] },
    { name: 'build', bars: 8, kick: 'four', rumble: 0.4, hat: 'six', ohat: 'oh', clap: 'two4', shaker: 'sh', stab: 't1', pad: 0.5, riser: 4, acid: [1.8, 3.5, 'up'], fills: ['snareroll', 'hatroll'] },
    { name: 'drop', bars: 16, impact: true, kick: 'four', rumble: 0.5, hat: ['six', 'off8'], ohat: 'oh', clap: 'two4b', ride: [0, 'rd'], perc: 'c1', shaker: 'sh', stab: 't2', pad: 0.4, acid: [3, 2, 'tri'], pings: 0.1 },
    { name: 'break', bars: 8, shaker: 'sh2', stab: 'sd', pad: 0.9, prog: 'alt', riser: 4, acid: [1.2, 3.8, 'up'], hp: [20, 160], fills: ['snareroll'] },
    { name: 'drop2', bars: 16, impact: true, kick: 'four', rumble: 0.5, hat: 'six', ohat: 'oh', clap: 'two4', ride: 'rd', perc: ['c1', 'c2'], shaker: 'sh', stab: ['t1', 't2'], pad: 0.4, acid: [3.5, 1.5, 'up'], pings: 0.1 },
    { name: 'roll', bars: 8, kick: 'four', rumble: 0.5, shaker: 'sh', acid: [1.5, 0.6, 'up'], lp: [16000, 1500] },
    { name: 'outro', bars: 8, kick: 'four', rumble: 0.6, hat: 'off8', shaker: 'sh', acid: [0.6, 0.35, 'up'], lp: [1500, 1000] },
  ],
};

export const SONGS = [SONG_A, SONG_B];

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
    await ctx.audioWorklet.addModule(base + 'deck-worklet.js');
    A.loopLen = Math.round(16 * 60 / BPM * sr);
    master = ctx.createGain(); master.gain.value = 0;
    const lim = ctx.createDynamicsCompressor();
    lim.threshold.value = -3; lim.knee.value = 6; lim.ratio.value = 6; lim.attack.value = 0.003; lim.release.value = 0.15;
    master.connect(lim).connect(ctx.destination);
    SONGS.forEach((song, i) => {
      const node = new AudioWorkletNode(ctx, 'deck', { numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [1] });
      node.port.postMessage({ song });
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
      decks.push({ node, lo, mid, hi, lp, hp, ch, an, xg, muted: false });
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
      const xg = Math.min(1, Math.sin(x * Math.PI / 2) * 1.22);
      d.xg.gain.setTargetAtTime(xg, t, tc);
      const mute = want.chan[i] * want.chan[i] * xg < 0.002;
      if (mute !== d.muted) { d.muted = mute; d.node.port.postMessage({ mute }); }
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
