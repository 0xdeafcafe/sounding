# SoundingCloud — Feature / UI / Ability Matrix

A cross-target map of what each app can do, which shared modules it compiles, and where
the asymmetries are.

Product name is **SoundingCloud** (`CFBundleDisplayName`); `SoundingTV` remains the
repo/target naming from before the rename.

**Legend**

| Symbol | Meaning |
| :---: | --- |
| ● | Full native implementation |
| ◐ | Partial — reduced surface, or drives another device rather than acting locally |
| ○ | Not implemented |
| — | Not applicable to the platform |

---

## 1. Targets

| Target | Scheme | Sources | Role |
| --- | --- | ---: | --- |
| tvOS app | `SoundingTV` | `SoundingTV.swiftpm/Sources/Apps/tvOS` (+ 122 files total) | Flagship. Big-screen player, DJ console, remote-control host |
| iOS app | `SoundingTV iOS` | `SoundingTV-iOS/Sources` (+ 116) | Full client, Companion remote, Watch host, auth origin |
| macOS app | `SoundingTV macOS` | `SoundingTV-macOS/Sources` (+ 117) | Full client + hardware DJ rig (MIDI), no native sign-in |
| watchOS app | `SoundingTV watchOS` | `SoundingTV-watchOS/Sources` (+ 63) | Remote control + browser. No local audio |
| Widget ext. | `SoundingTV-Widget` | `SoundingTV-Widget/Sources` (11) | iOS Live Activity / Dynamic Island |
| Share ext. | `SoundingTV-Share` | `SoundingTV-Share/Sources` (21) | iOS share sheet → send to Apple TV |
| Top Shelf ext. | `SoundingTV-TopShelf` | `SoundingTV-TopShelf/Sources` (5) | tvOS home-screen shelf |
| UI tests | `SoundingTV-UITests` | `SoundingTV-UITests/Sources` (1) | tvOS focus-engine regression suite |

`SoundingTV-tvOS/` holds only `Info.plist`, entitlements and assets — the tvOS Swift
sources live inside the SwiftPM package under `Sources/Apps/tvOS`.

> **Never run `xcodegen`.** `project.yml` declares only the tvOS target; the `.pbxproj`
> is hand-maintained and carries the other seven.

---

## 2. Feature matrix

### 2.1 Browse & discovery

| Capability | tvOS | iOS | macOS | watchOS |
| --- | :---: | :---: | :---: | :---: |
| Home / discovery shelves | ● | ● | ● | ● |
| Stream (activity feed) | ● | ● | ● | ○ |
| Search (tracks/artists/playlists) | ● | ● | ● | ◐ ¹ |
| Genre browse grid | ● | ○ | ● | ○ |
| Recent searches | ● | ● | ○ | ● |
| Library index (likes/playlists/following) | ● | ● | ● | ● |
| Artist detail | ● | ● | ● | ● |
| Playlist / album detail | ● | ● | ● | ● |
| Own profile | ● | ● | ● | ○ ² |
| Sortable track lists + analysis columns | ● | ● | ● | ○ |
| Per-collection download policy editor | ● | ● | ● | ○ |
| Infinite scroll / pagination | ● | ● | ● | ● |

¹ `WatchSearchView` is fully built but **orphaned** — no `NavigationLink` reaches it.
² Account identity only, inside Settings.

### 2.2 Playback

| Capability | tvOS | iOS | macOS | watchOS |
| --- | :---: | :---: | :---: | :---: |
| Local audio engine | ● | ● | ● | ○ ³ |
| Play / pause / next / previous | ● | ● | ● | ◐ |
| Shuffle | ● | ● | ● | ◐ ⁴ |
| Repeat modes (off/all/one) | ● | ● | ● | ○ |
| Seek / scrub | ● | ● | ● | ◐ ⁵ |
| Waveform scrubber | ● | ● | ● | ○ |
| Queue view | ● | ◐ ⁶ | ● | ○ |
| Queue reorder / remove | ◐ ⁷ | ◐ ⁶ | ● | ○ |
| Add to queue / play next | ● | ● | ● | ◐ |
| Add to playlist | ● | ○ | ● | ○ |
| Like / unlike | ● | ● | ● | ○ |
| Persistent mini transport | ● | ● | ● | ◐ |
| Full Now Playing screen | ● | ● | ● | ● |
| Ambient artwork palette | ● | ● | ● | ● |
| Timed comments on waveform | ● | ● | ● | ○ |
| Comments panel | ● | ● | ● | ○ |
| "Behind the Track" info | ● | ● | ● | ○ |
| Output routing / AirPlay picker | ● | ● | ● | ◐ ⁸ |
| Background audio | ● | ● | ● | — |
| System Now Playing / media keys | ● | ● | ● | ◐ |

