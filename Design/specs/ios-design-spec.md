# SoundingCloud for iPhone — Design Spec

*Raising the phone to the TV's bar, using Apple Music's craft as the yardstick — and making the things Apple Music can't do the reason to open our app instead.*

Reference viewport throughout: **iPhone 17 Pro, 402 × 874 pt**. Where a number depends on width I give the formula. Cross-check sizes at 393 × 852 (iPhone 17) and 440 × 956 (Pro Max).

Deployment floor stays **iOS 26.0**. iOS 27 ships ~Sept 2026; everything here is written to look right on 26.0 and *better* on 27 without a second code path.

---

## 0. The three changes that do most of the work

If only three things get built, build these. Everything in §3 is ranked below them.

| # | Change | Why it is the biggest lever | Size |
|---|---|---|---|
| **1** | **Rebuild `NowPlayingSheet` on Apple Music's geometry, and make it scroll.** Left-aligned title block with a trailing overflow button, artwork sized off screen width that shrinks when paused, bare transport glyphs instead of three glass circles, and — the structural part — a vertical scroll region beneath the fold holding the waveform lane, the comment feed, "Behind This Track" and Up Next. | This is the screen the app is *for*. It is currently a single fixed-height column with everything centred and three competing glass circles; the version below is the same information at Apple Music's density with our features living underneath it instead of hidden behind top-bar icons. | **L** |
| **2** | **Give the app a Home.** The phone's first screen is currently a segmented control over a plain `List`. tvOS opens on an 800pt hero + shelves. Port that shape: one hero card, then horizontal shelves with square artwork. | First impression. Everything else in the app is judged against the first screen, and ours currently looks like a settings pane. | **M** |
| **3** | **Stop fighting the tab-bar accessory, and make the waveform the app's signature.** Remove the glass-on-glass in the mini bar, adapt it to `tabViewBottomAccessoryPlacement`, and promote the waveform+comments from a 36pt strip under the title into a real, tall, touchable instrument. | The mini bar is on screen more than any other pixel in the app, and it currently double-glasses. The waveform is the one thing Apple Music structurally cannot copy. | **M** |

---

## 1. What Apple Music actually does

I have split this hard into what I **verified** this session and what I am **recalling**. Do not treat §1.3 numbers as ground truth — treat them as the starting point for a screenshot-and-measure pass on a real device.

### 1.1 Verified — Apple's own iOS 26 design-system rules

From the WWDC25 session *"Get to know the new design system"* (fetched transcript) and Apple's Liquid Glass docs:

