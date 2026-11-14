const TAU = Math.PI * 2;
const midi = n => 440 * Math.pow(2, (n - 69) / 12);
const clamp = (v, a, b) => v < a ? a : v > b ? b : v;
const VEL = { X: 1.15, x: 1, o: 0.7, '-': 0.45, '.': 0 };

class Rng {
  constructor(seed) { this.s = (seed >>> 0) || 1; }
  next() { let s = this.s; s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; this.s = s; return s / 4294967296; }
  spread(w) { return (this.next() + this.next() - 1) * w; }
}

class Noise {
  constructor(seed) { this.s = seed | 0 || 1; }
  next() { let s = this.s; s ^= s << 13; s ^= s >>> 17; s ^= s << 5; this.s = s; return (s >>> 0) / 2147483648 - 1; }
}

class SVF {
  constructor(sr) { this.sr = sr; this.ic1 = 0; this.ic2 = 0; this.k = 1; this.a1 = 0; this.a2 = 0; this.a3 = 0; this.lp = 0; this.bp = 0; this.hp = 0; this.set(1000, 0.7); }
  set(fc, q) {
    const g = Math.tan(Math.PI * clamp(fc, 8, this.sr * 0.45) / this.sr);
    const k = 1 / q;
    this.k = k; this.a1 = 1 / (1 + g * (g + k)); this.a2 = g * this.a1; this.a3 = g * this.a2;
  }
  run(x) {
    const v3 = x - this.ic2;
    const v1 = this.a1 * this.ic1 + this.a2 * v3;
    const v2 = this.ic2 + this.a2 * this.ic1 + this.a3 * v3;
    this.ic1 = 2 * v1 - this.ic1; this.ic2 = 2 * v2 - this.ic2;
    this.lp = v2; this.bp = v1; this.hp = x - this.k * v1 - v2;
    return v2;
  }
}

class Pole {
  constructor(sr, hz) { this.sr = sr; this.y = 0; this.set(hz); }
  set(hz) { this.a = 1 - Math.exp(-TAU * hz / this.sr); }
  lp(x) { this.y += (x - this.y) * this.a; return this.y; }
  hp(x) { this.y += (x - this.y) * this.a; return x - this.y; }
}

function blep(t, dt) {
  if (t < dt) { t /= dt; return t + t - t * t - 1; }
  if (t > 1 - dt) { t = (t - 1) / dt; return t * t + t + t + 1; }
  return 0;
}

// MARK: Voices

class Voice {
  constructor(e) { this.e = e; this.on = false; this.wait = 0; this.age = 0; }
  start(p, wait) { this.on = true; this.wait = wait | 0; this.age = this.e.t; this.trig(p); }
  out() {
    if (this.wait > 0) { this.wait--; return 0; }
    const v = this.run();
    if (this.done()) this.on = false;
    return v;
  }
}

class Kick extends Voice {
  trig(p) {
    const sr = this.e.sr;
    this.ph = 0; this.n = 0; this.env = 1; this.amp = p.level;
    this.f = p.pitch; this.f1 = p.deep; this.pd = Math.exp(-1 / (p.glide * 0.001 * sr));
    this.dec = Math.exp(-1 / (p.decay * 0.001 * sr)); this.atk = Math.max(1, Math.round(0.0015 * sr)); this.drive = p.drive;
  }
  run() {
    this.n++;
    this.f = this.f1 + (this.f - this.f1) * this.pd;
    this.ph += this.f / this.e.sr; if (this.ph >= 1) this.ph -= 1;
    this.env *= this.dec;
    const a = this.n < this.atk ? this.n / this.atk : 1;
    return Math.tanh(Math.sin(TAU * this.ph) * this.drive) / Math.tanh(this.drive) * this.env * a * this.amp;
  }
  done() { return this.env < 0.0002; }
}

class Bass extends Voice {
  constructor(e) { super(e); this.lpf = new Pole(e.sr, 300); }
  trig(p) {
    const sr = this.e.sr;
    this.inc = midi(p.note) / sr; this.ph = 0; this.n = 0; this.env = 0; this.len = p.len; this.amp = p.level; this.drive = p.drive;
    this.ar = 1 / (0.006 * sr); this.sus = Math.exp(-1 / (p.hold * 0.001 * sr)); this.rel = Math.exp(-1 / (p.rel * 0.001 * sr)); this.lpf.set(p.lp); this.lpf.y = 0; this.cut = false;
  }
  release() { this.cut = true; this.rel = Math.exp(-1 / (0.012 * this.e.sr)); }
  run() {
    this.n++;
    if (this.n < this.len && !this.cut) { if (this.env < 1 && this.n * this.ar < 1) this.env = this.n * this.ar; else this.env *= this.sus; }
    else this.env *= this.rel;
    this.ph += this.inc; if (this.ph >= 1) this.ph -= 1;
    const s = Math.tanh(Math.sin(TAU * this.ph) * this.drive) / Math.tanh(this.drive);
    return this.lpf.lp(s) * this.env * this.amp;
  }
  done() { return this.n > this.len && this.env < 0.0002; }
}

