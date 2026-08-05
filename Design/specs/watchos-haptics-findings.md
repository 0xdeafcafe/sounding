# Haptics on watchOS — feasibility research

**Question:** can an Apple Watch app act as a "silent metronome" tapping musical downbeats (~120 BPM = one tap every 500 ms, sub-beat accuracy required)?

**Date:** 2026-07-31
**Verdict:** technically possible, but not worth doing. See [Bottom line](#bottom-line).

**Method:** Apple's docs are JS SPAs, so pages were pulled from the backing DocC JSON API (`developer.apple.com/tutorials/data/documentation/<path>.json`) and cross-checked against the **watchOS 27.0 SDK on this machine** (Xcode 27.0, build 27A5228h). SDK headers are primary evidence and beat any doc page. Community sources searched separately.

**Confidence labels used throughout:**
- **VERIFIED** — Apple documentation, SDK headers, or WWDC primary source
- **COMMUNITY-REPORTED** — forum, blog, App Store review, GitHub
- **INFERRED** — my reasoning from the above, labelled as such

---

## Headline

**Core Haptics does not exist on watchOS — at all.** Every question about custom patterns, `start(atTime:)`, engine timebase, AHAP files, and parameter curves is moot. The entire watchOS haptic API surface is **one method** taking **one of ~9 usable fixed constants**, with no intensity, no duration, and no scheduling.

The one piece of good news: Apple's documented rate floor is **100 ms**, and 120 BPM is 500 ms. You are **5× above the floor**, so the throttle is *not* the binding constraint. The binding constraints are background execution, App Review, and unmeasured jitter.

---

## 1. `WKInterfaceDevice.play(_:)` / `WKHapticType`

### Complete case list — VERIFIED (SDK header, primary)

From `$(xcrun --show-sdk-path --sdk watchos)/System/Library/Frameworks/WatchKit.framework/Headers/WKInterfaceDevice.h`:

| Case | Since | Restriction (verbatim header comment) |
|---|---|---|
| `.notification` `.directionUp` `.directionDown` `.success` `.failure` `.retry` `.start` `.stop` `.click` | watchOS 2.0 | none |
| `.navigationLeftTurn` `.navigationRightTurn` `.navigationGenericManeuver` | watchOS 7.0 | "can only be used while the app has an active **navigation session** running" |
| `.underwaterDepthPrompt` `.underwaterDepthCriticalPrompt` | watchOS 9.0 | "can only be used while the app has an active **underwater depth session** running" |

**9 usable types** for a general-purpose app.

- https://developer.apple.com/documentation/watchkit/wkhaptictype

### Rate limiting — VERIFIED, explicit

From https://developer.apple.com/documentation/watchkit/wkinterfacedevice/play(_:) — verbatim:

> "Do not call this method multiple times in quick succession. If the haptic engine is already engaged when you call this method, **the system stops the current feedback and imposes a minimum delay of 100 milliseconds** before engaging the engine to generate the new feedback. Use of the haptic engine also consumes power, and using the engine too much may create a noticeable drain on the Apple Watch battery, as well as a negative user experience."

Semantics worth noting: this is **not** coalescing or dropping. The in-flight haptic is **truncated**, and the new one is **delayed** to a ≥100 ms boundary.

**INFERRED:** the documented floor implies a theoretical ceiling around 600 BPM for straight quarter notes. 16th-note subdivisions at ~150 BPM land at exactly 100 ms, i.e. right on the floor. At 500 ms spacing you should never touch it.

### Background behaviour — VERIFIED, with a documentation conflict

Same page, verbatim:

> "This method has no effect when called while your shared `WKExtension` object's `applicationState` property is either **background** or **inactive**. By default, you cannot play haptic feedback in the background. The only exception are apps with an active workout session."

**This contradicts the extended-runtime-session guide** (see §4), which states sessions can "play sounds or haptics, even after the watch's screen turns off." The `play(_:)` page appears stale — it predates watchOS 6. **Unresolved from documentation alone; needs a device test.**

### The HealthKit landmine — VERIFIED, materially important

Same page, an `Important` aside:

> "Do not call this method while gathering heart rate data using HealthKit. When you engage the haptic engine, **HealthKit stops gathering heart rate data until after the haptic engine finishes.**"

This directly undercuts the obvious background workaround. `HKWorkoutSession` is the *documented* way to get background haptics, and every workout session collects high-frequency heart rate. Firing haptics twice a second would effectively suppress HR collection for the entire session.

### Haptics come with sound — VERIFIED, relevant to "silent"

HIG, https://developer.apple.com/design/human-interface-guidelines/playing-haptics:

> "on Apple Watch, the Taptic Engine generates haptics for a number of built-in feedback patterns, **which watchOS combines with an audible tone**."

A "silent metronome" is only silent if the user has Silent Mode on. That is a user-settings dependency, not a property of the API.

---

## 2. Core Haptics on watchOS — **not available**

Three independent lines of evidence, all VERIFIED.

### (a) Apple's availability metadata lists no watchOS

Every symbol checked returns the same platform set — `iOS 13.0, iPadOS 13.0, Mac Catalyst 13.0, macOS 10.15, tvOS 14.0, visionOS 1.0`:

- `CHHapticEngine` — https://developer.apple.com/documentation/corehaptics/chhapticengine
- `CHHapticEngine.capabilitiesForHardware()` — https://developer.apple.com/documentation/corehaptics/chhapticengine/capabilitiesforhardware()
- `CHHapticDeviceCapability.supportsHaptics` — https://developer.apple.com/documentation/corehaptics/chhapticdevicecapability/supportshaptics
- `CHHapticPattern` — https://developer.apple.com/documentation/corehaptics/chhapticpattern
- `CHHapticPatternPlayer.start(atTime:)` — https://developer.apple.com/documentation/corehaptics/chhapticpatternplayer/start(attime:)
- `CHHapticEngine.currentTime` — https://developer.apple.com/documentation/corehaptics/chhapticengine/currenttime

Framework page: https://developer.apple.com/documentation/corehaptics — `iOS 13.0, iPadOS 13.0, Mac Catalyst 13.0, tvOS 14.0, visionOS 1.0`. Abstract reads "customize your **iOS** app's haptic feedback."

tvOS *is* listed (for game-controller haptics), so the platform list is meaningful — not an iOS-centric omission.

### (b) The framework is physically absent from the watchOS SDK

In `WatchOS27.0.sdk`:

- `CoreHaptics.framework` — **absent** (present in the iOS SDK)
- `find <sdk> -iname '*haptic*'` — **zero results**
- `grep -rl 'CHHaptic' <sdk>/System/Library/Frameworks/` — **zero results**

### (c) WWDC 2019 session 520 frames it as iPhone-only

https://developer.apple.com/videos/play/wwdc2019/520

> "we will be able to access hundreds of millions of haptic engine-equipped iPhones **starting from iPhone 8 onward**."

The only Apple Watch mention in the session is the Series 4 Digital Crown, cited as prior art for audio-haptic duality — not as a supported platform.

### Consequences (VERIFIED by absence)

- ❌ No custom `CHHapticPattern` (transient/continuous events), no intensity or sharpness control
- ❌ No `start(atTime:)`, no `CHHapticEngine.currentTime` — **no scheduled/future-timed haptics, no audio-clock-synchronised timebase.** Every tap must be triggered by your own timer, in-process, in real time
- ❌ No AHAP files, no `CHHapticParameterCurve`, no audio-haptic sync
- ❌ No `AudioToolbox` on watchOS either — so no `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)` fallback

### One nuance: SwiftUI `SensoryFeedback`

`SensoryFeedback` / `.sensoryFeedback(_:trigger:)` **is** available on **watchOS 10.0+** — https://developer.apple.com/documentation/swiftui/sensoryfeedback

It is a cross-platform wrapper over the same fixed set, not a Core Haptics bridge.

**INFERRED:** it is a *worse* choice than `play(_:)` for a metronome — it fires off an `Equatable` trigger change, inserting a SwiftUI view-update cycle between your clock and the tap.

---

## 3. Timing accuracy and jitter — **no public ground truth exists**

The honest headline: **no empirical latency or jitter measurement for watchOS haptics exists in any public source.** No blog benchmark, no forum measurement, no WWDC statement, no App Store review with numbers.

Two academic HCI papers use Apple Watch haptics for explicitly *rhythmic* feedback and report **zero** timing figures:

- "Hapster" — https://arxiv.org/abs/2507.05605 (plays haptics "four times in quick succession")
- "Closed-Loop Rhythmic Haptic Biofeedback via Smartwatch" — https://arxiv.org/html/2507.02432v1 (Apple Watch SE 2)

**The 100 ms figure in Apple's docs is the only hard number anywhere.** Nothing corroborates or contradicts it empirically.

### The one real device-testing account — COMMUNITY-REPORTED

A beta tester of a watchOS metronome ("Beatz Buddy", Watch Ultra 2 / watchOS 11.6.1) — https://www.kvraudio.com/forum/viewtopic.php?t=623534

> "The timing is not rock solid. When flicking around in the interface, it has to get caught up to deal with the interrupts... If I wave my hand/arm for whatever reason, the timing goes off. 5/4 is not even generically steady, even if I hold my hand still... The only time it's steady is if I don't move my hand at all, and the watch face is up."

The developer subsequently shipped a release labelled "Enhanced timing precision."

**INFERRED:** jitter appears dominated by system interrupts and wrist-motion/display wake, not by the haptic engine's raw scheduling.

### Existing apps — no BPM ceiling attributed to haptics

Surveyed: Wristonome, haptik.watch, metroGnome (hodge.io), Cadence, MWM's metronomes, "Haptic Watch Metronome". Quoted BPM ranges (40–220, 20–240) read as conventional metronome ranges.

**No app, developer, or review anywhere documents a max BPM because the haptic engine can't keep up.**

Cadence — https://apps.apple.com/us/app/cadence-haptic-metronome/id6760317385 — advertises "a drift-compensating algorithm that... measures expected vs. actual tick times and corrects in real time." Marketing copy, but it implies drift was a real engineering problem worth solving.

### Perceptibility is a bigger complaint than timing — COMMUNITY-REPORTED

Multiple user reviews report the tap is too weak to feel:

- haptik: *"pulse... too feeble to feel unless you have your fingers on it."*
- Wristonome: *"Haptic imperceptible on wrist, barely feel with fingers."*
- r/pianolearning thread titled *"Apple Watch Haptic Metronome Apps Are Terrible?"* — https://www.reddit.com/r/pianolearning/comments/1cjiiel/

### GitHub survey — read with caution

Repos found: `thegridbase-ai/Haptic` (renamed from `cankilic-gh/Haptic`), `justinciocoi/Apple-Watch-Haptic-Metronome`, `rob-omb/bing-bong`, `pandazxx/watchbeat`, `Itsuki1498/watch_metronome`.

Most use plain `Timer.scheduledTimer` with no drift correction and **no handling of the 100 ms floor**. The most sophisticated uses `DispatchSourceTimer(.strict)` + `mach_absolute_time` absolute-elapsed recomputation — a sound anti-drift pattern — but its own `STATE.md` admits the watchOS target is unbuilt.

A large share of this ecosystem is visibly LLM-scaffolded (2026 dates, AI commit trailers, unbuilt targets). Their "nanosecond precision" READMEs are generated copy, **not measured results**.

### Battery/thermal throttling — no evidence beyond the documented warning

Apple documents power *cost* but no dynamic throttle beyond the flat 100 ms delay. No evidence found that Low Power Mode or thermal state changes haptic behaviour. An AppleVis thread speculating that Prominent Haptics drains battery was **disputed by other commenters**. **Explicit gap.**

---

## 4. Background execution — the real constraint

### Extended runtime sessions — VERIFIED, authoritative table

From https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions

| Session type | Runtime | Schedulable | Time limit |
|---|---|---|---|
| Self care | Frontmost | No | **10 minutes** |
| Mindfulness | Frontmost | No | **1 hour** |
| Physical therapy | **Background** | No | **1 hour** |
| Smart alarm | **Background** | Yes | **30 minutes** |

Verbatim:

> "Extended runtime sessions let the app continue to communicate with a Bluetooth device, process data, **or play sounds or haptics, even after the watch's screen turns off.**"

> "Frontmost sessions continue to run in the foreground. **The watch screen doesn't need to remain on to keep your app alive.** The session continues until the time limit expires, your app invalidates the session, or the user explicitly leaves your app (for example, by pressing the digital crown or switching to a different app)."

**This directly contradicts the `play(_:)` page's "only exception are apps with an active workout session."** Unresolved from docs; needs device testing.

### Constraints — VERIFIED

- **One session type per app**, declared via `WKBackgroundModes` (`self-care` / `mindfulness` / `physical-therapy` / `alarm`). Can be combined with `workout-processing` — https://developer.apple.com/documentation/bundleresources/information-property-list/wkbackgroundmodes
- No entitlement required, but a plist key is: `WKExtendedRuntimeSessionErrorNotApprovedToStartSession = 7 // the app is missing a valid plist key or entitlement`
- User can kill it: `barDisabled = 6 // the BAR switch for the application is disabled` (Background App Refresh)
- CPU-capped: `exceededResourceLimits = 5`, and *"If your app sustains high CPU usage over a period of time, the system may cancel the session"*
- System can refuse outright: `suppressedBySystem`

### App Review risk — VERIFIED quote

> "Select a session type based on the app's intended use — not based on the features that the session provides."

**None of the four types is a metronome.** Declaring `physical-therapy` to obtain a background metronome is precisely what this sentence forbids.

### The one system-scheduled repeating haptic — VERIFIED but unusable here

`notifyUser(hapticType:repeatHandler:)` is the **only** watchOS API where the *system* schedules a repeating haptic rather than your timer.

https://developer.apple.com/documentation/watchkit/wkextendedruntimesession/notifyuser(haptictype:repeathandler:)

> "an optional block that returns a valid time interval for when to play the next haptic. This value must be **> 0.0 and <= 60.0**."

Tempting — `0.5` would be 120 BPM, system-scheduled. But it is fenced off:

- Alarm session type only
- Requires `start(at:)` scheduling (alarm background mode)
- Session state must be `.running`
- 30-minute cap
- **"If the app is not active, this will result in a system alert UI"** — with a Stop button

Not viable for a metronome, but worth knowing it exists.

### `HKWorkoutSession` — the documented path, with real costs

https://developer.apple.com/documentation/healthkit/running-workout-sessions — verbatim:

> "Your app can alert the user using audio or haptic feedback while running in the background."

Requirements: `workout-processing` **and** `audio` background modes, HealthKit authorization with usage strings, and a clear user-visible start/stop affordance. No documented duration cap.

Costs:
- Pollutes Move/Exercise rings
- **The HR-vs-haptic conflict from §1** — twice-a-second haptics would suppress the session's own heart-rate collection, which is the thing a workout session exists to do

### Background audio keepalive does **not** transfer from iOS — VERIFIED

https://developer.apple.com/documentation/watchkit/playing-background-audio

watchOS background audio uses the `.longFormAudio` route policy, and **"watchOS requires a Bluetooth audio route for long-form audio"** — presenting a route picker if none exists. The iOS "play a silent track to stay alive" trick does not work cleanly here.

---

## 5. WatchConnectivity latency

### Documented semantics — VERIFIED, verbatim

**`sendMessage(_:replyHandler:errorHandler:)`** — https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)

