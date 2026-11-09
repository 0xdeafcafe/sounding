(() => {
  const { M } = Cable;

  const depthOf = el => {
    const c = el.classList;
    if (c.contains('mass')) return -260;
    if (c.contains('cone') || c.contains('wave')) return -150;
    if (c.contains('ring')) return -70;
    if (c.contains('signal')) return -20;
    if (c.contains('plug')) return 20;
    if (c.contains('knurl')) return 300;
    return 0;
  };

  function plates(ctx) {
    const stack = ctx.layers.root;
    const all = [...stack.children];
    let ci = 0;
    return all.map((el, i) => {
      let z = depthOf(el);
      if (el.classList.contains('contour')) z = 70 + ci++ * 52;
      if (el.classList.contains('mass')) z -= (2 - ctx.layers.masses.indexOf(el)) * 30;
      const r = Cable.params && window.SoundingArt.Random(i * 7 + 3);
      const mx = r.in(-1, 1) * ctx.geo.s * 0.03, my = r.in(-1, 1) * ctx.geo.s * 0.03;
      return { el, z, mx, my };
    });
  }

  function play(ctx) {
    const { geo, layers } = ctx;
    const stack = layers.root;
    const P = plates(ctx);
    const spring = M.springEasing({ zeta: 0.78, response: 1.05 });
    const view = 'rotateX(56deg) rotateZ(-34deg) scale(.72)';
    M.animate(stack, [{ transform: view }, { transform: view, offset: 0.12 }, { transform: 'none' }], { duration: 1750, easing: M.ease.inOut });
    const pressAt = 1700;
    M.animate(stack, [{ transform: 'none' }, { transform: 'scale(.985)', offset: 0.25 }, { transform: 'none' }], { delay: pressAt, duration: 420, easing: 'ease-out', composite: 'add', fill: 'none' });
    P.forEach((p, i) => {
      const from = `translate3d(${p.mx.toFixed(1)}px, ${p.my.toFixed(1)}px, ${p.z * 1.6}px)`;
      const mid = `translate3d(${p.mx.toFixed(1)}px, ${p.my.toFixed(1)}px, 0px)`;
      const order = P.length - i;
      M.animate(p.el, [
        { transform: from, opacity: 0 },
        { transform: from, opacity: 1, offset: 0.12 },
        { transform: mid, opacity: 1, offset: 0.86, easing: 'cubic-bezier(.3,0,.1,1)' },
        { transform: 'none', opacity: 1 },
      ], { delay: order * 18, duration: pressAt - order * 18 + 160, easing: M.ease.inOut });
    });
    layers.rings.forEach((el, i) => M.animate(el, [{ transform: 'none' }, { transform: 'scale(1.03)', offset: 0.3 }, { transform: 'none' }], { delay: pressAt + 80 + i * 40, duration: 600, easing: 'ease-out', composite: 'add', fill: 'none' }));
    ctx.idle(ctx, { delay: pressAt + 700, masses: false });
    M.after(pressAt + 600, () => tilt(ctx, P));
  }

  function tilt(ctx, P) {
    if (!matchMedia('(pointer: fine)').matches || M.simTime != null) return;
    const hero = document.querySelector('.hero');
    const stack = ctx.layers.root;
    let tx = 0, ty = 0, x = 0, y = 0, active = false;
    hero.onpointermove = e => {
      const r = ctx.host.getBoundingClientRect();
      tx = Math.max(-1, Math.min(1, (e.clientX - r.left) / r.width * 2 - 1));
      ty = Math.max(-1, Math.min(1, (e.clientY - r.top) / r.height * 2 - 1));
      if (!active) { active = true; loop(); }
    };
    hero.onpointerleave = () => { tx = 0; ty = 0; };
    P.forEach(p => (p.el.style.willChange = 'transform'));
    const loop = () => M.loop(dt => {
      const k = 1 - Math.exp(-dt * 6);
      x += (tx - x) * k; y += (ty - y) * k;
      const amt = Math.hypot(x, y);
      stack.style.transform = `rotateX(${(-y * 5).toFixed(3)}deg) rotateY(${(x * 6).toFixed(3)}deg)`;
      P.forEach(p => (p.el.style.transform = `translateZ(${(p.z * 0.09 * Math.min(1, amt * 1.5)).toFixed(2)}px)`));
      if (amt < 0.002 && tx === 0 && ty === 0) { active = false; return false; }
    });
  }

  Cable.page({
    id: 'v6',
    title: 'Press',
    shells: ['zine', 'club'],
    buildOptions: () => ({
      root: host => {
        host.style.perspective = '1600px';
        const s = document.createElement('div');
        s.className = 'stack';
        s.style.cssText = 'position:absolute;inset:0;transform-style:preserve-3d';
        host.appendChild(s);
        return s;
      },
    }),
    play,
  });
})();
