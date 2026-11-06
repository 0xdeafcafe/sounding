# Sounding — Work Handoff (2026-08-13, fourth revision)

**Read this first.** You are taking over a multi-agent work session on the Sounding app
(mid-stream, usage-constrained handoff). Everything you need is below: current state,
in-flight agents, pending briefs, deploy mechanics, and the rules of the road.

## 0. User intent & ground rules

- The user is the sole developer, direct and technical. They test on real devices.
- **"Deploy" means install to their local devices. NEVER TestFlight** (they were explicit;
  no ASC credentials exist anyway).
- **Deploy incrementally** ("deploy as you go"): when a batch lands and builds green, install
  immediately to iPhone + Apple TV; macOS deploys with `ditto` to /Applications.
- The user prefers **shared components/logic over per-platform duplication** ("should be
  shared really") — shared code lives in `SoundingTV.swiftpm/Sources/{Core,Shared}`.
- **Do NOT git commit/push/reset** — the tree has a large pre-existing uncommitted diff;
  all work stays uncommitted unless the user explicitly asks.
- Auto permission mode: don't ask the user questions; make reasonable calls and proceed.

### Repo & build mechanics

- Repo: `/Users/afr/Source/github.com/0xdeafcafe/sounding-tv`
- iOS = `SoundingTV-iOS/Sources`, macOS = `SoundingTV-macOS/Sources`,
  tvOS app = `SoundingTV.swiftpm/Sources/Apps/tvOS`, shared = `SoundingTV.swiftpm/Sources/{Core,Shared}`
- Two `.xcodeproj` exist — ALWAYS pass `-project SoundingTV.xcodeproj` (other is WatchTest).
- Schemes: `SoundingTV iOS`, `SoundingTV` (tvOS), `SoundingTV macOS`.
- Build: `xcodebuild -project SoundingTV.xcodeproj -scheme '<scheme>' -destination 'generic/platform=<iOS|tvOS|macOS>' -derivedDataPath build/<dd> -allowProvisioningUpdates build`
- New files: add to `project.yml` source lists AND register in pbxproj — preferred:
  `ruby tools/add-source-file.rb <file> --targets 'SoundingTV,SoundingTV iOS,SoundingTV macOS'`
  (or `xcodegen generate` v2.45.4 if project.yml structure changed). Never hand-edit pbxproj.
- No tests wired into schemes — build success is the gate.

### Devices

- iPhone 15 Pro Max: `F2390233-3424-56E6-8F2A-2E41C4CE7A55` —
  `xcrun devicectl device install app --device F2390233-… 'build/deploy-dd-ios/Build/Products/Debug-iphoneos/Sounding.app'`
- Apple TV 4K "Living Room": `16B1EB59-1DDA-523A-8F65-961CFD8EBEEC` —
  `xcrun devicectl device install app --device 16B1EB59-… 'build/deploy-dd-tvos/Build/Products/Debug-appletvos/Sounding.app'`
- Mac: `pkill -x Sounding; ditto build/deploy-dd-mac/Build/Products/Debug/Sounding.app /Applications/Sounding.app`
- Product name is `Sounding.app` everywhere (NOT `SoundingTV iOS.app`).
- Crash logs: `xcrun devicectl device copy from --device <id> --domain-type systemCrashLogs --source / --destination /tmp/sounding-crash` then parse `.ips` JSON (skip header line).

## 1. Completed this session (all build-verified)

| Work | Key files/notes | Deployed |
|---|---|---|
| Auth-refresh fixes | `SoundCloudCredentialSource.swift:608-621`, `refreshIfNeededAtLaunch()` in mac/tv app delegates, `DeviceSessionStore` no failed-read caching | yes (earlier) |
| Download crypto off main thread | `DownloadManager` sync `localFileURL(for:)` vs async `resolvedLocalFileURL(for:)` (Task.detached + dedup) | yes (earlier) |
| iOS crash on play | `{ @Sendable _ in image }` in all 3 `NowPlayingArtworkProvider.swift` (MediaPlayer calls handler off-main; was `@MainActor` trap) | yes (earlier) |
| Playback state fixes | monotonic currentTime clamp, `seekInFlight`, `SystemNowPlayingBridge` NaN/dedup, `WaveformService` NSCache | yes (earlier) |
| iOS Settings rework | `PhoneSettingsView.swift`: white glyphs on tiles, 28 row-background overrides removed, auth-gates removed (no jumping), stable footer/icon | iPhone ✓ |
| PlaybackClock split (tvOS lag fix) | new `Core/Playback/PlaybackClock.swift` + `Shared/UI/Components/PlaybackClockView.swift`; `PlayerService.currentTime/duration` now computed pass-throughs; root/shelves/rows no longer tick at 2Hz. iOS file-private `PlaybackClock` renamed `PlaybackAnchorClock` | iPhone ✓ TV ✓ Mac ✓ |
| tvOS Sets pane + playlist grid + list perf | new `Apps/tvOS/UI/Components/SetListView.swift` (240pt cards, focus-revealed "View Setlist"); `LibraryView.swift:351` uses it; playlists 4-col + `SCCollectionArtworkResolver` mosaic + "N tracks" subtitles; `TrackListView` cached `visibleTracks`; `DeckIdentity.isLikelyMix` static regex | TV ✓ |
| Waveform smooth glide (shared) | `Shared/UI/Components/PulseTimeline.swift`: `Pulse.timelinePosition(...)` + `SmoothPlaybackTimeline`; iOS `TransportBarView` + macOS `MacNowPlayingView`/`MacTransportBar` scrubbers now interpolate at display cadence (tvOS was reference); iOS seek re-anchor bug fixed; `PlaybackClock.swift` registered in watchOS target | all ✓ |
| Waveform follow-ups | `Shared/Design/WaveformRenderer.swift`: `SCWaveformMarkerLane` (cue=diamond, suggestion=ring, comment=dot — ONE lane), `SCWaveformNeighbor` (dimmed prev/next past edges, `.centered` mode only), trailing mix-overlap via `PlayerService.shared.adaptiveMixPlan` (leading always plain — no public prev-plan accessor). macOS: neighbors only in `MacNowPlayingView`, not fixed-mode `MacTransportBar` | iPhone ✓ TV ✓ (Mac pending) |
| Downloads "Download this" | `CollectionDownloadButton` moved to `Shared/UI/Components/` + hydrating init (`pinForOfflineHydrating`); iOS: Likes(already)+`PlaylistDetailView`+`FeedPlaylistDetailView`; macOS: `MacPlaylistDetailView` hero + `MacLibraryBrowserView` likes toolbar; tvOS: `PlaylistDetailView` action row + Likes toolbar | iPhone ✓ TV ✓ Mac ✓ |
| Smart Downloads (opt-in) | `SettingKeys.SmartDownloadsEnabled` (deviceLocal, default false); `DownloadManager.refreshSmartDownloadsIfNeeded()` (likes index top-15 + `SoundCloudAPI.getPlayHistory(limit:10)` → dormant `considerRecommended`); triggers: `$isSyncing` settle + toggle-on. Toggles: iOS `DownloadsSettingsDetail`, macOS `MacAccountView`, tvOS `SettingsView.swift:~644` | iPhone ✓ TV ✓ Mac ✓ |
| tvOS decks perf + vinyl platter | `DJModeView.swift` restructured: root no longer observes clock, ticking leaves (`DJPlatterLive`, `DJDeckBColumn`, `DJMixerLeaf`, `DJWaveformPanel` leaf), `DJTimelineCache` memoizes resampled envelopes, `CinematicBackdrop` now `isAnimated:false` (static wash), shadows trimmed. NEW `Shared/UI/Components/VinylPlatterView.swift` (generic label, position-driven rotation 1.8s/rev, Canvas grooves — no UIKit, no timers) | all ✓ |
| Like-state unification | agent-18 completed the shared `LibraryCache.containsLike`/revision path; the legacy iOS probe and macOS capped fetch were removed | all ✓ |
| Decks core consolidation | `DJSessionDirector` owns the session; `PhantomDJEngine.Plan` is the single plan currency; `DJSessionSnapshot` is the coalesced console read model; junkie templates implemented | all ✓ |
| Cache-first first frame | `LibraryCache.loadSection` is synchronously readable; discovery/feed plus initial iOS Library, tvOS Home, and macOS Library view models hydrate persisted rows in `init`, then refresh in the background. Cached content no longer waits through an empty/loading SwiftUI frame | all ✓ |
| Decks UI parity | NEW shared `DJTransitionPlanView.swift`; tvOS consumes `DJSessionSnapshot` for measured knobs and stage progress; plan/stages/rationale travel in `DJStatePayload` to iPhone; Mac shows the same plan without taking an active Auto session manual; iOS/macOS use shared `VinylPlatterView` | all ✓ |
| Neighbor waveform clarity + back-track reuse | shared renderer tints previous context blue at 50%, next violet at 50%, mix overlap at 78%; `WaveformService` keeps an eight-track strong working set in addition to `NSCache`, preventing a just-visible previous waveform from reverting to loading when selected | all ✓ |
| Continue Listening repair | Top Shelf playback writes the full recent `Track` payload to `LibraryCache`; tvOS Home hydrates synchronously, observes snapshot changes, refreshes recents, and republishes progress when backgrounded | iPhone ✓ TV ✓ Mac ✓ |
| Top Shelf actions | display and play actions are now distinct; track/playlist routes survive cold launch, either navigate to the requested detail or start the requested item, and playlist actions no longer silently fall back to Home | TV ✓ |
| Launch navigation + auth presentation | iOS starts on Home; the shared credential source keeps launch refresh/revalidation behind one establishing-session boundary so a recoverable stale token no longer flashes Reconnect | iPhone ✓ TV ✓ Mac ✓ |
| tvOS Decks second perf pass | removed synchronous crash-log writes from `DJModeView.body`; mix progress is clock-derived instead of publishing the whole `PlayerService` at 30 Hz; decorative platter cadence is 15 Hz and its 48 SwiftUI tick views are one `Canvas`; transition completion poll is 10 Hz | TV ✓ |
| Full Junkie performance visibility | every plan has an executor-faithful display stage list (including legacy blends); shared timeline shows all stages, countdown, LIVE/DONE/NEXT state and continuous ramp/loop progress, auto-scrolls, and travels to iPhone/Mac; TV shows LP, HP, resonance, rate, delay, loop length, level, full EQ and crossfader telemetry | iPhone ✓ TV ✓ Mac ✓ |
| High-pass handover | promoted `highPassThinOut` from the spec's future list into the real registry/profile/planner/executor. It uses measured grids, drift gating, full-bodied entries, the existing HP DSP ramp, incoming fader ramp and bass handover. Fixed staged fader coordinates when the physical live deck is B | iPhone ✓ TV ✓ Mac ✓ |

## 2. In flight RIGHT NOW

None. Cache-first hydration, navigation/auth/Top Shelf/Continue Listening fixes, waveform fixes,
the Decks performance pass, and the complete Junkie automation presentation have been built and
installed on the iPhone, Apple TV, and Mac.

## 4. Pending work (with briefs)

### 4.1 Decks UI parity + transition-plan view + realtime knobs — COMPLETE

Shared plan/stage/rationale formatting lives in `Shared/UI/Components/DJTransitionPlanView.swift`.
tvOS and macOS observe the coalesced local snapshot; iPhone remains the authenticated remote
console and receives the same display-safe plan stages over `DJStatePayload`. Measured control
values drive the visible readouts, and iOS/macOS now use the shared vinyl platter.

The fourth revision extends this to the whole automated performance. Loop ladders, low/high-pass
sweeps, EQ swaps, echo/delay throws, tempo ramps, crossfader ramps, hard cuts and double-drop stages
all expose countdown and live progress. Default/legacy blends synthesize display stages from the
same parameters executed by `beginDefaultTransition`, rather than appearing idle. `highPassThinOut`
is now a shipping template, not a future placeholder.

### 4.1a tvOS Decks performance — COMPLETE, DEVICE FEEL NEEDS USER CONFIRMATION

The two main full-console invalidation sources are gone: synchronous DEBUG crash logging from the
view body and 30 Hz writes to `PlayerService.mixWindow.progress`. Progress is derived from immutable
mix-window bounds plus `PlaybackClock`; the platter's decorative refresh is capped at 15 Hz and its
ring is one `Canvas`. Signed build installed on Living Room Apple TV (database sequence 1920).

### 4.2 Recheck "About a Track" styling on device (user verification, not code)
User said some tvOS screens don't use tvOS styles, naming about-a-track. Only such screen is
`Apps/tvOS/Features/Player/BehindTheTrackView.swift` — agent-13 inspected: already uses tvOS
design tokens throughout. Likely stale-build artifact. Ask user to recheck on current build;
if still off, get a screenshot.

### 4.3 Known leftovers / smaller items
- `PolyphonyView` (iOS) has no signed-out branch — shows idle content signed out.
- tvOS comment markers lost avatars in the unified marker lane (dots by design; bubble keeps avatars) — flag if user complains.
- Deck B rotation steps at 0.5s cadence in preview (non-live) mixes — could get its own interpolation anchor.
- Leading-edge waveform neighbor is always plain (no public previous-track plan accessor — PlayerService read-only constraint at the time; agent-16's snapshot may unlock honest leading overlap too).
- Residual perf: `AmbientArtworkBackdrop` still animated on tvOS screensaver (`AmbientScreenView`), `SCFocusEffect` animated shadows per card, `AmbientIdleMonitor` 1s timer.
- First play of legacy downloaded track = one-time background vault migration (slight delay, by design).
- watchOS had a pre-existing registration bug (fixed); watch target builds as part of iOS scheme — transient parallel `SwiftEmitModule` failures seen once, rerun fixes.

## 5. Rules of the road (hard-won)

- **Never run two agents on the same files.** The session's whole sequencing is built on file
  ownership. Before dispatching, check ownership against in-flight agents.
- **Builds catch torn mid-edit trees.** If a deploy build fails in a file an agent owns, wait
  for that agent — do NOT "fix" their half-written state.
- **Quota 403s happen** ("usage limit for this billing cycle"). Resume agents; if the main
  session is also capped, stop and leave this doc current.
- **Keep this doc updated** as things land — it's the continuity mechanism.
- Verify builds with `tail -3` → `** BUILD SUCCEEDED **`.

## 5.1 Latest verification / deploy (fourth revision)

- tvOS signed device build: `** BUILD SUCCEEDED **`; installed to Living Room Apple TV,
  database sequence **1920**, and launched successfully.
- iOS signed device build: `** BUILD SUCCEEDED **`; installed to iPhone 15 Pro Max,
  database sequence **5300**. Post-install launch verification was denied only because the phone
  was locked; the install itself completed successfully.
- macOS signed build: `** BUILD SUCCEEDED **`; copied to `/Applications/Sounding.app` and
  `codesign --verify --deep --strict` passed.
- Generic tvOS, iOS and macOS compile gates also passed. A first parallel generic iOS build only
  hit Xcode's shared `build.db` lock; its isolated rerun passed.
## 6. Session files (full audit trail)

Session home: `/Users/afr/.kimi-code/sessions/wd_sounding-tv_bd828e034352/session_61358058-f9c0-4c14-a079-0f6617f16e6f/`
- `state.json` — session state; `logs/` — session logs
- Agent task records: `agents/main/tasks/<task-id>/output.log` (final report) + `<task-id>.json` (metadata)

Key reports (each is the agent's own complete handoff for its scope):

| Agent | Task ID (path under `agents/main/tasks/`) | Scope |
|---|---|---|
| explorer agent-6 | `agent-z4zgxqdw/output.log` | Downloads subsystem map |
| explorer agent-7 | `agent-kryzl335/output.log` | iOS Settings diagnosis |
| explorer agent-8 | `agent-9jz1h01e/output.log` | tvOS lag + set list diagnosis |
| explorer agent-11 | `agent-58oy5fn5/output.log` | Like-state root cause |
| explorer agent-12 | `agent-224x90c1/output.log` | Decks/DJ architecture map |
| coder agent-9 | `agent-1ugvb691/output.log` | iOS Settings rework |
| coder agent-10 | `agent-amo8edn3/output.log` | PlaybackClock split |
| coder agent-13 | `agent-tzkjsdyo/output.log` | tvOS Sets pane + grid + perf |
| coder agent-13 | `agent-yrhl7gjb/output.log` | tvOS download buttons + smart toggle |
| coder agent-14 | `agent-jnuqg1fa/output.log` | Waveform smooth glide |
| coder agent-14 | `agent-2c389yjl/output.log` | Waveform markers/neighbors/overlap |
| coder agent-15 | `agent-2qsh22po/output.log` | Downloads manual + smart (iOS/macOS/Core) |
| coder agent-17 | `agent-cjzqeazf/output.log` | tvOS decks perf + VinylPlatterView |
| coder agent-16 | `agent-hj6mn4bq/output.log` | Decks Core consolidation (IN FLIGHT — may not exist yet) |
| coder agent-18 | `agent-6imhnt3k/output.log` | Like-state unification (IN FLIGHT — may not exist yet) |

Note: earlier attempts of several tasks died to quota 403s (`agent-t7mc47cs`, `agent-lult83tf`,
`agent-68y1ctvh`, `agent-y8of1e3h`, `agent-gwbrvmw9`) — the resumed runs above supersede them.