> "Messages are queued serially and delivered in the order in which you sent them."

> "Calling this method from your WatchKit extension while it is active and running **wakes up the corresponding iOS app in the background** and makes it reachable. **Calling this method from your iOS app does not wake up the corresponding WatchKit extension.**"

That asymmetry is decisive: **the phone cannot wake the watch app.** Phone→watch per-beat messaging requires the watch app already foregrounded.

**Reachability asymmetry — VERIFIED.** https://developer.apple.com/documentation/watchconnectivity/wcsession/isreachable — watch-side `isReachable` requires the iPhone in range; iPhone-side `isReachable` requires **the WatchKit extension running in the foreground** (or high-priority background).

**`transferUserInfo(_:)`** — FIFO, survives suspension. **Not supported in Simulator.**

**`updateApplicationContext(_:)`** — **coalescing confirmed**: "This method replaces the previous dictionary that was set"; "The system sends context data **when the opportunity arises**."

**`WCSession` overview** — "the system may **delay transfers slightly to improve power usage**."

No payload size limit is documented anywhere (only `WCError.payloadTooLarge`, with no number given).

### Measured latency — old, sparse, all discouraging — COMMUNITY-REPORTED

- **~180 ms average one-way over 200 trials** (watchOS 2 era). A game developer needing <50 ms concluded it likely wasn't viable — https://web.archive.org/web/20210419140455/https://stackoverflow.com/questions/31993413/performance-of-watchconnectivity-wcsession-sendmessage
- **~250 ms average round-trip**, degrading to total failure within hours requiring a watch reboot — https://developer.apple.com/forums/thread/20311
- **An Apple DTS engineer's own guidance**, on a thread where a Digital Crown burst took >4 s to arrive — https://developer.apple.com/forums/thread/9368

  > "I'd suggest either restricting the frequency in which you send the messages to **a couple per second** or building a method of 'back pressure.'"

  **120 BPM is exactly 2 messages/sec — right at the ceiling Apple itself called reasonable.**

