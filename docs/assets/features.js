import { createScreens } from './screens.js';
import { createAudio } from './audio.js';
import { wireSound } from './sound.js';

const root = document.documentElement;
const base = new URL('.', import.meta.url).href;
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));

wireSound(createAudio(base));

const coarse = matchMedia('(pointer: coarse)').matches;
const panes = createScreens({ base, opaque: true });
if (coarse) { panes.resize('phone', 480); panes.resize('pad', 1024); panes.resize('watch', 320); }
panes.time(4);
panes.set('phone', { ph: 'play' });
panes.set('pad', { pad: 'play' });
panes.set('watch', { w: 'remote' });
for (const name of ['tv', 'mac', 'friend']) panes.show(name, false);

const mirrors = $$('canvas[data-mirror]').map(cv => ({ cv, name: cv.dataset.mirror }));
function copy(name) {
  const src = panes.canvas(name);
  for (const m of mirrors) {
    if (m.name !== name) continue;
    if (m.cv.width !== src.width || m.cv.height !== src.height) { m.cv.width = src.width; m.cv.height = src.height; }
    const x = m.cv.getContext('2d');
    x.clearRect(0, 0, src.width, src.height);
    x.drawImage(src, 0, 0);
  }
}
let left = 0;
function paint() {
  const done = panes.step(1 / 30);
  done.forEach(copy);
  if (done.length || left-- > 0) requestAnimationFrame(paint);
}
left = 90;
paint();
panes.ready.then(() => { left = 30; requestAnimationFrame(paint); });

if (root.classList.contains('ease')) {
  const devs = $$('.plat .dev');
  let raf = 0;
  const update = () => {
    raf = 0;
    const vh = innerHeight;
    for (const el of devs) {
      const r = el.getBoundingClientRect();
      const t = clamp((vh - r.top) / (vh * 0.55));
      el.style.setProperty('--in', (t * t * (3 - 2 * t)).toFixed(3));
    }
  };
  addEventListener('scroll', () => { if (!raf) raf = requestAnimationFrame(update); }, { passive: true });
  addEventListener('resize', update);
  update();
  matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', e => { if (e.matches) { root.classList.remove('ease'); devs.forEach(el => el.style.removeProperty('--in')); } });
}
