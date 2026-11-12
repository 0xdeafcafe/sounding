const TAU = Math.PI * 2;
const midi = n => 440 * Math.pow(2, (n - 69) / 12);
const clamp = (v, a, b) => v < a ? a : v > b ? b : v;
const VEL = { X: 1.15, x: 1, o: 0.72, '-': 0.42, '.': 0 };

class Rng {
  constructor(seed) { this.s = (seed >>> 0) || 1; }
  next() { let s = this.s; s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; this.s = s; return s / 4294967296; }
  pick(a) { return a[(this.next() * a.length) | 0]; }
  chance(p) { return this.next() < p; }
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

class Line {
  constructor(n) { let m = 1; while (m < n) m <<= 1; this.b = new Float32Array(m); this.m = m - 1; this.i = 0; }
  push(x) { this.b[this.i] = x; this.i = (this.i + 1) & this.m; }
  at(d) { return this.b[(this.i - d) & this.m]; }
  atF(d) { const j = this.i - d; const k = Math.floor(j); const f = j - k; const a = this.b[k & this.m]; return a + (this.b[(k + 1) & this.m] - a) * f; }
}

class AP {
  constructor(n, g) { this.l = new Line(n + 64); this.n = n; this.g = g; }
  run(x, mod = 0) {
    const d = mod ? this.l.atF(this.n + mod) : this.l.at(this.n);
    const w = x + this.g * d;
    this.l.push(w);
    return d - this.g * w;
  }
}

class Plate {
  constructor(sr, decay, damp) {
    const s = sr / 29761;
    const z = n => Math.round(n * s);
    this.pre = new Line(z(1200)); this.preN = z(500);
    this.bw = 0; this.bwc = 0.6;
    this.in = [new AP(z(142), 0.75), new AP(z(107), 0.75), new AP(z(379), 0.625), new AP(z(277), 0.625)];
    this.apL = new AP(z(672), -0.7); this.dL1 = new Line(z(4453) + 8); this.apL2 = new AP(z(1800), 0.5); this.dL2 = new Line(z(3720) + 8);
    this.apR = new AP(z(908), -0.7); this.dR1 = new Line(z(4217) + 8); this.apR2 = new AP(z(2656), 0.5); this.dR2 = new Line(z(3163) + 8);
    this.nL1 = z(4453); this.nL2 = z(3720); this.nR1 = z(4217); this.nR2 = z(3163);
    this.decay = decay; this.damp = damp;
    this.lpL = 0; this.lpR = 0; this.outL = 0; this.outR = 0;
    this.lfo = 0; this.lfoInc = TAU * 0.9 / sr; this.modD = z(12);
    this.t = [z(266), z(2974), z(1913), z(1996), z(1990), z(187), z(1066), z(353), z(3627), z(1228), z(2673), z(2111), z(335), z(121)];
  }
  run(x) {
    this.pre.push(x);
    let v = this.pre.at(this.preN);
    this.bw += (v - this.bw) * this.bwc; v = this.bw;
    for (let i = 0; i < 4; i++) v = this.in[i].run(v);
    this.lfo += this.lfoInc; if (this.lfo > TAU) this.lfo -= TAU;
    const m1 = Math.sin(this.lfo) * this.modD, m2 = Math.cos(this.lfo) * this.modD;
    let l = v + this.outR * this.decay;
    l = this.apL.run(l, m1);
    this.dL1.push(l);
    l = this.dL1.at(this.nL1);
    this.lpL += (l - this.lpL) * (1 - this.damp); l = this.lpL * this.decay;
    l = this.apL2.run(l);
    this.dL2.push(l);
    this.outL = this.dL2.at(this.nL2);
    let r = v + this.outL * this.decay;
    r = this.apR.run(r, m2);
    this.dR1.push(r);
    r = this.dR1.at(this.nR1);
    this.lpR += (r - this.lpR) * (1 - this.damp); r = this.lpR * this.decay;
    r = this.apR2.run(r);
    this.dR2.push(r);
    this.outR = this.dR2.at(this.nR2);
    const t = this.t;
    const yL = this.dR1.at(t[0]) + this.dR1.at(t[1]) - this.apR2.l.at(t[2]) + this.dR2.at(t[3]) - this.dL1.at(t[4]) - this.apL2.l.at(t[5]) - this.dL2.at(t[6]);
    const yR = this.dL1.at(t[7]) + this.dL1.at(t[8]) - this.apL2.l.at(t[9]) + this.dL2.at(t[10]) - this.dR1.at(t[11]) - this.apR2.l.at(t[12]) - this.dR2.at(t[13]);
    return (yL + yR) * 0.3;
  }
}

class Voice {
  constructor(e) { this.e = e; this.on = false; this.wait = 0; this.born = -1; this.fade = 1; this.fading = false; this.q = null; }
  start(delay, p) {
    delay = Math.max(1, delay | 0);
    if (this.on) { this.fading = true; delay = Math.max(delay, 96); }
    this.wait = delay; this.q = p; this.on = true; this.born = this.e.t + delay;
  }
  out() {
    if (!this.on) return 0;
    if (this.wait > 0) {
      this.wait--;
      let v = 0;
      if (this.fading) { this.fade -= 1 / 96; if (this.fade < 0) this.fade = 0; v = this.run() * this.fade; }
      if (this.wait === 0) { this.fading = false; this.fade = 1; this.trig(this.q); }
      return v;
    }
    const v = this.run();
    if (this.done()) this.on = false;
    return v;
  }
}

class Kick extends Voice {
  constructor(e) { super(e); this.hp = new SVF(e.sr); this.hp.set(2800, 0.7); this.ph = 0; this.f = 0; this.f0 = 50; this.pc = 0; this.env = 0; this.dec = 0; this.n = 0; this.cl = 0; this.clc = 0; this.click = 0; this.sat = 1; this.amp = 0; }
  trig(p) {
    this.ph = 0; this.f = p.pitch; this.f0 = p.deep; this.pc = 1 - this.e.dc(p.glide);
    this.env = 1; this.dec = this.e.dc(p.decay); this.n = 0; this.amp = p.level;
    this.cl = 1; this.clc = this.e.dc(2.5); this.click = p.click; this.sat = p.sat;
    this.e.duckE = 1;
  }
  run() {
    this.n++;
    const atk = this.n < 20 ? this.n / 20 : 1;
    this.f += (this.f0 - this.f) * this.pc;
    this.ph += this.f / this.e.sr; if (this.ph >= 1) this.ph -= 1;
    this.env *= this.dec; this.cl *= this.clc;
    let s = Math.sin(TAU * this.ph);
    s = Math.tanh(s * (this.sat + this.env * 1.4)) / Math.tanh(this.sat + 1.4);
    this.hp.run(this.e.noise.next());
    const c = this.hp.hp * this.cl * this.click;
    return (s * this.env + c) * atk * this.amp;
  }
  done() { return this.env < 0.0004; }
}

class Rumble extends Voice {
  constructor(e) { super(e); this.f = new SVF(e.sr); this.ph = 0; this.env = 0; this.dec = 0; this.n = 0; this.amp = 0; this.fr = 40; }
  trig(p) { this.env = 1; this.dec = this.e.dc(p.decay); this.n = 0; this.amp = p.level; this.f.set(p.lp, 1.3); this.ph = 0; this.fr = p.freq; }
  run() {
    this.n++;
    const atk = this.n < 500 ? this.n / 500 : 1;
    this.env *= this.dec;
    this.ph += this.fr / this.e.sr; if (this.ph >= 1) this.ph -= 1;
    const x = this.f.run(this.e.noise.next() * 2.5) + Math.sin(TAU * this.ph) * 0.35;
    return x * this.env * atk * this.amp;
  }
  done() { return this.env < 0.001; }
}

class Hat extends Voice {
  constructor(e) { super(e); this.hp = new SVF(e.sr); this.lp = new SVF(e.sr); this.env = 0; this.env2 = 0; this.dec = 0; this.dec2 = 0; this.tail = 0; this.n = 0; this.ph1 = 0; this.ph2 = 0; this.amp = 0; this.metal = 0; }
  trig(p) {
    this.env = 1; this.env2 = 1; this.dec = this.e.dc(p.decay); this.dec2 = this.e.dc(p.decay * 3.2); this.tail = p.tail;
    this.n = 0; this.amp = p.level; this.hp.set(p.hp, 0.8); this.lp.set(p.lp, 0.6); this.metal = p.metal;
  }
  run() {
    this.n++;
    const atk = this.n < 12 ? this.n / 12 : 1;
    this.env *= this.dec; this.env2 *= this.dec2;
    let x = this.e.noise.next();
    if (this.metal) {
      this.ph1 += 6173 / this.e.sr; if (this.ph1 >= 1) this.ph1 -= 1;
      this.ph2 += 8419 / this.e.sr; if (this.ph2 >= 1) this.ph2 -= 1;
      x *= 0.7 + 0.3 * ((this.ph1 < 0.5 ? 1 : -1) * (this.ph2 < 0.5 ? 1 : -1));
    }
    this.hp.run(x); x = this.lp.run(this.hp.hp);
    return x * (this.env + this.env2 * this.tail) * atk * this.amp;
  }
  done() { return this.env2 < 0.0008; }
}

class Clap extends Voice {
  constructor(e) { super(e); this.bp = new SVF(e.sr); this.hp = new SVF(e.sr); this.n = 0; this.b = 0; this.tl = 0; this.bd = 0; this.td = 0; this.gap = 1; this.amp = 0; }
  trig(p) { this.n = 0; this.b = 1; this.tl = 0; this.bd = this.e.dc(7); this.td = this.e.dc(p.decay); this.gap = Math.round(this.e.sr * 0.0095); this.amp = p.level; this.bp.set(p.freq, 1.1); this.hp.set(420, 0.7); }
  run() {
    this.n++;
    if (this.n === this.gap || this.n === this.gap * 2) this.b = 1;
    if (this.n === this.gap * 3) this.tl = 1;
    this.b *= this.bd; this.tl *= this.td;
    const atk = this.n < 10 ? this.n / 10 : 1;
    this.hp.run(this.e.noise.next());
    this.bp.run(this.hp.hp);
    return this.bp.bp * 2.2 * (this.b * 0.8 + this.tl) * atk * this.amp;
  }
  done() { return this.n > this.gap * 3 && this.tl < 0.001; }
}

class Perc extends Voice {
  constructor(e) { super(e); this.bp = new SVF(e.sr); this.ph = 0; this.f = 0; this.f0 = 0; this.env = 0; this.dec = 0; this.nz = 0; this.nd = 0; this.n = 0; this.amp = 0; this.pc = 0; this.tone = 0.5; }
  trig(p) { this.ph = 0; this.f = p.freq * 1.9; this.f0 = p.freq; this.env = 1; this.dec = this.e.dc(p.decay); this.nz = 1; this.nd = this.e.dc(p.ndecay); this.n = 0; this.amp = p.level; this.bp.set(p.freq * 2.5, 2); this.pc = 1 - this.e.dc(4); this.tone = p.tone; }
  run() {
    this.n++;
    const atk = this.n < 10 ? this.n / 10 : 1;
    this.f += (this.f0 - this.f) * this.pc;
    this.ph += this.f / this.e.sr; if (this.ph >= 1) this.ph -= 1;
    this.env *= this.dec; this.nz *= this.nd;
    this.bp.run(this.e.noise.next());
    const s = Math.sin(TAU * this.ph) * this.env * this.tone + this.bp.bp * 2 * this.nz * (1.2 - this.tone);
    return s * atk * this.amp;
  }
  done() { return this.env < 0.001 && this.nz < 0.001; }
}

class Bell extends Voice {
  constructor(e) { super(e); this.p1 = 0; this.p2 = 0; this.p3 = 0; this.f = 440; this.env = 0; this.env2 = 0; this.dec = 0; this.dec2 = 0; this.n = 0; this.amp = 0; }
  trig(p) { this.f = midi(p.note); this.p1 = this.p2 = this.p3 = 0; this.env = 1; this.env2 = 1; this.dec = this.e.dc(p.decay); this.dec2 = this.e.dc(p.decay * 0.3); this.n = 0; this.amp = p.level; }
  run() {
    this.n++;
    const atk = this.n < 30 ? this.n / 30 : 1;
    const sr = this.e.sr;
    this.p1 += this.f / sr; if (this.p1 >= 1) this.p1 -= 1;
    this.p2 += this.f * 2.76 / sr; if (this.p2 >= 1) this.p2 -= 1;
    this.p3 += this.f * 5.4 / sr; if (this.p3 >= 1) this.p3 -= 1;
    this.env *= this.dec; this.env2 *= this.dec2;
    return (Math.sin(TAU * this.p1) * this.env + Math.sin(TAU * this.p2) * this.env2 * 0.4 + Math.sin(TAU * this.p3) * this.env2 * this.env2 * 0.15) * atk * this.amp;
  }
  done() { return this.env < 0.001; }
}

function blep(t, dt) {
  if (t < dt) { t /= dt; return t + t - t * t - 1; }
  if (t > 1 - dt) { t = (t - 1) / dt; return t * t + t + t + 1; }
  return 0;
}

class Bass extends Voice {
  constructor(e) {
    super(e); this.f1 = new SVF(e.sr); this.f2 = new SVF(e.sr);
    this.ph = 0.5; this.sph = 0; this.inc = 0; this.incT = 0; this.gl = 1; this.env = 0; this.n = 0; this.len = 0; this.ce = 0; this.cdec = 0; this.rc = 0;
    this.amp = 0; this.cut = 300; this.cutEnd = 100; this.sub = 0; this.drive = 1; this.res = 1; this.ar = 0; this.sq = 0; this.ac = 0; this.acd = 0; this.acAmt = 0;
  }
  trig(p) {
    this.inc = this.incT = midi(p.note) / this.e.sr; this.gl = 1; this.ph = 0.5; this.sph = 0; this.env = 0; this.n = 0;
    this.len = p.len; this.amp = p.level; this.cut = p.cut; this.cutEnd = p.cutEnd; this.ce = 1; this.cdec = this.e.dc(p.cdecay);
    this.rc = this.e.dc(p.rel); this.sub = p.sub; this.drive = p.drive; this.res = p.res; this.ar = 1 / (0.0025 * this.e.sr);
    this.sq = p.square || 0; this.ac = p.accent ? 1 : 0; this.acd = this.e.dc(120); this.acAmt = p.accentAmt || 0;
  }
  slide(note, len) {
    this.incT = midi(note) / this.e.sr; this.gl = 1 - this.e.dc(55);
    this.len = this.n + len;
    if (this.ce < 0.35) this.ce = 0.35;
  }
  run() {
    this.n++;
    if (this.n < this.len) { this.env += this.ar; if (this.env > 1) this.env = 1; } else this.env *= this.rc;
    this.ce *= this.cdec; this.ac *= this.acd;
    if (this.gl < 1) this.inc += (this.incT - this.inc) * this.gl;
    if (!(this.n & 3)) {
      const fc = (this.cutEnd + (this.cut - this.cutEnd) * this.ce) * (1 + this.ac * this.acAmt);
      const q = this.res * (1 + this.ac * this.acAmt * 0.8);
      this.f1.set(fc, q); this.f2.set(fc * 1.3, 0.75);
    }
    this.ph += this.inc; if (this.ph >= 1) this.ph -= 1;
    let s = 2 * this.ph - 1 - blep(this.ph, this.inc);
    if (this.sq) { let q = this.ph + 0.5; if (q >= 1) q -= 1; s = (s - (2 * q - 1 - blep(q, this.inc))) * 0.6; }
    s = this.f2.run(this.f1.run(s));
    s = Math.tanh(s * this.drive * (1 + this.ac * this.acAmt * 0.5));
    this.sph += this.inc * 0.5; if (this.sph >= 1) this.sph -= 1;
    return (s * 0.65 + Math.sin(TAU * this.sph) * this.sub) * this.env * this.amp;
  }
  done() { return this.n > this.len && this.env < 0.0004; }
}

class Poly extends Voice {
  constructor(e) {
    super(e); this.f = new SVF(e.sr); this.ph = new Float64Array(12); this.inc = new Float64Array(12); this.cnt = 0; this.env = 0; this.n = 0; this.len = 0; this.ce = 0; this.lfo = 0; this.rel = false;
    this.amp = 0; this.cut = 1000; this.cutEnd = 500; this.cdec = 0; this.ar = 0; this.rc = 0; this.res = 0.7; this.lfoInc = 0; this.lfoAmt = 0; this.wave = 0; this.drive = 1; this.tri = 0;
  }
  trig(p) {
    const notes = p.notes; this.cnt = Math.min(12, notes.length * 2);
    for (let i = 0; i < notes.length && i * 2 + 1 < 12; i++) {
      const f = midi(notes[i]);
      this.inc[i * 2] = f * Math.pow(2, p.det / 1200) / this.e.sr; this.inc[i * 2 + 1] = f * Math.pow(2, -p.det / 1200) / this.e.sr;
      this.ph[i * 2] = this.e.rng.next(); this.ph[i * 2 + 1] = this.e.rng.next();
    }
    this.env = 0; this.n = 0; this.len = p.len; this.amp = p.level / Math.sqrt(notes.length);
    this.cut = p.cut; this.cutEnd = p.cutEnd; this.ce = 1; this.cdec = this.e.dc(p.cdecay);
    this.ar = 1 / (Math.max(0.002, p.attack) * this.e.sr); this.rc = this.e.dc(p.rel); this.res = p.res; this.rel = false;
    this.lfoInc = TAU * (p.lfo || 0) / this.e.sr; this.lfo = this.e.rng.next() * TAU; this.lfoAmt = p.lfoAmt || 0;
    this.wave = p.wave === 'sq' ? 1 : p.wave === 'tri' ? 2 : 0; this.drive = p.drive || 1;
  }
  release() { this.rel = true; }
  run() {
    this.n++;
    if (this.n < this.len && !this.rel) { this.env += this.ar; if (this.env > 1) this.env = 1; } else this.env *= this.rc;
    this.ce *= this.cdec;
    if (!(this.n & 7)) {
      this.lfo += this.lfoInc * 8; if (this.lfo > TAU) this.lfo -= TAU;
      const fc = (this.cutEnd + (this.cut - this.cutEnd) * this.ce) * (1 + this.lfoAmt * Math.sin(this.lfo));
      this.f.set(fc, this.res);
    }
    let s = 0;
    for (let i = 0; i < this.cnt; i++) {
      let ph = this.ph[i] + this.inc[i]; if (ph >= 1) ph -= 1; this.ph[i] = ph;
      let v;
      if (this.wave === 2) v = 4 * Math.abs(ph - 0.5) - 1;
      else {
        v = 2 * ph - 1 - blep(ph, this.inc[i]);
        if (this.wave === 1) { let q = ph + 0.5; if (q >= 1) q -= 1; v = (v - (2 * q - 1 - blep(q, this.inc[i]))) * 0.7; }
      }
      s += v;
    }
    s = this.f.run(s * 0.5);
    if (this.drive !== 1) s = Math.tanh(s * this.drive) / this.drive;
    return s * this.env * this.amp;
  }
  done() { return (this.n > this.len || this.rel) && this.env < 0.0004; }
}

class Riser extends Voice {
  constructor(e) { super(e); this.f = new SVF(e.sr); this.hp = new SVF(e.sr); this.n = 0; this.len = 1; this.env = 0; this.from = 100; this.to = 1000; this.amp = 0; }
  trig(p) { this.n = 0; this.len = p.len; this.from = p.from; this.to = p.to; this.amp = p.level; this.hp.set(200, 0.7); this.env = 1; }
  run() {
    this.n++;
    const u = Math.min(1, this.n / this.len);
    if (!(this.n & 15)) this.f.set(this.from * Math.pow(this.to / this.from, u), 1.6);
    if (this.n > this.len) this.env *= 0.9995;
    this.hp.run(this.f.run(this.e.noise.next()));
    return this.hp.hp * 1.8 * u * u * this.env * this.amp;
  }
  done() { return this.n > this.len && this.env < 0.002; }
}

class Impact extends Voice {
  constructor(e) { super(e); this.f = new SVF(e.sr); this.env = 0; this.dec = 0; this.ph = 0; this.benv = 0; this.bdec = 0; this.n = 0; this.amp = 0; this.bf = 110; }
  trig(p) { this.n = 0; this.env = 1; this.dec = this.e.dc(p.decay); this.f.set(p.lp, 0.6); this.ph = 0; this.benv = 1; this.bdec = this.e.dc(p.boom); this.amp = p.level; this.bf = 110; }
  run() {
    this.n++;
    const atk = this.n < 24 ? this.n / 24 : 1;
    this.env *= this.dec; this.benv *= this.bdec;
    this.bf += (44 - this.bf) * 0.0008;
    this.ph += this.bf / this.e.sr; if (this.ph >= 1) this.ph -= 1;
    const x = this.f.run(this.e.noise.next()) * this.env * 0.9 + Math.sin(TAU * this.ph) * this.benv * 0.9;
    return x * atk * this.amp;
  }
  done() { return this.env < 0.001 && this.benv < 0.001; }
}

class Comp {
  constructor(sr, thr, ratio, atk, rel) { this.thr = thr; this.k = 1 / ratio - 1; this.a = 1 - Math.exp(-1 / (atk * 0.001 * sr)); this.r = 1 - Math.exp(-1 / (rel * 0.001 * sr)); this.env = 0; this.g = 1; }
  run(x) {
    const a = Math.abs(x);
    this.env += (a - this.env) * (a > this.env ? this.a : this.r);
    const g = this.env > this.thr ? Math.pow(this.env / this.thr, this.k) : 1;
    this.g += (g - this.g) * 0.05;
    return x * this.g;
  }
}

function sum(pool) {
  let s = 0;
  for (let i = 0; i < pool.length; i++) { const v = pool[i]; if (v.on) s += v.out(); }
  return s;
}

class Engine {
  constructor(song, sr) {
    this.song = song; this.sr = sr;
    this.rng = new Rng(song.seed); this.noise = new Noise(song.seed * 7919 + 13);
    this.spb = 60 / song.bpm * sr; this.stepLen = this.spb / 4; this.barLen = this.spb * 4;
    this.dc = ms => Math.exp(-1 / (Math.max(0.01, ms) * 0.001 * sr));
    this.t = 0; this.stepIndex = 0; this.nextStepF = 0; this.nextStep = 0; this.bar = 0; this.step = 0;
    this.total = song.sections.reduce((a, s) => a + s.bars, 0);
    this.si = -1; this.sb = 0; this.sec = null; this.next = null; this.cur = {}; this.fill = 0; this.fillKind = ''; this.cutAt = -1;
    this.lpA = 20000; this.lpB = 20000; this.hpA = 20; this.hpB = 20; this.chord = song.chords.main[0]; this.root = song.roots.main[0]; this.pingStep = -1; this.bassRun = false;
    this.acid = null; this.acidCut = 1; this.acidTarget = 1; this.arpIdx = 0; this.arpDir = 1; this.arpNotes = [];
    this.kick = [new Kick(this), new Kick(this)];
    this.rumble = [new Rumble(this)];
    this.hat = [new Hat(this), new Hat(this), new Hat(this)];
    this.ohat = [new Hat(this), new Hat(this)];
    this.ride = [new Hat(this), new Hat(this)];
    this.clap = [new Clap(this), new Clap(this)];
    this.perc = [new Perc(this), new Perc(this), new Perc(this), new Perc(this)];
    this.shaker = [new Hat(this), new Hat(this)];
    this.bell = [new Bell(this), new Bell(this), new Bell(this)];
    this.bass = [new Bass(this), new Bass(this)];
    this.stab = [new Poly(this), new Poly(this)];
    this.pad = [new Poly(this), new Poly(this)];
    this.arp = [new Poly(this), new Poly(this), new Poly(this)];
    this.lead = [new Poly(this), new Poly(this)];
    this.padSlot = 0; this.padChord = null;
    this.riser = [new Riser(this)];
    this.impact = [new Impact(this)];
    this.groups = [this.kick, this.rumble, this.hat, this.ohat, this.clap, this.perc, this.shaker, this.bell, this.bass, this.stab, this.pad, this.riser, this.impact, this.arp, this.lead, this.ride];
    this.plate = new Plate(sr, song.fx.decay, song.fx.damp);
    this.dlN = Math.round(this.stepLen * song.fx.delaySteps); this.dl = new Line(this.dlN + 16); this.dlLp = 0; this.dlHp = 0;
    this.dlLpC = 1 - Math.exp(-TAU * 2600 / sr); this.dlHpC = 1 - Math.exp(-TAU * 220 / sr);
    this.lp = new SVF(sr); this.hp = new SVF(sr); this.lpHz = 20000; this.hpHz = 20;
    this.comp = new Comp(sr, song.fx.thr, song.fx.ratio, 4, 160);
    this.duckE = 0; this.duckDec = this.dc(190);
    this.gate = 1; this.gateT = 1;
    this.dcx = 0; this.dcy = 0;
    this.reset(0);
  }