- **WWDC 2015 session 713** slides label background transfers **"Recommended"**, with interactive messaging as the live-vs-live exception. No ms figures, no explicit real-time warning — https://devstreaming-cdn.apple.com/videos/wwdc/2015/713gc2tqvvb/713/713_introducing_watch_connectivity.pdf

**Explicit gap:** the only hard numbers on record are ~10 years old (watchOS 2 / iOS 9). Nobody has published modern round-trip measurements.

### The escape hatch is closed — VERIFIED, and relevant to this repo

**TN3135: Low-level networking on watchOS** — https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos (revised 2026-07-16), verbatim:

> "Low-level networking. This includes **Network framework**, Stream... It also includes APIs, like **`NWBrowser` and `NetService`, that interact directly with Bonjour**."

> "watchOS **blocks** low-level networking outside of these specific circumstances. For example, if a normal app attempts to start an `NWConnection`, that connection will stay in the `waiting(_:)` state with an error of `ENETDOWN`."

The three exceptions are:
1. Active audio streaming (watchOS 6+)
2. CallKit VoIP call in progress (watchOS 9+)
3. An app service listener so the same app **on tvOS** can connect via DeviceDiscoveryUI (watchOS 9+)

**iPhone is not among them.**

> "When writing watchOS networking code, **test it on a real device; the simulator always allows low-level networking.**"

