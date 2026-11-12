(() => {
  const root = document.documentElement;
  const KEY = 'sounding.side';
  const dark = matchMedia('(prefers-color-scheme: dark)');
  const range = document.querySelector('[data-xf-range]');
  const buttons = [...document.querySelectorAll('[data-xf]')];
  const theme = document.querySelector('meta[name="theme-color"]');
  const stored = () => { try { return localStorage.getItem(KEY); } catch { return null; } };
  const show = (b, dragging) => {
    root.dataset.side = b ? 'b' : 'a';
    buttons.forEach(x => x.setAttribute('aria-pressed', String((x.dataset.xf === '1') === b)));
    if (range && !dragging) range.value = b ? 1000 : 0;
    if (theme) theme.setAttribute('content', b ? '#110e0c' : '#f6f1e8');
  };
  const pick = b => { show(b); try { localStorage.setItem(KEY, b ? 'b' : 'a'); } catch {} };
  buttons.forEach(x => x.addEventListener('click', () => pick(x.dataset.xf === '1')));
  if (range) {
    range.addEventListener('input', () => show(+range.value > 500, true));
    range.addEventListener('change', () => pick(+range.value > 500));
  }
  dark.addEventListener('change', e => { if (!stored()) show(e.matches); });
  const s = stored();
  show(s ? s === 'b' : dark.matches);
})();