class Stab extends Voice {
  constructor(e) { super(e); this.f1 = new SVF(e.sr); this.f2 = new SVF(e.sr); this.ph = new Float64Array(12); this.inc = new Float64Array(12); this.cnt = 0; }
  trig(p) {
    const sr = this.e.sr;
    const notes = p.notes; this.cnt = Math.min(12, notes.length * 2);
    for (let i = 0; i < this.cnt; i++) {
      const cents = (i & 1 ? 1 : -1) * p.det * (0.7 + 0.3 * ((i >> 1) % 3) / 2);
      this.inc[i] = midi(notes[i >> 1]) * Math.pow(2, cents / 1200) / sr;
      this.ph[i] = (i * 0.382) % 1;
    }
    this.n = 0; this.env = 0; this.fenv = 1; this.amp = p.level / Math.sqrt(notes.length);
    this.atk = Math.max(1, Math.round(0.003 * sr)); this.dec = Math.exp(-1 / (p.decay * 0.001 * sr)); this.fdec = Math.exp(-1 / (p.fdecay * 0.001 * sr));
    this.cut = p.cut; this.famt = p.famt; this.q = p.res; this.f1.ic1 = this.f1.ic2 = this.f2.ic1 = this.f2.ic2 = 0;
  }
  run() {
    this.n++;
    if (this.n <= this.atk) this.env = this.n / this.atk; else this.env *= this.dec;
    this.fenv *= this.fdec;
    if (!(this.n & 15)) { const fc = this.cut * (1 + this.famt * this.fenv); this.f1.set(fc, this.q); this.f2.set(fc * 1.15, 0.6); }
    let s = 0;
    for (let i = 0; i < this.cnt; i++) {
      const d = this.inc[i];
      let p = this.ph[i] + d; if (p >= 1) p -= 1; this.ph[i] = p;
      s += 2 * p - 1 - blep(p, d);
    }
    s = this.f2.run(this.f1.run(s * 0.5));
    return s * this.env * this.amp;
  }
  done() { return this.n > this.atk && this.env < 0.0002; }
}

class Pad extends Voice {
  constructor(e) { super(e); this.ph = new Float64Array(8); this.inc = new Float64Array(8); this.cnt = 0; this.lpf = new Pole(e.sr, 900); }
  trig(p) {
    const sr = this.e.sr;
    this.cnt = Math.min(8, p.notes.length * 2);
    for (let i = 0; i < this.cnt; i++) { this.inc[i] = midi(p.notes[i >> 1]) * Math.pow(2, (i & 1 ? 6 : -6) / 1200) / sr; this.ph[i] = (i * 0.618) % 1; }
    this.env = 0; this.amp = p.level / Math.sqrt(p.notes.length); this.rising = true;
    this.att = 1 - Math.exp(-1 / (p.attack * sr)); this.rel = Math.exp(-1 / (p.release * sr)); this.lpf.set(p.lp);
  }
  release() { this.rising = false; }
  run() {
    if (this.rising) this.env += (1 - this.env) * this.att; else this.env *= this.rel;
    let s = 0;
    for (let i = 0; i < this.cnt; i++) {
      let p = this.ph[i] + this.inc[i]; if (p >= 1) p -= 1; this.ph[i] = p;
      const tri = p < 0.5 ? 4 * p - 1 : 3 - 4 * p;
      s += tri;
    }
    return this.lpf.lp(s * 0.5) * this.env * this.amp;
  }
  done() { return !this.rising && this.env < 0.0002; }
}

