(() => {
  const root = document.documentElement;
  if (!root.classList.contains('live')) return;
  const deep = () => root.classList.toggle('deep', scrollY > 24);
  addEventListener('scroll', deep, { passive: true });
  addEventListener('resize', deep);
  deep();
})();
