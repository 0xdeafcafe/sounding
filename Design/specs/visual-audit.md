# SoundingCloud — Visual Audit

**Date:** 2026-08-03 · **Auditor:** subagent, read-only · **Verdict on the owner's verdict:** substantiated.

Screenshots referenced inline live in `/Users/afr/.claude/jobs/3fc7cb5a/tmp/audit/`. Every claim below is either a screenshot reference, a `file:line`, or a measured pixel value. Where I am inferring rather than observing, it says **[inferred]**.

> **Direction set by the owner during this audit, and now binding on §4 and §5.5:** the DJ screen is *meant* to look like glassy Pioneer CDJs plus an Allen & Heath–style mixer, while staying easy to use on TV, iPhone and iPad. My first-pass reading of that screen as a "style collision" was wrong and has been corrected. DJ mode is the one place in the app where glass belongs on content, and that exception should be written into `CLAUDE.md` rather than treated as a violation.

---

## 0. Method, and what I could not do

**Built and ran both apps.** Both deployment targets are **27.0** (`project.pbxproj`: `TVOS_DEPLOYMENT_TARGET = 27.0`, `IPHONEOS_DEPLOYMENT_TARGET = 27.0`) — note `CLAUDE.md` still says 26.0, which is now wrong and sent me down a blind alley. No iOS 27 or tvOS 27 *device* existed; I created `AuditTV27` (`4AA45D87…`) and `AuditPhone27` (`A024E8B9…`).

- tvOS: **BUILD SUCCEEDED** first time (`build-tvos.log`).
- iOS: **BUILD FAILED** on the first two attempts — `SoundingTV.swiftpm/Sources/Services/WaveformService.swift:607:28: error: cannot call value of non-function type 'Float?'`, an in-flight edit by a concurrent agent (`build-ios.log`). I did not touch it. It went green ~2 minutes later (`build-ios2.log`) and I proceeded. **The concurrent agent's broken intermediate state also broke the tvOS target**, since that file is shared — worth knowing that a bad edit in `swiftpm/Sources/Services/` takes both apps down at once.

**What I could not capture, and why.**

1. **I could not drive the tvOS remote.** This Xcode (`/Applications/Xcode-beta.app`, Xcode 27.0 / 27A5228h) ships **no `Simulator.app`** — `Contents/Developer/Applications/` does not exist — and `xcrun simctl` has no `sendkey`/`press` verb. So there is no way to move focus. Everything in §4 about focus is therefore from (a) the *default* focus state each screen lands on, which I did capture, and (b) an exhaustive `file:line` inventory of every focus modifier in the tree. I could not verify **focus traversal order** (does it jump between columns oddly) — that one question in the brief is unanswered and needs a human with a remote.
2. **iOS demo data does not exist.** `DemoSeed` lives in `DesignSystem.swift`, which is in the **tvOS target only** (that is why the two `enum Spacing` declarations can coexist). `SOUNDING_TV_DEMO=1` is a no-op on the phone. So every iOS screen I captured is an **empty/unpaired state**. I could not see the iOS mini player, the expanded Now Playing sheet, the waveform, or a populated library. **This is itself a finding**: the phone app has no way to be seen in its loaded state without a live SoundCloud account, which is exactly how it came to be designed blind.
3. Sub-screens behind a tap (tvOS Settings → Playback/Downloads/Devices/About, playlist detail, comments panel, Behind The Track, Ambient screen) are unreachable without a remote.

**Cold start is slow.** On tvOS the app showed a featureless blurred gradient at 2s, 4s and 8s (`tv-settings-t2s.png`, `-t4s.png`, `-t8s.png` — byte-identical) and full content by 25s (`tv-settings-t25s.png`). **[inferred]** — I cannot separate "app is slow" from "simulator framebuffer is stale"; the three screenshots being *byte-identical* across two different launches makes me suspect the latter. Do not act on this without measuring on a device. What is *not* inferred: whatever the cause, there is **no skeleton, spinner or placeholder** in that window — the first thing a user sees is an empty wash.

---

## 1. The three changes that do most of the work

| # | Change | Why | Size |
|---|---|---|---|
| **1** | **Clamp the artwork-derived palette against a contrast floor, and stop drawing white text on it unconditionally.** Today the Now Playing background is whatever colour the artwork happens to be — measured **`#9FA07B`, a light khaki** — and the text ramp is white-at-opacity regardless. Measured contrast: title **2.70:1**, artist **1.96:1**, metadata **1.78:1**. | This is the app's most important screen and its text is, by measurement, illegible. It is the single largest gap between "looks designed" and "looks broken", and it is the literal content of "all weird colours". | **M** |
| **2** | **Collapse the focus system to one specification.** There are currently **10 distinct scale factors, 9 focus shadow radii, 3 ring widths across 7 ring colours**, and **5 components whose ring runs backwards** (visible at rest, invisible when focused). Nine of the app's primary content cards don't use the custom system at all. | "Bad focus states" is not one bug, it is the absence of a spec. One spec applied everywhere is a mechanical change with a disproportionate payoff. | **M** |
| **3** | **Make the two token files one system with two scales.** They are currently unrelated files that happen to share type names with different values. `Spacing.md` is 16 on tvOS and 14 on iOS. `scAccentGradient` is a fade-to-transparent on tvOS and a two-hue gradient on iOS. **11 of the 18 tvOS colour tokens have zero references** while their values are re-typed inline and then drift. | Every other finding in this document is downstream of this. Until roles are named once, parallel agents will keep inventing values. | **M** |

---

## 2. Colour — forensic

### 2.1 The headline: text on artwork-derived backgrounds fails, badly

Measured from `tv-01b-home-30s.png` (tvOS Now Playing, demo track "Coastline"). Ambient background sampled at **`#9FA07B`**.

| Element | Sampled | Contrast vs background | WCAG |
|---|---|---|---|
| Track title (76pt) | `#FFFFFF` | **2.70 : 1** | **FAIL** (large text needs 3:1) |
| Artist name | `#DCDCD8` | **1.96 : 1** | **FAIL** |
| Metadata "3:33 · 184.2K likes · 4.1M plays" | `#D2D2CD` | **1.78 : 1** | **FAIL** |
| Waveform, unplayed portion | `#C3C4BC` | **1.53 : 1** | **FAIL** |

See `crop-tv-np-actionrow.png` — the metadata line is visibly ghosted. Four of four measured elements fail; the *best* result on the screen is the 76pt title at 2.70:1.

The root cause is architectural, not a bad colour choice. `DesignSystem.swift:29-32` defines the text ramp as `Color.primary` at opacities `1.0 / 0.66 / 0.40 / 0.24`. That is correct **for a black background**. The background is not black — it is sampled from artwork and can be any luminance. Nothing reconciles the two.

**Three separate artwork-colour derivations exist, with four different clamp sets, and none of them measures contrast against the text that will sit on top:**

