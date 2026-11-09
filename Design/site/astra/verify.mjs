// Reproducible local checks. Start Chrome with --remote-debugging-port=9236 first.
// Uses Node's built-in WebSocket. No packages or external network requests.
import { writeFile } from 'node:fs/promises';

const directory = new URL('./', import.meta.url);
const targets = await fetch('http://127.0.0.1:9236/json').then(r => r.json());
const target = targets.find(t => t.type === 'page');
if (!target) throw new Error('Start headless Chrome on local debugging port 9236.');
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
let sequence = 0;
const pending = new Map();
const errors = [];
const requests = [];
socket.onmessage = ({ data }) => {
  const message = JSON.parse(data);
  if (message.id) {
    const call = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) call.reject(message.error); else call.resolve(message.result);
  } else {
    if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails.text);
    if (message.method === 'Network.requestWillBeSent' && /^https?:/.test(message.params.request.url)) requests.push(message.params.request.url);
  }
};
function send(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });
}
async function evaluate(expression) {
  const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
async function viewport(width, height = 900) {
  await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: width < 600 });
}
async function media(scheme, motion = 'no-preference') {
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }, { name: 'prefers-reduced-motion', value: motion }] });
}
async function screenshot(name, full = false) {
  const height = full ? await evaluate('document.documentElement.scrollHeight') : 3200;
  const width = await evaluate('innerWidth');
  const { data } = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: 0, y: 0, width, height, scale: 1 } });
  await writeFile(new URL(name, directory), Buffer.from(data, 'base64'));
}
await send('Emulation.setScriptExecutionDisabled', { value: false });
await send('Page.enable');
await send('Runtime.enable');
await send('Network.enable');
await viewport(1440);
await media('light', 'reduce');
await send('Page.navigate', { url: new URL('index.html', directory).href });
await evaluate(`new Promise(resolve => {
  const ready = async () => {
    localStorage.removeItem('sounding-appearance');
    delete document.documentElement.dataset.theme;
    await Promise.all([...document.images].map(image => { image.loading = 'eager'; return image.decode().catch(() => {}); }));
    resolve(true);
  };
  if (document.readyState === 'complete') ready(); else addEventListener('load', ready, { once: true });
})`);
const report = { viewports: [], errors, externalPageRequests: requests };
for (const width of [320, 390, 768, 1024, 1440]) {
  await viewport(width);
  const state = await evaluate(`({ width: innerWidth, scrollWidth: document.documentElement.scrollWidth,
    brokenImages: [...document.images].filter(i => !i.complete || i.naturalWidth === 0).map(i => i.getAttribute('src')),
    overflows: [...document.querySelectorAll('body *')].filter(el => {
      if (el.closest('svg,.hero-art,.offline-card,.closing,.skip-link')) return false;
      const rect = el.getBoundingClientRect(); return rect.width && (rect.right > innerWidth + 1 || rect.left < -1);
    }).map(el => el.className || el.tagName)
  })`);
  report.viewports.push(state);
}
report.reducedMotion = await evaluate(`({ matches: matchMedia('(prefers-reduced-motion: reduce)').matches, activeAnimations: document.getAnimations().filter(a => a.playState === 'running').length })`);
report.anchors = await evaluate(`({ broken: [...document.querySelectorAll('a[href^="#"]')].filter(a => a.hash && !document.getElementById(a.hash.slice(1))).map(a=>a.hash) })`);
await viewport(1440, 3200);
await screenshot('shot-desktop.png');
await screenshot('shot-desktop-full.png', true);
await viewport(390, 3200);
await screenshot('shot-mobile.png');
await screenshot('shot-mobile-full.png', true);
await media('dark', 'reduce');
report.dark = await evaluate(`({ background: getComputedStyle(document.body).backgroundColor, colour: getComputedStyle(document.body).color })`);
await screenshot('shot-mobile-dark.png', true);
await viewport(1440, 3200);
await screenshot('shot-desktop-dark.png', true);
await media('light', 'no-preference');
report.motion = await evaluate(`({ duration: getComputedStyle(document.querySelector('.reveal-sweep')).animationDuration, revealTransform: getComputedStyle(document.querySelector('.reveal-sweep')).transform })`);
await send('Page.bringToFront');
report.focus = await evaluate(`document.querySelector('summary').focus(); ({tag:document.activeElement.tagName, focused:document.hasFocus()})`);
await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r', unmodifiedText: '\r' });
await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
report.keyboardFAQ = await evaluate(`document.querySelector('details').open`);
await evaluate(`document.querySelector('.theme-button').focus()`);
await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r', unmodifiedText: '\r' });
await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
report.keyboardTheme = await evaluate(`document.documentElement.dataset.theme === 'light'`);
await evaluate(`localStorage.removeItem('sounding-appearance'); delete document.documentElement.dataset.theme; document.querySelector('details').open = false;`);
report.passed = report.viewports.every(v => v.width === v.scrollWidth && !v.brokenImages.length && !v.overflows.length) && !errors.length && !requests.length && report.keyboardFAQ && report.keyboardTheme && !report.anchors.broken.length && report.reducedMotion.activeAnimations === 0;
await writeFile(new URL('verification.json', directory), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
socket.close();
if (!report.passed) process.exitCode = 1;
