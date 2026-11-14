export function wireSound(audio) {
  const buttons = [...document.querySelectorAll('[data-sound]')];
  if (!buttons.length || !window.AudioWorkletNode) return;
  document.documentElement.classList.add('snd-ok');
  let busy = false;
  const label = () => buttons.forEach(b => {
    b.setAttribute('aria-pressed', String(audio.on));
    const s = b.querySelector('span');
    if (s) s.textContent = audio.on ? 'Sound on' : 'Sound off';
  });
  const toggle = () => {
    if (busy) return;
    if (audio.on) { audio.stop(); label(); return; }
    busy = true;
    audio.start().then(label, label).finally(() => { busy = false; });
  };
  buttons.forEach(b => b.addEventListener('click', toggle));
  document.addEventListener('visibilitychange', () => { if (document.hidden && audio.on) { audio.stop(); label(); } });
}
