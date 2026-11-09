# Sounding on iPad — plan, with the CDJ console as the centrepiece

**Status:** design only. Nothing in the repo was edited.
**Author:** planning agent, job 3fc7cb5a.
**Companion doc:** `design/specs/dj-engine-spec.md` (the auto-DJ / transition engine spec). This document assumes it and does not repeat its research. Where it says "§n" unqualified, it means that document.

**Working-tree note.** The repo is on branch `staging/session-rebuild` with 89 modified/deleted paths; the App Clip target's shell (`AppClipApp.swift`, Info.plist, entitlements) is being deleted while its sources stay in the iOS target. Other agents are mid-edit. Everything below was read off disk as it stands and nothing was fixed.

**Two corrections to CLAUDE.md, found while reading, not acted on:** deployment targets in `project.pbxproj` are now `IPHONEOS_DEPLOYMENT_TARGET = 27.0` / `TVOS_DEPLOYMENT_TARGET = 27.0`, not the 26.0 that CLAUDE.md states. And `SoundingTV-Share` already declares `TARGETED_DEVICE_FAMILY = "1,2"` inside a host app that declares `1` — a pre-existing inconsistency.

---

## 0. The verification ledger

Everything load-bearing in this document, sorted by how much you should trust it.

### Verified — read from the SDK, the code, or a primary source

| # | Claim | Evidence |
|---|---|---|
| V1 | **iPad has no haptics.** Apple's own CoreHaptics documentation, *Preparing your app to play haptics*, names the non-supporting devices: **iPad, iPod touch, Apple Vision Pro.** The guidance is to check `CHHapticEngine.capabilitiesForHardware().supportsHaptics` and "provide visual feedback instead". | `developer.apple.com/documentation/corehaptics/preparing-your-app-to-play-haptics` (fetched as JSON — the HTML is JS-rendered and returns an empty shell) |
| V2 | `CHHapticDeviceCapability.supportsHaptics` is the runtime gate; the protocol is `API_AVAILABLE(ios(13.0), tvos(14.0))` — tvOS availability exists **for game controllers**, not for the device. | `iPhoneOS27.0.sdk/…/CoreHaptics.framework/Headers/CHHapticDeviceCapability.h:52-59` |
| V3 | `UICanvasFeedbackGenerator` (iOS 17.5+) is the only iPad-side tactile API, and Apple's doc scopes it precisely: *"When using Apple Pencil Pro with a compatible iPad, this type of feedback can provide a tactile response."* Two methods only: `alignmentOccurred(at:)`, `pathCompleted(at:)`. | `…/UIKit.framework/Headers/UICanvasFeedbackGenerator.h`; docs JSON |
| V4 | `GCController.haptics` → `GCDeviceHaptics` exists (iOS 14+), and CoreHaptics has `CHHapticEngineStoppedReasonGameControllerDisconnect`. A connected controller *can* play haptics on an iPad. | `GameController.framework/Headers/GCController.h:255`; `CHHapticEngine.h:104,228` |
| V5 | **The iOS app target is iPhone-only today:** `TARGETED_DEVICE_FAMILY = 1` on both `SoundingTV iOS` build configs. Widget is `1`. TopShelf/tvOS are `3`. Share is `"1,2"`. | `SoundingTV.xcodeproj/project.pbxproj:1077, 1226, 1104, 1252, 1004, 1196, 1271, 1047, 1291` |
| V6 | **`MixEngine.swift`, `PlayerService.swift`, `PhantomDJEngine.swift` and `WaveformService.swift` are already compiled into the `SoundingTV iOS` target.** 23 files are shared between tvOS and iOS. The iPad can render DJ audio locally with **zero** new build configuration. | Parsed `PBXNativeTarget` → `PBXSourcesBuildPhase` membership from `project.pbxproj` |
| V7 | **`RemoteQueueServer.swift` is tvOS-only.** Only the TV can be a render target for a remote console today. | Same parse; `RemoteQueueServer.swift` appears in the tvOS-only set of 24 |
| V8 | **`DesignSystem.swift` and `GlassComponents.swift` are tvOS-only.** iOS uses `AppClipDesign.swift`, which defines `Spacing` with *different values under the same names* (`md` 14 vs 16, `lg` 20 vs 24, and no `xxs`/`xxxl`/`screen`), and `Radius` instead of `CornerRadius`. | Same parse + both files |
| V9 | Wire framing: **4-byte big-endian `UInt32` length prefix, JSON body, `maxFrameBytes = 1 << 20` (1 MiB)**, with a legacy sniff for a bare leading `{`. | `SoundingTV.swiftpm/Sources/Services/TokenTransferProtocol.swift:1414-1476` |
| V10 | **`noDelay` is set nowhere in the repo.** Zero hits. The only `NWProtocolTCP.Options` touched are the client's four keepalive fields (`idle 5`, `interval 3`, `count 3`). Nagle is active on every gesture frame. | `RemoteQueueClient.swift:260`; repo-wide grep |
| V11 | Telemetry cadence: `RemoteQueueServer.startStateTicking()` is a **10 Hz** `Task` loop with a **2 s forced keepalive** (`keepaliveTicks = 20`), fingerprint-gated so unchanged state isn't sent. | `RemoteQueueServer.swift:727-739` |
| V12 | **Every signed payload already carries `issuedAtMillis: Int64` (Unix wall-clock ms), and the phone never reads it.** Its only consumer is a server-side 120 s freshness check. There is **no ping/pong, no RTT measurement, and no clock offset estimation anywhere.** | `TokenTransferProtocol.swift:872-876, 984-988`; grep for `ping|pong|rtt|latency|clockOffset` across client/server/protocol |
| V13 | **`MixEngine.deckStatePayload(_:)` hardcodes `title: nil, artist: nil, bpm: nil`.** Consequence: the phone's deck header permanently reads "No Track", and `LoopControlView` offers loop lengths in **seconds** (`[1,2,4,8,16]`) because it has no BPM to convert with. | `MixEngine.swift:1186-1211`; `DJControlView.swift` |
| V14 | `MixEngine` publishes exactly five properties (`decks`, `crossfade`, `masterVolume`, `isRunning`, `lastError`). Playhead + meter tick is **20 Hz** (`Task.sleep(50_000_000)`), parameter ramps are **~60 Hz** (`16_000_000`), meter taps are audio-thread at `bufferSize: 1024`. | `MixEngine.swift:312-343, 1430, 1487` |
| V15 | `WaveformService` fetches **SoundCloud's `waveform_url` JSON only** — no local decode. Typical document is **~1800 points**, i.e. **~9 samples/s ≈ 110 ms per bucket** on a 200 s track. | `SoundingTV.swiftpm/Sources/Services/WaveformService.swift` |
| V16 | SwiftUI on iOS 27 has: `SpatialEventGesture` + `SpatialEventCollection` (concurrent touches with stable `id`, `phase`, `kind`), `simultaneousGesture`/`highPriorityGesture`/`GestureMask`, `onKeyPress` with `KeyPress.Phases`, `keyboardShortcut`, `NavigationSplitView`, `.tabViewStyle(.sidebarAdaptable)`, `PointerStyle`, `hoverEffect`, `onGeometryChange`, `sensoryFeedback`. | `SwiftUI.swiftinterface:32469, 25819-25827, 27469, 27618, 9564`; `SwiftUICore.swiftinterface:1221, 23117-23119, 7297` |
| V17 | UIKit gives what SwiftUI does not: `UITouch.majorRadius` + `majorRadiusTolerance` (iOS 8+), `UIEvent.coalescedTouchesForTouch:` and `predictedTouchesForTouch:` (iOS 9+), `UIWindowScene.requestGeometryUpdateWithPreferences:errorHandler:` (iOS 16+). | `UITouch.h:60-61`; `UIEvent.h:78,81`; `UIWindowScene.h:31` |
| V18 | `AVAudioSourceNode` exists (iOS 13+) — a render-thread callback block supplying `AudioBufferList`. This is the only route to scratching. | `AVFAudio.framework/Headers/AVAudioSourceNode.h:41` |
| V19 | `AVAudioSession.setPreferredIOBufferDuration:error:` is available on iOS. | `AVAudioSession.h:310` |
| V20 | The iOS `Info.plist` has **no** `UIApplicationSceneManifest`, **no** `UIRequiresFullScreen`, and `UISupportedInterfaceOrientations = [Portrait, LandscapeLeft, LandscapeRight]` (no upside-down, no `~ipad` variant). Multitasking/Stage Manager is therefore already on by default. | `SoundingTV-iOS/Info.plist` |
| V21 | The existing `DJControlView` is already a full console driving the TV: `JogWheelView` (160 pt, two-zone radius split at `0.38`, coarse `12 s/rev` outer vs fine `1.8 s/rev` inner = 33⅓ RPM), `KnobControl` (42 pt, `pixelsForFullSweep = 130`, vertical delta), `PitchFaderView` (magnetic detent at ±0.012 around 1.0), `CrossfaderView`, `CuePadView`, `LoopControlView`, `MixerConsoleView`. **Every gesture is a single-touch `DragGesture`; there is no multi-touch composition anywhere in the phone targets.** The only `simultaneousGesture` in the repo is a `LongPressGesture` on the CUE pad. | `SoundingTV-iOS/Sources/DJControlView.swift` |
| V22 | The only `UIViewRepresentable` in any phone target is `OAuthWebView` (a `WKWebView`). No `UIViewControllerRepresentable`, no UIKit gesture recognisers. | `SoundingTV-AppClip/Sources/AppClipLoginView.swift:556` |

### Inferred — derived, not read

| # | Claim | How it was derived | How to settle it |
|---|---|---|---|
| I1 | **iPad point geometry.** All iPads except the mini are 264 ppi at @2x = **132 pt per inch = 5.197 pt/mm**. The mini is 326 ppi = **163 pt/in = 6.42 pt/mm**. Landscape point sizes: 13" Pro **1376 × 1032**; 13" Air **1366 × 1024**; 11" Pro **1210 × 834**; 11" Air / iPad (A16) **1180 × 820**; mini **1133 × 744**. | Published pixel dimensions ÷ 2. The simulator `profile.plist` files carry `modelIdentifier` and `supportedProductFamilyIDs` but **no screen geometry**, so this could not be read locally. | One `GeometryReader` printing `size` in a booted sim per device. Ten minutes. |
| I2 | A 44 pt target is **8.5 mm** on a 132 pt/in iPad but **6.9 mm** on a mini. Apple's 44 pt guideline was calibrated at 163 pt/in. | Arithmetic from I1. | Same. |
| I3 | **WiFi LAN latency profile:** min-RTT 2–6 ms on 5 GHz, p95 15–40 ms, p99 spikes 100–300 ms driven by client power-save / DTIM. | Recalled, not measured on this network. This is the number the whole schedule-ahead design depends on and it is the weakest link in the plan. | Ship the `clock_ping`/`clock_pong` pair first (§4.2) and log the distribution for a week before choosing the lead constant. Named as **E-N1** in §7. |
| I4 | Two device crystals differ by 10–50 ppm, so clock drift between resync points is 0.6–3 ms per 60 s and irrelevant at a 5 s resync interval. | Standard consumer-oscillator tolerance. | Falls out of E-N1's logs for free. |
| I5 | `SpatialEventGesture` delivers all concurrent touches reliably inside this app's `TabView` → `NavigationStack` hierarchy. | Assumed from the type's shape; not exercised. | **E-T1** in §7. |
| I6 | A tiled pre-rendered `CGImage` waveform beats re-stroking a `Canvas` path at 120 Hz on an 11" iPad Air. | Standard result; not profiled here. | **E-T2** in §7. |

### Contested or unknown — say so out loud

- **Whether the owner will accept "no haptics".** V1 is not arguable; what *replaces* it is a taste call (§3.9).
- **Whether `AVAudioPlayerNode.play(at:)` is sample-accurate relative to another player node.** This is the auto-DJ spec's **E1** and it gates SYNC, quantised cues, and loop halving here too. Unresolved.
- **Whether key-lock artefacts at ±6% are acceptable.** Sources give 5%, 8%, 10–20%; none from a controlled study (§8.2 of the engine spec). Do not put a number in a comment.
- **Split-cable cue on a 2-channel output** is how djay and Serato do headphone monitoring on phones, but I did not verify that any Apple API forbids it. It requires a custom master mix stage and it contradicts the documented "stay stereo so the Sonos upmixes" decision — though only in cue mode, which nobody uses with a Sonos.

