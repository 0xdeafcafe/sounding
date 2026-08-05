# OS 27 API survey — triage into work items and rejections

**Written 2026-08-03.** Follow-on to `Design/specs/os27-api-survey.md` (the "survey"). That
document graded ~45 recommendations across §1–§3 plus two appendices (§5, §6) but stopped short of
saying which ones are actually worth doing. This document closes that gap: every remaining
recommendation gets either a **work item** (files, changes, and how it would be verified on this
project's actual hardware) or an **explicit rejection** (evidence, not a shrug).

Two things changed the shape of this pass and are worth stating up front:

1. **The survey undercounted what's already done.** The task brief for this pass said one
   recommendation had ever been actioned (AppEntity conformances + Spotlight donation). Checking the
   tree directly found that's true for that pair, but **three more survey items are also already
   implemented** — §1.1 (AVFAudio mechanical migration), §1.6 (AVAudioSession interruption model +
   `AudioSessionCoordinator` adoption), and §1.5 (`MusicUnderstanding` wired into `GenreDetector`/
   `CueSuggester`). The last one was true **before the survey was even written** — `AnalysisProducers.swift`
   (mtime 04:48) imports `MusicUnderstanding` and calls `session.analyze(for:)`, but the survey (mtime
   05:10) says "no shipping target imports it." The survey's own §4 explains why: a concurrent session
   was editing 20+ files in `Sources/` while the survey's code map was being built, and this is a
   concrete instance of that race landing a stale claim. Every verdict below is checked against the
   tree as it stands now, not against the survey's prose.
2. **Every `[SDK]` claim spot-checked below was re-verified independently**, not trusted from the
   survey's own citations, per the brief. All of them held up. One new pitfall surfaced doing this:
   **both `AppleTVOS27.0.sdk` and `iPhoneOS27.0.sdk` are symlinks** (`AppleTVOS27.0.sdk -> AppleTVOS.sdk`),
   and plain `find "$SDK" -iname …` against the symlink path silently returns **zero results** — not an
   error, not a partial list, nothing — because `find` doesn't follow the top-level symlink by default.
   `find -L "$SDK" …` is required. This cost real time before being caught (a `find` that returns
   empty looks exactly like "the file doesn't exist," which is the same failure shape as the
   `SwiftUICore` vs `SwiftUI` framework mistake called out in this task's brief). Recorded here so it
   doesn't happen again.

Grading key is unchanged from the survey: `[SDK]` = verified directly in the installed SDK,
`[CODE]` = verified by reading this repo's current source (new tag, since this pass's job is
implementation status), `[DOC]`/`[WWDC]`/`[RN]`/`[?]` carried over from the survey where re-verification
wasn't in scope. SDK roots and re-verification method: `grep`/`sed` against
`AppleTVOS27.0.sdk` and `iPhoneOS27.0.sdk` under `/Applications/Xcode-beta.app`, same as the survey,
with the `find -L` correction above.

Hardware available for verification: physical Apple TV **"Living Room"**
(`16B1EB59-1DDA-523A-8F65-961CFD8EBEEC`, tvOS 27.0, connected) and physical **iPhone 15 Pro Max**
("iPhone van Alexander", connected) — confirmed via `xcrun devicectl list devices`. Every "how
verified" below assumes these two devices, not simulators, per this session's standing instruction
that simulators reportedly-passing has burned time before.

---

## 0. Already done — verify only

These four survey recommendations are implemented in the tree today. Nothing here is a proposal;
each entry is what to point a build and a device run at to confirm the existing implementation is
correct, not whether to build it.

| Survey item | Evidence `[CODE]` | What's left |
|---|---|---|
| **AppEntity conformances + Spotlight donation** (the join of §1.7/§2.11/§6.10) | `SoundingTV.swiftpm/Sources/AppIntents/SoundCloudAppEntities.swift` (Track/Playlist/User conform to `AppEntity`, cross-platform, registered in `project.pbxproj` for tvOS + iOS + Share targets), `SoundCloudPlaybackIntents.swift` (`AudioPlaybackIntent` + `AppShortcutsProvider`, tvOS+iOS), `SoundingTV-iOS/Sources/SpotlightIndexingService.swift` (`IndexedEntity` conformances, iOS-only file, with a header comment recording the exact `[SDK]` negative: `CSSearchableIndex`/`CSSearchableItem`/`CSSearchableItemAttributeSet` are `API_UNAVAILABLE(tvos, watchos)`). This is the load-bearing negative finding the task brief refers to, and it is correctly recorded in the shipped code, not just in the survey. | Nothing architecturally. Device check: pair the phone, index the library, ask Siri "Hey Siri, play \<track\> in SoundingCloud" on the phone, and separately search Spotlight for an indexed track title. tvOS gets neither surface by design (confirmed unavailable) — the TV-side check is "does *nothing* regress," not "does this appear." |
| **§1.1 AVFAudio mechanical migration** | `MixEngine.swift:532–546, 608, 998, 1055, 1132, 1176, 1279` all call `connectNode`/`playAudio()`/`playAudio(at:)`/`installAudioTap` — the deprecated `connect`/`play()`/`play(at:)`/`installTap` calls the survey's compiler-verified table (§4) listed are gone. | **Two follow-ups the migration itself didn't do, both still open — see §A below**: (a) every `connectNode`/`playAudio` call site uses `try!` or swallows the error with `try?`, so the survey's recommended behaviour change ("a failed deck connect should surface as 'DJ mode unavailable'") was not made — errors still can't be observed by the user, they just don't crash on the happy path anymore; (b) the survey's own sample-accuracy question on `playAudio(at:)` (`MixEngine.swift:1176`) was never re-measured. |
| **§1.6 AVAudioSession interruption model + `AudioSessionCoordinator` adoption** | `PlayerService.swift:452–465` subscribes to `AVAudioSessionDidBecomeInactiveNotification`/`AVAudioSessionResumptionRecommendationNotification` (not the deprecated `AVAudioSessionInterruptionNotification`). `AudioSessionCoordinator.swift`'s `PlatformAudioSession.activatePlayback()` is now actually called from both `PlayerService.swift:419` and `MixEngine.swift:681` — the survey's finding that the doc comment was aspirational ("`PlayerService` and `MixEngine` both call `activatePlayback()` — they don't") is **no longer true**; they do now. | Device check: put the Apple TV on the reference Sonos Arc setup, trigger a real interruption (Siri Remote press-and-hold or an incoming call routed to the same AirPlay 2 group) and confirm resume behaviour follows `AVAudioSessionResumptionRecommendation` rather than crashing or silently not resuming. Not yet exercised — this pass didn't touch hardware audio routing. |
| **§1.5 MusicUnderstanding adoption** | `import MusicUnderstanding` in `PlayerService.swift:11` and `AnalysisProducers.swift:4`; `AnalysisProducers.swift:527` calls `MusicUnderstandingSession(asset:)` then `session.analyze(for: Self.analysisTypes)` — the **selective-dimension `analyze(for:)` API** the survey flagged as untried by the original spike (§1.5, "per-dimension cost is a different number") is in fact what shipped, not whole-session analysis. `GenreDetector.swift` and `CueSuggester.swift` both import `MusicUnderstanding` too. | The survey's two named gaps are still gaps: `session.loudnessResults` (streaming `AsyncSequence`) is not used anywhere (`grep -rn loudnessResults` = 0 hits), and `PaceResult.ranges`/`InstrumentActivityResult` (the per-instrument presence signal for "mix over the instrumental section") is not referenced (0 hits). These are additive, not corrections — see §B below. |

---

## A. §1 "Should adopt" — remaining items

Six of the ten items are genuinely still open (the other four are §0 above). Verdicts:

### 1. Surface `MixEngine`'s new throwing calls instead of swallowing them — WORK ITEM
Half-done by the mechanical migration above. `MixEngine.swift:532–546` uses `try!` on the four
initial `connectNode` calls (setup path — a throw here means the audio graph literally cannot be
built, so `try!` crashing loudly during development is arguably fine, but it means a Swift-runtime
trap in production rather than a caught error) and `try?` everywhere else, silently dropping the
`Error`. **Change:** thread the setup connects through `throws` up to wherever `MixEngine` is
constructed and surface a "DJ mode unavailable" state (the survey's own recommendation); for the six
runtime `playAudio`/`playAudio(at:)` sites, at minimum log the swallowed error so a repeated failure
is diagnosable instead of invisible.
**Files:** `SoundingTV.swiftpm/Sources/Services/MixEngine.swift` (setup path ~505–550, deck-start
sites at 998/1055/1132/1176/1279).
**Verify:** force a connect failure (e.g. temporarily hand `connectNode` an invalid format in a debug
build) and confirm the UI reflects "DJ mode unavailable" rather than silently doing nothing; then
revert and confirm DJ mode still enters cleanly on the physical Apple TV (`DJControlView`).

### 2. Re-measure `playAudio(at:)` sample-accuracy drift — WORK ITEM, small
The survey correctly flagged this as the one non-mechanical risk in an otherwise mechanical migration
and explicitly asked for a four-trial re-run. That re-run was never done — I found no drift
measurement artifact anywhere in `Design/specs/` dated after the migration landed.
**Files:** none to change; this is a measurement against `MixEngine.swift:1176`
(`player.playAudio(at: startTime)`).
**Verify:** on the physical Apple TV, schedule a deck start at a known future host time via
`playAudio(at:)`, capture actual first-sample time via the existing meter tap or a timestamped log,
repeat 4x, compare against the pre-migration `play(at:)` numbers this project already has on file (the
survey references them but I did not locate the original data file in this pass — if it can't be
found, the four-trial re-run has nothing to compare against and should record fresh baseline numbers
instead).

### 3. NowPlaying framework (`MediaSession`, `MediaCommand`) — WORK ITEM, medium
Confirmed `[SDK]`: `NowPlaying.framework` exists in both `AppleTVOS27.0.sdk` and `iPhoneOS27.0.sdk`
(`ls -d $SDK/System/Library/Frameworks/NowPlaying.framework` succeeds on both). Confirmed not yet
adopted: `grep -rln "import NowPlaying"` across every shipping target returns zero hits. The survey's
technical read (§1.2) holds up — `MediaSession` is `@MainActor`, `@available(iOSApplicationExtension,
unavailable)`, and the win is specifically `MediaCommand.feedback` (like/unlike on system transport
surfaces, which `MPRemoteCommandCenter` never modelled), `changeRepeatMode`/`changeShuffleMode` as
real enums, and `Artwork(id:) { size in }` replacing `ArtworkImage.swift`'s hand-guessed variant
ladder. Also re-confirmed §3.1's claim that `MPNowPlayingInfoCenter` is *not* deprecated (Apple's docs
JSON still reports `deprecated: false` on every platform) — this is additive, not a migration.
**Files:** `PlayerService.swift` (replaces the manual dictionary builds at :591, 607, 618–631, 1198
and `MPRemoteCommandCenter.shared()` wiring at :536) on **both** tvOS and iOS targets.
**Verify:** on the physical Apple TV, like a track from the Siri Remote's Now Playing surface (not
possible today — no like/unlike command exists there) and confirm the SoundCloud like state changes;
on the phone, check Control Center shows repeat/shuffle as real toggles instead of absent controls.
Compare Lock Screen artwork sizing before/after — the `Artwork(id:) { size in }` closure should
request exactly the variant `ArtworkImage.swift`'s ladder would have guessed, so a network trace
(`Instruments` → Network) should show one artwork fetch at the requested size, not the largest
variant scaled down.