- `ArtworkColors.boost` — `SoundingTV.swiftpm/Sources/Services/ArtworkColors.swift:112-113` — brightness ×1.05, ceiling 0.85
- `NowPlayingPalette.boost` — `SoundingTV-iOS/Sources/TransportBarView.swift:484-485` — brightness ×0.85, ceiling 0.55
- `PlayerView.vivid` — `SoundingTV.swiftpm/Sources/Views/Player/PlayerView.swift:1476-1477` — brightness ×1.2, ceiling 0.95

Three functions, one job, three answers. The tvOS one (ceiling **0.85**) is the permissive one, and tvOS is where the failure is measured.

The same failure is worse in DJ mode (`tv-dj-mode.png`, background `#424031`):

| Element | Contrast | |
|---|---|---|
| Deck B "UP NEXT" eyebrow | **1.87 : 1** | **FAIL** |
| Deck B artist | **2.54 : 1** | **FAIL** |
| Deck B BPM/KEY/ENERGY values | **2.69 : 1** | **FAIL** |
| "~ estimated, not measured" | **2.61 : 1** | **FAIL** |
| Error string (see §5) | **2.98 : 1** | **FAIL** |
| Even the accent-orange "DJ MODE" eyebrow | 3.44 : 1 | large-only |

See `crop-tv-dj-deckb.png`. The entire right-hand deck is dimmed to signal "not playing yet" and lands below legibility while doing it.

### 2.2 White on the accent orange fails everywhere it is used

Computed, not guessed:

| Fill | White on it | Black on it |
|---|---|---|
| `scAccent` dark `#FF6B1A` | **2.85 : 1** | 7.37 : 1 |
| `scAccentWarm` dark `#FF9933` | **2.13 : 1** | 9.86 : 1 |
| `scError` `#FF4F45` | **3.25 : 1** | 6.46 : 1 |
| `scSuccess` `#33C759` | **2.22 : 1** | 9.45 : 1 |

**Every one of these needs black text, and the app mostly uses white.** iOS "Sign In with SoundCloud" (`ios-ready-library.png`) is white on `#FF6B19` = **2.85:1**. tvOS "Sign Out" (`tv-tab-profile.png`) is white on `#FE635B` = **3.25:1**.

tvOS Settings gets it *right* — the focused row uses dark text on orange (`tv-settings-t45s.png`, measured `#2D1304` on `#EC6317`) — which makes the inconsistency worse, not better: the same accent fill carries black text in one place and white in another.

### 2.3 The token files are bypassed, not used

From the full inventory:

- **11 of 18 colour tokens in `DesignSystem.swift` have zero references.** `scSurface`, `scSurfaceHover`, `scSurfaceActive`, `scSeparator`, `scTextSecondary/Tertiary/Quaternary` and others are dead. Their *values* (`0.06`, `0.10`, `0.12`, `0.20`, `0.24`, `0.40`, `0.66`) are re-typed inline at the call site — and have since drifted.
- **38 distinct `.white.opacity(…)` values across 213 call sites.** Of those, **24 distinct values serve "secondary/tertiary text"** and **12 distinct values serve "card surface"**. The most-used single value is `0.55` (25 sites) — which is not a token.
- **16 distinct `.black.opacity(…)` values across 62 sites** (shadows and scrims).
- **17 distinct `scAccent.opacity(…)` values across 47 sites.**
- iOS has **no text tokens and no semantic colours at all** — `AppClipDesign.swift` defines only `scAccent`, `scAccentWarm`, two gradients, `scSurface` (unused) and `scAmbientFallback`. Hence raw `Color.red` / `Color.green` / `.secondary` scattered through `PhoneSettingsView.swift`, `CompanionRootView.swift`, `DJControlView.swift`.

### 2.4 Same role, different value — the ones that show on screen

| Role | Competing values | Evidence |
|---|---|---|
| Accent (primary) | tvOS light `rgb(0.95,0.30,0.00)` vs iOS light `rgb(0.96,0.30,0.0)` — **differ by 0.01 red for no reason** | `DesignSystem.swift:36` vs `AppClipDesign.swift:18` |
| Accent (rendered) | flat `#FF6B19` on the CTA vs gradient `#FF7E33` on the empty-state icon, **30pt apart on the same screen** | `crop-ios-two-oranges.png` |
| `scAccentGradient` | tvOS `[scAccent, scAccent.opacity(0.78)]` vs iOS `[scAccent, scAccentWarm]` — same name, completely different look | `DesignSystem.swift:54` vs `AppClipDesign.swift:29` |
| `scSurface` | tvOS `white.opacity(0.06)` vs iOS opaque `#1C1C21` / pure white in light | `DesignSystem.swift:23` vs `AppClipDesign.swift:46` |
| App background | iOS Library tab renders **`#000000`**, iOS Settings/Apple TV tabs render **`#0C0C15`** — two backgrounds inside one `TabView` | `ios-ready-library.png` vs `ios-ready-settings.png` |
| Deck identity | Deck B is **purple `#6B6BE8`-ish**, a hue in neither token file — but see §5.5.2: this is a *correct* instinct that needs tokenising, not removing | `tv-dj-mode.png`, `DJControlView` deck constants |
| Destructive | `scError` used for **destructive actions** *and* for a **+30.8% tempo delta** (`#EC4D43`, bottom right of `tv-dj-mode.png`). Out-of-pitch-range deserves its own amber role, not the error colour |

### 2.5 Half of both token files is dead code

`.preferredColorScheme(.dark)` is applied at **17 sites**, including both app roots:

```
SoundingTV.swiftpm/Sources/App/SoundingTVApp.swift:33
SoundingTV.swiftpm/Sources/Views/RootView.swift:34
SoundingTV-iOS/Sources/SoundingTViOSApp.swift:104
```

The app is dark-only, permanently. I verified this empirically: `xcrun simctl ui … appearance light` changes nothing (`ios-light-settings.png` is visually identical to `ios-ready-settings.png`).

Therefore every `Color(light:dark:)` light branch, every light gradient stop, `scSurface`'s light value (`Color.white`), and the whole `init(light:dark:)` machinery are **unreachable**. That is a meaningful fraction of both files, and it is actively misleading — it reads as a considered two-mode system that has never rendered once.

### 2.6 Surfaces are invisible

| Surface | vs its background | Verdict |
|---|---|---|
| tvOS Settings category row `#161616` on `#000000` | **1.16 : 1** | no perceptible edge |
| tvOS Settings detail row `#101010` on `#000000` | **1.10 : 1** | no perceptible edge |
| iOS card `#2E2E37` on `#0C0C15` | **1.45 : 1** | barely |

See `crop-tv-settings-surfaces.png`. At 3 metres the tvOS rows have no boundaries — the layout reads as floating text, and the *only* row you can see is the focused one. That is why the focused orange row looks so violent: it is the sole element with any contrast on the screen.

### 2.7 What is genuinely good here

