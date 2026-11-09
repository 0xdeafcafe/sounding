# watchOS for Sounding — plan, with an honest verdict

> ## SUPERSEDED — a watchOS target now exists
>
> This document recommended against building one. That recommendation was
> **overruled deliberately**, and a `SoundingTV watchOS` target was created
> (`tools/add-watchos-target.rb`). Everything below is kept because its
> constraint research is still accurate and still binding — but read these
> corrections first.
>
> **What changed since this was written:**
>
> - The phone app grew from a thin remote into a full-feature client, which
>   was the premise this document's cost/benefit rested on.
> - **A watchOS 27.0 simulator runtime is now installed.** This document says
>   there is none and to budget a multi-GB download. Stale.
> - `.glassEffect` / `GlassEffectContainer` (Liquid Glass) **are** available on
>   watchOS 27, so the watch shares the app's design language natively.
> - `MusicUnderstanding`, `WatchConnectivity`, `ShazamKit`, `CloudKit`,
>   `AVFoundation`, `SQLite3` and `Accelerate` all compile for watchOS 27.
>
> **What did NOT change — these still bind the design:**
>
> - **TN3135 still blocks Bonjour and raw TCP on watchOS.** The watch can
>   never reach the Apple TV directly. Every TV verb relays through the phone
>   via `PhonePlaybackCoordinator`. This is why the watch app is a remote.
> - **`WebKit` is absent**, so the watch cannot run the OAuth web view. It
>   receives credentials from the paired iPhone over WatchConnectivity
>   (`WatchLinkClient.requestSession()` → `PhoneWatchLinkServer`).
> - **`AudioToolbox` is absent**, so `MixEngine` cannot compile for watchOS.
>   Auto DJ is computed on the phone; the watch renders `WatchDJState`.
> - **`ActivityKit` and `CoreHaptics` are absent.**
> - `UIApplication` and `UIGraphicsImageRenderer` are unavailable, which is
>   why `PlayerService`, `LikesSyncEngine` and `Tokens.swift` are excluded.
>
> The §1 argument below — that the system already covers much of the wrist via
> Live Activities, Now Playing and the Remote app — was never refuted and is
> still worth acting on independently of the target.

**Status:** research + recommendation. **No repo file was edited.** No target was created.
**Question asked:** *"plan watchos … idk what we should do? airhorn button> lol"*

---

## Top-line recommendation

**Don't build a watchOS target.**

Not because a watch is a bad idea, but because **you already ship the watch app** — it just isn't a watch app. The iOS Live Activity in `SoundingTV-Widget/` renders on the Apple Watch Smart Stack today, with its existing transport buttons, because iOS Live Activities mirror to watchOS. Between that, the system Now Playing app, and the system Remote app (which already drives an Apple TV 4K over Bluetooth from the wrist), the wrist is roughly 85% covered for zero new targets.

**Do this instead — about half a day, entirely inside targets that already exist:**

| # | Change | Where | Why |
|---|---|---|---|
| 1 | Start the Live Activity for **local phone playback**, not only TV playback | `PhonePlaybackCoordinator` / `PlayerService` | It's currently started *only* from `RemoteQueueClient`. Play on the phone and you get no Lock Screen, no Dynamic Island, and no watch. This one fix lights up all three. |
| 2 | `supplementalActivityFamilies([.small, .medium])` + a compact `.small` layout | `NowPlayingLiveActivityWidget.swift` | This is the *actual* watch UI. `ActivityFamily.small` is the documented watchOS Smart Stack rendering. |
| 3 | Add a `ControlWidgetButton` to `SoundingWidgetBundle` | `SoundingTV-Widget/` | On watchOS 26, **iPhone Control widgets appear on the watch automatically with no watch app** — Control Center, Smart Stack, and the Ultra's Action button. The bundle currently has exactly one member and no Control widget at all. **[REPO]** |
| 4 | Put the mix countdown on the wire (`DJStatePayload` + `PhantomDJEngine.Plan.mixPointSeconds`/`.reasoning`) | `TokenTransferProtocol.swift` (both live copies) | The DJ cue display is the one genuinely good watch idea — but the data doesn't exist on the **phone** yet either. Build it where you can see whether it's useful. |

Then stop and see whether you ever look at it. If in three months you're glancing at your wrist mid-set and wishing it said more, revisit — with a much better idea of what the app should be than either of us has now.

**The airhorn is not dead.** It's just not a watchOS feature — it's a `MixEngine` feature (§5). Build the quantised one-shot sampler on the phone/TV; a wrist trigger is a 20-line addition afterwards, and by then you'll know if it's fun.

### The two findings that decide this

1. **watchOS forbids the app's entire networking model.** Bonjour, `NWBrowser`, `NWListener` and raw TCP are **blocked on watchOS** outside three narrow exceptions, none of which fits — `NWConnection` sits in `.waiting` with `ENETDOWN`. **[DOC — TN3135]** So a watch app can *never* talk to the Apple TV directly. "Control the TV from my wrist while my phone is in another room" is not buildable at any price. **And the code compiles fine, and works in the simulator** — this would have been discovered late and expensively. §8.
2. **You already have the wrist surface.** WWDC24: "With iOS 18 and watchOS 11, your iOS Live Activity will appear in the Smart Stack on Apple Watch **automatically**." **[DOC]** It's built, it has working buttons, and it costs nothing.

### Before writing any code, verify these four on a real watch (an hour, no build)

| Check | Expected |
|---|---|
| Does the existing Live Activity appear in the watch Smart Stack when the **TV** is playing? | Yes **[DOC]** |
| Does the system Now Playing app control phone playback correctly from the existing `MPRemoteCommandCenter` wiring? | Yes **[DOC]** |
| Does the watch's **Remote** app control the Apple TV running Sounding? | Yes for navigation/transport **[DOC]** |
| Does the Remote/Now Playing path surface *Sounding's own* tvOS `MPNowPlayingInfoCenter` metadata (title/artist/artwork) on the wrist? | **Genuinely unknown.** No Apple statement, no credible first-hand report for third-party tvOS apps. **[UNVERIFIED]** — this is the highest-value hour in the whole plan. If yes, TV now-playing on the wrist is already done and you can close this document. |

---

## How to read the evidence in this document

| Tag | Means |
|---|---|
| **[SDK]** | Verified by compiling against the installed **watchOS 27.0 SDK** on this machine (`swiftc -typecheck -target arm64_32-apple-watchos27.0`). Not recalled — run. |
| **[DOC]** | Verified from Apple's documentation JSON API (`developer.apple.com/tutorials/data/documentation/…`), quoted. |
| **[REPO]** | Verified by reading this repository. Absolute paths given. |
| **[INFER]** | My reasoning from the above. Flagged where load-bearing. |
| **[UNVERIFIED]** | I could not confirm it. An experiment is named. |

