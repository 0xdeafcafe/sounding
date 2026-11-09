# OS 27 feature survey: eight planned features against the Xcode 27.2 SDKs

Written 2026-11-06. Read-only research; no code was changed. Companion to `os27-api-survey.md` (2026-08-03, written against the 27.0 beta SDKs). This one re-verifies against the shipping 27.2 SDKs and answers a narrower question: for each planned feature, what is the best API on 27, what is new versus 26, and where does it run.

## 0. Method, evidence, and limits

SDK roots (all `27.2`, Xcode 27.2 build 27B52):

```
IOS = /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.2.sdk
TV  = .../AppleTVOS.platform/Developer/SDKs/AppleTVOS27.2.sdk
WCH = .../WatchOS.platform/Developer/SDKs/WatchOS27.2.sdk
MAC = .../MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk
```

Evidence tags: `[SDK]` read in a `.swiftinterface` or header under those roots; `[DOC]` read in the doc comments embedded in the `.swiftdoc` files next to the interfaces (`strings` on them), which are Apple's own text; `[GAP]` I looked and could not find it in the SDK, so it is not claimed; `[REPO]` observed in this repo.

Limits, stated once:

- There is **no iOS 26 SDK on this machine**, so "new in 27" is derived from `@available`/`API_AVAILABLE` markers, not a file diff. A framework is called new in 27 only when every availability marker in it is 27 or later.
- Entitlement names, Info.plist usage-description keys and App Store review rules are not in the SDK. Where a gotcha depends on one I say `[GAP]`. I did not search the web.
- Behaviour that only shows on a device (background budgets, whether an Apple TV app is woken, whether an intent can start audio from the lock screen) cannot be read from headers and is marked **device test**.
- My `scan` counted `27` markers in every `.swiftinterface` in a framework directory, so absolute counts are inflated by the number of architecture files. Only "zero" and "all" results are used as evidence.

### Corrections to the August survey

| Earlier claim | What the 27.2 SDK says |
|---|---|
| FoundationModels is in the tvOS SDK, "so an on-device LLM is available on the Apple TV" (§2.6) | The framework directory is there but **every public symbol is `@available(tvOS, unavailable)`** (544 such lines per architecture file of the tvOS interface). Nothing compiles against it on tvOS. `[SDK]` TV `FoundationModels.swiftinterface`. The repo already guards this: `DeckIdentity.swift:2` uses `#if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)`. `[REPO]` |
| `CoreAI` is "genuinely new and genuinely good" (§3.12) | `CoreAI.swiftinterface` is **9 lines**: it re-exports `CoreAIDelegates` (a SubFramework) and declares nothing itself. `CoreAIDelegates` is a model-loading runtime (`AIModelCache`, `SpecializationOptions`, `ComputeUnitKind`, `InferenceFunction`), about 120 lines. It is a bring-your-own-model runtime, not an Apple model. `[SDK]` |
| The `.audio` App Schema domain is "iOS only" (§1.7) | It is `@available(anyAppleOS 27.0, *)` with only `watchOS` and `tvOS` unavailable, so **iOS, iPadOS, macOS and visionOS**. The Mac menu-bar app can adopt it. `[SDK]` IOS `AppIntents.swiftinterface:320-420` |
| `RelevantEntities` surfaces playlists in the Fitness media picker (§6.10) | The only `AudioContext` in the SDK is **`.nowPlaying`**. There is no workout context in the headers. The Fitness claim comes from a release note, not from anything I can compile against. `[SDK]` `AppIntents.swiftinterface:8940-8953` |
| The widget target and Live Activity exist | True in the main checkout (`SoundingTV-Widget/` holds `SoundingWidgetBundle`, `NowPlayingLiveActivityWidget`, `PlaybackControlIntents`, `WidgetControlSender`) but **this worktree has no `SoundingTV-Widget/` directory**: it was deleted by `c72aa77`. Check which tree you are building before planning widget work. `[REPO]` |
| `AppShortcutsProvider` and `AudioPlaybackIntent` are unadopted (§6) | Now adopted: `SoundCloudPlaybackIntents.swift` has `PlayTrackIntent`, `PlayPlaylistIntent`, `PlayArtistIntent` as `AudioPlaybackIntent` plus three `AppShortcut`s. `NowPlaying` is now imported in `MediaSessionNowPlayingBridge.swift`. `[REPO]` |

Things in the August survey that **verified clean**: `AVPlayer.disconnectedFromSystemAudio` (`AVPlayer.h:515`, iOS/tvOS/watchOS/visionOS 27, not macOS); the `AVAudioSession` interruption replacement (`AVAudioSessionDidBecomeInactiveNotification`, `...ResumptionRecommendationNotification`, iOS/tvOS/watchOS 27, not macOS); `AVPlayerItemSampleBufferOutput` ("HLS `AVPlayerItems` only, decoded PCM", `AVPlayerItemSampleBufferOutput.h:84`); `AVReadOnlyAudioPCMBuffer`; `ActivityKit` has no 27 API; `isDynamicIslandLimitedInWidth` and `systemExtraLargePortrait` are the only WidgetKit 27 additions.

## 1. Platform presence of the frameworks that matter

`Y` = framework present with usable API; `-` = no framework in that SDK; `X` = framework present but every symbol unavailable.

