# Swapping the hero animation

The hero art on `docs/index.html` is one module: `docs/assets/hero.js` plus `docs/assets/hero.css`. Nothing else on the site knows how it works.

## The contract

- The page has one host element, `<div class="hero-art" id="hero-art" data-hero aria-hidden="true"></div>`, and loads `hero.css` and `hero.js` (`defer`). Nothing else references the hero.
- `hero.js` fills `[data-hero]` on load. It must:
  - honour `prefers-reduced-motion` (render the finished frame, no animation) and react to the setting changing;
  - pause when the host is offscreen (IntersectionObserver);
  - animate only transform, opacity and stroke-dashoffset;
  - take its colours from the page tokens (`--copper`, `--sage`, `--brass`, `--rose`, `--copper-mass`, `--sage-mass`, `--rose-mass`, `--muted`), so light and dark follow the site.
- `hero.css` holds the module's own styles and the host's `aspect-ratio`. Layout (grid column, width) stays in `site.css`, under `.hero-art`.

## Current default

The board's line-art draw-on (concept 1): an inline SVG built in `hero.js`. Each contour has `pathLength="1"` and animates `stroke-dashoffset`, staggered with `--d` and `--t`. The three flat masses fade and scale in. About 2.8 s in total, played once.

## Swapping in v1 to v5 (`Design/concepts/cable/`)

Those are built on the `Cable` framework, not plain SVG:

- `art.js` is the generator (`SoundingArt.compose` and `build`).
- `shell.js` holds the motion core (`Cable.M`, `draw`, `idle`, `plugAt`, `routeAt`), plus the demo page and toolbar, which the site does not need.
- `v1.js` to `v5.js` are specs exposing `play(ctx)` and `still(ctx)`.

To swap:

1. Make a new `docs/assets/hero.js` by concatenating `art.js`, the motion core from `shell.js` (the `M` object, `draw`, `idle`, `routeAt`, `plugAt`, `cableFracAt`, `wrapDeg`; drop the page templates, toolbar and `page()`), and the chosen `vN.js`.
2. End it with a small adapter that does what `page()` does without the shell:
   - set `host` to `[data-hero]`;
   - `geo = SoundingArt.compose({ w, h, seed: 11, adjust })`;
   - `layers = SoundingArt.build(host, geo, palette)`;
   - then `spec.play(ctx)`, or `spec.still(ctx)` when reduced motion is on;
   - wire `M.pause()` and `M.resume()` to an IntersectionObserver on the host;
   - rebuild on resize (debounced).
3. Choose `palette` from `SoundingArt.palettes.light` or `.dark` using `matchMedia('(prefers-color-scheme: dark)')` and the `data-theme` attribute on `<html>`.
4. Replace `hero.css` with a rule giving the host the aspect ratio the composition is tuned for (`compose` takes the host's width and height, and its `adjust` hook branches on landscape and portrait), and delete the old ink and mass classes.
5. Check v1 to v5 against the budget: hero JS under 15 KB. `art.js` alone is 16 KB unminified, so strip or minify when bundling.