---

## 1. iPad adaptation — the short section

### 1.1 One target, not two

**Set `TARGETED_DEVICE_FAMILY = "1,2"` on `SoundingTV iOS` and on `SoundingTV-Widget`. Do not create an iPad target.**

The reasoning is the same as CLAUDE.md's naming rule. The bundle id `red.forbes.sounding` is load-bearing for the App Store Connect record, TestFlight, provisioning and existing Keychain items; a second target means a second bundle id, a second App Store listing, a second provisioning profile, and a fork of every shared view. There is no UIKit device assumption anywhere in the phone targets to unpick — the only `UIViewRepresentable` in the whole app is a `WKWebView` (V22). The codebase is already SwiftUI top to bottom.

Provisioning cost is close to zero: the existing App ID covers iOS, and iPad support needs no new App ID, certificate or capability. The App Store Connect cost is **iPad screenshots**, which are mandatory for a universal listing — 13" (2064 × 2752) at minimum, and it is worth doing 11" too since the console reflows.

Two things to fix while you are in there:

- `SoundingTV-Widget` is `TARGETED_DEVICE_FAMILY = 1` (V5). A universal app with an iPhone-only widget extension is a warning and a bad user story. Bump it.
- `SoundingTV-Share` is already `"1,2"` inside a `1` host (V5). Once the host is `"1,2"` this stops being a mismatch.

**Do not touch `project.yml`,** and register the new files from the main session per CLAUDE.md's `project.pbxproj` rule. The console is a lot of new files (§6.4) and it is exactly the serialisation bottleneck that rule exists for.

### 1.2 Root shell: keep the `TabView`

`PhoneRootView` is a three-tab `TabView` (Library / Apple TV / Settings) with a `tabViewBottomAccessory` mini player, and the file's header comment explains at length why the shell changes *shape* with `PhoneAppState` rather than showing empty rooms. That logic is right and is orthogonal to screen size.

**Add one line: `.tabViewStyle(.sidebarAdaptable)` (V16).** On iPad this renders as a sidebar that collapses to a top tab bar, gets you the iPad idiom for free, and changes nothing on iPhone. A `NavigationSplitView` rewrite of the root would fork the two shells for no benefit — Library, Apple TV and Settings are three peers, not a master-detail.

**`NavigationSplitView` does earn its place, but inside `LibraryBrowserView`**, where playlist → track list → track detail is a genuine three-column shape and currently a `NavigationStack` push chain on a 1376 pt-wide screen. That is a self-contained change in one file.

The DJ console is neither. It is a **full-bleed modal scene** with no tab bar, no navigation chrome and no scroll view anywhere (§3.3 explains why the no-scroll rule is a hard constraint, not a preference).

### 1.3 Size classes and the reflow ladder

`UIRequiresFullScreen` is absent and there is no `UIApplicationSceneManifest` (V20), so **the app already supports Stage Manager and Split View** and the console can be handed any width the user likes. That is the real constraint, not the device model. Breakpoints, in points of *available width*:

| Width | Console layout |
|---|---|
| **≥ 1180** | Full two-deck console (§3.10). This is 11" Air landscape and up. |
| **900–1179** | Two decks retained; the mixer collapses to crossfader + filter + line faders, and the EQ block moves to a flip-out per channel. Hot cue pads drop from 8 to 4 with a bank toggle. |
| **< 900** | Single-deck focus with a deck selector and a persistent crossfader strip. This is the honest degradation — two decks in 800 pt means neither is operable. |
| Height **< 700** | Drop the overview waveforms (keep the detail/beatgrid stack, which is the one you actually mix on). |

The iPad mini at 1133 × 744 lands in the middle band and physically it is 24 % smaller per point (I2), so a 68 pt pad is 10.6 mm rather than 13.1 mm. **The mini gets the console but is not a design target.** Say so in the docs rather than pretending.

### 1.4 Orientation

The console is landscape-only. There is no honest portrait two-deck layout at any iPad size.

Do **not** lock the app's orientation — the Library and Settings tabs are fine in portrait and a user reading a track list will hold the thing however they want. Instead, on console presentation call `UIWindowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))` (V17) and **treat the error handler as a real branch**: it will fail under Stage Manager and on an external display, and when it does you render the `< 900` single-deck fallback rather than a broken two-deck layout in a portrait window. Add `UIInterfaceOrientationPortraitUpsideDown` to `UISupportedInterfaceOrientations` while you are in the plist — iPad users rotate 180° constantly and the app currently refuses.

### 1.5 Pointer and keyboard

A trackpad gives one thing touch cannot: **sub-pixel precision**. That matters exactly where §3.7 says the tempo fader runs out of resolution.

- `.pointerStyle` and `.hoverEffect` exist (V16). Use hover to reveal fine-adjust affordances (the ±0.01 % tempo arrows, the beat-count stepper on a loop) rather than showing them permanently and stealing space.
- Scroll wheel over a waveform = scrub; over a knob or fader = adjust; **⌥ + scroll = fine mode** (×0.1). This is the Logic/Ableton convention and a DJ will already have it.

Keyboard matters more. `onKeyPress(keys:phases:)` with `KeyPress.Phases` is verified present (V16), and **phases are the point** — cue and loop-roll are momentary actions and need `.down`/`.up`, not a fired-once shortcut.

Use `onKeyPress` on the console root with one big `keys:` set, **not** `keyboardShortcut` on forty hidden buttons — `keyboardShortcut` publishes into the menu system, steals keys from any text field, and does not give you key-up.

Proposed map. Single keys with no modifier, because your other hand is on the glass:

| Key | Action | Key | Action |
|---|---|---|---|
| `Q` / `P` | CUE deck A / B (momentary — preview on down, return on up) | `W` / `O` | play/pause A / B |
| `1`–`4` | hot cues 1–4, deck A (⇧ for 5–8) | `7`–`0` | hot cues 1–4, deck B (⇧ for 5–8) |
| `Z` / `C` / `X` | crossfader hard-left / centre / hard-right | `A` / `S` | loop toggle A / B |
| `[` `]` | nudge A back / forward (one press = 5 ms) | `;` `'` | nudge B back / forward |
| `-` `=` | tempo A down / up (one press = 0.05 %) | `,` `.` | tempo B down / up |
| `9` `0` | halve / double the focused deck's loop | `K` | key-lock toggle, focused deck |
| `Space` | play/pause focused deck | `Tab` | switch focused deck |
| `⇧` held | fine mode on every continuous key repeat (×0.1) | `⌘,` | Settings (system convention — this one *is* a `keyboardShortcut`) |

Note the nudge and tempo keys are the interesting ones: a keypress is a *quantised* increment, which is strictly better than a finger for the 0.05 % steps §3.7 says you cannot hit by hand.

### 1.6 The things that will ruin a gig, and cost nothing to fix

- `UIApplication.shared.isIdleTimerDisabled = true` while the console is presented. Obvious, always forgotten.
- **24 pt dead margin at every screen edge** with no control in it. The bottom edge is the home indicator and swipe-up; the top edge is Control Centre; the right edge is Slide Over. A crossfader that runs to the bottom bezel will get you a home-screen swipe mid-mix. Pair it with `.defersSystemGestures` so the first swipe only reveals the indicator.
- Document **Guided Access** in-app ("triple-click before you play"). It is the only real answer to notification banners and accidental gestures, and it is one sentence of copy.
- **`AVAudioSession` must keep the `.longFormAudio` route-sharing policy** (CLAUDE.md, non-negotiable for AirPlay 2). But AirPlay adds seconds of latency, so **DJ mode must refuse to arm over an AirPlay route** — check `AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType == .airPlay` and say why, rather than letting someone try to beatmatch across a two-second pipe.
- `setPreferredIOBufferDuration` (V19) at 0.005 s for local render. It will not always be granted; read `IOBufferDuration` back and show it.

---

## 2. Three things an iPad console cannot do, stated before the design

Design around these rather than discovering them at the end.

**2.1 There are no haptics (V1).** Not weak haptics, not haptics-if-you-ask-nicely. `supportsHaptics` is `false` and Apple's own docs name iPad in the exclusion list. `sensoryFeedback` and `UIImpactFeedbackGenerator` calls **compile and silently do nothing** — which is worse than not having them, because `DJControlView` already fires `.sensoryFeedback(.selection, …)` at the tempo fader's centre detent and `.impact(weight: .heavy)` at the crossfader endpoints, and on iPad those are dead code that looks live in review. §3.9 is the replacement.

**2.2 There is no headphone cue without extra hardware.** Pre-listening deck B while deck A goes to the PA needs ≥ 4 output channels or a split-cable trick. The iPad's built-in output is 2 channels. This is not a software limitation you can design past:

- **USB-C audio interface with 4 outs** — iPad Pro/Air USB-C does USB Audio Class. Master on 1/2, cue on 3/4. This is the real answer and it is what a DJ would actually plug in.
- **Split-cable mode** — sum master to L, cue to R, on the 2-channel output, which is how djay and Serato do it on phones. Implementable, needs a new master mix stage (§3.6), and it contradicts the documented "stay stereo so the Sonos does its own upmix" decision — but only while cue mode is engaged, which nobody does with a Sonos.
- **Neither** — you beatmatch visually off the beatgrid and phase meter (§3.3), or you use SYNC.

Say which of these you are in, in the UI, permanently. A DJ who thinks cue is working and finds out at the mix point is worse served than one who knows it is off.

**2.3 Scratching needs a deck-engine rewrite, and it is local-only.** Two independent blockers:

- `AVAudioPlayerNode` cannot play backwards at all. A scratch needs an `AVAudioSourceNode` (V18) with a fractional read pointer into an in-memory PCM buffer, driven from a lock-free atomic written by the touch thread. That replaces the player node as the deck source, which means loops, `schedule`, `seek`, and `playheadPosition` all rebuild on it. This is an **L**, and it is a rewrite of the most-debugged part of `MixEngine`, including the code path that owns the documented Obj-C-exception crash.
- Even with it, scratch is a **closed sensorimotor loop at < 10 ms**. It cannot be remoted, ever, under any protocol. See §4.6.

So: scratch is a v3 stretch, on local render only, and the plan below is honest about the console being excellent without it. The CDJ-3000's own jog is used for search and pitch bend far more than for scratching; the DJs who scratch are on turntables.

---

## 3. The CDJ console

### 3.1 Touch architecture — UIKit routes, SwiftUI draws

This is the single most important structural decision in the document, and the current code does not do it. Every gesture in `DJControlView` is an independent single-touch `DragGesture` on its own hit-tested subview (V21). That *accidentally* supports one finger per control, which is most of what you need, but it cannot express:

- a second finger on the same control meaning **fine mode**,
- two fingers on a waveform meaning **zoom** while one finger means **scrub**,
- **palm-on-platter** meaning brake (needs `UITouch.majorRadius`, V17 — SwiftUI never exposes touch radius),
- full-rate jog sampling (needs `UIEvent.coalescedTouches(for:)`, V17 — SwiftUI drops intermediate samples when the run loop is busy).

**The design:**

```
ConsoleTouchHost : UIViewRepresentable
  └─ UIView, isMultipleTouchEnabled = true
       touchesBegan/Moved/Ended/Cancelled  ──► TouchRouter
                                                 │
   SwiftUI console tree (pure renderers) ◄───────┘  reads bindings
```

- **`TouchRouter`** is an `@Observable` reference type holding `[ObjectIdentifier(UITouch) : ControlBinding]`. On `touchesBegan` it hit-tests the touch location against a **control frame registry** — each control publishes its rect via `.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("console")) }` (V16) — and binds. Subsequent `touchesMoved` route to the bound control by identity, so a finger that drifts off a knob keeps driving it. This is the behaviour every hardware control has and no naive hit-test-per-frame implementation has.
- **Second finger, same control** → do not create a binding; set `binding.fine = true` and scale the delta by 0.1. The finger can be anywhere within 120 pt of the control's frame, so you do not have to aim.
- **Two fingers, same waveform lane** → promote the binding to `.zoom` and drive it from their separation. One finger stays `.scrub`. No gesture arbitration, no flicker, no `minimumDistance` guessing.
- **Palm detection** → `majorRadius > 18 pt` (≈ 3.5 mm radius, i.e. a 7 mm contact patch) on the platter face means brake, not scrub. Fingertips are 5–9 pt. Calibrate on device; this is a starting number, not a measured one.
- **Coalesced touches** → the jog and the scratch path consume `event.coalescedTouches(for:)` so you get every 120 Hz sample even when the main actor is busy drawing. Everything else uses the single latest touch.
- **Controls become pure renderers.** They read `router.value(for: .eq(.a, .low))` and draw. They own no gesture and no `@State` value. That also collapses the "local leads then hands back" pattern (which `DJControlView` re-implements five times, V21) into one place in the router.

