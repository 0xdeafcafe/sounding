# Local DJ mode on the phone — plan, not a feature

**Status:** design only, plus the one prerequisite safety fix (§1), which is
implemented and verified. Everything else here is unbuilt. The owner decides
whether it ships.
**Backlog item:** #99. Related: #103 (dead Auto-Mix toggle — corrected below,
it is not dead), #117 (pairing UX, not touched by this doc).
**Author:** planning agent, TASK #99.

**Working-tree note.** This branch (`staging/session-rebuild`) has dozens of
files modified by concurrent agents. Two of those files —
`SoundingTV.swiftpm/Sources/Views/Library/LibraryView.swift` and
`SoundingTV-iOS/Sources/LibraryBrowserView.swift` — reference a type
(`LibraryCache`) whose source file exists on disk
(`SoundingTV.swiftpm/Sources/Services/LibraryCache.swift`) but is registered
in **zero** `PBXSourcesBuildPhase` targets. That breaks the tvOS and iOS
builds independently of anything in this document — see §5. Not this task's
file, not fixed here; flagged so the build failures below are read correctly.

---

## 0. Verification ledger

Everything load-bearing, so it can be checked rather than trusted.

| # | Claim | Status | Evidence |
|---|---|---|---|
| V1 | **`MixEngine.swift` is compiled into the iOS target.** | Confirmed | Three `PBXBuildFile` entries for `MixEngine.swift` (`project.pbxproj`), one of which resolves through the iOS target's own `PBXSourcesBuildPhase`; and dispositively, `SoundingTV.swiftpm/Sources/Services/PlayerService.swift` (an iOS-target file — `SoundingTV-iOS/Sources/SoundingTViOSApp.swift:33` instantiates `PlayerService.shared` at app root) calls `MixEngine.shared` at 20+ call sites. If `MixEngine.swift` were not a target member, the iOS build would fail with "cannot find `MixEngine` in scope" — it does not (§5, `exit=65` is entirely a `LibraryCache` failure, zero `MixEngine`/`PlayerService` diagnostics anywhere in the log). |
| V2 | **`PlayerService` already drives `MixEngine.shared`.** | Confirmed | `PlayerService.swift`: arms it (`armMixSession()` at `PlayerService.swift:1974`, `MixEngine.shared.load(...)` at `:2014`), transports it (`play`/`pause`/`seek` at `:1246,1264,1265,1285`), owns the handover (`takeOverFromAVPlayer` at `:2055`, `handBackToAVPlayer`), and observes it (`observeMixEngine()` at `:2943`, subscribing to both `$decks` and `$lastError`). |
| V3 | **macOS already does local mixing with the same engine.** | Confirmed | `MacConsoleView.swift:88,245,837`, `MacDeckPanel.swift:39`, `MIDIMixerBridge.swift:66`, `SoundingMacApp.swift:269` all reference `MixEngine.shared` directly; `MacLibraryBrowserView.swift:99` loads straight onto it, bypassing `PlayerService` entirely (relevant to §1.3). Also independently reconfirmed by this session's own macOS build: **`BUILD SUCCEEDED`** against a from-scratch `-derivedDataPath`, with the AirPlay guard (§1) newly present in the shared file — see §5. |
| V4 | **The dead Auto-Mix toggle (#103) — is it actually dead?** | **Backlog claim does not hold. Corrected.** | `grep "SettingsStore" SoundingTV.swiftpm/Sources/Services/PlayerService.swift` returns **8 matches, not zero**: `:432, 1799, 1806, 1809, 3071, 3093, 3354, 3364`. More to the point, `PlayerService.observeAutoMixSetting()` (`:1805`) reads `SettingsStore.shared.djAutoMixEnabled` and — via `applyAutoMixSettingEnabled` → `applySessionEnabledTransition` (`:1819-1852`) — calls `armMixSession()` (`:1836`) exactly like the console's own `setDJSessionEnabled(true)` does. This is called unconditionally from `PlayerService.init()` at `:528`, which runs on every platform. **On the phone today, toggling "Auto-Mix" in Settings (`PhoneSettingsView.swift:839`) already arms `MixEngine.shared` and takes over from `AVPlayer` for ordinary listening — with no dedicated console UI to show it happening, and, until §1's fix, with no AirPlay guard either.** See §4 for what this means for scope. |
| V5 | **`DJControlView` (iOS) performs no local audio.** | Confirmed, backlog is right here | Read in full. Every control (`JogWheelView.onScrub`, `KnobControl.onChange`, `CrossfaderView.onChange`, hot cues, loop) calls a `RemoteQueueClient` method (`client.jog`, `client.setEQ`, `client.setCrossfade`, `client.cue`, `client.setLoop`, all in `DJControlView.swift`) — a Bonjour round-trip to the TV's `MixEngine`, per `RemoteQueueClient.jog(deck:bySeconds:)` at `RemoteQueueClient.swift:667`. No reference to `MixEngine`, `PlayerService`, or `AVAudioEngine` anywhere in the file. |
| V6 | **The AirPlay guard did not exist before this session.** | Confirmed | `PlatformAudioSession.isAirPlayRoute` (`AudioSessionCoordinator.swift:102,150`) was defined — with a doc comment already saying *"DJ mode must refuse to arm"* — but had **zero** call sites anywhere in the repo before this task (`grep -rn "isAirPlayRoute"` returned only its own two declarations). Exactly this project's documented signature defect: a control that exists and does nothing. |
| V7 | **`PhonePlaybackCoordinator` already carries a per-source DJ-live signal.** | Confirmed | `NowPlayingSnapshot.isDJEngineLive` (`PhonePlaybackCoordinator.swift:343`) is populated from `player.isMixEngineLive` when `activeSource == .thisDevice` (`:102`) and from the TV's own pushed `isDJEngineLive` when `.appleTV` (`:120`). A local console reading this coordinator (rather than re-deriving "am I mixing locally") already has the field it needs — see §4.1. |
| V8 | **Gesture synthesis is unavailable in this environment.** | Structural, not re-derived | Per CLAUDE.md: no `Simulator.app`, no `idb`, no `cliclick`, and `simctl` cannot synthesise a drag/scroll. Any plan step below that depends on validating a touch gesture (jog wheel scratch feel, knob drag inertia, crossfader throw) is labelled **[BLOCKED: no gesture synthesis]** rather than assumed working. |

---

## 1. The AirPlay guard — implemented and verified this session

This is not part of the plan; it is the one piece of code this task actually
shipped, because the backlog is explicit that it is a prerequisite, not a
nice-to-have: *"That guard must land before any local DJ mode ships."*

### 1.1 Where it lives, and why there

`PlatformAudioSession.isAirPlayRoute` (`AudioSessionCoordinator.swift:97-102`)
was already the correct cross-platform seam — coarse `AudioOutputKind`,
`.airPlay` mapped correctly on iOS/tvOS (`AVAudioSessionCoordinator.kind(for:)`,
same file) **and** on macOS (`kAudioDeviceTransportTypeAirPlay` →
`.airPlay`, `MacAudioSessionCoordinator.swift:303`). It was simply never read.

The guard now lives in `MixEngine.start()` (`MixEngine.swift:771`, guard added
at `:810-825`), not only in `PlayerService.armMixSession()`, for a reason V3
makes concrete: **the macOS Decks console loads straight onto
`MixEngine.shared` from `MacLibraryBrowserView.swift:99`, bypassing
`PlayerService` entirely.** A guard placed only in `armMixSession()` would
leave the Mac unprotected. `start()` is the one choke point every caller —
iOS/tvOS arming (`load()` → `start()`), the macOS console, and every deck
transport call (`play`, `seek`, `cue`) that finds the engine not yet
running — actually shares.

A second, fast-fail copy also sits in `PlayerService.armMixSession()`
(`PlayerService.swift:1996-2005`) purely as a courtesy: it refuses before
spending a download + decode on a track `start()` would refuse anyway. It is
explicitly documented in its own comment as not the safety boundary.

### 1.2 Behaviour chosen, and why

**Refuses; does not force the route back to local.** A new
`MixEngineError.airPlayRouteActive` case (`MixEngine.swift:164`, description
at `:190-191`) carries: *"DJ mode isn't available over AirPlay — beat-matching
needs a local output with predictable latency. Switch to a local speaker to
mix."* This reuses machinery that already existed and already worked for
every other engine failure:

- Fresh arm attempt on AirPlay → `MixEngine.load()`'s existing `guard start()
  else { throw lastError ... }` (`MixEngine.swift`, inside `load(url:into:...)`)
  throws the new case → `PlayerService.armMixSession()`'s existing `catch`
  sets `mixEngineState = .unavailable(reason)` (`PlayerService.swift:2048`) —
  the same enum the console already renders reasons from.
- **Mid-session route change to AirPlay** — the case that actually matters for
  the Sonos Arc reference setup — is also covered, because
  `handleConfigurationChange()` (`MixEngine.swift:893-945`) unconditionally
  calls `engine.stop()` before rewiring and then calls `start()` again
  (`:935`) to resume. That `start()` call now lands on the same guard, so a
  session that was mixing locally and then has its route changed to AirPlay
  **stops mixing and says why**, via the existing `$lastError` →
  `mixEngineErrorDidChange(_:)` (`PlayerService.swift:2964`) plumbing — no new
  wiring needed for that path either.

Refusing rather than force-switching the route was chosen because: (a) the
project's own documented failure mode is silently doing nothing, which a
forced route change would just relocate — the user would see DJ mode "work"
while their explicitly-chosen Sonos output got yanked out from under them,
which CLAUDE.md's own reasoning (and the task prompt) calls out as hostile;
(b) there is no API to make AirPlay's receiver-side buffering disappear, so
"force local" is the only way to make DJ mode functional at all, and doing
that invisibly is worse than saying no.

### 1.3 Reachability — the call sites, outside `MixEngine.swift`

- `PlayerService.swift:2014` — `try await engine.load(...)` inside
  `armMixSession()`'s arm `Task`. This is the iOS/tvOS/console entry point;
  `load()` calls the guarded `start()` internally.
- `PlayerService.swift:1246` — `MixEngine.shared.play(deck: liveDeck)`, which
  also calls the guarded `start()`.
- `SoundingTV-macOS/Sources/MacLibraryBrowserView.swift:99` —
  `MixEngine.shared.load(...)`, the macOS Decks console's own arm path,
  independent of `PlayerService`. Confirms the guard is not iOS/tvOS-only.
- `MixEngine.swift:935` — `handleConfigurationChange()`'s own `start()` call,
  for the mid-session route-change case (§1.2).

### 1.4 What this guard is *not*

It does not touch Bluetooth, USB, or wired headphone routes — only
`.airPlay`. It does not attempt to distinguish AirPlay 1 from AirPlay 2, or a
low-latency AirPlay receiver from a high-latency one; `AudioOutputKind` is
deliberately coarse (`AudioSessionCoordinator.swift:38-41`) and this guard
inherits that. If a future receiver genuinely has low enough latency to
beat-match through, that would need a new, narrower signal — not a reason to
loosen this one today.

---

## 2. What exists today vs. what a local DJ mode needs

| Layer | Exists | Missing |
|---|---|---|
| Engine | `MixEngine` (two decks, EQ, filter, time/pitch, crossfader) — compiled into iOS (V1), already exercised on iOS today via Auto-Mix (V4) | Nothing engine-side. This is the backlog's strongest claim and it holds. |
| Arming | `PlayerService.armMixSession()` — platform-agnostic, already runs on iOS | Nothing — it already works, guarded now (§1) |
| Manual control surface | `DJControlView` — full console UI, but wired to `RemoteQueueClient` (remote to the TV), not `MixEngine.shared` (V5) | A **second** wiring of the same console views to local transport, or a mode switch inside the one view — see §4.2 |
| "Which device" arbitration | `PhonePlaybackCoordinator.activeSource` / `isDJEngineLive` (V7) | A rule for what `DJControlView` should show when local DJ mode exists as an option — currently the coordinator's rule ("local wins the instant anything plays locally") was written for ordinary playback, not for two *DJ* consoles that could both plausibly be "the" mix |
| Safety | AirPlay guard | Shipped this session (§1) |
| Settings UI | `djAutoMixEnabledBinding` toggle, already live (V4) | A way to tell the user *what* it does now that it's not hypothetical — see §4.3 |

---

## 3. The coexistence problem — the part that is not just "wire up a UI"

`DJControlView` is a remote control. `PhonePlaybackCoordinator` is described
in its own header as **the one place that decides local-vs-TV**, specifically
so "a Play button [never] ends up pointed at a different device than the
title above it." Local DJ mode is a second live audio engine that can be
*local*, on the same device the remote-control console already assumes is
*the TV*. Three shapes were considered:

**A. Same view, mode-switched.** `DJControlView` grows a local/remote branch
keyed off `PhonePlaybackCoordinator.activeSource`, and every `onChange`
closure dispatches to either `client.setEQ(...)` or
`MixEngine.shared.setEQ(...)` depending on which. This is the shape that
actually respects the "one decision point" rule — the view still never
decides for itself which device it's driving, it just asks the coordinator
and the coordinator's answer picks the closure. Cost: every one of the ~15
control closures in `DJControlView` needs the branch, and `DJStatePayload`
(the TV's pushed snapshot shape) and `MixEngine.DeckState` (the local shape)
are different types that would need a small adapter so the view can keep
reading one shape.

**B. Separate view, separate tab entry.** A `LocalDJControlView` that reads
`MixEngine.shared` directly, entered from a different affordance than the
Apple TV tab's "DJ Console" link. This avoids touching the existing remote
console at all, but **directly breaks the stated rule**: now there are two
places a view decides "am I local or remote," and nothing stops them from
both claiming to be live at once if the user has DJ Auto-Mix on locally
*and* a TV console open — which, per V4, is already a reachable state today.

**C. Do nothing UI-side; leave Auto-Mix as the only local entry point.**
Given V4, this is not "shipping nothing" — a local DJ *experience* already
exists (crossfaded ordinary listening), it is just headless. This is the
cheapest option and arguably honest: it doesn't invent manual local mixing
controls, it just stops mis-describing the current state as fully dead.

**Recommendation for the owner to weigh, not a decision made here:** (A) is
the only shape that doesn't violate `PhonePlaybackCoordinator`'s own
documented invariant, but it is real work across a file already 1,485 lines
long. (C) costs nothing but doesn't deliver "local DJ mode" as the backlog
title frames it — it delivers "the thing #103 already quietly built, now
named honestly." That gap between the backlog's framing and what's actually
buildable cheaply is the single most important thing for the owner to see
before sizing this.

---

## 4. Decision points — genuinely the owner's

### 4.1 Which of A/B/C in §3

Sizing differs by roughly an order of magnitude between C (documentation +
maybe a status label) and A (a real second transport path through an
already-large view). B is included only to show why it's the wrong shape, not
as a live option.

### 4.2 Does manual local mixing exist at all, or only Auto-Mix?

`MixEngine`'s manual controls (per-deck EQ, filter, jog, hot cues, loops) are
real and compiled in. But **nothing on iOS today lets a user manually reach
them** — `djAutoMixEnabledBinding` only ever asks for an *automatic* crossfade
between whatever the queue already has queued. Building manual local mixing
means building the equivalent of `DJControlView`'s controls against
`MixEngine.shared` instead of `RemoteQueueClient` — which is exactly §3's
option A/B distinction, restated as "is there a manual mode at all."

### 4.3 What Settings should say, now that Auto-Mix is not dead

`PhoneSettingsView.swift:839`'s "Auto-Mix" toggle currently reads like every
other quiet preference on that screen. Per V4 it silently swaps the audio
render path from `AVPlayer` to `AVAudioEngine` mid-session. That's a bigger
behavioural claim than the current copy makes, and the owner should decide
whether the toggle needs its own explanation, a "what does this do" link, or
nothing — it has apparently been shipping invisibly already.

### 4.4 Cue/headphone split

Out of scope for this document — `AudioSessionCoordinator.swift:73-76,107`
already answers "is a separate cue bus physically possible" via
`maximumOutputChannels >= 4`, and on a phone with one built-in output pair
the answer is always no. Noted only so the owner doesn't expect it as part
of this feature; it would need external hardware regardless of any UI work
here.

---

## 5. Verification — real exit codes, fresh DerivedData each time

| Scheme | Destination | DerivedData | Exit | Result |
|---|---|---|---|---|
| `SoundingTV` (tvOS) | `generic/platform=tvOS` | fresh `mktemp -d` (twice, to rule out a fluke — see below) | **65** both times | **Fails, pre-existing, unrelated to this task.** All 4 distinct errors are `cannot find 'LibraryCache' in scope` in `SoundingTV.swiftpm/Sources/Views/Library/LibraryView.swift:666,902,904,916`. Zero errors anywhere touching `MixEngine.swift`, `PlayerService.swift`, or `AudioSessionCoordinator.swift`. |
| `SoundingTV iOS` | `id=032145E9-…` (iPhone 17 Pro Max, iOS 27.0 sim) | fresh `mktemp -d` | **65** | **Fails, same root cause, iOS's own file:** `cannot find 'LibraryCache' in scope` in `SoundingTV-iOS/Sources/LibraryBrowserView.swift:677,856,858,870,872`. Same story: zero diagnostics in any file this task touched. |
| `SoundingTV macOS` | `platform=macOS,arch=arm64`, signing disabled | fresh `mktemp -d` | **0** | **BUILD SUCCEEDED.** This is the one target where the guard's own file (`MixEngine.swift`) is exercised end-to-end alongside real Decks console call sites (`MacLibraryBrowserView.swift`, `MacConsoleView.swift`, `MacDeckPanel.swift`), and it compiles and links clean. `LibraryCache` never enters this build (`grep -rln "LibraryCache" SoundingTV-macOS/Sources/*.swift` — zero hits), which is exactly why this target alone is unaffected by the other agent's breakage. |

**Root cause of the two failures, confirmed, not guessed:**
`SoundingTV.swiftpm/Sources/Services/LibraryCache.swift` (an `actor
LibraryCache`, real type, on disk, unmodified per `git status`) has **zero**
`PBXBuildFile`/`PBXSourcesBuildPhase` entries in `project.pbxproj`
(`grep -c "LibraryCache.swift" project.pbxproj` → `0`). This is a different,
concurrent backlog item's unregistered new file — exactly the failure mode
CLAUDE.md's own build notes describe ("Unregistered-but-referenced new files
… is the common one here, since agents may not touch the project file"). It
is not owned by this task, not caused by this session's edit, and not fixed
here — `project.pbxproj` registration is explicitly the main session's job,
per the ground rules this task was launched under. Flagging it here is the
whole point of reporting honestly rather than declaring victory on a build
that was never green for a reason unrelated to the change under review.

**What this does and does not prove about §1's guard specifically:** the
macOS green build proves `MixEngine.swift` (with the new
`MixEngineError.airPlayRouteActive` case and the `start()` guard) and
`PlayerService.swift` (with the new pre-check in `armMixSession()`) both
compile and link correctly, in the one target unaffected by the orthogonal
`LibraryCache` breakage. It does not prove the iOS or tvOS targets compile
these two files cleanly in isolation, because the build never got far enough
past `LibraryView.swift`/`LibraryBrowserView.swift` to say. Given `MixEngine`
and `PlayerService` are the *same source files* across all three targets
(V1–V3) and the language features used in the guard (a stored enum case, a
string description, an `if`/`guard` against an existing cross-platform
static) are not platform-conditional in any way, there is no structural
reason to expect a different result — but that is an inference, not a
measurement, and is reported as such.

---

## 6. What could not be verified in this environment

- **Any touch-gesture behaviour** — jog wheel scratch feel, knob drag
  inertia, crossfader throw, hot-cue long-press. Per V8, this environment has
  no `Simulator.app`, no `idb`, no `cliclick`; `simctl` cannot synthesise a
  drag or scroll. Any future implementation of §3's option A would need this
  validated by a human on real hardware or the Simulator app before shipping,
  not assumed from reading `DJControlView`'s gesture code.
- **Whether `handleConfigurationChange()`'s route-change path (§1.2) actually
  fires for an AirPlay-specific transition**, as opposed to only for HDMI/
  device-disappearance cases it was originally written for. The mechanism —
  `engine.stop()` then rewiring then `start()` — is real and reread directly
  from `MixEngine.swift:893-945`, and the guard demonstrably fires whenever
  that path runs. What's unverified is whether *every* way of switching to an
  AirPlay route on iOS/tvOS reliably raises `AVAudioEngineConfigurationChange`
  in the first place — that would need a physical device and a real AirPlay
  receiver (a Sonos Arc, per the reference setup) to observe, which this
  environment does not have. If it does not fire for some transition, the
  cold-start guard (§1.1, the common case — arming while already on AirPlay)
  is unaffected; only the live, mid-session hand-off case would be less
  airtight than described.
- **Whether the iOS/tvOS builds are otherwise green once `LibraryCache` is
  registered.** Not re-attempted after the fact — that would mean editing
  `project.pbxproj`, which this task is explicitly forbidden from doing.
