(() => {
  const top = document.querySelector('.top');
  const button = top && top.querySelector('.menu-btn');
  const links = document.getElementById('site-links');
  if (!button || !links) return;
  const wide = matchMedia('(min-width: 601px)');
  const isOpen = () => button.getAttribute('aria-expanded') === 'true';
  const set = open => {
    button.setAttribute('aria-expanded', String(open));
    top.classList.toggle('menu-open', open);
  };
  top.classList.add('menu-ready');
  button.addEventListener('click', () => set(!isOpen()));
  links.addEventListener('click', e => { if (e.target.closest('a')) set(false); });
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && isOpen()) { set(false); button.focus(); }
  });
  document.addEventListener('pointerdown', e => { if (isOpen() && !top.contains(e.target)) set(false); });
  top.addEventListener('focusout', e => { if (isOpen() && e.relatedTarget && !top.contains(e.relatedTarget)) set(false); });
  wide.addEventListener('change', () => set(false));
})();