Environment notes, since they differ from `CLAUDE.md`:

- Xcode **27.0** beta (`27A5228h`) is selected; `CLAUDE.md` says 26.x. **[SDK]**
- `IPHONEOS_DEPLOYMENT_TARGET` and `TVOS_DEPLOYMENT_TARGET` are both **27.0** in `project.pbxproj`; `CLAUDE.md` says 26.0. Stale doc or a concurrent bump. **[REPO]**
- watchOS **SDK** 27.0 is installed. There is **no watchOS simulator runtime** installed — the five present runtimes (iOS 18.2/26.3/27.0, tvOS 26.2/27.0) total 30.3 GB, so budget a comparable multi-GB `xcodebuild -downloadPlatform watchOS` before any watch target can even be run. **[SDK]**
- The working tree is heavily modified by concurrent agents (`git status` shows ~30 modified/deleted files including `project.pbxproj`-adjacent assets). Noted, not touched.

---

## 1. The most important question first: does the system already do this?

**Yes, and more of it than you'd guess.**

### 1a. The system Now Playing app on Apple Watch

> "Tap the play, pause, backward, and forward buttons"; "Turn the Digital Crown" to adjust volume; users can "switch to or add additional AirPlay devices"; "If more than one device is playing media — for example, a HomePod or iPad — the device's icon appears in the top-right corner"; "Now Playing launches automatically when you're near a HomePod that's playing audio." **[DOC]** — Apple Watch User Guide, *Now Playing*

`PlayerService` already registers `playCommand`, `pauseCommand`, `togglePlayPauseCommand`, `nextTrackCommand`, `previousTrackCommand` and `changePlaybackPositionCommand` on `MPRemoteCommandCenter.shared()`, and populates `MPNowPlayingInfoCenter` with title, artist, artwork and duration (`/Users/afr/Source/github.com/0xdeafcafe/sounding-tv/SoundingTV.swiftpm/Sources/Services/PlayerService.swift`, ~lines 513–608). **[REPO]**

So when the **phone** is playing, the watch already shows artwork, title, artist, a scrubber, transport, and crown volume — with no code from us. A custom watch app would reimplement exactly this, worse, and with an extra hop.

### 1b. The system Remote app already controls your Apple TV

> "You can use Apple Watch as a remote control for an Apple TV 4K through Bluetooth." Swipe to navigate, tap to select, pause/resume, Digital Crown volume, mute, captions, back, home, power, and press-and-hold the crown for Siri. **[DOC]** — Apple Watch User Guide, *Remote*

This is the answer to "watch → TV control". You don't need to build it. The tvOS app is an ordinary `TabView` + `PlayerView` app driven by focus; the watch Remote drives it exactly as the Siri Remote does, over **Bluetooth directly to the Apple TV** — which is *better* than anything we could build, because it doesn't route through the phone at all.

### 1c. Your Live Activity already renders on the watch

This is the finding that decides the whole plan.

> "With iOS 18 and watchOS 11, **your iOS Live Activity will appear in the Smart Stack on Apple Watch automatically.** The compact leading and trailing views from your Dynamic Island are automatically shown in the Smart Stack. **Updates to your Live Activity on iOS are automatically synchronized to Apple Watch.**" **[DOC]** — WWDC24 session 10068, *Bring your Live Activity to Apple Watch*

Corroborated by the API reference: "A Live Activity initiated on one device can be sent to a remote device that renders the Live Activity at a different family size… **If you want to opt in to customize the rendering** for a Live Activity for the watchOS Smart Stack, use the small family modifier." **[DOC]** — `WidgetKit/ActivityFamily`, iOS 18+. And ActivityKit's own abstract: "Share live updates from your app as Live Activities on iPhone, iPad, **Apple Watch**, and the Mac… On Apple Watch, it appears in the Smart Stack." **[DOC]**

Read that carefully: the mirroring is the **default and automatic**. `supplementalActivityFamilies(_:)` is how you *customise* the watch rendering, not how you enable it. Without it, the watch renders your **iOS Lock Screen view**, squeezed.

You already have:
- `NowPlayingLiveActivityWidget` with a full layout **[REPO]**
- `NSSupportsLiveActivities = true` in `SoundingTV-iOS/Info.plist` **[REPO]**
- Interactive `AppIntent` buttons — `PlayTransportIntent`, `PauseTransportIntent`, `NextTrackIntent`, `PreviousTrackIntent`, `MixNowIntent` — each of which independently rediscovers the TV over mDNS and sends one signed command via `WidgetControlSender` **[REPO]**

That is a watch app. It has transport, DJ "Mix Now", artwork, and a progress bar, and it works from a process that doesn't need the main app running. It cost you nothing extra.

**The one real gap:** `NowPlayingLiveActivity.start(...)` is called from exactly one place — `RemoteQueueClient.handle(_:)` on a `.playbackState` frame from the TV (`SoundingTV-iOS/Sources/RemoteQueueClient.swift:372`). **[REPO]** Nothing starts it for local phone playback. So the phone — which `CLAUDE.md` is emphatic is now **standalone-first** — has no Lock Screen presence, no Dynamic Island, and no watch presence when it plays on its own. That's a bug-shaped hole in the existing feature, and closing it is worth more than any watch target.

---

## 2. Candidate 1 — Remote control / Now Playing

**What it'd be.** A watch app showing what's playing with transport, volume, and up-next, working whether the audio is on the phone or the TV.

**What's technically possible.** The *phone* half, all of it: `MPNowPlayingInfoCenter` (watchOS 5+) **[DOC]**, `MPRemoteCommandCenter`, `WCSession` and `WidgetKit` all work on watchOS.

**The TV half is not possible.** Not "slow" — blocked. watchOS forbids Bonjour and raw TCP (§8), so the watch can never reach `RemoteQueueServer` directly; every TV verb has to be relayed by a phone that must be present, awake, and willing to re-establish a socket it drops on backgrounding. That removes the most attractive half of this candidate before you start.

**What it'd cost.** See §8 — a new target, a new App ID, a new SwiftUI design language, and a third copy of the now-playing state machine. `PhonePlaybackCoordinator` exists specifically because reconciling *two* sources of "what's playing" was already error-prone enough to need a single arbiter (`CLAUDE.md`: "Views must never re-derive 'am I on the TV' themselves"). A watch makes it three, across a device boundary, with its own reachability states.

**What you'd gain over the system.** Honestly: the app's own vocabulary. The queue. `isDJEngineLive`. "Which device is playing." Output switching (`PlaybackOutput.thisDevice` / `.appleTV`) — the system's Now Playing routes AirPlay, but your TV handoff is a different mechanism it can't see.

