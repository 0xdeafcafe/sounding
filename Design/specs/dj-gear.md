# DJ gear: prep, rekordbox and DJ Players

How Sounding prepares tracks for DJing, shares that prep with rekordbox, and later works next to Pioneer hardware. The Mac is the prep surface; iPhone and iPad view and edit cues; Apple TV and Watch show them.

Sources: the owner's decisions (2026-11-06, logged in the bible §13) and four design proposals (Astra, Sol, Opus, Sonnet). Where they disagreed this spec takes the simplest approach that is still correct. Bible vocabulary applies: **Music Analysis**, **Cue Points**, **Decks**, **Auto Mix**, **Setlists**. Pioneer hardware is **DJ Players**; "Pro DJ Link" appears only in small print, with "not affiliated with AlphaTheta".

---

## 1. The rights line

- The default build never writes SoundCloud audio anywhere: not to USB, not to a folder, not over the network to a player. It sends **analysis and cues**, attached to the **user's own local files**.
- Matching a SoundCloud track to a local file uses metadata (ISRC, title, artist, duration). Never an audio fingerprint of a SoundCloud stream.
- A SoundCloud-only track keeps its cues inside Sounding (synced to all devices) and is listed as "SoundCloud only" wherever an export would skip it. The UI states the fact; it doesn't explain the licence.
- **Personal build (phase 4).** Sending SoundCloud audio to USB or DJ Players exists only in a separate `Personal` build configuration with the `SOUNDING_PERSONAL` Swift flag, signed for the owner's devices, behind a hidden code. TestFlight and App Store binaries never contain that code path: it is compiled out, not hidden.

---

## 2. What already exists (code map)

| Concern | Where |
|---|---|
| Cue model: mix in/out, hot cues A–H, memory cues, loops, colour, label, tombstones | `Core/DJ/CuePoints.swift` |
| Cue storage (SQLite) and per-cue last-write-wins sync | `Core/DJ/CueStore.swift`, `Core/DJ/CueSync.swift`, `Core/Sync/CloudSyncMapping.swift` (`Cues` zone) |
| Structural suggestions, dismissals, resolution | `Core/DJ/CueSuggester.swift`, `CueDismissal`, `CueResolution` |
| Beat grid, sections, key, energy | `BeatGrid`, `TrackSection`, `CamelotKey` in `Core/DJ/DJTypes.swift` |
| Auto Mix entry/exit candidates | `DJPointFinder` in `Core/DJ/DJTemplates.swift`, fed by `DJSessionDirector.features(for:)` |
| Cue UI | iOS `TrackMapSheet`, tvOS `TrackMapView` / `NPCuesPane`, `CueBoard` |

---

## 3. Data model

### 3.1 TrackLink: a SoundCloud track and its local file
One record per SoundCloud track id.

| Field | Synced | Notes |
|---|---|---|
| `trackId` | yes | SoundCloud track id (`soundcloud:tracks:<id>` is `Track.urn`). |
| `title`, `artist`, `durationMillis` | yes | For listing without a network call. |
| `isrc` | yes | From the file's tags or SoundCloud's publisher metadata. |
| `fileHash` | yes | SHA-256 of size + first and last MiB. Identifies the same file on another Mac. |
| `rekordboxTrackId` | yes | `TRACK@TrackID` from the last XML import. |
| bookmark, path | **no** | Security-scoped bookmark, per device, in the local `track_link_file` table. Paths never reach iCloud. |

**Matching** (`TrackMatcher`), per rekordbox or local track, against the user's Sounding library (cached Likes and the current queue; no extra SoundCloud requests):
1. ISRC equal (case and dashes ignored) → matched.
2. Normalised title and artist equal and duration within ±2 s → matched. Normalising lowercases, folds diacritics, drops "(Original Mix)", "feat. …", punctuation and extra spaces, and treats "Artist - Title" in the title as artist + title.
3. More than one candidate passes → **ambiguous**: the import preview asks.
4. None → **missing**: not imported; its cues stay in rekordbox.

### 3.2 TrackPrep: everything per track that isn't a cue
One synced record per track, next to the cues (`Cues` zone, record type `PrepRecord`, kind `prep`).