**Why not `SpatialEventGesture`?** It is present (V16) and it is the SwiftUI-native answer to concurrent touches — `SpatialEventCollection` gives stable per-event `id`, `phase` and `kind` including `.pencil` and `.pointer`. If it works cleanly in this app's hierarchy it is less code. But it gives **neither `majorRadius` nor coalesced samples**, both of which the jog wheel needs, so you would end up with a UIKit host anyway. Build the UIKit host; keep `SpatialEventGesture` as the Pencil/pointer path if E-T1 (§7) shows it composes cleanly.

**Controls that must be simultaneously operable.** This list is the acceptance test for the router:

1. Crossfader (right hand) + EQ LOW on either deck (left) — the bass swap.
2. EQ LOW A + EQ LOW B, one hand each — the two-handed swap.
3. Jog A (left, nudging) + tempo fader A (right) — beatmatching by ear.
4. Line fader B + filter B — the filter-in.
5. Hot cue pad + crossfader — cue juggling.
6. Any control + a second finger for fine mode.
7. Waveform scrub + waveform pinch-zoom on the *other* deck's lane.

### 3.2 Jog wheels — smaller than instinct says

**Sizes.** 340 pt diameter on 13" (65.4 mm at 5.197 pt/mm, I1), 288 pt on 11" (55.4 mm). For scale: a DDJ-400 jog is 74 mm; a CDJ-3000 jog is 206 mm; a Technics platter is 332 mm. A CDJ-scale jog would be **1071 pt** and is not happening. So this is a controller jog, not a CDJ jog, and the design should stop pretending otherwise — 65 mm is already larger than the current 160 pt (30.8 mm) implementation.

The existing two-zone split is right and should be kept: **outer ring (radius > 0.38 × diameter) = coarse, inner face = fine**, matching `JogTuning.coarseSecondsPerRevolution = 12` / `fineSecondsPerRevolution = 1.8` (V21). 1.8 s/rev is 33⅓ RPM, which is a nice touch and worth keeping for the muscle memory.

**But the ring and the face should do different *kinds* of thing, not just different rates.** CDJ convention:

| Zone | Playing | Stopped / cued |
|---|---|---|
| **Outer ring** | **Pitch bend** — temporarily scales `timePitch.rate` by ±(0…8 %) proportional to angular velocity, decaying back to the fader value over 250 ms after release. Does *not* move the playhead directly. | Fast search — 12 s/rev, as today. |
| **Platter face** | **Search / scrub** — moves the playhead, audio follows. Today this is `seek(byNudging:)`, which is `player.stop()` + reschedule and therefore clicks. | Frame search — 1.8 s/rev. |
| **Palm on face** | **Brake** — ramp `rate` to 0 over 120 ms, hold, release ramps back over 250 ms. Uses `setRate(_:on:over:)` which already exists. | — |

The pitch-bend behaviour is the one that earns the wheel's screen area, because it is the one a DJ uses constantly and it needs **no new DSP** — it is `setRate` with a decay, and `RampKey.rate(Deck)` already exists so an overlapping gesture cancels the previous ramp correctly (V14).

**What is honestly achievable, ranked:**

| Behaviour | Achievable? |
|---|---|
| Pitch bend (rate modulation) | **Yes, today.** `setRate(_:on:over:)`, 60 Hz ramp. |
| Brake / spin-down | **Yes, today.** Same call, ramp to 0. |
| Search when stopped | **Yes, today**, but `seek` does `player.stop()` + reschedule so it is not gapless. Audible as a tick per drag update at 120 Hz — which is why the search path must **throttle to ~20 Hz and interpolate visually at 120 Hz**, not seek per frame. |
| Scrub-with-audio while playing | **Degraded today** for the same reason. Proper implementation needs `AVAudioSourceNode` (§2.3). |
| Scratch (reverse, sub-beat) | **No.** Deck rewrite, L. |
| Inertia / flywheel | **Yes, cosmetically** — spin the visual platter with decay on release. Do not let it drive audio; a flywheel that moves the playhead after your hand leaves is a bug on a screen with no friction. |

**Occlusion.** A hand on a platter occludes roughly a 90 × 120 mm region = **470 × 625 pt**, extending *up and inward* from the contact point. This is the constraint that fixes the whole layout: **nothing informational may sit within 200 pt above a jog wheel.** Jogs go in the bottom-outer corners; waveforms go at the top; the mixer goes bottom-centre where the hands are also expected.

### 3.3 Waveforms

Three surfaces, and they are different jobs.

**(a) Overview, per deck — 56 pt tall (13") / 44 pt (11").** Whole track, fixed scale. Source: **SoundCloud's `waveform_url` JSON via the existing `WaveformService`** (V15) — already in the iOS target, already cached with a 200-entry `NSCache`, already has a real error taxonomy. Zero new work, zero wire cost, works identically local and remote. At ~1800 buckets over a 6-minute track that is 200 ms/bucket, which is exactly right for an overview and useless for anything else. Draw hot cue markers, loop regions, the mix-point marker and the played/unplayed split on it.

**(b) Detail / beatgrid stack — the thing you actually mix on. 200 pt (13") / 160 pt (11").**

Layout, mirrored like Rekordbox and Serato so coincident transients form a symmetric shape:

```
┌────────────────────────────────────────────────────┐
│  deck A waveform, 3-band, drawn downward     88pt  │
├────────────────────────────────────────────────────┤
│  shared beat ruler + phase meter             24pt  │  ← anchored on the MASTER deck's grid
├────────────────────────────────────────────────────┤
│  deck B waveform, 3-band, drawn upward       88pt  │
└────────────────────────────────────────────────────┘
```

Both lanes share **one time axis, anchored on the tempo master's grid**, with each deck's *own* grid ticks drawn in its own lane. So you see grid-against-grid *and* transient-against-transient. Misalignment reads as an asymmetric zipper; that is the whole point of the mirrored arrangement and it is what makes beatmatching visible.

**Zoom levels**, specified in bars visible across ~1100 pt of lane width, at 128 BPM (beat = 469 ms):

| Level | Bars | Beats | pt/beat | **ms/pt** | Use |
|---|---|---|---|---|---|
| z−1 | 1 | 4 | 275 | **1.7** | Only useful with local render; a 10 ms error is 5.9 pt — unmissable. |
| **z0** | **4** | **16** | **69** | **6.8** | **Phase alignment.** A 10 ms error is 1.5 pt — visible, marginal. |
| z1 | 8 | 32 | 34 | 13.7 | Default. |
| z2 | 16 | 64 | 17 | 27 | Phrase view. |
| z3 | 32 | 128 | 8.6 | 55 | Structure view. |

**Read that ms/pt column.** The engine spec's budget is ≤ 10 ms hard, ≤ 25 ms tolerable (§1.2). **At the default zoom a 10 ms phase error is three quarters of a point.** You cannot see it. This is the argument for a **dedicated phase meter**, not for expecting the eye to read it off a waveform — Traktor ships exactly this and the spec's research confirms it exists precisely because phase residual is invisible in a waveform.

**Phase meter**, in the 24 pt ruler band, 120 × 20 pt: a needle, full scale ±1 beat, with a shaded ±10 ms centre zone drawn at exaggerated width (the centre 20 % of the widget is the centre 2 % of the range — a deliberately non-linear scale, because near zero is the only place resolution matters). Colour it by the spec's bands: green ≤ 10 ms, amber ≤ 25 ms, red > 30 ms.

**Beatgrid drawing:**

| Element | Style |
|---|---|
| Phrase start (every 32 beats) | 3 pt `Color.scAccent`, full height, numbered |
| Downbeat (bar 1 of 4) | 2 pt white, full height |
| Bar line | 1 pt white 45 %, 60 % height |
| Beat | 1 pt white 25 %, 30 % height |
| **Grid with `confidence < 0.6` or estimated provenance** | **dashed and desaturated, labelled "estimated"** |

That last row is not decoration. The codebase already has the `isEstimated` discipline and `DJTransitionService.synthesizeAnalysis` exists specifically so a hashed fake BPM can never be presented as a measurement. A solid beatgrid over a track whose BPM came from a hash is the same lie in pixels.

**Rendering.** Do **not** re-stroke a `Canvas` path at 120 Hz. A 6-minute track at 5 ms/bucket is 72,000 buckets; at 2 px/bucket that is a 144,000 × 176 px image — 101 MB as one bitmap. **Tile it:** 2048 px-wide tiles, ~71 per track, keep ±3 resident (7 × 2048 × 176 × 4 B = 2.5 MB per deck, 5 MB for two). Render tiles lazily on a background queue at deck load. Each frame then blits a translated sub-rect and strokes only the grid lines and the playhead — a few dozen primitives instead of a few thousand. **E-T2** in §7 is the profile that confirms this is necessary; my prior is that it is.

**(c) Where the detail waveform's *data* comes from** differs by render location, and this is the honest part:

- **Local render:** the deck already has a decoded canonical 44.1 kHz `.caf` on disk from `SourceImporter`. Compute the 3-band envelope at 5 ms/bucket once at load. Real data, full fidelity.
- **Remote (TV renders):** the iPad has no decoded audio and must not download the track twice. **The TV computes the envelope at deck load and sends it once as a blob** (§4.5). 72,000 buckets × 3 bands × `UInt8` = 216 KB, base64 in the JSON envelope = 288 KB, which fits the 1 MiB frame cap (V9) with room to spare, and takes ~20 ms on a LAN. One frame, once per deck load. This is far better than any streaming scheme and it is what makes the remote console visually identical to the local one.

### 3.4 Mixer section — and exactly which controls need new DSP

The whole point of this table is to separate "v1 with what exists" from "needs new nodes". The graph today, per deck, is `player → timePitch → eq(3-band) → filter(1-band, resonant **low-pass only**) → mixer → mainMixerNode → output`.

| Control | Backed by | Status |
|---|---|---|
| **TRIM / gain** | `setGain(_:on:over:)` | **Exists.** |
| **HI / MID / LOW** | `setEQ(_:on:toDecibels:over:)`, `eqGainRange = -60...12` | **Exists**, with two caveats below. |
| **FILTER, left half (low-pass)** | `setFilterCutoff` + `setFilterResonance`, `filterCutoffRange = 30...20_000`, bypass above `filterOpenHertz = 19_000` | **Exists.** |
| **FILTER, right half (high-pass)** | — | **Does not exist.** `AVAudioUnitEQ(numberOfBands: 1)` → `2`, `bands[1].filterType = .resonantHighPass`, one new `RampKey.filterHighPassCutoff(Deck)`, one `setHighPassCutoff` mirroring `setFilterCutoff`. **No new node, no graph change, no reconnection.** ~40 lines, size **S**. This is the cheapest high-value change available and the engine spec says the same (§3.2 T4). |
| **Line fader** | `setGain` | **Exists.** |
| **Crossfader** | `crossfade` (`@Published`, `didSet` → `applyMixerGains()`) | **Exists**, equal-power only. |
| **Crossfader curve selector** | — | **Needs a change to `applyMixerGains()`.** Today it unconditionally applies `a = cos(xπ/2)`, `b = sin(xπ/2)`; `FadeCurve` only shapes how the *fader position* travels, not the gain law. A real cut curve (full A until 90 %, then a 10 % transition) is a different law, not a different travel. Size **S**, but it is a change to the gain law — flag it explicitly rather than sliding it in. |
| **Channel level meter** | `DeckState.level` / `.peak`, tapped on `filter` output = post-EQ, **pre-fader** — a proper DJ channel meter | **Exists**, 20 Hz with attack-instant / release-0.75 ballistics. |
| **Master meter** | — | Trivial: tap `mainMixerNode`. Size **S**. |
| **Master limiter** | — | **Does not exist and is required.** `kAudioUnitSubType_PeakLimiter` via `AVAudioUnitEffect(audioComponentDescription:)`, −1.0 dBTP. See below. |
| **CUE / headphone monitor** | — | **Architecturally blocked on hardware.** §2.2, §3.6. |