- The accent hue itself is right — SoundCloud orange, and `DesignSystem.swift:6-9` documents the "don't tint everything" rule correctly. The rule is good; it just isn't followed.
- `tv-signedout-qr.png` (QR sign-in) is the **best screen in either app** and should not be touched: single centred column, real hierarchy (title → instruction → code → status → action → reassurance), the accent used exactly once as a bloom behind the code, generous rhythm. Whoever did this understood the assignment.
- tvOS Library's *content* colours are fine: card title `#FFFFFF` at 20.42:1, artist `#7F7F7F` at 5.10:1 (`tv-tab-library.png`). The black-background screens are not the problem; the artwork-tinted ones are.

---

## 3. Focus — tvOS

`CLAUDE.md` states the rule: content cards/rows use `scaleEffect` + drop shadow + accent ring with `.focusEffectDisabled()`; glass is chrome only, never content, never glass-on-glass.

### 3.1 There is no single treatment — there are ten

**10 distinct scale factors:** 1.02, 1.03, 1.04, 1.05, 1.06, 1.08, 1.09, 1.11, 1.12, 1.14.

Five of them — 1.02 / 1.03 / 1.04 / 1.05 / 1.06 — are within 4% of each other and **visually indistinguishable at 3 metres**. That is five decisions where one would do:

- 1.02 `PlaylistPickRow` — `PlayerActions.swift:348`
- 1.03 `CategoryRow` — `SettingsView.swift:776`; `CommentRow` — `PlayerView.swift:2050`
- 1.04 four capsule buttons — `SettingsView.swift:1284, 1318, 1566, 1592`
- 1.05 `UpNextRow` — `PlayerView.swift:980`; `RelatedTrackCard` — `BehindTheTrackView.swift:385`
- 1.14 `ControlButton` — `PlayerView.swift:2159`

**9 distinct focus shadow radii** (8, 10, 12, 14, 16, 18, 20, 22, 24) and 22 shadow radii overall. **There is no shadow token in `DesignSystem.swift` at all** — all 62 `.shadow(` calls are literals. `y` offsets are equally ad hoc (1, 3, 4, 6, 8, 12, 14, 16, 18, 22, 36, 40, 60, 70), and ten call sites have no `y` at all.

**3 ring widths across 7 colours**, using **six different accent opacities for the same "this is focused" signal**: 0.55, 0.65, 0.70, 0.75, 0.85, 1.0.

### 3.2 Five components run the focus ring backwards

The ring is present at rest and **disappears on focus**:

- `ScopeToggle` — `SettingsView.swift:1245` (`white@0.12` → `white@0`)
- `DestructiveCapsuleButton` — `SettingsView.swift:1282` (`scError@0.45` → `scError@0.0`)
- `DebugActionButton` — `SettingsView.swift:1317`
- `SignOutButton` — `SettingsView.swift:1564`
- `GlassActionButton` — `QRCodeLoginView.swift:534-537` (`white@0.16` → `.clear`)

### 3.3 Invisible focus has been reintroduced — three times, in one file

`CLAUDE.md` documents this exact trap. It is live in `BehindTheTrackView.swift`:

- `:224-226` loading row — `.focusable()` + `.focusEffectDisabled()`, **no `@FocusState` at all**, so it cannot even know it is focused
- `:231-233` error row — same
- `:238-240` empty row — same

Focus lands on a spinner or a sentence and nothing changes on screen.

Separately, `DJPillButton` (`DJModeView.swift:1785`) calls `.focusable()` **without gating on `isEnabled`**, then `guard isEnabled else { return }` in its tap handler (`:1789`). "Mix Now" takes full focus treatment — scale, shadow, ring — while being inert. Compare `StepButton.focusable(!disabled)` (`SettingsView.swift:1216`) and `CommentRow.focusable(isSeekable)` (`PlayerView.swift:2058`), which do it correctly in the same codebase.

Three `.focusSection()`s can contain zero focusable children:
- `PlayerView.swift:336` `upNextSection` when the queue is empty — an empty focus region sitting between the hero and the transport row
- `BehindTheTrackView.swift:105` `statsRow` — permanently empty
- `PlayerView.swift:1941` `commentsList` — empty when no comment is timed

**Credit where due:** `HomeView`, `LibraryView`, `SearchView`, `DJModeView` and `QRCodeLoginView` all handle their empty/loading/error branches correctly, several with comments explaining the previous bug. `StatusPanel` (`GlassComponents.swift:314-323`) and the Settings detail container (`SettingsView.swift:245-258`) are focusable-with-no-action *and* draw a 3pt ring — the right answer.

But `SettingsView`'s safety depends on `detailHasFocusableContent(...)`, a **hand-maintained map** at `:128-132`. It will rot the first time a pane's contents change.

### 3.4 The app's most-used surfaces don't use the custom system at all

Nine primary content components rely on the **system** focus effect — the exact Liquid-Glass halo every bespoke control in the app is written to suppress:

| Component | file:line | Style |
|---|---|---|
| Home shelf card | `HomeView.swift:309-346` | `.buttonStyle(.borderless)` + `.hoverEffect(.highlight)` |
| Home hero "Play" | `HomeView.swift:154-164` | `.borderedProminent` |
| Library likes / playlists / following cards | `LibraryView.swift:106-201` | `.borderless` + `.hoverEffect(.highlight)` |
| Library section `Picker` | `LibraryView.swift:39-44` | `.segmented` |
| Search result card | `SearchView.swift:55-82` | `.borderless` + `.hoverEffect(.highlight)` |
| `NowPlayingView` "Browse Home" | `NowPlayingView.swift:40-53` | `.plain` |

This is visible in `tv-tab-library.png`: the selected "Liked" segment is a white pill, and there is no way to tell selection from focus. The two states share one visual.

### 3.5 Glass on content — six violations

**tvOS** (`DJModeView.swift`): `:984-987` jog-wheel platter (a data readout, and the code comment claims it is chrome), `:1219` mixer panel, `:1467` waveform panel.

**iOS** (`DJControlView.swift`): `:62` advisory card, `:249` deck console, `:1092` mixer console — while `AppClipDesign.swift:158-167` documents `scCard` as existing *precisely* so content blocks are not glass.

Borderline: `QRCodeLoginView.swift:531-532` stacks an **opaque white `Capsule` fill directly under `.liquidGlass`**, which nullifies the sampling glass exists to do.

**No glass-on-glass nesting found** — all four `GlassEffectContainer`s hold siblings, which is correct. But `DJModeView`'s header and transport row put **6 adjacent glass shapes on screen with no container** (`:1683, :1715, :1739`, 4× `:1778`), so each samples the scene independently — the exact cost the container exists to avoid, and a rule stated in `GlassComponents.swift:11-12`.

---

## 4. Composition — the worst three screens

### Worst #1 — tvOS Now Playing (`tv-01b-home-30s.png`)

The most important screen in the app, and the weakest.

