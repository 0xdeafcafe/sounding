/* Progressive enhancement: content, navigation and FAQs work without JavaScript. */
(() => {
  const root = document.documentElement;
  const button = document.querySelector('.theme-button');
  const themeColour = document.querySelector('meta[name="theme-color"]');
  const system = window.matchMedia('(prefers-color-scheme: dark)');
  const themes = ['system', 'light', 'dark'];
  let theme = 'system';

  // Storage can be unavailable for a local file or in a private browser session.
  try {
    const saved = localStorage.getItem('sounding-appearance');
    if (themes.includes(saved)) theme = saved;
  } catch { /* Follow the operating system. */ }

  function applyAppearance() {
    if (theme === 'system') delete root.dataset.theme;
    else root.dataset.theme = theme;
    const next = themes[(themes.indexOf(theme) + 1) % themes.length];
    button.setAttribute('aria-label', `Appearance: ${theme}. Switch to ${next}.`);
    button.title = `Appearance: ${theme}. Switch to ${next}.`;
    const dark = theme === 'dark' || (theme === 'system' && system.matches);
    themeColour.content = dark ? '#1c201d' : '#f5f1e9';
  }

  if (button) {
    applyAppearance();
    button.hidden = false;
    button.addEventListener('click', () => {
      theme = themes[(themes.indexOf(theme) + 1) % themes.length];
      try { localStorage.setItem('sounding-appearance', theme); } catch { /* Optional preference. */ }
      applyAppearance();
    });
    system.addEventListener('change', applyAppearance);
  }
})();