**The layer model.** Two layers only: a **content layer** (the app's actual stuff) and a **navigation layer** that floats above it. Liquid Glass belongs to the navigation layer and *"remains unobtrusive when interaction isn't needed"*, bringing structure *"without ever stealing focus"*. Apply the material **to controls, not to their inner views**.

**Typography.** *"Typography is bolder and left-aligned to improve readability in key moments."* Hierarchy is *"expressed through layout and grouping, not decoration"* — remove custom backgrounds and borders from bars.

**Concentric corner radii.** Three shape kinds: fixed radius, capsule (radius = half the container height), and **concentric** (radius = parent radius − padding). Nested containers such as artwork inside a card *must* use concentric shapes. *"Avoid corners that feel too pinched or flared — they create tension and break balance."* On iPhone specifically: use a **capsule with extra margin near the screen edge**.

**Tinting.** Only the primary action is tinted. It becomes *"a clear focal point that's easy to spot."* (Matches our own `DesignSystem.swift` note: *"if you tint everything, nothing stands out."*)

**Tab bars.** *"One of the most persistent parts of your app."* They support persistent features via **accessory views** — Apple's own cited example is *"media playback controls that stay visible across app"*. Rule: **do not put screen-specific actions in a tab bar.**

**Scroll edge effects.** Replace hard dividers with a subtle blur where content meets chrome. **One per view.** Do not stack or mix them. Soft is the iOS default.

**Bar organisation.** Group by function and frequency. Do **not** group a symbol with a text label in one container — they read as a single button.

**Glass mechanics** (API-level, cross-checked against a third-party reference and our own code):
- `.regular` for most UI, `.clear` for media-rich backgrounds, `.identity` to conditionally disable.
- *"Glass cannot sample other glass; container provides shared sampling region."* Hence `GlassEffectContainer(spacing:)` — `spacing` is the **morph threshold**, the distance within which two glass shapes visually merge.
- Morphing needs all three of: same container, `glassEffectID` in a shared namespace, and an animation on the state change.
- `tabViewBottomAccessoryPlacement` returns **`.expanded`** (accessory sits above the tab bar) or **`.inline`** (accessory merges *into* the tab bar during scroll). `.tabBarMinimizeBehavior(.onScrollDown)` drives the transition.

### 1.2 Verified — iOS 27 / tvOS 27 (WWDC26, betas now, ships ~Sept 2026)

This matters because our floor will move within a release or two, and one of these changes is a direct template for a screen we ship badly today.

**Liquid Glass, refined.** Apple changed the material's construction: it now *"more effectively diffuses complex content"* behind it. Two visible additions — a **darkened edge** around glass elements, and **brighter specular highlights** — both for depth and separation. A user-facing **transparency slider** runs *"anywhere from ultra clear to fully tinted"*. Uniform toolbars now appear at the top when content scrolls beneath floating bars. **Apps get most of this automatically without recompiling.**

**Search moves back into the tab bar.** iOS 26 broke the search tab out to the trailing edge; iOS 27 re-integrates it with the other tabs. Apple Music is the named example.

**Apple Music artist pages — the one to copy.** Live in beta:
- The artist photo *"blends downward into the page content below it"* — not a framed header image, a bleed.
- Its dominant colour palette *"shap[es] the visual tone of the full page"*, described as *"closer to ambient room lighting than a framed picture."*
- **Play, Shuffle, artist name and Follow sit immediately beneath the image, before any catalogue content.** Explicitly to cut the scroll-to-play distance.
- Featured music is split into **its own distinct card**, separate from the discography.
- Underlying structure is unchanged: *"a reprioritization, not a reinvention."*

**Apple Music album pages** — announced, not yet in beta.

**Now Playing** now works in **both portrait and landscape** on iPhone, and loads faster.

**AutoMix** got better key/tempo matching, and shipped to **Apple TV and HomePod** for the first time. tvOS 27 also adds AutoMix + Crossfade, Hi-Res Lossless up to 24-bit/192 kHz, Smart Downloads, a Larger Text accessibility option, and ~30% faster app launches.

> **Strategic read:** AutoMix arriving on Apple TV in tvOS 27 means Apple is now doing, first-party and on the same box, a weaker version of what our DJ mode does. Our differentiation has to be the *manual* console, the *visible* mixer, and Phantom's stated reasoning — not "we auto-mix too." See §4.4.

### 1.3 Recalled — treat as approximate, verify by screenshot

I could not find a published teardown with real numbers. These are my own recollection of the shipping app and should be re-measured before anyone commits them to code. They are here because "roughly this" beats "large artwork".

| Element | Recalled value | Confidence |
|---|---|---|
| Now Playing artwork width | screen width − 2 × 24pt (≈ 88% of width) | med |
| Artwork corner radius | 12–14pt, continuous | med |
| **Paused-state shrink** | artwork scales to ≈ **0.80–0.82**, springs, shadow softens with it | high that it happens, low on the number |
| Title | ≈ 22pt bold, **left-aligned**, single line, marquee on overflow | med-high |
| Artist | **same size as title**, regular weight, **tinted with the artwork-derived accent** | high — this is Apple Music's most distinctive tell |
| Overflow button | circular "···", ≈ 28pt, trailing, aligned to the title block | high |
| Scrubber at rest | thin capsule ≈ 7pt tall, no visible thumb | high |
| Scrubber under touch | **thickens to ≈ 2× and the timestamps grow/brighten**; haptic on grab | high that it happens |
| Transport glyphs | play/pause ≈ 34pt, prev/next ≈ 28pt, **bare glyphs — no button chrome at all** | high |
| Volume slider | same capsule language as the scrubber, thinner, with small speaker glyphs at each end | high |
| Utility row | three items across the bottom: Lyrics, AirPlay/route, Up Next | high |
| Background | blurred/animated artwork wash, dominant colour, slow drift | high |
| Mini player | ≈ 44pt artwork, title only (no artist), play + next, translucent, docks above the tab bar | high |

### 1.4 The pattern behind the numbers

Four things, and they are what "premium" actually decomposes into:

1. **Restraint in chrome, generosity in content.** Apple Music's Now Playing has *no button backgrounds*. The artwork is the biggest thing on screen by a wide margin. Every pixel of decoration removed makes the content read as more expensive.
2. **Colour comes from the content, never from the brand.** The artist name, the scrubber fill, the background — all derived from the artwork. The brand colour appears essentially nowhere on Now Playing.
3. **State is expressed physically.** Paused isn't a changed glyph, it's the artwork physically getting smaller. Scrubbing isn't a moved dot, it's the control growing under your thumb.
4. **One thing is tinted.** Everything else is white at graded opacity.

---

## 2. Gap analysis — where we actually fall short

Read against `/Users/afr/Source/github.com/0xdeafcafe/sounding-tv/SoundingTV-iOS/Sources/` and the tvOS views the user rates highly.

### 2.1 The honest good news

The phone is not badly built. It already has: an artwork-derived 3×3 `MeshGradient` background (`NowPlayingPalette`, `TransportBarView.swift:363`), a real waveform scrubber with clustered timed comments, `matchedTransitionSource` + `.navigationTransition(.zoom())` hero transitions, `scrollTransition` row settle, `sensoryFeedback` on transport and selection, symbol `.replace` + `.bounce` on play/pause, Reduce Motion routed through a token. That is a lot of correct groundwork. The problem is not craft-per-component; it's **composition, hierarchy, and the absence of a first screen.**

### 2.2 `TransportBarView.swift` — the mini bar

- **Glass on glass.** The bar applies `.glassEffect(.regular.tint(…).interactive(), in: RoundedRectangle(cornerRadius: Radius.lg))` at line 101 — *inside* `.tabViewBottomAccessory`, whose container the system already draws in Liquid Glass (`PhoneRootView.swift:267`). This is precisely the stacking Apple's docs and this project's own `GlassComponents.swift` header forbid: *"Glass cannot sample other glass."* On iOS 27, with darkened edges added to every glass element, a doubled edge will be visibly wrong.
- **Does not adapt to placement.** `tabViewBottomAccessoryPlacement` is never read. In `.inline` (tab bar minimised on scroll) the bar still tries to render artwork + two lines + three buttons + a progress capsule into tab-bar height.
- **`.tabBarMinimizeBehavior` is never set**, so the inline state barely occurs anyway — meaning the app never gets the Apple Music behaviour where the player melts into the bar as you scroll.
- Progress capsule redraws on a 1 Hz `TimelineView` with a 1s linear animation. Correct approach, but at 3pt tall under a glass pill it is nearly invisible; Apple Music's mini bar has no progress line at all.
- Artwork is 44 × 44 at `Radius.sm` (10pt) — fine, but it is not concentric with the accessory's own capsule.

### 2.3 `TransportBarView.swift` — `NowPlayingSheet`

The single largest gap. Specific failures:

- **Everything is centred** (`titleArtist`, `.multilineTextAlignment(.center)` at line 846). Apple's own iOS 26 guidance is bolder **and left-aligned**. Centred title + centred artist + centred transport reads as a 2016 lock screen.
- **No paused state.** `snapshot.isPlaying` drives a glyph swap and a symbol bounce and nothing else. The artwork never moves. tvOS *does* do this (`HeroArtwork`, scale 1.0 ↔ 0.96 on a `spring(0.6, 0.78)`) — the phone, where the gesture is most physical, does not.
- **Artwork is capped at 380pt.** `min(proxy.size.width - Spacing.xxl * 2, 380)` → on a 402pt device that's `402 − 80 = 322`, so the cap never binds and the real number is 322pt = **80% of width**, with 40pt gutters. Apple Music runs ~88% with 24pt gutters. Ours reads small and floaty.
- **Three glass circles across the transport** (54 / 84 / 54 at lines 918, 951, 971), plus up to three more glass circles in the top bar, plus a glass comment bubble. That is up to seven glass shapes over a mesh gradient on one screen. Apple Music has zero button chrome here. This is the biggest single visual-weight problem.
- **The play button is the only element not tinted by the artwork.** It uses `Color.scAccentGradient` (fixed SoundCloud orange) while its own shadow uses `palette.current.accent`. The two disagree on every track.
- **The waveform is a 36pt strip.** `barHeight: CGFloat = 36`, `barPitch 4`, `barGap 1.5`. It is the app's signature feature rendered at the size of a progress bar. It does not respond to touch beyond seeking — no expansion, no haptic, no timestamp growth.
- **Comment markers are 5pt dots at `y = barHeight − 7`**, i.e. crammed inside the waveform's own 36pt box. The bubble is `offset(y: -84)` — it floats over the *title*, which is why it has to be `.allowsHitTesting(false)`.
- **Our distinctive features are all behind icons in a top bar.** Comments = a 40pt glass circle. Up Next = another. Output = another. All three are ~15pt glyphs in the top-right corner, at the smallest and least visited point on the screen. The features that justify the app are its least prominent elements.
- **No track actions at all.** No like, no add-to-playlist, no share, no add-to-queue. tvOS has all four in `secondaryActionsRow` (`PlayerView.swift:325`).
- **No "Behind This Track".** tvOS wires `BehindTheTrackView` at `PlayerView.swift:163`/`:338` (note: that type has **no definition anywhere in the tree** — it is in-flight work by a concurrent agent, `PlayerView.swift` mtime 2026-08-03 01:58). The phone has no equivalent and no placeholder.
- **Up Next only exists when the TV owns the session** (`upNextLink`, line 759, gated on `snapshot.source == .appleTV`). Local playback has no queue screen at all. The comment says so explicitly: *"A local queue view is a separate screen that doesn't exist yet."*
- **Fixed layout, no scroll.** A rigid `VStack` of `Spacer`s between `topBar` and `transportButtons`. There is nowhere to put anything else, which is why everything ended up in the top bar.

### 2.4 `PhoneRootView.swift` — the shell

- **Three tabs: Library / Apple TV / Settings.** Settings is a top-level destination; there is no Home; there is no Search tab. Apple Music's tab bar is content-first; ours is admin-first. A tab bar advertises capability, and ours advertises "settings" as one third of the app.
- The `BottomAccessoryModifier` iOS-26.0 fallback rebuilds the whole `TabView` when playback starts or stops. The comment is honest about it. It is the right trade at 26.0 and evaporates at 26.1 — but it means **every navigation stack pops to root the first time something plays**, which is a real polish hit on the exact moment the app should feel best.

### 2.5 `LibraryBrowserView.swift`

- **A segmented control over a plain `List`.** Three sections × one 52pt-thumbnail row style. Compare tvOS `LibraryView`: a 4-column `LazyVGrid` of square artwork with 40pt gutters. Playlists in particular are *art*, and we render them as 52pt squares in a table.
- `PlaylistHero` (line 340) is an 84pt thumbnail + title + "N tracks · owner" — **and no Play button, no Shuffle button.** iOS 27's artist page puts play/shuffle *above the catalogue* precisely to kill this. Our playlist detail requires scrolling and tapping an individual row to start anything.
- **No hero, no bleed, no colour.** Playlist detail is `Color(uiColor: .systemBackground)` behind a small thumbnail. tvOS's equivalent gets `DynamicBackground`. iOS 27's artist page bleeds the image into the page and washes the whole page in its dominant colour.
- Search is `.searchable` on the Library tab rather than a `Tab(role: .search)`.
- Row artwork 52pt, `Radius.sm` (10). Fine. Rows are the one thing here at Apple Music's level.

### 2.6 `CompanionRootView.swift` — the Apple TV tab

- Structurally right (the demotion from root to tab was the correct call), visually a **stack of five near-identical `scCard` blocks**: same `Radius.lg`, same `Spacing.lg` padding, same `Color.primary.opacity(0.05)` fill, same `Spacing.xl` horizontal inset. Nothing is dominant. The one genuinely interesting thing on the screen — the output router, which is the whole reason the tab exists — looks exactly like the connection status card above it.
- The `livePulse` heartbeat dot is good and is the only piece of personality on the screen.
- The radial accent wash (`endRadius: 420`) is a nice touch and is invisible under five opaque cards.

### 2.7 `QueueManagerView.swift` / `PhoneSettingsView.swift` / `WelcomeView.swift`

- `QueueManagerView` is competent — current-row accent fill, `scrollTransition` settle, haptics on jump and reorder. Its one flaw: it renders **only the TV's queue**, so from the phone's own session there is no queue UI whatsoever.
- `WelcomeView` is the best-composed screen in the phone app (blurred accent halo, pulsing `waveform.circle.fill`, `.glassProminent` capsule). It is also the screen users see least. Its energy should be redistributed.
- `MessageState` / `StateMessage` are duplicated across three files with slightly different numbers (64pt vs 44pt icon, `.scDisplay` vs `.scTitle` title). Minor, but it's the kind of drift that reads as "assembled" rather than "designed".

### 2.8 Design-token gaps

`AppClipDesign.swift` (the iOS token file) versus what the redesign needs:

| Missing | Needed for |
|---|---|
| A display size above 34pt | Home hero title |
| A `scTitle3` / section-header token | Shelf headers ("Recently Played") |
| An eyebrow token (uppercase + tracking) | tvOS has `Font.tvEyebrow` 18/heavy/kerning 2.4; iOS has no equivalent, so `CompanionRootView` hand-rolls `.scCaption` + `.kerning(1.2)` at line 262 |
| A focus/press-scale token | `SquishButtonStyle` (0.88) and `BouncyPressStyle` (0.96) are duplicated private types in two files with different constants |
| A `Motion.press` spring | Same — `spring(0.25, 0.55)` and `spring(0.28, 0.55)` inline in two places |
| Ambient loop durations | `TransportBarView` uses 9s, `CompanionRootView` 1.1s, both inline |

**Note the two token files are separate.** `SoundingTV.swiftpm/Sources/Design/DesignSystem.swift` (`Font.tv*`, `Spacing` at 4/8/12/16/24/32/48/64/80, `CornerRadius`, `Animation.tvFocusSpring`) compiles into **both** apps. `SoundingTV-AppClip/Sources/AppClipDesign.swift` (`Font.sc*`, `Spacing` at 4/8/14/20/28/40, `Radius`, `Motion`) compiles into **iOS only**. They both declare `enum Spacing` — with **different values** — which works only because they are in different targets. Every new iOS token goes in `AppClipDesign.swift`. See §5.

---

## 3. The prescription

Ranked by visual impact per unit of work. Do them in this order.

| Rank | Item | Screen | Size |
|---|---|---|---|
| 1 | Now Playing: left-align, resize artwork, add paused shrink, strip button chrome | `NowPlayingSheet` | M |
| 2 | Now Playing: make it scroll; move comments / Behind / Up Next below the fold | `NowPlayingSheet` | M |
| 3 | Mini bar: remove glass-on-glass, adapt to placement, add `tabBarMinimizeBehavior` | `TransportBarView` + `PhoneRootView` | S |
| 4 | Waveform: promote to a real instrument (tall, expands under touch, comment rail) | `PhoneWaveformScrubber` | M |
| 5 | Home tab: hero + shelves | new file | M |
| 6 | Playlist/artist detail: bleeding hero + page-wide colour + Play/Shuffle above the list | `LibraryBrowserView` | M |
| 7 | Track actions row (like / playlist / queue / share) | `NowPlayingSheet` + rows | M |
| 8 | Tab bar: Home / Library / Search / Apple TV, Settings behind an avatar | `PhoneRootView` | S |
| 9 | Local Up Next screen | new file | M |
| 10 | "Behind This Track" sheet | new file | M |
| 11 | Apple TV tab: one dominant router, everything else quiet | `CompanionRootView` | S |
| 12 | Library: grid for playlists, keep list for tracks | `LibraryBrowserView` | S |
| 13 | Phantom surface | `CompanionRootView` / DJ | M |
| 14 | Token consolidation | `AppClipDesign.swift` | S |

Details follow.

### 3.1 `NowPlayingSheet` — the rebuild (rank 1–2, M+M)

**Structure.** Replace the fixed `VStack` with a `ScrollView` whose first "page" is exactly one screen tall, using `.containerRelativeFrame(.vertical)`. Everything else scrolls up from below.

```
┌─ screen 1 (containerRelativeFrame .vertical) ────┐
│  grabber (36 × 5, white 0.3, capsule)            │  ← replaces chevron.down
│                                                   │
│  ARTWORK                                          │
│                                                   │
│  title / artist ······················ (···)      │  ← left-aligned + trailing overflow
│  WAVEFORM SCRUBBER                                │
│  0:41 ··························· −2:37           │
│                                                   │
│      ⏮        ▶︎/⏸        ⏭                       │  ← bare glyphs
│                                                   │
│  ─────────── volume ───────────                   │
│                                                   │
│  💬 Comments    📺 iPhone ▾    ☰ Up Next          │  ← utility row
└───────────────────────────────────────────────────┘
     ↓ scroll
  [ Timed comments feed ]
  [ Behind This Track ]
  [ Up Next ]
```

**Geometry (402pt reference):**

| Element | Value |
|---|---|
| Horizontal page inset | **24pt** (down from `Spacing.xl` = 28; use a new `Spacing.page = 24`) |
| Artwork side | `width − 48` = **354pt** (88% of width). No 380 cap — cap at `min(width − 48, height × 0.46)` so it doesn't crowd on small devices |
| Artwork corner radius | **14pt** continuous (down from `Radius.xxl` = 34, which at 322pt reads as a rounded-rect app icon rather than a record sleeve) |
| Artwork border | 1pt `white 0.10` — keep |
| Artwork shadow, playing | `black 0.55, radius 30, y 18` |
| Artwork shadow, paused | `black 0.35, radius 14, y 8` |
| **Paused scale** | **0.82** — 354 → 290pt |
| Paused spring | `.spring(response: 0.42, dampingFraction: 0.86)` — add as `Motion.artwork` |
| Gap artwork → title | 28pt |
| Title | **22pt / bold**, kerning −0.4, left-aligned, `lineLimit(1)` |
| Artist | **22pt / regular**, `palette.current.accent`, left-aligned, `lineLimit(1)` |
| Title↔artist spacing | 2pt |
| Overflow button | 28pt glyph `ellipsis.circle.fill`, `.hierarchical`, `white 0.55`, 44pt tap target, trailing, vertically centred on the two-line block |
| Gap title block → scrubber | 24pt |
| Timestamps | 12pt / medium / monospacedDigit, `white 0.55`; **grow to 13pt / semibold / `white 0.9` while dragging** |
| Transport glyph, play/pause | **34pt heavy**, 72pt tap target |
| Transport glyph, prev/next | **28pt semibold**, 60pt tap target |
| Transport spacing | 40pt between centres |
| Gap scrubber → transport | 32pt |
| Volume row | 44pt tall; capsule 6pt at rest, `white 0.2` track / `white 0.7` fill; `speaker.fill` and `speaker.wave.3.fill` at 12pt `white 0.4` flanking |
| Utility row | three equal-width items, 20pt glyph over a 12pt semibold label, `white 0.75` |

**Alignment.** The title block, the scrubber, the timestamps and the utility row all share the **same 24pt leading edge as the artwork**. Only the transport cluster is centred. This one change — a single consistent left rule with one centred exception — does more for "premium" than any other item in this document.

**Kill the chrome.** Delete the `GlassEffectContainer` around the transport and the `.glassEffect(chromeGlassStyle, in: Circle())` on prev/next. They become bare `Image`s with `.foregroundStyle(.white)`. Keep `SquishButtonStyle` for press feedback (now the *only* press feedback, so raise the scale from 0.88 to 0.92 so it reads without a background to squeeze).

**The play button.** Two options, pick one and be consistent:
- **(a) Apple Music discipline:** bare 34pt `play.fill` / `pause.fill` in white, same as the others. Purest, and lets the artwork carry all the colour.
- **(b) Our identity:** keep a solid disc, but shrink 84 → **68pt**, and fill it with **`palette.current.accent`, not `Color.scAccentGradient`** — so it agrees with its own shadow and with the scrubber fill. Shadow `palette.accent 0.45, radius 18, y 8`.

I recommend **(b)**. It's one tinted primary action against otherwise-bare controls, which is exactly Apple's stated tinting rule, and it keeps a recognisable mark. But the fixed-orange gradient must go.

**Top bar.** Delete it. The chevron becomes a **36 × 5pt capsule grabber** at `white 0.3`, 12pt from the top, centred — the standard sheet affordance, and it frees the entire top-right corner. Output picker, comments and Up Next all move to the utility row and the below-fold content.

**Background.** Keep the `MeshGradient`. Two tweaks: raise the black overlay from `0.16` to **`0.22`** now that white text sits at the left edge over unpredictable mesh corners, and slow the drift from 9s to **14s** (9s is fast enough to notice, which ambient motion should never be — tvOS uses 12s / 46s / 61s / 97s deliberately non-harmonic periods).

**Below the fold.** Three sections, each a plain content block on the mesh (no glass — content layer):
1. **Comments** — the full timed feed inline (see §4.1). Section header `13pt heavy, uppercase, kerning 1.4, white 0.5`.
2. **Behind This Track** — see §4.2.
3. **Up Next** — the local queue, or the TV's, resolved by `PhonePlaybackCoordinator` (see §4.3).

**Scroll edge effect.** Exactly one, at the top. Do not add a second at the bottom.

**Landscape.** iOS 27's Now Playing supports it. Add a `ViewThatFits`/size-class branch: artwork on the leading half, the entire title/scrubber/transport column on the trailing half. `DJControlView` already proves the `ViewThatFits(in: .horizontal)` pattern in this codebase.

### 3.2 Mini bar (rank 3, S)

```swift
@Environment(\.tabViewBottomAccessoryPlacement) private var placement
```

- **Remove** the `.glassEffect(...)` at `TransportBarView.swift:101` entirely. The accessory container is already glass. Keep the palette tint by other means if wanted — but on iOS 27 the system will be drawing a darkened edge and brighter specular on that container, and a second glass layer inside it will fight both.
- **`.expanded`:** 44pt artwork (`Radius` concentric with the accessory capsule — use `RoundedRectangle(cornerRadius: .containerConcentric)` where available, else 12pt), title 15/semibold + artist 13/regular, play + next, **no progress capsule** (Apple Music has none; at 3pt under glass ours is noise).
- **`.inline`:** 28pt artwork, **title only**, play only. Nothing else fits and nothing else is needed.
- Cross-fade between the two with `Motion.gentle` (0.25s ease) — not a spring; this is a layout swap, not a physical event.
- Add `.tabBarMinimizeBehavior(.onScrollDown)` on the `TabView` in `PhoneRootView`. Without it the inline state effectively never occurs.
- Keep: the `appletv.fill` source glyph, the loading spinner, `matchedTransitionSource`, `.sensoryFeedback`. Those are all correct.

### 3.3 Waveform (rank 4, M) — see §4.1 for the full design

### 3.4 Home tab (rank 5, M)

Port tvOS `HomeView`'s shape, at phone scale.

| Element | Value |
|---|---|
| Hero card | full-bleed artwork, `height = width × 1.1`, corner radius 20 continuous, 24pt page inset |
| Hero scrim | `LinearGradient(black 0.0 @0.35 → black 0.75 @1.0)`, top→bottom, plus a leading `black 0.5 → clear @0.55` so left-aligned copy survives bright artwork (tvOS's `HeroBackground` needed exactly this — the note is verbatim in the file) |
| Hero eyebrow | 12pt heavy, uppercase, kerning 1.4, `white 0.8` — "FROM YOUR STREAM" |
| Hero title | 28pt heavy, kerning −0.6, 2 lines max, `minimumScaleFactor 0.8` |
| Hero byline | 15pt medium, `white 0.7` |
| Hero Play | `.glassProminent` capsule, `.tint(palette.accent)`, 44pt tall, leading-aligned under the byline |
| Shelf header | 20pt bold, 24pt leading inset, 12pt above the rail |
| Shelf card | `containerRelativeFrame(.horizontal, count: 2, span: 1, spacing: 14)` → ~166pt at 402. Square artwork, 12pt radius, title 14/semibold `lineLimit(1)`, subtitle 12/regular `white 0.55` |
| Shelf rail | `.scrollClipDisabled()`, `.safeAreaPadding(.horizontal, 24)` — content inset so cards align with the header but scroll edge to edge, exactly as tvOS does it |
| Section gap | 32pt |

Shelves: **Recently Played**, **From Your Stream**, **Your Likes**, **Playlists**. Reuse `LibraryBrowserViewModel`'s endpoints.

Row/card scroll settle: reuse `scRowTransition()` (opacity 0.5, scale 0.96) — it already exists in `LibraryBrowserView.swift:681` and should be lifted into `AppClipDesign.swift`.

### 3.5 Playlist / artist detail (rank 6, M) — the iOS 27 pattern

This is the screen with the largest gap-to-effort ratio after Now Playing.

```
┌──────────────────────────────┐
│                              │
│      ARTWORK (bleeds)        │   width × 0.72 tall, masked to fade out
│                              │   over the bottom 40%
│ ░░░░░░ fades into page ░░░░░ │
│                              │
│  Playlist Title              │   26pt heavy, kerning −0.5, left
│  Owner · 24 tracks · 1h 38m  │   14pt regular, white 0.6
│                              │
│  [ ▶︎ Play ]  [ ⇄ Shuffle ]   │   two capsules, 46pt tall, equal width
│  ♡   ⤓   ↑   ⋯               │   like / download / share / more
│                              │
│  1. Track ················   │
└──────────────────────────────┘
```

- The **whole page background** is `NowPlayingPalette`-style mesh derived from *this* artwork, not the now-playing one. Extract a second, non-singleton palette instance keyed to the detail item. (`NowPlayingPalette.extract` is already `nonisolated static` — reuse it directly.)
- Hero mask: `.mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.6), .init(color: .clear, location: 1.0)], startPoint: .top, endPoint: .bottom))`. This is the *"blends downward into the page content below it"* behaviour, verified live in the iOS 27 beta.
- **Play and Shuffle above the track list** is non-negotiable — it is the explicit point of the iOS 27 redesign.
- Zoom transition source stays `playlist.id` in `libraryNamespace`; it already works.

### 3.6 Tab bar (rank 8, S)

```
Home   Library   Apple TV   [Search]
```

- `Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search)` — on iOS 26 it separates to the trailing edge; on iOS 27 it re-integrates. Both are correct automatically.
- **Settings leaves the tab bar** and becomes a circular avatar button in the Home nav bar's trailing slot (Apple Music's exact pattern). This is also better per Apple's rule: a tab bar is for persistent *content* destinations.
- Preserve the `PhoneAppState` shape-shifting: `.remoteOnly` drops Home, Library and Search, leaving Apple TV alone; `.unconfigured` still gets `WelcomeView` with a Settings escape hatch. That logic in `PhoneRootView` is correct and must survive.

### 3.7 Apple TV tab (rank 11, S)

Stop making five cards that look identical.

- **Output router becomes the hero:** full-width, 96pt tall, its own artwork-tinted glass surface (this one *is* chrome, so glass is legitimate), with the two destinations as large tappable halves showing the device glyph, name, and a live "playing here" indicator. Not a `.segmented` `Picker`.
- Connection state collapses to a **single 32pt status line** above it — glyph, one sentence, the pulsing dot. Not a card.
- Queue and DJ become two side-by-side 88pt tiles, not full-width rows.
- Keep `livePulse`. Extend it to the output router's active side.

### 3.8 Local Up Next (rank 9, M)

`QueueManagerView` currently reads `RemoteQueueClient` directly. Generalise: give it a source abstraction so it can render `PlayerService.queue` too, resolved by `PhonePlaybackCoordinator` — exactly the rule the coordinator exists to enforce. The row design, reorder, swipe-delete and haptics all carry over unchanged.

This also unblocks the Up Next section below the fold in Now Playing, and lets the `upNextLink` gate at `TransportBarView.swift:759` be deleted.

### 3.9 Token consolidation (rank 14, S)

Add to `AppClipDesign.swift` (**iOS only** — see §5):

```swift
extension Font {
    static let scHero     = Font.system(size: 28, weight: .heavy)   // Home hero
    static let scTitle3   = Font.system(size: 20, weight: .bold)    // shelf headers
    static let scNowTitle = Font.system(size: 22, weight: .bold)    // Now Playing title
    static let scNowArtist = Font.system(size: 22, weight: .regular)
    static let scEyebrow  = Font.system(size: 12, weight: .heavy)   // + .kerning(1.4) at call site
}

enum Spacing { /* … existing … */ static let page: CGFloat = 24 }

enum Motion {
    /* … existing … */
    static let artwork = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let press   = Animation.spring(response: 0.26, dampingFraction: 0.55)
    static let ambient = Animation.easeInOut(duration: 14).repeatForever(autoreverses: true)
}
```

Then delete the duplicated `SquishButtonStyle` (`TransportBarView.swift:26`) and `BouncyPressStyle` (`CompanionRootView.swift:407`) in favour of one shared `scPress` button style, and lift `scRowTransition()` out of `LibraryBrowserView`.

---

## 4. How our distinctive features get showcased

This is the part that matters. Apple Music has no waveform, no timed comments, no second-screen handoff, no manual mixer. Each of these should read as *the reason to use this app*, not as an extra icon.

### 4.1 Waveform + timed comments — the signature

Today: a 36pt strip with 5pt dots along its bottom edge and a bubble that floats over the title. It functions. It does not announce itself.

**Make it an instrument.**

| Element | At rest | Under touch |
|---|---|---|
| Lane height | **56pt** (from 36) | **96pt** |
| Bar pitch / gap | 4 / 1.5 → **3.5 / 1.5** (more bars, finer read) | same |
| Bar corner | 1.75 (half width — capsule bars) | same |
| Played fill | `palette.accent` | `palette.accent`, plus a 2pt playhead line at the drag point |
| Unplayed fill | `white 0.22` | `white 0.30` (whole control brightens) |
| Expansion animation | — | `.spring(response: 0.3, dampingFraction: 0.75)` |
| Haptic | — | `.sensoryFeedback(.selection)` on grab; `.impact(.light)` each time the drag crosses a comment marker |
| Timestamps | 12/medium `white 0.55` | 13/semibold `white 0.9` |

**Comment rail.** Move the markers **out of the waveform** into their own 14pt rail directly beneath it. This is the change that turns the feature from a decoration into a second timeline:

- Marker = a **10pt circular avatar** (not a 5pt dot) — the commenter's face, which is what makes SoundCloud's comments feel human. Fall back to a 6pt accent dot when the avatar hasn't loaded.
- Clusters (>1 comment) get a 14pt avatar with a `+N` badge, 9pt heavy, on an accent capsule.
- Keep `clusterTimedComments` with `minSpacing` raised from 22 → **26pt** to suit avatars.
- Markers are **tappable** (they aren't today — `.allowsHitTesting(false)`). Tap = seek to that moment and pop the bubble. This is the single most SoundCloud-native interaction in the app.

**Bubble.** Move it **below** the rail, not `y: -84` over the title. Glass is correct here (it is chrome floating over content), width `min(300, screenWidth − 48)`, `Radius.md`, tinted `palette.accent 0.16`, connector tick pointing *up* at its marker. Keep the ±2.5s activation window and the `.spring(0.3, 0.75)` entry.

**Feed below the fold.** The full comment list stops being a modal `.sheet` and becomes an inline section in the scrolled Now Playing page. Rows: 36pt avatar, name 14/semibold, timestamp badge in `palette.accent` 12/semibold, body 15/regular `white 0.85`. Tap seeks and scrolls the page back up to the player. Keep `Comment.searchQuery` and the "Search for this" action — on iPhone it can do more than tvOS could: **copy to pasteboard and offer a share sheet**, not just open a web search. That is a genuine phone-only advantage over the TV.

**Honesty rules stay.** No invented bars. Keep the dashed pulsing baseline and the exact `notice(for:)` string set. That discipline is part of why the tvOS app reads as well-made.

### 4.2 "Behind This Track"

Currently aspirational everywhere: `BehindTheTrackView` is *called* at `PlayerView.swift:163` and `:338` but **has no definition anywhere in the repo** — a concurrent agent is building it on tvOS right now. Design the phone version to the same content model so both can share it.

Below the fold in Now Playing, as a content card (flat `scCard`, not glass):

- **Eyebrow:** "BEHIND THIS TRACK", 12 heavy, kerning 1.4, `palette.accent`.
- **Description** — `Track.description`, 15/regular `white 0.85`, `lineLimit(4)` with a "More" disclosure that expands in place (`Motion.expand`). Most SoundCloud descriptions are where the artist actually says something; this is real content, not filler.
- **Stats strip** — three columns: plays, likes, reposts. Value 20/heavy monospacedDigit, label 11/semibold uppercase `white 0.45`. Reuse tvOS's `formattedCount` (1.2M / 4.3K).
- **Uploaded** — relative date, 13/regular `white 0.5`.
- **Artist row** — 44pt circular avatar, name 16/semibold, follower count 13 `white 0.55`, trailing Follow capsule.
- **Tags** — SoundCloud genre/tag list as small capsules, 12/semibold, `white 0.08` fill, tappable into Search.
- **Open on SoundCloud** — a quiet trailing link, 13/semibold `palette.accent`.

Empty behaviour: if `description` is nil, the section renders **stats + artist only** and never says "no description". An absence rendered as an absence, matching the mini bar's own rule.

### 4.3 Apple TV handoff — never a modal chore

The rule: **routing is a control, not a screen.** It already half-follows this; finish the job.

1. **In Now Playing, the route lives in the utility row**, not a top-bar glass circle. Item label is the *current* device name — "iPhone" or "Apple TV" — with the matching glyph, so it reads as a status *and* a control, exactly like an AirPlay button. Tap opens the inline `Picker` menu that already exists.
2. **When the TV is playing, say so on the artwork**, not just under the artist. A small glass capsule pinned to the artwork's bottom-leading corner (12pt inset): `appletv.fill` + "Apple TV", 12/semibold. It reads at a glance from across the room, which is the situation you are in when the TV owns the session.
3. **Moving the session gets a physical animation.** `moveSession(to:)` is currently silent until the snapshot flips. Give it: the artwork scales to 0.94 and the route glyph does a `.symbolEffect(.bounce)` while the move is in flight; `.sensoryFeedback(.success)` on arrival. Roughly 400ms of "it went somewhere". This is the app's most impressive trick and it currently has no choreography at all.
4. **The Apple TV tab keeps everything else** — the queue, the DJ console, the connection detail. Now Playing only ever offers *where does this play*.
5. **Never block.** Preserve the existing discipline: connection state is inline content, link errors are alerts, only pairing is a `fullScreenCover`. That is already right and a redesign must not undo it.

### 4.4 DJ mode and Phantom

**Phantom's engine is real and tested; Phantom has no UI anywhere.** `PhantomDJEngine.swift` (415 lines) produces a `Plan { mixPointSeconds, transitionSeconds, outroShape, accent, reasoning }`, and `PlayerService` publishes `isPhantomEnabled` and `phantomActivity: PhantomActivity` with a ready-made `.label`. **No view in either app reads either property.** The phone should be where Phantom gets its face — it is the device you have in your hand while the mix runs.

Given tvOS 27 brings Apple's own AutoMix to Apple TV, our differentiation must be **visibility and honesty**, not automation:

- **Phantom card in the Apple TV tab and in Now Playing's below-fold**, only while `isPhantomEnabled`. It shows `PhantomActivity.label` plus, crucially, **`Plan.reasoning`** — the sentence explaining *why* it chose that mix point. Apple's AutoMix is a black box; ours explains itself. That is a defensible product difference, and it costs nothing because the string already exists.
- Armed state renders a **countdown to `mixPointSeconds`** on the waveform: a translucent accent band from the mix point to `mixPoint + transitionSeconds`, matching the `MIX` overlap band tvOS's `DJModeView` already draws (`scAccent 0.10` fill, `scAccent 0.40` 1pt stroke).
- **Reuse `.cutting`'s honesty.** When Phantom falls back to a hard cut it must say so — the type is already designed for that (*"Phantom never fakes a mix"*). Surface it.
- Manual `DJControlView` stays as-is visually; it is the best-looking screen in the phone app and its warm/cool deck split (deck A `rgb(1.00, 0.478, 0.157)`, deck B `rgb(0.486, 0.455, 1.00)`) should be lifted into the token file so Phantom's UI can use the same two colours.

### 4.5 Track actions

Four verbs, three placements, one behaviour each — no verb should mean different things in different places:

| Verb | Now Playing | List row | Where |
|---|---|---|---|
| Like | in the overflow menu **and** as a standalone heart in the utility row (it's the most-used) | swipe leading | `heart` / `heart.fill` + `.symbolEffect(.bounce)` |
| Add to Playlist | overflow menu | context menu | needs `TrackActionsProviding`, which like `BehindTheTrackView` does not exist yet |
| Add to Queue | overflow menu | swipe trailing (exists) + context menu (exists) | `text.append` |
| Share | overflow menu | context menu | `ShareLink` with `permalinkURL` |
| Play on Apple TV | — (the route control covers it) | context menu (exists) | gated on `isAppleTVAvailable`, `nil` not disabled |

Confirmation: keep `QueueConfirmationController`'s 2s glass capsule. It's the right weight. Move it to a shared file so `NowPlayingSheet` can use it too.

### 4.6 Downloads and tier gating

Both services (`DownloadManager`, `SubscriptionService`) are wired into `PhoneSettingsView` and nowhere else. Two surfaces:

- **A download glyph in the playlist/artist detail action row** (`arrow.down.circle` → determinate `ProgressView` → `checkmark.circle.fill`), and a small filled-circle badge on downloaded rows.
- **Tier gating renders as absence, not as a locked door.** An unentitled track already has empty `transcodings` and a nil `streamURL` by construction in `Track.init`. The UI must reflect that state honestly — a dimmed row with a quiet "Not available on your plan" — and must never render a play affordance that can't work. **Do not build any UI that implies a preview, an unlock path, or an ad-strip.** See §5.

---

## 5. Traps

Things a redesign will break if nobody says this out loud.

1. **`SoundingTV.swiftpm/Sources/Design/DesignSystem.swift` compiles into BOTH apps.** Changing `Spacing.*`, `CornerRadius.*`, `Color.sc*`, `Font.tv*` or `Animation.tvFocusSpring` changes the tvOS app. Every iOS-only token goes in `SoundingTV-AppClip/Sources/AppClipDesign.swift`. Note both files declare `enum Spacing` with **different values** (tv: 4/8/12/16/24/32/48/64/80; iOS: 4/8/14/20/28/40) — they only coexist because they are in different targets. Do not "unify" them.

2. **`Color.scAccent` and `Color.scAccentGradient` are declared in both files, with different values.** tvOS's gradient is `[scAccent, scAccent.opacity(0.78)]`; iOS's is `[scAccent, scAccentWarm]`. Touching either has a blast radius.

3. **The `ZStack` sibling height trap.** A full-bleed backdrop must be `.background()`, not a `ZStack` sibling, or it drives the stack's height and pushes content off screen. `CLAUDE.md` says this cost real debugging time twice. The new Home hero and the bleeding playlist hero are both exactly the shape that triggers it.

4. **Glass on glass, three live instances.** (a) The mini bar glasses inside the already-glass `tabViewBottomAccessory`. (b) `NowPlayingSheet`'s comment bubble is glass floating over a screen that has up to six other glass shapes. (c) `DJControlView`'s "engine isn't live" banner is glass over a screen of glass panels. Fix (a) at minimum. On iOS 27, with darkened edges added to every glass element, doubled edges become obvious.

5. **`tabViewBottomAccessory` sizes itself.** The system draws the accessory's capsule unconditionally the moment the modifier is attached — zero-height content still leaves a full-size empty pill. `PhoneRootView.swift:267`'s `BottomAccessoryModifier` documents this empirically. `isEnabled:` is **iOS 26.1**; our floor is **26.0**, where the only fix is not attaching the modifier, which rebuilds the `TabView` and pops every navigation stack. Any redesign that adds depth to navigation makes that pop more expensive. Do not raise the floor casually and do not remove the fallback.

6. **Entitlement enforcement lives in `Track.init`**, which filters snippet transcodings out so `transcodings` is empty and `streamURL` is nil. Never write UI that unlocks previews, bypasses the check, or strips ads — including for content moved peer-to-peer between the user's own devices.

7. **`AuthenticationService` is tvOS-only.** Nothing in `SoundingTV.swiftpm/Sources/` may reference it. If a shared component (say, an artist Follow button) needs "who am I", it must go through `SoundCloudCredentialSource`, not the auth service.

8. **Two live `TokenTransferProtocol.swift` copies must stay byte-identical.** They are the wire contract. Nothing here touches them, but any handoff-choreography work might.

9. **`project.pbxproj` is a serialisation bottleneck.** This spec adds ~5 new files (Home, playlist detail, Behind This Track, local Up Next, shared components). Register them from the main session; do not let parallel agents touch the project file.

10. **`.glassEffect()` must be the last modifier in the chain**, and `.glassEffectID` must immediately follow it. `GlassComponents.swift`'s `liquidGlass(in:id:namespace:...)` overload exists because of this.

11. **Reduce Motion is a token, not a call-site decision.** Every new spring goes through `Animation.scMotion(_:reduceMotion:)` (iOS) or `View.scMotion(_:reduceMotion:value:)` (shared). The new ambient loops (Home hero, playlist hero, waveform expansion) all need the `guard !reduceMotion else { return }` at the source, not merely a shortened duration. Note `DJModeView.CinematicBackdrop` is currently missing this guard — a pre-existing bug, worth fixing while nearby.

12. **`PhonePlaybackCoordinator` is the only thing allowed to decide local-vs-TV.** No new view may re-derive it. Every new surface — Home hero, Up Next, Behind This Track, the route capsule on the artwork — reads `nowPlaying` / `activeSource` and dispatches through the coordinator's verbs.

13. **Don't regenerate from `project.yml`.** It is stale; the `.xcodeproj` has diverged deliberately.

14. **Do not run `xcodebuild` from a parallel agent** while others are building.

---

## 6. Sources

Verified this session:

- [Get to know the new design system — WWDC25 session 356](https://developer.apple.com/videos/play/wwdc2025/356/) — layer model, left-aligned typography, concentric radii, tinting, tab-bar accessories, scroll edge effects, bar organisation
- [Meet Liquid Glass — WWDC25 session 219](https://developer.apple.com/videos/play/wwdc2025/219/)
- [Liquid Glass — Apple Developer Documentation](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass)
- [LiquidGlassReference (third-party API compendium)](https://github.com/conorluddy/LiquidGlassReference) — `glassEffect` / `glassEffectID` / `GlassEffectContainer` signatures, placement rules, `tabViewBottomAccessory`, concentric radii
- [Enhancing the tab bar with a bottom accessory — Create with Swift](https://www.createwithswift.com/enhancing-the-tab-bar-with-a-bottom-accessory/) — `.expanded` vs `.inline`, `tabBarMinimizeBehavior`
- [Tab Bar: Bottom Accessory Placement for iOS 26 — SwiftUISnippets](https://swiftuisnippets.wordpress.com/2025/07/15/tab-bar-bottom-accessory-placement-swiftui-for-ios-26/)
- [Here's How Liquid Glass Is Changing in iOS 27 — MacRumors](https://www.macrumors.com/2026/06/10/how-liquid-glass-is-changing-in-ios-27/) — darkened edges, brighter specular, transparency slider, automatic adoption
- [Apple Music in iOS 27 introduces new design changes in two key areas — 9to5Mac](https://9to5mac.com/2026/06/19/apple-music-in-ios-27-introduces-new-design-changes-in-two-key-areas/) — artist page bleed, page-wide colour, controls above catalogue, featured card
- [Apple Music iOS 27 Design Changes: What's Live vs. Promised — Gadget Hacks](https://apple.gadgethacks.com/news/apple-music-ios-27-design-changes-whats-live-vs-promised/)
- [iOS 27: Here's all the new Apple Music features — 9to5Mac](https://9to5mac.com/2026/06/10/ios-27-heres-all-the-new-apple-music-features/) — portrait+landscape Now Playing, AutoMix on Apple TV/HomePod
- [Apple Announces tvOS 27 — MacRumors](https://www.macrumors.com/2026/06/08/apple-announces-tvos-27/) and [Everything New Coming To tvOS 27 — BGR](https://www.bgr.com/2190232/tvos-27-new-features-apple-tv-wwdc-2026/) — Hi-Res Lossless 24/192, AutoMix + Crossfade, Larger Text, faster launches
- [What Is AutoMix on iOS 26 — MacObserver](https://www.macobserver.com/tips/automix-explained-ios-26/) and [Apple Music's new AutoMix feature — MusicTech](https://musictech.com/news/gear/apple-music-automix-ai/) — time-stretch/beat-match, "Mixing" animation on Now Playing
- [Apple Music brings your Lock Screen to life with new iOS 26 look — 9to5Mac](https://9to5mac.com/2025/06/11/apple-music-brings-your-lock-screen-to-life-with-new-ios-26-look/) and [iOS 26 Offers Full-Screen Animated Album Art — MacRumors](https://www.macrumors.com/2025/06/11/ios-26-animated-lock-screen-album-art/)
- [iOS 26.1 Beta Adds Swipe Gesture to Apple Music MiniPlayer — MacObserver](https://www.macobserver.com/news/ios-26-1-beta-adds-swipe-gesture-to-apple-music-miniplayer/)
- [Liquid Glass Is Cracked, and Usability Suffers in iOS 26 — NN/g](https://www.nngroup.com/articles/liquid-glass/) — the contrast criticism iOS 27's slider answers

Recalled, not verified: everything in §1.3.
