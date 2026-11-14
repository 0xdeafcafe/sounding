export const BPM = 122;

const KICK = { four: 'x...x...x...x...' };

const SONG_A = {
  seed: 101, bpm: BPM, swing: 0.06,
  chords: [
    { notes: [57, 60, 64, 67, 71], root: 45, bars: 4 },
    { notes: [53, 57, 60, 64, 67], root: 41, bars: 4 },
  ],
  pat: {
    kick: KICK,
    hat: { off: '..x...x...x...x.', off16: '..x.-.x...x.-.x.' },
    shaker: { sh: '.-o-.-o-.-o-.-o-' },
    rim: { r1: '..........x.....', r2: ['...x.......x....', '......x.......x.'] },
    stab: { s0: '..x.............', s1: ['..x.......x.....', '..x.......x..x..'], s2: ['...x..x.....x...', '...x..x.......x.'] },
    bass: {
      b1: [[2, 0, 1.6], [6, 0, 1.6], [10, 0, 1.6], [14, 0, 1.6]],
      b2: [[0, 0, 3], [6, 0, 1.5], [10, 7, 1.5, 0.85], [14, 0, 1.5]],
      b3: [[0, 0, 7], [8, 0, 6, 0.9]],
    },
  },
  kit: {
    kick: { pitch: 110, deep: 50, glide: 28, decay: 170, drive: 1.3, level: 0.52 },
    bass: { drive: 1.4, hold: 600, rel: 40, lp: 320, level: 0.3 },
    stab: { det: 7, cut: 900, famt: 1.2, fdecay: 70, res: 1.6, decay: 160, level: 0.8 },
    pad: { attack: 1.6, release: 2.2, lp: 900, level: 0.16 },
    hat: { attack: 0.8, decay: 22, hp: 5500, lp: 8000, level: 0.2 },
    shaker: { attack: 3, decay: 40, hp: 4500, lp: 7000, level: 0.06 },
    rim: { freq: 1150, decay: 28, noise: 0.5, level: 0.1 },
  },
  fx: { delaySteps: 3, delayLp: 2200, delayHp: 280, feedback: 0.55, rt: 2.6, damp: 4500, duck: 0.45, duckMs: 140, stabSend: 0.7, stabDry: 0.8, stabRev: 0.3, echoRev: 0.35, echoLevel: 0.75, padRev: 0.4, rimSend: 0.8, rimDry: 0.4, rimRev: 0.2, hatSend: 0.04, revLevel: 0.55, hiss: 0.006, gain: 1 },
  sections: [
    { name: 'in', bars: 4, kick: 'four', stab: 's0', cut: [450, 700], pad: 0.5 },
    { name: 'a', bars: 16, kick: 'four', hat: 'off', bass: 'b1', stab: 's1', rim: 'r1', cut: [700, 1500], pad: 0.4 },
    { name: 'b', bars: 16, kick: 'four', hat: 'off16', shaker: 'sh', bass: ['b1', 'b2'], stab: 's2', rim: 'r2', cut: [1500, 900], pad: 0.5 },
    { name: 'dub', bars: 8, bass: 'b3', stab: 's1', rim: 'r1', cut: [900, 600], fb: 0.7, pad: 1 },
    { name: 'c', bars: 16, kick: 'four', hat: 'off16', shaker: 'sh', bass: 'b2', stab: ['s1', 's2'], rim: 'r2', cut: [700, 2000], pad: 0.3 },
    { name: 'd', bars: 16, kick: 'four', hat: 'off', shaker: 'sh', bass: 'b1', stab: 's2', rim: 'r1', cut: [2000, 800], pad: 0.5 },
    { name: 'out', bars: 4, kick: 'four', stab: 's0', cut: [800, 450], pad: 0.5 },
  ],
};

const SONG_B = {
  seed: 202, bpm: BPM, swing: 0.08,
  chords: [
    { notes: [57, 60, 62, 64, 67], root: 45, bars: 6 },
    { notes: [50, 53, 57, 60, 64], root: 38, bars: 2 },
  ],
  pat: {
    kick: KICK,
    hat: { soft: '..o...o...o...o.', off: '..x...x...x...x.', off16: '..x.-.x.-.x...x-' },
    shaker: { sh: '-o-x-o-x-o-x-o-x' },
    rim: { r1: '.......x........', r2: ['...x......x.....', '......x....x..x.'] },
    stab: { s1: '...x.....x......', s2: ['..x..x....x.....', '..x..x.......x..'] },
    bass: {
      roll: [[2, 0, 1], [3, 0, 0.8, 0.6], [6, 0, 1], [7, 12, 0.6, 0.5], [10, 0, 1], [11, 0, 0.8, 0.6], [14, 0, 1], [15, 7, 0.6, 0.5]],
      b3: [[0, 0, 7], [8, 0, 6, 0.9]],
    },
  },
  kit: {
    kick: { pitch: 100, deep: 46, glide: 30, decay: 200, drive: 1.5, level: 0.56 },
    bass: { drive: 1.8, hold: 300, rel: 30, lp: 280, level: 0.29 },
    stab: { det: 10, cut: 700, famt: 1.6, fdecay: 50, res: 2.2, decay: 120, level: 0.75 },
    pad: { attack: 2.5, release: 3, lp: 700, level: 0.13 },
    hat: { attack: 0.8, decay: 18, hp: 6000, lp: 8000, level: 0.19 },
    shaker: { attack: 2.5, decay: 35, hp: 4500, lp: 7000, level: 0.065 },
    rim: { freq: 900, decay: 24, noise: 0.7, level: 0.11 },
  },
  fx: { delaySteps: 3, delayLp: 1800, delayHp: 300, feedback: 0.62, rt: 3.4, damp: 3800, duck: 0.5, duckMs: 150, stabSend: 0.8, stabDry: 0.7, stabRev: 0.35, echoRev: 0.45, echoLevel: 0.8, padRev: 0.5, rimSend: 0.9, rimDry: 0.35, rimRev: 0.25, hatSend: 0.05, revLevel: 0.6, hiss: 0.007, gain: 1 },
  sections: [
    { name: 'in', bars: 4, kick: 'four', hat: 'soft', stab: 's1', cut: [400, 600], pad: 0.4 },
    { name: 'a', bars: 16, kick: 'four', hat: 'off', shaker: 'sh', bass: 'roll', stab: 's1', rim: 'r1', cut: [600, 1300], pad: 0.3 },
    { name: 'b', bars: 16, kick: 'four', hat: 'off16', shaker: 'sh', bass: 'roll', stab: ['s1', 's2'], rim: 'r2', cut: [1300, 700], fb: 0.66, pad: 0.4 },
    { name: 'dub', bars: 8, kick: 'four', bass: 'b3', stab: 's2', rim: 'r1', cut: [700, 500], fb: 0.74, pad: 0.9 },
    { name: 'c', bars: 16, kick: 'four', hat: 'off16', shaker: 'sh', bass: 'roll', stab: 's2', rim: 'r2', cut: [500, 1700], pad: 0.3 },
    { name: 'd', bars: 16, kick: 'four', hat: 'soft', shaker: 'sh', bass: 'roll', stab: 's1', rim: 'r1', cut: [1700, 600], pad: 0.5 },
    { name: 'out', bars: 4, kick: 'four', hat: 'soft', stab: 's1', cut: [600, 400], pad: 0.4 },
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

  A.set = next => { Object.assign(want, next); if (A.on) apply(); };

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
    apply(0.001);
    master.gain.cancelScheduledValues(ctx.currentTime);
    master.gain.setTargetAtTime(0.75, ctx.currentTime, 0.05);
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