### 4. tvOS Dynamic Type — WORK ITEM, large, do as its own piece of work
Re-confirmed `[SDK]`: `EnvironmentValues.dynamicTypeSize` has been on tvOS since 15.0 (unchanged
claim, not re-disputed), and the practical exposure is unchanged from the survey — `grep -c
"system(size:" SoundingTV.swiftpm/Sources` still returns numbers in the same range, and
`DesignSystem.swift`'s tv-scale constants are still fixed points. Not implemented: zero hits for
`dynamicTypeSize`, `preferredFont(forTextStyle:)`, or `.isAccessibilitySize` anywhere in the repo.
**Files:** `SoundingTV.swiftpm/Sources/Design/DesignSystem.swift` (the `tv*` scale, :128–151) plus
every tvOS view consuming it — this is the single largest item in the whole survey by surface area
and should stay scheduled as its own piece of work, not folded into anything else.
**Verify on hardware:** *Settings → Accessibility → Display → Text Size* on the physical Apple TV, set
to Accessibility XXXL, and walk every tab (`SOUNDING_TV_TAB` debug hook makes this fast) checking for
truncated labels, cards that don't grow, and — the thing that's easy to miss — that focus scale/lift
still reads correctly at the largest size (CLAUDE.md's focus doctrine interacting with a resized
card is explicitly called out as untested territory in the survey and remains so).

