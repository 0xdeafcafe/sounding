# SoundingCloud — remaining work

Handoff document. Everything an agent needs to pick up the backlog without
re-deriving context. Written 2026-08-04.

**Read `CLAUDE.md` at the repo root first — it is authoritative and records
dozens of already-debugged traps. This file does not repeat it.**

---

## What this is

**SoundingCloud** — an unofficial SoundCloud client for Apple TV, iPhone and
Mac, plus a two-deck DJ mixer. No backend of our own: all three apps talk to
`api-v2.soundcloud.com` directly, and to each other over the local network via
Bonjour + a length-prefixed TCP protocol. Internal names still say `SoundingTV`
deliberately — see CLAUDE.md before renaming anything.

Seven Xcode targets: `SoundingTV` (tvOS), `SoundingTV iOS`, `SoundingTV macOS`,
`SoundingTV-Share`, `SoundingTV-Widget`, `SoundingTV-TopShelf`,
`SoundingTV-UITests`. **Two app schemes green is not the project green.**

Deployment targets tvOS 27.0 / iOS 27.0 / macOS 27.0.

---

## Non-negotiable rules

These are not style preferences. Each one is here because it was violated once
and cost real work.

1. **Never `git stash` / `git checkout` / `git reset`.** `HEAD` is a stale
   checkpoint far behind the working tree; these have permanently destroyed
   uncommitted work twice. Commit only when explicitly asked.
2. **Never edit `SoundingTV.xcodeproj/project.pbxproj` from a subagent.** It is
   a serialization bottleneck. Write new files and report the path + target
   membership; the main session registers them.
3. **Never bypass the entitlement check.** `Track.init` filters snippet
   transcodings so an unentitled track has no `streamURL`. That is the
   enforcement point. Unplayable must be visibly, quietly unavailable — never
   silently broken, never unlocked, including peer-to-peer between the user's
   own devices.
4. **Never log, print, write to disk or report any token, refresh token, cookie
   value, nonce, signature or session id, at any level.** Assert
   presence/absence and shape only.
5. **`~/Music/` is strictly read-only.** 321 real tracks live in
   `~/Music/SoundCloud` and are ideal for testing at real scale.
6. **Use a `-derivedDataPath` that did not exist before** (`mktemp -d`). A
   pre-populated one can report `BUILD SUCCEEDED` without recompiling — this
   false positive fooled three agents at once and hid an unregistered file.
   **Read the exit code**; never pipe to `tail` and judge by that (always 0).
7. **Trust `xcodebuild`, never SourceKit.** `SoundingTV.swiftpm/Package.swift`
   poisons the editor for everything under `swiftpm/Sources/` and emits a
   constant stream of errors no build ever produces. If a diagnostic is not in
   an xcodebuild log, it is not real.
8. **`SIMCTL_CHILD_` prefix is mandatory** for simulator env hooks.
   `simctl launch <dev> <bundle> KEY=VAL` sets argv, not the environment, and
   fails completely silently.

### Design law

- **Glass is chrome only.** Never on content, never glass-on-glass — 27 draws a
  darkened edge on every glass element, so doubling is visibly wrong. Content
  surfaces get opaque fills. "More Liquid Glass" usually means *less* glass in
  fewer, better places.
- **Chrome follows the platform; content components do not.** Track rows, media
  cards, hero cards and their backgrounds, section headers, artwork sizing and
  radius, empty states, analysis badges, **motion** and **the waveform** must
  read as one app across tvOS/iOS/macOS, differing only by a sizing token.
- **tvOS focus** = `scaleEffect` + drop shadow + accent ring with
  `.focusEffectDisabled()`. Not a glass glow, not the stock white pill.
- **No touch UI on macOS.** Ruled out by the owner; no hardware exists to test on.
- **The DJ console ("Decks" on macOS) is Serato/Rekordbox** — dense,
  high-contrast, hard-edged. Making it calmer or more Apple-like is a
  regression. **It must never scroll**; when it does not fit, scale it
  proportionally, then reflow at breakpoints, then raise the window minimum.

### Reference material (committed)