³ No `AVPlayer` path exists on watchOS despite `WKRunsIndependentlyOfCompanionApp = true`.
⁴ Playlist-level shuffle only. ⁵ Digital Crown scrub with debounced commit.
⁶ `QueueManagerView` manages the **Apple TV's** queue; no local-queue editor on iPhone.
⁷ Reorder/remove is driven from the phone via `RemoteQueueServer`. ⁸ iPhone ↔ Apple TV switch only.

### 2.3 DJ / mixing — the flagship differentiator

| Capability | tvOS | iOS | macOS | watchOS |
| --- | :---: | :---: | :---: | :---: |
| `MixEngine` compiled in | ● | ● | ● | ○ ⁹ |
| Dual-deck console UI | ● `DJModeView` | ● `DJControlView` ¹⁰ | ● `MacConsoleView` | ○ |
| Auto-mix / transition planner | ● | ● | ● | ◐ ¹¹ |
| "Mix Now" manual trigger | ● | ● | ● | ● |
| DJ personality profiles | ● | ● | ● | ○ |
| Jog wheels | ● | ● | ● | ○ |
| 3-band EQ + filter + trim | ● | ● | ● | ○ |
| Crossfader | ● | ● | ● | ○ |
| Tempo fader / key lock | ◐ | ● | ● | ○ |
| Hot cues (4/deck) | ● | ● | ● | ○ |
| Loop control (toggle/half/double) | ● | ● | ● | ○ |
| BPM / key ("Camelot") match chip | ● | ● | ● | ○ |
| Track Map / cue-point editor | ● | ● | ◐ | ○ |
| Keyboard shortcut map | — | — | ● | — |
| MIDI controller (DDJ-400) | ○ | ○ | ● | ○ |
| Separate cue-bus detection | ○ | ○ | ● | ○ |

⁹ watchOS compiles 1 of 15 `Core/DJ` files — types only, no engine.
¹⁰ iPhone's deck console is a **remote surface** driving the Apple TV's engine.
¹¹ Toggle Auto DJ + Mix Now, relayed to the iPhone.

### 2.4 Music intelligence & analysis

| Capability | tvOS | iOS | macOS | watchOS |
| --- | :---: | :---: | :---: | :---: |
| Waveform generation | ● | ● | ● | ◐ |
| Genre taxonomy inference | ● | ● | ● | ◐ |
| `MusicUnderstanding` deep analysis | ○ ¹² | ● | ● | ○ |
| ShazamKit setlist scanning | ● (secondary) | ○ ¹³ | ● (primary) | ○ |
| `FoundationModels` deck identity | ○ | ● | ● | ○ |
| Setlist / tracklist editor | ● | ● | ● | ○ |
| Analysis dashboard w/ provenance | ● | ● | ● ¹⁴ | ○ |
| Manual analysis correction | ○ | ○ | ● | ○ |
| Analysis cache (SQLite) | ● | ● | ● | ● |

¹² Explicitly gated off — `MusicUnderstandingProducer.isSupportedOnThisPlatform` returns
false on tvOS. ¹³ By design: iPhone consumes Mac/TV-produced results via CloudKit rather
than burning battery. ¹⁴ macOS's `MacIntelligenceView` is the richest of the three.

> **ShazamKit is not an entitlement.** Do not add `com.apple.developer.shazamkit` to
> the `.entitlements` files — it breaks all three apps with exit 65. It is granted via
> App Services on the App ID.

### 2.5 Auth & pairing

| Capability | tvOS | iOS | macOS | watchOS |
| --- | :---: | :---: | :---: | :---: |
| Native OAuth sign-in | ○ | ● ¹⁵ | ○ ¹⁶ | ○ |
| QR-code pairing (display) | ● | — | ○ | — |
| QR scan → hand off token | — | ● | — | — |
| Numeric-comparison handshake (ECDH) | ● | ● | ● | ● |
| Bonjour + TLS-PSK pairing channel | ● | ● | ● | ◐ |
| Authorize a waiting Apple TV | — | ● | ● | ● ¹⁷ |
| Adopt session via CloudKit sync | ● | ● | ● | ○ ¹⁸ |
| Adopt session from iPhone (WC) | — | — | — | ● |
| Sign out | ● ¹⁹ | ● | ◐ ²⁰ | ● |