class Hat extends Voice {
  constructor(e) { super(e); this.hpf = new SVF(e.sr); this.lpf = new SVF(e.sr); }
  trig(p) {
    const sr = this.e.sr;
    this.n = 0; this.env = 0; this.amp = p.level; this.atk = Math.max(1, Math.round(p.attack * 0.001 * sr));
    this.dec = Math.exp(-1 / (p.decay * 0.001 * sr)); this.hpf.set(p.hp, 0.7); this.lpf.set(p.lp, 0.6);
  }
  run() {
    this.n++;
    if (this.n <= this.atk) this.env = this.n / this.atk; else this.env *= this.dec;
    this.hpf.run(this.e.noise.next());
    return this.lpf.run(this.hpf.hp) * this.env * this.amp;
  }
  done() { return this.n > this.atk && this.env < 0.0002; }
}

class Rim extends Voice {
  constructor(e) { super(e); this.bp = new SVF(e.sr); }
  trig(p) {
    const sr = this.e.sr;
    this.n = 0; this.env = 0; this.ph = 0; this.inc = p.freq / sr; this.amp = p.level; this.atk = Math.max(1, Math.round(0.0012 * sr));
    this.dec = Math.exp(-1 / (p.decay * 0.001 * sr)); this.bp.set(p.freq * 2.2, 3); this.noise = p.noise;
  }
  run() {
    this.n++;
    if (this.n <= this.atk) this.env = this.n / this.atk; else this.env *= this.dec;
    this.ph += this.inc; if (this.ph >= 1) this.ph -= 1;
    this.bp.run(this.e.noise.next());
    return (Math.sin(TAU * this.ph) + this.bp.bp * this.noise) * this.env * this.amp;
  }
  done() { return this.n > this.atk && this.env < 0.0002; }
}

// MARK: Space

class Echo {
  constructor(sr) { this.sr = sr; this.buf = new Float32Array(sr * 4); this.w = 0; this.len = sr; this.lo = new Pole(sr, 2400); this.hi = new Pole(sr, 260); }
  set(len, lp, hp) { this.len = clamp(len | 0, 1, this.buf.length - 1); this.lo.set(lp); this.hi.set(hp); }
  clear() { this.buf.fill(0); this.lo.y = this.hi.y = 0; }
  run(x, fb) {
    let r = this.w - this.len; if (r < 0) r += this.buf.length;
    const d = this.buf[r];
    const back = this.hi.hp(this.lo.lp(d));
    this.buf[this.w] = x + Math.tanh(back * fb * 1.1) / 1.1;
    if (++this.w >= this.buf.length) this.w = 0;
    return d;
  }
}

class Room {
  constructor(sr, rt, damp) {
    const k = sr / 48000;
    this.lines = [1559, 1907, 2341, 2789].map(n => ({ buf: new Float32Array(Math.round(n * k)), i: 0, y: 0 }));
    this.ap = [142, 379, 107].map(n => ({ buf: new Float32Array(Math.round(n * k)), i: 0 }));
    this.pre = new Pole(sr, 5200);
    this.damp = 1 - Math.exp(-TAU * damp / sr);
    this.g = this.lines.map(l => Math.pow(10, -3 * l.buf.length / (sr * rt)));
  }
  clear() { for (const l of this.lines) { l.buf.fill(0); l.y = 0; } for (const a of this.ap) a.buf.fill(0); this.pre.y = 0; }
  run(x) {
    x = this.pre.lp(x);
    for (const a of this.ap) { const d = a.buf[a.i]; const v = x + d * 0.6; a.buf[a.i] = v; x = d - v * 0.6; if (++a.i >= a.buf.length) a.i = 0; }
    const L = this.lines;
    const o0 = L[0].buf[L[0].i], o1 = L[1].buf[L[1].i], o2 = L[2].buf[L[2].i], o3 = L[3].buf[L[3].i];
    const h = [o0 + o1 + o2 + o3, o0 - o1 + o2 - o3, o0 + o1 - o2 - o3, o0 - o1 - o2 + o3];
    for (let j = 0; j < 4; j++) {
      const l = L[j];
      l.y += (h[j] * 0.5 * this.g[j] - l.y) * this.damp;
      l.buf[l.i] = x + l.y;
      if (++l.i >= l.buf.length) l.i = 0;
    }
    return (o0 + o1 + o2 + o3) * 0.25;
  }
}

// MARK: Engine

function pool(e, C, n) { return Array.from({ length: n }, () => new C(e)); }
function sum(p) { let s = 0; for (let i = 0; i < p.length; i++) if (p[i].on) s += p[i].out(); return s; }
function grab(p) {
  let best = null;
  for (const v of p) { if (!v.on) return v; if (!best || v.age < best.age) best = v; }
  return best;
}

