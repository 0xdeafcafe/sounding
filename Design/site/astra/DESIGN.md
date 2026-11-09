# Sounding: a place to listen

This direction treats Sounding as a piece of listening equipment. Warm paper, copper wire, dark listening rooms and a little technical notation. The photographed jack remains the app icon. Its drawn counterpart gives the website a recognisable identity before a screenshot appears.

The homepage is complete and self-contained. Open `index.html` directly. It uses static HTML, CSS, vanilla JavaScript and local WebP images. No build, fonts, libraries, analytics or external asset requests.

## The composition

The welcome headline, “Plug in. Turn it up.”, sits beside a large copper jack. A cable curls underneath it, giving the hero a sense of physical connection. A thin platform strip leads into numbered editorial sections:

1. **Listen:** the newest Now Playing and Tracklist prototypes share an always-dark panel. Copy introduces the existing library, timed comments, track identification and the queue.
2. **Mix:** the real Mac decks screenshot gets enough space to show the controls. Two compact notes explain analysis and Auto Mix.
3. **Move:** Apple TV is the large product image. Adjacent copy explains the remote and playback handoff. Four short platform descriptions cover all five Apple devices.
4. **Download:** a verdigris panel contains the real download settings screen. The copy covers playlist sync, Optimise Storage and encryption.
5. **Privacy:** an outlined panel states the architecture plainly. No servers, analytics, advertising or accounts of our own. Private iCloud sync.
6. **Questions and launch:** native disclosures, a direct support address and a copper closing panel. No invented release date or working beta link.

Wide layouts use three columns for section introductions: a small section label, the heading and its explanation. Images sit below. On mobile, this becomes a single reading order. Sections remain visible without entrance effects or scroll JavaScript.

## Typography

System stack: `-apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", sans-serif`. Technical numbers use `ui-monospace, SFMono-Regular, Menlo, monospace`. No downloads.

| Role | Desktop | Mobile | Weight / line height |
| --- | --- | --- | --- |
| Hero | Fluid, up to 112 px | Fluid, about 68 px at 390 | 500 / 0.99–1.03 |
| Closing headline | Fluid, up to 92 px | 57 px | 500 / 1.06 |
| Section heading | Fluid, up to 58 px | 44 px | 500 / 1.06 |
| Feature heading | 29–42 px | 28–34 px | 500 / 1.16 |
| Introductory copy | 24 px | 22 px | 400 / 1.35 |
| Main copy | 14–16 px | 13–14 px | 400 / 1.55 |
| Navigation / controls | 12–14 px | 11–14 px | 400–500 / 1.3–1.55 |
| Eyebrow | 10 px | 9–10 px | 600 / 1.5 |
| Captions / notes | 10–12 px | 9–12 px | 400 / 1.6 |

Headings use tight tracking, from −0.035em on small features to −0.075em on the hero. Eyebrows use +0.13em and uppercase. Small text is reserved for secondary labels and captions, never essential instructions. Headings have deliberate short lines. Body copy remains natural and left aligned.

## Colour tokens

Colours reference the welcome art’s copper, brass, verdigris, rose copper and cream. Copper is brown enough to read as the material in the icon. It does not imitate SoundCloud branding.

