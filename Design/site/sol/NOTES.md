# Sounding homepage / Sol

Open `index.html` directly in a browser. Static HTML, CSS and vanilla JavaScript, with system fonts. No dependencies, build step, audio playback, fetches, analytics or external resources.

## Design

Warm paper, copper type and quiet green surfaces surround an always-dark Now Playing preview. The complete homepage includes features, downloads, music analysis, device handoff, Polyphony, all five platforms, privacy, FAQ, beta feedback and TestFlight contact. Light and dark appearances follow the system. The preview stays dark in both.

Copy is adapted from `Design/site/BRIEF.md` and `Design/appstore/metadata.md`. The brief supplies the tracklist and newer Now Playing features. A public TestFlight URL was not supplied: both CTAs deliberately say **Ask about TestFlight** and open the supplied contact email. Replace those mailto targets with a real invitation when available. The privacy link points to the live site's privacy URL. The support link uses email. There are no additional local pages or changes to `docs/`.

## Lift the interactive piece

1. Copy the `section.np-demo[data-sounding-player]` between the `SELF-CONTAINED NOW PLAYING` HTML comments. Optionally copy its following `.demo-caption` and associated styling. If omitting the caption, remove `aria-describedby="demo-help"` from the section.
2. Copy the single CSS block between `BEGIN LIFTABLE NOW PLAYING BLOCK` and `END LIFTABLE NOW PLAYING BLOCK`. It includes its own responsive and reduced-motion rules. It uses no page-level custom properties or reset. All selectors are scoped to `.np-demo`. Give the host container the desired width.
3. Copy `app.js` and `assets/low-tide.svg`. Keep the SVG path relative to the stylesheet and markup, or update both references.
4. Include `<script src="app.js" defer></script>` once. It automatically mounts each `[data-sounding-player]` section.

The JS is one self-contained module packaged as an IIFE/classic script. This deliberately works under `file://` without the module-script CORS restriction. It has no imports or dependencies. For dynamic embedding:

```js
const preview = SoundingPlayer.mount(document.querySelector('[data-sounding-player]'));
preview.seek(785); // Seconds in the fictional one-hour mix.
preview.pause();
preview.destroy(); // Cancel frames, disconnect observer and remove listeners.
```

Mounting the same element twice returns the existing instance. Multiple instances have independent state. For multiple instances on one page, give each instance's tab/panel IDs a unique prefix and update their ARIA references. Those IDs are solely accessibility connections; the JS uses scoped data attributes.

## How the preview works

- Artwork, all 37 timed comments, artists, times and the 12-track DJ mix come from `Design/prototypes/now-playing/shared/data.js`. The waveform adapts the prototype's deterministic seeded waveform approach into 225 static SVG bars. No audio files are shipped. These are fictional fixtures, clearly labelled in the page.
- A one-hour mix plays at **18×** so transitions are visible in a short visit. It starts at 12:40 and stops at 60:00. Play resumes from the start after the end. Previous/next jump between the tracks inside the mix.
- The playhead, played-wave reveal and comment entrances use **only transform and opacity**, driven by one `requestAnimationFrame` loop. The played waveform is a moving overflow clip with a counter-translated copy of the static SVG, so no animated width, masks, filters, SVG geometry, canvas draws or background positions are needed.
- The artwork backdrop is statically blurred once by CSS. There are no moving blurred surfaces. The waveform geometry is created only at mount. Text updates at whole mix seconds; track highlighting and list positioning change only at track boundaries. Geometry reads for list positioning occur only on those boundaries, not on each frame.
- The comment bubble appears when its timestamp passes, then fades away after 110 mix seconds. At the accelerated demo speed, that is roughly six real seconds. Scrubbing backwards also restores the correct earlier comment.
- `IntersectionObserver` cancels the loop when the preview is entirely offscreen. `visibilitychange` also cancels it in a hidden browser tab. Resuming resets the frame timestamp so time spent offscreen or hidden is not skipped. There are no polling loops, timers or background animation frames.
- `prefers-reduced-motion: reduce` prevents autoplay and all continuous motion. The transport becomes an explicitly labelled **Advance preview by 30 seconds** button. Waveform scrubbing, comment timestamps, track selection, previous/next and tabs still work. A preference change pauses the demo immediately.
- The waveform is a native, labelled range input with arrow-key, Home and End support. The three tabs implement roving focus, Left/Right and Home/End. Tracklist and comment timestamps are real buttons. User-triggered seeks and playback changes have a polite live status; automatic progression does not repeatedly announce itself. FAQ uses native `details`.

## Assets

All imagery is local. PNG app screenshots were downscaled and converted with `cwebp`, quality 78–82. Each raster asset is under 40 KB, well below the brief's 250 KB target. The waveform and brand line detail are code-native SVG, with no generated bitmap request.

- `app-icon.webp`: copper jack icon, from `Branding/Sounding-iOS-AppIcon-Master.png`.
- `low-tide.svg`: original generated artwork extracted from the Now Playing prototype (about 3.4 KB).
- `mac-decks.webp`: a close crop of the actual mixer controls from `macos-2-decks.png`. The source has no loaded tracks; the crop avoids using the empty waveform as the feature image.
- `iphone-downloads.webp`: from `iphone-5-downloads.png`.
- `iphone-playing.webp` and `tv-playing.webp`: from the newer Now Playing prototype screenshots.

## Verification

Headless Google Chrome, loaded directly from `file://`. The requested CLI screenshot command was run at 1440 × 3200 and 390 × 5400. Chrome on macOS clipped the mobile window without a device-metrics override, so the final saved screenshots use Chrome DevTools Protocol with an explicit 390 px viewport. Final captures include the complete page, at 1440 × 3730 and 390 × 5002. Both have been visually inspected.

Checks cover waveform generation, track selection and highlighting, comment timestamp seeking, keyboard tabs, keyboard waveform scrubbing, play/pause, timed-comment matching, offscreen stop/resume, reduced-motion still mode and 30-second advance, dark appearance, 320/390/768/1440 px overflow, image loading, FAQ disclosure, teardown/remount, console errors and network requests. No external requests or browser exceptions were observed. Runtime browser-check scripts and the Chrome profile live in the session temporary directory, outside the deliverable.

The page has no performance audit dependency and no claimed Lighthouse score. The main remaining integration task is replacing the TestFlight contact with the owner's real invite URL when available.