  reset(start) {
    this.t = start;
    this.stepIndex = Math.round(start / this.stepLen);
    this.nextStepF = this.stepIndex * this.stepLen; this.nextStep = Math.round(this.nextStepF);
    this.bar = this.stepIndex >> 4; this.step = this.stepIndex & 15;
    for (const g of this.groups) for (const v of g) v.on = false;
    this.padChord = null; this.si = -1; this.cutAt = -1; this.gate = this.gateT = 1; this.duckE = 0;
    this.startBar();
  }

  section(bar) {
    let bi = bar % this.total, si = 0;
    const secs = this.song.sections;
    while (bi >= secs[si].bars) { bi -= secs[si].bars; si++; }
    return [si, bi];
  }

  choose(v) {
    if (!v) return 0;
    if (Array.isArray(v)) return this.rng.pick(v);
    return v;
  }

  genAcid() {
    const r = this.rng, song = this.song;
    const notes = song.acidNotes;
    const hits = [];
    let prevOn = false;
    for (let s = 0; s < 16; s++) {
      const on = s % 4 === 0 ? r.chance(0.8) : r.chance(0.62);
      if (!on) { prevOn = false; continue; }
      const n = r.pick(notes);
      const acc = r.chance(0.28);
      const slide = prevOn && r.chance(0.3);
      hits.push([s, n, r.chance(0.3) ? 2 : 1, acc, slide]);
      prevOn = true;
    }
    if (!hits.length) hits.push([0, 0, 2, 1, false]);
    return hits;
  }