**This matters for this codebase.** The `_soundingtv._tcp` Bonjour + `NWListener`/`NWBrowser` pattern already used between iOS and tvOS **cannot be replicated on watchOS** — and a prototype will work perfectly in the simulator before failing on device. Also: no BSD sockets on watchOS under any circumstances.

---

## Bottom line

**Technically feasible with a specific architecture, but three risks make it a poor bet.**

### What works

500 ms tap spacing sits 5× above Apple's documented 100 ms floor, so the throttle is not the binding constraint. The 9 available haptic types give just enough vocabulary to differentiate a downbeat from an offbeat (e.g. `.notification` or `.start` on 1, `.click` on the rest).

### Required architecture — INFERRED, but strongly supported

Run the clock **on the watch**. Send tempo plus an absolute start timestamp once via `sendMessage` / `updateApplicationContext`, then let a local `DispatchSourceTimer(.strict)` with absolute-elapsed recomputation (not accumulated intervals) drive `WKInterfaceDevice.play()`, resyncing only periodically.

**Never send a message per beat.** The phone cannot wake the watch app; the only measured RTT (~180 ms) consumes a third of the beat budget; and Apple's own DTS guidance caps you at "a couple per second," which is exactly 120 BPM. Every shipping haptic metronome converges on watch-local timing.