**Two caveats on the EQ, both worth fixing in the same commit:**

1. **The low shelf is at 120 Hz.** Every reference mixer sits higher — DJM nominal 70 Hz but with the shelf transition well above it, Xone:92 low shelf at 250 Hz, Xone:42 "420 Hz and down". At 120 Hz a −60 dB cut leaves the entire 120–250 Hz kick-body and bass-guitar region present, which is exactly the mud band. **Move it to 200 Hz.** One line, disproportionate audible effect, and the engine spec independently reaches the same conclusion (§3.1(b)). The high shelf at 6 kHz is also low against the DJM's 13 kHz — less urgent, more of a house-sound call, but worth an experiment.
2. **The knob's travel should not map to the full −60…+12 dB.** `KnobControl` currently maps ±60 dB across `pixelsForFullSweep = 130` (V21) — that is **0.55 dB per point**, and with ±4 pt of finger jitter you get ±2.2 dB of unintended gain on a bass shelf. Two fixes, both cheap:
   - Map the travel to **−26…+6 dB** (the DJM range) over **200 pt** = 0.16 dB/pt. Better by 3.4×.
   - Put the **kill on a double-tap** (instant −60 dB, latching, with a hard visual state). This is how you actually use a kill, it is instantaneous rather than a swipe, and it removes the need for the bottom 34 dB of travel to exist at all.
   - Fine mode (second finger) gives another ×10.

**Keep the rotary appearance, keep the vertical drag.** The knobs *look* rotary and *behave* linear today, which sounds like the worst of both but is what djay and rekordbox do and what a 42 pt control forces (there is no stable drag radius on a small knob — the existing comment says exactly this). The fix is not to change the gesture; it is to **draw a thin vertical value track beside each knob** so the mapping is discoverable in one look. Use real vertical faders for TRIM and the line fader, where there is height to spend.

**Gain staging, and why the limiter is not optional.** The engine spec's §1.6 finding: two beatmatched 4/4 tracks are *deliberately correlated* in the low band — same kick sample instant, same sub octave — so the sum below 250 Hz is **+6 dB**, not the +3 dB you get from uncorrelated material. Equal-power crossfade at the midpoint gives each deck −3.01 dB, so correlated content lands at **+3 dB over unity**; both line faders at full during a swap gives **+6 dB**.

The auto-DJ never does that because it drives its own faders. **A human will.** So the limiter moves *earlier* here than in the engine spec's staging — it belongs in the console's v1, not v2. `mainMixerNode` is deliberately never explicitly connected to `outputNode` (so it tracks the hardware format across route changes), so the limiter goes in as an `AVAudioUnitEffect` between `mainMixerNode` and the output, and that connection **does** need to survive `handleConfigurationChange`. Treat it as the one graph change with real regression risk.

### 3.5 Hot cues and loops

**Hot cues.** 8 pads per deck, `(seconds, name, colour)`, persisted per track id.

Two problems with what exists. `CuePadView` keeps its cue point in phone-local `@State` and **never sends or persists it** (V21) — long-press sets it, app relaunch loses it. And `MixEngine.seek(deck:to:)` does `player.stop()` + reschedule, so a hot-cue hit is not gapless and not sample-accurate.

- **Persistence:** a `CuePointStore` alongside the existing `AnalysisCache.swift` (already a shared file in both targets). Keyed by track id, so cues survive across devices if you ever sync them, and survive a deck reload trivially.
- **Accuracy:** a hot cue is a *now* event. It cannot be scheduled ahead and it cannot be quantised without destroying the point of drumming on the pads. So: **hot-cue drumming works on local render and is quantise-only when remote** (§4.6). Gapless hitting needs the engine spec's `sampleAccurateCue` (**M**, gated on E1).
- **Pad modes**, Serato/rekordbox convention: **HOT CUE** and **LOOP** in v1. **ROLL** needs a momentary loop where the timeline keeps advancing underneath — `setLoop` freezes the playhead, so it is a *loop*, not a *roll*, and the two must not be conflated in the API (the engine spec makes the same point). **SLICER** is out of scope.

**Loops — including the 20-bar ask.**

The good news first: **long loops are cheap.** `setLoop` reads the region into an `AVAudioPCMBuffer` and schedules it with `.loops`, so the wrap happens on the render thread with no Swift in the path. At the canonical 44.1 kHz stereo float32 that is 352,800 B/s:

| Loop | @128 BPM | Memory |
|---|---|---|
| 4 bars | 7.5 s | 2.6 MB |
| 16 bars | 30 s | 10.6 MB |
| **20 bars** | **37.5 s** | **13.2 MB** |
| 32 bars | 60 s | 21.2 MB |
| 32 bars @ 90 BPM | 85.3 s | **30.1 MB** |

Nothing here is a problem. **Ship long loops.**

The blocker is different and it is one line: **`deckStatePayload` hardcodes `bpm: nil` (V13)**, so `LoopControlView` offers loop lengths in *seconds* (`[1,2,4,8,16]`) and explicitly says in a comment that it does so because BPM is unreliable. Fix that and the entire beat-based loop UI unblocks:

- **Beat lengths:** 1/8, 1/4, 1/2, 1, 2, 4, 8, 16, 32 beats.
- **Bar lengths:** 1, 2, 4, 8, 16, 20, 32 bars.
- **Manual in/out:** tap IN, tap OUT, then auto-snap the length to the nearest sensible beat count if within 10 %. A CDJ does this and it is what makes hand-set loops usable.
- **20 bars is not a power of two** and will not land on a phrase boundary — exiting a 20-bar loop puts you 12 bars out of phrase. Show a small **out-of-phrase glyph** on the loop readout when the length is not 1/2/4/8/16/32 bars. A marker, not a dialog; a real DJ knows what they are doing and does not want to be nannied, but does want to be told.
- **Halve / double: v2.** `setLoop` does `player.stop()` + `scheduleBuffer`, which its own comments concede is the audible-gap path. A halving on a bar line must be sample-accurate, which means pre-building the halved buffer and scheduling it at a computed `AVAudioTime` rather than stopping first. Size **M**, gated on **E1**. Until then, offer "set an N-beat loop from the next downbeat" and "exit loop" and nothing else — a gap on every halving would make the build sound broken.

### 3.6 Master bus and the cue path

Signal chain to build:

```
deck A mixer ─┐
              ├─► mainMixerNode ─► [peak limiter, −1.0 dBTP] ─► outputNode (ch 1/2)
deck B mixer ─┘

cue bus:  deck A/B pre-fader taps ─► cueMixer ─► [cue gain] ─► outputNode (ch 3/4)
```

- **Limiter:** `AVAudioUnitEffect(audioComponentDescription:)` with `kAudioUnitSubType_PeakLimiter` (`'lmtr'`). Threshold −1.0 dBTP, matching the streaming and club-master references. Size **S**. Must be re-connected in `handleConfigurationChange` — this is the one place in the plan that can break the engine on a route change, so it gets a self-test.
- **Cue bus:** only meaningful with ≥ 4 output channels (§2.2). Detect it: `AVAudioSession.sharedInstance().maximumOutputNumberOfChannels`. If ≥ 4, offer full cue. If 2, offer **split-cable mode** (master summed to L, cue summed to R) behind an explicit toggle with a warning, because it destroys the stereo image and directly contradicts the documented "stay stereo, let the receiver upmix" decision. If 2 and split is off, **the CUE buttons are disabled and say why.**
- `MixEngine` deliberately does **not** call `setPreferredOutputNumberOfChannels` today, for a good documented reason (negotiating discrete multichannel with only L/R populated tells a Sonos "already spatialised", suppressing its upmix). Enabling a 4-channel cue bus **requires** calling it. So: only call it when the user has explicitly enabled cue *and* an interface with ≥ 4 outs is present, and restore the default on teardown. Do not make this a global setting.

### 3.7 Tempo faders and key lock

**Range selector: ±6 / ±10 / ±16 / WIDE (±50 %)**, matching CDJ-3000. `MixEngine.rateRange` is `0.5...2.0`, so WIDE fits with headroom. Default ±6.