¹⁵ `SoundCloudLoginView` loads SoundCloud's unmodified mobile sign-in flow and inspects
the completed WebKit session only after `/signin/callback`. It does not intercept
`/oauth/token`. ¹⁶ macOS uses the same best-effort personal web-session flow; neither
platform claims a registered SoundCloud OAuth client. See `soundcloud-integration.md`.
¹⁷ Genuinely watch-unique: authorize a TV from the wrist with no phone interaction.
¹⁸ watchOS does not compile `Core/Sync` at all. ¹⁹ Hard privacy reset — clears queue,
Top Shelf and library cache. ²⁰ Local only; pauses adoption of the synced session.

### 2.6 Sync, downloads & offline

| Capability | tvOS | iOS | macOS | watchOS |
| --- | :---: | :---: | :---: | :---: |
| CloudKit sync engine (`CKSyncEngine`) | ● | ● | ● | ○ |
| — session sync | ● | ● | ● | ○ |
| — cue sync | ● | ● | ● | ○ |
| — analysis sync | ● | ● | ● | ○ |
| — download-manifest sync | ● | ● | ● | ○ |
| — setlist sync | ● | ● | ● | ○ |
| Download manager | ● | ● | ● | ◐ ²¹ |
| Storage cap + LRU eviction | ● (10 GB default) | ● (2 GB) | ● (2 GB) | ○ |
| Quality ceilings + per-collection override | ● | ● | ● | ○ |
| Post-download analysis kickoff | ● | ○ ²² | ● | ○ |
| Peer content transport (device→device streaming) | ● | ● | ● | ○ |

²¹ Read-only mirror of the iPhone's downloads. ²² `resumeDownloadedIntelligenceWork()`
is gated to `#if os(macOS) || os(tvOS)` — mains-powered devices do the heavy lifting.

### 2.7 Cross-device & system integration

| Capability | tvOS | iOS | macOS | watchOS |
| --- | :---: | :---: | :---: | :---: |
| Remote queue **server** (is controlled) | ● | ○ | ○ | ○ |
| Remote queue **client** (controls a TV) | ○ | ● | ● | ◐ |
| Polyphony (synchronised nearby listening) | ● | ● | ● | ◐ ²⁶ |
| WatchConnectivity host | — | ● | — | — |
| Handoff (`NSUserActivity`) | ● | ● | ● | ◐ ²³ |
| Live Activities / Dynamic Island | — | ● | — | ○ |
| App Intents / Siri Shortcuts | ● | ● | ● | ○ |
| Spotlight indexing | ○ | ● | ○ | ○ |
| Top Shelf | ● | — | — | — |
| Share extension target | — | ● | ○ | — |
| Widgets / complications | — | ● ²⁴ | ○ | ○ ²⁵ |
| Deep links (`soundingtv://`) | ● | ● | ○ | ○ |
| Universal links (`applinks:`) | ○ | ● | ● | ○ |

²³ Activity type declared in `Info.plist` but no `onContinueUserActivity` handler found.
²⁴ Live Activity only — no home-screen widget. ²⁵ No complications exist.
²⁶ The Watch mirrors Polyphony state and can start or leave the session hosted by its paired iPhone; audio remains on the phone.

### 2.8 Platform-exclusive abilities

| Platform | Exclusive to it |
| --- | --- |
| **tvOS** | Top Shelf shelves; ambient screensaver (`AmbientScreenView`, DJ-aware); focus-engine design language; remote-queue **server**; `.sidebarAdaptable` tab view; d-pad scrub / `onMoveCommand`; QR-code sign-in display |
| **iOS** | Native OAuth (the only real login origin); Live Activities + Dynamic Island; Spotlight indexing; share extension; WatchConnectivity host; camera QR scan; tab-bar bottom accessory transport |
| **macOS** | `MenuBarExtra` mini player; multi-window (Now Playing + Mini Player as separate `Window` scenes); real menu-bar commands + keyboard shortcuts; CoreMIDI hardware (DDJ-400 mapping, live MIDI monitor); CoreAudio device introspection / cue-bus detection; manual analysis correction; `NSVisualEffectView` materials; app sandbox |
| **watchOS** | Digital Crown scrubbing; authorize an Apple TV from the wrist; phone-relayed transport |