**What you'd lose.** The system version is always there, is on the face's Smart Stack automatically, survives your app crashing, and gets better every September for free.

> ### Verdict: **Don't build.** The system gives you 85%, and the remaining 15% is better delivered as a richer Live Activity than as a target.

---

## 3. Candidate 2 — the wrist as a DJ cue display

**The strongest idea on the list, and the one with a prerequisite problem.**

**What it'd be.** Glanceable at the decks: what's playing, time remaining, what's next, and — when the DJ engine is live — a countdown to the next transition and a one-line reason ("breakdown at 4:12, filter close, keys compatible").

**Why it's the right shape.** It is genuinely the thing a wrist is for: read-only, time-critical, hands-busy. It's not a control surface competing with a controller; it's a clock that knows about music. That's a real idea.

**The problem: the data isn't there.**

- `PhantomDJEngine.Plan` has exactly what you'd want — `mixPointSeconds`, `transitionSeconds`, `outroShape`, `accent`, and a human-readable `reasoning: String`. **[REPO]** (`SoundingTV.swiftpm/Sources/Services/PhantomDJEngine.swift:86–96`)
- **None of it is on the wire.** `DJStatePayload` carries `isEnabled`, `isEngineLive`, `isAutoMixEnabled`, `crossfade`, and two `DJDeckStatePayload`s. There is no mix point, no countdown, no reasoning. **[REPO]** (`TokenTransferProtocol.swift:1150–1259`)
- So the **phone doesn't have this either.** `DJControlView.swift` renders decks, EQ, jog, crossfader, loop and a BPM readout — no transition countdown anywhere. **[REPO]**
- And `MixEngine` reports `bpm: nil` for deck state: *"nothing in this file knows BPM"*. **[REPO]** (`MixEngine.swift:1173–1207`) BPM only reaches the payload via `DJTransitionService`, and for HLS-only tracks it's `synthesizeAnalysis` — a hash of `track.id`, flagged `isEstimated: true`. **[REPO]**, per `dj-engine-spec.md` §0.3.

**[INFER]** Therefore the cheapest honest version of this feature is *not* a watch app. It's: add `mixPointSeconds` + `reasoning` to `DJStatePayload` (a signed payload — both live copies of `TokenTransferProtocol.swift` must stay byte-identical, per `CLAUDE.md`), render a countdown on the phone's DJ tab, and let it ride to the wrist inside the Live Activity you already have. If the countdown turns out to be the thing you actually look at, *that's* when a dedicated watch face for it earns its keep.

**One uncomfortable grounding note.** The brief frames this around "when you're at the decks". The evidence in `~/Music/` is thinner than that framing suggests, and it changes the value calculation, so I'm stating it plainly:

- Serato: **215 library entries, of which the sampled ones are largely Serato's own demo tracks and scratch samples** (`Serato Demo Tracks.crate`, `Serato Scratch Beats.crate`, `Serato Scratch Samples.crate`, `Serato Stems`, `iCloud.crate` — 5 crates total).
- `~/Music/_Serato_/History/Sessions/`: **four sessions, the most recent dated November 2024.**
- `~/Music/rekordbox/` contains empty `Sampler` and `Recording` folders (Dec 2024). `~/Music/Ableton/` has a User Library from Jan 2024 and **no `.als` project newer than 2025-01-01**.
- `~/Music/SoundCloud/` has **321 downloaded tracks**, newest March 2025. Nothing anywhere under `~/Music/` is newer than June 2025.
- BPM distribution of the analysed tracks: median **96.7**, p25 82, p75 122, with a strong cluster at 130 (41 tracks) and another at 80–95. **[REPO/local]**

That reads as *a serious listener and collector with DJ software installed and lightly used* rather than someone regularly behind decks. **[INFER]** — and it may simply be wrong: hardware-only DJing (CDJs, a standalone controller, USB sticks) leaves no trace on this Mac, and this may not be the machine you play from. But if "hands busy at the decks" happens a few times a year, a watch target maintained forever is a poor trade, and the phone-side countdown is a much better first move.

> ### Verdict: **Good idea, wrong platform, wrong order.** Build the countdown on the wire and on the phone. It reaches the wrist for free via the Live Activity. Revisit a dedicated watch surface only if you find yourself using it.

---

## 4. Candidate 3 — haptic phrase counting

**Dead. Not "risky" — foreclosed by the API, before you get anywhere near a jitter measurement.**

The brief correctly identified this as make-or-break and asked for an experiment. The experiment isn't needed, because three independent facts each kill it on their own.

### 4a. There is no CoreHaptics on watchOS

```
$ echo 'import CoreHaptics' > A.swift
$ swiftc -typecheck -sdk <watchOS 27.0 SDK> -target arm64_32-apple-watchos27.0 A.swift
A.swift:1:8: error: no such module 'CoreHaptics'
```
**[SDK]** — and independently, `CHHapticEngine`'s documented platforms are **iOS, iPadOS, Mac Catalyst, macOS, tvOS 14.0, visionOS. watchOS is not listed.** **[DOC]**

No `CHHapticPattern`. No transient/continuous events with `relativeTime`. No `CHHapticPatternPlayer.start(atTime:)`. No `CHHapticEngine.currentTime` timebase to align to audio. No AHAP files, no parameter curves, no intensity or sharpness control. On iOS you hand the system a *timed pattern* and it renders it on a real clock; **on watchOS that entire mechanism does not exist.** There is no fallback either — `AudioToolbox` (and thus `AudioServicesPlaySystemSound`) is also absent from watchOS. **[SDK]**

Note that tvOS *is* on CoreHaptics' platform list (game-controller haptics, since 14.0), so the omission of watchOS is deliberate metadata, not an iOS-centric oversight. **[DOC]**

### 4b. The only haptic API cannot be scheduled

```objc
- (void)playHaptic:(WKHapticType)type WK_AVAILABLE_WATCHOS_ONLY(2.0);
```
**[SDK]** — `WatchKit.framework/Headers/WKInterfaceDevice.h:104`

No time parameter. No completion handler. No queue. No intensity. The usable `WKHapticType` set is exactly **nine** constants — `notification, directionUp, directionDown, success, failure, retry, start, stop, click` — because the navigation types are header-gated to "an active navigation session" and the underwater types to "an active underwater depth session". **[SDK]** These are notification-grade patterns with their own envelopes, not zero-length impulses.