### The three risks, in order

1. **Background execution + App Review.** Foreground-only is the sanctioned default. `HKWorkoutSession` is the documented background path but pollutes activity rings and — per Apple's own aside — suppresses the heart-rate collection that the session exists to perform. Extended runtime sessions look better on paper, but Apple explicitly forbids selecting a type for its features rather than its intended use, and none of the four types is "metronome."

2. **Jitter is unmeasured.** There is no public ground truth, anywhere. The one credible device account attributes jitter to UI interrupts and wrist motion rather than the engine itself. You would have to characterise this on hardware yourself, with no prior art to check against. Treat any competitor's "rock-solid timing" claim as unverified marketing.

3. **Perceptibility, and the audible tone.** Multiple user reviews of shipping apps say the tap is simply too weak to feel on the wrist. And watchOS pairs haptics with a sound unless Silent Mode is on — so "silent" is a user-settings dependency, not a property of the API.

---

## Source index

**Apple primary**
- https://developer.apple.com/documentation/watchkit/wkhaptictype
- https://developer.apple.com/documentation/watchkit/wkinterfacedevice/play(_:)
- https://developer.apple.com/documentation/corehaptics
- https://developer.apple.com/documentation/corehaptics/chhapticengine
- https://developer.apple.com/documentation/swiftui/sensoryfeedback
- https://developer.apple.com/design/human-interface-guidelines/playing-haptics
- https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions
- https://developer.apple.com/documentation/watchkit/wkextendedruntimesession/notifyuser(haptictype:repeathandler:)
- https://developer.apple.com/documentation/bundleresources/information-property-list/wkbackgroundmodes
- https://developer.apple.com/documentation/healthkit/running-workout-sessions
- https://developer.apple.com/documentation/watchkit/playing-background-audio
- https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)
- https://developer.apple.com/documentation/watchconnectivity/wcsession/isreachable
- https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos
- https://developer.apple.com/videos/play/wwdc2019/520
- https://devstreaming-cdn.apple.com/videos/wwdc/2015/713gc2tqvvb/713/713_introducing_watch_connectivity.pdf
- watchOS 27.0 SDK headers (`WKInterfaceDevice.h`, `WKExtendedRuntimeSession.h`), Xcode 27.0 build 27A5228h

**Community**
- https://www.kvraudio.com/forum/viewtopic.php?t=623534
- https://developer.apple.com/forums/thread/9368
- https://developer.apple.com/forums/thread/20311
- https://web.archive.org/web/20210419140455/https://stackoverflow.com/questions/31993413/performance-of-watchconnectivity-wcsession-sendmessage
- https://www.reddit.com/r/pianolearning/comments/1cjiiel/
- https://apps.apple.com/us/app/cadence-haptic-metronome/id6760317385

**Academic**
- https://arxiv.org/abs/2507.05605
- https://arxiv.org/html/2507.02432v1