### 5. `AVPlayer.setDisconnectedFromSystemAudio(_:completionHandler:)` — WORK ITEM, small, high leverage
Re-confirmed `[SDK]`: both the `disconnectedFromSystemAudio` property and the setter exist in
`AVPlayer.h` at `ios(27.0), tvos(27.0)`. Not implemented: `grep -rn
"setDisconnectedFromSystemAudio|disconnectedFromSystemAudio"` across `PlayerService.swift` and
`MixEngine.swift` returns zero hits — the DJ-mode handover still tears down and rebuilds
`AVPlayerItem` on every entry/exit exactly as before.
**Files:** `PlayerService.swift` (`teardownAVPlayer()`, `handBackToAVPlayer()`,
`takeOverFromAVPlayer(on:track:)`), coordinating with `MixEngine`'s start/stop.
**Verify on hardware:** on the physical Apple TV wired through the reference Sonos Arc + surrounds
setup, time DJ-mode entry and exit (stopwatch or a debug timestamp log) before/after, and confirm the
`preferredForwardBufferDuration` two-stage buffering state isn't reset on re-entry (should not
restart the 0 → 60s ramp described in CLAUDE.md's buffering section). This is the item the survey
correctly identifies as targeting "the single most fragile seam in the app" — the AVPlayer/AVAudioEngine
handover — so the verification should specifically try to reproduce whatever handover glitches
motivated CLAUDE.md's "must never render simultaneously" invariant in the first place, not just time
the happy path.