| CSS token | Light | Dark | Purpose |
| --- | --- | --- | --- |
| `--paper` | `#f5f1e9` | `#1c201d` | Main canvas |
| `--surface` | `#ebe6dc` | `#252a25` | Device section / frames |
| `--ink` | `#292b26` | `#f2eee5` | Main type / primary action |
| `--muted` | `#66675f` | `#b5b7ad` | Supporting text |
| `--line` | `#d4cec2` | `#42473f` | Rules and panel outlines |
| `--copper` | `#99502e` | `#e5a27a` | Hero accent / focus / annotations |
| `--sage` | `#49645b` | `#9bb6a7` | Verdigris strokes |
| `--brass` | `#a18142` | `#c8a363` | Decorative strokes only |
| `--rose` | `#aa746c` | `#ce9b91` | Decorative strokes only |
| `--copper-mass` | `#e8c3a5` | `#4a3326` | Flat hero shape |
| `--sage-mass` | `#d6dfd1` | `#293d33` | Flat hero shape |
| `--rose-mass` | `#e7d3cc` | `#483435` | Flat hero shape |
| `--green-surface` | `#e3e8dc` | `#28352c` | Downloads panel |
| `--closing` | `#e6c4a7` | `#3d2c23` | Launch panel |
| `--closing-ink` | `#382e25` | `#f2ddc7` | Launch panel text |
| `--room` | `#171b19` | `#171b19` | Always-dark listening panel |
| `--room-ink` | `#f4f0e8` | `#f4f0e8` | Listening heading |
| `--room-muted` | `#b8bcb1` | `#b8bcb1` | Listening body copy |

`prefers-color-scheme` selects the initial palette. The header control cycles System → Light → Dark → System and stores only that preference locally. Storage failure is harmless. CSS supplies the system palette without JavaScript. App screenshots retain their original colour scheme.

## Spacing and shape

Use a practical 4 px rhythm: 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56 and 64 px. Section gaps are deliberately larger, 94 px on desktop and 58 px on mobile.

The page is capped at 1240 px. Desktop outer space is at least 56 px, tablet 32 px and mobile 20 px. The main responsive break is 760 px. Cards use a restrained 6 px radius. Buttons use 4 px. Product silhouettes keep their own rounded hardware corners. Rules are 1 px. No blurred website backgrounds or decorative shadows compete with the app artwork.

Touch controls have useful hit areas. The 38 px mobile appearance button is the one compact auxiliary control. Navigation and primary actions remain in the header at mobile widths, with the three section links omitted because the page itself is short enough to navigate by scrolling.

## Copper line art and motion

The inline SVG is original vector work based on the welcome screen and `SoundingLineArt.swift`. It contains a copper jack outline, grip lines, three echo contours, paired cables, sound rings and three flat colour masses. It uses no third-party logo or stock illustration. SVG `<use>` keeps the repeated paths compact.

The hero’s line-art draw-on uses a **transformed SVG clipping rectangle**, revealing the contours progressively from left to right. It lasts 2.3 seconds with `cubic-bezier(.22, 1, .36, 1)`. This reconciles the draw-on request with the brief’s restriction to animating transform and opacity. It does not animate stroke dash offsets, dimensions, path data or layout. The colour masses fade in over 1.5 seconds and the small annotation fades in once.

There is no perpetual motion, parallax, autoplay, scroll hijacking or content hidden pending an observer. Buttons lift by 2 px and soften in opacity on hover. FAQ crosses rotate. The footer has four static cable contours to close the visual thread.

With `prefers-reduced-motion: reduce`, all CSS animations and transitions are disabled. The complete SVG appears immediately, smooth scrolling becomes ordinary anchor navigation, and hover movement stops. The artwork is decorative and hidden from assistive technology.

## Assets and provenance

All images are local WebP, converted with `cwebp -q 82 -resize WIDTH 0`. No source screenshots were changed. The total prepared image set is about 132 KiB. The largest is 43 KiB, comfortably under the requested per-image limit.

| Local file | Source | Width | Bytes |
| --- | --- | --- | --- |
| `assets/app-icon.webp` | `Branding/Sounding-iOS-AppIcon-Master.png` | 128 | 1,250 |
| `assets/now-playing.webp` | `Design/prototypes/now-playing/shots/iphone-playing-dark.jpg` | 463 | 16,488 |
| `assets/tracklist.webp` | `Design/prototypes/now-playing/shots/iphone-tracklist-dark.jpg` | 463 | 20,232 |
| `assets/tv-playing.webp` | `Design/prototypes/now-playing/shots/tv-playing-dark.jpg` | 1280 | 25,034 |
| `assets/mac-decks.webp` | `Design/appstore/screenshots/macos/macos-2-decks.png` | 1440 | 44,070 |
| `assets/downloads.webp` | `Design/appstore/screenshots/iphone/iphone-5-downloads.png` | 480 | 21,296 |
| `assets/watch-playing.webp` | `Design/prototypes/now-playing/shots/watch-playing.jpg` | 300 | 6,876 |

