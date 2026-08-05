# OS 27 API survey — what SoundingCloud should adopt

**Written 2026-08-03. Read-only research; no repo file outside this one was touched.**

Both apps target **iOS 27.0 / tvOS 27.0** with Xcode 27.0 beta, deliberately, so anything 27-only is
fair game with no availability guards. This document surveys what the 27 SDKs actually added, ranks
it against *this* app's surfaces, and — just as importantly — writes down what looks relevant but
isn't, so the same ideas don't get re-proposed.

Everything here is graded. Read the grade before you plan around a claim.

**If you only care about features users will notice, skip to "The customer-facing shortlist" below.**

**If you read nothing else:** the AVFAudio deprecations are a mechanical rename plus `try` and
`play(at:)`'s sample accuracy survives (§1.1); the `AVAudioSession` **interruption model was
replaced and the old one is deprecated**, which is the only forced change in here (§1.6); `NowPlaying`
and `MusicUnderstanding` are both on **tvOS** and neither is imported by any shipping target yet
(§1.2, §1.5); tvOS finally has Dynamic Type and the design system's 75 hard-coded font sizes do not
scale (§1.3); and the highest-stakes unknown is `AVPlayerItemSampleBufferOutput`, an HLS→PCM pull API
that may partly overturn the "no library-wide analysis from a stream" constraint (§2.1).

---

## The customer-facing shortlist

The numbered sections below are organised by *API area*, which makes the survey read as mostly
plumbing. It isn't. This section re-cuts the same findings by **what a user would actually notice**,
and adds three things the API-area pass missed. Ordered by how visible the feature is.

| # | What the user gets | New in 27? | Platform | Detail |
|---|---|---|---|---|
| C1 | **"Hey Siri, play Four Tet on SoundingCloud"** — plus like it, add to library, add to a playlist, all by voice, with no user-authored shortcut | **Yes** | iPhone/iPad | §1.7 |
| C2 | **Point the camera at a record sleeve or a gig poster → SoundingCloud results** in Visual Intelligence | No (iOS 26) | iPhone/iPad | §6.8 |
| C3 | **Ask your library questions in natural language** — "what did I like that sounds like this", "what deep house have I saved" — grounded in your own SoundCloud content | **Yes** | iPhone/iPad | §2.11 |
| C4 | **Like / repeat / shuffle from the Lock Screen, Control Center and the Siri Remote**, instead of just play-pause-skip | **Yes** | **Both** | §1.2 |
| C5 | **Larger text on the TV** for anyone who needs it, and an App Store accessibility badge for it | **Yes** | Apple TV | §1.3 |
| C6 | **Pick the Apple TV from the system route picker**, like an AirPlay speaker, instead of a bespoke tab in the app | **Yes** | iPhone → TV | §2.2 |
| C7 | **Now Playing on the Apple Watch and CarPlay** without building a watchOS app | No (iOS 18) | iPhone | §6.5 |
| C8 | **Now Playing on the Dynamic Island in landscape**, and a big nightstand now-playing card in StandBy | **Yes** | iPhone | §6.9 |
| C9 | **Control Centre play/pause toggle** and a Home Screen widget — neither exists today | No | iPhone | §6.3–6.4, §2.9 |
| C10 | **Your playlists offered in the Fitness app's media picker** when a workout starts | No (iOS 18 API) | iPhone | §6.10 |
| C11 | **Drag to reorder the queue, swipe to remove** | **Yes** | iPhone/iPad | §1.9 |
| C12 | **Better auto-DJ transitions** — mixing over instrumental passages rather than guessing from structure, using per-instrument activity | **Yes** | Both | §1.5 |
| C13 | **Artwork stops re-downloading**; the player and the DJ decks stop fighting over the same image | **Yes** | iPhone | §1.8 |
| C14 | **DJ mode stops stuttering on entry/exit**, and playback resumes correctly when the AV receiver wakes up | **Yes** | Both | §1.4, §1.6 |

Two honest caveats on that table. First, **the two best customer features on it (C1, C3) are
iPhone-only** — the `.audio` Siri schema domain and `SpotlightSearchTool` are both
`@available(tvOS, unavailable)` `[SDK]`. The Apple TV can be *driven* by them over the existing
Bonjour channel, which is a good shape, but the TV does not get them natively. Second, **several of
the highest-value customer features are not new in 27 at all** — C2, C7, C9 and C10 have been
available for one or two releases and simply were not built. If the question is "what can we ship
that users will notice", the not-new list is where the cheap wins are; see §6.

Everything else in this document — the deprecations, the `AVAudioSession` rework, the reader/writer
redesign — is maintenance. Real, and one item of it is forced, but nobody buys an app for it.

---

## 0. Method and evidence grades

The web-search budget for the session that produced this was already exhausted, so nothing here
came from a search-engine result page, a blog, or an aggregator. Every claim traces to one of:

| Tag | Meaning |
|---|---|
| `[SDK]` | **Verified in the SDK installed on this machine**, with an absolute path and line number. Strongest grade — it beats any web source, and a *failure* to find a symbol is recorded as a negative result rather than dropped. |
| `[DOC]` | Apple developer documentation, cited by URL. Fetched from `developer.apple.com/tutorials/data/documentation/…json`, which is the machine-readable form of the docs site. |
| `[WWDC]` | An Apple WWDC26 session, cited by URL. Session pages were read via a summarising fetch, so **API names taken only from a session and not cross-checked in the SDK are second-hand** and are marked as such inline. |
| `[RN]` | Apple release notes (tvOS 27 / iOS-iPadOS 27, beta 4), cited by URL. |
| `[?]` | **Unconfirmed.** Could not be verified in the SDK or in Apple's own docs. Do not plan around these. |

SDK roots used throughout:

```
TV  = /Applications/Xcode-beta.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS27.0.sdk
IOS = /Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk
```

Three facts about grepping these SDKs, learned the hard way, so the next person doesn't repeat them:

- The iOS SDK ships **`arm64e-apple-ios.swiftinterface`** only — there is no `arm64-apple-ios`
  variant. tvOS ships `arm64-apple-tvos`.
- The **AVFoundation Swift overlay lives under `usr/lib/swift/AVFoundation.swiftmodule/`**, not in
  the framework bundle. AVFAudio's overlay *is* in the bundle. Looking in the wrong one produces a
  false negative.
- Some frameworks spell availability **`@available(anyAppleOS 27, *)` with no `.0`** — AppIntents,
  Speech, and parts of SwiftUI do this. A `grep '27\.0'` silently misses them.

One methodological note worth keeping: **at least one WWDC session summary in this survey was wrong
and the SDK caught it.** Session 223 presents `ActivityFamily` / `supplementalActivityFamilies(_:)`
as new in this release; the SDK says `@available(iOS 18.0, *)`. See §3.13. That is the whole reason
for the grading scheme.

---

## 1. Should adopt

Ranked by value × confidence × cost. The one-line version:

| # | What | Where it lands | Grade | Cost |
|---|---|---|---|---|
| 1 | AVFAudio deprecation migration (`connectNode`, `playAudio`, `installAudioTap`) | `MixEngine.swift` | `[SDK]` | Small, mechanical |
| 2 | **NowPlaying** framework (`MediaSession`, `MediaCommand`) | `PlayerService.swift` (tvOS + iOS) | `[SDK]` `[DOC]` `[WWDC]` | Medium |
| 3 | **tvOS Dynamic Type** | `Design/DesignSystem.swift` + every tvOS view | `[WWDC]` `[SDK]` | Large |
| 4 | `AVPlayer.setDisconnectedFromSystemAudio(_:completionHandler:)` | `PlayerService.swift` ↔ `MixEngine.swift` handover | `[SDK]` | Small |
| 5 | **MusicUnderstanding** — still not imported by any shipping target | `AnalysisCache`, `GenreDetector`, `CueSuggester`, `DJCore` | `[SDK]` `[WWDC]` | Large (already designed) |
| 6 | AVAudioSession interruption model — **the old one is deprecated** | `PlayerService.swift:406, 452`, `MixEngine.swift:651` | `[SDK]` | Small, but mandatory |
| 7 | The **`.audio` App Schema domain** — Siri "play … on SoundingCloud" | iOS app + `SoundingTV-Widget` intents | `[SDK]` | Medium |
| 8 | `AsyncImage` HTTP caching + `asyncImageURLSession(_:)` | 10 iOS call sites | `[SDK]` `[RN]` | Trivial |
| 9 | SwiftUI `reorderable()` / `swipeActionsContainer()` (iOS only) | `QueueManagerView.swift` | `[SDK]` | Small |
| 10 | `AVAssetReader` / `AVAssetWriter` provider–receiver migration | `MixEngine.SourceImporter`, `PlayerService.AudioAnalyzer` | `[SDK]` `[DOC]` | Medium — real redesign |

### 1.1 AVFAudio deprecation migration — mechanical, and `play(at:)`'s sample accuracy survives

This is the item the brief asked about most specifically, so it gets the most evidence.

Every one of the deprecated AVFAudio symbols follows **one pattern**: the Objective-C method gained
an `NSError **` out-parameter and an `NS_SWIFT_NAME`, so the Swift call becomes a `try`. The
underlying implementation is the same method. `[SDK]`

```
TV/System/Library/Frameworks/AVFAudio.framework/Headers/AVAudioPlayerNode.h:312
- (void)play API_DEPRECATED_WITH_REPLACEMENT("playAndReturnError:", ios(8.0, 27.0), watchos(2.0, 27.0), macos(10.10, 27.0), tvos(9.0, 27.0));

TV/…/AVAudioPlayerNode.h:323
- (BOOL)playAndReturnError:(NSError **)outError NS_SWIFT_NAME(playAudio()) API_AVAILABLE(macos(27.0), ios(27.0), watchos(27.0), tvos(27.0));

TV/…/AVAudioPlayerNode.h:351
- (void)playAtTime:(AVAudioTime * __nullable)when API_DEPRECATED_WITH_REPLACEMENT("playAtTime:error:", ios(8.0, 27.0), …, tvos(9.0, 27.0));

TV/…/AVAudioPlayerNode.h:383
- (BOOL)playAtTime:(AVAudioTime * __nullable)when error:(NSError **)outError NS_SWIFT_NAME(playAudio(at:)) API_AVAILABLE(macos(27.0), ios(27.0), watchos(27.0), tvos(27.0));

TV/…/AVAudioEngine.h:281
- (void)connect:…format: API_DEPRECATED_WITH_REPLACEMENT("connect:to:format:error:", ios(8.0, 27.0), …, tvos(9.0, 27.0));

TV/…/AVAudioEngine.h:295
- (BOOL)connect:…format:error: NS_SWIFT_NAME(connectNode(_:to:format:)) API_AVAILABLE(…, tvos(27.0));

TV/…/AVAudioEngine.h:271
- (BOOL)connect:…fromBus:toBus:format:error: NS_SWIFT_NAME(connectNode(_:to:fromBus:toBus:format:)) API_AVAILABLE(…, tvos(27.0));
```

**On the sample-accuracy question.** `playAtTime:error:` is the *same* selector family as
`playAtTime:`, differing only by the error out-param, and it takes the same `AVAudioTime *`.
`AVAudioTime` itself is unchanged. Nothing in the header suggests a scheduling behaviour change,
and Apple documents it with `API_DEPRECATED_WITH_REPLACEMENT`, which is the annotation used for
signature-level replacements rather than semantic ones. **Expect the 0-frame drift measured for
`play(at:)` to carry over to `playAudio(at:)`.** That said — this project measured it once, so
measure it again after the migration; a four-trial re-run is cheap and the claim is load-bearing
for `MixEngine`'s beat-aligned cue at `MixEngine.swift:1132`.

The migration table for `MixEngine.swift`:

| Site | Today | After |
|---|---|---|
| 516–519 | `engine.connect(a, to: b, format: format)` ×4 | `try engine.connectNode(a, to: b, format: format)` |
| 530, 778 | `engine.connect(mixer, to: main, fromBus:toBus:format:)` | `try engine.connectNode(…)` |
| 961, 1016, 1090, 1236, 1275 | `player.play()` | `try player.playAudio()` |
| **1132** | `player.play(at: startTime)` | `try player.playAudio(at: startTime)` |

Five of the six `play()` sites are already inside functions that can absorb a throw or are on paths
guarded by `engine.isRunning`; wiring at 505–531 happens once in setup, which is the natural place
for a `throws`. **The one genuine judgement call is what `MixEngine` should do when a `connectNode`
or `playAudio` throws** — today these calls cannot fail visibly, so there is no error path at all.
The honest answer is that a failed deck connect should surface as "DJ mode unavailable" rather than
a silent dead deck, which is a small but real behaviour improvement, not just a rename.