---

## 3. Shared-module compilation matrix

Ground truth from `SoundingTV.xcodeproj/project.pbxproj` build phases. Numbers are files
compiled into that target; `○` means the module is not in the target at all.

| Module | tvOS | iOS | macOS | watchOS | Widget | Share | TopShelf |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| `Core/Analysis` | 12 | 11 | 11 | 5 | ○ | ○ | ○ |
| `Core/Artwork` | 2 | 2 | 2 | 2 | ○ | ○ | ○ |
| `Core/DJ` | 15 | 15 | 15 | 1 | ○ | ○ | ○ |
| `Core/Downloads` | 4 | 4 | 4 | 1 | ○ | ○ | ○ |
| `Core/Library` | 2 | 2 | 2 | 1 | ○ | ○ | ○ |
| `Core/Models` | 6 | 5 | 5 | 5 | ○ | 5 | ○ |
| `Core/Networking` | 2 | 2 | 2 | ○ | ○ | ○ | ○ |
| `Core/Playback` | 7 | 7 | 7 | 3 | ○ | ○ | ○ |
| `Core/Polyphony` | 1 | 1 | 1 | ○ | ○ | ○ | ○ |
| `Core/Setlist` | 3 | 3 | 3 | 3 | ○ | 3 | ○ |
| `Core/Settings` | 1 | 1 | 1 | 1 | ○ | ○ | ○ |
| `Core/SoundCloud` | 2 | 2 | 2 | 2 | ○ | 2 | ○ |
| `Core/Support` | 2 | 2 | 2 | 2 | 2 | 2 | 2 |
| `Core/Sync` | 1 | 1 | 1 | ○ | ○ | ○ | ○ |
| `Core/TopShelf` | 1 | ○ | ○ | ○ | ○ | ○ | 1 |
| `Core/WatchLink` | ○ | 1 | ○ | 1 | ○ | ○ | ○ |
| `Auth/Shared` | 2 | 5 | 5 | 4 | 3 | 3 | ○ |
| `Shared/AppIntents` | 2 | 2 | 2 | ○ | ○ | 1 | ○ |
| `Shared/Design` | 8 | 9 | 7 | 8 | ○ | 1 | ○ |
| `Shared/LiveActivity` | ○ | 2 | ○ | ○ | 2 | ○ | ○ |
| `Shared/Networking` | ○ | 1 | 1 | ○ | ○ | ○ | ○ |
| `Shared/UI/*` | 7 | 7 | 6 | 4 | ○ | 1 | ○ |
| `Shared/ViewModels` | 5 | 5 | 5 | 4 | ○ | ○ | ○ |
| `Shared/Debug` | 1 | 1 | 1 | 1 | ○ | ○ | ○ |

**Reading the gaps**

- **watchOS omits `Core/Sync`, `Core/Networking`, `Core/Polyphony`** and takes only 1 of
  15 `Core/DJ` files. It is a thin client by construction: no CloudKit, no peer transport,
  no mix engine.
- **tvOS omits `Shared/Networking`** (`RemoteQueueClient`) — it is the server, not a client.
- **tvOS compiles only 2 of 5 `Auth/Shared`** files; the phone-side web-login and session
  sync pieces don't belong on the TV.
- **iOS is the only target with both `Core/WatchLink` and `Shared/LiveActivity`.**
- **`Core/TopShelf` reaches only tvOS and the Top Shelf extension.**
- **iOS compiles 3 files from `Apps/tvOS/Features`** (Feed ×1, Library ×2) — cross-target
  view reuse that crosses the intended app boundary. Worth watching.

---

## 4. Navigation & UI shape