| Framework | iPhone/iPad | Apple TV | Mac | Watch | New 27 API? |
|---|---|---|---|---|---|
| GroupActivities | Y | Y | Y | - | **None.** Zero 27 markers; the 887-line interface is identical on iOS, tvOS and macOS. |
| WidgetKit (incl. controls) | Y | - | Y | Y | 2 symbols |
| ActivityKit | Y | - | Y | - | None |
| AlarmKit | Y | - | - | - | 1 (see feature 6) |
| TipKit | Y | Y | Y | Y | None |
| FoundationModels | Y | **X** | Y | Y (PCC model only) | Large |
| AppIntents | Y | Y (schemas unavailable) | Y | Y (schemas unavailable) | Large |
| BackgroundTasks | Y | Y (API only) | - | - | 1 (async submit) |
| UserNotifications | Y | Y (no title/body) | Y | Y | 1 |
| CloudKit | Y | Y | Y | Y | `CKAsset.ExportedAssetID` only |
| NaturalLanguage | Y | Y | Y | Y | None |
| MediaPlayer | Y | Y | Y | Y | 1 key |
| NowPlaying | Y | Y | Y | Y | New framework |
| MusicUnderstanding | Y | Y | Y | Y | New framework |
| ShazamKit / MusicKit / Translation / TVServices | Y / Y / Y / TV only | Y / Y / Y / Y | Y / Y / Y / - | Y / Y / Y / - | 1 / 1 / 0 / 0 |

TipKit: `popoverTip` is tvOS 26 (not watchOS). `cloudKitContainer` configuration is iOS 18 / tvOS 18 / watchOS 11. `[SDK]` IOS `TipKit.swiftinterface:870, 256-262`.

### New frameworks in the 27 SDKs

Derived by "every availability marker is 27". Same-name directories that appear in more than one SDK are listed once.

- **Audio/media (relevant):** `NowPlaying` (iOS, tvOS, macOS, watchOS), `MusicUnderstanding` (all four), `MediaIntents` (all four), `AVSystemRouting` (iOS), `MediaDevice` (iOS), `MediaIntelligence` (iOS, tvOS, macOS; image/video face-group analysis, not audio).
- **Intents plumbing:** `AppIntentsTypeSupport` (all four), cross-import overlays `_MediaIntents_AppIntents`, `_MediaPlayer_AppIntents`, `_NowPlaying_AppIntents`, `_UserNotifications_AppIntents`, `_Photos_AppIntents`, `_AppIntents_HealthKit`.
- **Models/search:** `_CoreSpotlight_FoundationModels` (iOS, macOS; carries `SpotlightSearchTool`), `_Vision_FoundationModels` (all four; `OCRTool`, `BarcodeReaderTool`), `_FoundationModels_UIKit`, `_FoundationModels_AppKit`, `CoreAI` (shell, see corrections).
- **Not relevant to a music app:** `ComputeGraph`, `USDKit` and its RealityKit overlays, `StateReporting` (diagnostic state reporter), `CrashReportExtension`, `SuggestedActions` (messages, iOS/macOS), `HomeExtensions` and `AppManagedFeatures` and `TrustInsights` (iOS only), `AccessoryAccess`, `DiskImageKit`, `SpatialPreview` (macOS only), `LinkSecurity`, and `MetalFX` on tvOS.
- Scan artefacts, ignore: `ColorSync`, `ImageIO` are old frameworks whose only header markers happen to be 27.

## 2. Features 1 to 7

### Feature 1: SharePlay / GroupActivities, listen together

**Best API on 27:** `GroupActivities`, unchanged from 26. There is no 27 API in it on any platform `[SDK]`. Use `GroupActivity` + `GroupActivityMetadata` with `type = .listenTogether` and `supportsContinuationOnTV`, `GroupSession`, and `GroupSessionMessenger` for the app's own state.

**New versus 26:** nothing. Nothing in `NowPlaying` references GroupActivities either (searched the interface: no match), so the new Now Playing framework does not give you SharePlay for free. `[SDK]`

**Availability:** iPhone, iPad, Apple TV, Mac: yes (iOS 15 / tvOS 15 / macOS 12). Watch: no framework. Details that decide the Apple TV design `[SDK]` IOS `GroupActivities.swiftinterface`:

- `GroupActivitySharingController` and `GroupActivityAssociationInteraction` are **iOS-only** (UIKit overlay `_GroupActivities_UIKit`; the Apple TV SDK has the overlay directory but the symbols are `tvOS unavailable`, `macOS unavailable`). The Apple TV cannot present a "start SharePlay" sheet from the app.
- `registerGroupActivity(_ activity:)` is `tvOS unavailable`. Only the `preparationHandler:` form compiles on tvOS, meaning the TV joins sessions started elsewhere (a FaceTime call, or iPhone-to-TV continuation) rather than starting them.
- `AVPlaybackCoordinator.coordinateWithSession(_:)` exists on tvOS/iOS/macOS (iOS 15) but only drives `AVPlayer`.
- `GroupSessionMessenger` has `.reliable` and `.unreliable` delivery modes (iOS 16 / tvOS 16). `GroupSessionJournal` (iOS 17 / tvOS 17) transfers `Transferable` attachments.
- `SystemCoordinator` is visionOS only.

**Gotchas:**

- `MixEngine` is `AVAudioEngine`; `AVPlaybackCoordinator` does not apply to it. DJ mode in a shared session needs the messenger plus your own clock, and `playAudio(at:)` with a shared reference time. The AVPlayer path can use the coordinator.
- Sending only track IDs and transport state (small `Codable` messages) means each person streams their own copy from their own SoundCloud session. Whether SoundCloud's terms allow a second listener without their own login is a product question, not an SDK one.
- Capability/entitlement for Group Activities: `[GAP]` not found in the SDK. Add it in Xcode Signing & Capabilities and check the generated key.
- tvOS joining behaviour, including whether `GroupStateObserver.isEligibleForGroupSession` flips on a TV that is not in a FaceTime call: **device test**.

