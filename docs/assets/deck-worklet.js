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
    this.loop = null;
    this.scr = null;
    this.pos = 0;
    this.ref = 0;
    this.old = 0;
    this.r = 1;
    this.m = 1;
    this.mix = 0;
    this.locked = true;
    this.sg = 0;
    this.tick = 0;
    this.port.onmessage = e => {
      if (e.data.loop) { this.loop = e.data.loop; this.scr = e.data.scr; }
      if (e.data.ref != null) { this.ref = e.data.ref; this.pos = e.data.ref; }
    };
  }

  read(buf, p) {
    const n = buf.length;
    p -= Math.floor(p / n) * n;
    const i = p | 0;
    const f = p - i;
    const a = buf[i], b = buf[i + 1 < n ? i + 1 : 0];
    return a + (b - a) * f;
  }

  process(inputs, outputs, params) {
    const out = outputs[0][0];
    if (!this.loop) return true;
    const rate = params.rate[0], master = params.master[0], slip = params.slip[0] > 0.5, scratch = params.scratch[0];
    const n = this.loop.length;
    if (slip && this.locked) { this.locked = false; this.pos = this.ref; this.mix = 0; }
    if (!slip && !this.locked) { this.locked = true; this.old = this.pos; this.mix = 1; }
    for (let i = 0; i < out.length; i++) {
      this.r += (rate - this.r) * 0.006;
      this.m += (master - this.m) * 0.002;
      this.sg += (scratch - this.sg) * 0.003;
      this.ref += this.m;
      if (this.ref >= n) this.ref -= n;
      let v;
      if (this.locked) {
        v = this.read(this.loop, this.ref);
        if (this.mix > 0) {
          this.old += this.r;
          v = v * (1 - this.mix) + this.read(this.loop, this.old) * this.mix;
          this.mix -= 1 / 1400;
        }
        this.pos = this.ref;
      } else {
        this.pos += this.r;
        v = this.read(this.loop, this.pos);
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