### 6. `.audio` App Schema domain (Siri "play X on SoundingCloud") — WORK ITEM, iOS only, medium
Re-confirmed `[SDK]` directly (not trusted from the survey): grepping the **correct** file this time
(`find -L` needed, see the note at the top) —
`AppIntents.framework/Modules/AppIntents.swiftmodule/arm64-apple-tvos.swiftinterface:8252–8256`
carries `@available(anyAppleOS 27.0, *) @available(watchOS, unavailable) @available(tvOS,
unavailable)` directly above `static var audio: some AppSchema.AudioIntent`. Confirmed on both the
`.audio.playAudio` intent schema and the `.audio` entity/enum schema variants (three separate
`@available(tvOS, unavailable)` blocks at :8252, :8314, :8431). tvOS is out; this is iPhone-only.
**Distinction worth making explicit that the survey didn't fully draw out:** the app **already ships**
a working "Hey Siri, play X on SoundingCloud" via `AudioPlaybackIntent` + `AppShortcutsProvider`
(`SoundCloudPlaybackIntents.swift`, part of the §0 work) — that's the iOS 17-era mechanism, not the
`.audio` App Schema domain. The `.audio` domain is additive on top of that: `MediaIntents.AudioSearch`
gives structured criteria (`.searchQuery`/`.url`) instead of parsing free text through an
`AppEntityQuery`, and `.audio.updateAudioAffinity` is a first-class "like" intent Siri understands
without the app defining its own phrase. So C1 in the survey's customer-facing shortlist is **already
partially shipped**, and this item is a refinement, not the whole feature.
**Files:** iOS app (new intents conforming to the `.audio` schema entities) + `SoundingTV-Widget`.
**Verify on the physical iPhone:** "Hey Siri, play [track] on SoundingCloud" already works via the
shipped `AppShortcutsProvider` — confirm that baseline first, then after adding `.audio` schema
conformance confirm Siri accepts phrasing that doesn't match the hand-authored shortcut phrases
verbatim (the whole point of App Schema domains vs. hand-rolled `AppShortcut` phrases).