- **Text is illegible** (§2.1): 1.78:1 on the metadata line.
- **The composition is a diagonal void.** Artwork sits at upper-left ~500×500 in a 3840×2160 frame (13% of width). Text runs upper-middle. The transport bar is bottom-centre. The entire right third and the lower-left quadrant are empty. There is no grid — the artwork's left edge (x≈200) and the title's left edge (x≈820) share nothing.
- **There is a completely empty circular button.** `crop-tv-np-actionrow.png` — the action row is heart / **[blank]** / add-to-playlist / QR / "DJ Mode" / info. The second circle renders no glyph. **[inferred]** cause: a missing or unavailable SF Symbol name.
- **The action row is unreadable at TV distance.** Icons in ~26pt circles; the row mixes four icon-only circles, one labelled pill, and one more icon-only circle, with no grouping logic.
- **"DJ Mode" is the highest-contrast control on the screen**, above play/pause. Visual weight is inverted against importance.

### Worst #2 — tvOS Settings (`tv-settings-t45s.png`)

- **Every surface is invisible** (1.16:1, 1.10:1) so the only legible element is the focused row, which is a full-saturation orange bar with a bloom. The screen reads as one orange stripe on black.
- **The two columns have no relationship.** Left rail 505pt wide, right detail pane 1110pt — the *subordinate* pane is more than twice the width of the navigation. Internal insets differ too: left rail icon inset 23pt, detail row icon inset 35pt.
- **~55% of the screen is empty** below two detail rows.
- 19 inline `.font(.system(size:))` calls in this file alone.

### Worst #3 — tvOS DJ Mode (`tv-dj-mode.png`)

The most *ambitious* screen, which is why its failures cost the most.

**First, a correction to my own initial read.** I originally filed the skeuomorphic knobs, tick rings and physical crossfader as a style collision. The owner has since confirmed the hardware look is **deliberate and wanted** — the target is glassy Pioneer CDJs plus an Allen & Heath–style mixer. That reframes the finding entirely, and I agree with the owner: it is the right direction and it is the app's strongest identity idea. The problem is not that it is skeuomorphic. **The problem is that it is half-committed** — the gear reads as flat dark discs rather than lit glass instruments, and it is rendered at a scale and contrast that make it unusable. Full direction in §5.5.

Real defects on this screen, independent of style direction:

- **Five failing contrast measurements** (§2.1), including the entire right-hand deck: "UP NEXT" at **1.87:1**, artist at **2.54:1**, BPM/KEY/ENERGY at **2.69:1**. The dimming used to say "cued, not playing" goes past "quiet" into "unreadable". On real gear the cued deck is *dimmer but never illegible* — its ring is lit amber instead of white, not faded to 20%.
- **27 inline font sizes in one file**, minimum **12pt** (`DJModeView.swift:1234`) — on a television. BPM, key and energy are the numbers a DJ actually reads; they are currently the smallest text on the screen.
- **A raw error string is product UI:** *"Knobs are a drawing — audio hard-cuts. Stream request failed with HTTP 404."* An HTTP status code, rendered at 2.98:1.
- `+30.8%` tempo delta rendered in `scError` red. On a CDJ the tempo display is neutral until it exceeds the pitch range — red at +30.8% is arguably *correct* here, but it must be a deliberate `tempo.outOfRange` role, not `scError` borrowed.
- The knobs are **six identical unlabelled discs**; only their captions (LOW/MID/HIGH) distinguish them, at 13pt.

### The rest, briefly

- **tvOS Home** (`tv-tab-home.png`) — good bones, one systemic flaw: **the hero has no scrim.** White title directly on artwork measures 4.13:1 where I sampled but 10.72:1 forty pixels to the right (`crop-tv-home-noscrim.png`). Legibility is currently a function of which photo loaded. A bright cover art puts it below 3:1. Also the stream shelf is clipped by the frame bottom — the hero eats ~85% of the height.
- **tvOS Library** (`tv-tab-library.png`) — the most competent browse screen. Two nits: the segmented control sits in a 940pt-wide empty band, and grid left edge (x≈123) vs segmented-control left edge (x≈131) are misaligned by 8pt.
- **tvOS Profile** (`tv-tab-profile.png`) — jagged left rule: avatar at 165, name block at 445, stats back at 165, divider at 165. And a **giant glowing red "Sign Out"** is the only control on the page — a destructive action rendered as the hero.
- **iOS Settings** (`ios-ready-settings.png`) — **six identical saturated orange icon badges in a vertical ladder**, five circles and one rounded square (Devices). Apple's Settings varies hue per row precisely to avoid this. Two of six values truncate: "Unknown · Unve…", "High streaming · Spe…".
- **iOS DJ** (`ios-dj.png`) — **the single worst screen in either app.** A tiny spinner and "Not paired with an Apple TV" in a 2622px void with no title, no nav bar, no back button, no tab bar. A dead end with no visible exit.
- **iOS Library / Queue** — empty states are vertically centred in the *whole screen* rather than the content area, so there is a 500px void between the search field and the message (`ios-ready-library.png`, `ios-queue.png`).

### Spacing, type and radius discipline (measured)

| | tvOS | iOS + AppClip |
|---|---|---|
| Raw-number paddings/spacings | **61** across 16 distinct values | **93** across 19 |
| Raw-number `.frame(…)` | **63** | **54** |
| Raw corner radii | 12 (values 1, 6, 8, 12, 34) | 13 (3,4,5,6,8,12,14,20,22,24) |
| Inline `.font(.system(size:))` | **69**, 25 distinct sizes | **72**, 18 distinct sizes |

Worst offenders: `DJModeView.swift` (22 raw spacings, 19 raw frames, 27 inline fonts), `DJControlView.swift` (33/21/22), `SettingsView.swift` (10/13/19), `TransportBarView.swift` (17/15/18).

Specific things that will read as sloppy:

- **`40` is the grid gutter and screen padding of all three browse screens** (`HomeView.swift:307, 329`; `LibraryView.swift:4, 55, 104, 137, 170`; `SearchView.swift:8, 53, 89`) and **`40` is not in the `Spacing` enum**. Neither is `26` (`HomeView.swift:26`).
- **`12` is the artwork corner radius on every content card in the app** (`HomeView.swift:315`, `LibraryView.swift:112, 145`, `SearchView.swift:61`) and is 2pt off `CornerRadius.md` = 14.
- **Seven different max-content widths**: 700, 800, 900, 940, 980, 1200, and a hardcoded 480 column (`SettingsView.swift:210`).
- **Circular buttons documented as sharing "the same visual language" are 56pt in two places and 64pt in two others** (`PlayerActions.swift:465`, `PlayerView.swift:1985` vs `QRCodeLoginView.swift:493`, `DJModeView.swift:1732`).
- **51 tvOS text sizes below the stated 28pt floor**, minimum 12pt. And **the token file breaks its own rule**: `tvCallout` 26, `tvCaption` 23, `tvMini` 20, `tvEyebrow` 18 are all sub-28, while `tvHero` 96 and `tvDisplay` 76 exceed the stated 58 ceiling. Either the rule or the ramp is wrong; right now `CLAUDE.md` describes neither.

---

## 5. On the earlier iOS design spec

`design/specs/ios-design-spec.md` is a good document. Where I agree and where I don't:

