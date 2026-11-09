# Sounding website: design tokens

The site at `docs/` (sounding.forbes.red). One aesthetic: the app's copper line art on paper or near-black, real music, lots of room. `Design/DESIGN-BIBLE.md` wins where this disagrees.

## Palette
Light follows the app's light line-art palette, dark follows the dark one. The page follows the system setting.

| Token | Light | Dark | Use |
|---|---|---|---|
| `--paper` | `#f6f1e8` | `#110e0c` | Ground |
| `--ink` | `#1c1814` | `#f2ece3` | Headings, body |
| `--ink-2` | `#5e564e` | `#a99f94` | Secondary text (4.5:1 or better) |
| `--button` | `#b84a12` | `#ff7a2e` | The one primary action |
| `--copper` | `#a3410f` | `#ff8a45` | Text links |
| `--ink0`…`--ink4` | copper, ochre, teal, wine, umber | copper, brass, verdigris, rose copper, cream | Line-art strokes, in this order |
| masses | peach, lilac, mint | burnt copper, plum, deep verdigris | Flat colour masses, the only backgrounds |

No gradients, glows or tinted panels outside the device screens.

## Type
System fonts only (SF Pro on Apple devices). Four sizes:

| Token | Size | Use |
|---|---|---|
| `--t-display` | 56–128 px, weight 700, tracking −0.045em | The hero headline only |
| `--t-h2` | 34–62 px, weight 700, tracking −0.035em | One heading per section |
| `--t-lede` | 18–20 px | Hero paragraph, scene captions, the first line of the decks and honesty blocks |
| `--t-body` | 17 px | Body |
| `--t-small` | 16 px | Footer, notes under buttons, captions under the decks |

Nothing on the page is smaller than 16 px. Scene captions open with a short bold sentence in `--ink` ("This is the tracklist."), then carry on in `--ink-2`.

No eyebrows, no uppercase labels, no mono captions.

## Shape and space
- One radius: `--r: 12px` (buttons, artwork). Device frames use their physical radii.
- No drop shadows. Depth comes from echo outlines (below).
- Spacing scale: 8, 16, 24, 40, 64, 104, 168 px (`--s1`…`--s7`). Side padding `--pad`: 24–96 px. Content max 1240 px.

## Line-art system
Ported from `SoundingLineArt.swift` (`Design/concepts/cable/art.js`), drawn at runtime in `docs/assets/site.js`.

- **Stroke:** 1.5 px everywhere (knurl lines 1.2 px).
- **Echo:** 4.5 px pitch between contours. Four contours on desktop, two on phones. Tone order: ink0, ink1, ink2, ink3.
- **The cable** is one aux lead: a jack in the hero socket, then four parallel contours that taper from the plug body to a 6 px core over 110 px, then weave down the page, behind each scene, and end in a second jack seated in the TestFlight button.
- **Echo outlines** frame the real objects: the phone, the four Output devices, the decks, the mixer and the TestFlight button once the jack seats. They're CSS `box-shadow` rings (4 px paper gap, 1.5 px ink), so they share the cable's pitch.
- **Artwork plates** get a single echo ring, cycling ink0 to ink4.
- **Sound rings:** six arcs from the hero jack tip. The button's echo outline acts as its rings.
- **Wave bands:** five contours, used as dividers (hero bottom, and the gap between the two pinned scenes).
- **Masses:** three per scene at most, behind the hero art, the phone, the devices and the decks.

## Motion
- Animate only transform, opacity, stroke-dashoffset and clip-path.
- The cable is the only thing scrubbed by scroll. The pen sits at 66% of the viewport height. Inside pinned scenes it draws with scene progress instead, in an SVG inside the sticky stage, so it never lags the pin.
- **Pinned scenes are state machines, not scrubbed timelines.** Each scene (desktop ≥1000×620) has five states: a pre-state while it scrolls in, then one state per caption. `site.js` maps the scroll offset to a state with 16 px of hysteresis and sets `data-state` on the stage. CSS transitions play the change in 300–500 ms, eased, then stop. Scrolling back reverses it, and jumping several states plays one transition straight to the target. A scene never rests between states.
- Breakpoints: the pre-state ends when the stage is 30% of the viewport from pinning, then at 24%, 50% and 76% of the pinned span. Each scene is 300vh tall.
- Listen states: covers scattered → Likes (covers fly into the rows) → the 90-minute set in Now Playing → the tracklist → a tap jumps to a track. Output states: TV asks to sign in → the chime rings and the iPhone asks to sign in → Play On sheet, TV wakes at the same timestamp → Watch becomes the remote → Polyphony (a friend's phone and the Mac join, rings over every device).
- Each state has one caption. In pinned scenes the captions sit in one grid cell and crossfade (out in 160 ms, in after 140 ms). Without pins they're all shown as paragraphs and the visuals show the final state.
- The tracklist in the demo is real UI: tapping a row jumps the time without scrolling the page. The clock ticks once a second while the scene's on screen.
- Hero "Patch in": contours draw on over 1.3 s, the jack slides in and clicks at 1.8 s, the socket bumps and the rings ripple. Plays once.
- The second jack seats in 420 ms when the cable reaches it.
- No fade-up on sections. The only text motion is the caption crossfade in pinned scenes (opacity only, no slide).
- The hero intro runs about 1.15 s and never delays reading the headline.
- Echo outlines use two rings on phones.
- Reduce Motion: scenes still pin and change state, but every change is instant (no transitions, no tap ripple, no ticking clock, no list slide). No intro, the full cable drawn, decks don't spin.
- Phones: no pins, the cable runs down the right-hand gutter with two contours.