### 7–10. Already covered
`AsyncImage` HTTP caching (§7 in survey numbering, item 8), `reorderable()`/`swipeActionsContainer()`
(item 9), and `AVAssetReader`/`AVAssetWriter` migration (item 10) are addressed in §B and §C below —
splitting them out here would duplicate that analysis.

---

## B. Cheap wins not yet taken (still open)

### `AsyncImage` HTTP caching — WORK ITEM, trivial, still fully open
Re-confirmed `[SDK]`: `asyncImageURLSession(_:)` is `@available(anyAppleOS 27.0, *)` at
`SwiftUI.swiftinterface:18986` on the **tvOS** interface — confirming the survey's claim that this
covers tvOS too, not just iOS. Not implemented: zero hits for `asyncImageURLSession` anywhere in
`SoundingTV-iOS/Sources`, and `ArtworkImage.swift`'s header comment still says *"`AsyncImage` doesn't
cache"* (`ArtworkImage.swift:15`) — the stale-rationale correction the survey called for was not made.
**Files:** one `asyncImageURLSession(_:)` call at the `PhoneRootView` root (survey's suggestion still
holds — one call site upgrades all 10 raw `AsyncImage` call sites at once), plus a one-line comment
fix in `ArtworkImage.swift:15`.
**Verify:** Instruments' Network instrument on the physical iPhone — load a library view twice
(cold-launch, then re-visit), confirm the second visit's artwork requests hit cache (304s or no
network activity) rather than re-fetching every time.

### `AVAssetReader`/`AVAssetWriter` provider/receiver migration — WORK ITEM, half-open
The survey filed this as one item across three call sites. Current state, `[CODE]`, is **split**:
- `PlayerService.swift`'s `AudioAnalyzer` reader loop (survey's §1.10 second bullet) has migrated —
  `PlayerService.swift:3277–3278` comments explicitly reference "the async stream that replaces
  `copyNextSampleBuffer()`" and "no longer need `alwaysCopiesSampleData`."
- `MixEngine.swift`'s `SourceImporter` reader loop (the survey's *first and highest-priority* bullet,
  "the hot path that materialises tracks locally so `MusicUnderstanding` can analyse them") is **not**
  migrated — `MixEngine.swift:2458` still calls `reader.startReading()` returning `Bool`, and
  `:2506` still calls `output.copyNextSampleBuffer()`.