**Recommended approach:** one `ListenTogetherActivity: GroupActivity` carrying a queue snapshot; leader/follower roles over `GroupSessionMessenger(.reliable)` for play/pause/skip/queue edits; `.unreliable` for position ticks. Use `AVPlaybackCoordinator` for plain playback and a custom messenger clock for DJ mode. Start from iPhone with `GroupActivitySharingController`; treat Apple TV as a joiner. Do not promise "start on Apple TV" until the device test.

### Feature 2: Control Center, Lock Screen, Action button controls

**Best API on 27:** `ControlWidget` with `ControlWidgetToggle` (play/pause) and `ControlWidgetButton` (resume last mix), backed by App Intents, plus `ControlValueProvider` for state. Unchanged since iOS 18.

**New versus 26:** nothing in the controls API. The two 27 WidgetKit symbols are `isDynamicIslandLimitedInWidth` (iOS, Live Activity) and `WidgetFamily.systemExtraLargePortrait`. `[SDK]` IOS `WidgetKit.swiftinterface:620, 964`. What helps indirectly: `IntentExecutionTargets` (`anyAppleOS 27.0`, `AppIntents.swiftinterface:7688`, with `.main`, `.appIntentsExtension`, `.widgetKitExtension`) lets an intent say it should run in the app process.

**Availability:** controls are `@available(iOS 18.0, macOS 26.0, watchOS 26.0)` and `tvOS unavailable`, `visionOS unavailable` `[SDK]` (`ControlCenter` class, `ControlValueProvider`, `StaticControlConfiguration`, `AppIntentControlConfiguration`, `ControlWidgetToggle`, `ControlWidgetButton`). iPhone and iPad: yes. Mac: yes (macOS 26+). Watch: yes (watchOS 26+). Apple TV: no WidgetKit in the SDK. The Action button picks a control in Settings; there is no code for it.

**Gotchas:**

- The existing widget process sends commands to the Apple TV over Bonjour (`WidgetControlSender`) `[REPO]`. A "play/pause" control that targets the **phone's own** playback needs either an `AudioPlaybackIntent` that runs in the app, or `allowedExecutionTargets` including `.main`; whether the lock screen can start audio from a cold app via an intent is **device test**. `AudioPlaybackIntent` is already in use for the three play intents.
- `MediaSession` (NowPlaying) is `iOSApplicationExtension unavailable`, so state for a control comes from the App Group (`group.red.forbes.sounding`), not from the player.
- This worktree has no widget target at all. Re-adding it means touching `project.pbxproj` by hand per the repo rules.

**Recommended approach:** add a `ControlWidgetToggle` bound to a `SetValueIntent` that conforms to `AudioPlaybackIntent`, with a `ControlValueProvider` reading a small App Group snapshot; add a `ControlWidgetButton` for "Resume last mix" whose intent resumes the last queue. Reload with `ControlCenter.shared.reloadControls(ofKind:)` on state change. Reuse the same intents for Siri (feature 5).

### Feature 3: Lock Screen and StandBy widgets (current mix, progress)

**Best API on 27:** `WidgetKit` accessory families on the Lock Screen (iOS 16) and the standard families in StandBy (iOS 17), in the existing widget target.

**New versus 26:** only `systemExtraLargePortrait` (`iOS 27, macOS 27, visionOS 26`; tvOS and watchOS unavailable) `[SDK]` `WidgetKit.swiftinterface:964`. I found no new accessory family, no new StandBy API and no new timeline API. The 26 additions to know: `WidgetPushInfo`/`WidgetPushHandler` (push-driven reload, needs a server we do not have), `WidgetMountingStyle`, `levelOfDetail`, `WidgetLocation.carPlay` (iOS 26 only). `[SDK]` lines 126, 248, 834-839, 1634.

**Availability:** WidgetKit: iPhone, iPad, Mac, Watch. Apple TV: no framework. `RelevanceKit` (relevant-context hints for watch/phone widgets) is on all four.

**Gotchas:**

- A widget cannot own playback and `MediaSession` is unavailable in extensions. Current mix and progress must be written to the App Group by the app; progress should be a timer-driven view rather than reloaded entries. (SwiftUI timer-interval views are pre-27 API and I did not re-verify them here.)
- `WidgetCenter` reload budgets are not in headers: **device test**.
- Do not put a second Live Activity in the plan: ActivityKit gained nothing in 27 and the existing one lacks `supplementalActivityFamilies([.small])` (iOS 18) `[REPO]`.

**Recommended approach:** one `AppIntentConfiguration`-less static widget showing mix title, artwork and a progress bar, with `accessoryRectangular`/`accessoryCircular` and `systemSmall` (the StandBy slot); data from an App Group snapshot the player already writes for the Live Activity. Add `widgetAccentedRenderingMode` handling for Lock Screen tinting.

### Feature 4: On-device models (FoundationModels)

**Best API on 27:** `LanguageModelSession` with `@Generable` guided generation, `Tool` calling over the app's own library search, and `SystemLanguageModel.tokenCount(for:)` to budget context. The 27 API adds a lot around it.

**New versus 26** `[SDK]` IOS `FoundationModels.swiftinterface`:

