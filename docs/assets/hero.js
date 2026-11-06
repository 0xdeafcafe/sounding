(() => {
  const host = document.querySelector('[data-hero]');
  if (!host) return;

  const PLUG = 'M192 436 214 396 242 348 330 260 344 272 418 198 410 190 438 162 446 170 465 151 457 143 482 118 505 115 518 128 515 151 490 176 482 168 463 187 471 195 443 223 435 215 361 289 373 303 285 391 238 416 214 456';
  const CABLE = 'M192 436C155 475 97 526 124 562C166 619 456 578 672 500M214 456C179 495 143 527 157 545C190 585 465 554 672 477';
  const HATCH = 'm250 340 44 44m-35-53 44 44m-35-53 44 44m-35-53 44 44m-35-53 44 44m-35-53 44 44m-35-53 44 44M418 198l25 25m-5-61 25 25m2-36 25 25';

  const line = (shape, tone, width, delay, duration) =>
    `<${shape.tag} class="draw ink-${tone}" pathLength="1" stroke-width="${width}" style="--d:${delay}ms;--t:${duration}ms" ${shape.attrs}/>`;
  const path = d => ({ tag: 'path', attrs: `d="${d}"` });
  const circle = (r) => ({ tag: 'circle', attrs: `cx="65" cy="339" r="${r}"` });
  const echo = (scale, tone, delay) =>
    `<g transform="translate(355 323) scale(${scale}) translate(-355 -323)">${line(path(PLUG), tone, 1.6, delay, 1500)}${line(path(CABLE), tone, 1.6, delay + 200, 1500)}</g>`;

  host.innerHTML = `<svg class="copper-art" viewBox="0 0 650 650" fill="none" aria-hidden="true" focusable="false">
    <path class="mass mass-copper" style="--d:0ms" d="M223 182C346 76 570 149 601 305C636 479 480 596 316 549C162 504 86 300 223 182Z"/>
    <path class="mass mass-sage" style="--d:140ms" d="M-30 282C25 213 130 218 167 289C213 376 140 478 51 467C-44 456-83 347-30 282Z"/>
    <path class="mass mass-rose" style="--d:280ms" d="M466-8C540-60 682-1 705 75C728 150 618 174 555 137C491 100 425 65 466-8Z"/>
    <g stroke-linecap="round" stroke-linejoin="round">
      ${line(path('M428 93A110 110 0 0 1 555 250'), 'brass', 1.25, 1300, 1100)}
      ${line(path('M414 65A142 142 0 0 1 582 270'), 'sage', 1.25, 1380, 1100)}
      ${line(path('M399 37A174 174 0 0 1 610 290'), 'rose', 1.25, 1460, 1100)}
      ${line(path('M385 9A206 206 0 0 1 638 310'), 'copper', 1.25, 1540, 1100)}
      ${line(circle(69), 'sage', 1.25, 1500, 1200)}
      ${line(circle(91), 'brass', 1.25, 1600, 1200)}
      ${line(circle(113), 'rose', 1.25, 1700, 1200)}
      ${echo(1.16, 'rose', 700)}${echo(1.08, 'sage', 900)}${echo(0.92, 'brass', 1100)}
      ${line(path(PLUG), 'copper', 2.8, 0, 1700)}
      ${line(path(CABLE), 'copper', 2.8, 500, 1900)}
      ${line(path(HATCH), 'copper', 1.5, 1300, 1100)}
    </g>
    <g class="notation" fill="currentColor" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="11" letter-spacing="2"><text x="344" y="618">A GOOD CONNECTION.</text><text x="15" y="174" transform="rotate(-90 15 174)">SOUNDING / 01</text></g>
  </svg>`;

  const still = matchMedia('(prefers-reduced-motion: reduce)');
  let observer = null;

  const start = () => {
    host.classList.add('is-live', 'is-paused');
    observer = new IntersectionObserver(entries => {
      host.classList.toggle('is-paused', !entries[entries.length - 1].isIntersecting);
    }, { threshold: 0.1 });
    observer.observe(host);
  };
  const stop = () => {
    if (observer) observer.disconnect();
    observer = null;
    host.classList.remove('is-live', 'is-paused');
  };

  if (!still.matches) start();
  still.addEventListener('change', () => (still.matches ? stop() : start()));
})();