class Engine {
  constructor(song, sr) {
    this.song = song; this.sr = sr;
    this.spb = 60 / song.bpm * sr; this.stepLen = this.spb / 4; this.barLen = this.spb * 4;
    this.rng = new Rng(song.seed); this.noise = new Noise(song.seed * 7919 + 13);
    this.total = song.sections.reduce((a, s) => a + s.bars, 0);
    this.chordBars = song.chords.reduce((a, c) => a + c.bars, 0);
    this.kick = pool(this, Kick, 2); this.bass = pool(this, Bass, 3); this.stab = pool(this, Stab, 4); this.pad = pool(this, Pad, 2);
    this.hat = pool(this, Hat, 3); this.shaker = pool(this, Hat, 3); this.rim = pool(this, Rim, 2);
    this.all = [this.kick, this.bass, this.stab, this.pad, this.hat, this.shaker, this.rim];
    const fx = song.fx;
    this.echo = new Echo(sr); this.echo.set(Math.round(fx.delaySteps * this.stepLen), fx.delayLp, fx.delayHp);
    this.room = new Room(sr, fx.rt, fx.damp);
    this.hissHp = new Pole(sr, 1800); this.hissLp = new Pole(sr, 5000);
    this.hp1 = new Pole(sr, 28); this.hp2 = new Pole(sr, 28);
    this.duck = 0; this.duckT = 0; this.duckDec = Math.exp(-1 / (fx.duckMs * 0.001 * sr)); this.duckA = 1 - Math.exp(-1 / (0.003 * sr));
    this.fb = fx.feedback; this.fbT = fx.feedback; this.cut = 600; this.cutT = 600; this.padLvl = 0; this.padT = 0; this.hiss = 0; this.hissT = 0;
    this.dcx = 0; this.dcy = 0;
    this.reset(0);
  }

  reset(start) {
    this.t = start;
    this.stepIndex = Math.round(start / this.stepLen);
    this.nextStepF = this.stepIndex * this.stepLen; this.nextStep = Math.round(this.nextStepF);
    for (const p of this.all) for (const v of p) v.on = false;
    this.echo.clear(); this.room.clear();
    this.chordAt = -1; this.duck = this.duckT = 0;
    const [sec] = this.where(this.stepIndex >> 4);
    this.fb = this.fbT = sec.fb ?? this.song.fx.feedback;
    this.cut = this.cutT = sec.cut ? sec.cut[0] : this.song.kit.stab.cut;
    this.padLvl = this.padT = sec.pad || 0; this.hiss = this.hissT = sec.hiss ?? this.song.fx.hiss;
  }

  where(bar) {
    let b = bar % this.total, i = 0;
    const s = this.song.sections;
    while (b >= s[i].bars) { b -= s[i].bars; i++; }
    return [s[i], b];
  }

  chord(bar) {
    let b = bar % this.chordBars;
    for (const c of this.song.chords) { if (b < c.bars) return c; b -= c.bars; }
    return this.song.chords[0];
  }

  pat(kind, name, bar) {
    if (!name) return null;
    const set = this.song.pat[kind];
    if (Array.isArray(name)) name = name[Math.floor(bar / 4) % name.length];
    const p = set && set[name];
    if (!p) return null;
    return Array.isArray(p) && typeof p[0] === 'string' ? p[bar % p.length] : p;
  }

  vel(str, s) { return str ? VEL[str[s]] || 0 : 0; }