**Agree, strongly.**
- §2.3's read on `NowPlayingSheet` — centred everything, seven glass shapes, the waveform demoted to a 36pt strip, the app's differentiating features hidden behind 15pt glyphs in the top-right corner. All correct.
- "Colour comes from the content, never from the brand" (§1.4). This is the right principle and the app violates it in both directions: the fixed orange play button over an artwork-derived mesh, *and* the artwork-derived background with fixed-white text.
- Trap #4 (glass-on-glass in the mini bar) and Trap #11 (Reduce Motion is a token). Both confirmed by my inventory.
- Ranking Now Playing #1 and #2. Confirmed by measurement — it is the worst screen on both platforms.

**Disagree.**
1. **Trap #1: "Do not 'unify' them."** This is the one call I think is wrong, and it is the reason the codebase is in this state. The spec is right that you must not *merge the files* — different targets, and tvOS 10-foot metrics genuinely are not iOS metrics. But the conclusion drawn from that ("every new iOS token goes in `AppClipDesign.swift`", full stop) leaves two files with **colliding type names and different values** and no shared vocabulary. `Spacing.md` meaning 16 in one target and 14 in the other is not a design decision, it is a landmine. See §6 — the answer is shared *semantic names*, per-platform *values*.
2. **The spec is iOS-only, and tvOS is where the measurable damage is.** The owner's complaint covers both. Every WCAG failure I measured is on tvOS. A plan that starts with `NowPlayingSheet` on the phone leaves the worst screen in the product untouched.
3. **§1.3 is explicitly recalled, not verified,** and the spec says so honestly — but items 1 and 2 of its own "three changes" then depend on those numbers (88% artwork width, 0.82 paused scale, 22pt title). Do not let those numbers reach code without the screenshot-and-measure pass the spec asks for.
4. **It does not mention contrast once.** Given §2 above, that is the gap.
5. **§4.4 proposes lifting the deck A/B colours into the token file.** Agreed, and stronger than the spec puts it — per §5.5.2, deck identity colour is the *primary wayfinding* on a DJ surface, not a decorative choice. Tokenise it as `deckA`/`deckB` and give it a documented state ramp (cued / playing / warning).
6. **§4.4 says "manual `DJControlView` stays as-is visually".** Disagree. It is the right *direction* (see §5.5) but it is currently the least legible screen in the product, and the iOS variant is a dead end with no exit. "As-is" is not a safe instruction here.

---

## 5.5 DJ mode — the intended direction, specified

**Owner's direction:** the DJ screen should read as **glassy Pioneer CDJs + an Allen & Heath–style mixer**, and stay easy to operate on a TV remote, an iPhone and an iPad.

This is a good call and it resolves a tension the codebase currently has with itself. The rest of the app follows "Liquid Glass is chrome only, never content". DJ mode is the one screen where **the instrument *is* the content**, so the material rule should be stated as an explicit, documented exception rather than something `DJModeView` quietly violates three times (`:984`, `:1219`, `:1467`). Write the exception into `CLAUDE.md`; don't keep flagging it as a bug.

Below is what "glassy CDJ" has to mean concretely to be better than what is there now, rather than just darker.

### 5.5.1 What real gear does that the current screen doesn't

| Hardware cue | CDJ-3000 / Xone / Rane does | We currently do |
|---|---|---|
| **Jog wheel** | Lit ring around the platter; ring colour = deck state (white cue, amber cued, red at end-of-track). Centre display carries artwork + position. | Flat dark ring with tick marks; a single small orange dot for position; artwork inset. No lit ring, no state colour. |
| **Channel strip** | Vertical: trim → 3-band EQ → filter → level meter → fader. One column per deck, read top-to-bottom. | Six knobs in a 3×2 grid, decks stacked as rows, no meters, no trim, no filter. |
| **Level meters** | Always visible, per channel, the primary feedback surface. | **Absent entirely.** |
| **Tempo** | Large, always-on, with a ±range and a "sync/master" lamp. | 13pt caption, `~117` with a tilde. |
| **Cue / loop** | Big lit rubber buttons, colour-coded, latched state obvious. | Not present. |
| **Material** | Brushed metal + smoked acrylic + backlit translucency. Light comes from *inside* the control. | Matte dark grey discs. No emission. |