  startBar() {
    const song = this.song, r = this.rng;
    const [si, bi] = this.section(this.bar);
    const secs = song.sections;
    const sec = secs[si];
    const fresh = si !== this.si || bi === 0;
    this.si = si; this.sb = bi; this.sec = sec; this.next = secs[(si + 1) % secs.length];
    if (fresh || bi % 4 === 0) {
      const c = this.cur;
      for (const k of ['kick', 'hat', 'ohat', 'clap', 'rim', 'shaker', 'perc', 'ride', 'bass', 'stab', 'arp', 'lead', 'keys']) c[k] = this.choose(sec[k]);
      c.ghost = r.chance(0.5);
      c.arpMode = r.pick(['up', 'updown', 'random', 'up']);
      if (sec.acid && (!this.acid || bi % 8 === 0 || r.chance(0.35))) this.acid = this.genAcid();
      if (sec.acid && this.acid && r.chance(0.5)) {
        const h = r.pick(this.acid);
        h[1] = r.pick(song.acidNotes); h[3] = r.chance(0.3);
      }
    }
    if (sec.acid) {
      const a = sec.acid;
      const u = (bi + 0.5) / sec.bars;
      const curve = a[2] === 'tri' ? 1 - Math.abs(u * 2 - 1) : u;
      this.acidTarget = a[0] * Math.pow(a[1] / a[0], curve) * (1 + r.spread(0.25));
    }
    const last = bi === sec.bars - 1;
    const eight = bi % 8 === 7 && sec.bars > 8;
    this.fill = last ? 2 : eight ? 1 : 0;
    this.fillKind = this.fill ? r.pick(sec.fills || song.fills) : '';
    this.cutAt = this.fill === 2 && this.next.impact && r.chance(0.7) ? r.pick([14, 13, 12]) : -1;
    const lp = sec.lp || [20000, 20000], hp = sec.hp || [20, 20];
    const u0 = bi / sec.bars, u1 = (bi + 1) / sec.bars;
    this.lpA = lp[0] * Math.pow(lp[1] / lp[0], u0); this.lpB = lp[0] * Math.pow(lp[1] / lp[0], u1);
    this.hpA = hp[0] * Math.pow(hp[1] / hp[0], u0); this.hpB = hp[0] * Math.pow(hp[1] / hp[0], u1);
    const prog = sec.prog || 'main';
    const ci = (bi >> 1) % song.chords[prog].length;
    this.chord = song.chords[prog][ci];
    this.root = song.roots[prog][ci];
    this.pingStep = sec.pings && r.chance(sec.pings) ? r.pick([3, 6, 7, 10, 11, 13, 15]) : -1;
    this.bassRun = this.fill === 2 && this.fillKind === 'bassrun';
    const an = this.chord.slice(1);
    this.arpNotes = an.concat(an.map(n => n + 12));
    if (bi % 2 === 0) { this.arpIdx = 0; this.arpDir = 1; }
  }