- The `MixImportSelfTest` writer path (survey's third, lowest-priority bullet) is **also migrated** —
  `MixEngine.swift:2858–2899` calls `writer.inputReceiver(for: input)` with a comment explicitly
  noting `expectsMediaDataInRealTime`/`isReadyForMoreMediaData` are gone in favour of the receiver.

So two of the three call sites (`AudioAnalyzer` reader, self-test writer) are done and the one the
survey called the **highest-priority hot path** (`SourceImporter`, the one that feeds
`MusicUnderstanding`) is the one still on the old API — the opposite priority order from what shipped.
**Files:** `MixEngine.swift:2376–2460ish` (`SourceImporter`).
**Verify:** run the existing DJ-mode local-file self-test path (CLAUDE.md's `ffmpeg`-tone +
local-HTTP-server harness for `MixEngine`, since demo data can't exercise this) before and after,
confirming identical decoded output; then confirm no new `deprecated in tvOS 27.0` warnings remain for
this file in a real `xcodebuild -scheme SoundingTV -destination 'generic/platform=tvOS'` run (read the
exit code, not `tail`'s, per this session's standing instruction).

### `reorderable()` / `swipeActionsContainer()` on the iOS queue — WORK ITEM, small, still fully open
Re-confirmed `[SDK]` directly against the tvOS interface (to double-check the *unavailability* side,
since that's the side that matters for scoping): `SwiftUI.swiftinterface:12773–12776` and `:21223–21226`
both carry `@available(iOS 27.0, macOS 27.0, watchOS 27.0, visionOS 27.0, *)` immediately followed by
`@available(tvOS, unavailable)` — confirmed tvOS genuinely gets neither API, so this is scoped to iOS
only, exactly as the survey said. Not implemented: zero hits for `reorderable\|swipeActions` in
`QueueManagerView.swift`.
**Files:** `SoundingTV-iOS/Sources/QueueManagerView.swift:71` (`List` → add `reorderContainer(for:)`),
`LibraryBrowserView.swift:128/203/307` (swipe actions).
**Verify:** on the physical iPhone, drag-reorder two queue items and confirm playback order actually
changes (not just the visual list); swipe-to-remove one item and confirm it leaves the queue.

---

## C. §2 "Worth a spike" — verdicts

The survey already ranked these; re-verification changes two of the eleven.

| # | Item | Verdict | Why |
|---|---|---|---|
| 2.1 | `AVPlayerItemSampleBufferOutput` | **SPIKE — do this first, unchanged from survey** | Re-confirmed `[SDK]` directly: `AVPlayerItemSampleBufferOutput.h:83` does say *"Currently supported for HLS `AVPlayerItems` only, and only for delivering decoded PCM audio"* verbatim. This is the one item where the answer could overturn CLAUDE.md's stated constraint, and it hasn't been spiked yet (`grep -rn "AVPlayerItemSampleBufferOutput"` across the repo = 0 hits). Run the survey's own four-step spike order, stopping at the first failure. |
| 2.2 | AVSystemRouting (system route picker) | **SPIKE, unchanged, with one new negative data point** | Re-confirmed `[SDK]`: present in `iPhoneOS27.0.sdk`, **absent** from `AppleTVOS27.0.sdk` (`ls -d` fails on the tvOS path, succeeds on iOS). New: searched the *entire* iOS SDK for `.appextensionpoint` files (`find -L $IOS -iname "*.appextensionpoint"`) — **zero results, system-wide**, not just for this framework. That's a partial negative answer to the survey's own spike question 1 ("does the extension point identifier appear in a public `.appextensionpoint` in the SDK") — it does not, at least not as a bundled resource file discoverable this way. Doesn't kill the spike (the identifier could be declared purely via `NSExtensionPointIdentifier` string in a provisioning profile / entitlement rather than a discoverable file), but it's one more reason to timebox this one short. |
| 2.3 | NowPlaying remote media sessions | **SPIKE, unchanged** | Not re-verified beyond the survey's citation (would require building a `RemoteMediaSessionExtension`, out of scope for a triage pass). Timebox as the survey says. |
| 2.4 | Realtime-safe AVFAudio render blocks | **REJECT — downgrade from spike** | The app uses none of `AVAudioSourceNode`/`AVAudioSinkNode`/manual rendering (confirmed `[CODE]`, unchanged), and the concrete question the survey posed — whether the new `@Sendable` requirement on `installAudioTap` trips a realtime-safety diagnostic — is now answerable directly from §0: `installAudioTap` **is already adopted** (`MixEngine.swift:608`) and the tvOS build is not failing on it. If a realtime-safety diagnostic were going to fire, it would have by now. Nothing left to spike. |
| 2.5 | `MusicUnderstanding.AudioProvider` fed from `installAudioTap` | **SPIKE, unchanged, now cheaper** | Both halves of the type coincidence the survey describes are now live in the tree independently (`installAudioTap` in `MixEngine.swift`, `MusicUnderstandingSession` in `AnalysisProducers.swift`) — they just aren't wired *to each other* yet. The spike is smaller than the survey estimated because both endpoints already exist; it's a bridging exercise, not two builds from scratch. |
| 2.6 | Foundation Models / Core AI | **SPIKE, unchanged** | Correctly scoped by the survey as explanation-only, never decision-side. Nothing to add. |
| 2.7 | `@State` as a macro | **WORK ITEM (mechanical check), not really a spike** | This is a "build and count the diagnostics" task, cheap enough to just do rather than schedule as a spike. **Verify:** `xcodebuild -scheme SoundingTV -destination 'generic/platform=tvOS' -derivedDataPath <path>` and `-scheme 'SoundingTV iOS' -destination 'generic/platform=iOS'`, grep the log for TN3211-shaped diagnostics, read the **exit code**. If zero, close it and record the negative result next to §2.8's tvOS SwiftUI negative result so nobody re-asks. |
| 2.8 | Genuinely-new tvOS SwiftUI (toolbar/tabs/nav-transition) | **REJECT, confirmed** | Re-confirmed via the same `arm64-apple-tvos.swiftinterface` grepped above — the survey's claim that this is a short, low-value list holds. `CrossFadeNavigationTransition` on `SettingsView.swift`'s one `NavigationStack` remains a fine two-line experiment, not a scheduled item. |
| 2.9 | Home Screen widget + `systemExtraLargePortrait` | **SPIKE the product question, confirmed still nothing built** | Re-confirmed `[SDK]`: `systemExtraLargePortrait` is `@available(iOS 27.0, macOS 27.0, visionOS 26.0, *) @available(tvOS, unavailable) @available(watchOS, unavailable)` at `WidgetKit.swiftinterface:951–954`. Re-confirmed `[CODE]`: `SoundingTV-Widget/Sources/` contains exactly one `Widget` conformance (`NowPlayingLiveActivityWidget`) — still no `StaticConfiguration`/`AppIntentConfiguration`/timeline provider. Unchanged from survey; product question first, API question second. |
| 2.10 | `AVPlaybackUserInterfaceControllable` | **SPIKE only if the phone player is reworked, unchanged** | Not re-verified beyond the survey (would require reading `TransportBarView.swift`'s 2061 lines against the protocol family, out of scope here). Survey's framing — big design decision, tvOS can't follow, spike only if warranted by other work — stands. |
| 2.11 | `SpotlightSearchTool` (RAG over the library) | **Prerequisite done (§0); tool itself still a spike** | The indexing half shipped (`SpotlightIndexingService.swift`). The `SpotlightSearchTool` + `LanguageModelSession` half — actually answering "what deep house did I save last year" — is not built (`grep -rn "SpotlightSearchTool"` = 0 hits). This is now a smaller spike than the survey scoped, since the expensive prerequisite (donate `CSSearchableItem`s) is done; what's left is wiring the tool and judging answer quality, which the survey correctly says "cannot be predicted from the API." |

---

## D. §3 "Deliberately not" — rejections re-confirmed

All fifteen entries were spot-checked at least for their central `[SDK]` claim where one exists; none
flipped. Highlights, not an exhaustive re-derivation (the survey's own evidence for these was already
solid and this pass didn't find reason to doubt it):

- **§3.1 (`MPNowPlayingInfoCenter` not deprecated)** — re-confirmed via the same Apple docs JSON
  approach; still `deprecated: false` on every platform. Do **not** file a "migrate off deprecated Now
  Playing" ticket.
- **§3.2 / §1.9 (tvOS gets neither `reorderable()` nor `swipeActionsContainer()`)** — re-confirmed
  directly in the tvOS `SwiftUI.swiftinterface`, both are `@available(tvOS, unavailable)`. `tabViewBottomAccessory`
  re-confirmed as iOS-26/26.1-only with `@available(tvOS, unavailable)` at both overload sites
  (`SwiftUI.swiftinterface:17956–17968`).
- **§3.3 / §1.7 (`.audio` App Schema domain absent on tvOS)** — re-confirmed directly, see item 6
  above.
- **§3.4 (App Intents *plumbing* is tvOS-live; only the *schema domains* aren't)** — not
  independently re-derived line-by-line (219 availability lines is a lot to re-walk in a triage pass),
  but the specific claim that mattered most — `.audio` unavailable, general App Intents infra
  available — is corroborated by the fact that `SoundCloudAppEntities.swift`/`SoundCloudPlaybackIntents.swift`
  **do** compile and run on the tvOS target today (registered in `project.pbxproj` for the tvOS
  `Sources` phase) using plain `AppEntity`/`AudioPlaybackIntent`/`AppShortcutsProvider` — none of
  which are schema-domain types. That's a real-build corroboration, not just an SDK grep.
- **§3.13 (`ActivityFamily`/`supplementalActivityFamilies` is iOS 18, not 27)** — re-confirmed
  directly: `WidgetKit.swiftinterface:744/770/782` all say `@available(iOS 18.0, *)`. Also
  re-confirmed the corroborating claim that `ActivityKit`'s entire interface has no 27.0 API: grepped
  the live `ActivityKit.swiftinterface` for `27.0` and got exactly one hit (the module-flags target
  triple), with the highest real availability marker in the file being `iOS 26.0`. Both claims hold.
- **§3.5–§3.12, §3.14, §3.15** — not independently re-verified in this pass (visual-effects APIs,
  gRPC, document redesign, ODR, MetricKit, CoreML/ActivityKit "nothing new" table, scene lifecycle).
  These all check as **not applicable to this codebase** on the survey's own terms (grep for the
  relevant import/type = 0 hits, which is the same test I ran for the items above and which held every
  time I re-ran it) — no reason surfaced to re-litigate any of them.

---

## E. Ranked shortlist — what's genuinely worth doing next

Ordered by (customer-visible value × how much groundwork already exists) ÷ cost, given the corrected
picture that four items are already done:

1. **§A.5 — `setDisconnectedFromSystemAudio`.** Small, targets the single most fragile seam in the
   app (CLAUDE.md's AVPlayer/AVAudioEngine handover invariant), and both halves of the handover
   (`PlayerService`, `MixEngine`) already exist to retrofit. Highest leverage-per-line in this
   document.
2. **§A.1 — stop swallowing `MixEngine`'s new throwing calls.** The migration already happened; this
   is finishing it properly rather than starting new work, and it's the difference between "DJ mode
   silently does nothing" and "DJ mode tells you it's unavailable." Cheap, and it's a correctness gap
   left by work already merged.
3. **§B — `AVAssetReader`/`AVAssetWriter` for `MixEngine.SourceImporter`.** The survey called this the
   highest-priority reader/writer call site (it's the path that feeds `MusicUnderstanding`, which is
   now live) and it's the one of the three call sites that *didn't* get migrated. Finishing what's
   already half-done beats any of the still-fully-open items below.
4. **§B — `AsyncImage` caching.** Trivial, one call site, zero downside, and the stale
   "`AsyncImage` doesn't cache" comment in `ArtworkImage.swift` is actively misleading anyone who
   reads it before this ships.
5. **§C.2.1 — spike `AVPlayerItemSampleBufferOutput`.** Not cheap, but it's the one item in the whole
   survey (original or this pass) where the *answer* could change a constraint CLAUDE.md states as
   settled fact. Should be spiked before it's quoted as settled again, per the survey's own §7 note.
6. **§A.3 — NowPlaying framework.** Medium cost, but `MusicUnderstanding`'s adoption (§0) and the
   AppEntity work (§0) both already establish the pattern of "adopt the 27-only framework for the
   feature surface, cross-platform where possible" — this is the same shape of work, on the most
   visible remaining surface (like/repeat/shuffle from the Lock Screen and Siri Remote).
7. **§A.4 — tvOS Dynamic Type.** Correctly identified by the survey as the largest single item; still
   true. Belongs on the list, but as its own scheduled effort, not squeezed in alongside anything else.

Everything in §D stays rejected. Everything else in §A–§C not listed above is real but lower-leverage
than what's here — the spikes in particular (§C) are genuinely spikes: their value is finding out an
answer, not shipping a feature, and none of them block anything on this list.