(SwiftUI's `.sensoryFeedback(_:trigger:)` exists on watchOS 10+ **[DOC]**, but it's a thin wrapper over the same nine constants, fired off an `Equatable` trigger change — it inserts a view-update cycle between your clock and the tap, so it's strictly worse for this.)

The *only* possible implementation is "poke it from a Swift timer", and Apple explicitly warns against exactly that:

> "**Do not call this method multiple times in quick succession.** If the haptic engine is already engaged when you call this method, the system stops the current feedback and imposes a **minimum delay of 100 milliseconds** before engaging the engine to generate the new feedback." **[DOC]** — `WKInterfaceDevice.play(_:)`

**Being fair about the 100 ms — it is *not* the binding constraint.** At 130 BPM a beat is 461.5 ms, roughly 5× the floor, so a short `.click` almost certainly isn't still engaged when the next fires. Where it bites is everything more interesting — double-time, eighth-note counts, a sub-beat "3-2-1" count-in — all capped at 10 Hz with a documented 100 ms displacement on overrun. I'm flagging this because it's the number that *looks* fatal and isn't; the fatal ones are below.

The real problem is that there is **no documented timing guarantee of any kind** for the tap you do get. You'd be building a musical instrument on unspecified behaviour. For scale: at 130 BPM a sixteenth note is 115 ms, and musicians detect asynchrony well below that. **[INFER, general knowledge]**

**And the field reports are not encouraging.** There is no published latency or jitter measurement for watchOS haptics anywhere — not a blog benchmark, not a forum measurement, not a WWDC statement. Two HCI papers use Apple Watch haptics for explicitly *rhythmic* feedback and report zero timing figures. The one substantive first-hand account is a beta tester of a watchOS metronome on an Ultra 2 / watchOS 11.6.1: **[COMMUNITY-REPORTED]**

> "The timing is not rock solid. When flicking around in the interface, it has to get caught up to deal with the interrupts… **If I wave my hand/arm for whatever reason, the timing goes off.** 5/4 is not even generically steady, even if I hold my hand still… The only time it's steady is if I don't move my hand at all, and the watch face is up."

Jitter dominated by system interrupts and *wrist motion* is exactly the wrong failure mode for a DJ, whose wrist is by definition moving. And separately, multiple user reviews of shipping haptic metronomes say the tap is simply **too weak to feel on the wrist** ("too feeble to feel unless you have your fingers on it"). **[COMMUNITY-REPORTED]**

**One more thing that undoes the premise.** The HIG: "on Apple Watch, the Taptic Engine generates haptics for a number of built-in feedback patterns, **which watchOS combines with an audible tone**." **[DOC]** So a "silent metronome on the wrist" is only silent if the user has Silent Mode on — silence is a user setting, not a property of the API.

### 4c. Haptics don't fire unless the app is foreground-active

> "This method has no effect when called while your shared [`WKExtension`] object's [`applicationState`] property is either [background] or [inactive]. By default, you cannot play haptic feedback in the background. **The only exception are apps with an active workout session.**" **[DOC]** — `WKInterfaceDevice.play(_:)`

A metronome you have to hold your wrist up and stare at is not a metronome.

**In fairness, Apple's docs are in tension here** and I couldn't resolve it from documentation alone. The extended-runtime-session guide says sessions "let the app continue to communicate with a Bluetooth device, process data, **or play sounds or haptics, even after the watch's screen turns off**" **[DOC]** — which contradicts `play(_:)`'s "the only exception are apps with an active workout session". The `play(_:)` page predates watchOS 6 and may be stale. **[UNVERIFIED]** *Experiment that would settle it:* an extended-runtime session of each type, firing `.click` on a timer, wrist lowered. Needs hardware.

**But the conflict doesn't matter, because both escape hatches are closed for other reasons:**

- **`WKExtendedRuntimeSession`** supports exactly four types, with hard caps: *self care* (frontmost, 10 min), *mindfulness* (frontmost, 1 hr), *physical therapy* (background, 1 hr), *smart alarm* (background, 30 min). **[DOC]** Apple: "Select a session type based on the app's intended use — **not based on the features that the session provides**." None of them is "DJ metronome"; declaring `physical-therapy` to get a background metronome is precisely what that sentence forbids, and it's an App Review conversation you don't want on an unofficial SoundCloud client. The alarm variant is worse still: `notifyUser(hapticType:repeatHandler:)` — the *only* API on watchOS where the system schedules a repeating haptic, interval 0–60 s, so 0.5 s would technically be 120 BPM — is alarm-only, requires `start(at:)`, caps at 30 minutes, and "If the app is not active, playing the haptic **displays a system alarm alert to the user**", with "If you fail to play a haptic during the session, the system displays a warning and offers to disable future sessions." **[DOC]** That's an alarm clock, deliberately.
- **`HKWorkoutSession`** is the documented background-haptics path, and is why every Apple Watch metronome you've seen asks to start a workout. Besides inflating your Move/Exercise rings and requiring HealthKit authorization to play a click track, Apple documents a direct conflict that kills it: **"Do not call this method while gathering heart rate data using HealthKit. When you engage the haptic engine, HealthKit stops gathering heart rate data until after the haptic engine finishes."** **[DOC]** — `WKInterfaceDevice.play(_:)`. Firing twice a second would suppress heart-rate collection for the entire session — i.e. you'd break the workout in order to borrow its background privileges.

### 4d. And it's moot anyway: there is no beat grid

Even with perfect haptics you'd have nothing to tap to. `MixEngine` explicitly reports `bpm: nil`. **[REPO]** A real beat/bar/phrase grid would come from `MusicUnderstanding`'s `RhythmResult.beats: [CMTime]` / `bars: [CMTime]` and `StructureResult.phrases` — which is a **design proposal in `dj-engine-spec.md`, not code**. That spec's own header: *"Status: design only, no code written."* **[REPO]** And the spec notes the engine can't even start a deck at a chosen sample instant today (`scheduleSegment(..., at: nil, ...)` everywhere).

Add the clock-sync problem — `mach_absolute_time` is per-device, so the watch would have to estimate its offset from the phone's audio clock over `WCSession` round trips whose jitter is undocumented **[UNVERIFIED]** — and you have four independent blockers stacked.

### 4e. A note on the more optimistic reading

There is a defensible case that this is "technically feasible": 500 ms spacing is 5× the documented floor, the nine haptic types are enough to distinguish downbeat from offbeat, and the correct architecture is obvious — send tempo plus one absolute start timestamp, then run a `DispatchSourceTimer(.strict)` **on the watch** with absolute-elapsed recomputation, resyncing rarely. Never message per beat. Every shipping haptic metronome converges on that design.

**I don't think that survives contact with this app**, and it's worth being explicit about where I'm disagreeing with the optimistic read:

- Feasible *for a metronome app you open and stare at*. Not feasible for a DJ, because §4c is foreground-only and every background workaround is either forbidden by App Review guidance or breaks the mechanism it borrows.
- The one field report attributes jitter to **wrist motion** — the DJ's defining condition.
- "Silent" isn't silent (§4b, the audible tone).
- And §4d is the one nobody outside this repo can see: **there is nothing to tap to.** The app has no beat grid.

**The experiment, for the record.** If you want to see it fail yourself: a watch app with `DispatchSourceTimer(.strict)` at 461.5 ms firing `.click`, recorded with a microphone at the wrist, cross-correlating tap transients against a phone-played click track — then repeated with the arm moving. **You cannot run it here:** no watchOS simulator runtime is installed **[SDK]**, and simulators don't emit haptics regardless. It's a physical-device experiment with a microphone, and I'd skip it — §4a–4d settle the decision without spending the afternoon.

> ### Verdict: **Dead.** No custom haptics; no scheduling API; foreground-only with every workaround closed; not actually silent; jitter unmeasured with the one field report blaming wrist motion; and no beat grid to tap to. Five independent blockers, any one sufficient.

---

## 5. Candidate 4 — the airhorn

**The joke deserves a real answer, and the real answer is: it's a good feature, and it has nothing to do with watchOS.**

### The latency case is exactly as bad as you'd fear

Trace the path for a wrist tap reaching TV audio:

1. Tap → `WCSession.sendMessage`. Documented behaviour: "Calling this method from your WatchKit extension while it is active and running **wakes up the corresponding iOS app in the background** and makes it reachable." **[DOC]** Good — the phone in your pocket *can* be woken. Latency is undocumented; the only public measurements are ancient (watchOS 2 era) and unflattering: **~180 ms average one-way over 200 trials**, and **~250 ms round-trip** in a separate report. **[COMMUNITY-REPORTED]** More usefully, an Apple DTS engineer's own guidance on a thread where a Digital Crown burst took over 4 seconds to arrive: *"I'd suggest either restricting the frequency in which you send the messages to **a couple per second** or building a method of 'back pressure.'"* **[DOC — Apple DTS, developer forums]** For reference, 120 BPM is exactly two messages per second — right at the ceiling Apple itself called reasonable. This channel is not a musical instrument.
2. Phone app must then have a live TCP connection to the TV. **It won't.** `SoundingTViOSApp` calls `queueClient.disconnect()` on `scenePhase == .background` (`SoundingTV-iOS/Sources/SoundingTViOSApp.swift:185`). **[REPO]** So the phone must redo mDNS discovery + TCP connect from cold — precisely the `WidgetControlSender` path, whose own doc comment says this "typically lands in well under a second when the TV is already advertising, **but is not guaranteed to**", and which budgets `controlTimeout = .seconds(5)`. **[REPO]**
3. TV validates the HMAC, applies the command.

**[INFER]** Realistic end-to-end: ~50–150 ms in the lucky case (phone foreground, socket warm), **0.5–5 s** in the normal case (phone in pocket). Anything rhythmic is not merely hard — it's off by whole bars.

There's a second landmine: `RemoteQueueServer.handleNewConnection` accepts **exactly one connection and cancels the previous one**. **[REPO]** (`RemoteQueueServer.swift:208–214`) A watch that talked to the TV directly would kick the phone off; a watch that talks via a background-woken phone would kick the *foreground* phone off if you happened to be holding it.

### Does the "quantise it" framing rescue it?

**Conceptually yes — that's genuinely what a controller does.** A sloppy human trigger snapped to the next downbeat is correct design, and it means the trigger surface's latency stops mattering as long as it lands inside the ~1.85 s bar (at 130 BPM). At 0.5 s it's fine; at 5 s it's three bars late, so you'd need a "fire on the next downbeat *after* arrival, and tell me which one" contract rather than a naive quantiser.

**But look at what quantising requires**, none of which exists:

| Requirement | Status |
|---|---|
| A beat/bar grid on the live deck | Absent. `MixEngine` → `bpm: nil` **[REPO]**; the grid is a `MusicUnderstanding` proposal in a design-only spec **[REPO]** |
| Ability to start audio at a chosen sample instant | Absent. `dj-engine-spec.md` §0: *"Nothing in the engine can currently start a deck at a chosen sample instant"* — `scheduleSegment(..., at: nil, ...)` everywhere **[REPO]** |
| A one-shot sampler bus | Absent. Two decks, bus-pinned; no third path for one-shots **[REPO]** |
| Master limiting so an airhorn on top of a full mix doesn't clip | Absent. `dj-engine-spec.md` §0.1: *"Master limiting — Absent"* **[REPO]** |

**[INFER]** So the airhorn is ~a week of `MixEngine` work: beat grid, sample-accurate scheduling, a sampler bus, and a limiter. Every one of those is independently valuable (they're the same primitives real beatmatching needs — §8.3 of the spec). And once they exist, the trigger is a button. On the phone. Or in the Live Activity — **which already renders on your watch.** The watch contributes nothing to this feature except being the slowest and most expensive way to press it.

> ### Verdict: **Build the airhorn — as a `MixEngine` feature, not a watch feature.** Quantised one-shot triggering is real DJ-controller behaviour and it unlocks primitives you need anyway. Trigger it from the phone first. A wrist trigger afterwards is trivial, and by then you'll know whether it's fun.

---

## 6. Candidate 5 — complications / Smart Stack

**The instinct is right; the implementation you're imagining is the expensive one.**

**Cost is higher than "cheap".** A WidgetKit complication needs a **watchOS app target *and* a separate watchOS widget extension target** — two new targets, not one. **[DOC]** ("Add a watchOS app target and a watchOS widget extension target.")

**Constraints:**
- Budget: "up to 75 updates per day, based on how often they're viewed." **[DOC]** For a now-playing complication that's roughly one refresh per 20 minutes — it will be stale most of the time.
- **Not interactive:** "if the user touches your complication, the system launches your app instead of passing the touch event to the SwiftUI views, so a complication **can't use interactive elements like buttons or switches**." **[DOC]** So there is no "resume" button — only "launch the app, which then does the thing".

**The alternative gets you the same outcome for ~nothing.** A Live Activity in the Smart Stack updates in real time (push/ActivityKit, not a 75/day timeline), *is* interactive (your `AppIntent` buttons work), and needs **zero new targets**. **[DOC]** + **[REPO]**

> ### Verdict: **Don't build the complication. Do the Live Activity `.small` family instead.** Same slot on the wrist, live data instead of a stale snapshot, working buttons instead of "launch the app", and no new target.

---

## 7. Candidate 6 — better ideas than the five above

**7a. Fix the Live Activity gap (highest value/effort ratio in this whole document).**
Local phone playback publishes no Live Activity at all — it's started only from the TV's `.playbackState` push. **[REPO]** Fixing that gives the standalone-first phone a Lock Screen, a Dynamic Island, and a watch presence in one change. If you do one thing from this document, do this one.

**7b. Ship the `.small` activity family.**
`supplementalActivityFamilies([.small, .medium])` on `NowPlayingLiveActivityWidget`, plus a layout that reads at 40 mm: artwork chip, title, a two-line-max artist, play/pause + next. `@Environment(\.activityFamily)` to branch. **[DOC]** This *is* the watch app, built in a target you already ship.

**7c. Add "send to Apple TV" as a Live Activity affordance.**
The one verb the system's Now Playing genuinely can't express. The system routes AirPlay; your `PlaybackOutput.thisDevice` / `.appleTV` handoff is a different mechanism it cannot see. **[REPO]** `RemoteQueueClient.handOff(track:queue:index:position:isPlaying:)` already implements it entirely in terms of commands the TV validates. A `HandOffToTVIntent` next to the existing `MixNowIntent` is a small, well-shaped addition — and it lands on the wrist for free.

**7d. Add a Control widget — on watchOS 26 it reaches the wrist with no watch app.**

> "Controls can be placed in Control Center, Smart Stack, and Action button (Apple Watch Ultra)… **Controls from iPhone apps are automatically available on Apple Watch (even without a Watch app). When tapped, actions perform on the companion iPhone.**" **[DOC]** — WWDC25 session 334, *What's new in watchOS 26*; corroborated by WWDC25 278 and the WidgetKit release notes (June 2025: "Create controls using `ControlWidgetButton` and `ControlWidgetToggle` on watchOS and macOS").

`SoundingWidgetBundle` currently has **exactly one member**, `NowPlayingLiveActivityWidget()` — there is no `ControlWidget` anywhere in the repo. **[REPO]** So this is unclaimed: a `ControlWidgetButton` wrapping the existing `MixNowIntent` or a "play/pause the TV" intent would land in iPhone Control Center, the watch's Control Center and Smart Stack, and the Ultra's Action button — from **one file in a target you already ship**. That is the cheapest wrist surface available, and it's a physical Action-button airhorn trigger if you ever build §5.

**7e. If you want a *watch-shaped* toy: an audible click, not a haptic one.**
`AVAudioEngine`, `AVAudioPlayerNode`, `scheduleBuffer(at:)` and `lastRenderTime` all exist on watchOS. **[SDK]** So sample-accurate *audio* on the watch is real, in a way sample-accurate haptics categorically is not. The catch is fatal in practice: it needs headphones on the watch's own Bluetooth route, and a DJ's headphones are on the mixer. Noted for completeness, not recommended.

---

## 7f. The one thing that *would* justify a target — and why it still doesn't

Honesty requires naming the strongest case for building this, which isn't on the brief's list: **standalone playback from the watch to Bluetooth headphones, on a run, with no phone.**

That is the one capability the system genuinely cannot fake, and it is technically real:

- `AVQueuePlayer` + HLS is the documented, recommended watchOS streaming path (WWDC19 session 716). `WKAudioFilePlayer` is deprecated since watchOS 6. **[DOC]**
- `URLSession` HTTPS works, so `api-v2.soundcloud.com` and the `getStreamURL(for:)` JSON second hop both work. **[DOC]**
- `WKInterfaceDevice.supportsAudioStreaming` gates it to Series 3+. **[DOC]**

Three things kill it anyway:

1. **Auth.** No `WKWebView` **[SDK]**, and per-device OAuth is already blocked (`CLAUDE.md`). The watch cannot obtain a token by itself, so "no phone" is exactly the case it can't serve without a prior handoff — and Apple's independence guidance says an independent app "can't use Watch Connectivity as its main source of data". **[DOC]** §9.
2. **Route friction.** Activating a `.playback` session with `.longFormAudio` on watchOS **requires a Bluetooth output route**; with none, the system "presents the route picker", and if the user dismisses it the activation completion handler gets `false`. **[DOC]** Every session starts with a device picker.
3. **It's a different app.** Apple's own guidance is to start at **64 kbps** and upgrade only if the network allows. **[DOC]** A wrist player at 64 kbps has nothing to do with the Sonos Arc spatialisation work in `PlayerService`, and it would be a second, separate playback stack to maintain.

> ### Verdict: **the only genuinely watch-shaped feature is blocked by the app's auth model**, which is itself blocked by not having a `client_id` with a custom-scheme `redirect_uri`. If SoundCloud ever grants you one, reopen this section — it's the only entry here that would change the recommendation.

---

## 8. The connectivity reality — the OS forbids it, not just discourages it

**This section changed after I found Apple's technote. It is now the hardest constraint in the document.**

I initially verified that `NWBrowser(for: .bonjour(type: "_soundingtv._tcp", …))` **compiles clean** against the watchOS 27 SDK **[SDK]**, and was ready to file "does Bonjour actually work on a watch?" as an open question. It isn't open. Apple answers it directly, and the answer is no:

> "watchOS groups networking into two categories: **High-level networking** — HTTP and HTTPS support in `URLSession`… **Low-level networking** — Network framework, `Stream`, and any other API that runs a TCP connection or UDP session directly… **It also includes APIs, like `NWBrowser` and `NetService`, that interact directly with Bonjour.**
>
> watchOS allows all apps to use high-level networking equally. However, it only allows an app to use low-level networking under specific circumstances: … an audio streaming app **while actively streaming audio** (watchOS 6+) … a VoIP app **while running a call using CallKit** (watchOS 9+) … an app that sets up an **application service listener so that the same app on tvOS can establish a low-level connection to it** using `DeviceDiscoveryUI` (watchOS 9 / tvOS 16+).
>
> **watchOS blocks low-level networking outside of these specific circumstances.** For example, if a normal app attempts to start an `NWConnection`, that connection will stay in the `waiting(_:)` state with an error of **`ENETDOWN`**. Similarly, an `NWPathMonitor` will remain in the `unsatisfied` state.
>
> The BSD sockets API **doesn't work for networking on watchOS under any circumstances**."
>
> **[DOC]** — TN3135, *Low-level networking on watchOS*, revised 2026-07-16

Two things in that technote would have cost real time:

- **The symbols compile. That proves nothing.** My SDK probe was correct and useless — availability annotations say `watchos(6.0)`, the code typechecks, and it fails at runtime with `ENETDOWN`. Apple DTS put it plainly on the forums: `NWBrowser` "is available in watchOS from a symbol standpoint, but when used outside the context of an audio stream session does not work."
- **The simulator lies.** TN3135: *"When writing watchOS networking code, test it on a real device; **the simulator always allows low-level networking**."* You could build the whole thing in the simulator, watch it work perfectly, and discover on hardware that it never could. (Worse: watchOS 6–8 had a bug where it sometimes worked on device too — r. 83682211, **fixed in watchOS 9**, which enforces the rules properly. So it got stricter, and any tutorial predating that is poison.)

Also confirmed: there is **no local network privacy prompt on watchOS** — TN3179's platform table marks watchOS **No**, `NSLocalNetworkUsageDescription` doesn't list watchOS, and the multicast entitlement is iOS/iPadOS/visionOS only. **[DOC]** There's no permission to grant because there's no local networking to gate.

### What this means concretely

`RemoteQueueClient`, `BonjourAuthClient`, `BonjourAuthServer` and every byte of the `_soundingtv._tcp` protocol **cannot run on a watch.** The `TokenTransferProtocol.swift` compile-clean result **[SDK]** is a curiosity, not a capability.

**So the topology is forced: watch → phone → TV.** Two hops, both hops' latency, and the phone must be present, awake, and willing to reconnect. The "phone in a pocket, TV is playing" case — the one the brief singles out — is the *worst* case: the phone app is backgrounded (`scenePhase == .background` → `queueClient.disconnect()`) **[REPO]**, its socket is gone, and every wrist command pays a cold mDNS + TCP round trip budgeted at up to 5 s **[REPO]**.

And even if watchOS permitted it, `RemoteQueueServer.handleNewConnection` accepts **exactly one connection and cancels the incumbent** **[REPO]**. A watch on that socket would displace the phone; the phone's `startLivenessWatchdog` would reconnect ~10 s later and displace the watch. Two clients would flap forever.

**"Control the Apple TV from my wrist while my phone is in another room" — the single most compelling watch feature for this app — is not buildable.** Not "hard". Not "high latency". Blocked by the OS.

**And the system already does it better anyway:** the watch's Remote app talks to the Apple TV **over Bluetooth, directly**, with no phone in the path at all. **[DOC]**

### The one sanctioned exception, and why it doesn't fit

`DeviceDiscoveryUI` (TN3135 exception #3) genuinely does allow a tvOS↔watchOS encrypted local connection. **[DOC]** It doesn't fit here:

- **The TV initiates.** The watch can only run a listener; the user starts pairing on the *Apple TV*, not the wrist. That's backwards from the UX.
- tvOS connects to **one device at a time**, and **only to other copies of the same app** — which requires universal purchase / a shared bundle ID across platforms, and this project deliberately uses per-platform bundle IDs.
- Devices only appear if signed into the **iCloud account of the Apple TV's default user**.
- Doesn't work in the Simulator.

Worth knowing it exists. Not worth rearchitecting the app's identity scheme for.

### What *does* work from the watch

`URLSession` HTTP/HTTPS is fully supported. **[DOC]** So `api-v2.soundcloud.com` and `getStreamURL(for:)`'s JSON second hop would both work. (`URLSessionStreamTask` and `URLSessionWebSocketTask` are classified low-level and are blocked — irrelevant here, you use neither.) And `WCSession.sendMessage` from watch → phone **wakes the backgrounded iOS app**; phone → watch does **not** wake the watch app. **[DOC]**

---

## 9. Independent vs dependent, and whether a watch app can authenticate

**Dependent is still supported, and is still the default.** Adding a watch app to an existing iOS app produces a dependent app; independence is opt-in via `WKRunsIndependentlyOfCompanionApp`, which is **not deprecated**. **[DOC]** So "must it be a satellite?" has a mechanical answer of "no, but you can choose one" — and a practical answer of "yes, it has no choice."

**Apple's position is nonetheless unambiguous:** *"To ensure the best experience for all Apple Watch users, create an independent watchOS app that doesn't require a companion iOS app."* And: *"Independent watchOS apps can't rely on the WatchConnectivity framework to transfer data or files from a companion iOS app… the independent watchOS app can't use Watch Connectivity as its main source of data, so it needs to be capable of accessing information on its own."* **[DOC]**

**This app cannot satisfy that.** Auth is the blocker, three ways:

1. **No WKWebView on watchOS.** `import WebKit` → *"no such module 'WebKit'"*. **[SDK]** The app's *only* sign-in mechanism is `AppClipLoginView` presenting a `WKWebView` at `https://soundcloud.com/signin` and capturing the `oauth_token` cookie. That flow cannot exist on the watch.
2. **Per-device OAuth is already blocked.** `CLAUDE.md`, Known unresolved issues: it needs a `client_id` with a custom-scheme `redirect_uri`, which you don't have. So there is no non-webview path either.
3. **Keychain access groups don't cross devices.** `PairedTVStore` and `PhoneSessionStore` share `6Z49PF6642.red.forbes.sounding.shared` between the iOS app and the widget extension — same device, different processes. **[REPO]** A watch is a different device. Both the SoundCloud OAuth token *and* the TV pairing's HMAC secret would have to be shipped over `WCSession` and stored in the watch's own keychain.

Apple's sanctioned alternatives — no accounts, CloudKit, Sign In with Apple, or custom text-field forms **[DOC]** — none fit an unofficial client scraping a session cookie.

**[INFER]** So a Sounding watch app is structurally a **dependent satellite**: it can't sign in, can't get a token on its own, can't stream without one, and would show an empty shell to anyone who opened it without their phone. That's the profile Apple's guidance exists to discourage, and it's a genuine argument that the platform is a poor fit for *this specific app* — not a general one.

Also worth stating plainly: making a third device hold your SoundCloud OAuth token and the TV's pairing secret widens the blast radius of a lost watch, for a feature whose whole value proposition is "glanceable". (The right transfer primitive would be `WCSession.updateApplicationContext(_:)` — no reachability requirement, coalescing, "replaces the previous dictionary" **[DOC]** — not `sendMessage`. Your HMAC-signed `TokenTransferMessage` design wouldn't apply; WatchConnectivity is already an OS-managed encrypted channel.)

**One gotcha to decide deliberately if you ever do ship a target:** `PUICAutoLaunchAudioOptOut` (watchOS 5+) — *"A Boolean value that indicates whether a watchOS app should opt out of automatically launching when its companion iOS app starts playing audio content."* **[DOC]** The **default is to auto-launch**. Ship a watch app without setting this and Sounding will jump onto the wrist every time the phone starts a track. That default is itself a strong hint about what Apple thinks a music app's watch app is *for* — a remote control for the phone, which is exactly the thing the system already provides.

---

## 10. Real cost, concretely

| Item | Detail |
|---|---|
| **Targets** | 1 (watch app) — **2** if you want a complication **[DOC]** |
| **Bundle ID** | Must be `red.forbes.sounding.watchkitapp`, with `INFOPLIST_KEY_WKCompanionAppBundleIdentifier = red.forbes.sounding` **[SDK]** (Xcode watchOS template) |
| **Provisioning** | New App ID + profile in the developer portal. New entitlements file if you want a keychain group. |
| **`project.pbxproj`** | The riskiest line item. `CLAUDE.md`: hand-edited, diverged from `project.yml`, "a serialization bottleneck", and **embed phases were deliberately stripped**. A watch app *requires* an "Embed Watch Content" phase on the iOS app. This is precisely the class of change that has broken this project before, and it must be done in the main session with no agent touching the file. |
| **Versioning** | `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` are project-level. The watch target must *reference* them — a mismatched `CFBundleVersion` is a build warning and an ASC rejection (`CLAUDE.md`). |
| **Info.plist** | `CFBundleDisplayName` must be set explicitly or the watch reads "SoundingTV Watch App" (`PRODUCT_NAME = $(TARGET_NAME)`). |
| **UI** | A third design language. `Font.tv*` is 28–58 pt; iOS sizes are also wrong. Nothing in `DesignSystem.swift` transfers. |
| **State sync** | A third now-playing state machine, across a device boundary, with its own reachability/staleness handling. `PhonePlaybackCoordinator` exists because reconciling *two* was already hard enough to need a single arbiter. |
| **Toolchain** | Multi-GB `xcodebuild -downloadPlatform watchOS` before you can run anything (no runtime installed; the 5 current runtimes are 30.3 GB). **[SDK]** |
| **Ongoing** | Every wire-protocol or now-playing change becomes a three-platform change, forever, on a personal app. |
| **App Store Connect** | Watch screenshots, a separate review surface. |

**Against that, the recommended alternative:** one call site moved, one `supplementalActivityFamilies` modifier, one `.small` SwiftUI layout, in a target that already exists. Call it half a day.

---

## 11. What would change my mind

| If this turned out to be true | Then reconsider |
|---|---|
| **SoundCloud grants you a `client_id` with a custom-scheme `redirect_uri`** | The biggest one. It unblocks watch-side auth, which unblocks **standalone playback to Bluetooth headphones** (§7f) — the only genuinely watch-shaped feature this app has. |
| Apple lifts TN3135 and permits Bonjour on watchOS | A watch-native TV remote becomes coherent — though you'd still have to solve `RemoteQueueServer`'s single-connection rule (§8), and the system Remote app already does it over Bluetooth |
| Apple ships CoreHaptics on watchOS with scheduled patterns | Candidate 3 comes back from the dead and becomes the most interesting thing in the app. Re-run the one-line compile probe each September — it's the cheapest recurring check in this document. |
| You build the `MusicUnderstanding` beat grid **and** find yourself glancing at the mix countdown constantly | A dedicated watch cue face earns its target |
| You start gigging weekly | Re-weigh §3 entirely — the `~/Music/` evidence is the weakest input in this document and the easiest to overturn |

---

## Appendix — verification method

Every **[SDK]** claim came from compiling against `/Applications/Xcode-beta.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS27.0.sdk`:

```bash
SDK=$(xcrun --sdk watchos27.0 --show-sdk-path)
swiftc -typecheck -sdk "$SDK" -target arm64_32-apple-watchos27.0 probe.swift
```

| Probe | Result |
|---|---|
| `import CoreHaptics` | **error: no such module** |
| `import WebKit` | **error: no such module** |
| `import ActivityKit` | **error: no such module** |
| `WKInterfaceDevice.current().play(.click)` | compiles |
| `NWBrowser(for: .bonjour(type: "_soundingtv._tcp", …), using: .tcp)` | compiles — **and does not work at runtime**, see below |
| `AVAudioEngine` / `AVAudioPlayerNode.lastRenderTime` / `AVAudioSession` / `AVPlayer` | compiles |
| `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` / `WCSession` | compiles |
| `WidgetFamily.accessoryCircular/.accessoryRectangular/.accessoryCorner/.accessoryInline` | compiles |
| `WKExtendedRuntimeSession` | compiles |
| `SoundingTV.swiftpm/Sources/Services/TokenTransferProtocol.swift` (whole file, unmodified) | **compiles clean, 0 errors** |

**The methodological caveat, which is the most transferable thing in this document:** on watchOS, *compiling is not evidence of working.* `NWBrowser` typechecks, carries a `watchos(6.0)` availability annotation, and fails at runtime with `ENETDOWN` (§8). Apple DTS: it "is available in watchOS from a symbol standpoint, but when used outside the context of an audio stream session does not work." And per TN3135, **"the simulator always allows low-level networking"** — so the simulator would have confirmed the wrong answer too. For watchOS specifically, the availability table and the technotes outrank both the compiler and the simulator.

Every **[DOC]** claim came from Apple's documentation JSON API (`https://developer.apple.com/tutorials/data/documentation/<path>.json`), Apple technotes (TN3135, TN3179), WWDC session pages, or the Apple Watch User Guide on `support.apple.com`, and is quoted rather than paraphrased where it's load-bearing. **[COMMUNITY-REPORTED]** items are labelled inline and never carry a verdict on their own.

### Primary sources for the load-bearing claims

- TN3135, *Low-level networking on watchOS* — https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos
- TN3179, *Understanding local network privacy* — https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- `WKInterfaceDevice.play(_:)` — https://developer.apple.com/documentation/watchkit/wkinterfacedevice/play(_:)
- `CHHapticEngine` (platform list, no watchOS) — https://developer.apple.com/documentation/corehaptics/chhapticengine
- *Using extended runtime sessions* — https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions
- *Bring your Live Activity to Apple Watch*, WWDC24 10068 — https://developer.apple.com/videos/play/wwdc2024/10068/
- `WidgetKit/ActivityFamily` — https://developer.apple.com/documentation/widgetkit/activityfamily
- *What's new in watchOS 26*, WWDC25 334 — https://developer.apple.com/videos/play/wwdc2025/334/
- *Creating accessory widgets and watch complications* — https://developer.apple.com/documentation/widgetkit/creating-accessory-widgets-and-watch-complications
- *Creating independent watchOS apps* — https://developer.apple.com/documentation/watchOS-Apps/creating-independent-watchos-apps
- `WKWebView` (platform list, no watchOS) — https://developer.apple.com/documentation/webkit/wkwebview
- `PUICAutoLaunchAudioOptOut` — https://developer.apple.com/documentation/bundleresources/information-property-list/puicautolaunchaudioopt-out
- Apple Watch User Guide, *Now Playing* / *Remote* — https://support.apple.com/guide/watch/now-playing-apd4ea5db227/watchos , https://support.apple.com/guide/watch/remote-apd619078d99/watchos

Nothing in the repository was modified.