  fire(pool, delay, p) {
    let v = pool[0];
    for (const x of pool) { if (!x.on) { v = x; break; } if (x.born < v.born) v = x; }
    v.start(delay, p);
    return v;
  }

  pat(name, group) {
    if (!name) return null;
    const p = this.song.pat[group][name];
    if (!p) return null;
    return Array.isArray(p) ? p[this.bar & 1 ? 1 : 0] || p[0] : p;
  }

  vel(pattern, s) { return pattern ? VEL[pattern[s]] || 0 : 0; }

  nextArp(mode) {
    const n = this.arpNotes.length;
    const r = this.rng;
    if (mode === 'random') return this.arpNotes[(r.next() * n) | 0];
    const i = this.arpIdx;
    if (mode === 'up') this.arpIdx = (i + 1) % n;
    else { this.arpIdx = i + this.arpDir; if (this.arpIdx >= n) { this.arpIdx = n - 2; this.arpDir = -1; } if (this.arpIdx < 0) { this.arpIdx = 1; this.arpDir = 1; } }
    return this.arpNotes[i % n];
  }

  fireStep() {
    const s = this.step;
    if (s === 0) this.startBar();
    const song = this.song, sec = this.sec, c = this.cur, r = this.rng, k = song.kit;
    const sw = (s & 1) ? (sec.swing ?? song.swing) * this.stepLen : 0;
    const hum = () => sw + r.spread(0.0022 * this.sr);
    const vh = () => 1 + r.spread(0.09);
    const steps16 = s >= 12;
    if (s === 0 && this.sb === 0 && sec.impact) this.fire(this.impact, 1, k.impact);
    if (s === 0 && sec.riser && this.sb === sec.bars - sec.riser) this.fire(this.riser, 1, { ...k.riser, len: Math.round(sec.riser * this.barLen) });
    const kickPat = this.fill && this.fillKind === 'kickpush' ? this.pat('push', 'kick') : this.pat(c.kick, 'kick');
    const kv = this.vel(kickPat, s);
    if (kv) {
      this.fire(this.kick, 1, { ...k.kick, level: k.kick.level * kv * (1 + r.spread(0.03)) });
      if (sec.rumble) this.fire(this.rumble, Math.round(this.sr * 0.018), { ...k.rumble, level: k.rumble.level * sec.rumble });
    }
    if (this.cutAt >= 0 && s === this.cutAt) this.gateT = 0;
    if (s === 0) this.gateT = 1;
    const hatPat = this.pat(c.hat, 'hat');
    let hv = this.vel(hatPat, s);
    if (this.fill && this.fillKind === 'hatroll' && steps16) hv = 0.5 + (s - 12) * 0.2;
    if (!hv && c.ghost && hatPat && (s & 1) && r.chance(0.18)) hv = 0.3;
    if (hv) this.fire(this.hat, hum(), { ...k.hat, level: k.hat.level * hv * vh(), decay: k.hat.decay * (0.8 + r.next() * 0.5) });
    const ov = this.vel(this.pat(c.ohat, 'ohat'), s);
    if (ov) this.fire(this.ohat, hum(), { ...k.ohat, level: k.ohat.level * ov * vh() });
    const rv = this.vel(this.pat(c.ride, 'ride'), s);
    if (rv) this.fire(this.ride, hum(), { ...k.ride, level: k.ride.level * rv * vh() });
    let cv = this.vel(this.pat(c.clap, 'clap'), s);
    if (this.fill === 2 && this.fillKind === 'claproll' && steps16) cv = 0.55 + (s - 12) * 0.15;
    if (this.fill && this.fillKind === 'snareroll' && s >= 8) cv = (s & 1) ? 0 : 0.4 + (s - 8) * 0.08;
    if (cv) this.fire(this.clap, hum() * 0.5, { ...k.clap, level: k.clap.level * cv * vh() });
    const rimv = this.vel(this.pat(c.rim, 'rim'), s);
    if (rimv) this.fire(this.perc, hum(), { ...k.rim, level: k.rim.level * rimv * vh() });
    const pv = this.vel(this.pat(c.perc, 'perc'), s);
    if (pv) this.fire(this.perc, hum(), { ...k.perc, level: k.perc.level * pv * vh(), freq: k.perc.freq * (pv > 0.9 ? 1 : 1.32) });
    if (this.fill && this.fillKind === 'percburst' && steps16 && (s & 1)) this.fire(this.perc, hum(), { ...k.perc, level: k.perc.level * 0.8, freq: k.perc.freq * (1 + (s - 12) * 0.2) });
    const shv = this.vel(this.pat(c.shaker, 'shaker'), s);
    if (shv) this.fire(this.shaker, hum() + r.spread(0.002 * this.sr), { ...k.shaker, level: k.shaker.level * shv * vh() });
    const oct = song.bassOct || 0;
    if (this.bassRun && steps16) {
      const n = this.root + [0, 3, 5, 7][s - 12] + oct;
      this.fire(this.bass, hum() * 0.4, { ...k.bass, note: n, len: Math.round(this.stepLen * 0.8), level: k.bass.level * 0.9, cut: k.bass.cut * 1.3 });
    } else if (sec.acid && this.acid) {
      this.acidCut += (this.acidTarget - this.acidCut) * 0.3;
      for (const h of this.acid) if (h[0] === s) {
        const len = Math.round(this.stepLen * h[2] * (h[4] ? 1.05 : 0.6));
        const live = this.bass.find(v => v.on && v.n < v.len && !v.fading);
        if (h[4] && live) { live.slide(this.root + h[1] + oct, len); continue; }
        this.fire(this.bass, hum() * 0.3, { ...k.bass, note: this.root + h[1] + oct, len, level: k.bass.level * (h[3] ? 1.15 : 0.9), cut: k.bass.cut * this.acidCut * (h[3] ? 1.5 : 1), accent: h[3] });
      }
    } else if (c.bass) {
      const bassPat = song.pat.bass[c.bass];
      for (const h of bassPat) if (h[0] === s) {
        const acc = h[3] ? 1 : 0;
        this.fire(this.bass, hum() * 0.4, { ...k.bass, note: this.root + h[1] + oct, len: Math.round(this.stepLen * h[2] * 0.82), level: k.bass.level * (0.85 + acc * 0.25) * (1 + r.spread(0.05)), cut: k.bass.cut * (acc ? 1.7 : 1) });
      }
    }
    const stabPat = this.pat(c.stab, 'stab');
    const sv = this.vel(stabPat, s);
    if (sv) {
      const dub = typeof c.stab === 'string' && c.stab.startsWith('sd');
      const inv = this.bar & 2 ? 12 : 0;
      const notes = this.chord.slice(1).map(n => n + inv);
      this.fire(this.stab, hum() * 0.6, { ...k.stab, notes, len: Math.round(this.stepLen * (dub ? 6 : 1.4)), level: k.stab.level * sv * (dub ? 0.85 : 1) * vh(), send: dub ? 0.95 : k.stab.send });
    }
    const keysPat = this.pat(c.keys, 'keys');
    const kyv = this.vel(keysPat, s);
    if (kyv) {
      const notes = this.chord.slice(0, 4).map(n => n + 12);
      this.fire(this.stab, hum() * 0.5, { ...k.keys, notes, len: Math.round(this.stepLen * 3), level: k.keys.level * kyv * vh(), send: k.keys.send });
    }
    const arpPat = this.pat(c.arp, 'arp');
    const av = this.vel(arpPat, s);
    if (av) {
      const n = this.nextArp(c.arpMode);
      this.fire(this.arp, hum() * 0.5, { ...k.arp, notes: [n], len: Math.round(this.stepLen * 0.7), level: k.arp.level * av * vh() });
    }
    const leadPat = c.lead ? song.pat.lead[c.lead] : null;
    if (leadPat) {
      const ls = (this.sb & 1) * 16 + s;
      for (const h of leadPat) if (h[0] === ls) this.fire(this.lead, hum() * 0.3, { ...k.lead, notes: [h[1]], len: Math.round(this.stepLen * h[2] * 0.9), level: k.lead.level * (h[3] || 1) });
    }
    if (s === 0 && sec.pad) {
      const changed = this.padChord !== this.chord;
      if (changed || !this.pad[this.padSlot].on) {
        if (this.pad[this.padSlot].on) this.pad[this.padSlot].release();
        this.padSlot ^= 1;
        this.fire(this.pad, 1, { ...k.pad, notes: this.chord.slice(0, 4).map(n => n - 12 * (k.pad.drop || 0)), len: 1e9, level: k.pad.level * sec.pad });
        this.padChord = this.chord;
      }
    }
    if (s === 0 && !sec.pad && this.padChord) { for (const p of this.pad) if (p.on) p.release(); this.padChord = null; }
    if (s === this.pingStep) {
      const n = r.pick(this.chord) + 24;
      this.fire(this.bell, hum(), { ...k.bell, note: n, level: k.bell.level * (0.7 + r.next() * 0.5) });
    }
    this.step = (s + 1) & 15;
    if (this.step === 0) this.bar++;
  }