  fireStep() {
    const si = this.stepIndex++;
    const bar = si >> 4, s = si & 15;
    const [sec, sb] = this.where(bar);
    const k = this.song.kit, r = this.rng;
    const swing = s & 1 ? Math.round(this.song.swing * this.stepLen) : 0;
    const u = (sb * 16 + s) / (sec.bars * 16);
    if (sec.cut) this.cutT = sec.cut[0] * Math.pow(sec.cut[1] / sec.cut[0], u);
    this.fbT = sec.fb ?? this.song.fx.feedback;
    this.padT = sec.pad || 0;
    this.hissT = sec.hiss ?? this.song.fx.hiss;
    const ch = this.chord(bar);
    if (s === 0 && ch !== this.chordAt) {
      this.chordAt = ch;
      for (const v of this.pad) if (v.on) v.release();
      grab(this.pad).start({ ...k.pad, notes: ch.pad || ch.notes.slice(0, 4).map(n => n - 12) }, 0);
    }
    const kv = this.vel(this.pat('kick', sec.kick, sb), s);
    if (kv) { grab(this.kick).start({ ...k.kick, level: k.kick.level * kv }, 0); this.duckT = 1; }
    const hv = this.vel(this.pat('hat', sec.hat, sb), s);
    if (hv) grab(this.hat).start({ ...k.hat, level: k.hat.level * hv * (1 + r.spread(0.12)), decay: k.hat.decay * (0.85 + r.next() * 0.3) }, swing);
    const shv = this.vel(this.pat('shaker', sec.shaker, sb), s);
    if (shv) grab(this.shaker).start({ ...k.shaker, level: k.shaker.level * shv * (1 + r.spread(0.15)) }, swing);
    const rv = this.vel(this.pat('rim', sec.rim, sb), s);
    if (rv) grab(this.rim).start({ ...k.rim, level: k.rim.level * rv }, swing);
    const sv = this.vel(this.pat('stab', sec.stab, sb), s);
    if (sv) grab(this.stab).start({ ...k.stab, notes: ch.notes, cut: this.cutT * (1 + r.spread(0.06)), level: k.stab.level * sv }, swing);
    const bp = this.pat('bass', sec.bass, sb);
    if (bp) for (const h of bp) if (h[0] === s) {
      for (const v of this.bass) if (v.on) v.release();
      grab(this.bass).start({ ...k.bass, note: ch.root + h[1], len: Math.round(this.stepLen * h[2]), level: k.bass.level * (h[3] || 1) }, swing);
    }
  }

  advance() {
    while (this.t >= this.nextStep) { this.fireStep(); this.nextStepF += this.stepLen; this.nextStep = Math.round(this.nextStepF); }
  }

  skip(buf, off, n) {
    for (let i = 0; i < n; i++) { this.advance(); buf[off + i] = 0; this.t++; }
    for (const p of this.all) for (const v of p) v.on = false;
    this.duck = this.duckT = 0;
  }

  render(buf, off, n) {
    const fx = this.song.fx;
    for (let i = 0; i < n; i++) {
      this.advance();
      if (!(this.t & 63)) {
        this.cut += (this.cutT - this.cut) * 0.05;
        this.fb += (this.fbT - this.fb) * 0.01;
        this.padLvl += (this.padT - this.padLvl) * 0.004;
        this.hiss += (this.hissT - this.hiss) * 0.01;
      }
      this.duckT *= this.duckDec;
      this.duck += (this.duckT - this.duck) * this.duckA;
      const dg = 1 - fx.duck * this.duck;
      const kick = sum(this.kick), bass = sum(this.bass), stab = sum(this.stab), pad = sum(this.pad) * this.padLvl;
      const hats = sum(this.hat) + sum(this.shaker), rim = sum(this.rim);
      const d = this.echo.run(stab * fx.stabSend + rim * fx.rimSend + hats * fx.hatSend, this.fb);
      const rev = this.room.run(stab * fx.stabRev + d * fx.echoRev + pad * fx.padRev + rim * fx.rimRev);
      const h = this.hissLp.lp(this.hissHp.hp(this.noise.next())) * this.hiss;
      let x = kick + bass * dg + hats + rim * fx.rimDry + (stab * fx.stabDry + d * fx.echoLevel + pad) * (0.55 + 0.45 * dg) + rev * fx.revLevel + h;
      x = this.hp2.hp(this.hp1.hp(x)) * fx.gain;
      const a = Math.abs(x);
      if (a > 0.6) x = Math.sign(x) * (0.6 + 0.4 * Math.tanh((a - 0.6) / 0.4));
      const y = x - this.dcx + 0.997 * this.dcy; this.dcx = x; this.dcy = y;
      buf[off + i] = y;
      this.t++;
    }
  }
}

function makeScratch(sr) {
  const n = sr | 0;
  const out = new Float32Array(n);
  const osc = [[220, 0.5], [330, 0.2], [110, 0.3]].map(([f, g]) => ({ inc: f / sr, ph: 0, g }));
  const bp = [[760, 9, 1], [1180, 10, 0.6], [2700, 12, 0.35]].map(([f, q, g]) => { const s = new SVF(sr); s.set(f, q); return { s, g }; });
  let peak = 0;
  for (let i = 0; i < n; i++) {
    let x = 0;
    for (const o of osc) { o.ph += o.inc; if (o.ph >= 1) o.ph -= 1; x += (2 * o.ph - 1 - blep(o.ph, o.inc)) * o.g; }
    let y = 0;
    for (const b of bp) { b.s.run(x); y += b.s.bp * b.g; }
    out[i] = y;
    if (i > sr * 0.2) peak = Math.max(peak, Math.abs(y));
  }
  const k = 0.5 / (peak || 1);
  for (let i = 0; i < n; i++) out[i] *= k;
  return out;
}