The watch image is prepared for the integrator but not loaded by this homepage. The two iPhone prototype screenshots already contain a hardware silhouette. Their black outer corners are rounded in CSS to sit inside the dark panel. The downloads image is intentionally cropped inside a decorative handset frame, with the visible controls unmodified. The Mac decks image is an actual empty-decks capture, not a fabricated populated session.

All visible product claims come from `Design/site/BRIEF.md` and `Design/appstore/metadata.md`. British English and short sentences follow the supplied tone-of-voice skill. Prototype figures are captioned as design previews.

## Accessibility and behaviour

Semantic landmarks, one H1, ordered heading levels, a skip link, visible focus indicators, descriptive image alternatives and decorative SVG isolation are included. Native `<details>` supplies keyboard-operable FAQs. There is no menu state, modal or focus trap. Links and FAQs work without JavaScript. The only JavaScript feature is the optional appearance control.

Images declare dimensions. Larger images below the first feature use lazy loading and asynchronous decoding. Core content is never dependent on JavaScript or animation completion. Theme changes follow the operating system while System is selected. The theme control exposes the current and next appearance through its accessible name and tooltip.

No Lighthouse score is claimed. The implementation avoids third-party execution, web fonts and large assets, but a production Lighthouse run belongs to the integrated HTTP site.

## Integration notes

- This lane delivers the homepage only. Nothing in `docs/`, the app code or other lanes was edited. No commit was made.
- The homepage’s Privacy and Support links currently target its own sections so the standalone concept has no broken local routes. When integrated, point them to the integrator’s `/privacy/` and `/support/` pages. The full existing privacy policy must be preserved verbatim there.
- Keep `docs/auth/index.html` byte-identical, along with `docs/CNAME` and existing `docs/*.md` files. This implementation has not touched them.
- The public TestFlight invitation URL was not supplied. “Get Sounding” goes to the launch section. “Ask about TestFlight” opens the supplied support email with a subject. Replace that CTA only once a real invitation link exists. The page does not claim the beta is already open.
- No App Store badge or availability date is invented. The page says “Coming to the App Store”. Free pricing comes from the metadata.
- The independence and trademark statement must remain on every integrated page. SoundCloud appears only in descriptive text.
- The icon, screenshots and CSS are local. Do not include the PNG review screenshots or verification utility in the production asset bundle.

## Review files and verification

`shot-desktop.png` is the top 3200 px at a 1440 px viewport. `shot-mobile.png` is the top 3200 px at a true 390 px viewport. The corresponding `-full.png` files show the complete page. `shot-desktop-dark.png` and `shot-mobile-dark.png` show complete dark-mode renders.

Both initial views were rendered using the requested headless Chrome command and inspected. Chrome’s desktop window minimum made the first mobile capture wider internally than its screenshot. Final captures therefore use Chrome DevTools Protocol device metrics to enforce 390 px. The render utility eagerly decodes images for captures only, so full-page reviews include assets that would normally load as the visitor scrolls.

`verify.mjs` is a dependency-free Node utility for the local headless Chrome instance on port 9236. It writes `verification.json` and the six review screenshots. It checks responsive widths, missing images, local anchors, runtime errors, external page requests, system dark mode, reduced motion and keyboard activation of the FAQ and appearance control. It is a review utility, not part of the website.

Final browser checks passed at 320, 390, 768, 1024 and 1440 px. No horizontal overflow, missing images, broken anchor targets, runtime errors or external page requests were found. Both keyboard interactions passed. Reduced motion reported zero running animations. The system dark palette resolved to the intended dark canvas and light text.