| Path | What |
|---|---|
| `Design/reference/apple-music-ios/` | 6 Apple Music iOS 26/27 captures + `OBSERVED.md`, a measured spec |
| `Design/reference/macos-glass/` | 15 Apple Music macOS 27 captures + `REDESIGN.md` |
| `Design/reference/tvos-current/` | 3 real 4K captures of **our** tvOS app — the before-state |

---

## The project's signature defect: features wired to nothing

**Twelve proven cases now.** All but the last are fixed, but the *rate* is the
point — this keeps happening, and it is invisible to a green build. Check
before believing any "done":

Round one (all since resolved):

- `DownloadManager` — complete, synced, with a settings screen, and no UI
  anywhere called `download()`, so no user could ever start a download.
- `SettingKeys.DJAutoMixEnabled` — fully built, CloudKit-synced, with
  conflict-resolution self-tests, and nothing in the playback path read it.
  **Now wired**: `observeAutoMixSetting()` → `applySessionEnabledTransition` →
  `armMixSession()`, reachable from the Auto-Mix toggle in `PhoneSettingsView`.
- `MacTransportBar` / `MacNowPlayingView` — built, zero call sites, invisible in
  the running app.
- `Button("Open DJ Console") {}` — an empty closure; the menu item did nothing.

Round two, all found in a single six-agent sweep:

- **Five shared design files** — `ContentStyle`, `ContentComponents`,
  `AnalysisBadge`, `GeneratedArtwork`, `WaveformRenderer`, ~90KB, sat in
  `Design/` **in no target at all**. Never compiled. Now registered into all
  three apps — but still adopted by nothing, which is why #114/#116 stay open.
- `DownloadManager.handleBackgroundURLSessionEvents` — zero callers, because
  neither app had a `UIApplicationDelegate`. Background downloads could start
  and never report completion.
- `EntryPoint.hasBassFromHere` — computed on every entry point, read nowhere.
  The same defect at *field* granularity rather than feature granularity, which
  is far harder to spot.
- `LibraryCacheSelfTest` — a full round-trip/ordering/deletion/sign-out suite
  that was never added to the `SOUNDING_TV_MIXTEST` runner, so it had never
  once executed.
- `SOUNDING_TV_TAB=settings` matched case-sensitively and fell through to Home,
  and `SOUNDING_TV_PHONE_DEMO=bar` matched only the literal `"1"`. Both failed
  **silently**, so two screens could not be screenshotted or driven at all —
  which is how a defect survives on a screen nobody can see.

Round three — the sharpest one yet, because every piece of it was individually
"wired":

