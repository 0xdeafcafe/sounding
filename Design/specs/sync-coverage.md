# Sync coverage — "do we sync everything?"

Audit written 2026-08-04 ~03:00 CEST, against the working tree as found (see
"A note on timing" at the bottom — other agents were actively editing files
elsewhere in the tree while this was written; nothing below touches the
in-flight macOS area, #108/#113/#115).

> **Update 2026-08-04, later the same day — gaps 1 and 2 are closed.** Cue
> points and settings now both sync continuously rather than once per launch.
> The affected rows and ranked gaps below carry inline `**Closed**` notes
> saying what closed them. Everything not so marked still stands as written.

**Standard of evidence used throughout:** every claim below is backed by (a)
a call site outside the defining file, and (b) a route a user can actually
reach — or, where that second thing could not be established, the cell says
`UNVERIFIED` and why. A type existing, a record shape being self-tested, or
a green build is not treated as evidence of reachability anywhere in this
document.

## Headline answer

**No.** Of the eleven kinds of state below, real CloudKit sync exists for
exactly five: session/auth, cue points, analysis rows, the download manifest,
and — since `19bff43` — settings, including the DJ Auto-Mix toggle the owner
named specifically. As originally audited, all of these ran once per app
launch on tvOS and iOS with no way to force a refresh short of relaunching;
that is no longer true (see gap 1). Cue points additionally have a live
Companion path and are the only state that converges without waiting on
CloudKit. Liked tracks and playlists "sync" only in the sense that they live
on SoundCloud's own servers, not because this app moves them. Play queue and
now-playing position have no durable cross-device form at all.
Recently-played does not exist as a synced (or even cross-screen) concept
anywhere.

## The sync table

| State | Mechanism | Direction | Platforms | Status | Evidence |
|---|---|---|---|---|---|
| **Session / auth** (OAuth token, refresh token, client id) | `CKSyncEngine`, private DB, dedicated `Session` zone, one fixed record, secret fields via `CKRecord.encryptedValues` | Bidirectional, pull-then-push, last-writer-wins on `updatedAtMillis`→`writerId` | tvOS, iOS, macOS all wired | **Synced**, cadence-limited | `SessionSyncTarget.source` set in `SoundingTVApp.swift:16`, `SoundingTViOSApp.swift:81`, `MacSyncCoordinator.swift:147`/`SoundingMacApp.swift:100`. Encryption proven structurally by `CloudSyncSelfTest.testSessionFieldsAreEncryptedNotPlain` (`CloudSyncEngine.swift:1044-1069`). |
| **Liked tracks** | None at the app level — each device calls `api-v2.soundcloud.com` directly while signed into the same account; `LibraryCache` (SQLite) is a local, revalidating paint-cache only, never a sync source of truth | N/A (server-authoritative) | tvOS, iOS, macOS (LibraryCache.swift: 4 target build-phase entries) | **Synced via SoundCloud**, gated by Row 1 | `LibraryCache.swift:1-70` header: "Not a general offline library... caches whatever the phone has already fetched... over the network... so the next visit... can paint instantly." Sign-out clears it (`LibraryBrowserViewModel.handleSignOut()` → `clearAll()`). |
| **Playlists** (own + subscribed) | Same as liked tracks — server-authoritative, `LibraryCache` paints instantly, revalidates in background | N/A | tvOS, iOS, macOS | **Synced via SoundCloud**, gated by Row 1 | Same mechanism as above. Note: **playlist creation/editing does not exist anywhere in this app** — `SoundCloudAPI.swift` has no create/update-playlist endpoint (checked directly); every platform is read/browse/play-only. Not an asymmetry — uniformly absent. |
| **Play queue** | Bonjour live control channel: TV runs `RemoteQueueServer`, phone runs `RemoteQueueClient`; `.queueState` (TV→phone), `.queueReorder`/`.queueRemove`/`.queueJump`/`.queueAdd`/`.queueReplace` (phone→TV) | TV-authoritative; phone sends commands, TV applies and rebroadcasts | tvOS (server) + iOS (client) only | **Partial** — live-only, not durable | `RemoteQueueServer.swift:381-394` switch handles the five command cases; `RemoteQueueClient.swift:438-497` handles `.queueState`. **macOS excluded**: `SoundingMacApp.swift:17-20` — "`RemoteOutputTarget` — deliberately left nil for now... needs a `RemoteQueueClient` with macOS target membership." Confirmed via `project.pbxproj`: both files have exactly one target's Sources build-phase entry each. Never touches CloudKit — no queue record type exists (see `CloudSyncRecordType`, `CloudSyncEngine.swift:147-153`). |
| **Now-playing position** (resume state) | `PlaybackStateStore` — `UserDefaults`, key `red.forbes.sounding.playbackState.v1`, per device | None cross-device; each device restores only its own last-saved snapshot on its own relaunch | tvOS, iOS, macOS independently (file compiles into 6 target build phases) | **Not synced** | `PlaybackStateStore.swift` full file: plain `UserDefaults.standard`, no transport, no `CKRecord` type. Absent from `CloudSyncRecordType` (`CloudSyncEngine.swift:147-153`) and from `CloudSyncCoordinator.runOnce`'s parameter list (`CloudSyncEngine.swift:835-850`) — there is no fifth relay for it. The only cross-device visibility of "where playback is" is the ephemeral Bonjour mirror in Row 4, which evaporates on disconnect. |
| **Cue points** (hot cues, memory cues, loops, dismissals) | `CKSyncEngine`, `Cues` zone, `Cue`/`CueDismissal` record types; tombstone via an `isDeleted` field that keeps existing (never a CloudKit-level delete), so an offline device still learns about a removal | Bidirectional, full-set push (no export budget — cues aren't large enough to need one), last-writer-wins | tvOS, iOS, macOS all wired, and the round-trip is genuinely UI-visible | **Synced** — continuously, plus a live Companion path (gap 1 closed) | Cadence, added 2026-08-04: `CueSyncTarget.localChangeCommitted()` fires from every local `CueStore` mutation and coalesces both a CloudKit relay and a Companion push; also on the 30-second loop and on foreground. Live path: signed `cue_sync` message over the existing TLS-PSK link, chunked at `CueSyncChunking.maxBatchSize`, with a per-connection high-water mark so a freshly-connected peer gets a full catch-up (`CompanionServer.runCuePush`, `CompanionClient.runCuePush`). `CueStore` conforms directly to `CueSyncStore` (`CueSync.swift:89`) — an imported cue lands in the exact actor `CueSheetView` (tvOS) and `CuePickerView` (iOS) already read from, not a side store. `CueStore.shared` passed identically in `SoundingTVApp.swift:53`, `SoundingTViOSApp.swift:253`, `MacSyncCoordinator.swift:172`. `CuePickerView.swift:1-26` documents the exact mechanism a phone-placed cue uses to reach the TV. |
| **Analysis results** (BPM / key / structure / rhythm / instrument activity) | `CKSyncEngine`, `Analysis` zone, `AnalysisRow` record type; content-addressed key (track + engine + version + schema + audio fingerprint) makes most "conflicts" identical rows by construction; `bpm`/`keyWheelPosition`/`keyMode`/`genre` are broken out as queryable fields, everything else (structure/rhythm/instrument-activity) rides inside the opaque `payload` blob | Bidirectional | tvOS, iOS, macOS all wired, same real round-trip as cues | **Synced**, cadence-limited (see Row 1) | `AnalysisCache` conforms directly to `AnalysisSyncStore` (`AnalysisCache.swift:1160`). `AnalysisCache.shared` passed identically in all three app inits (same three call sites as Row 6). Record mapping: `CloudSyncEngine.swift:258-312`. **Production is skewed toward Mac/iOS in practice** — per CLAUDE.md's already-measured facts (not re-derived here): `AVPlayerItemSampleBufferOutput` delivers zero sample buffers on a physical Apple TV, and `MusicUnderstandingSession(asset:)` needs a local `file://` asset — so tvOS fully *consumes* synced rows but is a weak *producer*. |
| **Downloaded audio files** (the bytes) | None, deliberately — each device downloads its own copy from `api-v2.soundcloud.com` under its own token | N/A | iOS + macOS can initiate; tvOS carries the engine but no initiation UI | **Not synced**, by design | `DownloadManifestSync.swift:16-28` header states this outright: "the manifest, not the bytes... never a local file URL, and never a stream URL." Initiation call sites: `downloadManager.download(track)` in `LibraryBrowserView.swift:1356/1375/1385`, `FeedView.swift:454/473/483` (iOS); `MacPlaylistDetailView.swift:451` (macOS). tvOS's `SettingsView.swift:114,268,457` only *observes* `DownloadManager.shared` for a storage-used/cap display — no `.download(` call site exists anywhere under `SoundingTV.swiftpm/Sources/Views`. |
| **Download manifest** (which device has which track downloaded/pinned) | `CKSyncEngine`, `DownloadManifests` zone, `DownloadManifestEntry` record type, scoped per-`deviceId` (no real multi-writer conflict is structurally possible) | Export is real on all three platforms; import lands in `RemoteDownloadManifestStore` and is never read back out | tvOS, iOS, macOS all export | **Partial — sync works, has zero consumers** | Export: `LocalDownloadManifestSource` passed into `CloudSyncCoordinator.runOnce` identically on all three platforms (same three call sites as Rows 1/6/7). Import: `RemoteDownloadManifestStore.manifestsByDevice(excluding:)` (`DownloadManifestSync.swift:221`) is called **only** from that file's own self-tests (`DownloadManifestSync.swift:398,415,432`) — grepped for every call site in the repo, zero UI hits. The file's own header admits this: "a read-only-from-the-outside cache meant for a future 'downloaded on your other devices' affordance" (`DownloadManifestSync.swift:16-19`). Also has **no tombstone yet** — a track un-downloaded locally simply stops appearing in the next export; a peer that already pulled the row has no way to learn it was removed (`DownloadManifestSync.swift`, "Known limitation: no tombstones (yet)" section). |
| **Settings** (streaming/download quality ceiling, DJ Auto-Mix, DJ transition length, ambient screensaver timeout, etc.) | `SettingsStore` has per-key `SettingRevision` bookkeeping and `SettingsMerge` (revision → wall-clock → `writerId` tiebreak), `exportSyncPayload()`/`merge(_:)`, all self-tested by `SettingsSelfTest`. Since `19bff43` these ride a CloudKit relay: `SettingsSyncRecord`, `CloudKitSettingsSyncTransport`, driven by `CloudSyncCoordinator.requestSettingsSync()` | Bidirectional over CloudKit, on the shared 30-second cadence | tvOS, iOS, macOS | **Synced** as of `19bff43` (gap 2 closed) | Resolved over CloudKit, not over the Companion link. The `.settingsSync` `TokenTransferMessage` case this audit pointed at was never adopted by either side and was deleted 2026-08-04, together with the `settings: Data?` field and the `settingsSync(sessionId:settings:)` factory — a live settings push over the Companion link does not exist, and settings converge only at CloudKit cadence. **`SettingKeys.DJAutoMixEnabled`** — the setting named in the task brief — is declared `defaultScope: .synced` and documented as meant to "travel with the pairing" (`SettingsStore.swift:315-324`), but structurally cannot, today. (`SettingsSelfTest.run()` is reachable — from a DEBUG button in `SettingsView.swift:786` and `PhoneSettingsView.swift:1477` — but is not part of the automated `SOUNDING_TV_MIXTEST` battery the way every other self-test in this table is; a smaller, secondary finding.) |
| **Recently played** | No SoundCloud endpoint exists (`/me/play-history` — given fact, restated from `Design/specs/BACKLOG.md:159` and not rediscovered here). The closest analogue, tvOS's Top Shelf "recents" shelf, is populated locally by `TopShelfPublisher.notePlayed(track)` into a JSON file in the shared App Group container | N/A / local-only where it exists at all | tvOS only (as a Top Shelf convenience); no equivalent screen anywhere | **Not synced** (and barely exists) | Real call site: `RootView.swift:44` (`TopShelfPublisher.notePlayed(track)` on every track change). Storage is `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` (`TopShelfSnapshot.swift:256-257`) — App Group, not CloudKit, so it never leaves the physical Apple TV. No "recently played" list is browsable in-app on any platform. |

## Known facts restated (not rediscovered this pass)

- ⚠️ **CORRECTED — this section previously asserted "there is no `/me/play-history` endpoint", citing `Design/specs/BACKLOG.md` as an already-established fact. It was never probed, and it is false.** `me/play-history/tracks` returns **401, not 404**, with a client_id alone, and is present in SoundCloud's own route table; `me/play-history/contexts`, plus POST (add) and DELETE (clear), exist too. The response shape is still unverified — that needs a real token. See `Design/specs/soundcloud-home-endpoints.md`.

  Two things to carry forward from how this went wrong. **A 404 and a 401 mean opposite things** — the second is an endpoint confirming it exists and refusing you. And the claim spread because it was restated from another spec rather than tested; "restated from `BACKLOG.md:159` and not rediscovered here" was written into this file as though citation were evidence. Cite a probe, not a document.
- **macOS cannot currently be signed in by the phone.** Confirmed while reading for this audit: `BonjourAuthServer.swift:5` is `import UIKit`, which does not exist on macOS — the QR/cookie-capture pairing host cannot be ported without a rewrite. `MacSyncCoordinator.swift:50-59` states the practical consequence directly: "a Mac that is the very first device signed in has nothing to pull," and `MacSignInView.swift` "was left unwritten." A Mac only ever *receives* a session that a phone or TV produced by going through the real sign-in flow and synced out via CloudKit (Row 1).

## What this document could not verify

One thing under-pins the "Synced" verdict on four rows (session, cues,
analysis, download manifest) that this pass did not — and could not —
independently confirm: **whether `CKSyncEngine` actually converges two real
devices.** `CloudSyncEngine.swift`'s own header says this plainly (lines
90-97): record mapping and the encrypted-vs-plain guard are exercised for
real, offline, by `CloudSyncSelfTest`, but "`CKSyncEngine` itself — actually
reaching iCloud, actually converging two devices — is **not** exercised by
anything in this repository: that needs a signed-in iCloud account on a real
device, which this environment does not have." This audit did not have that
either, so those four rows' "Synced" verdicts rest on: the record mapping
being correct (self-tested and real), the relay logic being correct
(self-tested and real), and the call sites that invoke `start()`/`runOnce()`
being real and reachable (traced directly, cited above) — not on having
watched a cue placed on one device actually appear on another. Treat the
mechanism as *wired*, not as *empirically proven to converge*.

No table cell above is marked `UNVERIFIED` outright — every row had enough
direct call-site evidence to support a definite status — but this
end-to-end-convergence caveat applies to every row whose mechanism is
`CKSyncEngine`, and should be read as attached to all four.

## Ranked gaps (worst first — input to #132)

1. ~~**tvOS and iOS only sync once, at their own launch — no debounce-after-mutation, no periodic timer, no manual trigger.**~~ **Closed 2026-08-04.** All three platforms now coalesce a cue relay on every local mutation (`CueSyncTarget` in `CueSync.swift`, fired from `CueStore.upsert`/`delete`/`dismiss`/`undismiss` — deliberately *not* from `adopt`, which is what stops two devices echoing cues at each other), run it on the shared 30-second cadence, and nudge it on foreground. Cues additionally propagate live over the paired TLS-PSK Companion link via a signed `cue_sync` message, so a same-network phone→TV hop no longer waits on a CloudKit round trip at all. Settings were separately put on a CloudKit relay in `19bff43`. The original finding, for the record: `SoundingTVApp.swift:50-60` and `SoundingTViOSApp.swift:246-260` each run exactly one `.task` at launch. Compare macOS, which got both a 5-minute periodic loop (`SoundingMacApp.swift:106`, `MacSyncCoordinator.swift:203-212`) and a manual "Sync Now" button (`MacAccountView.swift:211`) — and whose own header explains *why*: "a Mac plausibly stays open for hours... a launch-only round would mean a Mac left open before that phone sign-in never sees it until the next relaunch" (`MacSyncCoordinator.swift:184-195`). The identical argument applies to a TV, which plausibly runs even longer than a Mac, and got none of the fix. A cue set on the phone mid-session may not reach an already-running TV for hours or days. This is the single biggest reason "the apps are aware of each other" fails today — everything else in this list is a *what* doesn't sync; this is *why even what does sync often hasn't yet*.
2. ~~**Settings — including DJ Auto-Mix — never sync anywhere, despite a complete, self-tested transport sitting unused.**~~ **Closed in `19bff43`.** Settings now ride a CloudKit relay (`SettingsSyncRecord`, `CloudKitSettingsSyncTransport`, `CloudSyncCoordinator.requestSettingsSync()`) on the shared 30-second cadence. Note the resolution went the *other* way from what this row predicted: the Companion `settings_sync` wire message the audit pointed at was never adopted, so it was deleted 2026-08-04 along with its `settings: Data?` field and factory. Settings sync is CloudKit-only — there is no live Companion path for it, unlike cues.
3. **macOS has no live-control channel to or from the TV or phone at all.** It is aware of a peer only every 5 minutes, only via CloudKit, and only for cues/analysis/session/download-manifest — never queue, now-playing, or DJ state. A Mac cannot see "the TV is playing X" the way the phone can.
4. **A fresh Mac and a fresh TV can mutually deadlock on sign-in.** Neither can originate a session on its own (Mac has no sign-in UI at all; the TV's own QR/Bonjour host is the only originating path and needs a phone to complete it) — see "Known facts restated" above. A household that sets up a Mac and a TV before ever using the phone app gets stuck.
5. **No durable "pick up where I left off" across devices.** Play queue and playback position have no CloudKit form at all — only the ephemeral, connection-scoped Bonjour mirror between tvOS and iOS. Pausing on the TV and resuming from the same point on the phone (or vice versa, or involving the Mac at all) is not supported by anything in the sync layer.
6. **Download-manifest sync moves real, correct data with zero UI consumer.** "Downloaded on your other device" is fully wired end-to-end except the one screen that would show it — the cheapest of these gaps to close, since the hard part (the sync itself) is already done and self-tested.

## A note on timing

Several agents were editing Swift files elsewhere in this tree while this
audit was written (per the task brief) — directly observed: a new,
un-registered file (`SoundingTV-iOS/Sources/GlobalSearchView.swift`)
appeared mid-session at 03:06 CEST, and several iOS files this document
cites (`LibraryBrowserView.swift`, `FeedView.swift`, `TransportBarView.swift`,
`PhoneCredentialSource.swift`) differ from the last commit. Every citation
above was re-checked against the live file content as of ~03:10 CEST, not
just read once early and trusted — line numbers were re-grepped after the
concurrent edits were noticed. None of the sync mechanism itself
(`CloudSyncEngine.swift`, `SessionSync.swift`, `CueSync.swift`,
`AnalysisSync.swift`, `DownloadManifestSync.swift`, `MacSyncCoordinator.swift`)
showed signs of concurrent editing during this pass. If a later reader finds
a cited line number has shifted further, re-grep the symbol name rather than
assume the underlying finding is stale — nothing in this document depends on
other agents' work landing or not landing.