Every field is a `PrepField<Value>` carrying `source` (`user` > `rekordbox` > `sounding`), `updatedAtMillis` and `writerId`.

| Field | Value |
|---|---|
| `grid` | `PrepGrid`: tempo segments (`startMillis`, `bpm`, `beatsPerBar`, `beatInBar` of the segment's first beat), optional explicit `downbeats` (ms), `locked`. |
| `key` | Camelot label plus the original text (e.g. "Am"). |
| `energy` | 1–10. |
| `phrases` | `[startMillis, kind, mood]` (rekordbox kinds map to `SectionKind`). |
| `colour` | rekordbox track colour (RGB). |
| `comment` | Free text. |

### 3.3 Cue points (extended, not replaced)
- `CuePoint.origin` is **stored**: `user`, `imported` or `suggested`. Editing an imported cue makes it `user`.
- **Hot loops:** a `loop` may take a hot slot A–H (`hotCueIndex`). It shares the slot id `<track>#hot#<n>` with hot cues, so a slot holds one thing.
- Ids stay deterministic: slots by slot, imported memory cues and loops by `<track>#<kind>#rekordbox#<startMs>[-<endMs>]`, so a re-import is idempotent.

### 3.4 Listening tallies
Per track, **per device**: bar-snapped counters of intentional seeks and replays. Each device writes only its own row (`PrepRecord` kind `tally`, name `tally:<track>:<device>`); readers sum all rows, so rows never conflict.

A **landing** counts when the user seeks (or replays backwards) and playback then continues for 6 s near that point. Excluded: scrub previews (seeks superseded within 6 s), SharePlay/remote corrections (they call `seek` with `.correction`), Auto Mix transitions (they don't seek), and any time the Decks are live.

Each bucket stores `hits`, `sessions` and the last session id; a session is one continuous play of the track.

---

## 4. Conflict rules

- **Cues:** per-cue last-write-wins on `(updatedAtMillis, writerId)` (unchanged).
- **Prep fields:** per field. A field whose source is `user`, or a grid that is `locked`, is never overwritten by analysis or import. Otherwise the higher source wins, then last-write-wins. A `user` edit from another device follows last-write-wins against a local `user` value (so unlocking propagates).
- **Import never deletes.** A cue missing from an XML isn't a tombstone.
- **Import conflicts:** when an imported value differs from a local `user` value (grid, key, colour, comment, a hot slot), the import asks: **Keep Sounding** / **Use Imported**, per row and for all. Imported values that replace other imported or analysed values apply without asking.
- **Tallies:** never conflict (one writer per row).
- **Live safety:** Auto Mix snapshots prep when it plans; sync never moves a transition already scheduled.

---

## 5. Suggestions learned from listening

- `ListeningSuggester` (`sounding.listening` v1) clusters summed tally buckets within ±1 bar. A cluster with **3 or more hits across 2 or more sessions** becomes a suggested **memory cue** at the cluster's downbeat, labelled "Often replayed".
- Suggestions appear on every device with **Accept** / **Dismiss**. Accept makes a user memory cue (or a hot cue, if the user picks a free slot). Dismissals sync and cover ±1 bar, so a cluster that drifts doesn't come back.
- Suggestions never fill hot-cue slots A–H until accepted.
- There's no setting: counts stay in the user's private iCloud, carry no timestamps, and the feature only proposes.

---

## 6. Auto Mix uses prep (minimal; the Auto Mix overhaul will replace this)

`DJSessionDirector` passes `PrepMixHints` into `TrackFeatures`:

| Prep | Auto Mix |
|---|---|
| Mix In / Mix Out | Preferred entry / exit (unchanged). |
| Memory cue on a phrase boundary (within ½ beat) | Exit candidate, confidence 0.9. |
| Hot cue labelled Drop or Break (any case) | Entry candidate, confidence 0.9. |
| Loop in the last third of the track | Permitted extension: Loop roll-down may use it even for profiles that don't cut tracks short, exiting at the loop start. |
| Locked or user grid | Replaces the measured grid; confidence 0.95, provenance includes measured beat grid and downbeats. |
| Suggested cue (not accepted) | Same roles at half confidence. |

---

## 7. rekordbox XML

Documented format: `DJ_PLAYLISTS` (version 1.0.0) with `PRODUCT`, `COLLECTION/TRACK`, `TEMPO`, `POSITION_MARK`, `PLAYLISTS/NODE`.

| rekordbox | Sounding |
|---|---|
| `TRACK@TrackID`, `Name`, `Artist`, `TotalTime`, `Location` | `TrackLink`, matching |
| `TEMPO@Inizio` (s), `Bpm`, `Metro` ("4/4"), `Battito` (1–4) | `PrepGrid` segments; `Battito` 1 marks a downbeat |
| `POSITION_MARK Type=0 Num=-1` | memory cue |
| `Type=0 Num=0…7` | hot cue A–H |
| `Type=4 Num=-1` | loop |
| `Type=4 Num=0…7` | hot loop A–H |
| `Type=1` / `Type=2` (fade-in / fade-out) | Mix In / Mix Out |
| `Type=3` (load) | kept in the preview as unsupported; not imported |
| `Red`, `Green`, `Blue`, `Name` | cue colour, label |
| `Tonality` | key (`CamelotKey.parse`) |
| `Colour` ("0xRRGGBB"), `Comments` | prep colour, comment |
| `PLAYLISTS/NODE Type=0` folder, `Type=1` playlist, `KeyType=0` | rekordbox playlists (local, listed in Prep) |

**Export** writes a new file (never the user's own `rekordbox.xml`), only for tracks with a linked local file, with `Location` as `file://localhost/<percent-encoded path>`. Mix In / Mix Out export as memory cues named "Mix In" / "Mix Out" and come back as Mix In / Mix Out on import. The export sheet previews what rekordbox can't hold: phrases, energy, suggested cues, SoundCloud-only tracks.

Round-trip golden tests use fixtures written in rekordbox 6 and 7 dialects (`Tests/SoundingTVTests/Sources/RekordboxFixtures.swift`; the test target has no resources phase). They check: parse → write → parse is lossless and byte-stable, and rekordbox → Sounding → rekordbox keeps every supported mark, tempo, key, colour and comment.

The parser uses `XMLParser` with external entities off, rejects files over 64 MiB, and ignores unknown elements and attributes.

---

## 8. Mac UI

Native idioms only: grouped Forms, system controls, `Table`, `.inspector`, centred `ContentUnavailableView` for empty, loading and error states. No custom cards. Copy is short and has no implementation prose.

### Settings › Library › rekordbox
```
rekordbox
  Library        rekordbox.xml         [Choose…]
  Linked Tracks  42
                 [Import…]   [Export for rekordbox…]
  footer: Sounding never changes your rekordbox library.
```

### Import (sheet)
```
Import from rekordbox
  rekordbox.xml · 1,284 tracks · 41 playlists
  Matched 412 · Choose 3 · Not in Sounding 869
  [Matched | Choose | Not in Sounding]      (segmented Picker)
  Table: Title  Artist  Time  Match          (Choose rows: Picker of candidates)
  Music Folder   ~/Music/DJ          [Allow Access…]
                                      [Cancel] [Import]
```
Then, if anything differs from the user's own prep, **Review Changes**:
```
Review Changes                    [Keep All Sounding] [Use All Imported]
  Table: Track  Item  Sounding  Imported  Keep (Picker: Sounding | Imported)
                                      [Cancel] [Apply]
```

### Prep window (⌥⌘P, Window › Prep; `MacPrepView.swift`)
```
Toolbar: [Source: All Linked | <playlist> ▾]  [Search]        [Inspector]
Table: Title  Artist  BPM  Key  Cues  File                   | Inspector
------------------------------------------------------------ | Grid
waveform overview with beat grid (bars), phrase marks          |  BPM 128.00  Locked [ ]
cue lane: A–H flags, memory cues, loops as ranges              |  [Set Downbeat] [◀ ▶ Nudge]
                                                               |  [½×] [2×]
                                                               | Selected Cue
                                                               |  Name / Colour / Slot
                                                               | Suggestions
                                                               |  1:32 Often replayed [Accept] [Dismiss]
Empty: ContentUnavailableView "No Prepared Tracks" + Import from rekordbox…
```
Shortcuts with the waveform focused: Space plays from the cursor, ←/→ move the cursor a beat, ⌥←/⌥→ nudge the grid 10 ms, 1–8 set hot cue A–H, M adds a memory cue, L adds a 4-bar loop, Delete removes the selected cue. The **Prep** menu: Set Downbeat at Cursor ⌘D, Lock Grid ⌥⌘L (⌘L is Like), Halve Tempo ⌘[, Double Tempo ⌘]. Every grid and cue edit registers with the window's undo manager (⌘Z / ⇧⌘Z).

The grid editor is in the inspector (Beat Grid section): tempo field, source, Lock Grid, Set at Cursor, nudge, ½× / 2×. The editor under the table has an overview lane, a 16-second detail lane with beats and red downbeats, a cue-flag lane, and A–H pads.

### iPhone and iPad
`TrackMapSheet` gains: hot-cue and hot-loop captions ("Hot Loop C · to 2:20", "From rekordbox"), **Accept** and **Dismiss** on every suggestion (plus "Accept as Hot Cue X" in the context menu, using the first free slot), and a Hot Cue submenu, Move to the mark, Rename and Delete on each cue. Grid editing stays on the Mac (and iPad later).

### Entitlements (Mac)
`com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope`. Network and USB work comes with phases 2–3.

---

## 9. Where phase 1 lives

| Piece | File |
|---|---|
| Prep model, policy, grid edits | `Core/DJ/TrackPrep.swift` |
| TrackLink, file hash, matcher | `Core/DJ/TrackLink.swift` |
| Tallies, `ListeningSuggester`, `ListeningRecorder` | `Core/DJ/ListeningTally.swift` (hooked from `PlayerService.seek`; SharePlay passes `.correction`) |
| Storage (same SQLite file as cues) | `Core/DJ/CueStore+Prep.swift` |
| Sync (`PrepRecord` in the `Cues` zone) | `Core/DJ/PrepSync.swift`, run after each cue relay round |
| XML parse/write | `Core/DJ/RekordboxXML.swift` |
| Mapping, import plan/apply, export | `Core/DJ/RekordboxBridge.swift` |
| Auto Mix hints | `Core/DJ/PrepMixHints.swift`, `DJPointFinder`, `LoopRollDownTemplate` |
| Mac | `Features/DJ/MacPrep*.swift`, `MacRekordbox*.swift`; Settings › Library tab |

CloudKit: `PrepRecord` and the new `Cue.origin` field are created automatically in the development environment; deploy the schema to production before release.

## 9a. The personal build (phase 4)

Only the owner's Macs ever run this. Everything lives in `SoundingTV-macOS/Sources/Personal/` inside `#if SOUNDING_PERSONAL`; no other configuration compiles it.

| Piece | Where |
|---|---|
| `Personal` configuration (every target; only the macOS app adds `SOUNDING_PERSONAL`, Apple Development signing and `SOUNDING_PERSONAL_CODE_HASH`) and the "SoundingTV macOS Personal" scheme | `SoundingTV.xcodeproj` |
| Unlock: ⌥-click Version in Settings › Advanced › About opens a code sheet. The source holds only `salt:sha256(salt + code)`; the build setting is copied into the built Info.plist (`SoundingPersonalCodeHash`) by the guard phase. Unlock is stored in UserDefaults against that digest, so a new code relocks. | `PersonalCodeLock.swift`, `PersonalUnlockSheet.swift`, `tools/personal/hash-code.sh` |
| SoundCloud audio for Export to USB: `PersonalAudio.provider` queues tracks one at a time at background priority (8 s ± 25% apart, 60 s doubling backoff, stops after 3 failures, waits out SoundCloud traffic stops and background pauses). Each track goes through `DownloadManager` (same source choice, gateway, budget and coalescing as Downloads), is decrypted, tagged (ID3v2.3 for MP3; iTunes atoms for AAC/M4A; FLAC as is) into `Application Support/Personal/DJ Audio/<track id>.<ext>`, and the download it added is removed again so Downloads doesn't change. | `PersonalAudioProvider.swift`, `PersonalFetchQueue.swift`, `PersonalAudioTagger.swift` |
| Guard: the "Personal Build Guard" run-script phase on the macOS target fails any build with `SOUNDING_PERSONAL` outside the Personal configuration, off macOS, with a distribution identity, with an App Store / TestFlight / ad hoc `SOUNDING_EXPORT_METHOD`, or as an archive without `SOUNDING_EXPORT_METHOD=debugging`. `release.sh` archives with `SOUNDING_EXPORT_METHOD=app-store-connect` and runs `check-no-personal-marker.sh` (`strings`/`nm` for `SoundingPersonalMarker` and `SoundingPersonalCodeHash`) on the archive and on the exported package before any upload. | `tools/personal/personal-build-guard.sh`, `tools/personal/check-no-personal-marker.sh`, `tools/testflight/release.sh` |
| Build and install | `tools/personal/build-personal.sh [--install]` |
| Tests | `PersonalBuildTests.swift` (the test target always compiles with `SOUNDING_PERSONAL`), `tools/personal/tests/run-tests.sh` |

The Export to USB sheet (`MacUSBExportModel.startExport`), behind `#if SOUNDING_PERSONAL` and only when `SoundCloudPersonalAudioProvider.shared.isEnabled` (the hidden code was entered), fetches every chosen track with no file on this Mac through `localAudioFile(forTrackID:metadata:)` before reading audio, keeps the export heartbeat alive while it waits, and names any track it couldn't fetch in the result. Without the flag none of this is compiled: the default model only ever sees `fetchesMissingAudio == false`, and `check-no-personal-marker.sh` passes on the default build.

The same unlock lets hardware DJ controllers drive decks holding SoundCloud tracks (`MacDeckControlSurface.access`, inside `#if SOUNDING_PERSONAL`), for future SoundCloud mixing on CDJs. Every other build limits controllers to the user's own files; see `dj-controllers.md`.

## 10. Phases

| Phase | Scope | Exit gate |
|---|---|---|
| **1 (this change)** | TrackLink + matching; TrackPrep + cue origin + hot loops + sync; grid correction; listening suggestions; Auto Mix hints; rekordbox XML import/export with preview and conflict review; Mac Settings › Library and Prep window; iPhone/iPad cue editing; entitlements | Unit tests (matching, conflicts, XML round-trip, suggestion thresholds, grid edits); four schemes build; screenshots in light and dark |
| **2: USB** | Read rekordbox USB sticks (`PIONEER/rekordbox/export.pdb`, `exportExt.pdb`, ANLZ `.DAT/.EXT/.2EX`: `PQTZ` grid, `PCOB/PCO2` cues, `PSSI` phrases with the XOR mask). Then write sticks for linked local files: staged write, verify, eject. Legacy Device Library first (CDJ-3000, NXS2); OneLibrary only after asking AlphaTheta. Parsers are clean-room Swift from the Deep Symmetry docs; crate-digger/rekordcrate are test oracles only (licences). | Golden exports read back by crate-digger in CI; tested on a real CDJ-3000 and an NXS2 |
| **3: DJ Players** | Observer: UDP 50000/50001/50002 on a chosen wired interface (BSD sockets, `SO_BROADCAST`), players, BPM, on-air, master; record a Setlist from the players; import cues from a player's stick over NFS; Decks follow player tempo. Then the Mac as a **virtual deck** (a free player number) that players beat-sync to; rekordbox must be closed ("Quit rekordbox to see your players"). Local Network prompt primed like the microphone; `network.client/server` already present. No track serving. | Two-player rig plus DJM; permission denial, sleep/wake, port clash |
| **4: Personal build** (built, §9a) | `Personal` build configuration and scheme, `SOUNDING_PERSONAL` flag, owner's signing only. Hidden code unlocks sending SoundCloud audio to USB export (DJ Players track serving stays out of scope). Build-time guard: any App Store or TestFlight build or archive with the flag fails. | `strings`/`nm` check in `release.sh` that release binaries lack the code |

Later, separately scoped: OneLibrary writing, serving tracks to players over the network, master.db (never).