- **`QualityCeiling`** — the streaming/download quality setting is read by
  nothing. Picking a tier changes no behaviour (#148).
- **`AnalysisLookup`** (#150) — feeds `TrackSort` (shared → tvOS *and* iOS) and
  `MacDeckPanel`, so BPM/key/genre badges and sorting are blank on all three
  platforms. Broken **four independent ways at once**, each sufficient alone:
  it queries `.musicUnderstanding` at a hardcoded `schemaVersion: 1` while the
  producer writes 2 (a hard key miss — the bug arrived silently when #107
  bumped it); its `RawAnalysisPayload` guesses a flat `bpm`/`key: String`
  shape while the producer stores nested `SessionResult`, and because every
  field is optional the decode yields all-nil rather than throwing; it falls
  back to `.fftAudioAnalyzer`, an engine **no producer has ever written** —
  it exists only in self-tests and sync fixtures; and it never queries
  `.genreTaxonomy`, the one engine that writes genre, making that field
  unreachable by construction.

  **The lesson is the second one.** A hardcoded constant that must track a
  value defined elsewhere is not a wiring bug you fix once — it is a wiring bug
  on a timer. `schemaVersion: 1` was *correct* when written. Fixes here must
  derive such values, not copy them.

**For anything you add: grep for a call site outside its own file, and reach it
in the running app.** A green build is not evidence. Neither is a registered
file — check the target's `.SwiftFileList` for what the compiler was actually
handed, and note that every target's intermediates nest under a project-level
`SoundingTV.build/`, so a loose path glob will silently match the wrong target.

### Known environment limits (do not claim past these)

- **Nothing here can synthesise a drag or scroll gesture** — no `Simulator.app`,
  no `idb`, no `cliclick`; `simctl` cannot do gestures. Two tasks are blocked on
  this. `XCUIRemote` (tvOS) *can* drive focus, and is the only way to learn
  anything true about tvOS focus.
- `~/Downloads`, `~/Desktop` and `~/Documents` are TCC-blocked for the shell.
  Reference material must live inside the repo.

---

## In flight

- **macOS** — #108 #113 #115. Owns `SoundingTV-macOS/Sources/**`.

Everything else from the six-agent sweep has landed. Closed this pass: #97 #98
#100 #101 #102 #105 #109 #110 #112 #117 #118, and the DJ set #99 #103 #104 #106
#107.

## Recently landed (context, not work)

- **macOS music surfaces** — Home, Feed, Search, Playlists, Playlist detail,
  Artist, Album, Queue sidebar, Account, track context menu. The Mac previously
  had *only* Library / DJ Console / Status / Hardware and no browse surface at
  all. Two findings worth keeping: the queue pane uses **`.inspector`**, not a
  three-column `NavigationSplitView` — `.doubleColumn` hides the *sidebar*, not
  the trailing column, which a screenshot caught.

  ⚠️ **The second finding was wrong and propagated.** This bullet used to state
  there is no recently-played data source "(no `/me/play-history` endpoint)".
  `me/play-history/tracks` **does exist** — probed live, it returns **401, not
  404**, with a client_id alone, and appears in SoundCloud's own route table.
  So does `me/play-history/contexts` (what you were playing *from*), plus POST
  (add) and DELETE (clear). Shape is still unverified — that needs a token.
  The claim was restated as fact into `Design/specs/sync-coverage.md` before
  anyone tested it. **Absence of an endpoint is a claim that requires a probe;
  a 404 and a 401 mean opposite things.** See
  `Design/specs/soundcloud-home-endpoints.md` for the route table and the
  repro recipe.
- **macOS shell** — transparent unified titlebar (`MacWindowChrome`), `.sidebar`
  material, floating transport capsule mounted as an `.overlay` (never a
  `ZStack` sibling — a sibling drives stack height), `MacSyncCoordinator`
  wiring CloudKit session + cue + analysis + download-manifest sync.
- **Decks** — renamed from "DJ Console"; the existing Serato-style key map is
  now exposed through a generated cheat sheet and a real menu; **the horizontal
  `ScrollView` was replaced with proportional scale-to-fit** per the
  never-scroll rule.
- **#25 peer content serving** and **#95 MixEngine failure paths** — both closed
  and independently verified.

## Not started — free to pick up

### #26 — Per-device OAuth via authorization-code relay
**Blocked, needs a human.** Requires a `client_id` with a custom-scheme
`redirect_uri`, which we do not have. Consequence: **the Mac and TV can never
sign in on their own** and must receive a session from the phone. Needs a
five-minute manual check by the owner with an Artist Pro account. Related to
#105 and #117 — the phone's cookie-scraping login is the reason refresh tokens
go missing, and a real PKCE grant would fix that class of bug at the root.

### #99 — Local DJ mode on the phone
`DJControlView` on iOS is a **remote** for the Apple TV's decks
(`client.jog(deck:bySeconds:)` over Bonjour); it performs no local audio.

Sizing is better than it looks: **`MixEngine` is already compiled into the iOS
app** (both it and `PlayerService` live in `swiftpm/Sources/`, and
`PlayerService` already drives `MixEngine.shared`), and **macOS already does
local mixing with the same engine**. The engine is not the work.

What is: an entry point, the dead Auto-Mix toggle (#103), and —
**a real safety gap** — there is **no AirPlay guard on `MixEngine.start()` /
`armMixSession()`**. `AVPlayer` and `AVAudioEngine` must never render
simultaneously, and the reference setup is a Sonos Arc over AirPlay 2 under the
`.longFormAudio` route-sharing policy. **That guard must land before any local
DJ mode ships.**

Deliver a sized plan, not a half-built feature — the owner decides whether it
ships.

### #117 — Phone surfaces a waiting TV/Mac pairing offer
The TV shows a QR and advertises `_soundingtv._tcp`; the phone only engages if
the user scans it or taps the Handoff banner. The owner wants the push
direction: while a TV or Mac sits on its sign-in screen, the phone shows an
Apple TV glyph in the tab bar and a prompt naming the device.

**The security point that needs a deliberate decision — do not silently drop
it.** The QR carries the shared secret, and scanning it proves the user is
*physically present at the TV*. That is what stops anyone else on the same
Wi-Fi (flatmate, hotel, venue, café) from advertising an offer and harvesting a
session. The Bonjour TXT record is **unauthenticated** — a device calling itself
"Living Room" is a claim, not proof.

Use the standard mitigation instead of removing the QR: **numeric comparison**,
as AirPlay/Bluetooth/passkeys do. Show a 4–6 digit code on the TV/Mac *and* in
the phone's prompt; the user confirms they match. Keeps the one-tap feel,
preserves the binding, and fails honestly. Keep the QR as fallback.

Device name/type/model go in the TXT record and the prompt ("Living Room (Apple
TV 4K) wants to sign in") — presented as *claimed* identity.

Also decide the Mac half: (a) the Mac runs its own `BonjourAuthServer` and shows
the same pairing screen — better UX, reuses proven code; or (b) it leans on the
CloudKit session sync that now runs every 5 minutes and the phone merely
approves.

**Constraints:** do not weaken HMAC verification or the 300s pairing timeout —
discovery is convenience, never authorisation. The badge must appear only while
an offer is live. **An `NWConnection` that cannot reach its peer never fails** —
measured: `.preparing` for 75s, then `.waiting`, still no terminal state at
100s — so every connect needs its own bounded no-progress timeout (#91 was
exactly this bug). Browse while foregrounded only.

---

## Useful measured facts

Do not re-derive these; they cost real spike work.

- **`MusicUnderstandingSession(asset:)` accepts local `file://` assets only.**
- **`AVPlayerItemSampleBufferOutput` delivers *zero* sample buffers on the
  physical Apple TV** (every configuration, ~3000 nil pulls, while the item was
  demonstrably playing). It works on macOS. So the Mac is the ecosystem's
  analysis producer; library-wide stream analysis on tvOS does not work.
- **`RhythmResult.bars` is a real downbeat tracker** (whole framework is 27.0+).
  CLAUDE.md previously claimed none existed. `rhythm` alone ≈ 130 MB / 9.8 s on
  a 251 s track; `structure` and `pace` are the expensive ones (~620 MB). All
  six types together is **2.43× faster than summing individually** — request
  them in one pass.
- **`InstrumentActivityResult`** gives `.vocal`/`.drum`/`.bass`/`.other` time
  ranges — usable to avoid mixing over a vocal.
- **Liquid Glass is macOS/iOS/tvOS **26**.0, not 27.** Nothing glass is new in
  27 except AppKit's `NSGlassEffectView.effectIsInteractive`.
- **macOS 27 has 38 entirely new frameworks** (332 vs 294 in 26), including
  `MusicUnderstanding`, `NowPlaying`, `MediaIntents`, `VisualIntelligence`.
- **CoreMIDI has zero macOS-27 additions** — no hot-plug or LED-feedback help
  for DDJ controllers. **CoreAudio has nothing for multi-output**, so
  headphone-cue-vs-master is an architecture problem, not a missing API.
- **SoundCloud's waveform JSON** is `{"width":1800,"height":140,"samples":[…]}`,
  each sample `0...height`, and `Waveform.init` scales by the **declared
  height** ("so a quiet track still reads as quiet") — meaning samples are
  comparable *across* tracks. It is an amplitude envelope, **not** spectral
  data, so Serato-style frequency-band colouring cannot be faked from it.
- **The token goes in the `Authorization: OAuth <token>` header.** The
  `?oauth_token=` query param is v1 and api-v2 ignores it — sending only the
  query param made every request anonymous and produced an endless
  session-expired loop.
- **`isTokenValid(_:)` fails open** — only an explicit 401 counts as invalid. A
  timeout or offline device must never read as signed out. Preserve this.
