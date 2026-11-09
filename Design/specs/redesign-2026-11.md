# Redesign: Companion, Intelligence, Downloads & Storage (November 2026)

Written 2026-11-05 from three read-only audits of the code as of `49da060`. Supersedes the conflicting parts of `ios-design-spec.md`, `feature-matrix.md` and `ui-acceptance-2026-08-04.md` for these three areas.

Principle for all three: features live where the user already is (Now Playing, track rows, the output picker, Settings), not in dedicated dashboards. Every screen follows native Apple idioms: grouped Forms, system controls, terse copy, no implementation prose.

## 1. Companion becomes Output

### What the user needs
Sitting with an iPhone (or Mac) while music plays on the Apple TV: see what's playing there, control it, add music to it from the phone's library or search, and move playback between devices. DJ control of the TV's decks when DJ mode is on.

### Design
- **Output picker, like AirPlay.** One route button in the mini player, Now Playing and the Mac transport bar. It lists This iPhone, Living Room (Apple TV) and This Mac. Choosing a device moves the current session there (track, queue, position). This replaces "Continue Listening…", the Companion screen's move picker and the separate "Play on Apple TV" row action.
- **Whatever is playing, wherever, is what the phone controls.** When the output is the TV, the mini player, Now Playing, Up Next and every row action (Play, Play Next, Add to Queue) operate the TV. There are no separate TV-only screens and no QueueManagerView. Up Next in Now Playing *is* the TV queue, with reorder and remove.
- **DJ remote** opens from a Decks button in Now Playing when the output's DJ engine is live. DJControlView is reused, but reached from there.
- **Pairing is Link, in Settings → Devices.** It's Apple-style: a device list with each device's status, "Add Apple TV…", and a pairing sheet with one instruction, the code or QR, and one action. The phone keeps a single pairing implementation (today it's duplicated in PhoneRootView and CompanionRootView). The tvOS sidebar "Companion" tab becomes Settings → Remotes & Devices.
- **Removed:** CompanionRootView as a destination, the Home AppleTVBanner (the output picker and a "Playing on Living Room" mini player subtitle replace it), QueueManagerView, "Independent Playback" copy, and the dead Mac↔iPhone "Share with iPhone" path (`startForSharedSession`, `SharedSessionCompanionLink`).

### Under the hood
- CompanionServer accepts multiple concurrent clients (phone, Mac, Share extension) instead of evicting the previous one.
- Playback telemetry sends an anchor (position, timestamp, rate, isPlaying) only on change. Clients interpolate, so there are no per-tick messages and no 2s forced payloads. `persistSnapshot` is throttled.
- Stale-state rule: when not connected, the TV's playback shows as unknown, never as a stale "playing".
- Vocabulary: internal `adoptHandoff` / `showsHandoffActions` get renamed to output terms. "Handoff" stays NSUserActivity only.
- The Share extension reuses CompanionClient's protocol code rather than a third client.

## 2. Intelligence becomes ambient

### What the user needs
BPM, key and genre on their tracks (DJ prep, sorting, auto-mix), and in long DJ mixes, "what track is this?" plus a tracklist. Nobody needs engine provenance, schema versions, cache sliders or three policy layers.

### Design
- **No Intelligence tab and no dashboard.** iPhone tabs are Home, Library, Search and Settings.
- **Where it appears:**
  - BPM, key and genre badges in track rows, plus sorting by them (already exists);
  - Now Playing's **Tracklist** pane for mixes, with each entry time-tracked, the current entry highlighted, and an **Identify** button that runs a Shazam probe at the current moment;
  - Now Playing's **About** pane, which absorbs "Behind the Track", stays plain metadata, and isn't called intelligence;
  - Library → **Setlists** for saved tracklists;
  - the Mac library table's BPM, key and genre columns with inline correction, which are the Mac's power surface instead of a separate dashboard.
- **One setting:** Settings → Music Analysis → "Analyse Music on This Device" (on by default, battery-aware), and "Clear Analysis Data" in the same section. It ignores per-collection levels and the liked/playlists rules.

### Under the hood
- Analyse anything played or downloaded. Phase 1: downloaded files plus the current local file. Phase 2: analyse streamed tracks via `MusicUnderstandingSession(audioProvider:)` fed from the playback tap, which removes "download first" (see `os27-api-survey.md`).
- **Fix:** Mac "Analyse" must pass the local file. Without it, BPM and key never resolve.
- **Fix:** DJ-deck analysis goes through `AutomaticAnalysisScheduler` and nothing else.
- **One summariser:** `AnalysisSummaryStore`, used by iOS, macOS and tvOS. The iOS and Mac copies are deleted. Summarising moves off the main actor.
- **Removed:** `CollectionIntelligenceLevel`, `automaticAnalysisPolicy` rules, the dead `fftAudioAnalyzer` concept, and the stale Mac "honesty" popover.
- `SetlistIntelligenceStore` persistence moves off the main actor. iPhone may scan a mix the user explicitly asks about (Identify or a tracklist request).

## 3. Downloads & Storage: one simple model

### What the user needs
"Downloaded" means it's on this device and plays offline, and nothing appears or disappears by surprise. Storage that's honest and easy to reclaim.

### Design (the Apple Music model)
- **A track, playlist or Likes is either Downloaded or not.** Downloading a playlist or Likes keeps it in sync: new additions download, and removed tracks are deleted. **Remove Download** on the collection turns that off and deletes its files.
- **Download state is per device and is not synced.** Downloading on the Mac never starts downloads on the phone. This is the cause of the surprise 50 Likes.
- Removing one track that belongs to a downloaded collection excludes it from that collection's sync, so it stays removed.
- Large downloads (over 1 GB, or any download on cellular) show the size first.
- **Settings → Downloads**, as a grouped Form:
  - a storage gauge, "X GB used by downloads";
  - **Downloaded Music**, a list grouped by Playlists, Likes and Songs, with swipe to remove;
  - toggles: Download over Cellular, Optimise Storage (Apple Music semantics: when the device is low on space, remove downloads not played recently, keeping at least the chosen minimum);
  - Download Quality, which applies to new downloads only, plus an explicit "Re-download at New Quality (≈ X GB)" action;
  - **Cache**, one row with the total size of artwork, analysis, the DJ cache and the URL cache, and a Clear Cache button;
  - "Remove All Downloads" as a destructive action with a confirmation.
- **Removed:** Smart Downloads, predictive/"ahead of you" downloads (dead code), the 30-day TTL, the pin/sparkle distinction, the "Copy N from Other Devices" mass copy (peer *streaming* of a file another device has stays as an internal fast path), and the per-collection quality override UI.

### Under the hood
- One entry model: a download is `explicit(trackID)` or `collection(collectionID)`, with an exclusion set. The cap no longer evicts user downloads; Optimise Storage is the only automatic removal, and the UI says so.
- **No plaintext copies.** Play encrypted files through an `AVAssetResourceLoader` that decrypts chunks on demand. The chunk layout is fixed-size, so seeking can compute offsets directly. This removes the unbounded decrypted cache, which today doubles real disk use. Analysis decrypts to a temp file and deletes it afterwards.
- `usedBytes` is true on-disk usage.
- Quality migration never runs implicitly.
- Collection download settings live in a device-local store; the synced `CollectionPolicies.automaticDownloads` is retired. Existing synced flags are migrated: keep them on the device that has files for that collection, drop them elsewhere.
- tvOS keeps downloads with the same model, and Optimise Storage is always on there, because Apple TV storage is purgeable.