**Resolution, and why the fader alone is not enough.** A 300 pt vertical throw (57.7 mm — about half a CDJ's 100 mm; my hands zone cannot afford 520 pt) across ±6 % at 128 BPM is ±7.68 BPM over 300 pt = **0.0256 BPM per point**. Finger precision is roughly ±4 pt, so ±0.10 BPM.

Now apply the engine spec's drift arithmetic (`drift_ms = 1000 · Δbpm · T / bpm`): 0.1 BPM at 128 BPM is **0.78 ms/s**, which is 10 ms of phase error in **12.8 seconds**. That is under seven bars.

**So a bare touch tempo fader cannot hold a beatmatch.** That is not a defect of this design; it is why CDJ DJs nudge continuously and why software has sync. Three responses, all of which ship:

1. **Fine mode** (second finger, ×0.1) → 0.0026 BPM/pt → ±0.010 BPM → 10 ms in 128 s ≈ 68 bars. Adequate.
2. **Keyboard increments** at 0.05 % per press (§1.5) — quantised, repeatable, better than any finger.
3. **SYNC** (§3.8), which removes the problem entirely when the grids are trustworthy.

**Never store the display BPM.** The engine spec is emphatic and the arithmetic backs it: holding tempo to one decimal (±0.05 BPM) drifts 10 ms in 25.6 s. Store the **rate ratio as a `Double`**, quantise the fader to 0.01 % (1200 discrete steps across ±6 %), and derive the BPM label for display only. Show two decimals; hold full precision.

**MASTER TEMPO (key lock) is free.** `AVAudioUnitTimePitch` with `rate` moved and `pitch` untouched *is* key lock — that is the default behaviour today. To turn key lock **off** (turntable mode) you couple `pitch = 1200 · log2(rate)` on the same node. One node, zero reconnection. Default **on**, matching the 24,202 real transitions in Kim et al. where DJs leave master tempo on.

**Turntable mode has a counterintuitive rule worth putting in the UI, not just a comment.** With varispeed, *small* pitch changes are more harmonically damaging than large ones:

| Rate | Cents | Musically |
|---|---|---|
| +2 % | +34 | a third of a semitone — sour |
| **+3 %** | **+51** | **a quarter-tone. Not a key at all.** |
| **+5.946 %** | **+100** | **exactly one semitone — a real key** |
| +8 % | +133 | a semitone and a third |

So: **in turntable mode, snap the fader to semitone multiples** (within 15 cents) and re-derive the Camelot code, or refuse and stay key-locked. Show the resulting key.

**KEY SHIFT** (independent of tempo): `setPitch(cents)`, `pitchCentsRange = ±2400`. Snap to semitones, ±12 range, display the new Camelot code. Free — exists today.

### 3.8 SYNC, TEMPO MATCH, and not lying about which one you shipped

Traktor distinguishes **BeatSync** (tempo *and* phase) from **TempoSync** (tempo only, "there can be offsets in the beat synchronization") and ships a separate phase meter for the residual. Mixxx calls the audible symptom of residual phase error a "double bass kick". That distinction is exactly the one this codebase currently cannot honour, and it should be visible in the button label.

- **What exists today:** `matchTempo(on:sourceBPM:targetBPM:over:)`, which sets `rate` and nothing else. Every `scheduleSegment`/`play` passes `at: nil`, so the incoming deck starts "whenever the main actor gets round to it" — a `Task` hop plus a render quantum, ≈ 11.6 ms of jitter at 512 frames before you count the hop, against a 10 ms budget. **The engine cannot phase-lock.**
- **Therefore v1 ships a button labelled `TEMPO`, not `SYNC`.** It matches rate. It does not claim phase. The phase meter sits next to it showing the residual, which is the honest UI and is also the useful one.
- **`SYNC` (phase lock) is v2, gated on E1** — "is `AVAudioPlayerNode.play(at:)` sample-accurate relative to another player node in the same engine?" Offline render, two impulse trains at 128 BPM, cross-correlate, assert < 1 ms. Until that passes, phase lock is a hope.
- Also gate on the **grid confidence**: if either deck's beatgrid is estimated or `confidence < 0.6`, SYNC is disabled with a reason string. The library scan in the engine spec found a 6 % analysis-failure rate in the owner's own Serato database and a strongly bimodal BPM distribution — a sync button that confidently locks to a hashed BPM is worse than no sync button.
- **Beat parity is not phase.** A one-beat offset in 4/4 house produces *no flam at all* — the kick is on all four beats — but the incoming clap lands on the outgoing 1 and 3 and the groove inverts. No phase metric catches it. So the phase meter needs a companion: a **beat-in-bar indicator** (1 2 3 4, lit) and a **phrase counter** (bar N of 32) per deck, drawn in the ruler band. Those two readouts catch the failure the meter cannot.

### 3.9 What replaces haptics

iPad has none (V1). The `sensoryFeedback` calls already in `DJControlView` are silent no-ops there. Do not add more, and **audit the existing ones** — a detent that fires haptics on iPhone and nothing on iPad needs a visual counterpart either way, so the fix is additive rather than conditional.

Ranked by how much they actually help:

**1. Resistive value mapping — the best substitute, and it is free.** Do not make a detent a *flash*; make it a *stickiness in the value*. Within ±6 pt of a detent, the value moves at 0.25× finger speed; past that it releases at full rate. Your finger feels the *number* stop moving even though the glass does not push back, and because the sense being fooled is proprioception rather than touch, it works. Apply to: tempo fader at 0.00 %, EQ knobs at 0 dB, filter at centre (bypass), crossfader at centre and at both ends, loop length at power-of-two bar counts.

This is a change to the router's delta→value mapping (§3.1), which is one function. It is the highest value-per-line item in this whole section.

**2. Visual detents at display rate.** ProMotion iPads run to 120 Hz. A two-frame (16.6 ms) bright flash at the snap instant is clearly perceptible. Drive it from the `TimelineView(.animation)` clock, **not** from a default SwiftUI `.animation()` — the latter can land a frame late, and a detent that is a frame late is worse than no detent. Spec: 1 pt full-brightness line at the detent position + a 60 ms 1.04× scale pulse on the control body.

**3. Audible click layer — conditionally.** A short click rendered into the graph is the closest thing to real tactile confirmation. The problem is that on a single-output iPad **the click goes to the PA**. So:

- **Local render, ≥ 4 outputs:** click on the cue bus (ch 3/4). Correct and unobtrusive. Do this.
- **Local render, 2 outputs:** off by default. Offer it at −40 dBFS as an explicit setting for headphone practice.
- **Remote (iPad drives the TV or the phone):** the click renders **on the iPad**, locally, while the music renders elsewhere. This is the case where you most need confirmation and where it is completely safe. **Do this — it is the best feedback channel in the remote configuration and it costs one `AVAudioPlayerNode` on a separate, tiny engine.**

**4. Apple Pencil Pro** via `UICanvasFeedbackGenerator.alignmentOccurred(at:)` (V3). Real tactile feedback, on real hardware, verified. Useless for two-handed mixing — but genuinely good for a **one-handed automation mode**: draw a filter sweep or a fader curve onto the waveform lane with the Pencil, feel the alignment tick at each bar line. That is a nice, small, distinctive feature and it is the only place iPad haptics exist at all. Stretch, but list it.

**5. Game controller haptics** (V4). Technically real; a DualSense in your lap while DJing is absurd. Mention and dismiss.

**6. The iPhone as a haptic satellite.** The phone has a Taptic Engine, is already on the same Bonjour channel, and would be sitting next to the iPad. A `haptic_pulse` message → `UIImpactFeedbackGenerator`. LAN latency 5–15 ms makes it fine for **confirmations** ("loop armed", "cue set") and useless for anything beat-synchronous. Cheap plumbing, genuine novelty, honest limits. Stretch — and note it requires the iPad to be a *server*, which it is not today (V7, §5.3).

**Verdict: ship 1 and 2 in v1, and 3 in the remote configuration. Everything else is optional colour.** Do not design any interaction whose only feedback is a haptic.

### 3.10 Layout at real sizes

All figures in points. Conversion at 5.197 pt/mm (I1) so the physical sizes are checkable.

#### 13" iPad Pro, landscape — 1376 × 1032

```
┌──────────────────────────────────────────────────────────────────────────────┐ 24 margin
│ TOP BAR                                                                 48   │
│  A: title · key · 128.00 BPM · ±0.00%   │ MASTER  bar 17/32 │  B: …          │
├──────────────────────────────────────────────────────────────────────────────┤ 12
│ OVERVIEW A  (whole track, cues, loop, mix point)                        56   │
│ OVERVIEW B                                                              56   │
├──────────────────────────────────────────────────────────────────────────────┤ 12
│ DETAIL / BEATGRID STACK                                                200   │
│    deck A, 3-band, drawn downward                              88            │
│    ruler: beat ticks · phase meter 120×20 · 1 2 3 4 · bar N/32 24            │
│    deck B, 3-band, drawn upward                                88            │
├──────────────────────────────────────────────────────────────────────────────┤ 12
│ PERFORMANCE ROW                                                        140   │
│  [8 pads A: 2×4 @ 80×62]  [loop A]        [loop B]  [8 pads B: 2×4 @ 80×62] │
├──────────────────────────────────────────────────────────────────────────────┤ 12
│ HANDS ZONE                                                             430   │
│  ┌────────────┐ ┌──┐  ┌──────────────────────────────┐  ┌──┐ ┌────────────┐ │
│  │            │ │T │  │ TRIM  A │ TRIM  B            │  │T │ │            │ │
│  │   JOG A    │ │E │  │ HI MID LOW │ HI MID LOW      │  │E │ │   JOG B    │ │
│  │   340 ⌀    │ │M │  │ FILTER  │ FILTER             │  │M │ │   340 ⌀    │ │
│  │            │ │P │  │ line fader │ line fader      │  │P │ │            │ │
│  └────────────┘ │O │  │ ── CROSSFADER 420 ────────── │  │O │ └────────────┘ │
│                 └──┘  └──────────────────────────────┘  └──┘                │
└──────────────────────────────────────────────────────────────────────────────┘ 24 margin
```

Vertical: `24 + 48 + 12 + 112 + 12 + 200 + 12 + 140 + 12 + 430 + 24 = 1026` ≤ 1032. Six points spare.

Horizontal: `24 + 340 (jog) + 12 + 56 (tempo) + 20 + 472 (mixer) + 20 + 56 + 12 + 340 + 24 = 1376`. Exact.

Physical check: jog 340 pt = **65.4 mm** (DDJ-400 is 74 mm). Crossfader throw 420 pt = **80.8 mm** (a DJM crossfader is 45 mm — ours is nearly twice as long, which is the right trade on glass). Tempo throw 300 pt = **57.7 mm** (CDJ is 100 mm). Hot cue pad 80 × 62 pt = **15.4 × 11.9 mm** (a DDJ performance pad is ~19 mm square). Line fader ~220 pt = **42 mm** (DJM is 60 mm).

Mixer column, 472 pt wide = 236 pt per channel: TRIM (vertical mini-fader, 120 pt), HI/MID/LOW (three 76 pt knobs in a row, `3 × 76 + 2 × 4 = 236`), FILTER (one 76 pt centre-detented knob + a 100 pt horizontal track), line fader (220 pt tall × 48 pt), CUE + PFL buttons. Crossfader spans both channels at the bottom.

#### 11" iPad Pro, landscape — 1210 × 834

```
top bar 40 · overview 2×44=88 · detail stack 160 (72/16/72) · performance 112 · hands 380
vertical: 20 + 40 + 10 + 88 + 10 + 160 + 10 + 112 + 10 + 380 + 20 = 860  ✗ over by 26
```

So it does not fit as-is. **Two changes at 11":**

- Detail stack **144** (64 / 16 / 64) instead of 160.
- Performance row **100** instead of 112, with pads at **68 × 44** in 2 × 4 = `4×68 + 3×6 = 290` wide, 94 tall.

Revised vertical: `20 + 40 + 10 + 88 + 10 + 144 + 10 + 100 + 10 + 380 + 20 = 832` ≤ 834.

Horizontal: `20 + 288 (jog) + 10 + 48 (tempo) + 16 + 446 (mixer) + 16 + 48 + 10 + 288 + 20 = 1210`. Exact. Mixer 223 pt per channel: three 68 pt EQ knobs (`3×68 + 2×3 = 210`), 190 pt line fader, 360 pt crossfader.

At 11" the detail lanes are 64 pt tall against 88 pt at 13". That is the single biggest fidelity loss and it is the right one to take — the beatgrid ticks and the phase meter are unchanged, and only the waveform's amplitude resolution suffers.

#### Occlusion audit

Draw the hand shadows before you draw the controls.

- **Jog wheels are bottom-outer.** A hand on the platter occludes ~470 × 625 pt extending up and inward (§3.2). From the jog centre at roughly `(194, 812)` on 13", that shadow covers the tempo fader (acceptable — you are not touching it) and reaches the bottom 190 pt of the mixer column. **It does not reach the performance row or the waveforms.** Correct by construction.
- **The crossfader is at the bottom of the mixer**, which is inside the right hand's natural shadow when the right hand is on jog B. That is fine — the crossfader is the one control you can operate blind, and it has the endpoint detents (§3.9) to tell you where you are.
- **The detail waveform stack is at eye level and never occluded.** That is the whole reason it is at the top rather than between the decks where a CDJ layout would put it.
- **Never put a readout directly above a control.** Level meters go *beside* the line faders, not above them. BPM readouts go in the top bar, not on the tempo fader.

#### The no-scroll rule

**There is no `ScrollView` anywhere in the console, at any size.** This is a hard constraint, not a preference: a scroll view competes for every vertical drag, which is what an EQ knob, a line fader and a tempo fader all are. The existing `DJControlView` uses `ViewThatFits` with a `ScrollView` portrait fallback (V21) — that fallback is exactly the thing that must not exist on iPad. Below 900 pt the answer is the single-deck layout (§1.3), not a scroll view.

---

## 4. Networked realtime — schedule, do not stream

### 4.1 The principle, and the one sentence that follows from it

Send **"at bar 41 beat 1, begin a 16-bar crossfade from 0.0 to 1.0"**, not **"fader to 0.5 now"**. The rendering device executes against its own clock. Continuous gestures become **parameter ramps with a near-future start time**, interpolated locally by the receiver — which is free, because `MixEngine.ramp(_ key:duration:apply:)` already interpolates at 60 Hz and already cancels a prior ramp with the same `RampKey` (V14), so segment chaining works with no new machinery.

The consequence, which must be stated as a product decision rather than discovered as a bug:

> **Remote means quantised. If you want unquantised, render locally.**

A crossfader cut sent as a ramp with a 150 ms lead *feels* 150 ms late. So a cut is not sent as a ramp: it is detected (velocity above threshold, target at an endpoint) and re-sent as a scheduled move **on the next beat**, with a ghost marker on the beat ruler showing that it is armed. Which is what you wanted musically anyway — and the UI showing the armed state is what makes it feel like intent rather than lag.

### 4.2 Clock synchronisation

**Use NTP-style offset estimation (Cristian's algorithm) with a minimum-RTT filter. Not PTP. Not Ableton Link.**

- **PTP (IEEE 1588)** buys sub-microsecond accuracy *only* with hardware timestamping at the NIC. Over WiFi, from an app-layer socket, with no access to the PHY, it degrades to exactly the same round-trip estimate as NTP while costing far more to implement. It is the right answer for AVB/wired audio and the wrong answer here.
- **Ableton Link** is the closest prior art and it is worth understanding rather than adopting: it synchronises a shared *tempo and beat phase* over UDP multicast, not a wall clock, and it explicitly does not try to sync sample clocks — each peer renders on its own clock and Link converges phase gradually. That model is exactly what §4.3 does. But adopting LinkKit itself means shipping a third-party SDK on **both** ends, and I could not verify tvOS support. **The idea is right; the dependency is not. Reimplement the 200 lines.**
- **NTP-style** gets you ±RTT/2 of accuracy, which on a LAN is ±1–3 ms. Against a 10 ms phase budget that is comfortable.

**Sync the right clock.** This matters more than the algorithm. `AVAudioTime.hostTime` is `mach_absolute_time()` — so the clock you synchronise must be `mach_absolute_time()` converted to nanoseconds through `mach_timebase_info`, **not** `Date()` and not `CLOCK_REALTIME`. If you sync wall clock and schedule against host time, you have synchronised the wrong thing and the error will look like jitter. (Note the existing `issuedAtMillis` is `Date().timeIntervalSince1970 * 1000` — wall clock — and is used only for a 120 s freshness window (V12). Leave it alone; it is not the clock you want.)

**Wire:**

```
.clockPing  (phone→TV)  { t1: Int64 }                    // client mach-ns
.clockPong  (TV→phone)  { t1: Int64, t2: Int64, t3: Int64 }  // t2 = TV mach-ns at receive,
                                                              // t3 = TV mach-ns at send
```

Client on receipt at `t4`:

```
offset = ((t2 − t1) + (t3 − t4)) / 2      // add to a client time to get TV time
rtt    = (t4 − t1) − (t3 − t2)
```

**Sampling and filtering:**

- **2 Hz for the first 10 s** after `.connected`, then **0.2 Hz** (every 5 s).
- Keep a sliding window of the **last 32 samples**. Use the offset from the sample with the **minimum RTT**, not the mean. The least-queued sample has the least path asymmetry, and asymmetry is the entire error term in Cristian's algorithm. This is what NTP does and it is one line.
- Do **not** fit a drift slope. Two consumer crystals differ by 10–50 ppm, so between 5 s resyncs the accumulated drift is 0.05–0.25 ms (I4). Below the noise floor. A slope fit is over-engineering.
- Publish `offsetUncertainty = minRTT / 2` and **put it in the UI**: a small readout reading `link ±2 ms`. A DJ should be able to see how tight the link is before they commit to a mix, the same way they can see whether a needle is tracking.

**Sequencing:** `clockPing`/`clockPong` must bypass the `SequenceGate` (they are not deck commands) and must be exempt from the 120 s freshness check (they *are* the clock). They should also skip HMAC — they carry no authority and signing them puts SHA-256 in the latency path. If that feels loose, sign them but do not let verification failure block the sample; just discard it.

### 4.3 The musical timeline

Everything beat-critical is expressed in **beats on a shared timeline**, not seconds.

```
.masterClock  (TV→phone, 10 Hz, alongside .djState)
{
  masterDeck:        ControlDeck
  beatAnchorHostTime: Int64      // TV mach-ns of the beat named below
  beatIndex:          Int64      // absolute beat number since track start
  beatPeriodNs:       Int64      // current beat period INCLUDING the rate multiplier
  barLength:          Int        // 4
  phraseLength:       Int        // 32
  generation:         Int        // bumped on seek, loop set/clear, rate change, deck load
}
```

From this the iPad computes any beat's TV host time exactly:

```
t_TV(beat n) = beatAnchorHostTime + (n − beatIndex) × beatPeriodNs
t_iPad(n)    = t_TV(n) − offset
```

`generation` is the discipline that keeps this honest: any event that invalidates the extrapolation bumps it, and the iPad discards everything scheduled against a stale generation rather than executing something computed from a timeline that no longer exists.

**Where the beat grid itself comes from** is the weak point, and it should be said plainly: today `deckStatePayload` sends `bpm: nil` (V13), the beatgrid work is v2/v3 in the engine spec, and `DJTransitionService.synthesizeAnalysis` will happily hash a track id into a fake BPM. **Until a real grid exists, `masterClock` must send `generation` with a `confidence` field and the console must draw the dashed "estimated" grid (§3.3) and disable SYNC.** Quantising to a fake grid is worse than not quantising.

### 4.4 Scheduled commands, and continuous gestures as ramp segments

One new message covers everything beat-critical:

```
.djSchedule (phone→TV)
{
  atBeat:        Int64          // absolute beat index on the master timeline
  generation:    Int            // must match; else drop
  action:        enum { crossfadeRamp, gainRamp, eqRamp, filterRamp, rateRamp,
                        cue, loopSet, loopExit, loopHalve, bassSwap, play, pause }
  deck:          ControlDeck
  band:          EQBand?        // for eqRamp
  from, to:      Double
  durationBeats: Double         // 0 = instantaneous
  curve:         enum { linear, equalPower, logarithmic }
  lateness:      enum { snapToValue, requantise, drop }
  sequence, issuedAtMillis, nonce, signature       // reuse the existing auth machinery
}
```

**Durations are in beats, not seconds.** If the tempo changes mid-ramp, a seconds-based ramp desynchronises from the music; a beats-based one does not. The receiver converts beats→nanoseconds at execution time using the live grid.

**Continuous gestures become a segment stream.** The iPad samples the finger at 120 Hz but sends at **10 Hz**. Every 100 ms it emits one segment covering the *next* 100 ms, starting at `now + lead`:

```
from          = value predicted at (now + lead)
to            = value predicted at (now + lead + 100 ms)      // first-order hold
durationBeats = 100 ms expressed in beats
```

First-order hold (linear extrapolation from the last two samples) over 100 ms, for a fader moving at human speeds (≤ ~2 units/s), gives ~±0.02 of error on a 0–1 crossfader. Invisible.

**The lead constant.** This is the number the whole design hangs on and it must be measured, not guessed (I3, E-N1):

```
lead = clamp(3 × p95_oneWayDelay + 30 ms, 120 ms, 400 ms)
```

recomputed every 5 s from the same ping window, and floored at `renderQuantum + rampTick(16 ms) + publishJitter(100 ms)`. At 128 BPM one beat is 469 ms, so **beat quantisation dominates the lead entirely** — the lead only decides whether you make *this* beat or the next one. Display it: `latency 140 ms · quantise 1 beat`.

**Nagle must go.** `noDelay` is unset everywhere (V10). A ~300-byte JSON frame every 100 ms against un-ACKed data is precisely the Nagle pathology, and it can add up to 200 ms of purely self-inflicted delay — larger than the entire lead budget. **Two lines, one on each end. This is the highest value-per-line network change in the document, and it improves the existing console today, before any of the rest of this ships.**

### 4.5 Late arrival

The receiver compares `atBeat` to its own now and branches. At 128 BPM, one beat = 469 ms and 1/8 beat = 59 ms.

| Lateness | Behaviour |
|---|---|
| `≤ 0` (early) | Schedule normally. The expected case. |
| `0 < late ≤ 1/8 beat` | Execute immediately. **For ramps, start from the value interpolated at "now", not from `from`** — otherwise you get an audible jump backwards before the ramp resumes. |
| `1/8 beat < late ≤ 1 beat` | Apply the `lateness` policy. `.snapToValue` for EQ / filter / fader / gain — set the endpoint, no ramp, no jump. `.requantise` for `cue`, `loopSet`, `loopHalve` (next beat) and `bassSwap` (next **bar**) — a bass swap fired 200 ms late is worse than one fired a bar later. `.drop` for anything whose musical meaning was the instant. |
| `> 1 beat` | Drop. Send `.error("late")` back. |
| `generation` mismatch | Drop silently. The timeline it was computed against no longer exists. |

**Adaptation:** three drops in 10 s → `lead × 1.5` and flash the latency readout amber. Ten seconds clean → decay back toward the computed value at 5 %/s. Never let it ratchet permanently.

**Interaction with the existing `SequenceGate`.** It admits strictly-greater `sequence` per `(type, deck)` and returns *silently* on failure (V-agent). That is correct for a segment stream — a late-arriving stale segment should vanish. But it means a dropped segment leaves a gap, so the receiver must **hold the last value** rather than jumping. `MixEngine.ramp`'s existing `RampKey` cancellation gives exactly that behaviour for free: a new segment cancels the old ramp mid-flight and starts from wherever it got to.

### 4.6 What cannot be remoted, ever

This is the list to be honest about up front, because each item is a control that must either be disabled or visibly change behaviour when the iPad is not the renderer.

| Gesture | Why | Remote behaviour |
|---|---|---|
| **Scratch** | A closed sensorimotor loop needing < 10 ms *round trip* with low jitter. The network alone is 2× one-way plus jitter — 10–20 ms typical, 100 ms+ at p99 (I3). And a gesture that has not happened yet cannot be scheduled. Doubly blocked, since scratch also needs a deck rewrite (§2.3). | **Control removed**, not disabled-with-a-tooltip. The platter face becomes search-only and says so. |
| **Continuous pitch bend / platter nudge by ear** | Same closed loop: hear → nudge → hear, with the network inside it twice. Also requires cue monitoring, which the iPad does not have anyway (§2.2). | Replaced by a **discrete offset**: `nudge deck B by −5 ms`, applied at the next beat. Honestly *better* than a finger, because it is repeatable. Keyboard `[` `]` (§1.5) is the good version of this. |
| **Hot-cue drumming** | The hit time *is* the musical content. Quantising it removes the technique. | Pads still work but are **quantised to the beat** by default, with the quantise division shown on the pad block. Unquantised is offered and clearly labelled as sloppy. |
| **Loop-roll release timing** | The release instant is the musical event; 50 ms late puts you off-grid. | Quantised release only — which is how CDJs behave with quantize on anyway. |
| **Brake / spin-down as a performance move** | It is a continuous rate gesture and its shape is the point. | Offered as a **scheduled preset**: "brake over 1 beat, starting at bar N". Loses the expressiveness, keeps the effect. |
| **Fader cuts / chops on the beat** | See §4.1. | Re-armed to the next beat with a visible ghost marker. |

Everything else — EQ, filter, trim, line faders, crossfader sweeps, tempo, key, loop set/exit, play/pause, deck load — **remotes cleanly as ramps or scheduled discretes**, and in most cases is *more* precise remote than local because it is quantised.

### 4.7 Telemetry the other way: drawing a moving waveform for audio playing elsewhere

The iPad must draw two scrolling waveforms at 120 Hz against audio it is not rendering. **Do not wait for position updates.** Extrapolate from a timestamped anchor.

**The wire change is two fields.** Extend `DJDeckStatePayload` (which already carries `positionSeconds` and `rate`) with:

```
positionHostTime: Int64    // TV mach-ns at which positionSeconds was sampled
generation:       Int      // bumped on seek / loop change / deck load
```

That is it. The existing 10 Hz ticker (V11) then becomes sufficient for perfectly smooth 120 Hz drawing, because between anchors you are not interpolating — you are computing.

**Extrapolation:**

```
t_local  = mach_ns_now
elapsed  = t_local − (positionHostTime − offset)
pos      = positionSeconds + elapsed × 1e−9 × rate
```

then wrap through the loop if `loopStartSeconds`/`loopLengthSeconds` are set. **`LoopMath.wrap` already exists, is pure, is self-tested, and lives in `MixEngine.swift` — which is in the iOS target (V6).** So the iPad gets loop-correct extrapolation for free by calling the same function the renderer uses. That is a genuinely nice reuse and it eliminates the class of bug where the display and the engine disagree about where a loop wraps.

**Rates:**

| Thing | Rate | Why |
|---|---|---|
| Anchor (`positionHostTime` + `positionSeconds` + `rate`) | **10 Hz**, existing ticker | Between anchors the extrapolation is exact to within clock drift, which is 0.05 ms over 100 ms (I4). More anchors buy nothing. |
| Clock resync | 0.2 Hz after warm-up | §4.2 |
| Redraw | **display rate** — `TimelineView(.animation)`, up to 120 Hz on ProMotion | At 200 px/s scroll, each 120 Hz frame moves 1.67 px. Smooth. |
| Beat grid | **once per deck load** | Static per track. Never stream it. |
| Detail envelope | **once per deck load**, 288 KB blob (§3.3c) | Fits the 1 MiB frame cap (V9). |

**Correction slew — do not let the waveform jump.** When a new anchor arrives:

- Disagreement `< 30 ms` and same `generation`: **slew**. Adjust the displayed rate by up to ±3 % for 250 ms to converge. This is a first-order phase-locked loop and it is four lines. Without it, every anchor produces a visible 1–5 ms hitch at 120 Hz.
- Disagreement `≥ 30 ms`, or `generation` changed: **snap**. Something real happened — a seek, a loop, a deck load — and pretending otherwise is worse.

**The same extrapolation path serves local render.** This is the point that makes it worth building properly: locally, calling `playheadPosition(for:)` at 120 Hz means 6× more entries into the documented Obj-C-exception window (§6.3). Instead, sample it at the existing **20 Hz** tick and extrapolate to 120 Hz with the identical code. **One extrapolator, two sources, and the crash surface *shrinks* rather than grows.**

### 4.8 Summary of wire changes

All in `TokenTransferProtocol.swift`, which exists in **two byte-identical copies** that are the wire contract (CLAUDE.md). `cp` one over the other and prove it with `diff -q`.

| Change | Size |
|---|---|
| `noDelay = true` on both ends | **2 lines. Do this first, independently of everything else.** |
| Stop hardcoding `title/artist/bpm = nil` in `deckStatePayload` | ~5 lines. Unblocks beat loops, deck headers, BPM readout. |
| `positionHostTime` + `generation` on `DJDeckStatePayload` | ~10 lines + fingerprint update |
| `.clockPing` / `.clockPong` | ~80 lines, both ends |
| `.masterClock` | ~60 lines |
| `.djSchedule` + receiver scheduling queue | ~250 lines, mostly the receiver's beat→host-time conversion and the lateness branch |
| `.deckWaveform` blob | ~80 lines |
| Segment-stream sender on the iPad | ~150 lines |

Two structural notes. **HMAC sign/verify and JSON coding run on the main actor on both ends** (V-agent) — adding `masterClock` at 10 Hz plus a 10 Hz segment stream roughly doubles the current load, which at ~30 µs per message is still under 1 ms/s of main-actor time. Fine. But the 288 KB waveform blob is *not* fine to decode on the main actor: give it its own off-actor decode path.

And **`.settingsSync` is declared in `MessageType` but wired to nothing on either side** (V-agent). If you are touching the enum anyway, either implement or delete it; a dead case in a wire contract is a trap for the next person.

---

## 5. Where the audio actually renders

### 5.1 Case A — the iPad renders locally

**Available today with no build changes.** `MixEngine.swift` and `PlayerService.swift` are already members of the `SoundingTV iOS` target (V6). This is the single most useful fact in the document: the expensive part is already compiled.

Everything in §3 works, with these caveats:

- **No headphone cue without a USB interface or split-cable mode** (§2.2). Without it, beatmatching is visual (§3.3) or via SYNC (§3.8). This is the biggest single degradation and it is hardware, not software.
- **No scratch** until the `AVAudioSourceNode` rewrite (§2.3).
- **`seek` clicks.** Hot cues, search and loop re-arm all go through `player.stop()` + reschedule. Acceptable, audible, fixed by `sampleAccurateCue` (**M**, gated on E1).
- **Entitlement still applies, and it will bite mid-set.** An unentitled track has its snippet transcodings filtered out in `Track.init`, leaving `streamURL` nil. **The console must surface this at deck-load time with the reason**, not at the mix point. Nothing here circumvents it and nothing should.
- **`AVPlayer` / `AVAudioEngine` must never both render.** This is the invariant, it is enforced by `takeOverFromAVPlayer` / `endMixSession` in shared code, and §6.3 explains why the iPad makes it *harder* to hold than tvOS does.
- **Must refuse AirPlay routes** (§1.6).
- **Battery and thermals.** Two decks decoding, a 120 Hz waveform, and a limiter is a sustained load. Cap the waveform redraw at 60 Hz when `ProcessInfo.thermalState >= .fair` and say so in the UI rather than silently getting choppy.

This is the configuration for practising, for a small room off the iPad's own output into a mixer, and for anything requiring scratch or unquantised pad work.

### 5.2 Case B — the iPad controls the Apple TV

**Works today** in degraded form: `RemoteQueueClient` is in the iOS target and `DJControlView` already drives the TV over it (V21). This is the configuration a party actually wants — the TV is on mains, probably on Ethernet, and is already wired to the PA.

What changes versus Case A:

| Feature | Remote status |
|---|---|
| EQ, filter, trim, line faders, crossfader sweeps | **Full**, as scheduled ramps. Arguably better — quantised. |
| Tempo, key lock, key shift | **Full.** |
| Loop set / exit, deck load, play/pause | **Full**, quantised. |
| Hot cues | **Quantised only.** Drumming is gone (§4.6). |
| Loop roll | **Quantised release only.** |
| Nudge / pitch bend | **Discrete offsets only.** No continuous platter push. |
| Brake / spin-down | **Scheduled preset only.** |
| **Scratch** | **Absent. Control removed, not greyed out.** |
| Detail waveform | **Full fidelity**, via the one-shot 288 KB blob (§3.3c). Visually identical to local. |
| Playhead motion | **Smooth**, via extrapolation (§4.7). Indistinguishable from local. |
| Headphone cue | **Absent** — the TV has one output and it is the PA. Unless you count the click layer, which renders on the iPad and is genuinely useful here (§3.9.3). |
| Feedback | **Best case**, because the audible click layer is free and safe when the music is elsewhere. |

The TV already enforces the engine invariant server-side (`applyMixEngineCommand` requires `PlayerService.shared.isMixEngineLive`), which is the right shape and should be extended, not bypassed, for the new scheduled commands.

One operational note: `RemoteQueueServer` accepts **exactly one connection**, cancelling the previous one when a new one arrives. The widget extension opens its own short-lived connection for control intents and therefore *displaces* the app's socket, self-healing via the client's 10 s liveness watchdog. **A widget tap mid-mix will drop the console's link for up to 10 seconds.** That is tolerable today and unacceptable with a scheduled-command stream in flight. Either suppress the widget's control intents while a DJ session is live, or give the server a second, DJ-only listener.

### 5.3 Case C — the iPad controls the iPhone

**Not possible today, and I recommend not building it.**

`RemoteQueueServer.swift` is a member of the tvOS target only (V7). To make the phone a render target you would add it to the iOS target and give the phone a listener — which immediately collides with two things: the pairing model (`sessionId` and the shared secret both come from the TV's QR pairing flow, and there is no phone-to-phone pairing path), and the single-connection rule.

And musically it is pointless. The phone's output is worse than the iPad's, its thermal budget is smaller, and if you have both devices in the room the iPad should be the renderer.

**The inverse is the interesting one.** Making the **iPad a server** and the **iPhone a client** gives you:

- the iPhone as a **haptic satellite** (§3.9.6) — the only real haptics in the setup;
- a second surface for hot cue pads or the queue, held in one hand;
- a "what's next" screen for whoever is standing next to you.

Same code addition (`RemoteQueueServer` into the iOS target) with a coherent purpose instead of an incoherent one. It still needs a device-to-device pairing flow that does not exist. **Stretch, and only after the console is good.**

### 5.4 The arbiter

`PhonePlaybackCoordinator` is documented in CLAUDE.md as **the one place that decides local-vs-TV**, with an explicit rule that views must never re-derive it. The iPad adds a third state and the rule must extend with it:

```
enum PlaybackTarget { case local, appleTV, localDJ }
```

`.localDJ` is not the same as `.local`: it means the `AVAudioEngine` owns the output and `PlayerService`'s `AVPlayer` has been torn down. If the coordinator does not model it, the mini player and the `NowPlayingSnapshot` will describe an `AVPlayer` that no longer exists while two decks are running — which is exactly the class of bug the coordinator was written to prevent.

---

## 6. Staging, cost, and what can break

### 6.1 The ladder

**v0 — unblocks everything, roughly a day, touches no DJ code**

1. `TARGETED_DEVICE_FAMILY` `1` → `"1,2"` on `SoundingTV iOS` and `SoundingTV-Widget` (V5).
2. `.tabViewStyle(.sidebarAdaptable)` on `PhoneRootView.tabs` (§1.2).
3. `noDelay = true` on both ends of the control channel (§4.8). **Improves the console that already ships.**
4. Stop hardcoding `title/artist/bpm = nil` in `deckStatePayload` (V13). Unblocks beat-based loops and the deck headers.
5. `UIInterfaceOrientationPortraitUpsideDown` in the plist; `isIdleTimerDisabled` in the console.
6. iPad screenshots for App Store Connect.

Nothing here needs the DJ engine work. Items 3 and 4 make the *existing* iPhone console better on the way past.

**v1 — the console exists. This is the bulk of the work.**

7. **UIKit touch router + control frame registry** (§3.1). Everything else sits on it; build it first and build it with a diagnostic overlay.
8. Two-deck landscape layout at 13" and 11", with the reflow ladder (§1.3, §3.10). No `ScrollView`.
9. **Waveforms**: overview from the existing `WaveformService`; tiled detail renderer; mirrored beatgrid stack; phase meter; beat-in-bar and bar-in-phrase readouts (§3.3).
10. **One extrapolator** for the playhead, fed by the 20 Hz local tick *or* the 10 Hz remote anchor (§4.7). Build this early — it is what keeps the crash surface small.
11. Mixer: trim, EQ (−26…+6 travel, 200 pt sweep, double-tap kill), filter (low-pass half only until the high-pass band lands), line faders, crossfader with curve selector (§3.4).
12. **Master limiter at −1.0 dBTP** (§3.6). Moved earlier than the engine spec has it, because a human will slam both faders.
13. Tempo fader with range selector, 0.01 % quantisation, fine mode; key lock; key shift (§3.7). Button labelled **TEMPO**, not SYNC.
14. Hot cues (8/deck, persisted via a `CuePointStore`) and beat-based loops including 20-bar, with the out-of-phrase marker (§3.5).
15. Keyboard map with `.down`/`.up` phases (§1.5).
16. **Resistive value mapping + visual detents** (§3.9.1, §3.9.2) — the haptics replacement.
17. Local render on iPad, with `.localDJ` added to the coordinator (§5.4), AirPlay refusal, and thermal backoff.

Dependencies on the DJ engine spec: **none, strictly.** The console works against `MixEngine` as it stands. It gets materially better with the spec's v1 (`entrySeconds`, snapped bass swap, 200 Hz low shelf), and the 200 Hz shelf is a shared prerequisite for the EQ to behave the way §3.4 describes.

**v2 — it becomes musical over the network**

18. **High-pass band** on the existing filter node → real centre-detented filter knob (~40 lines, **S**). Cheapest high-value item after v0.
19. **Clock sync** (`clockPing`/`clockPong`, min-RTT filter) + `masterClock` + `djSchedule` + the lateness branch (§4.2–4.5).
20. One-shot `deckWaveform` blob (§3.3c) — makes the remote console visually equal to the local one.
21. **SYNC** — phase lock. Gated on **E1**.
22. Loop halve/double with sample-accurate re-arm (**M**, gated on E1).
23. `AVAudioUnitDelay` per deck → echo-out (**M**). Placement is load-bearing: after `filter`, before `mixer`, so the fader does not kill the tail.
24. Cue/monitor: 4-channel detection, split-cable mode, cue bus (§3.6).
25. Widget-vs-console socket contention fix (§5.2).

**v3 — stretch**

26. **Scratch** via `AVAudioSourceNode` (§2.3). **This is a deck-engine rewrite, not a feature.** Loops, scheduling, seek and `playheadPosition` all rebuild on it. Local-only forever. Size **L**, and it is the riskiest item in the document.
27. External display: waveforms and library on the monitor, controls on the glass. Needs `UIApplicationSceneManifest` + `UIApplicationSupportsMultipleScenes` (absent today, V20).
28. Apple Pencil Pro automation-drawing mode (§3.9.4) — the only real haptics on the platform.
29. iPad-as-server / iPhone satellite (§5.3).

### 6.2 Cost, honestly

Line estimates for v1, new code only:

| Piece | Lines |
|---|---|
| Touch router + frame registry + diagnostic overlay | 300 |
| Console root, layout, reflow ladder | 250 |
| Waveform renderer + tile cache + beatgrid + phase meter | 500 |
| Playhead extrapolator (serves both cases) | 150 |
| Jog wheel (pitch bend, brake, search, palm detect) | 250 |
| Mixer controls (EQ, filter, faders, crossfader, meters) | 400 |
| Tempo / key / key-lock | 180 |
| Pads, cue store, loop panel | 350 |
| Keyboard + pointer | 120 |
| Coordinator `.localDJ` + AirPlay + thermal | 150 |
| Self-tests | 350 |
| **Total** | **≈ 3,000** |

**Two to three weeks of focused work for v1**, not days. v2's networking is another ~600 lines and about a week, most of it in the lateness branch and its tests. v3's scratch is a separate project.

Project-level costs beyond code: one build-setting change per target, iPad screenshots, and **a lot of new files through `project.pbxproj`** — which CLAUDE.md identifies as a serialisation bottleneck. Register them from the main session, group-relative paths, never regenerate from `project.yml`.

### 6.3 Risks to the documented invariants

**(a) `AVPlayer` / `AVAudioEngine` — the highest-risk item, and it is worse on iPad than on tvOS.**

On tvOS there is one playback authority. On iPad there are two: `PhonePlaybackCoordinator` (routing local-or-TV) and now a local `AVAudioEngine`. The failure mode is not "both render on the same device" — `takeOverFromAVPlayer` handles that — it is **the coordinator's `NowPlayingSnapshot` describing an `AVPlayer` that has been torn down** while two decks run. Mitigations: the `.localDJ` case (§5.4); an assertion in the coordinator that `.localDJ` implies `!PlayerService.shared.hasPlayerItem`; and a self-test that enters and leaves DJ mode ten times and asserts the snapshot agrees with the engine each time.

Second-order: entering local DJ mode while the coordinator is targeting the **TV** is legitimate (different devices) but produces two independent playing streams. Decide the policy explicitly — I would **stop the TV** on entering local DJ mode, because two rooms playing different things from one app is never what you meant.

**(b) The `playheadPosition` Obj-C exception — the one that already crashed DJ mode on open.**

`playerTime(forNodeTime:)` raises `com.apple.coreaudio.avfaudio` "required condition is false" — an Objective-C exception, not a Swift trap, so it is uncatchable and fatal. The guard is `nodeTime.isSampleTimeValid || nodeTime.isHostTimeValid` **and** `playerTime.sampleRate > 0`, and the window it hits is *just after a player node starts*.

The console makes this worse in exactly the wrong way: it wants the playhead at 120 Hz instead of 20 Hz (6× the entries), and it wants it **immediately after loading a track into a deck**, which is precisely the danger window.

Mitigations, in order of importance:

1. **Do not call it at 120 Hz.** Sample at the existing 20 Hz tick and extrapolate (§4.7). This removes the risk almost entirely and is required for the remote case anyway, so it is not extra work.
2. **One `private func renderClock(for:) -> AVAudioTime?` helper** with the guard written once, verbatim from the existing implementation. Every new `lastRenderTime` access goes through it. Never a second copy of the guard.
3. **Fail closed**: `nil` means "no anchor yet", the extrapolator holds its last value, the waveform freezes for a frame. Never crash, never guess.
4. **Self-test**: attempt a playhead read 5 ms after `engine.start()` and assert it returns `nil` rather than throwing.

**(c) `@Published` re-entrancy and redraw storms.** `MixEngine.decks` is `@Published` and ticks at 20 Hz. **Do not bind the console tree to `@ObservedObject var mixEngine`** — every tick would invalidate the whole console, including 120 Hz waveform lanes. Take a non-observable snapshot into the router and drive redraws from `TimelineView(.animation)`. The engine spec makes the matching point for the planner: never invoke it from inside `mixEngineDidTick`.

**(d) Design-token collision.** `Spacing.md` is **16** in `DesignSystem.swift` (tvOS-only) and **14** in `AppClipDesign.swift` (iOS), with `CornerRadius` vs `Radius` and a different `scAccent` (V8). **Rule: all console code lives in `SoundingTV-iOS/Sources/`.** If any of it drifts into `SoundingTV.swiftpm/Sources/` it will silently resolve to different values per target, and a layout tuned to the point on iPad will be wrong on tvOS with no compile error.

**(e) The master limiter is a graph change.** `mainMixerNode` is deliberately never explicitly connected to `outputNode` so it tracks the hardware format across route changes. Inserting the limiter creates an explicit connection that **must be rebuilt in `handleConfigurationChange`** or the engine dies on the first route change — i.e. the first time someone plugs in headphones. This is the one v1 item with real regression risk; it gets its own test.

**(f) A pre-existing inconsistency worth knowing about, not fixing here.** `PhoneWaveformScrubber` in `TransportBarView.swift` has a **parallel** waveform implementation with its own `WaveformDocument` and a pure-peak resample, and a comment claiming it is "identical algorithm to tvOS's `Waveform.resampled(to:)`" — which stopped being true when that gained the 0.7 peak / 0.3 mean blend. `WaveformService.swift` is already in the iOS target (V6), so the duplicate can just be deleted. Out of scope for this plan; flagged because the console will make the visual divergence obvious.

---

## 7. The experiments that resolve the uncertainty

Each of these is cheap and each one settles something the plan currently assumes. `E1`–`E8` are the DJ engine spec's; `E-N*` and `E-T*` are new here.

| # | Question | Experiment | Blocks |
|---|---|---|---|
| **E-N1** | What is the real one-way delay distribution on this LAN, iPad ↔ Apple TV? | Ship `clockPing`/`clockPong` first, alone. Log min / p50 / p95 / p99 RTT and the offset residual for a week, including with the iPad screen-locked and on battery. | **The `lead` constant (§4.4), which the entire remote design hangs on.** Everything in I3 is recalled, not measured. Do this before writing `djSchedule`. |
| **E-N2** | How much does `noDelay` actually buy? | Same rig, toggle `noDelay`, compare p95 on a 10 Hz small-frame stream. | Nothing — do it anyway, because it is two lines and the answer is a number you can put in a commit message. |
| **E-T1** | Does `SpatialEventGesture` deliver all concurrent touches cleanly inside this app's `TabView`→`NavigationStack` hierarchy, and does it coexist with system edge gestures? | A diagnostic view rendering one dot per `SpatialEventCollection.Event.id`, logging `collection.count`. Put six fingers down. Repeat inside a `fullScreenCover`, in Split View, and near each screen edge. | Whether the Pencil/pointer path can be SwiftUI (§3.1). The UIKit host is being built regardless, for `majorRadius` and coalesced touches. |
| **E-T2** | Does a tiled pre-rendered `CGImage` waveform actually beat a re-stroked `Canvas` at 120 Hz on an 11" iPad Air? | Instruments, both implementations, two lanes scrolling, measure frame time and thermal state over 10 minutes. | The renderer choice (§3.3). My prior is strongly that tiles win; measure it rather than asserting it. |
| **E-T3** | What `majorRadius` threshold actually separates a fingertip from a resting palm? | Log `majorRadius` for 100 deliberate fingertip touches and 100 palm rests on the platter. Pick the separating value. | The brake gesture (§3.1). The 18 pt figure in this document is a guess. |
| **E-T4** | Confirm iPad point geometry per device. | One `GeometryReader` printing `size` in each booted simulator. | I1, and therefore every number in §3.10. Ten minutes. |
| **E1** *(from the engine spec)* | Is `AVAudioPlayerNode.play(at:)` sample-accurate relative to another player node in the same engine? | Offline render via `enableManualRenderingMode(.offline:)`, two impulse trains at 128 BPM, cue B against A, cross-correlate, assert offset < 1 ms. | **SYNC, quantised hot cues, loop halve/double** — everything in v2 that claims phase accuracy. |
| **E-A1** | Does the master limiter survive a route change? | Enter DJ mode, plug/unplug headphones ten times, assert the engine is still running and the limiter is still connected. | §6.3(e). |
| **E-A2** | Does the playhead read return `nil` rather than throwing, 5 ms after `engine.start()`? | Direct assertion in the existing `SOUNDING_TV_MIXTEST=1` self-test rig. | §6.3(b). This is the crash that already happened once. |
| **E-A3** | Is split-cable cue (master→L, cue→R) achievable on the 2-channel output without breaking the `.longFormAudio` policy? | Build the master mix stage, render offline, verify channel isolation; then verify a real AirPlay route still works with cue off. | §3.6, §2.2. |

The rig already exists for the offline ones: `#if DEBUG`, `XSelfTest.run()`, registered in `SoundingTVApp.swift`, run under `SOUNDING_TV_MIXTEST=1`, with `PhantomPlanSelfTest` and `MixLoopSelfTest` as the pattern. `ffmpeg`-generated tones served from a local HTTP server mimicking SoundCloud's JSON second hop, pointed at with `SOUNDING_TV_STREAM_HOST`, is documented in CLAUDE.md as the thing that reproduced the DJ crash locally. Same rig, extended.

Add an iPad screenshot hook alongside `SOUNDING_TV_DJ` — `simctl` cannot synthesise a tap, so the console is otherwise unverifiable from the command line. `SOUNDING_TV_CONSOLE=1` launching straight into it, DEBUG-only, matching the existing convention.

---

## 8. What I could not verify, stated plainly

- **The LAN latency numbers (I3).** Recalled, not measured on this network, and the whole schedule-ahead design depends on them. E-N1 exists precisely because I do not want this document's `lead` constant taken as fact.
- **iPad point geometry (I1).** Derived from published pixel dimensions ÷ 2. The simulator `profile.plist` files carry `modelIdentifier` and family IDs but **no screen dimensions**, so there was no local source. Every number in §3.10 inherits this. E-T4 settles it in ten minutes.
- **Whether `AVAudioPlayerNode.play(at:)` is sample-accurate against another player node.** The engine spec's E1, still open. SYNC, quantised cues and loop halving all depend on it and none of them should be scheduled until it passes.
- **The `majorRadius` palm threshold.** 18 pt is a plausible starting number and nothing more.
- **Whether `AVAudioUnitTimePitch` at ±6 % with coupled pitch sounds acceptable** versus needing `AVAudioUnitVarispeed` (engine spec E5). Affects turntable mode.
- **Whether `LinkKit` supports tvOS.** Could not check; it is why §4.2 recommends reimplementing rather than adopting. If it does support tvOS, adopting Link would be a legitimate alternative and would also make the app interoperate with every other Link app in the room, which is a real feature this plan does not deliver.
- **Whether split-cable cue conflicts with anything in `AVAudioSession` that I did not read.** E-A3.
- **Key-lock artefact thresholds.** Sources give 5 %, 8 % and 10–20 %; none from a controlled study. Do not put a number in a code comment as though it were fact.
- **Web search budget was exhausted for this session**, so the Apple documentation claims (V1, V3) were verified by fetching the `developer.apple.com/tutorials/data/…json` endpoints directly rather than through search. Both returned real prose and both are quoted above. Everything else marked **verified** came from the installed `iPhoneOS27.0.sdk` headers and `.swiftinterface` files, or from the repository itself.

---

## 9. The short version

**The owner is right that SwiftUI handles most of the iPad adaptation.** Three build-setting changes, one `.tabViewStyle`, one plist key, and the app is universal. Do not make a second target.

**The owner is wrong about haptics, and it is not close.** iPad has none, Apple's docs name it explicitly, and the `sensoryFeedback` calls already in the codebase are silent no-ops there. The replacement is **resistive value mapping** — near a detent the value moves at a quarter of finger speed, so proprioception does the work touch cannot — plus frame-accurate visual detents, plus an audible click layer which is *safe and excellent* in exactly the configuration where you need it most: when the music is rendering on the TV and the click renders on the iPad.

**The owner is right that networked realtime is possible, via scheduling.** NTP-style offset estimation with a min-RTT filter, synchronised against `mach_absolute_time` because that is what `AVAudioTime.hostTime` uses; a shared beat timeline; commands expressed as *"at beat N, ramp from x to y over M beats"*; continuous gestures as a 10 Hz stream of 100 ms ramp segments starting one `lead` in the future. Beat quantisation dominates the lead entirely at dance tempos, which is why the whole thing works. **Remote means quantised. If you want unquantised, render locally** — and the iPad can, today, with no build changes, because `MixEngine` and `PlayerService` are already in its target.

**Scratching cannot be remoted and cannot currently be done at all** — `AVAudioPlayerNode` will not play backwards, and fixing that means rewriting the deck source on `AVAudioSourceNode`. Say so up front, remove the control in remote mode rather than greying it out, and note that CDJ DJs use the platter for search and pitch bend far more than for scratching.

**The two cheapest wins are not in the console at all.** `noDelay = true` on both ends of the control channel — two lines, and Nagle can currently add more delay than the entire lead budget. And deleting the hardcoded `bpm: nil` in `deckStatePayload` — five lines, and it unblocks every beat-based loop length, the deck headers, and the 20-bar loop the owner asked for.

**The centrepiece is not the jog wheels.** It is the mirrored beatgrid stack with a non-linear phase meter, because at the default zoom a 10 ms phase error is three quarters of a point and no waveform will ever show it to you. Build that first, get the extrapolator right so it is smooth whether the audio is on the iPad or the TV, and the rest is controls.