**The tap is the one non-mechanical piece.** `[SDK]`

```
TV/…/AVAudioNode.h:117   installTapOnBus:bufferSize:format:block:   API_DEPRECATED_WITH_REPLACEMENT("installTapOnBus:bufferSize:format:error:block", …, tvos(9.0, 27.0))
TV/…/AVAudioNode.h:160   - (BOOL)installTapOnBus:…format:error:block: NS_REFINED_FOR_SWIFT API_AVAILABLE(macos(27.0), ios(27.0), watchos(27.0), tvos(27.0));
```

`NS_REFINED_FOR_SWIFT` means the Swift spelling comes from an overlay, and it does:

```
TV/System/Library/Frameworks/AVFAudio.framework/Modules/AVFAudio.swiftmodule/arm64-apple-tvos.swiftinterface:63
@available(macOS 27.0, iOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
public func installAudioTap(onBus bus: AVAudioNodeBus,
                            bufferSize: AVAudioFrameCount,
                            format: AVAudioFormat?,
                            tapProvider: @escaping @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void) throws
```

Two consequences for `MixEngine.installMeterTaps()` (`MixEngine.swift:578–608`):

1. **The buffer type changes** to `AVReadOnlyAudioPCMBuffer`, a `Sendable` struct new in 27
   (`AVFAudio.swiftinterface:333`) `[SDK]` `[DOC]`. It has no `floatChannelData`. Its
   `channelData(_:)` returns a **non-escapable** `ChannelData` enum wrapping `Span<Int16>` /
   `Span<Int32>` / `Span<Float>` (`:349–362`). The current body passes
   `channels[channel]` straight into `vDSP_rmsqv` / `vDSP_maxmgv` as an `UnsafePointer<Float>`, so
   it has to be rewritten. The path of least resistance is `withUnsafeAudioBufferList(_:)`
   (`:354`, marked `@unsafe`), which keeps the vDSP calls exactly as they are.
2. **The closure is `@Sendable`.** The current block captures `box` (`meters[deck.rawValue]`).
   That capture has to be `Sendable`. Verify before committing — it may already be, since it is
   written from the render thread today, but the compiler will now make you prove it.

`format: nil` is still permitted, so the existing `format: nil` argument carries over unchanged.
`bufferSize` gained a documented constraint — *"Supported range is [100, 400] ms"* (`AVAudioNode.h:124`)
`[SDK]`. At the canonical 44.1 kHz that is roughly 4410–17640 frames; **`MixEngine.swift:584` passes
1024**, which is ~23 ms and well below the stated floor. It works today, but the new API documents a
range the current call sits outside of. Worth re-checking the meter's responsiveness after migration
— a 100 ms minimum buffer is a visibly slower meter than a 23 ms one.

Two small conveniences arrive with the same buffer type, both `[SDK]`
(`AVFAudio.swiftinterface:117–120, 318–322`): `AVAudioFile.read(frameCount:)` now returns an
`AVReadOnlyAudioPCMBuffer` directly, and `AVAudioPlayerNode` gained a `scheduleBuffer` overload
taking one. That is relevant to the loop path at `MixEngine.swift:1199/1225`, which builds an
`AVAudioPCMBuffer` by hand and schedules it with `.loops`.

**One papercut to expect.** Apple's replacement string for the tap is malformed —
`API_DEPRECATED_WITH_REPLACEMENT("installTapOnBus:bufferSize:format:error:block", …)` is missing the
trailing colon, and the doc comment above the new method is typo'd
`installTapOnBus:bufferSize:forma:errort:block:` `[SDK]` (`AVAudioNode.h:117, 119`). **Xcode's
fix-it will not resolve.** Do that one by hand and don't waste time wondering why the automatic
migration failed.

**Verdict: adopt.** It is a warning-clearing exercise everywhere except the tap, and even the tap is
contained to one 30-line function. Doing it now, while `MixEngine` is the file everyone is already
in, is much cheaper than doing it later.

### 1.2 NowPlaying framework — new, on tvOS as well as iOS