- `PrivateCloudComputeLanguageModel` (iOS/macOS/visionOS/**watchOS** 27, tvOS unavailable): `availability` (`.deviceNotEligible`, `.systemNotReady`), `quotaUsage` (per-user request budget, `limitIncreaseSuggestion.show()`), errors `NetworkFailure`, `QuotaLimitReached`, `ServiceUnavailable`. `[DOC]`: "To develop with PCC you must meet certain eligibility requirements ... request access to the managed entitlement" (link: developer.apple.com/private-cloud-compute). So PCC is **gated by a managed entitlement**; do not plan around it.
- `LanguageModel` protocol (`capabilities`: `.vision`, `.guidedGeneration`, `.reasoning`, `.toolCalling`), `LanguageModelError` (nonexhaustive: `contextSizeExceeded`, `rateLimited`, `guardrailViolation`, `refusal`, `unsupportedCapability`, `timeout`, ...). Lets you swap model backends.
- `SystemLanguageModel.Variant` (`.core3`, `.coreAdvanced3`) and `.variant`; `contextSize` is now the real value (the 26.x back-deploy returns `4096`).
- `DynamicInstructions`, `DynamicProfile` (`LanguageModelSession.Profile`, builders, modifiers), `SessionProperty`: composable, per-turn instructions and tools.
- Image input: `Transcript.ImageAttachment`, `Attachment<ImageAttachmentContent>` (init from `CGImage`/`CIImage`, `UIImage` via `_FoundationModels_UIKit`).
- `_Vision_FoundationModels`: ready-made `OCRTool`, `BarcodeReaderTool`.
- `SystemLanguageModel.Adapter` was deprecated 26.4 and is **obsoleted at 27.0**; do not plan on adapters.
- 27.2 adds `DataEntryRepresentable` and data-entry actions for custom executors (iOS/macOS/visionOS/watchOS, tvOS unavailable).
- `SpotlightSearchTool` (`_CoreSpotlight_FoundationModels`, iOS/macOS/visionOS 27) is a ready-made `Tool` over the app's Core Spotlight index (see feature 5).

**Availability:** iPhone, iPad, Mac: on-device model plus PCC. Watch: **PCC only** (`SystemLanguageModel` extensions are `watchOS unavailable`). **Apple TV: nothing.** Run these features on the phone or Mac and let the TV ask.

**Gotchas:**

- On-device availability is `.unavailable(.deviceNotEligible | .appleIntelligenceNotEnabled | .modelNotReady)`; every feature needs a non-AI fallback. `supportsLocale(_:)` gates languages. Guardrails refuse some inputs; handle `guardrailViolation`.
- 26.x context is 4096 tokens: summarising a long mix's comments must chunk and merge (map-reduce), using `tokenCount(for:)` (26.4) to size chunks.
- A model in the DJ decision loop is still a determinism risk (August survey §2.6); keep it to summaries, tags and prompt-to-set-list.
- Genre/mood tagging should be an `@Generable` struct with an enum of the app's own taxonomy so output cannot invent tags. `SystemLanguageModel.UseCase.contentTagging` exists (26) and is worth comparing against `.general`: **quality test**.
- Set-list generation must resolve every returned ID against real search results (tool calling returns real tracks; reject IDs not seen). Model-invented track names are the failure mode.

**Recommended approach:** (a) comment summary: chunk, summarise each, merge, return an `@Generable` struct of `summary`, `moments`, `sentiment`; (b) tags: `@Generable` enum-constrained genre/mood with confidence; (c) set list: a `Tool` wrapping `searchTracks`, `@Generable SetList { picks: [Pick] }`, post-validate IDs. Gate all behind `#if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)` as `DeckIdentity.swift` does. Run on iPhone/Mac; sync results to TV through the existing CloudKit path.

### Feature 5: Siri and Shortcuts (library intents)

**Best API on 27:** the `.audio` App Schema domain for the things Siri already understands (play, add to library, add to playlist, like), plus ordinary `AppIntent`/`AppEntity`/`EntityQuery` for the app-specific ones (set lists), plus `IndexedEntity` for Spotlight.

**New versus 26** `[SDK]` IOS `AppIntents.swiftinterface`:

- `AppSchema.Intent` `.audio`: `playAudio` (`PlayAudioIntent`), `addToLibrary`, `addToPlaylist`, `updateAudioAffinity` (like/dislike), `warmupAudioQueue`, `createStation`, `recognizeAudio`. Entities `.audio.song`, `.artist`, `.playlist`, `.album`, `.songCollection`, radio stations and podcast types. All `anyAppleOS 27.0`, **`watchOS` and `tvOS` unavailable** (lines 320-470). The old `playAudiobook` and the per-domain `search` schemas are deprecated 27.0 in favour of `.audio.playAudio` and `.system.searchInApp` (lines 586, 3063).
- `MediaIntents.AudioSearch` with `Criteria = .unspecified | .searchQuery(String) | .url([URL])`. `[SDK]` `MediaIntents.swiftinterface:11-36`.
- `IndexedEntityQuery` (iOS/macOS/visionOS 27), `SyncableEntity`, `EntityCollection`, `LongRunningIntent`, `IntentExecutionTargets`, `RunSystemShortcutIntent`/`SystemShortcut` (iOS only).
- `RelevantEntities.shared` with `AudioContext.nowPlaying` (all platforms incl. tvOS). Only `.nowPlaying` exists.
- `MPNowPlayingInfoPropertyAppEntityIdentifiers`, `MediaContentRepresentable.appEntityIdentifiers`, and `AlarmConfiguration(appEntityIdentifier:)` tie system surfaces back to `AppEntity` values.
- 27.2: `IntentParameter(... importing:)` initialisers and `AssistantSchemaEnum.caseDisplayRepresentations`. Minor.

**Availability:** iPhone, iPad, Mac: schemas available. Apple TV, Watch: App Intents plumbing yes, **schemas no**. So "play my last liked set" by voice lands on the phone or Mac and reaches the TV over the existing Bonjour channel.

**Gotchas:**

- `.audio.*` is a contract: the intent's parameters must match the schema's shape. The macro list shows `AppSchema.Intent("PlayAudioIntent")` but not the parameter shapes, which live in the macro. Expect to adopt by compile-and-fix. `[GAP]` whether Apple reviews or gates schema adoption; the headers say nothing.
- "Add this to <set list>" needs a `SetListEntity` (`AppEntity` with an `EntityQuery` and `IndexedEntity`); the schema's `PlaylistEntity` is the nearest match. Decide whether set lists map onto the playlist schema or stay a custom entity.
- "Last liked set" is a query over data the app fetches from SoundCloud; donate liked items to Core Spotlight (`CSSearchableItem` + `IndexedEntity`) so the system can answer without launching.
- Running from the lock screen: `AudioPlaybackIntent` is the right marker. Cold start behaviour: **device test**.

**Recommended approach:** build `TrackEntity`, `ArtistEntity`, `PlaylistEntity` first (this unlocks features 2, 4, 5 and the August survey's visual-intelligence idea). Adopt `@AppIntent(schema: .audio.playAudio)` mapping `.searchQuery` to `searchTracks`/`searchUsers` and `.url` to `resolve(url:)`; add `updateAudioAffinity` for like and `addToPlaylist` for set lists. Keep the three existing `AudioPlaybackIntent`s and the `AppShortcut`s as the Shortcuts-app surface.

**Status (2026-11-06, built):**

- Schema shapes, read from the macro expansion and the extracted `Metadata.appintents`: `playAudio` takes `audioEntity`, `playbackAttributes`, `warmupAudioQueueResult`, `queueLocation`; `createStation` takes no parameters and means "start a station from what's playing"; `.audio.playlist` has `title`, `owner`, `createdByMe`, `curatedForMe`. `MediaIntents.AudioSearch` is not a `playAudio` parameter. Apple's own `playAudio` training examples include "Play my liked songs on Spotify", "Shuffle my library" and "Play Kendrick Lamar in the Living Room".
- `INPlayMediaIntent` is not deprecated on 27 (the Notes/Reminders SiriKit intents are). The iPhone app handles it in-process (`application(_:handlerFor:)`, `INIntentsSupported`, `com.apple.developer.siri`), which covers iOS 26.5 and Siri's preferred-media-app routing.
- One resolver (`MediaRequest` / `MediaRequestResolver`) serves both paths: Likes, cached playlists, followings, history snapshot and saved Setlists first, then at most one SoundCloud search per request, none for "my …" requests or while traffic is stopped.
- Likes is a `PlaylistEntity` with id `likes`, so "play my likes" works through the schema, `INPlayMediaIntent` and Shortcuts alike. Now Playing is published to `RelevantEntities` under `.audio(.nowPlaying)` so "something like this" and "like this" resolve.

**HomePod (what Apple allows on 27):**

- A HomePod runs no third-party code. Siri on a HomePod only plays from Apple services and from media services that integrate in the cloud: the app links an account with `MediaSetup` (`MSSetupSession`/`MSServiceAccount`, iOS only, unchanged since 14) and the service runs an OAuth token endpoint plus a configuration/playback server that Apple's servers call. Sounding has no server and SoundCloud is not such a partner, so "Hey Siri, play X on Sounding" said to a HomePod cannot work, and Sounding cannot be the HomePod's default music service.
- "Use Default Media App" for HomePod in the Home app only lists services added through `MediaSetup`. Making Sounding the default media app on the iPhone (Siri learning or the per-request choice) affects requests made to the iPhone, not to the HomePod.
- `AVSystemRouting` (iOS 27) is for third-party cast protocols through Media Device extensions (`MDESupportedProtocols`), not AirPlay; there is still no public API to pick an AirPlay route by name. `AVRoutePickerView` needs a tap.
- The supported flow is Siri on the iPhone (or Mac): the intent starts playback in Sounding with the `.longFormAudio` route-sharing policy, so audio follows the system's current long-form route, including a HomePod chosen in Control Center. Whether Siri itself routes "… in the kitchen" to a HomePod for a schema-adopting third-party app is **device test**.

### Feature 6: AlarmKit, wake to a mix, and a sleep timer

**Best API on 27:** `AlarmKit` (`AlarmManager.shared.schedule`, `AlarmConfiguration.alarm(schedule:attributes:...)` and `.timer(duration:...)`), unchanged from 26 except one addition.

**New versus 26:** the only 27 symbols are three `AlarmConfiguration` initialisers taking `appEntityIdentifier: EntityIdentifier?` (iOS 27), so an alarm can be tied to a mix entity. `[SDK]` IOS `AlarmKit.swiftinterface` (the `extension AlarmManager.AlarmConfiguration` marked `iOS 27.0`).

**Availability:** **iPhone and iPad only.** No AlarmKit in the tvOS, macOS or watchOS SDKs, and `macCatalyst` is unavailable. `[SDK]`

**Gotchas** `[SDK]`/`[DOC]`:

- **The alarm sound cannot be a stream.** `AlertConfiguration.AlertSound` has only `.default` and `.named(String)`; `named` takes "a file that's in your app's main bundle or the `Library/Sounds` folder of your app's data container". A mix cannot be the alarm tone.
- `stopIntent` and `secondaryIntent` are `LiveActivityIntent`s; the secondary button can be `.custom` and run an intent "without" opening the app. That is the hook for "Play mix". Whether a `LiveActivityIntent` may start an audio session from the locked/background state: **device test**.
- Authorization: `requestAuthorization()`; denial means "all attempts to schedule alarms fail". `AlarmError.maximumLimitReached` exists. The Info.plist usage-description key and any widget-extension requirement for the alarm's Lock Screen UI: `[GAP]` not in the SDK; check Xcode.
- A timer created with `.timer(duration:)` **alerts** like an alarm when it expires. That is wrong for a sleep timer.

**Recommended approach:** two separate things. (1) Wake-to-mix: AlarmKit alarm with a short bundled tone, a custom secondary "Play mix" button running an `AudioPlaybackIntent`-style intent, and the mix stored as an `AppEntity`. (2) Sleep timer: an in-app timer with a volume fade and a Live Activity countdown, no AlarmKit. If a "pre-alert then stop" is wanted, AlarmKit's `CountdownDuration.preAlert` is the only built-in option, and it will ring.

### Feature 7: TipKit

**Best API on 27:** `TipKit`, unchanged in 27 (zero 27 markers on any platform).

**New in 26 that you may not have used** `[SDK]` IOS `TipKit.swiftinterface`: `Tips.Event.deleteDonations()`, `Tips.DonationLimit`, `popoverTip` (iOS/macOS/tvOS/visionOS 26; not watchOS), and from iOS 18/tvOS 18/watchOS 11 `Tips.ConfigurationOption.cloudKitContainer(_:)`.

**Availability:** iPhone, iPad, Apple TV (17+), Mac, Watch (10+).

**Gotchas:** `cloudKitContainer` syncs tip state across a person's devices, which is the right answer for "do not show the comments tip on the TV after I dismissed it on the phone". The repo already owns the CloudKit container `iCloud.red.forbes.sounding` (`SoundingTV.entitlements`); whether TipKit may share it or wants its own is `[GAP]`. How `TipView`/`popoverTip` behaves under tvOS focus: **device test**.

**Recommended approach:** one `Tip` per hidden feature (comments, deck mix, DJ mode) with an `Event` donated when the user opens the relevant screen and a `Rule` that fires after N plays without using the feature. `Tips.configure([.displayFrequency(.daily), .cloudKitContainer(...)])`. Use `popoverTip` on tvOS where inline `TipView` fights the focus engine. Tune with `IgnoresDisplayFrequency` only for first-run.

## 3. Feature 8: Scout (tell the app what you saw; it tells you when the set is posted)

User story: "I saw Young Marco at Lago Lago 2026, tell me when his set is up."

### 3.1 Parsing the request on-device

- Use `LanguageModelSession` on iPhone, iPad or Mac with an `@Generable struct ScoutRequest { artists: [String]; event: String?; startDate: Date?; endDate: Date?; extraKeywords: [String] }` and `@Guide` descriptions. This is guided generation (iOS 26+). `[SDK]` `Generable`, `Guide`.
- Put **today's date in the instructions**; the model has no clock, so "last weekend" and "Lago Lago 2026" need it. (Design advice, not an SDK fact.)
- Availability: iPhone/iPad/Mac only. Apple TV has no model at all. On-device `SystemLanguageModel` can be `.unavailable(.deviceNotEligible | .appleIntelligenceNotEnabled | .modelNotReady)`; the PCC fallback needs a managed entitlement `[DOC]`, so do not count on it.
- A request line is short, so the 4096-token context is not a constraint. Latency is a model call; use `prewarm()` when the sheet opens `[DOC]` ("only when you have a window of at least 1 second").
- **Fallback that must exist anyway:** structured form (artist token field, event field, year) plus a small deterministic parser (split on `at`, `@`, `x`, `b2b`, `,`; 4-digit year). `NaturalLanguage` (`NLTagger` name/organization tags) is on every platform and unchanged in 27 `[SDK]`. Treat the model as a convenience over the form, never the only path.
- Entry points: in-app text field, plus an `AppIntent` with a `String` parameter ("Scout for ...") so Siri and Shortcuts can create one (feature 5). The intent runs on phone/Mac where the model exists.
- Resolve names to SoundCloud accounts after parsing with `searchUsers` (exists: `SoundCloudAPI.searchUsers`) and let the person confirm which "Young Marco" and which festival or label account to watch. Wrong-account matches are the biggest quality risk, so confirmation beats model confidence.

### 3.2 How to watch with no server of our own

**What 27 gives you, from the headers:**

- `BackgroundTasks`: `BGAppRefreshTask`/`BGProcessingTask` are iOS 13 and **tvOS 13**, `macOS unavailable`, `watchOS unavailable`. The only 27 change is async `submitTaskRequest(_:)` (`BGTaskScheduler.h:145`, iOS/tvOS 27) with the sync form deprecated. Limits stated in the header: "a total of 1 refresh task and 10 processing tasks scheduled at any time". `earliestBeginDate` is a lower bound; there is **no new 27 background API** and no budget numbers in the header. `BGContinuedProcessingTask` (iOS 26) is for user-initiated visible work, so it does not fit. `[SDK]`
- The iOS Info.plist has only `UIBackgroundModes = audio`; the tvOS one has `audio` and the entitlement `aps-environment`; **neither lists `fetch`** and there is no `BGTaskSchedulerPermittedIdentifiers`. `[REPO]`
- `UserNotifications`: on **tvOS** the notification content fields `title`, `body`, `sound`, `categoryIdentifier`, `userInfo` are all `API_UNAVAILABLE(tvos)` (`UNNotificationContent.h:39-66`), and categories/actions are tvOS-unavailable, so an Apple TV cannot show a meaningful "your set is up" itself. `UNMutableNotificationContent.appEntityIdentifiers` is new at 27 on all platforms (`_UserNotifications_AppIntents`). `[SDK]`
- `CloudKit` is unchanged for this purpose. `CKNotificationInfo.alertBody`, `titleLocalizationKey` etc. exist and are `__TVOS_PROHIBITED`; `shouldSendContentAvailable` gives a silent push; a subscription with no alert/sound/badge is delivered at lower priority with no content (`CKSubscription.h:429`). `[SDK]`
- `ActivityKit` has no 27 change. Starting a Live Activity needs the app in the foreground or a push-to-start token (`pushToStartToken`, iOS 17.2+) delivered by a server, so a Live Activity is not a server-free "it's up" channel. `[SDK]`
- `NSBackgroundActivityScheduler` is macOS only (`API_UNAVAILABLE(ios, watchos, tvos)`). `[SDK]`

**Recommended design: poll where the app stays alive, relay with CloudKit, alert on the phone.**

1. **Scout record** (created on phone or Mac) is a CloudKit record in the existing private zone: parsed fields, resolved account IDs, event dates, a `seenTrackIDs` set, state. It syncs to every device with the existing `CKSyncEngine` (`CloudSyncEngineController` already has a per-feature inbox pattern `[REPO]`; Scout is one more inbox type).
2. **Pollers, best to worst:**
   - **Mac menu-bar app** (`MenuBarExtra`, `[REPO]` `SoundingMacApp.swift`): a `Timer` plus `NSBackgroundActivityScheduler`. Reliable while the Mac is awake. It already has `MacActivityNotificationDelivery` and a polling view model (`FeedViewModel.poll`) `[REPO]`, so this is the least new code.
   - **Foreground opportunism on every device:** poll on launch and on scene activation. Free and instant when someone opens the app.
   - **iPhone `BGAppRefreshTask`:** register one, add `fetch` to `UIBackgroundModes`, set `earliestBeginDate` about 15 to 30 minutes out and reschedule in the handler. Opportunistic; the system decides.
   - **Apple TV `BGAppRefreshTask`:** the API exists on tvOS but **nothing in the SDK says an idle Apple TV app is woken**; treat as a bonus, not a dependency. **Device test.**
3. **Relay:** when any poller finds a match it writes a `ScoutHit` record (track ID, title, matched Scout, confidence). The iPhone holds a `CKQuerySubscription` on `ScoutHit` creation with `CKNotificationInfo.alertBody` set; **CloudKit/APNs then shows the notification with no app execution on the phone and no server of ours** (the app already has `aps-environment` on tvOS and a CloudKit container). The tvOS flag `__TVOS_PROHIBITED` on `alertBody` is why the *alert* is addressed to the phone while the TV and Mac are the writers. A local `UNNotificationRequest` is the fallback when the finder is the phone itself (BG task or foreground).
4. **De-duplication:** `ScoutHit` record name = hash(scoutID + trackID), so two pollers finding the same upload produce one record and one push.
5. **Cost control (the main lever):** a set cannot be posted before the event ends, so **do not poll before `endDate`**. After it, poll fast for 72 hours (the common upload window), back off to daily for about 60 days, then expire the Scout and tell the person. This keeps request volume, and the background budget, small.

**Things I could not verify in the SDK** (so the design should not depend on them): whether silent pushes reach a force-quit app; the CloudKit alert-push path working on the shared `CKSyncEngine` zone (needs an index on the record type and a `CKQuerySubscription` with `zoneID`; **prototype first**); iOS background refresh frequency; and anything about SoundCloud's rate limits and API stability (this is a private API client, `[REPO]` `SoundCloudAPI.swift`). Shortcuts "time of day" personal automations that run an `AppIntent` are a possible hourly-ish driver; I did not find anything in the SDK about them, so it is an idea, not a finding.

### 3.3 Matching against SoundCloud

The client already has what is needed `[REPO]` `SoundCloudAPI.swift`: `searchTracks(query:)`, `searchUsers`, `getUserTracks(userId:)`, `getUserReposts(userId:)`, `getFeed`, `getStream`, `getTracks(ids:)`, `resolve(url:)`.

Candidate sources per Scout, deduped by track ID:

1. `getUserTracks` for each confirmed artist account.
2. `getUserTracks` and `getUserReposts` for confirmed **event, festival and label** accounts (festivals often upload sets from their own page).
3. `getUserReposts` for the artist's account, since many sets are reposts from an organiser.
4. `searchTracks` with 2 or 3 query variants: `"{artist} {event}"`, `"{artist} {event} {year}"`, `"{artist} live {year}"`.
5. The person's own `getFeed`/`getStream` is free for followed accounts.

Scoring (deterministic first, model second):

- Normalise titles: Unicode folding, lowercase, strip punctuation and `@`, collapse variants (`b2b`, `x`, `&`, `at`, `live @`, `live at`, `set`, `full set`).
- +: all artist tokens in title or uploader; event tokens in title/description/tags; year token; created date is on or after the event start and within the window; duration over about 30 minutes (a set, not a teaser); uploader is a watched account.
- −: created before the event; duration under about 10 minutes (clips); already in `seenTrackIDs`; looks like a studio release (single, EP).
- Two thresholds: high score notifies "Young Marco at Lago Lago is up", mid score notifies "Possible match, tap to check". Never auto-play.
- Optional: for the mid band, ask `SystemLanguageModel` for an `@Generable { isMatch, reason }` judgement over title + description. On-device only, iPhone/Mac, never required.

### 3.4 Latency and reliability

| Approach | Typical latency | Reliability | Needs |
|---|---|---|---|
| Mac menu-bar poller + CloudKit alert push | Poll interval (5 to 15 min) plus seconds | Good while the Mac is awake and the app is running | Mac running; CloudKit subscription on iPhone |
| Foreground poll on open | Instant | Only when opened | Nothing |
| iPhone `BGAppRefreshTask` | Hours, system-decided | Low to medium; none if background refresh is off or the app was force-quit | `fetch` mode + permitted identifier |
| Apple TV `BGAppRefreshTask` | Unknown | Unknown | **Device test** |
| Apple TV foreground only | When used | Low | Nothing |
| CloudKit silent push to wake iPhone | Seconds, throttled | Low to medium | Not needed if alert push is used |
| Live Activity for "it's up" | n/a | Not possible without a server | Push-to-start token |

Realistic expectation: with a Mac running, "within about 15 minutes of upload". With only a phone, "within a few hours, and immediately the next time the app opens". Say that in the UI. Do not promise minutes.

**Effort: L.** Parser and form M, Scout record and sync S, matching and scoring M, Mac poller plus relay record S, CloudKit alert subscription M (the riskiest piece, prototype first), iOS BG task S. Ship in order: form + foreground poll + local notification (S/M), then Mac poller + CloudKit alert relay, then BG tasks, then the model parser.

## 4. New in 27 and worth adding (music and DJ fit only)

| Item | Symbol / framework | One-line pitch | Effort |
|---|---|---|---|
| Real Now Playing | `NowPlaying.MediaSession`, `MediaCommand.feedback`/`changeRepeatMode`/`changeShuffleMode`, `MusicContent`, `Artwork` (all four platforms) | Like, repeat, shuffle on lock screen, Control Center and Siri Remote; repo already imports it in `MediaSessionNowPlayingBridge.swift` (finish it) | M |
| Siri "play X on Sounding", like, add to set list | AppIntents `.audio.*`, `MediaIntents.AudioSearch` (iOS/iPadOS/macOS) | Voice control with no user-authored shortcut | M |
| Ask your library in plain English | `SpotlightSearchTool` + `CoreSpotlightSource` (iOS/macOS) | "Deep house I liked last year" answered from your own data | L (needs Spotlight donation first) |
| Instrument-aware mixing | `MusicUnderstanding` `InstrumentActivityResult`, `analyze(for:)` (all four) | Mix over instrumental passages instead of guessing from structure | L |
| Park the AVPlayer, do not rebuild it | `AVPlayer.setDisconnectedFromSystemAudio(_:completionHandler:)` (iOS/tvOS/watchOS) | Smoother DJ-mode entry and exit | S |
| System says whether to resume | `AVAudioSession` `DidBecomeInactive` / `ResumptionRecommendation` notifications (iOS/tvOS/watchOS) | Correct resume after calls or an AV receiver waking. The old interruption notification is deprecated at 27, so this is forced | S |
| Image caching for free | `AsyncImage` HTTP caching, `asyncImageURLSession(_:)` (all) | Artwork stops re-downloading on iOS | S |
| Drag-to-reorder queue | SwiftUI `reorderable()`, `reorderContainer(for:)` (iOS/macOS/visionOS/watchOS; tvOS unavailable) | Native queue and set-list editing, also on Mac | S |
| Respect "back off" | `EnvironmentValues.systemPrefersReducedResourceUsage` (all) | Drop animation rates and pause analysis when the system asks | S |
| Entity-tagged notifications | `UNMutableNotificationContent.appEntityIdentifiers` (all) | Scout hits link to the track entity | S |
| Photo-to-artist | `SemanticContentDescriptor` (iOS 26) | Point at a poster, find the artist; same entity work as feature 5 | M |
| Mac toolbar polish | `ToolbarItemVisibilityPriority`, `TabRole.prominent`, `TabsPickerStyle` (27) | Small chrome upgrades on iOS/Mac/TV | S |

Looked at and **not** worth it for a music app: `AVSystemRouting`/`MediaDevice` (needs a media device extension, entitlement unknown, iOS only; spike only), `MediaIntelligence` (faces), `CoreAI` (empty shell plus a BYO-model runtime), `CarPlay` 27 (navigation templates; only `CPNowPlayingTemplate.allowsMiniPlayer` is audio-relevant), `Speech` 27 (`SpeechAnalyzer` options and `AssetInputSequenceProvider`; transcribing sets is a feature nobody asked for), `ShazamKit` (only `SHMediaItem.songs() async throws -> [MusicKit.Song]`; the app uses ShazamKit, so adopt it when touching that code), `MusicKit` (one trivial lookup), `Translation` and `TVServices` (no 27 changes), the documents API.

## 5. What to drop or change in the plan

1. **Drop "FoundationModels on Apple TV".** It does not compile on tvOS. Everything model-driven (features 4, 8) runs on phone or Mac and reaches the TV through CloudKit or the Bonjour channel.
2. **Drop "wire PCC in" unless Apple has granted the entitlement.** It needs a managed entitlement from a programme with eligibility requirements `[DOC]`. Design for on-device only with a non-AI fallback.
3. **Drop "AlarmKit as the sleep timer".** A timer alerts. Build the sleep timer in-app with a fade and a Live Activity countdown. Keep AlarmKit for wake-up only.
4. **Change wake-to-mix:** the alarm tone must be a bundled file; the mix starts from the alarm's secondary-button intent after the person acts.
5. **Change SharePlay on Apple TV from "start" to "join".** `GroupActivitySharingController` and `registerGroupActivity(_ activity:)` are not available on tvOS. Start from iPhone.
6. **Do not wait for a 27 SharePlay or TipKit or ActivityKit upgrade.** There is no new API in any of them in 27; build on the 26 surface now.
7. **Widgets:** the controls, accessory widgets and `systemExtraLargePortrait` are the entire WidgetKit story. Resolve the missing `SoundingTV-Widget/` in this tree before planning.
8. **Scout:** do not plan for Live Activities or silent pushes as the delivery channel; use CloudKit alert push to the phone with Mac, foreground and BG pollers behind it.
9. **Add AppEntity work as step zero.** `TrackEntity`, `ArtistEntity`, `PlaylistEntity` (and a set-list entity) unlock features 2, 4, 5, 8 and the entity-tagged notifications and alarms.
10. **Correct two items in `os27-api-survey.md`:** the `.audio` domain is not iOS-only (adds macOS), and the FoundationModels/CoreAI tvOS claims above.