The single biggest visual gap is **emission**. Real gear glows; the current knobs are unlit. That is why it reads as "a drawing of a mixer" (which, per the screen's own error string, is what it currently is) rather than as an instrument.

### 5.5.2 Concrete spec

**Material — "lit glass", a documented content-layer exception.**
- Panel body: `.liquidGlass` over a dark plate, **plus** a 1pt top rim highlight at `white @ 0.22` and a 1pt bottom shadow at `black @ 0.55`. That inner bevel is what makes glass read as a moulded faceplate rather than a floating card.
- Every *active* control carries an emissive layer: the control's own colour at `0.85`, blurred `radius 12`, drawn **under** the glass. Inactive controls have it at `0.0`. This one addition does most of the "Pioneer" work.
- Deck-tinted specular: the top-left highlight on each channel strip picks up that deck's identity colour at `0.15`.

**Layout — vertical channel strips, not a knob grid.**
```
┌─ DECK A ─────┐  ┌─ MIXER ────────────┐  ┌─ DECK B ─────┐
│  jog wheel   │  │  A          B      │  │  jog wheel   │
│  (lit ring)  │  │ TRIM       TRIM    │  │  (lit ring)  │
│              │  │ HIGH       HIGH    │  │              │
│  TITLE       │  │ MID        MID     │  │  TITLE       │
│  artist      │  │ LOW        LOW     │  │  artist      │
│              │  │ FILTER     FILTER  │  │              │
│  128.0 BPM   │  │ ▮▮▮▯▯      ▮▮▯▯▯   │  │  124.0 BPM   │
│  Am · +2.4%  │  │  ║          ║      │  │  Am · −1.1%  │
│  [CUE][LOOP] │  │  ║ faders   ║      │  │  [CUE][LOOP] │
└──────────────┘  │ ──── X ────        │  └──────────────┘
                  └────────────────────┘
        ══════ dual waveform lane, full width ══════
```
Two symmetric decks flanking one mixer, read left→right, which is how the hardware is laid out and how a DJ already thinks. The current 3×2 knob grid maps to no real device.

**Colour.** Deck identity is not decoration here, it is the core wayfinding — Pioneer's whole UI is "deck 1 is this colour". So my §2.4 note is **withdrawn**: the orange/purple split is a correct instinct. It needs *tokenising and strengthening*, not removing:

| Role | Value | Note |
|---|---|---|
| `deckA` | `#FF7A28` | warm; already close to `accent`, keep it distinct enough to not read as "primary action" |
| `deckB` | `#7C74FF` | cool; the current purple, made deliberate |
| `deck.ring.cued` | deck colour @ 1.0 | lit ring, full |
| `deck.ring.playing` | `#FFFFFF` @ 0.9 | white = playing, matching hardware convention |
| `deck.ring.warning` | `#FF4F45` | last 30s |
| `meter.safe / hot / clip` | `#33C759` / `#FFB020` / `#FF4F45` | three-zone, standard |
| `tempo.inRange` | `text.primary` | |
| `tempo.outOfRange` | `#FFB020` | **amber, not `scError`** — out-of-range is a warning, not a failure |

Everything dimmed for "not playing" must still clear **4.5:1**. Use *hue* to signal state (amber ring vs white ring), not opacity. That is both what hardware does and what fixes the five failures in §4.

**Type.** BPM and key are the readout, so they get the biggest numerals on the screen, not the smallest:
- BPM: tvOS **58 / heavy / monospacedDigit**, iOS 28. Currently 13pt.
- Key + pitch: tvOS 30, iOS 15.
- Channel labels (TRIM/HIGH/MID/LOW/FILTER): tvOS **28 / heavy / uppercase / kern 2.0**, iOS 11. Currently 13.

### 5.5.3 Keeping it operable on all three inputs

This is the part that usually kills a hardware-mimic UI, so it needs designing rather than inheriting.

**tvOS (Siri Remote) — the hard case.** A remote cannot manipulate six continuous knobs. The resolution: **the mixer is a readout on tvOS, and a small set of discrete focusables.**
- Focusable on TV: per-deck `CUE`, `LOOP`, and one `EQ` entry per channel. Everything else renders as state.
- Selecting an `EQ` focusable enters a **modal knob** — the ring becomes a value arc, left/right on the D-pad steps it in **discrete detents** (−∞, −12, −6, −3, 0, +3, +6 dB — seven positions, not a continuous sweep), Menu exits. Detents are what make a rotary control operable from a remote at all, and they match how DJs actually use EQ kills.
- Crossfader: focusable, left/right steps in 10 positions with a centre detent.
- Focus treatment on these is the §7 spec, **plus** the ring's emissive layer going to full — so a focused control looks *powered up*, which is exactly the hardware metaphor.
- **Never require a continuous drag on tvOS.** Anything that genuinely needs one belongs on the phone.

**iPhone — one deck at a time.** 402pt cannot hold two channel strips and two jog wheels. Use a deck switcher (the two jog wheels shrink to lit thumbnails at the top; tapping one promotes it). The mixer collapses to a single channel strip for the active deck, plus the crossfader, always visible. Knobs get a **vertical drag** gesture (not rotational — rotational gestures on a phone are a known usability failure), with haptic detents at the same seven positions, and `.sensoryFeedback(.selection)` on each.

**iPad — the full console.** This is the layout the design is actually for: both decks, full mixer, waveform lane, at hardware-ish proportions. `ViewThatFits(in: .horizontal)` already proves the pattern in `DJControlView`. Add a `.regular` horizontal size class branch that renders the full three-column layout, and treat the iPhone layout as the compact fallback rather than the base case.

**Shared rule:** every control must have a **non-gestural** path (tap → detent step) so the same screen is operable by remote, thumb and pencil. Design the detents once; all three inputs use them.

### 5.5.4 What this changes in the fix list

Items 18 and 19 in §8 are **rescoped, not dropped**: don't strip glass off `DJModeView:984/1219/1467` — instead make it *deliberate* lit glass per 5.5.2 and document the exception. Item 19 (wrapping the six loose glass shapes in a `GlassEffectContainer`) still stands and matters more, not less, once the panels are properly glassy.

---

## 6. The prescription — one token system, two scales

### 6.1 How the two files should relate

Not one file. Not two unrelated files. **One semantic layer, two metric layers.**

```
Design/Tokens.swift            ← NEW, in swiftpm/Sources (compiles into BOTH)
    enum SCRole                — semantic names only, no values
    protocol SCMetrics         — the contract: space(_:), radius(_:), font(_:)
    Color.sc(_ role: SCRole)   — resolves through the active metric set

Design/Metrics+tvOS.swift      ← tvOS target only   (10-foot values)
Design/Metrics+iOS.swift       ← iOS target only    (AppClipDesign.swift, renamed)
```

Rules that make this stick:

1. **Names are shared; values are not.** `Space.gutter` exists on both. It is 40 on tvOS and 20 on iOS. `Spacing.md` meaning two different numbers stops being possible because `Spacing` stops existing.
2. **Roles, not values, at the call site.** `Color.sc(.textSecondary)`, never `.white.opacity(0.55)`.
3. **Delete the light-mode branches** until `.preferredColorScheme(.dark)` comes off. 17 call sites force dark; the light palette is fiction. Keeping it invites an agent to "fix" light mode that nobody will ever see.
4. **A lint gate.** A grep in CI for `\.opacity\(0\.` on `Color.white`/`Color.black` outside `Design/`, for `\.font\(\.system\(size:` outside `Design/`, and for `cornerRadius: [0-9]` outside `Design/`. Without this the drift returns within a week — it is exactly how the current state was reached.

### 6.2 Colour — semantic roles

Nineteen roles. Every value below is chosen to hit its stated contrast floor.

| Role | tvOS (dark) | iOS (dark) | Contract |
|---|---|---|---|
| `bg.base` | `#000000` | `#0C0C15` | the page |
| `bg.raised` | `#1A1A1A` | `#1E1E28` | **≥ 1.6:1 vs `bg.base`** — today 1.10–1.45:1 |
| `bg.overlay` | `#242424` | `#282833` | sheets, popovers |
| `separator` | `white @ 0.14` | `white @ 0.14` | one value, not four |
| `text.primary` | `#FFFFFF` | `#FFFFFF` | ≥ 12:1 on `bg.base` |
| `text.secondary` | `white @ 0.68` | `white @ 0.68` | ≥ 5:1 on `bg.raised` |
| `text.tertiary` | `white @ 0.46` | `white @ 0.46` | ≥ 3:1 — **decorative only, never a value a user must read** |
| `accent` | `#FF6B1A` | `#FF6B1A` | identical. One value. |
| `accent.on` | `#1A0A00` | `#1A0A00` | **the fg for anything filled with `accent`** — 7.4:1. Never white. |
| `accent.muted` | `accent @ 0.20` | `accent @ 0.20` | tints, selected-row backgrounds |
| `destructive` | `#FF4F45` | `#FF4F45` | |
| `destructive.on` | `#1A0000` | `#1A0000` | 6.5:1. Never white. |
| `success` / `success.on` | `#33C759` / `#001A06` | same | |
| `deckA` / `deckB` | `#FF7A28` / `#7C74FF` | same | tokenise the purple deliberately |
| `focus.ring` | `accent @ 0.90` | n/a | **one** opacity, not six |
| `focus.shadow` | `black @ 0.45` | n/a | one |
| `scrim.hero` | `black 0.0 → 0.80` | same | **new, mandatory** — see 6.6 |

### 6.3 Spacing — one scale, two value sets

| Name | tvOS | iOS | Use |
|---|---|---|---|
| `hair` | 4 | 4 | icon↔label |
| `tight` | 8 | 8 | within a control |
| `snug` | 16 | 12 | label stacks |
| `base` | 24 | 16 | default padding |
| `roomy` | 32 | 20 | between groups |
| `section` | 48 | 32 | between sections |
| `gutter` | 40 | 20 | **grid/shelf gutters — the missing 40** |
| `page` | 80 | 24 | screen inset |

Eight names. The current tvOS set has nine and iOS has six, sharing four names with different values, and the two most-used real numbers (`40`, `26`) are in neither.

### 6.4 Type — one ramp, two value sets

| Role | tvOS | iOS |
|---|---|---|
| `hero` | 76 / black | 34 / heavy |
| `title` | 58 / heavy | 26 / bold |
| `section` | 40 / heavy | 20 / bold |
| `headline` | 34 / bold | 17 / semibold |
| `body` | **30** / regular | 15 / regular |
| `bodyEmph` | **30** / semibold | 15 / semibold |
| `caption` | **28** / regular | 13 / regular |
| `eyebrow` | **28** / heavy, kern 2.4, uppercase | 12 / heavy, kern 1.4 |

**Nine tvOS tokens collapse to eight, and nothing on tvOS goes below 28.** That is the rule `CLAUDE.md` already states and neither the ramp nor the code currently honours. Deleting `tvMini` (20) and dropping `tvEyebrow` 18 → 28 will force ~51 call sites to change, which is the point.

Restate the rule in `CLAUDE.md` as: **tvOS type is 28–76pt.** The current "28–58" is contradicted by the file's own `tvHero`/`tvDisplay`.

### 6.5 Radius and motion

**Radius** — one name set, concentric-aware:

| Name | tvOS | iOS |
|---|---|---|
| `control` | 14 | 10 |
| `card` | 22 | 16 |
| `panel` | 32 | 22 |
| `hero` | 44 | 28 |
| `pill` | capsule | capsule |

Kill the raw `12`s on the four content cards (they should be `control`), the `34`s in `DJModeView` (→ `panel`), and the `20` in `AppClipLoginView` (→ `card`).

**Motion** — four tokens, and only four. Today tvOS has `focusSpring` *and* `tvFocusSpring` in the same file, plus iOS's separate `enum Motion`, plus two different `scMotion` APIs (a `View` extension on tvOS, a static on `Animation` for iOS).

| Name | Value | Use |
|---|---|---|
| `press` | `.spring(0.28, 0.86)` | button press |
| `focus` | `.spring(0.34, 0.62)` | tvOS focus (keep `tvFocusSpring`'s curve, delete `focusSpring`) |
| `settle` | `.spring(0.52, 0.86)` | sheets, layout |
| `ambient` | `.easeInOut(0.7)` | palette crossfades |

Unify the two `scMotion` signatures on the `View` extension form.

### 6.6 The palette-clamp contract — the fix for §2.1

This is the highest-value single change and it belongs in the token layer, not in three separate view files.

Replace `ArtworkColors.boost`, `NowPlayingPalette.boost` and `PlayerView.vivid` with **one** function in `Design/`:

```
sc_ambient(from artwork) -> (background, accent)
```

with these hard guarantees:

1. **Luminance ceiling on the background: relative luminance ≤ 0.14.** Today the measured Now Playing background was `#9FA07B` ≈ 0.34. This alone takes the title from 2.70:1 to ≥ 9:1.
2. **Saturation ceiling 0.55** on the background, so no screen goes khaki, magenta or lime.
3. **Verify, don't hope.** After derivation, compute contrast against `text.primary` and `text.secondary`. If `text.secondary` lands below **4.5:1**, darken the background until it doesn't. This is ~10 lines and it makes the failure mode structurally impossible.
4. **The derived accent gets its own floor: ≥ 3:1 against the final background**, or fall back to `Color.sc(.accent)`.
5. **Hero images get a mandatory scrim.** `scrim.hero` (`black 0.0 @ 0.35 → black 0.80 @ 1.0`, plus a leading `black 0.55 → clear @ 0.55`) is applied by the hero *component*, not by each caller. `tv-tab-home.png` currently has none and its legibility is a coin flip on the artwork.

---

## 7. The tvOS focus specification

One spec. Apply verbatim everywhere. Delete every competing value.

```
FOCUSED state, all content rows/cards/controls:

  scale          1.06            (one value — replaces 10)
  shadow         focus.shadow (black @ 0.45), radius 24, y 12
  ring           focus.ring (accent @ 0.90), lineWidth 4, inset 0
                 — always drawn ON focus, never on rest, never inverted
  animation      Motion.focus  = .spring(response: 0.34, dampingFraction: 0.62)
  system effect  .focusEffectDisabled()   — mandatory

RESTING state:
  scale 1.0, no shadow, no ring.
  Selection (a different thing) = accent.muted fill + 2pt accent @ 0.5 ring.
  Selection must never look like focus. Focus must never be a fill change alone.

TEXT ON A FOCUSED ACCENT FILL:
  always Color.sc(.accent.on).   Never white.

FOCUSABILITY:
  .focusable(...) must be gated on the control actually being actionable.
  A focusable view MUST render at least the ring. No exceptions.
  Any .focusSection() must be proven to contain ≥1 focusable descendant.
```

Why 1.06 and 4pt: at 3 m on a 65" panel, a 1.02 scale is ~2px of movement — invisible. A 2pt ring is sub-pixel at typical viewing. The current spread (1.02–1.14, 1pt–3pt) means some controls are imperceptible and others jump.

Then the harder half: **the nine components in §3.4 must move onto this system.** They are the Home shelf, all three Library grids, and the Search grid — i.e. the app's entire browse surface. Right now the browse surface uses the system halo and every bespoke control fights it, so the app has two focus languages and the *content* uses the one it was told not to.

---

## 8. Ranked fix list

Highest visual impact per unit of work first.

| # | Fix | Files | Screens | Size |
|---|---|---|---|---|
| **1** | **Palette clamp + contrast verification** (§6.6). One `sc_ambient`, delete the three `boost`/`vivid` variants. | `ArtworkColors.swift:112-113`, `TransportBarView.swift:484-485`, `PlayerView.swift:1476-1477` | tvOS Now Playing, DJ, ambient; iOS Now Playing | **S** |
| **2** | **`accent.on` / `destructive.on`** — black text on every accent and error fill. | `AppClipDesign.swift`, `SettingsView.swift`, `LibraryView.swift`, `WelcomeView.swift` | every CTA in both apps | **S** |
| **3** | **Raise `bg.raised` to ≥1.6:1** so surfaces have edges. | `DesignSystem.swift:23`, `AppClipDesign.swift:46` | tvOS Settings, all iOS cards | **S** |
| **4** | **Mandatory hero scrim** on the tvOS Home hero and any future bleeding hero. | `HomeView.swift` hero background | tvOS Home | **S** |
| **5** | **One focus spec** (§7) — mechanical find/replace of 10 scales, 9 radii, 7 ring colours. | `SettingsView.swift`, `PlayerView.swift`, `PlayerActions.swift`, `DJModeView.swift`, `QRCodeLoginView.swift`, `BehindTheTrackView.swift`, `GlassComponents.swift` | all tvOS | **M** |
| **6** | **Fix invisible focus + ungated focusables.** | `BehindTheTrackView.swift:224, 231, 238`; `DJModeView.swift:1785` | Behind The Track, DJ | **S** |
| **7** | **Un-invert the five backwards rings.** | `SettingsView.swift:1245, 1282, 1317, 1564`; `QRCodeLoginView.swift:534` | Settings, QR | **S** |
| **8** | **Fill the empty icon button** on Now Playing. | `PlayerView.swift` secondary actions row | tvOS Now Playing | **S** |
| **9** | **Remove the raw error string** *"…Stream request failed with HTTP 404"* from DJ. | `DJModeView.swift` transition card | tvOS DJ | **S** |
| **10** | **Stop `scError` meaning "tempo delta."** | `DJModeView.swift` (`+30.8%`) | tvOS DJ | **S** |
| **11** | **iOS Settings: vary the row-icon hue**, and stop the value column truncating. | `PhoneSettingsView.swift` | iOS Settings | **S** |
| **12** | **iOS DJ dead end** — give it a title, a nav bar and a way out. | `DJControlView.swift`, `SoundingTViOSApp.swift:76` | iOS DJ | **S** |
| **13** | **One app background on iOS** — Library is `#000`, the others `#0C0C15`. | `LibraryBrowserView.swift` / `PhoneRootView.swift` | all iOS tabs | **S** |
| **14** | **Introduce `Design/Tokens.swift`** (§6.1) + the CI lint gate. | new file + both metric files | all | **M** |
| **15** | **Migrate the 154 raw spacings / 141 inline fonts / 25 raw radii** onto tokens, worst files first (`DJModeView`, `DJControlView`, `SettingsView`, `TransportBarView`). | as listed | all | **L** |
| **16** | **Move the nine browse components onto the custom focus system** (§3.4). | `HomeView.swift`, `LibraryView.swift`, `SearchView.swift` | tvOS browse | **M** |
| **17** | **tvOS type floor to 28pt** — delete `tvMini`, raise `tvEyebrow`; fix the 51 sub-28 call sites. | `DesignSystem.swift` + call sites | all tvOS | **M** |
| **18** | **DJ "lit glass" pass** (§5.5.2) — inner bevel, emissive layer under active controls, deck-tinted specular. Keeps the glass on `DJModeView:984/1219/1467` and `DJControlView:62/249/1092`; documents the content-layer exception in `CLAUDE.md`. | `DJModeView.swift`, `DJControlView.swift`, `CLAUDE.md` | DJ, both platforms | **M** |
| **19** | **Wrap `DJModeView`'s 6 loose glass shapes in a `GlassEffectContainer`.** | `DJModeView.swift:1683-1778` | tvOS DJ | **S** |
| **19a** | **DJ state-by-hue, not by opacity** — cued/playing/warning ring colours; every dimmed element ≥ 4.5:1. Fixes the five failures on the screen. | `DJModeView.swift`, `DJControlView.swift` | DJ | **S** |
| **19b** | **DJ readout type** — BPM to 58pt tvOS / 28pt iOS, channel labels to 28/11. | `DJModeView.swift`, `DJControlView.swift` | DJ | **S** |
| **19c** | **DJ channel-strip relayout** — vertical strips + level meters, replacing the 3×2 knob grid. | `DJModeView.swift`, `DJControlView.swift` | DJ | **L** |
| **19d** | **DJ input model** — seven-position detents shared by remote / touch / pencil; tvOS modal-knob; iPad `.regular` full console. | `DJModeView.swift`, `DJControlView.swift` | DJ | **L** |
| **20** | **Recompose tvOS Settings** — equalise column widths, unify insets, fill the dead 55%. | `SettingsView.swift` | tvOS Settings | **M** |
| **21** | **Recompose tvOS Now Playing** — one left rule, larger artwork, kill the diagonal void. | `PlayerView.swift` | tvOS Now Playing | **L** |
| **22** | **Delete the dead light-mode palette** (or remove `.preferredColorScheme(.dark)` and actually design it). | both token files | — | **S** |
| **23** | **iOS `NowPlayingSheet` rebuild** — the earlier spec's §3.1, after items 1–3 land. | `TransportBarView.swift` | iOS Now Playing | **L** |
| **24** | **Give the phone a demo seed** so the loaded state can be reviewed without an account. | `SoundingTV-iOS/Sources` | — | **S** |

Items 1–4 are four small, surgical changes and between them they fix every WCAG failure in this document.

---

## 9. What not to break

- **`tv-signedout-qr.png`** — the QR sign-in screen. Best composition in the product. Leave it alone.
- The empty/loading/error focus handling in `HomeView`, `LibraryView`, `SearchView`, `QRCodeLoginView` and `DJModeView` — several carry comments explaining a bug that was already fixed once. Do not regress them.
- `StatusPanel` (`GlassComponents.swift:314-323`) — the correct pattern for focusable-with-no-action.
- The chrome-only glass in `PlayerView.swift:500` (transport pill), `TransportBarView`'s accessory, `GlassComponents.swift:120`. That is all correct usage.
- tvOS Library's content colour treatment (20.42:1 / 5.10:1). The black-background screens are fine.
- **The DJ screen's hardware metaphor.** The jog wheels, tick rings, physical crossfader and per-deck colour coding are the app's strongest identity idea. §5.5 is about committing harder to them, not softening them. Do not let a token-cleanup pass flatten this screen into cards.
- `Track.init`'s entitlement filtering. Untouched by anything here, and nothing in this document should be read as a reason to render a play affordance for an unentitled track.

---

## Appendix — screenshot index

| File | What |
|---|---|
| `tv-01b-home-30s.png` | tvOS Now Playing, loaded — the contrast failure |
| `crop-tv-np-actionrow.png` | Now Playing action row — the empty button, ghosted metadata |
| `tv-tab-home.png` / `crop-tv-home-noscrim.png` | tvOS Home — unscrimmed hero |
| `tv-tab-library.png` | tvOS Library — best browse screen |
| `tv-tab-search.png` | tvOS Search — empty state |
| `tv-tab-profile.png` | tvOS Profile — glowing red Sign Out, jagged left rule |
| `tv-settings-t45s.png` / `crop-tv-settings-surfaces.png` | tvOS Settings — invisible surfaces, orange focus bar |
| `tv-settings-t2s/-t4s/-t8s.png` | tvOS cold-start blank state |
| `tv-dj-mode.png` / `crop-tv-dj-deckb.png` / `crop-tv-dj-knobs.png` | tvOS DJ — failing deck B, skeuomorphic knobs |
| `tv-signedout-qr.png` | tvOS QR sign-in — the good one |
| `ios-ready-library.png` / `crop-ios-two-oranges.png` | iOS Library — two accents, black background |
| `ios-ready-settings.png` | iOS Settings — orange ladder, truncated values |
| `ios-ready-appleTV.png`, `ios-remoteOnly-appleTV.png` | iOS Apple TV tab |
| `ios-queue.png` | iOS Up Next — empty |
| `ios-dj.png` | iOS DJ — the dead end |
| `ios-light-settings.png`, `ios-light-library.png` | proof light mode is ignored |
| `build-tvos.log`, `build-ios.log`, `build-ios2.log` | build evidence |