`NowPlaying.framework` exists in **both** SDKs. `[SDK]` Platform availability from Apple's own docs:
iOS 27.0, iPadOS 27.0, Mac Catalyst 27.0, macOS 27.0, **tvOS 27.0**, visionOS 27.0, watchOS 27.0.
`[DOC]` ([NowPlaying](https://developer.apple.com/documentation/nowplaying))

Today the app hand-builds `MPNowPlayingInfoCenter.default().nowPlayingInfo` dictionaries at
`PlayerService.swift:591, 607, 618–620, 627–631, 1198` and wires `MPRemoteCommandCenter.shared()`
at `:536`. The NowPlaying model replaces both with a declarative conformance:

```
TV/System/Library/Frameworks/NowPlaying.framework/Modules/NowPlaying.swiftmodule/arm64-apple-tvos.swiftinterface:145
@MainActor public protocol MediaSessionRepresentable : Identifiable {
  var id: String { get }
  var content: (any MediaContentRepresentable)? { get }
  var playbackSnapshot: MediaPlaybackSnapshot? { get }
  var commands: [MediaCommand] { get }
}
```

`MediaSession<Representable>` (`:109`) is `Observable` (`:141`) and observes an `@Observable` model
for you — the manual "rebuild the dictionary on every state change" bookkeeping goes away.

The parts that matter *specifically here*, all `[SDK]` from the same interface file:

- **`MediaCommand.feedback(title:shortTitle:status:_:)`** (`:76`) with
  `FeedbackStatus { positive, neutral, negative }` (`:16`). SoundCloud has likes. This puts
  like/unlike on the system transport surfaces, which `MPRemoteCommandCenter` never modelled well.
- **`MediaCommand.changeRepeatMode` / `.changeShuffleMode`** (`:73–74`) with first-class
  `RepeatMode { off, one, all }` and `ShuffleMode { off, items, collections }` enums.
- **`MediaCommand.changePlaybackRate(supported:_:)`** (`:72`) — relevant given `MixEngine` already
  varies rate via `AVAudioUnitTimePitch`.
- **`MusicContent`** (`:411`) as a first-class content type, rather than the generic dictionary.
- **`Artwork(id:) { size in … }`** (`:506`) — the system asks for the size it wants. This is a
  direct fit for `ArtworkImage.swift`'s existing variant ladder
  (`original` → `t500x500` → `large`), which currently has to guess.
- **`AnimatedArtwork`** (`:513`) with an `AspectRatio` enum.
- `MediaPlaybackSnapshot.PlaybackState` (`:79`) has `.buffering` and `.interrupted` cases — states
  the app already tracks internally (`AVPlayerItemPlaybackStalled` at `PlayerService.swift:841`)
  but cannot currently express to the system.
- **`MediaContentRepresentable.appEntityIdentifiers: [EntityIdentifier]`** — from the
  `_NowPlaying_AppIntents` cross-import overlay, tvOS 27 `[SDK]`. This ties Now Playing content back
  to App Entities, which is the join between §1.2 and §1.7.

**One constraint to design around:** `MediaSession` is `@available(iOSApplicationExtension,
unavailable)` (`:108`). It cannot be driven from `SoundingTV-Widget`. That is fine — the widget
already reaches the app over Bonjour (`WidgetControlSender.swift`) rather than owning playback.

**This is elective, not forced** — see §3.1. Adopt it for the feature surface (feedback, repeat,
shuffle, sized artwork), not as a deprecation fix.

### 1.3 tvOS Dynamic Type — the one tvOS-wide UI change, and it hits the design system

tvOS 27 adds a **system-wide Text Size setting** at *Settings › Accessibility › Display › Text Size*,
ranging from Large through Accessibility XXXL. `[WWDC]`
([Prepare your tvOS apps for Dynamic Type, session 221](https://developer.apple.com/videos/play/wwdc2026/221/))

Precision that matters, because it is easy to get this backwards: **the API is not new.**
`EnvironmentValues.dynamicTypeSize` and the `DynamicTypeSize` enum have been available on tvOS since
15.0 `[SDK]`
(`TV/…/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64-apple-tvos.swiftinterface:14185, 14219`).
What is new in 27 is that **the system now reports values other than the default**, because there is
finally a user-facing control. Code that reads `\.dynamicTypeSize` compiled fine on tvOS 26; it just
never saw anything interesting.

The exposure in this codebase is concrete and large:

- `Design/DesignSystem.swift:128–151` defines the **entire tvOS type scale** as fixed
  `Font.system(size:)` — `tvHero` 96, `tvDisplay` 76, `tvLargeTitle` 58, … `tvMini` 28. None of it
  scales.
- **75** occurrences of `system(size:` across `SoundingTV.swiftpm/Sources`, **63** across
  `SoundingTV-iOS/Sources`.
- **88** `Font.tv*` call sites across the tvOS views.
- `dynamicTypeSize`, `DynamicTypeSize`, `preferredFont(forTextStyle:)` and
  `adjustsFontForContentSizeCategory` appear **nowhere** in the repo.

The session's guidance maps onto this app's specific traps `[WWDC]`:

- Replace fixed sizes with semantic styles, or with `Font.custom(_:size:relativeTo:)` if the 28–58pt
  scale is worth preserving as a *base* — the latter keeps the deliberate tvOS scale
  CLAUDE.md insists on while still scaling. This is the recommended route here.
- Swap `.frame(width:)` for `.frame(maxWidth:.infinity)`; fixed widths truncate at large sizes.
- Use `dynamicTypeSize.isAccessibilitySize` to reduce `containerRelativeFrame(_:count:spacing:)`
  counts on shelves — directly applicable to `HomeView.swift`'s horizontal rails and
  `LibraryView.swift`'s `LazyVGrid` (104/139/174).
- Use `AnyLayout` to switch `HStack`→`VStack` at accessibility sizes — applicable to the player
  metadata block and the DJ deck cards.

There is also an App Store consequence: apps can now declare **Larger Text support in the
Accessibility Nutrition Label for tvOS**. `[WWDC]`

**Verdict: adopt, and treat it as its own piece of work.** It is the largest item in this survey by
effort and the only one that touches essentially every tvOS view. It also interacts with the focus
doctrine (`DesignSystem.swift:272–290`) — a card that grows with text size must still scale and lift
correctly on focus.

### 1.4 `AVPlayer.setDisconnectedFromSystemAudio(_:completionHandler:)` — the handover primitive

New in tvOS 27 / iOS 27. `[SDK]`

```
TV/System/Library/Frameworks/AVFoundation.framework/Headers/AVPlayer.h:515
@property (nonatomic, readonly) BOOL disconnectedFromSystemAudio … API_AVAILABLE(ios(27.0), tvos(27.0), watchos(27.0), visionos(27.0));

TV/…/AVPlayer.h:536
- (void)setDisconnectedFromSystemAudio:(BOOL)disconnected
                     completionHandler:(nullable void (^ NS_SWIFT_SENDABLE)(void))completionHandler
    NS_REFINED_FOR_SWIFT … API_AVAILABLE(ios(27.0), tvos(27.0), …);
```

The header's own words: when `YES`, "the player is disconnected from system audio and will not
interact with the audio session. It will not activate the audio session when starting and it does
not reconfigure after route changes."

CLAUDE.md states the hardest invariant in this project: *"`AVPlayer` and `AVAudioEngine` must never
render simultaneously — handover tears one down before starting the other."* That teardown is
`PlayerService.teardownAVPlayer()` (`:2487`), `handBackToAVPlayer()` (`:2437`), and
`takeOverFromAVPlayer(on:track:)` (`:1654`).

This API lets you **park** the `AVPlayer` instead of destroying it: disconnect it from system audio,
get a completion callback confirming the disconnect actually happened, *then* start `MixEngine`.
Coming back, reconnect and resume. The header even documents the ordering explicitly — deactivate
the session **inside** the completion handler, not before it.

Concretely this should buy: no `AVPlayerItem` re-creation on every DJ-mode entry/exit (which today
throws away the `preferredForwardBufferDuration` state machine at `PlayerService.swift:806/816` and
restarts the two-stage buffering from scratch), a deterministic ordering guarantee where today there
is a teardown-then-hope, and a much shorter path back to audio when leaving DJ mode.

**Verdict: adopt.** Small surface, high leverage, and it targets the single most fragile seam in the
app.

### 1.5 MusicUnderstanding — the framework the 27.0 floor was chosen for is still not imported

`MusicUnderstanding.framework` is present in **both** SDKs `[SDK]`, and Apple lists it under iOS 27
"Games and Media" as "Analyze audio across six dimensions on-device". `[DOC]`
([iOS what's new](https://developer.apple.com/ios/whats-new/))

**Finding worth stating plainly: no shipping target imports it.** There are zero
`import MusicUnderstanding` and zero `import NowPlaying` statements across `SoundingTV.swiftpm/`,
`SoundingTV-iOS/`, `SoundingTV-Widget/`, `SoundingTV-Share/`, `SoundingTV-TopShelf/` and
`SoundingTV-AppClip/`. The only usage is the standalone spike under
`Design/specs/artifacts/mu-spike/src/`, which is not part of any Xcode target. Meanwhile the app has
explicit MU-shaped holes waiting: `GenreDetector.swift:6–42` documents how to fill itself from
`MusicUnderstandingSession.SessionResult`; `AnalysisCache.swift:16–37` is designed to hold MU output
alongside the FFT output; `WaveformService.swift:394, 439–446` mirrors MU's LUFS shape without
importing it; and `CueSuggester.swift`, `DJCore.swift`, `DJScoringTerms.swift`, `AnalysisSync.swift`
all reference it in comments.

Two API details from the session that the existing spike work did not exercise `[WWDC]`
([Meet the Music Understanding framework, session 253](https://developer.apple.com/videos/play/wwdc2026/253/)):

- **`session.analyze(for: [.loudness])`** — analyse a *subset* of dimensions. `mu-findings.md`
  measured whole-session cost; per-dimension cost is a different and probably much better number for
  the cases where only BPM or only key is needed for candidate recall.
- **`session.loudnessResults`**, an `AsyncSequence<LoudnessResult, any Error>` — streaming results
  while analysis runs. This is what a live meter or a live auto-gain would consume.
- **`PaceResult.ranges: [RangedValue<Double>]`** and **`InstrumentActivityResult`** (per-`Instrument`
  presence ranges *and* 0–1 intensity over time). Neither appears in the DJ engine design, and
  instrument activity is precisely the signal for "where in this track are the vocals absent, so I
  can mix over it" — a question `dj-engine-spec.md`'s transition catalog currently answers from
  structure alone.

The known hard constraint stands and is not softened by anything in 27: `MusicUnderstandingSession(asset:)`
accepts local `file://` assets only. Nothing in the session material contradicts `mu-findings.md`;
the session's own examples use `AVURLAsset` with `AVURLAssetPreferPreciseDurationAndTimingKey` and
never mention HLS or remote sources. `[WWDC]`

**Verdict: adopt.** This is less "evaluate a new API" than "execute the plan already written in
`mu-findings.md` and `dj-engine-spec.md`". It is on this list because the survey turned up that it
has not, in fact, been started.

### 1.6 AVAudioSession — the whole interruption model was replaced, and the old one is deprecated

**This is the only item in §1 that is not optional.** `AVAudioSessionInterruptionNotification`,
which the app observes at `PlayerService.swift:452` and decodes at `:474` and `:485`, is deprecated
at 27.0 `[SDK]`:

```
TV/…/AVFAudio.framework/Headers/AVAudioSessionTypes.h:229
AVAudioSessionInterruptionNotification … API_DEPRECATED("Use AVAudioSessionDidBecomeInactiveNotification and AVAudioSessionResumptionRecommendationNotification instead", ios(6.0, 27.0), watchos(2.0, 27.0), tvos(9.0, 27.0), visionos(1.0, 27.0))
```

Deprecated with it: `AVAudioSessionInterruptionTypeKey` (`:331`), `…OptionKey` (`:334`),
`…ReasonKey` (`:337`, → `AVAudioSessionDeactivationContext.interruptionDetails.reason`), and the
enums `AVAudioSessionInterruptionType` (`:643`) and `AVAudioSessionInterruptionOptions` (`:650`).
Everything the app's interruption handling is built on, in other words.

The replacement, all `ios(27.0), tvos(27.0)` `[SDK]`:

```
AVAudioSessionTypes.h:311  AVAudioSessionDidBecomeActiveNotification
AVAudioSessionTypes.h:316  AVAudioSessionDidBecomeInactiveNotification          → userInfo[AVAudioSessionDeactivationContextKey]  (:377)
AVAudioSessionTypes.h:321  AVAudioSessionResumptionRecommendationNotification   → userInfo[AVAudioSessionResumptionContextKey]    (:382)
AVAudioSessionTypes.h:689  AVAudioSessionDeactivationSource         { App = 1, System = 2 }
AVAudioSessionTypes.h:696  AVAudioSessionResumptionRecommendation   { ShouldNotResume = 0, ShouldResume = 1 }
AVAudioSessionTypes.h:404  AVAudioSessionDeactivationOptions        { None, NotifyOthersOnDeactivation = 1<<0 }
AVAudioSession.h:574       AVAudioSessionInterruptionContext   NS_SWIFT_NAME(AVAudioSession.InterruptionContext)
AVAudioSession.h:589       AVAudioSessionDeactivationContext   { .source, .interruptionContext }
AVAudioSession.h:609       AVAudioSessionResumptionContext     { .recommendation }
```

All three context classes are `NS_SWIFT_SENDABLE`, and Swift gets typed
`NotificationCenter.Message`s rather than dictionary-digging `[SDK]`
(`AVFAudio.swiftinterface:246–304`): `DidBecomeActiveMessage`, `DidBecomeInactiveMessage` — which
carries `deactivationResult: DeactivationResult` of `.systemInterruption(InterruptionContext)` or
`.appDeactivated` — and `ResumptionRecommendationMessage`.

**This is a genuine improvement, not just a rename.** Today the app receives "an interruption began /
ended" and has to decide for itself whether to resume; the `.shouldResume` option on the old API was
famously unreliable. `AVAudioSessionResumptionRecommendation` is the system telling you outright.
On an Apple TV wired to an AV receiver — the reference setup — "the receiver woke up, should I
resume?" is a genuinely hard call to make from `AVAudioEngineConfigurationChange`
(`MixEngine.swift:618`) plus a route-change notification (`PlayerService.swift:456`) alone.
`AVAudioSessionDeactivationSource` also finally distinguishes "I deactivated" from "the system
deactivated me", which the old API never did.

Separately, **async activation** — same headers, both live on tvOS `[SDK]`:

```
AVAudioSession.h:278   - (void)activateWithOptions:completionHandler:    API_AVAILABLE(ios(27.0), watchos(5.0), tvos(27.0), visionos(27.0))
AVAudioSession.h:289   - (void)deactivateWithOptions:completionHandler:  API_AVAILABLE(ios(27.0), watchos(27.0), tvos(27.0), visionos(27.0))
```

The header calls `setActive:` "a relatively time consuming operation", which is exactly why the
async form exists. The app calls the synchronous form at `PlayerService.swift:406/411` and
`MixEngine.swift:651`, both on the main actor, in a project that already cares measurably about
time-to-first-audio (it is the documented reason `preferredForwardBufferDuration` starts at 0).

`AVAudioSessionDeactivationOptionNotifyOthersOnDeactivation` pairs with §1.4: disconnect the
`AVPlayer`, then deactivate with this option in the completion handler so whatever was interrupted
can resume.

**There is already a seam to do this behind.**
`SoundingTV.swiftpm/Sources/Services/AudioSessionCoordinator.swift` defines
`AudioSessionCoordinating` (`:62`), `PlatformAudioSession` (`:120`) and `AVAudioSessionCoordinator`
(`:149`), with a doc comment at `:55` stating that *"`PlayerService` and `MixEngine` both call
`activatePlayback()`"*. **They don't** — nothing outside that file references it, and both services
still reach `AVAudioSession.sharedInstance()` directly (`PlayerService.swift:406, 411, 427;
MixEngine.swift:651`). Two conclusions: the file's comment is aspirational and should be corrected,
and **this migration is the natural moment to actually adopt the coordinator**, which turns "change
the interruption model in two places with divergent logic" into "change it in one".

Concrete deprecated call sites in the interruption handler:
`AVAudioSession.interruptionNotification` (`:452`), `AVAudioSession.InterruptionType(rawValue:)`
(`:474`), and `AVAudioSession.InterruptionOptions(rawValue:).contains(.shouldResume)` (`:485`) —
that last one being exactly the unreliable signal `AVAudioSessionResumptionRecommendation` replaces.

**Verdict: adopt**, together with §1.4 — they are one piece of work, and the interruption half is
forced.

### 1.7 The `.audio` App Schema domain — iOS only, and it is a real thing

This is the find that would not have shown up in any blog. `[SDK]`

`AppIntents` in the 27 SDK carries an `AppSchema.AudioIntent` marker protocol and an `.audio`
namespace, and the schema list under it is:

```
IOS|TV /System/Library/Frameworks/AppIntents.framework/Modules/AppIntents.swiftmodule/*.swiftinterface:8265+
  .audio.addToLibrary        → AppSchema.Intent("AddAudioToLibraryIntent")
  .audio.addToPlaylist       → AppSchema.Intent("AddAudioToPlaylistIntent")
  .audio.createStation       → AppSchema.Intent("CreateStationIntent")
  .audio.playAudio           → AppSchema.Intent("PlayAudioIntent")
  .audio.recognizeAudio      → AppSchema.Intent("RecognizeAudioIntent")
  .audio.updateAudioAffinity → AppSchema.Intent("UpdateAudioAffinityIntent")
  .audio.warmupAudioQueue    → AppSchema.Intent("WarmupAudioQueueIntent")
```

…and the entity schemas `.audio.song` (`SongEntity`), `.audio.artist`, `.audio.playlist`,
`.audio.album`, `.audio.songCollection`, `.audio.algorithmicRadioStation`, `.audio.liveRadioStation`,
`.audio.ambientSound`, plus podcast/audiobook/news types (`:8320–8440`).

The parameter type lives in a **new framework**, `MediaIntents`, present in both SDKs `[SDK]`:

```
TV/System/Library/Frameworks/MediaIntents.framework/Modules/MediaIntents.swiftmodule/arm64-apple-tvos.swiftinterface:10
@available(iOS 27.0, macOS 27.0, watchOS 27.0, visionOS 27.0, tvOS 27.0, *)
public struct AudioSearch : Codable, Equatable, Hashable, Sendable {
  public init(criteria: AudioSearch.Criteria)
  public enum Criteria { case unspecified; case searchQuery(String); case url([URL]) }
}
```

Mapped onto this app: `.audio.playAudio` is "Hey Siri, play *<anything>* on SoundingCloud".
`.audio.updateAudioAffinity` is the SoundCloud like. `.audio.song` / `.audio.artist` /
`.audio.playlist` map onto `Track`, `User` and `Playlist` in `Sources/Models/`.
`Criteria.url([URL])` maps onto the existing `SoundCloudAPI.resolve(url:)` path that the Share
extension already feeds.

**Critical availability caveat, and it is the reason this is ranked 7 and not 2** `[SDK]`:

```
@available(anyAppleOS 27.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)      ← the whole .audio domain
extension AppSchemaIntent where Self == AppSchema.Intent { public static var audio: … }
```

**The `.audio` schema domain is unavailable on tvOS.** `MediaIntents.AudioSearch` compiles on tvOS,
but the schema it is a parameter for does not. So this is an iPhone-app feature. The Apple TV can
still be *driven* by it, over the existing Bonjour control channel — which is a nice shape: Siri on
the phone, playback on the TV, using machinery that already exists in `RemoteQueueClient`.

Note also that the `@AppIntent(schema:)` macro's generated conformance list includes
`AudioPlaybackIntent` and `LiveActivityIntent` (`AppIntents.swiftinterface:7974`) — neither of which
the app's five intents in `PlaybackControlIntents.swift` currently adopt. See §6.

**Verdict: adopt on iOS.** Unverified: whether Apple gates the `.audio` domain behind review, as it
does some Siri domains. Session 240 only demonstrated the Messages domain and did not enumerate
others `[WWDC]`, so treat the *behaviour* of these schemas as `[?]` even though their *existence* is
`[SDK]`-verified.

### 1.8 `AsyncImage` HTTP caching — free, and it retires a stale rationale

In apps built with the 27 SDKs, `AsyncImage` automatically caches downloaded images using HTTP
caching protocols; you can supply a `URLRequest` with a `cachePolicy`, and set a custom session for
a whole subtree with `View.asyncImageURLSession(_:)`. `[RN]`
([tvOS 27 release notes](https://developer.apple.com/documentation/tvos-release-notes/tvos-27-release-notes),
[iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes), radar 78212597)

Availability is `@available(anyAppleOS 27.0, *)` — **including tvOS** `[SDK]`
(`TV/…/SwiftUI.swiftinterface:18986`).

This matters more than it sounds, because the two apps diverged here. The tvOS side built
`Views/Components/ArtworkImage.swift`, whose header comment gives three reasons for replacing
`AsyncImage`, the second being *"**No cache.** `AsyncImage` doesn't cache, so the same artwork was
fetched once per view instance."* **That reason is now obsolete.** Reasons 1 (resolution variants)
and 3 (fallback ladder) still stand, so `ArtworkImage` should survive — but the comment should stop
claiming a cache problem that the platform fixed.

The iPhone app never adopted `ArtworkImage` and still uses raw `AsyncImage` at **10 live call
sites**: `QueueManagerView.swift:244`, `LibraryBrowserView.swift:919`, `CompanionRootView.swift:287`,
`TransportBarView.swift:354, 943, 1806, 1866, 2001`, `PhoneSettingsView.swift:392`, plus
`SoundingTV-Widget/Sources/NowPlayingLiveActivityWidget.swift:62`. Every one of those gets caching
for free by rebuilding against the 27 SDK. Adding one `asyncImageURLSession(_:)` at the
`PhoneRootView` level with a sized `URLCache` upgrades all ten at once.

**Verdict: adopt (iOS).** Near-zero cost. Also fix the stale comment in `ArtworkImage.swift`.

### 1.9 SwiftUI reordering and swipe actions — iOS queue only

New in 27 `[SDK]` (`TV/…/SwiftUI.swiftinterface`, availability read from the tvOS SDK because it
lists the tvOS verdict explicitly):

```
:12774  @available(iOS 27.0, macOS 27.0, watchOS 27.0, visionOS 27.0, *) @available(tvOS, unavailable)
        public func reorderable() -> some DynamicViewContent<Self.Data>
:12786  … public func reorderContainer<Item>(for:isEnabled:move:) -> some View
:21223  @available(iOS 27.0, …) @available(tvOS, unavailable)
        public func swipeActionsContainer() -> some View
```

`reorderContainer(for:)` works on `List` **and** `LazyVGrid` and any container, hands you a
`ReorderDifference` to apply, and `swipeActions` now applies to any view rather than only `List`
rows, coordinated by `swipeActionsContainer()`. `[WWDC]`
([What's new in SwiftUI, session 269](https://developer.apple.com/videos/play/wwdc2026/269/))

Landing zone: `SoundingTV-iOS/Sources/QueueManagerView.swift:71` (`List`) — drag-to-reorder the play
queue and swipe-to-remove, replacing whatever hand-rolled affordance exists.
`LibraryBrowserView.swift:128/203/307` could take swipe actions for "add to queue" / "play next".

**tvOS gets neither.** See §3.2.

### 1.10 `AVAssetReader` / `AVAssetWriter` — a real redesign, not a rename

Unlike §1.1, this one is **not** mechanical. The 27 SDK deprecates the imperative pull/push loop and
replaces it with a provider/receiver model. `[DOC]`
([AVAssetReader](https://developer.apple.com/documentation/avfoundation/avassetreader),
[AVAssetReaderOutput](https://developer.apple.com/documentation/avfoundation/avassetreaderoutput),
[AVAssetWriter](https://developer.apple.com/documentation/avfoundation/avassetwriter),
[AVAssetWriterInput](https://developer.apple.com/documentation/avfoundation/avassetwriterinput))

| Deprecated | Replacement |
|---|---|
| `AVAssetReader.startReading()` → `Bool` | `AVAssetReader.start()` (throwing) |
| `AVAssetReader.add(_:)` | `AVAssetReader.outputProvider(for:)` / `outputProviderWithRandomAccess(for:)` |
| `AVAssetReaderOutput.copyNextSampleBuffer()` | `AVAssetReaderOutput.Provider<Payload>.next() async throws -> Payload?` |
| `AVAssetReaderOutput.alwaysCopiesSampleData` | *(no scalar equivalent — the provider model owns copy behaviour)* `[?]` |
| `AVAssetReaderOutput.supportsRandomAccess`, `reset(forReadingTimeRanges:)`, `markConfigurationAsFinal()` | `AVAssetReaderOutput.RandomAccessController` |
| `AVAssetWriter.startWriting()` → `Bool` | `AVAssetWriter.start()` (throwing) |
| `AVAssetWriter.add(_:)` | `AVAssetWriter.inputReceiver(for:)` (and `inputPixelBufferReceiver`, `inputMetadataReceiver`, `inputCaptionReceiver`) |
| `AVAssetWriter.finishWriting()` (sync) | `finishWriting(completionHandler:)` |
| `AVAssetWriterInput.append(_:)`, `.requestMediaDataWhenReady(on:using:)`, `.isReadyForMoreMediaData`, `.expectsMediaDataInRealTime` | `AVAssetWriterInput.SampleBufferReceiver` |

**`AVAssetReaderOutput.Provider` is available from iOS/tvOS 26.0** `[DOC]`, not 27 — so the
replacement predates the deprecation and there is no availability problem at a 27.0 floor.

Call sites:

- `MixEngine.swift:2376–2442` (`SourceImporter`) — reader at 2376, `alwaysCopiesSampleData = false`
  at 2388, `startReading()` at 2394, `copyNextSampleBuffer()` at 2442. This is the hot path that
  materialises tracks locally so `MusicUnderstanding` can analyse them, so it is worth doing
  properly.
- `PlayerService.swift:3124–3142` (`AudioAnalyzer`) — an entirely separate reader loop with the same
  three deprecated calls.
- `MixEngine.swift:2783–2819` (`MixImportSelfTest`) — writer at 2783,
  `expectsMediaDataInRealTime = false` at 2791, `startWriting()` at 2819. Self-test only; lowest
  priority.

The real work is that `copyNextSampleBuffer()` is a synchronous pull inside a loop, and
`Provider.next()` is `async throws`. Both call sites therefore become async functions, which ripples
into their callers. Doing the reader and writer together, and doing them *after* §1.1, is the right
sequencing — §1.1 is a warning cleanup, this is a refactor with a testable behaviour boundary.

**Verdict: adopt, but schedule it separately from §1.1.** Two loops, both already isolated behind
narrow entry points (`SourceImporter`, `AudioAnalyzer.analyze(streamURL:duration:trackId:)`).

---

## 2. Worth a spike

Roughly ordered by stakes. §2.1 is the only one where the *answer* could change an architectural
decision already taken; the rest are ordinary "measure before committing".

### 2.1 `AVPlayerItemSampleBufferOutput` — the one that might overturn a documented constraint

**Spike this first.** It is the highest-stakes item in the whole survey, because it bears directly on
a constraint CLAUDE.md states as settled fact.

Entirely new file in the 27 SDK, `[SDK]`
`TV/System/Library/Frameworks/AVFoundation.framework/Headers/AVPlayerItemSampleBufferOutput.h`,
every symbol `API_AVAILABLE(macos(27), ios(27), tvos(27), watchos(27), visionos(27))`:

```
:21  @protocol AVPlayerItemSampleBufferOutputDelegate   — outputMediaDataAvailable:, outputSequenceWasRestarted:
:43  AVPlayerItemSampleBufferOutputConfiguration
:50  AVPlayerItemSampleBufferOutputAudioConfiguration
:59    @property CMFormatDescriptionRef requestedAudioFormat   (must be PCM)
:86  AVPlayerItemSampleBufferOutput : AVPlayerItemOutput
:92    initWithConfiguration:
:102   copyNextSampleBuffer
```

and the header says at `:83`: *"Currently supported for HLS `AVPlayerItems` only, and only for
delivering decoded PCM audio."*

Swift refinement `[SDK]` (`TV/usr/lib/swift/AVFoundation.swiftmodule/arm64-apple-tvos.swiftinterface:1850–1859`):

```swift
public struct SampleBufferInSequence : Sendable {
  public var sampleBuffer: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>
  public var sequenceWasRestarted: Bool
}
public func nextAvailableSampleBuffer() -> SampleBufferInSequence?
nonisolated public func nextSampleBuffer() async -> SampleBufferInSequence?
```

A second, independent new route to the same place: `AVAudioMix.h:63–66` adds
`AVAudioMixInputParametersTrackMixID = 0`, documented at `:102` as the way to tap **the mix of all
audio tracks** — *"particularly useful for setting up volume ramps or an audio tap for streaming
playback"* — paired with `MTAudioProcessingTapCreateWithPreferredFormat(...)`, new at
`MediaToolbox/MTAudioProcessingTap.h:356–361`, `API_AVAILABLE(macos(27.0), ios(27.0), tvos(27.0), visionos(27.0))`,
which lets you name the PCM format you want back. `[SDK]`

**Why this matters so much here.** CLAUDE.md states: *"`MusicUnderstandingSession(asset:)` accepts
local `file://` assets only — six remote sources (HLS and progressive, localhost and public CDNs)
all fail instantly with `invalidAsset`. … Practical consequence: … **library-wide candidate analysis
from a stream does not work**, so next-track selection leans on metadata."* That finding is real and
`mu-findings.md` measured it. But it was measured against `MusicUnderstandingSession(asset:)`, and
27.0 is the first release that ships **an HLS → decoded-PCM pull API**. The other half of the join
also arrives in 27: `MusicUnderstandingSession(audioProvider:)` takes an `AsyncSequence` whose
`Element` is `AVReadOnlyAudioPCMBuffer` `[SDK]`
(`MusicUnderstanding.swiftinterface:170`), and `AVReadOnlyAudioPCMBuffer` is itself new in 27.

So the chain HLS → `AVPlayerItemSampleBufferOutput` → PCM → `AVReadOnlyAudioPCMBuffer` →
`MusicUnderstandingSession(audioProvider:)` did not exist when that constraint was written.

**Do not get excited yet.** The `audioProvider:` route is still realtime-paced — CLAUDE.md and
`mu-findings.md` both establish that, and nothing in 27 contradicts it. So this probably does *not*
unlock faster-than-realtime library sweeps. What it plausibly *does* unlock is analysing the track
that is **currently streaming** without first materialising it through `SourceImporter` — which is a
meaningfully different capability from what the app does today, and it is the precondition for live
loudness/pace on the AVPlayer path rather than only on the DJ path.

Spike, in order, stopping at the first failure: (1) can you attach an
`AVPlayerItemSampleBufferOutput` to a SoundCloud HLS `AVPlayerItem` at all, given SoundCloud's
second-hop stream URLs; (2) does it deliver PCM at the requested format; (3) does feeding it to
`MusicUnderstandingSession(audioProvider:)` produce usable results; (4) at what CPU cost on an
Apple TV.

Note also that `WaveformService.swift:775–801` contains a written-up decision to **not** build an
`MTAudioProcessingTap` ("Tier 3"). `MTAudioProcessingTapCreateWithPreferredFormat` plus the new
track-mix ID changes the inputs to that decision; the rationale should be re-read rather than
assumed still valid.

### 2.2 AVSystemRouting — put the Apple TV in the system route picker

**New framework in 27.** `[SDK]` — present in `IOS/System/Library/Frameworks/AVSystemRouting.framework`,
**absent from the tvOS SDK**. Apple's platform line: iOS 27.0, iPadOS 27.0, Mac Catalyst 27.0.
`[DOC]` ([AVSystemRouting](https://developer.apple.com/documentation/avsystemrouting)) Abstract:
*"Send media from your app to a TV, speaker, or other device through a media device extension."*

Surface: `AVSystemRouteController`, `AVSystemRouteControllerObserver`, `AVSystemRouteEvent(.activate/.deactivate)`,
`AVSystemRoute`, `AVSystemRouteSession(url:mode:)` with `AVSystemRoute.LaunchMode` of `.player` or
`.application`, `AVSystemRouteMediaSession`, `AVSystemRoute.DataChannel` + `AVSystemRouteDataDelegate`,
`AVSystemRoutingError`. `[DOC]`
([Routing media to third-party devices](https://developer.apple.com/documentation/AVSystemRouting/routing-media-to-third-party-devices))

Why it is interesting here: the phone→TV relationship this app already implements by hand — discover
a device, send it a URL, then exchange control messages over a persistent channel — is *exactly* the
shape `AVSystemRouteSession(url:mode: .application)` plus `dataChannel` describes. Adopting it would
put "Apple TV (SoundingCloud)" in the **system** route picker rather than in a bespoke tab, and would
subsume the output-switching UI in `CompanionRootView` / `RemoteOutputTarget` / `RemoteQueueClient`.
The docs also note `playbackControl` "supports Observation in Swift", so SwiftUI views update
automatically — which is what `PhonePlaybackCoordinator` currently hand-rolls.

**Why it is a spike and not an adoption:** it requires a *media device extension*, and neither the
article nor the framework landing page states whether that extension point is open to any developer
or gated behind an entitlement / Apple approval, as MFi-adjacent capabilities usually are. `[?]`
Spike question, in order: (1) does the extension point identifier appear in a public
`.appextensionpoint` in the SDK; (2) does building a trivial extension get past provisioning;
(3) does the route show up in the picker on a real device. Stop at the first "no".

Also note the doc's own instruction: *"Report your playback metadata to `MPNowPlayingInfoCenter`"* —
AVSystemRouting expects the legacy Now Playing API, which is more evidence for §3.1.

One corroborating SDK detail: `AVAudioSessionTypes.h:88` adds an **iOS-only**
`AVAudioSessionPortMediaDeviceExtension` port type in 27.0 `[SDK]`. So the media device extension is
a real, first-class audio route on the phone — not a video-only or metadata-only concept — which
raises the value of the spike.

### 2.3 NowPlaying remote media sessions — the right idea, possibly the wrong transport

`RemoteMediaSessionRepresentable`, `RemoteMediaSession`, `MediaDevice` with
`MediaDevice.Capability.absoluteVolume(_:_:)`, and a `RemoteMediaSessionExtension` conforming to
`ExtensionFoundation.AppExtension`. `[SDK]`
(`TV/…/NowPlaying.swiftinterface:157, 182, 232, 254, 278, 307, 327`)

This is precisely "my app knows about a device elsewhere that is playing something; represent it to
the system, including its volume, and route commands to it". That is the Apple TV, from the phone's
point of view.

**Why it is a spike:** `[SDK]` says `RemoteMediaSessionAttributes` is
`@available(iOS 27, iOSApplicationExtension 27, *)` with `tvOS`, `watchOS`, `macOS`, `visionOS` and
`macCatalyst` all **unavailable** (`:157–165`) — so it is a phone-side-only feature, fine. But the
architecture Apple describes is **APNs-driven**: a server pushes state, the system launches your
extension, the extension returns a representation. `[WWDC]`
([Meet the Now Playing framework, session 312](https://developer.apple.com/videos/play/wwdc2026/312/))
This app has no server and discovers the TV on the LAN. Whether the extension can be driven by a
local Bonjour observation rather than a push is the whole question, and nothing in the docs answers
it. `[?]`

Spike: build a `RemoteMediaSessionExtension` and try to update it from a local
`NWBrowser`/`NWConnection` without any push involvement. Timebox it — the answer may simply be no.

### 2.4 Realtime-safe AVFAudio render blocks

New in 27, `CA_REALTIME_API`-annotated: `[SDK]`

```
TV/…/AVFAudio.framework/Headers/AVAudioSourceNode.h:48, 88, 116   AVAudioSourceNodeRenderBlockRealtimeSafe, initWithRealtimeSafeRenderBlock:, initWithFormat:realtimeSafeRenderBlock:
TV/…/AVAudioSinkNode.h:40, 87                                     AVAudioSinkNodeReceiverBlockRealtimeSafe, initWithRealtimeSafeReceiverBlock:
TV/…/AVAudioIONode.h:50, 218                                      AVAudioIONodeInputBlockRealtimeSafe, setRealtimeSafeManualRenderingInputPCMFormat:inputBlock:
TV/…/AVAudioEngine.h:150                                          AVMIDIEventListBlock (CA_REALTIME_API)
```

The app uses none of `AVAudioSourceNode`, `AVAudioSinkNode` or manual rendering today. But this is
the direction Core Audio is moving — the compiler will increasingly know which closures run on the
render thread — and `MixEngine`'s meter tap is exactly such a closure. Worth a spike specifically to
find out whether the `@Sendable` requirement on the new `installAudioTap` (§1.1) is part of the same
push, and whether the existing meter box would trip a realtime-safety diagnostic.

### 2.5 `MusicUnderstanding.AudioProvider` fed from `installAudioTap`

A neat type coincidence: `MusicUnderstandingSession(audioProvider:)` consumes an `AsyncSequence`
yielding **`AVReadOnlyAudioPCMBuffer`** `[WWDC]`, and the new `installAudioTap` vends exactly
`AVReadOnlyAudioPCMBuffer` `[SDK]`. The spike at
`Design/specs/artifacts/mu-spike/src/audioprovider_test.swift:98` had to bridge from the old tap's
`AVAudioPCMBuffer` by hand; in 27 the types line up.

What that could unlock: live loudness and live pace off the `MixEngine` graph, feeding
auto-gain and the tension model in `tension-gestures-spec.md`. What it explicitly does **not**
unlock: faster-than-realtime library-wide analysis — the `audioProvider:` route is still
realtime-paced, which `mu-findings.md` already established and nothing in 27 changes.

Spike: measure whether a second `MusicUnderstandingSession` running off a live tap costs enough CPU
to disturb the render thread on an Apple TV. That is the only question that matters.

### 2.6 Foundation Models / Core AI

`FoundationModels.framework` and `CoreAI.framework` are in **both** SDKs `[SDK]`, so an on-device LLM
is available on the Apple TV, which is unexpected and worth knowing. iOS 27 adds multimodal prompts,
Dynamic Profiles, and Private Cloud Compute access for small developers. `[DOC]`
([iOS what's new](https://developer.apple.com/ios/whats-new/))

Plausible uses here, in descending order of how much I believe them: explaining a transition choice
("mixing into this because it shares a key and drops 4 BPM"), which `dj-engine-spec.md`'s scoring
registry already has the structured inputs for; normalising SoundCloud's freeform genre tags into
`GenreTaxonomy`; and generating "behind the track" copy for `BehindTheTrackView`.

Spike, not adopt: none of these is load-bearing, and a model in the DJ decision loop is a
latency and determinism risk in a system that is explicitly designed to be *reproducible* (seeded
softmax, memory decay). Keep it on the explanation side of the boundary, never the decision side.

### 2.7 `@State` as a macro — source-breaking, so measure before upgrading

Xcode 27 reimplements `@State` as a Swift macro so an initial-value expression is evaluated once
rather than on every view re-instantiation. It back-deploys to iOS 17. It is "largely source
compatible, with a few exceptions". `[RN]` (radar 105893279, both release notes)

The breaking case: you may no longer both give a default value at the declaration **and** assign it
in `init`. Apple published
[TN3211](https://developer.apple.com/documentation/Technotes/tn3211-resolving-swiftUI-source-incompatibilities-for-state-and-contentbuilder)
for this. `[WWDC]`

This app has a lot of `@State`, including in the two largest view files (`PlayerView.swift` 2260
lines, `TransportBarView.swift` 2061 lines). Spike = build both targets against the 27 SDK and count
the diagnostics. If the count is zero, this section is closed; if not, it is mechanical but wide.
Related: `@ContentBuilder` replaces the per-container builders and is claimed to cut type-checking
time substantially — worth measuring on `PlayerView.swift` specifically.

### 2.8 Genuinely-new tvOS SwiftUI, all of it small

The complete list of SwiftUI symbols annotated `tvOS 27.0` in the tvOS SDK, after filtering out
internal plumbing `[SDK]` (41 raw matches in `SwiftUI.swiftinterface`, 22 in `SwiftUICore.swiftinterface`
of which **every single one** is `_propertyStorageSize` / `_preferenceValuesEqual` / package-internal
geometry helpers):

- `ToolbarItemVisibilityPriority` + `visibilityPriority(_:)` on `ToolbarContent`
- `TabContent.help(_:)`
- `TabsPickerStyle`
- `NavigationTransition` / `AnyNavigationTransition` / `CrossFadeNavigationTransition`

That is the whole of it. The tvOS app has no toolbars and only one `NavigationStack`
(`SettingsView.swift:117`), so the practical value is near zero — but `CrossFadeNavigationTransition`
on the Settings stack is a two-line experiment, and the negative result above is worth recording so
nobody goes looking again.

### 2.9 `systemExtraLargePortrait`, and the prior question of Home Screen widgets at all

`WidgetFamily.systemExtraLargePortrait` is `@available(iOS 27.0, macOS 27.0, visionOS 26.0, *)`,
`@available(tvOS, unavailable)`. `[SDK]`
(`IOS/…/WidgetKit.swiftmodule/arm64e-apple-ios.swiftinterface:951–954`)

The prior question is bigger: `SoundingTV-Widget` contains a Live Activity and five App Intents and
**no Home Screen widget at all** — no `StaticConfiguration`, no `AppIntentConfiguration`, no timeline
provider, no `ControlWidget`. A "recently played / resume" widget is the obvious missing surface, and
`widgetAccentedRenderingMode(_:)` and `containerBackground(for:)` are the modern styling hooks.
`[WWDC]` ([WidgetKit foundations, session 277](https://developer.apple.com/videos/play/wwdc2026/277/))

Spike the product question first, not the API.

### 2.10 `AVPlaybackUserInterfaceControllable` — iPhone only, and only if the phone player grows

New in iOS 27, `@available(ios(27.0)) API_UNAVAILABLE(tvos, visionos, macos, watchos)` `[SDK]`
(`IOS/System/Library/Frameworks/AVKit.framework/Headers/AVPlaybackUserInterfaceControllable.h`). A
protocol family — `AVPlaybackUserInterfacePlaybackControllable` (`:379`), `…TimeControllable`
(`:431`), `…MediaSelectionControllable` (`:477`), `…VolumeControllable` (`:509`),
`…MetadataProviding` (`:528`), composed at `:543` — plus `AVPlaybackUserInterfaceTimelineSegment`
(`:94`), `…MediaSelectionOption` (`:139`), `…ContentMetadata` (`:289`), `…PlaybackPosition` (`:347`).
In Swift these are `@MainActor … : AnyObject, Observable`
(`AVKit.swiftmodule/arm64e-apple-ios.swiftinterface:123–188`).

It is a "drive the system player UI from your own playback engine" seam. Worth knowing about because
`TransportBarView.swift` is 2061 lines of hand-built transport UI; whether any of it could be
delegated to the system is a real question, but it is a big design decision and the tvOS half of the
app cannot follow. **tvOS AVKit has zero new API in 27** `[SDK]` — a clean negative result.

Spike only if the phone's full-screen player is being reworked anyway.

### 2.11 `SpotlightSearchTool` — natural-language search over the user's own library

**New in 27, and one of the best customer features in this survey.** `[SDK]`

```
IOS/System/Library/Frameworks/_CoreSpotlight_FoundationModels.framework/…/arm64e-apple-ios.swiftinterface:12
@available(macOS 27.0, iOS 27.0, visionOS 27.0, *)  @available(tvOS, unavailable) @available(watchOS, unavailable)
public struct CoreSpotlightSource   { init(searchableIndexDelegate:fetchAttributes:) }
:25  public struct FileSource
:34  public struct SearchSource
:48  public struct SpotlightSearchTool.Configuration
:57  init(sources:guide:contactResolver:customStages:maximumResponseSize:)
```

A cross-import overlay between `CoreSpotlight` and `FoundationModels`: `SpotlightSearchTool` conforms
to the Foundation Models `Tool` protocol, so a `LanguageModelSession` can search your app's
Core Spotlight index and answer in natural language, grounded in real indexed content — RAG, with
Apple supplying both the retriever and the model. It supports semantic search over text *and*
structured search over metadata, and `customStages` lets you add your own pipeline computation.
`[WWDC]` ([LLM search using Core Spotlight, session 246](https://developer.apple.com/videos/play/wwdc2026/246/))

Why this is a genuinely good fit here: the app already has a rich, structured, *personal* corpus —
likes, playlists, listening history, and an `AnalysisCache` holding BPM, key and (soon) MU output
per track. Questions like *"what have I liked that's around 124 and in a minor key"* or *"what deep
house did I save last year"* are exactly what this answers, and they are questions SoundCloud's own
search cannot answer because it does not know your local analysis data.

**Prerequisite the app does not currently meet:** it must donate `CSSearchableItem`s to Core
Spotlight. There is **no CoreSpotlight usage anywhere in the repo** — no `CSSearchableItem`, no
`CSSearchableIndex`, no `CSSearchableIndexDelegate`. So this is really two pieces of work: index the
library (worthwhile on its own — it makes tracks findable from system Spotlight, which is C9-adjacent
free value), then bolt the tool on.

`tvOS` unavailable. The Apple TV would have to ask the phone.

Spike: index a few hundred tracks, wire the tool, and find out whether the on-device model's answers
are good enough to ship. That last part is the whole risk and cannot be predicted from the API.

---

## 3. Deliberately not

This section is the point of the document. Each entry is something that looks like it belongs in §1
and does not, with the reason, so it does not get re-proposed.

### 3.1 Do **not** rip out `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` as a deprecation fix

They are **not deprecated.** Apple's documentation reports `deprecated: false` for
`MPNowPlayingInfoCenter` on every platform — iOS, iPadOS, Mac Catalyst, macOS, tvOS, visionOS,
watchOS — with no replacement guidance. `[DOC]`
([MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter))
Corroborating: the AVSystemRouting article, written for the 27 SDK, actively instructs you to
"report your playback metadata to `MPNowPlayingInfoCenter`". `[DOC]`

So NowPlaying (§1.2) is **additive**. Adopt it for `MediaCommand.feedback`, repeat/shuffle modes and
sized artwork. Do not schedule a "migrate off the deprecated Now Playing API" task, because there
isn't one, and do not delete the `MPNowPlayingInfoCenter` code as part of the NowPlaying work until
you have proved the system surfaces are equivalent on a real Apple TV.

### 3.2 tvOS does not get `reorderable()`, `swipeActionsContainer()`, or `ToolbarOverflowMenu`

All three are explicitly `@available(tvOS, unavailable)` in the tvOS SDK. `[SDK]`
(`SwiftUI.swiftinterface:12775, 12785, 12789, 12793, 12797` / `:21224` / `:31361`) Any plan for
drag-to-reorder the queue **on the TV** must still be hand-built against focus-based interaction, and
`swipeActions` remains a phone idiom. Same for `tabViewBottomAccessory`, which is iOS 26 only
(`:17957`) — the tvOS app's `TabView` (`RootView.swift:124`) cannot host a bottom accessory, which is
why the mini-player pattern is iOS-only and should stay that way.

### 3.3 The `.audio` App Schema domain does not exist on tvOS

`@available(tvOS, unavailable)` on the whole domain. `[SDK]`
(`AppIntents.swiftinterface:8249, 8254, 8264`) Do not plan Siri media control *on the Apple TV*
around App Schemas. Route it through the phone.

### 3.4 ~~None of the new App Intents APIs support tvOS~~ — **corrected: most of them do**

This entry started life as a "deliberately not", sourced from session 345, whose platform table
marks every new App Intents API as unsupported on tvOS. `[WWDC]`
([Discover new capabilities in the App Intents framework, session 345](https://developer.apple.com/videos/play/wwdc2026/345/))

**The SDK disagrees.** The **tvOS** `AppIntents.swiftinterface` (13,837 lines) carries 219
availability lines gated at 27, of which only ~36 are immediately `@available(tvOS, unavailable)`.
tvOS-live in 27 `[SDK]`:

```
:1564-1591  IntentExecutionTargets (.main / .appIntentsExtension / .widgetKitExtension),
            AppIntent.allowedExecutionTargets (:1105), EntityQuery (:2219), IntentValueQuery (:2409)
:1593-1617  LongRunningIntent + performBackgroundTask(options:operation:), LongRunningTaskOptions.requiresGPU,
            IntentResponseStream<Value>
:711-747    SyncableEntity / SyncableEntityIdentifier<LocalID, StableID>
:1710-1756  AppUnionValue / AppUnionValueCasesProviding
:5574-5640  EntityCollection<Entity> with resolvedEntities() async throws
:5952-5970  EntityOwnership / OwnershipProvidingEntity
:2810-2841  RelevantEntities.shared + AppEntityContext, including AudioContext.nowPlaying
:1311-1321  CustomAppIntentErrorConvertible
:2225-2228  EntityQuery.displayRepresentations(for:)   (DisplayRepresentation.Components deprecated at 27.0)
:3044-3051  IntentSystemContext.isVoiceOnly, .locale
```

**What is genuinely tvOS-unavailable is the *schema domains*** — Messages, Audio, Photos, Reminders,
Clock, Notes, Browser, Calendar, Mail, Phone, Maps, SystemIntent — each gated at 27.0 *and*
`@available(tvOS, unavailable)` (e.g. `:7975–8030`). That is §3.3, and it stands. iOS-only extras:
`SystemShortcut` / `RunSystemShortcutIntent`, `IndexedEntityQuery`,
`CSSearchableItem.relatedAppEntityIdentifier`.

`AssistantSchemas` is blanket-renamed to `AppSchema` (`:18–40`), and there is **no new snippet API**
— `SnippetIntent` is 26.0, not 27.

So the correct statement is: *tvOS gets the App Intents plumbing but not the Siri schema contracts.*
The one that stands out for this app is `RelevantEntities.shared` with
`AppEntityContext.audio(.nowPlaying)` — a system channel for "these entities are relevant to what is
playing right now" — which works on the Apple TV and has an obvious mapping onto the DJ engine's
candidate set.

(`IntentExecutionTargets` is also more interesting than it first looks: `PlaybackControlIntents`
currently runs in the widget process and opens a one-shot `NWBrowser`/`NWConnection` per invocation
(`WidgetControlSender.swift`); `allowedExecutionTargets: .main` would let it reuse the app's live
connection when the app is running. Filed as a note, not a recommendation — the one-shot design is
deliberate and is what works when the app is *not* running, which is the common case.)

**Kept in §3 rather than promoted to §1** because this is exactly the class of claim that needs a
compile before anyone plans around it, and because the *product* case for App Intents on the TV is
still weak. But the blanket "not on tvOS" is wrong and should not be repeated.

### 3.5 "Compose advanced graphics effects with SwiftUI" contains no new API

Session 322 is genuinely relevant to the ambient backdrop (`AmbientScreenView.swift`,
`ArtworkColors.swift`) — layered domain warping over blurred cover art is a much better-looking
version of what `CIAreaAverage` currently produces. But every API it uses is old:
`colorEffect(_:)`, `distortionEffect(_:)`, `layerEffect(_:maxSampleOffset:)`, `TimelineView(.animation)`
and `alignmentGuide(_:)` all predate 27 by years. `[WWDC]`
([session 322](https://developer.apple.com/videos/play/wwdc2026/322/))

Do not file this as an "OS 27 feature". File it as a visual-design idea, in
`visual-audit.md`'s territory. Note also that it would introduce Metal shaders to a codebase that
currently has **zero** `.metal` files and zero `import Metal`.

### 3.6 "Dive into lazy stacks and scrolling" also contains no new API

Same verdict. `ScrollPosition`, `onScrollGeometryChange`, `onScrollTargetVisibilityChange` and
`scrollTransition` are iOS 18-era. `[WWDC]`
([session 321](https://developer.apple.com/videos/play/wwdc2026/321/)) The session's *advice* is
worth reading for `LibraryView.swift`'s `LazyVGrid`s and `HomeView.swift`'s rails — particularly
"set up state in the initialiser, not `onAppear`, so prefetch can work", and "avoid dynamic subview
counts in `ForEach`" — but there is nothing to adopt.

### 3.7 LiveCommunicationKit is not a device-to-device networking framework

Session 226 is about `ConversationManager`, `Conversation`, `Handle`, `JoinConversationAction`,
PushKit VoIP pushes and Lock Screen call UI. `[WWDC]`
([session 226](https://developer.apple.com/videos/play/wwdc2026/226/)) It is CallKit's successor for
real-time *conversations*. Nothing to do with Bonjour, `NWConnection`, or handing audio between two
of your own devices. The name is misleading; that is the only reason it is in this list.

### 3.8 gRPC Swift is not an upgrade path for the Bonjour protocol

Session 265 introduces first-party gRPC for Swift. `[WWDC]`
([session 265](https://developer.apple.com/videos/play/wwdc2026/265/)) The existing wire format —
`MessageFraming` with a big-endian `UInt32` length prefix, `maxFrameBytes = 1 << 20`, and a
`MessageFramer` incremental reader (`TokenTransferProtocol.swift:1414–1470`) — is about 60 lines,
is byte-identical across the two live copies by policy, and carries a TLS-PSK handshake
(`PairingTLS.makeParameters` at `:586`). Replacing that with HTTP/2 + protobuf + a code generator,
for a two-peer link on the same LAN, is strictly more moving parts for no capability the app needs.
No.

`NWProtocolFramer` is likewise still unused and still doesn't need to be.

### 3.9 The SwiftUI document redesign does not touch this app

`FileDocument` is deprecated in favour of `ReadableDocument` / `WritableDocument` / `Document`,
alongside `DocumentGroupLaunchScene`, `NewDocumentButton`, `DocumentReader` / `DocumentWriter`.
`[RN]` (radars 177458781, 178776840) The app has no documents, no `DocumentGroup`, no
`FileDocument`. Ignore the entire area.

### 3.10 On Demand Resources deprecation does not apply

`NSBundleResourceRequest` is deprecated in favour of Background Assets. `[RN]` (radar 170066290,
tvOS 27 release notes) The app does not use ODR. `DownloadManager.swift` uses a background
`URLSession` (`URLSessionConfiguration.background(withIdentifier:)` at `:268`), which is unaffected.

### 3.11 MetricKit's deprecation does not apply

`MXMetricManager`, `MXMetricManagerSubscriber`, `MXMetricPayload` and `MXDiagnosticPayload` are
deprecated in favour of a new `MetricManager` with an `AsyncStream` interface. `[RN]` (radar
174892111) MetricKit is not imported anywhere in this repo.

### 3.12 Do not hand-roll a CoreML model for audio analysis

`CoreAI` and on-device model tooling are genuinely new and genuinely good. They are also entirely
the wrong tool for BPM/key/loudness/structure, because `MusicUnderstanding` ships exactly that,
tuned by Apple, on both platforms (§1.5). The repo currently has zero CoreML usage; keep it that
way for the analysis path. `mu-findings.md` already measured MU at 10/11 exact on BPM and 8/11 on
key against the existing vDSP baseline.

### 3.13 Live Activity `ActivityFamily` / `supplementalActivityFamilies` is **not** new in 27

Session 223 presents `.supplementalActivityFamilies([.small])`, `\.activityFamily` and Apple Watch /
CarPlay Live Activity support as new in this release, with a table marking them "27+". `[WWDC]`
([session 223](https://developer.apple.com/videos/play/wwdc2026/223/))

The SDK disagrees, and the SDK wins: `[SDK]`

```
IOS/…/WidgetKit.swiftmodule/arm64e-apple-ios.swiftinterface:744   @available(iOS 18.0, *)  public enum ActivityFamily { case small; case medium }
IOS/…:770                                                          @available(iOS 18.0, *)  func supplementalActivityFamilies(_:)
IOS/…:782                                                          @available(iOS 18.0, *)  var activityFamily
IOS/…:1026                                                         @available(iOS 15.0, …)  var showsWidgetContainerBackground
```

Only `isDynamicIslandLimitedInWidth` is actually iOS 27 (`:605–610`), for the new Dynamic Island
landscape presentation.

Corroborating at the framework level: **ActivityKit's entire Swift interface contains no 27.0 API at
all** — the only "27.0" string in its 632 lines is the module-flags target triple, and the highest
availability marker anywhere in the file is `iOS 26.0`. `[SDK]`

The practical conclusion is unchanged — the app's Live Activity
(`NowPlayingLiveActivityWidget.swift`) has never adopted the small family and should — but it belongs
in §6 as pre-existing debt, not in a list of things iOS 27 made possible. Recorded here because this
is the concrete instance of the failure mode this project has been burned by before.

### 3.14 27.0 deprecations the app does not hit

For completeness, so nobody chases them. All `[SDK]`:

- `AVAudioNode.auAudioUnit` / `AVAudioUnit.audioUnit` (→ `withAUAudioUnit(_:)` / `withAudioUnit(_:)`,
  `AVFAudio.swiftinterface:75–77, 93, 111`) and `AVAudioEngine.musicSequence`
  (→ `withMusicSequence(_:)`, `:136`) — no direct `AUAudioUnit` access or `MusicSequence` anywhere.
- All four `connectMIDI(…block:)` / `connectMIDI(…eventListBlock:)` variants
  (→ `…eventListProvider:`, `AVAudioEngine.h:847, 952`) — no MIDI.
- `AVAudioFormat.initWithCMAudioFormatDescription:` (→ `initWithFormatDescription:`, correctly
  `nullable` this time, `AVAudioFormat.h:151/161`) — not used.
- **`AVSampleBufferAudioRenderer` and `AVQueuedSampleBufferRendering` are comprehensively
  deprecated** at 27.0 — nearly every member (`AVQueuedSampleBufferRendering.h:27, 59, 75, 97, 112,
  124, 136`; `AVSampleBufferAudioRenderer.h:40, 52, 121, 137, 149, 161`) — in favour of
  `AVSampleBufferAudioRenderer.Receiver` with `enqueue(_:) async throws -> EnqueueResult`,
  `enqueueImmediately(_:)`, and a `renderingEventsAfterFinishedEnqueuing` `AsyncSequence`
  (overlay `:1688–1724`). **The app uses none of it** — playback is `AVPlayer`, DJ is
  `AVAudioEngine`. Listed because the scale of the deprecation makes it look alarming in a build log
  it will never appear in.
- `AVAssetExportSession.exportAsynchronouslyWithCompletionHandler:` / `.progress` / `.cancelExport`
  (→ `export(to:as:)`, `states(updateInterval:)`, `Task.cancel()`) — no export path.
- `AVAsset.audiovisualTypes` (→ `audiovisualContentTypes`, itself 26.0) — not used.
- `DisplayRepresentation.Components` in AppIntents — not used.
- `SHMediaItem.songs` property (→ `songs() async throws -> [MusicKit.Song]`) — ShazamKit not used.

**ActivityKit has nothing new and nothing deprecated in 27.0** — the only "27.0" string in its
632-line interface is the module-flags target triple, and the highest availability marker in the
whole file is `iOS 26.0`. `[SDK]` This is the SDK-level confirmation of §3.13.

**CoreML has nothing new in 27.0** — neither the Swift interface nor any of its 71 ObjC headers, on
either SDK. `[SDK]` So does CreateML, CreateMLComponents, and SoundAnalysis (whose entire Swift
interface is 27 lines, topping out at 15.0). More evidence for §3.12.

### 3.15 The UIKit scene-lifecycle mandate

"Apps built with the latest SDK must adopt the scene-based life cycle or they fail to launch."
`[RN]` (radar 141837548, tvOS 27 release notes) Both apps are SwiftUI `App`-lifecycle
(`SoundingTVApp.swift`, `SoundingTViOSApp.swift`), which satisfies this. Listed only because "fail
to launch" deserves a positive confirmation rather than silence. Worth one grep for a
`UIApplicationDelegate`-only launch path before the next device build.

---

## 4. Deprecations that hit this codebase — the full table

> **Compiler-verified 2026-08-03.** The table below was written from SDK headers, then checked
> against a real `xcodebuild -scheme SoundingTV -destination 'generic/platform=tvOS'` run. The build
> emits **28 `deprecated in tvOS 27.0` warnings across exactly two files**, and they match this
> table. Verified call sites, for whoever does the migration:
>
> ```
> MixEngine.swift      526, 527, 528, 529, 540, 790          connect(_:to:[fromBus:toBus:]format:)
> MixEngine.swift      594                                    installTap(onBus:bufferSize:format:block:)
> MixEngine.swift      973, 1028, 1102, 1248, 1287            play()
> MixEngine.swift      1144                                   play(at:)
> MixEngine.swift      2400, 2404, 2406, 2454                 alwaysCopiesSampleData, add, startReading, copyNextSampleBuffer
> MixEngine.swift      2803, 2807, 2831, 2840                 expectsMediaDataInRealTime, add, startWriting, isReadyForMoreMediaData
> PlayerService.swift  480, 491                               InterruptionType, InterruptionOptions
> PlayerService.swift  882, 893                               AVPlayerItemPlaybackStalled, AVPlayerItemDidPlayToEndTime
> PlayerService.swift  3210, 3211, 3217                       alwaysCopiesSampleData, add, startReading
> ```
>
> Two rows were upgraded from inferred to confirmed by this run: `AVAssetWriterInput.isReadyForMoreMediaData`
> (`MixEngine.swift:2840`) and both `AVAssetReader.add(_:)` / `AVAssetWriter.add(_:)` sites. Note the
> line numbers drift — the tree is under active edit; re-grep before relying on them.
>
> **The migration was not performed.** See the note at the end of this section.

Every row verified `[SDK]` in `AppleTVOS27.0.sdk` unless marked otherwise. "Mechanical" means rename
plus `try`; "redesign" means the calling code's shape changes.

| Deprecated symbol | Replacement | Call sites | Nature |
|---|---|---|---|
| `AVAudioEngine.connect(_:to:format:)` | `connectNode(_:to:format:)` throws | `MixEngine.swift:516, 517, 518, 519` | Mechanical |
| `AVAudioEngine.connect(_:to:fromBus:toBus:format:)` | `connectNode(_:to:fromBus:toBus:format:)` throws | `MixEngine.swift:530, 778` | Mechanical |
| `AVAudioPlayerNode.play()` | `playAudio()` throws | `MixEngine.swift:961, 1016, 1090, 1236, 1275` | Mechanical |
| `AVAudioPlayerNode.play(at:)` | `playAudio(at:)` throws | `MixEngine.swift:1132` | Mechanical — **re-measure drift** |
| `AVAudioNode.installTap(onBus:bufferSize:format:block:)` | `installAudioTap(onBus:bufferSize:format:tapProvider:)` throws, `@Sendable`, `AVReadOnlyAudioPCMBuffer` | `MixEngine.swift:584` | Small redesign (buffer accessors + `Sendable` capture). **Fix-it is broken — see §1.1** |
| **`AVAudioSessionInterruptionNotification`** + `…TypeKey`, `…OptionKey`, `…ReasonKey`, `AVAudioSessionInterruptionType`, `AVAudioSessionInterruptionOptions` | `AVAudioSessionDidBecomeInactiveNotification` + `AVAudioSessionResumptionRecommendationNotification`, with `DeactivationContext` / `ResumptionContext` | `PlayerService.swift:452, 474, 485` | **Redesign — the interruption model changed. §1.6** |
| `NSNotification.Name.AVPlayerItemPlaybackStalled` | `AVPlayerItem.playbackStalledNotification` | `PlayerService.swift:841` | Pure rename (Swift-only) |
| `NSNotification.Name.AVPlayerItemDidPlayToEndTime` | `AVPlayerItem.didPlayToEndTimeNotification` | `PlayerService.swift:852` | Pure rename (Swift-only) |
| `.AVPlayerItemFailedToPlayToEndTime`, `.AVPlayerItemTimeJumped`, `.AVPlayerItemNewAccessLogEntry`, `.AVPlayerItemNewErrorLogEntry` | `AVPlayerItem.<x>Notification` | none found — check before assuming | Pure rename |
| `AVPlayerItem.accessLog` / `.errorLog` (sync) | `fetchAccessLogWithCompletionHandler:` / `fetchErrorLogWithCompletionHandler:` (`getter:accessLog()` async) | none found | Mechanical |
| `AVAssetReader.startReading()` | `AVAssetReader.start()` throws — **Swift-only deprecation** (`#if __swift__`), replacement is **26.0** | `MixEngine.swift:2394`, `PlayerService.swift:3133` | Mechanical |
| `AVAssetReaderOutput.copyNextSampleBuffer()` | `AVAssetReaderOutput.Provider<Payload>.next() async throws`, vending `CMReadySampleBuffer<CMSampleBuffer.DynamicContent>` | `MixEngine.swift:2442`, `PlayerService.swift:3142` | **Redesign** — callers become async |
| `AVAssetReaderOutput.alwaysCopiesSampleData` | **none — deliberately.** Message: *"It is not necessary to copy the sample data in order to make it safe to use the vended buffer"*; the new provider vends a Sendable value type | `MixEngine.swift:2388`, `PlayerService.swift:3126` | Delete the line |
| `AVAssetReader.add(_:)` | `outputProvider(for:)` / `outputProviderWithRandomAccess(for:)` | implied by the two reader loops | Redesign |
| `AVAssetWriter.startWriting()` | `AVAssetWriter.start()` throws (26.0) | `MixEngine.swift:2819` | Mechanical |
| `AVAssetWriterInput.expectsMediaDataInRealTime` | **`SampleBufferReceiver.appendImmediately(_:)` vs `await append(_:)`** — real-time-ness is now which method you call, not a property | `MixEngine.swift:2791` | Redesign |
| `AVAssetWriterInput.append(_:)`, `.isReadyForMoreMediaData`, `.requestMediaDataWhenReady(on:using:)` | `AVAssetWriterInput.SampleBufferReceiver` | `MixEngine.swift` self-test writer | Redesign |
| `AVAssetWriter.add(_:)` | `inputReceiver(for:)` | `MixEngine.swift:2790` (implied) | Redesign |
| `SwiftUI .squareBorder` / `.roundedBorder` text field styles | `.bordered` + `textInputBorderShape(_:)` `[RN]` | none found | n/a |
| `SwiftUI FileDocument` | `ReadableDocument` / `Document` `[RN]` | none | n/a — §3.9 |
| `NSBundleResourceRequest` (ODR) | Background Assets `[RN]` | none | n/a — §3.10 |
| `MXMetricManager` et al. | `MetricManager` `[RN]` | none | n/a — §3.11 |
| `AVAudioNode.auAudioUnit`, `AVAudioEngine.musicSequence`, `connectMIDI(…block:)` | scoped/provider forms | none | n/a — §3.14 |

A structural note on the AVFoundation rows: **most of them are `#if __swift__`-guarded**, i.e.
deprecated for Swift callers only, with the ObjC declaration left untouched. `[SDK]`
(`AVAssetReader.h:205–212`, `AVAssetReaderOutput.h:95–100`, `AVAssetWriter.h:202–209`,
`AVAssetWriterInput.h:174–181`) And the replacements are marked **26.0**, not 27.0 — the new Swift
API shipped a year earlier and 27.0 is simply when the old one started warning. At a 27.0
deployment floor that means there is no availability gymnastics and no `if #available` anywhere in
this migration.

**Suggested sequencing:** (a) the mechanical AVFAudio rows and the `AVPlayerItem` notification
renames in one pass, with a drift re-measurement on `play(at:)`; (b) the tap; (c) the AVAudioSession
interruption-model change (§1.6), which has real behaviour in it and deserves its own testing;
(d) the reader/writer redesign as a separate change with its own verification. Do not mix (a) and
(d) in one commit — (a) should be reviewable as pure rename noise.

### Why the migration was not performed in this pass

It was attempted and deliberately abandoned. Three blockers, all of them still true as of
2026-08-03 05:09:

1. **The tree does not build.** `xcodebuild -scheme SoundingTV -destination 'generic/platform=tvOS'`
   exits 65 on `Views/Feed/FeedView.swift:66:54` — *"contextual closure type
   `(NavigationState.Tab) -> Void` expects 1 argument, but 2 were used in closure body"*. That is
   unrelated in-flight Feed work. With a red baseline there is no way to tell a regression caused by
   the migration from one that was already there, and `MixEngine` is the file where that distinction
   matters most.
2. **Another session is editing the same two files concurrently.** At the time of the attempt:
   `AudioSessionCoordinator.swift` modified 74 seconds earlier, `MixEngine.swift` and
   `PlayerService.swift` ~4 minutes earlier, `project.pbxproj` ~2.5 minutes earlier, and 20+ files
   across `Sources/` inside 30 minutes — including files (`Views/Feed/`, `Models/FeedActivity.swift`)
   that did not exist when this survey's code map was built. Editing `MixEngine.swift` under those
   conditions risks landing an edit on a stale read.
3. **`AudioSessionCoordinator.swift` is itself mid-rewrite**, and it is the exact file §1.6 says the
   interruption migration should land behind. Doing §1.6 now would collide head-on.

**Preconditions for doing it:** the `FeedView.swift` error fixed and the tvOS scheme green; the
concurrent session quiesced or the work done in a worktree; and — because several §1 items need new
files registered — `project.pbxproj` edits made from the main session, per CLAUDE.md.

---

## 5. Behaviour changes in the 27 SDKs to verify

These are not APIs to adopt; they are things that change **because you build against the 27 SDK**.
All `[RN]`, from the
[tvOS 27](https://developer.apple.com/documentation/tvos-release-notes/tvos-27-release-notes) and
[iOS/iPadOS 27](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
release notes.

1. **tvOS button tinting changed.** *"Buttons on tvOS no longer automatically use the accent color
   from an app's asset catalog as a label tint color when building against the tvOS 27 SDK."*
   (171830912) The design system is built on `Color.sc*` accents (`DesignSystem.swift`). Check every
   tvOS `Button` label — some may silently lose their tint. **Highest-risk item in this section.**
2. **`TabView` now crashes if `selection` is set to a hidden tab.** (164516837) `RootView.swift:124`
   uses `TabView(selection:)` with a `.search`-role tab at `:142`. Verify no code path can select a
   tab that isn't currently visible — including the `SOUNDING_TV_TAB` debug launch hook.
3. **`containerRelativeFrame(_:alignment:)` safe-area behaviour was fixed** under the 27 SDK
   (165913417). The fix changes computed sizes on the non-scrollable axis. `HomeView.swift` and
   `LibraryView.swift` use container-relative sizing; re-screenshot them.
4. **`controlSize`, `buttonSizing`, `buttonRepeatBehavior`, `menuIndicatorVisibility` and
   `ButtonBorderShape` now reset to defaults inside sheets and popovers** under the 27 SDK
   (167448274). The iOS app presents pairing via `fullScreenCover` and has several sheets; check for
   controls that were relying on an inherited `controlSize`.
5. **`Menu` labels may no longer contain controls, gestures, or view representables with gesture
   recognizers** (169091260).
6. **`@State` macro source incompatibilities** (105893279) — §2.6.
7. **Swift Charts warns** when the deployment target is below 27.0 and a `Chart` closure uses a
   conditional (174168981). Not applicable — no Swift Charts usage — but noted in case the DJ
   analytics views ever reach for it.
8. **`systemPrefersReducedResourceUsage`** is new at `ios(27.0), tvos(27.0)` `[SDK]`
   (`UIKit/UITraitCollection.h:146`, `UIApplication.h:185`, with
   `UIApplicationSystemPrefersReducedResourceUsageDidChangeNotification` at `UIApplication.h:596`).
   This is the system asking an app to back off. A tvOS app running `AVAudioEngine` with two decks,
   a vDSP meter tap, an FFT analyser and a `TimelineView(.animation)` pulse view is precisely the
   kind of app it is aimed at. Not a deprecation and not required — but this app should probably
   honour it, at minimum by dropping `PulseTimeline`'s frame rate
   (`WaveformService.swift:768`) and `DJControlView`'s `1/30` timeline (`:366`), and by pausing
   background analysis. Filed here rather than in §1 because it needs a product decision about what
   "reduced" should mean, not just an API call.

---

## 6. Not new in 27, but still unadopted

Surfaced by the same sessions, and all of it available today. None of this belongs in §1 — it is
not new — but a survey that only listed 27-only APIs would leave the impression that the app is
current, and it isn't.

1. **`AudioPlaybackIntent`** (iOS 17). The five intents in
   `SoundingTV-Widget/Sources/PlaybackControlIntents.swift:67, 81, 95, 105, 117` are plain
   `AppIntent`s. `AudioPlaybackIntent` is the protocol that lets an intent *start audio* from a
   background process. This is arguably a correctness issue, not a nicety.
2. **`LiveActivityIntent`** (iOS 17.2). Buttons inside a Live Activity should use it; the app's
   Live Activity (`NowPlayingLiveActivityWidget.swift`) has no interactive controls at all.
3. **`AppShortcutsProvider` / `AppShortcut`** — absent entirely. Without it none of the app's intents
   appear in Shortcuts or Siri without the user building a shortcut by hand.
4. **`ControlWidget` / `ControlWidgetButton`** (iOS 18) — absent. A Control Center "play/pause
   SoundingCloud" toggle is the single most obvious missing surface for a music app.
5. **`ActivityFamily.small` via `supplementalActivityFamilies([.small])`** (iOS 18, see §3.13) —
   absent. This is what puts the Live Activity in the Apple Watch Smart Stack and the CarPlay
   Dashboard, **without a watchOS target**.
6. **Home Screen widgets of any kind** — see §2.9.
7. **`ScrollPosition` / `onScrollTargetVisibilityChange`** (iOS 18) and the prefetch discipline from
   session 321 — see §3.6.
8. **Visual intelligence integration** (iOS 26). `VisualIntelligence.framework` is in the iOS SDK
   and **absent from tvOS** `[SDK]`; `SemanticContentDescriptor` is `@available(iOS 26.0, macOS 27.0,
   macCatalyst 27.0, *)` (`VisualIntelligence.swiftinterface:35–38`) and `IntentValueQuery` is
   `@available(anyAppleOS 26.0, *)` (`AppIntents.swiftinterface:2680`). So this is **not** a 27
   feature — but session 297's worked example is *literally a music app*: point the camera at album
   art or a poster, get matching albums back, tap through via an `OpenIntent`. `[WWDC]`
   ([Best practices for integrating visual intelligence, session 297](https://developer.apple.com/videos/play/wwdc2026/297/))
   The recipe is an `AppEntity` + an `IntentValueQuery` taking a `SemanticContentDescriptor` +
   an `OpenIntent`, with Vision's `GenerateImageFeaturePrintRequest` pre-computed per item for
   similarity matching. For a SoundCloud client, "photograph the flyer, find the artist" is a
   plausibly great feature and the app already has `SoundCloudAPI.search` and artwork URLs to build
   feature prints from. **No `VisualIntelligence` import exists in the repo.**
9. **Dynamic Island landscape and StandBy** for the Live Activity. `isDynamicIslandLimitedInWidth`
   *is* new at `@available(iOS 27.0, *)` `[SDK]` (`WidgetKit.swiftinterface:605–610`) — that one is
   real. The StandBy presentation (Lock Screen view scaled to 200% while charging in landscape,
   tinted edge-to-edge via `activityBackgroundTint(_:)`) is described in session 223 as system
   behaviour rather than new API, and `showsWidgetContainerBackground` is `iOS 15.0` `[SDK]`, so
   treat the StandBy claim as `[WWDC]`-only. Either way the app's Live Activity handles neither
   case.
10. **`RelevantEntities.shared.updateEntities(_:for:)` with `AppEntityContext.audio(...)`** — surfaces
    your playlists in the Fitness app's media picker when a workout starts, among other contexts.
    The API is available on **tvOS as well as iOS** (§3.4), and the iOS 27 release notes carry a
    fix for *"Entities registered via `RelevantEntities` for workout audio context don't appear in
    Fitness media picker"* (177996973) `[RN]`, which is good evidence the flow is real and
    supported. Requires `AppEntity` conformances the app does not yet have.

Items 1–5 are all in `SoundingTV-Widget`, which suggests that target has had less attention than
the two apps. Items 8 and 10 both require `AppEntity` conformances for `Track` / `User` / `Playlist`
— **that single piece of work unblocks C1, C2, C9 and C10 at once**, and is the highest-leverage
thing on this list.

---

## 7. What this changes about plans already made

- **`watchos-plan.md`.** Its verdict ("technically possible, not worth doing") is not overturned by
  anything in 27 — but §3.13 is relevant to *how* the Watch gets a presence. Live Activity
  `ActivityFamily.small` lands SoundingCloud in the Watch Smart Stack **without a watchOS target**,
  and has been available since iOS 18 rather than being a new 27 capability. That is a materially
  cheaper path to the same user-visible outcome than the plan evaluates, and the plan should say so.
  Separately, `NowPlaying` is available on **watchOS 27** `[DOC]`, which changes what a future watch
  app would have to build itself.
- **`ipad-plan.md`.** `reorderable()` / `reorderContainer(for:)` and the extended `swipeActions`
  (§1.9) are available on iPadOS 27 and are directly useful for a CDJ-style console's crate and
  queue panes. Neither existed when that plan was written. The plan's "near-realtime network sync"
  section should also be read against §2.1 (AVSystemRouting `dataChannel`) before any new transport
  is designed.
- **`mu-findings.md`.** Still accurate on the hard constraint (local `file://` only; the
  `audioProvider:` route is realtime-paced). Two gaps to close: it never exercised
  `analyze(for:)` selective-dimension analysis or the `loudnessResults` streaming sequence (§1.5),
  and its `AudioProvider` bridging code predates `AVReadOnlyAudioPCMBuffer` (§2.4).
- **`dj-engine-spec.md`.** `InstrumentActivityResult` gives per-instrument presence *and* intensity
  over time, which the transition catalog does not currently use. "Mix over the instrumental
  section" is a better-grounded rule than "mix over the structural section", given that spec's own
  finding that `structure`/`phrases` often degenerate to generic 8-bar chunking.
- **`ArtworkImage.swift`.** Its second stated rationale ("`AsyncImage` doesn't cache") is obsolete
  as of the 27 SDK (§1.8). The file should stay; the comment should be corrected, because a stale
  rationale in a header comment is how the wrong decision gets re-made.
- **CLAUDE.md — two corrections.** (a) It says the 27.0 floor "unlocks `MusicUnderstanding` … and
  `NowPlaying`". True of the SDK; not yet true of the code — neither framework is imported by any
  shipping target (§1.5). Worth rewording to "makes available" so nobody reads it as "already
  adopted". (b) The stronger one: *"library-wide candidate analysis from a stream does not work"* was
  established against `MusicUnderstandingSession(asset:)` and is still true **of that API**, but
  27.0 ships `AVPlayerItemSampleBufferOutput` (HLS → decoded PCM) and
  `MTAudioProcessingTapCreateWithPreferredFormat`, neither of which existed when the constraint was
  written (§2.1). The claim should be narrowed to name the API it applies to, and the spike should
  run before the next time it is quoted as settled.
- **`WaveformService.swift:775–801`.** The written-up decision not to build an `MTAudioProcessingTap`
  ("Tier 3") predates `MTAudioProcessingTapCreateWithPreferredFormat` and
  `AVAudioMixInputParametersTrackMixID`. Re-read the rationale against the new inputs (§2.1) before
  treating it as still-current.
- **`visual-audit.md` / `ios-design-spec.md`.** Both are written against fixed point sizes. tvOS
  Dynamic Type (§1.3) means the tvOS half of that work now has a second axis, and the reference
  viewport numbers need a "at default text size" qualifier.

---

## 8. Sources

Apple documentation and release notes:

- [What's new — Apple Developer](https://developer.apple.com/whats-new/) — confirms iOS 27 / iPadOS 27 / macOS 27 / tvOS 27 / visionOS 27 / watchOS 27 and Xcode 27 beta
- [iOS — what's new](https://developer.apple.com/ios/whats-new/)
- [tvOS 27 release notes](https://developer.apple.com/documentation/tvos-release-notes/tvos-27-release-notes)
- [iOS & iPadOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
- [NowPlaying framework](https://developer.apple.com/documentation/nowplaying)
- [AVSystemRouting framework](https://developer.apple.com/documentation/avsystemrouting)
- [Routing media to third-party devices](https://developer.apple.com/documentation/AVSystemRouting/routing-media-to-third-party-devices)
- [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter) — deprecation status
- [AVAudioNode](https://developer.apple.com/documentation/avfaudio/avaudionode), [AVAudioPlayerNode](https://developer.apple.com/documentation/avfaudio/avaudioplayernode), [AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine)
- [AVReadOnlyAudioPCMBuffer](https://developer.apple.com/documentation/avfaudio/avreadonlyaudiopcmbuffer)
- [AVAssetReader](https://developer.apple.com/documentation/avfoundation/avassetreader), [AVAssetReaderOutput](https://developer.apple.com/documentation/avfoundation/avassetreaderoutput), [AVAssetReaderOutput.Provider](https://developer.apple.com/documentation/avfoundation/avassetreaderoutput/provider), [AVAssetWriter](https://developer.apple.com/documentation/avfoundation/avassetwriter), [AVAssetWriterInput](https://developer.apple.com/documentation/avfoundation/avassetwriterinput)
- [TN3211: Resolving SwiftUI source incompatibilities](https://developer.apple.com/documentation/Technotes/tn3211-resolving-swiftUI-source-incompatibilities-for-state-and-contentbuilder)

WWDC26 sessions:

- [253 — Meet the Music Understanding framework](https://developer.apple.com/videos/play/wwdc2026/253/)
- [312 — Meet the Now Playing framework](https://developer.apple.com/videos/play/wwdc2026/312/)
- [221 — Prepare your tvOS apps for Dynamic Type](https://developer.apple.com/videos/play/wwdc2026/221/)
- [269 — What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/)
- [321 — Dive into lazy stacks and scrolling with SwiftUI](https://developer.apple.com/videos/play/wwdc2026/321/)
- [322 — Compose advanced graphics effects with SwiftUI](https://developer.apple.com/videos/play/wwdc2026/322/)
- [223 — Live Activities essentials](https://developer.apple.com/videos/play/wwdc2026/223/)
- [277 — WidgetKit foundations](https://developer.apple.com/videos/play/wwdc2026/277/)
- [345 — Discover new capabilities in the App Intents framework](https://developer.apple.com/videos/play/wwdc2026/345/)
- [240 — Build intelligent Siri experiences with App Schemas](https://developer.apple.com/videos/play/wwdc2026/240/)
- [226 — Create live communication experiences](https://developer.apple.com/videos/play/wwdc2026/226/)
- [265 — Build real-time apps and services with gRPC and Swift](https://developer.apple.com/videos/play/wwdc2026/265/)
- [246 — LLM search using Core Spotlight](https://developer.apple.com/videos/play/wwdc2026/246/)
- [297 — Best practices for integrating visual intelligence in your app](https://developer.apple.com/videos/play/wwdc2026/297/)

**No session at WWDC26 covers the AVFoundation / AVFAudio deprecations in §4.** They shipped in the
SDK without session coverage, which is why §1.1 and §1.10 lean entirely on header and documentation
evidence.