class Deck extends AudioWorkletProcessor {
  static get parameterDescriptors() {
    return [
      { name: 'rate', defaultValue: 1, minValue: -8, maxValue: 8, automationRate: 'k-rate' },
      { name: 'master', defaultValue: 1, minValue: 0, maxValue: 2, automationRate: 'k-rate' },
      { name: 'slip', defaultValue: 0, minValue: 0, maxValue: 1, automationRate: 'k-rate' },
      { name: 'scratch', defaultValue: 0, minValue: 0, maxValue: 1, automationRate: 'k-rate' },
    ];
  }

  constructor() {
    super();
    this.sr = sampleRate;
    this.engine = null;
    const L = this.sr > 50000 ? 1 << 21 : 1 << 20;
    this.L = L; this.mask = L - 1; this.tape = new Float32Array(L); this.head = 0;
    this.scr = makeScratch(this.sr);
    this.pos = 0; this.ref = 0; this.old = 0; this.r = 1; this.m = 1; this.mix = 0; this.locked = true; this.sg = 0; this.tick = 0; this.muted = false;
    this.port.onmessage = e => {
      if (e.data.song) { this.engine = new Engine(e.data.song, this.sr); this.head = 0; this.ref = this.pos = this.old = 0; }
      if (e.data.ref != null) this.seek(e.data.ref);
      if (e.data.mute != null) this.muted = !!e.data.mute;
    };
  }

  seek(ref) {
    if (!this.engine) { this.ref = this.pos = ref; return; }
    const beat = this.engine.spb;
    const q = Math.round((Math.round(ref / beat) % 16) * beat);
    this.engine.reset(q);
    this.head = q; this.ref = this.pos = this.old = q; this.mix = 0;
  }

  ensure(need) {
    while (this.head < need) {
      if (this.muted) this.engine.skip(this.tape, this.head & this.mask, 64);
      else this.engine.render(this.tape, this.head & this.mask, 64);
      this.head += 64;
    }
  }

  read(buf, p) {
    if (buf) {
      const n = buf.length;
      p -= Math.floor(p / n) * n;
      const i = p | 0; const f = p - i;
      const a = buf[i], b = buf[i + 1 < n ? i + 1 : 0];
      return a + (b - a) * f;
    }
    if (p > this.head - 2) p = this.head - 2;
    const lo = this.head - this.L + 4;
    if (p < lo) p = lo;
    const i = Math.floor(p); const f = p - i;
    const a = this.tape[i & this.mask], b = this.tape[(i + 1) & this.mask];
    return a + (b - a) * f;
  }

  process(inputs, outputs, params) {
    const out = outputs[0][0];
    if (!this.engine) return true;
    const rate = params.rate[0], master = params.master[0], slip = params.slip[0] > 0.5, scratch = params.scratch[0];
    if (slip && this.locked) { this.locked = false; this.pos = this.ref; this.mix = 0; }
    if (!slip && !this.locked) { this.locked = true; this.old = this.pos; this.mix = 1; }
    for (let i = 0; i < out.length; i++) {
      this.r += (rate - this.r) * 0.006;
      this.m += (master - this.m) * 0.002;
      this.sg += (scratch - this.sg) * 0.003;
      this.ref += this.m;
      let need = this.ref;
      let v;
      if (this.locked) {
        if (this.mix > 0) { this.old += this.r; if (this.old > need) need = this.old; }
        this.ensure(need + 3);
        v = this.read(null, this.ref);
        if (this.mix > 0) {
          v = v * (1 - this.mix) + this.read(null, this.old) * this.mix;
          this.mix -= 1 / 1400;
        }
        this.pos = this.ref;
      } else {
        this.pos += this.r;
        if (this.pos > need) need = this.pos;
        if (this.pos < this.head - this.L + 8) this.pos = this.head - this.L + 8;
        this.ensure(need + 3);
        v = this.read(null, this.pos);
      }
      if (this.sg > 0.001) {
        const sp = Math.min(1, Math.abs(this.r) * 2.5);
        v = v * (1 - this.sg * 0.45) + this.read(this.scr, this.pos * 0.5) * this.sg * sp * 0.9;
      }
      out[i] = v;
    }
    this.tick += out.length;
    if (this.tick >= 4096) { this.tick = 0; this.port.postMessage({ ref: this.ref, at: currentTime }); }
    return true;
  }
}

registerProcessor('deck', Deck);
