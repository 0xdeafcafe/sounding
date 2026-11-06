(() => {
  const root = document.documentElement;
  const base = document.currentScript ? document.currentScript.src.replace(/site\.js(\?.*)?$/, '') : 'assets/';

  const button = document.querySelector('.theme-button');
  if (button) {
    const colour = document.querySelector('meta[name="theme-color"]');
    const status = document.querySelector('.theme-status');
    const system = matchMedia('(prefers-color-scheme: dark)');
    const themes = ['system', 'light', 'dark'];
    let theme = 'system';
    try {
      const saved = localStorage.getItem('sounding-appearance');
      if (themes.includes(saved)) theme = saved;
    } catch (error) {}

    const apply = announce => {
      if (theme === 'system') delete root.dataset.theme;
      else root.dataset.theme = theme;
      const next = themes[(themes.indexOf(theme) + 1) % themes.length];
      const label = `Appearance: ${theme}. Switch to ${next}.`;
      button.setAttribute('aria-label', label);
      button.title = label;
      if (colour) colour.content = theme === 'dark' || (theme === 'system' && system.matches) ? '#1c201d' : '#f5f1e9';
      if (announce && status) status.textContent = `Appearance set to ${theme}.`;
    };

    button.hidden = false;
    apply(false);
    button.addEventListener('click', () => {
      theme = themes[(themes.indexOf(theme) + 1) % themes.length];
      try { localStorage.setItem('sounding-appearance', theme); } catch (error) {}
      apply(true);
    });
    system.addEventListener('change', () => apply(false));
  }

  const slot = document.querySelector('[data-np-slot]');
  if (slot) {
    let started = false;
    const load = () => {
      if (started) return;
      started = true;
      const sheet = document.createElement('link');
      sheet.rel = 'stylesheet';
      sheet.href = `${base}player.css`;
      const script = document.createElement('script');
      script.src = `${base}player.js`;
      const finish = () => {
        slot.removeAttribute('data-np-slot');
        document.head.appendChild(script);
      };
      sheet.onload = finish;
      sheet.onerror = finish;
      document.head.appendChild(sheet);
    };
    if ('IntersectionObserver' in window && location.hash !== '#now-playing') {
      const observer = new IntersectionObserver(entries => {
        if (entries.some(entry => entry.isIntersecting)) {
          observer.disconnect();
          load();
        }
      }, { rootMargin: '700px 0px' });
      observer.observe(slot);
    } else {
      load();
    }
  }
})();