| | tvOS | iOS | macOS | watchOS |
| --- | --- | --- | --- | --- |
| **Shell** | `TabView(.sidebarAdaptable)` | `TabView` (iOS 18 `Tab` API) | `NavigationSplitView` | `NavigationStack` + `List` |
| **Top-level destinations** | 7 — Home, Stream, Search, Library, Now Playing, Profile, Settings | 6 — Home, Stream, Library, Companion, Settings, Search | ~16 sidebar rows in 4 groups | 6 push rows |
| **Transport placement** | Bottom-trailing floating bar | Tab-bar bottom accessory | Bottom `safeAreaInset` | Now Playing chip |
| **Now Playing** | Dedicated tab | Full-screen sheet (zoom transition) | Takeover overlay **or** detached window | Pushed screen |
| **Queue** | Up Next preview | Separate `QueueManagerView` (TV's queue) | `.inspector` sidebar | None |
| **Design system** | `Apps/tvOS/Design` — focus scale + lift, glass chrome | `Shared/Design/PhoneDesign` | `MacMaterials` + `Sources/Design` | `Shared/Design` |
| **Router** | `NavigationState` env object | Per-tab `NavigationStack` | `MacRootSelection` pub/sub | Plain push |

> **tvOS focus style:** size-inverse `scaleEffect` (1.15 tile / 1.08 card / 1.05 hero) +
> top-lit sheen + soft downward shadow + label promotion, with `.focusEffectDisabled()`.
> **No focus ring of any colour** — Apple draws none. Focused chrome inverts to a
> near-white fill with a black label. Glass effects are reserved for nav/chrome.

---

## 5. Extensions

| | Widget | Share | Top Shelf |
| --- | --- | --- | --- |
| Host | iOS | iOS | tvOS |
| Extension point | `com.apple.widgetkit-extension` | `com.apple.share-services` | `com.apple.tv-top-shelf` |
| Purpose | Now Playing Live Activity — Lock Screen + Dynamic Island (compact/expanded/minimal) | Send a shared SoundCloud URL to the paired Apple TV | 4 dynamic home-screen shelves |
| Actions | Prev / Play-Pause / Next / **Mix Now** via App Intents | Add to End / Play Next / Play Now / Replace Queue (≤100 tracks) | Play + display, deep-linked back into the app |
| Network I/O | ● Bonjour discovery + signed TCP direct to the TV | ● Same, plus `SoundCloudAPI.resolve` | ○ Reads an app-group snapshot |
| Reads | `NowPlayingActivityAttributes`, `PairedTVStore` | `DeviceSessionStore`, `PairedTVStore` | `TopShelfStore` snapshot |
| Fallbacks | Optimistic state w/ rollback on `SendError` | Not-a-SC-link / not-signed-in / partial-batch errors | signedOut / noSnapshot / emptyLibrary shelves |
| Complete? | Yes | Yes | Yes |

The Widget deliberately carries **only** the shared keychain group
(`red.forbes.sounding.shared`), not the app's own — it has no business reading the
SoundCloud session, only the TV pairing secret.

---

## 6. Entitlements & declared capabilities

| | tvOS | iOS | macOS | watchOS | Widget | Share | TopShelf |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| iCloud / CloudKit | ● | ● | ● | ○ | ○ | ○ | ○ |
| App group | ● | ○ | ○ | ○ | ○ | ○ | ● |
| Keychain access groups | ● | ● | ● | ● | ● | ● | ○ |
| Associated domains | ○ | ● | ● | ○ | ○ | ○ | ○ |
| App sandbox | — | — | ● | — | — | — | — |
| Bonjour (`_soundingtv._tcp`) | ● | ● | ● | ● | ● | ● | ○ |
| Background audio | ● | ● | — | ○ | — | — | — |
| Live Activities | — | ● | — | ○ | ● | — | — |
| USB device (MIDI) | — | — | ● | — | — | — | — |
| Music library read-only | — | — | ● | — | — | — | — |

CloudKit container is `iCloud.red.forbes.sounding`; app group is
`group.red.forbes.sounding`; the shared keychain group is `red.forbes.sounding.shared`.

---

## 7. Known gaps & asymmetries

**Structural**

- **SoundCloud sign-in is unofficial and best effort.** iOS and macOS load SoundCloud's
  unmodified mobile sign-in flow and can adopt a completed web session only when it
  exposes all required session material. There is no registered SoundingCloud OAuth
  client, embedded secret, or borrowed third-party identity.
- **watchOS has no local audio path** despite `WKRunsIndependentlyOfCompanionApp = true`.
  Every play is a WatchConnectivity command to the iPhone. The plist declares a
  standalone capability the code does not deliver.
- **watchOS has no CloudKit.** It adopts its session over WatchConnectivity only, so if
  the phone was never reachable the watch is fully blocked.
- **No lyrics feature — by design.** When mirroring Apple Music's Now Playing, the pane
  toggle's second slot is Up Next / Comments / Tracklist / About, never Lyrics.

**Missing surfaces**

- No **local queue editor** on iPhone — `QueueManagerView` only manages the Apple TV's queue.
- `WatchSearchView` is **fully built but orphaned** — nothing navigates to it.
- No **watch complications**, no iOS **home-screen widget** (Live Activity only).
- No **Add to Playlist** on iOS (present on tvOS and macOS).
- No **repeat-mode** control on watchOS; shuffle is playlist-level only.
- macOS has no **drag & drop** and no **AppleScript** support.
- macOS **MIDI mapping editor** is not built — `HardwarePane` is a raw monitor and says so.

**Honest limitations documented in-product**

- Beat grids are spaced from tempo but **not aligned to a detected downbeat**.
- Genre detection is text-matched, not audio-analysed — roughly 1 track in 8 resolves on
  a real 321-track library, at low confidence.
- CDJ / Pioneer Pro DJ Link is **impossible**, not merely absent — proprietary, no SDK.
- No Dolby Atmos: SoundCloud does not provide spatial masters.

**In-flight refactor (working tree, not committed)**

- `RemoteQueueClient` is being moved out of `SoundingTV-iOS/Sources/Features/AppleTV/`
  into `SoundingTV.swiftpm/Sources/Shared/Networking/` so iOS, macOS and watchOS share one
  client. iOS code still references it throughout.
- The Polyphony engine has moved to `Core/Polyphony`; the old iOS implementation remains
  behind `#if POLYPHONY_LEGACY_IMPLEMENTATION` as migration history.

---

## 8. Testing

| Suite | Target | Coverage |
| --- | --- | --- |
| `SoundingTV-UITests/FocusWalkTests.swift` | tvOS (via `XCUIRemote`) | 13 tests, entirely focus-engine correctness |
| ~28 in-app `*SelfTest` enums | All | Runtime assertion suites in `Core`, not XCTest |

`FocusWalkTests` asserts: every tab has something focusable on entry; focus enters content
rather than the sidebar on Search/Settings/Profile; Settings walks to the bottom without
stranding; Menu returns to the Settings root without quitting; loading skeletons are
themselves enterable; comment replies and untimed rows are remote-reachable.

**There is no unit-test coverage** for the macOS app, the widget, the share extension, or
the Top Shelf provider. The `*SelfTest` pattern (`DJEngineSelfTest`, `CueSelfTest`,
`MixLoopSelfTest`, `CredentialLeakSelfTest`, `PageDecodeSelfTest`, `CloudSyncSelfTest`, …)
carries most of the real verification burden and is invoked from debug menus and the
`SOUNDING_TV_MIXTEST` env var rather than by `xcodebuild test`.

---

## 9. Frameworks by subsystem

| Framework | Used in |
| --- | --- |
| AVFoundation / AVFAudio / Accelerate / AudioToolbox | `Core/DJ/MixEngine`, `Core/Playback`, `Core/Analysis`, `Core/Networking` |
| MusicUnderstanding | `Core/Analysis/AnalysisProducers`, `Core/Playback/PlayerService` — **off on tvOS** |
| ShazamKit | `Core/Setlist/SetlistIntelligenceStore` — macOS primary, tvOS secondary |
| FoundationModels | `Core/Setlist/DeckIdentity` — excluded on tvOS + watchOS |
| CloudKit (`CKSyncEngine`) | `Core/Sync/CloudSyncEngine` — the single sync integration point |
| Network (Bonjour / NWConnection) | `Auth/Shared`, `Core/Downloads`, `Core/Networking`, `Core/Polyphony`, `Shared/Networking` |
| CryptoKit | Pairing, sync payload hashing, artwork cache keys, PSK derivation |
| SQLite3 (direct, no ORM) | `AnalysisCache`, `CueStore`, `LibraryCache` |
| ActivityKit | `Shared/LiveActivity` — iOS only |
| AppIntents | `Shared/AppIntents`, Widget playback intents |
| NowPlaying / MediaPlayer | `Core/Playback` — two interchangeable bridges |
| WatchConnectivity | `PhoneWatchLinkServer` (iOS), `WatchLinkClient` (watchOS) |
| CoreMIDI | macOS only — `MIDIControllerHub`, `DDJ400MappingResolver` |
| WebKit | `Auth/Shared/PhoneCredentialSource` — the OAuth web login |