  skip(buf, off, n) {
    for (let i = 0; i < n; i++) {
      while (this.t >= this.nextStep) { this.fireStep(); this.nextStepF += this.stepLen; this.nextStep = Math.round(this.nextStepF); }
      buf[off + i] = 0;
      this.t++;
    }
    for (const g of this.groups) for (const v of g) v.on = false;
    this.padChord = null; this.duckE = 0; this.gate = this.gateT = 1;
  }

  render(buf, off, n) {
    const fx = this.song.fx;
    const grp = this.groups;
    for (let i = 0; i < n; i++) {
      while (this.t >= this.nextStep) { this.fireStep(); this.nextStepF += this.stepLen; this.nextStep = Math.round(this.nextStepF); }
      if (!(this.t & 31)) {
        const uu = clamp((this.step - 1 + (this.t - (this.nextStep - this.stepLen)) / this.stepLen) / 16, 0, 1);
        const lpT = this.lpA * Math.pow(this.lpB / this.lpA, uu);
        const hpT = this.hpA * Math.pow(this.hpB / this.hpA, uu);
        this.lpHz += (lpT - this.lpHz) * 0.08; this.hpHz += (hpT - this.hpHz) * 0.08;
        this.lp.set(this.lpHz, 0.8); this.hp.set(this.hpHz, 0.75);
      }
      const kick = sum(grp[0]) + sum(grp[1]);
      const hats = sum(grp[2]) + sum(grp[3]) + sum(grp[6]) + sum(grp[15]);
      const perc = sum(grp[4]) + sum(grp[5]);
      const bell = sum(grp[7]);
      const bass = sum(grp[8]);
      const stab = sum(grp[9]);
      const pad = sum(grp[10]);
      const air = sum(grp[11]) + sum(grp[12]);
      const arp = sum(grp[13]);
      const lead = sum(grp[14]);
      this.duckE *= this.duckDec;
      const dk = 1 - fx.duck * this.duckE;
      this.gate += (this.gateT - this.gate) * 0.004;
      const g = this.gate;
      const dIn = stab * fx.stabSend + perc * fx.percSend + bell * 0.6 + arp * fx.arpSend + lead * fx.leadSend + hats * 0.04;
      const d = this.dl.at(this.dlN);
      let w = dIn + d * fx.feedback;
      this.dlLp += (w - this.dlLp) * this.dlLpC; w = this.dlLp;
      this.dlHp += (w - this.dlHp) * this.dlHpC; w -= this.dlHp;
      this.dl.push(w);
      const rIn = perc * fx.percRev + stab * fx.stabRev + pad * fx.padRev + air * 0.5 + bell * 0.5 + d * 0.3 + hats * fx.hatRev + kick * fx.kickRev + arp * fx.arpRev + lead * fx.leadRev;
      const rev = this.plate.run(rIn);
      let x = (kick + bass + hats + perc + bell) * g + (stab + pad + arp + lead + d * fx.delayLevel) * dk * g + rev * fx.revLevel * (0.6 + 0.4 * dk) + air;
      this.hp.run(x); x = this.hp.hp;
      x = this.lp.run(x);
      x = Math.tanh(this.comp.run(x) * fx.makeup);
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
