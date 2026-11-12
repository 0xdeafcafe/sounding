# Sounding feature, polish and review matrix

One file for how every part of every app is getting on. Statuses come from commits, the bible decision log and the code up to 2026-11-09; where nothing shows a review they say "unreviewed".

| Mark | Meaning |
|---|---|
| ✅ | done and polished |
| 🟡 | works, needs polish |
| 🔴 | broken or rough |
| ⬜ | not built, but another platform has it (or the system offers it) |
| — | not applicable |

Dates are the last review of that row. "2026-11-09 code audit" means the cells were checked against the code at the matrix-audit base commit: does the platform contain the feature, not how it looks or whether it works on device. Plain 2026-11-09 means evidence-based triage from commits and owner feedback. The Watch is a remote for the iPhone and, since 2026-11-09, also plays music sent to it on its own (On This Watch); Watch cells describe what the Watch app shows, controls or plays.

**Branches merging right now.** History, Stations, playlist folders, Search rebuild, library linking, Decks rework, TV redesign and full-bleed album pages are all in flight and will change rows. Rows they touch say "in merge" in Notes; cells there show the base commit and may be stale as soon as a branch lands. Every TV row is exposed to the TV redesign.

## Onboarding & sign-in

| Feature | iPhone | iPad | Mac | TV | Watch | Last reviewed | Notes |
|---|---|---|---|---|---|---|---|
| SoundCloud sign-in (Safari PKCE default, web fallback) | 🟡 | 🟡 | 🟡 | — | — | 2026-11-09 code audit | Centred dialog on iPad and Mac; AutoFill depends on the PKCE review/terms risk the owner accepted. TV signs in through the QR plate or a linked device; Watch borrows the iPhone's credentials. |
| Welcome + "Use Without SoundCloud" | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 code audit | SoundCloud-first, shipped this week; e2e walkthrough exists. |
| Music step (own music folders) | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 code audit | Own setup page since 2026-11-09; polish unreviewed on device. |
| Signed-out Library | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | TV has full-bleed hero and shared brand (TV redesign in merge); others unreviewed. |
| Account page / account status | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-07 | One status model (Signed Out, Signed In, Needs Reconnect); unreviewed since. |
| Refresh-token ownership across devices | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | Landed 2026-11-09; needs long-run soak. Library linking in merge. |

## Home

| Feature | iPhone | iPad | Mac | TV | Watch | Last reviewed | Notes |
|---|---|---|---|---|---|---|---|
| Home feed and shelves | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 code audit | Stops reloading after a failed load (fixed); otherwise unreviewed. TV redesign in merge. |
| Home tiles open sets/albums | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | e2e tests exist; no polish pass. Full-bleed album pages in merge. |
| Recently Played across devices | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 code audit | New, written without a build: plays (30 s or 90%) go once to SoundCloud's play history and to a synced account setting; one merged shelf second on Home (Watch too), Apple TV Top Shelf and recap, widget. Needs a first-play check in Network Activity that `POST /me/play-history` returns 2xx, and a two-device check. Mac widget added 2026-11-09, waiting on the Mac app group. History is in merge. |
| Continue from another device | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 code audit | New, written without a build: each device publishes where it is (track, position, queue, source, Auto Mix) on play, pause, track change and every 30 s while playing, through the synced account setting and Link. The offer shows in the mini player when nothing is playing (iPhone and iPad accessory, Mac capsule: artwork, title, "Playing on iPhone · 0:14", prominent play, Not Now in the context menu) and as a large hero at the top of Home (shared `CollectionHeroHeader`, position bar, Play and Not Now; a big focused tile on Apple TV; a card on Watch Home), fading and rising, when another device played within 12 hours, more recently than this one. Handoff `red.forbes.sounding.playing` on iPhone, iPad and Mac (the shared `ContinueFromHandoff`); TV advertises Now Playing Handoff. Offer surfaces rewritten 2026-11-09 without a build (the old plain row was "far too non-descript"). Needs a two-device check of the mini player, hero and Not Now, a Reduce Motion check, a Handoff check from the Dock and app switcher, and a Link check with the Apple TV. |
| Stations | 🟡 | 🟡 | 🟡 | 🟡 | ⬜ | 2026-11-09 code audit | In merge. Base commit has station shelves on Home (all four) and a Create Station intent; no Watch surface. |

## Search

| Feature | iPhone | iPad | Mac | TV | Watch | Last reviewed | Notes |
|---|---|---|---|---|---|---|---|
| One box: library + SoundCloud, Top Result | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 code audit | Shipped 2026-11-08; Search rebuild in merge, so this row will change. |
| Vibe titles | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-07 | Glass capsules; unreviewed. Search rebuild in merge. |
| Watch search | — | — | — | — | 🟡 | 2026-11-09 code audit | Exists; unreviewed. |
| Identify Song button | 🟡 | 🟡 | 🟡 | — | 🟡 | 2026-11-09 | Search toolbar on iPhone, iPad and Mac (`shazam.logo`); first row of the Watch root list. Unbuilt (branch `identify`). See System integrations › Shazam / Identify. |

## Library

| Feature | iPhone | iPad | Mac | TV | Watch | Last reviewed | Notes |
|---|---|---|---|---|---|---|---|
| Library shell (one Library, SoundCloud optional) | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | TV, written without a build: every store folder comes from `AppDataDirectory` (Caches on tvOS, created on first use, falls back to Caches then tmp), so the library DB persists; launch paints the cached library from the DB and shows shaped loading, never "Your Library Is Empty", until the first library sync run has finished and the DB is re-read; a failed first run shows Couldn't Load with Try Again. Local-first library DB in progress (🟡). Library linking in merge. |
| Library sync (one backfilling device per account) | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | Lease in the `LibraryChunk` zone elects one backfiller (Mac on power first; TV only when alone); others refresh the Likes head and read shared chunks. Unit-tested election; unreviewed on devices. Library linking in merge. |
| Recently Added (mixed feed) | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 code audit | One date-sorted grid of playlists, liked albums, liked tracks (days of 3+ grouped), follows and own music, six months or 200 items, no extra requests. Written without a build. Follows are dated from first sight (the same stamp the people pages show), so older follows are absent. |
| Library order | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 code audit | Recently Added, Tracks, Albums, Artists, Playlists, Sets, Setlists, Downloads, Mixes (each platform keeps only the items it has). Likes is no longer its own item. TV's Library sections are only Recently Added, Liked, Playlists, Following; the rest are shelves. Mac sidebar has the iPad split (Library, Playlists, Social; collapsible, remembered) with Recently Added, Setlists and Downloads added; unbuilt. History item is in merge. |
| History (listening history page) | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | 2026-11-09 code audit | In merge. No History page exists at the base commit; Recently Played is a shelf only. |
| Tracks / Likes | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | Likes is a pinned playlist, first in Playlists (heart over line art, "N tracks"), opening the same Likes page. Sort & Filter and Roomy/Dense views; shaped loading placeholders; configurable columns (Settings › Library › Columns). |
| Albums | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | Every liked and own album from the library DB (was first 100 liked playlists); grid placeholders while loading. TV reaches albums through shelves only. |
| Artists | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | iPad and Mac: list beside the selected artist (avatar, name ›, Play, Shuffle, albums); iPhone pushes the same page. Album years aren't scanned yet, so albums show a track count. TV keeps its grid. Watch artist pages have Play and Shuffle. |
| Playlists | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 code audit | iPhone has its own Playlists tab (not a Library row). Likes pinned first on every platform. View As Grid or List (iPhone, iPad, Mac; synced per page); New Playlist (+, Add to Playlist, Mac File › New Playlist… ⌘N) with Add Tracks on an empty playlist. iPad and Mac sidebars have a Playlists section. Add to Playlist sheet on iPhone and iPad; TV page on shared hero. Playlist folders in merge (Mac has My Playlists and Liked Playlists items, no folders). |
| Sets | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | Built from every liked track (was only loaded pages); TV page on shared hero. |
| Downloads | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 code audit | Apple Music model; Go/Go+ only. Mac: Downloads sidebar item (shared `DownloadedMusicView`), unbuilt. TV has it in Settings and Library shelves. Watch Downloads lists what is on the watch (swipe to remove, storage against the limit) and the iPhone's downloads, which play through the iPhone. |
| Send to Watch / On This Watch (offline Watch playback) | 🟡 | — | — | — | 🟡 | 2026-11-09 | New, written without a build. iPhone: Send to Watch toggle first in the More menu of playlists, albums, Likes and own-file albums, and a Send to Watch section in Settings › Downloads (per collection toggles, Your Music albums, Storage Limit 2/4/8 GB, default 2 GB, what's on the watch). Files go over `WCSession.transferFile` only for downloads the plan allows (never previews or tokens). Watch: own audio engine (`AVAudioSession` long-form, `AVPlayer`, Now Playing and remote commands), Library › On This Watch, opens there when the iPhone isn't reachable, iPhone / This Watch switch in Output and the empty Now Playing; plays sync back to Recently Played and SoundCloud through the iPhone. SoundCloud files are removed after 30 days without the iPhone confirming the plan. Needs a real-device check with AirPods, iPhone out of range. |
| Your Music (own files) | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | TV streams from linked devices, opt-in iCloud; new this week. Watch plays own-file albums sent with Send to Watch. |
| Your Tracks (own SoundCloud uploads) | ⬜ | ⬜ | 🟡 | ⬜ | — | 2026-11-09 code audit | Mac sidebar item only; iPhone, iPad and TV reach uploads through the profile page. |
| Private Shares | ⬜ | ⬜ | 🟡 | ⬜ | — | 2026-11-09 code audit | Mac sidebar item only. |
| Setlists / saved mixes | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | Unreviewed. Mac: Setlists sidebar item (shared `SavedSetlistsLibraryView`), unbuilt. |
| Sort, filter, dense/roomy lists | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | One shared column layout for iPad table, Mac tables and Dense rows. TV (written without a build): the shared Sort & Filter menu (`TrackCollectionMenuItems`) in the header of Likes, Tracks, Sets, Setlists and Downloads, with Show Columns (off: artwork grid; on: one-line rows with the first two layout columns; the old Dense choice migrates on) in place of Roomy/Dense; queries remembered per list under the same keys as iPhone. |
| Start & End times (trim editor) | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 code audit | Shared `TrackTrimEditor` from track menus on iPhone, iPad and Mac. Unreviewed. TV (2026-11-09, written without a build): Edit Start & End… in track context menus (long-press) and Start & End in the Now Playing More pane open a full-screen editor on the same `TrackTrimStore`: the waveform with the cut parts dimmed, Start and End pills you click to move (swipe or ◀ ▶, click when done, Menu backs out), Preview Start, Preview End, Suggest, Reset and Save. |

## Social

| Feature | iPhone | iPad | Mac | TV | Last reviewed | Notes |
|---|---|---|---|---|---|---|
| Following | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | One shared people page (model + view) on all four: search, Sort (Recently Followed, Name, Most Followers), avatar, name, follower count and Follow/Following per person; "Followed in March" only for follows first seen by the sync after it shipped, older ones sort after. Written without a build; TV `.searchable` placement and the Library › Following list on iPhone (still the old list) need a look. |
| Followers | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | Same shared people page as Following, read from the library database (capped at 2,000 followers by the sync). New followers are first-seen stamped from now; existing ones show no date. Follow back from the row. Written without a build. |
| Profile page | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | Shared `PersonHero`; banner no longer spills under the iPad sidebar; name always white over the image. Check on device. Mac Overview matches iPad: Latest Release (album or single), Top Tracks, Albums and Playlists shelves; shaped loading placeholders. Unbuilt. |
| Scout (new track/set alerts) | 🟡 | 🟡 | 🟡 | ⬜ | 2026-11-09 code audit | Finds sets by name; lives in Settings on iPhone, iPad and Mac. No TV or Watch surface. Unreviewed. |
| Feed | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 code audit | Unreviewed. No Watch feed. |
| Messages | ⬜ | ⬜ | 🟡 | ⬜ | 2026-11-09 code audit | Mac sidebar item and Social menu only. |

## Album, playlist and artist pages

| Feature | iPhone | iPad | Mac | TV | Watch | Last reviewed | Notes |
|---|---|---|---|---|---|---|---|
| Album page | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | Accent scoped to hero buttons and rows (no longer tints every page); track-row placeholders while loading. Mac own-file albums now on the shared `CollectionHeroHeader` with the artwork accent; Mac collection table shows BPM/key pending marks. Unbuilt. Full-bleed album pages in merge. Watch has a playlist/album list. |
| Playlist / set page | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | TV shipped on shared hero; Mac outside the shared hero. Full-bleed pages and playlist folders in merge. |
| Artist page | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | Hero starts beside the iPad sidebar; Top Tracks from SoundCloud top tracks; light toolbar over the hero. Mac: Top Tracks, Latest Release, shelves and shaped loading like iPad (unbuilt). Full-bleed pages in merge. |

## Navigation

| Feature | iPhone | iPad | Mac | TV | Last reviewed | Notes |
|---|---|---|---|---|---|---|
| Sidebar highlight on page selection | — | 🟡 | 🟡 | 🟡 | 2026-11-09 | Unbuilt, unreviewed. iPad: playlists, Likes and your own profile opened from Home, Search, All Playlists, artist pages or New Playlist select their sidebar row (`SidebarNavigator`). Mac: any pushed playlist, Likes or your own profile redirects to its sidebar row; Back and Forward cross items and keep the highlight. Apple TV: your own profile opened anywhere opens Library › Profile (the account menu). Check: tap a playlist in All Playlists, Search and Home on iPad; Go to Playlist, a playlist tile and Back/Forward on Mac. |
| Navigation redesign | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | In progress. iPhone tabs now Home, Library, Playlists, Social, Search; iPad has no toolbar avatar; selected sidebar item is orange on iPad and Mac. TV tabs: Home, Search, Library, Decks, Now Playing, Settings (Social removed 2026-11-09: an account menu with your avatar tops the Library sidebar with Profile, Activity, Following and Followers); TV redesign in merge. Unreviewed on device. |
| iPad floating sidebars | — | 🟡 | — | — | 2026-11-09 | Home, Search, Decks, then Library, Playlists and Social sections. No Settings item: the account row opens the Settings sheet (signed out, a gear beside Sign In), ⌘, too. Settings sheet: sidebar list style, account header, one-line icon rows. Playlists section (All Playlists, Likes, every playlist, New Playlist). Account row is the last row of the sidebar list, so it can't cover Activity. Check a device. |
| TV focus traps and Menu behaviour | — | — | — | 🟡 | 2026-11-09 | Traps fixed; Menu from Now Playing returns to origin; keep walking the UI tests. TV redesign in merge. |
| Mac Settings sidebar | — | — | 🟡 | — | 2026-11-09 | System Settings style, owner decision. |
| Mac list selection (no `List(selection:)`) | — | — | 🟡 | — | 2026-11-09 | Sidebar, Settings, Messages, Artists, DJ Prep and DJ Library use button rows with their own highlight (sidebar: brand orange) plus arrow keys and Return. Unbuilt; check the look, scroll-to-selection and double-click on device. |

## Now Playing

| Feature | iPhone | iPad | Mac | TV | Watch | Last reviewed | Notes |
|---|---|---|---|---|---|---|---|
| Now Playing | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 code audit | Always dark; TV metadata focus chrome being stabilised. |
| Mini player | 🟡 | 🟡 | 🟡 | — | — | 2026-11-09 | iPad rebuilt as the Apple Music bar (shuffle, transport, repeat, identity, more, Lyrics, Up Next; Not Playing state); iPhone inline is artwork plus play/pause; zooms from the artwork into Now Playing. Mac has a toolbar player and a menu bar player. Foreground is `.primary`/`.secondary` only on the system glass (no tint, no fixed colour); stale window scheme released after Now Playing closes. White-on-white fix needs a device check. |
| Tape scrubber | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 code audit | 6 min+ tracks and sets on iPhone, iPad and Mac. TV (written without a build): 6 min+ tracks and sets turn the Now Playing waveform into a tape on the shared `SCWaveformRenderer` (`.centered`, 4-minute window, `SCWaveformStyle.tv`, cue marks): swipe on the touch surface or press ◀ ▶ (15 s) to move it, click to play from there, Menu to cancel; it lands by itself after 6 s. Shorter tracks keep the whole-track lane, where a click now also commits a scrub. Comments are now small avatar dots and count capsules at their times (capped, nearest the playhead), text on pass or hover; written, not yet built or seen on device. |
| Waveform (Metal) | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-08 | Unreviewed. |
| Track map / tracklist | 🟡 | 🟡 | ⬜ | 🟡 | 🟡 | 2026-11-09 code audit | `TrackMapSheet` on iPhone and iPad, `TrackMapView` on TV, Watch tracklist; Mac has none. |
| Comments | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 code audit | Below the fold on iPhone and iPad, a pane on Mac, a list on TV. Unreviewed. |
| Behind the Track | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 code audit | Replaces About. Pane, title tap, ••• and context-menu sheet; TV button-row button. Followed likers and reposters unverified against live SoundCloud. Not yet built or seen. Watch has a small Track Info page only. |
| Sleep Timer | 🟡 | 🟡 | 🟡 | 🟡 | ⬜ | 2026-11-09 code audit | Unreviewed. |
| Wake alarms (AlarmKit) | 🟡 | 🟡 | — | — | — | 2026-11-07 | Unreviewed. |
| Add to Playlist | 🟡 | 🟡 | 🟡 | 🟡 | ⬜ | 2026-11-09 code audit | Mac: Add to Playlist… in the track context menu and the Now Playing ••• menu opens a searchable sheet on the shared `AddToPlaylistModel` (was a bare submenu that swallowed errors). No "Added to" toast on the Mac yet. Written without a build. TV (written without a build): Add to Playlist… in every track context menu (long-press: Library, playlists, artist pages, Home and Search tiles) and Add to Playlist in the Now Playing More pane open a full-screen focusable list of your playlists with a New Playlist field (Create and Add) on the shared `AddToPlaylistModel` (now cross-platform with `PlaylistEditFailure` and the `presentAddToPlaylist` environment key); "Added to …" glass toast. Watch can't add to a playlist. |
| Sharing (SoundCloud link) | 🟡 | 🟡 | 🟡 | — | — | 2026-11-08 | Unreviewed. |
| Output / Play On | 🟡 | 🟡 | 🟡 | — | 🟡 | 2026-11-09 | Sonos output added; Nearby section links an unlinked Apple TV from Play On (iPhone, iPad, Mac popover), written without a build; unreviewed. |
| Output / Play On | 🟡 | 🟡 | 🟡 | — | 🟡 | 2026-11-09 | Sonos output added. Output volume is one shared model (`Core/Playback/OutputVolume.swift`): Now Playing and Play On set the TV or Sonos when either is the Output; iPhone and iPad volume buttons step a remote Output in the foreground. Written without a build; unreviewed on device. |

## Lyrics

| Feature | iPhone | iPad | Mac | TV | Watch | Last reviewed | Notes |
|---|---|---|---|---|---|---|---|
| Synced lyrics (LRCLIB, opt-in) | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 code audit | Full-screen on TV; "No Lyrics for Mixes". Bible: the Watch has no lyrics. Unreviewed. |

## Queue

| Feature | iPhone | iPad | Mac | TV | Watch | Last reviewed | Notes |
|---|---|---|---|---|---|---|---|
| Up Next / Playing Next | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-08 | "Playing from…" on all; Watch jumps on tap. |
| Queue with Auto Mix | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-08 | Queued tracks play first, then Auto Mix picks. |
| Drag and drop (tracks, albums, playlists) | ⬜ | 🟡 | 🟡 | — | — | 2026-11-09 code audit | New, written without a build. Drag any track row, playlist or album tile, or the Now Playing artwork (Mac: a multi-selection in the track table). Drops: Up Next (iPad panes insert at the drop position with the system line; Mac rows insert above the row and the pane appends; local files allowed), the iPad and Mac mini player appends, your own playlist tiles, rows and pages (adds the tracks; SoundCloud tracks only, so local files show no highlight), folders in the iPad sidebar and the Mac sidebar and folder pages (moves the playlist). Dropping into other apps gives the SoundCloud link as a URL and text. Types `red.forbes.sounding.track`, `.local-track` and `.collection` are exported in the iOS and Mac Info.plists. Not built: reordering an owned playlist by dragging (no playlist-order API yet), individual playlist rows in the sidebars (they have folders only), Mac success toast. iPhone has the sources but few drop targets; Decks still takes track drops. Needs an iPad and Mac pass: Tab-level `dropDestination` on the iPad folder rows, the Up Next `dropDestination` beside `onMove`, and a multi-select drag from the Mac Tracks table. |
| Restore last session on launch | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | Rebuilt after the iPad came back "Not Playing" after a relaunch: restores track (paused, same position), whole queue, shuffle/repeat, source and Auto Mix with its style from cached metadata before any network. Unverified on device; check `Log.playback` restore lines. |

## Auto Mix, DJ and Decks

| Feature | iPhone | iPad | Mac | TV | Watch | Last reviewed | Notes |
|---|---|---|---|---|---|---|---|
| Auto Mix engine and planner | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | Heavy active work; owner still hears audible steps in some mixes. |
| Auto Mix live line (Now Playing) | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 code audit | iPhone and Mac: one glass capsule (artwork, "Mix into Title", move sentence, two-lane glyph, countdown) replaces the dark timeline panel; Mac decks drop the duplicate timeline. Written, not yet built or seen on device. TV unchanged. Watch shows a Mix into plate. |
| Auto Mix settings (Style, Your Moves, Flair) | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | Unreviewed. Mac: Auto Mix page carries Auto Mix, Style, Blend, Keep Queue Order, Status and Energy above Your Moves (moved out of Playback); Decks › Start Auto Mix… opens the shared sheet in place. Unbuilt. |
| Auto Mix AI picking | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | Prototype. TV: the same Tonight section in Settings › DJ › Your Moves, plus Tonight… in the Decks Auto Mix menu (deterministic parser, no on-device model on tvOS); why lines in the live view. Not yet seen on a TV. |
| Mixes history and replay | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | TV (written without a build): a Mixes shelf last in Library (saved sets, saved mixes, then recent; opens the transition or set page with Play This Mix) and the shared Mixes page from its header; read-only on TV; no longer in Settings. iPhone, iPad, Mac unreviewed. History is in merge. |
| Decks | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 code audit | iPhone and iPad share `PhoneDecksView` (iPad has a Decks sidebar item); TV Decks (`DJModeView`) redesigned 2026-11-09; Watch DJ is Auto Mix and workout energy only. Decks rework in merge. |
| Decks on the Apple TV from iPhone and iPad | 🟡 | 🟡 | — | 🟡 | — | 2026-11-09 | `PhoneRemoteDecksView` inside `PhoneDecksView`: opens straight onto the TV's decks when Output is the TV and Decks is on screen there; "Mixing on Living Room", CUE, Play, Sync, tempo, EQ and filter, crossfader, Mix Now, Load Next, Extend; 10 Hz deck state while attached. Written, not yet built or seen on device. Decks rework in merge. |
| DJ Perform / Prep / Plan | — | — | 🟡 | — | — | 2026-11-12 | Prep is an action: no Prep page or window, the track inspector (⌘I/⌥⌘P, context-menu Prep) edits grid, cues, start/end, suggestions and analysis with the shared TrackMap views and follows the selection; decks set downbeat, tempo and cues directly; crates are sidebar smart playlists; Export to USB in File; rekordbox imports in File › Import. Decks: whole window dark, main sidebar collapses, never two sidebars or inspectors, Plan a sheet over Perform. |
| Mixer, cueing, deck FX | — | — | 🟡 | — | — | 2026-11-08 | Unreviewed. iPhone and iPad have a deck mixer in `PhoneDecksMixer`. Decks rework in merge. |
| rekordbox import/export, USB export | — | — | 🟡 | — | — | 2026-11-09 | No `master.db` access by decision. |
| Music Analysis | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | Throughput 13 to 114 tracks/min; own models stopped. |
| BPM and key: pending state, Analyse Now, Analyse All Now, Tempo & Key | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 code audit | Built, not yet built or seen on device. Pending marks in the iPad table, Dense rows, Mac table, Mac Now Playing and Decks library; Tempo & Key sheet (BPM 40–250, Tap Tempo, 24 keys, Reset to Analysed) from track menus on iPhone, iPad and Mac; status and Analyse All Now in Music Analysis settings (TV shows status only). Mac collection tables use the shared `TrackAnalysisValueCell`. |
| Analyse Missing | 🟡 | 🟡 | ⬜ | 🟡 | — | 2026-11-12 | Written without a build. Shared `MissingAnalysisRun` (Core/Analysis/MissingAnalysis.swift) and `AnalyseMissingMenuItems` / `MissingAnalysisProgressLine`. iPhone and iPad: playlist and track menus, Sort & Filter on playlists, Likes, Sets, Tracks and local collections, progress line in the lists. TV: track menu, the gate copy as a toast. Mac: in progress by another agent. |
| Match My Workout (heart rate to Auto Mix energy) | 🟡 | — | — | — | 🟡 | 2026-11-09 code audit | Watch workout drives iPhone Auto Mix energy; iPad, Mac and TV have no equivalent. |

## Controllers

| Feature | iPhone | iPad | Mac | TV | Last reviewed | Notes |
|---|---|---|---|---|---|---|
| DJ controllers (own music only) | ⬜ | ⬜ | 🟡 | ⬜ | 2026-11-09 code audit | Built in, no plugins; Mac Hardware page lists controllers and DJ Players (status, Connect) and a MIDI monitor; DJ Players popover in the Decks toolbar. Real-hardware status unreviewed. |

## Devices, Link, Companion and TV sign-in

| Feature | iPhone | iPad | Mac | TV | Watch | Last reviewed | Notes |
|---|---|---|---|---|---|---|---|
| Link (QR, Bonjour token transfer) | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | One tap between your own devices: iCloud link key (`LinkOwnerKey`) proves same Apple ID and account, TV skips Allow, phone skips the code; falls back to code and Allow. Needs the `LinkOwnerKey` schema in Production. TV progress now spans offer close and authenticated handoff; numeric codes are centred, monospaced and only shown for required approval. Unbuilt and untested on device (2026-11-09). |
| Companion (control, state, settings) | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-08 | Mac Remote window removed. |
| TV sign-in screen and warm chime | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 code review | Separate reserved countdown caption; copper-and-amber breathing gradients and cable depth; one plate halo; original 1.45 s C–E–G chime replaces Omen and the audible data texture. Ultrasonic pairing remains; QR/numeric fallback needed on outputs that filter ultrasound. Active links and Companion credential adoption show a centred spinner. Unbuilt and unheard; main session must check light/dark, Reduce Motion, audio routes and handoff/failure/timeout. |
| Automatic TV sign-in card | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | Remembered like AirPods: no Link for linked TVs, no Sign In for signed-in TVs, Not Now saved per TV until away and back after 12 h. The large hierarchical `appletv.fill` is restored on the card; `DeviceIllustration` remains in the discovery header; candidates deduplicated by kind and name. Unbuilt; not yet tested on device. |
| Add Apple TV sheet (Nearby list) | 🟡 | 🟡 | 🟡 | — | — | 2026-11-09 | Native inset grouped Nearby list with status and chevron, small searching header, QR / code fallback as a plain bottom button; duplicate TVs merged. Unbuilt. |
| Liquid QR code (shared renderer) | — | — | — | 🟡 | — | 2026-11-09 | Shared `SoundingQRCode.swift`; used by the sign-in plate, Open on Phone and Open Source; ripple-in respects Reduce Motion; unbuilt, `SoundingQRCodeTests` unrun. TV only: no Mac or iOS screen shows a QR code. |
| Time Sensitive sign-in request | 🟡 | 🟡 | 🟡 | — | — | 2026-11-09 | Link / Not Now actions, withdrawn when the TV signs in or gives up; Mac gets it as a notification. Untested on device. |
| New Sign-In notification (account used on a new device) | 🟡 | 🟡 | 🟡 | — | — | 2026-11-09 | Built 2026-11-09, untested on device; TV writes the record but shows nothing. Needs the `AccountSignIn` schema deployed. |
| Devices page | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | TV uses a stock list. |

## SharePlay

| Feature | iPhone | iPad | Mac | TV | Watch | Last reviewed | Notes |
|---|---|---|---|---|---|---|---|
| Listen Together | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 code audit | Playback only, replaced Polyphony; needs multi-device soak. Buttons in Now Playing on all four; Watch isn't compiled with it. |

## Settings

| Feature | iPhone | iPad | Mac | TV | Watch | Last reviewed | Notes |
|---|---|---|---|---|---|---|---|
| Settings structure and icons | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | Colour per row, never orange. New Library › Columns (iPhone, iPad, Mac). |
| Network Activity log | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-08 | One log for every URLSession path. |
| Artwork cache (resized HEIC, Settings › Downloads › Artwork + Clear Artwork) | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | Stores each variant downsampled to its display size as HEIC (JPEG fallback, PNG for alpha); smaller variants derived from larger on disk; caps 256/512/128/32 MB (iOS/Mac/TV/Watch); old full-size cache deleted once. Every remote artwork and avatar view uses it except the Share extension's one header thumbnail. 2026-11-09 smoothness pass: first-frame cache reads, any cached size stands in, no placeholder flash on reuse, show-before-encode, bounded newest-first prefetch, RAM-scaled budget, cached mosaics, Mac palette off the main thread. Not yet built or checked on device. |
| Alarms, Sleep, Sharing, Advanced | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-08 | Unreviewed. |
| Settings sync and scopes (iCloud, account wipe) | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | New: Apple ID sync, account settings wiped on sign-out and restored on sign-in; needs a two-device check. |
| Home lighting (HomeKit scenes, Party, Wind Down) | 🟡 | 🟡 | ⬜ | 🟡 | — | 2026-11-09 code audit | Settings on iPhone, iPad and TV; the HomeKit backend is UIKit-only, so the Mac has none. Party Mode and Wind Down intents exist. |

## System integrations

One row per Apple surface. Cells say whether the code ships it, not whether it works on device.

| Integration | iPhone | iPad | Mac | TV | Watch | Last reviewed | Notes |
|---|---|---|---|---|---|---|---|
| CarPlay | ⬜ | — | — | — | — | 2026-11-09 code audit | No `CarPlay` import, entitlement or scene. Only mentioned in `Design/specs/os27-*`. Background audio and Siri carry iPhone in the car. |
| Focus filters | ⬜ | ⬜ | ⬜ | — | ⬜ | 2026-11-09 code audit | No `SetFocusFilterIntent` anywhere. |
| Control Center controls | 🟡 | 🟡 | 🟡 | — | 🟡 | 2026-11-09 | Play/Pause and Resume controls in the Widget extension; the Watch widget bundle has Play/Pause. Mac gets the same two in Control Center and the menu bar from the new Mac widget extension (macOS 26 `ControlWidget`). Mac written without a build. |
| Live Activities / Dynamic Island | 🟡 | — | — | — | — | 2026-11-09 code audit | Now Playing and TV sign-in activities (iPhone only; iPadOS has none). Mac and Watch mirror iPhone activities with no code of ours. |
| StandBy | ⬜ | — | — | — | — | 2026-11-09 code audit | No StandBy-specific view; the small Now Playing widget shows there by default. TV has an Ambient screen. |
| Lock Screen widgets | 🟡 | 🟡 | — | — | — | 2026-11-09 code audit | Now Playing and Recently Played accessory families. |
| Home Screen widgets | 🟡 | 🟡 | ⬜ | — | — | 2026-11-09 code audit | Small and medium Now Playing and Recently Played. |
| Mac widgets | — | — | 🟡 | — | — | 2026-11-09 | `SoundingTV-macOS-Widget` compiles the iOS widget sources: Now Playing and Recently Played, small and medium, desktop and Notification Center, Play or Pause and Next buttons, taps open `soundingtv://widget` links in the Mac app. Written without a build. Shows nothing until the Mac app gets the `group.red.forbes.sounding` app group (owner to enable). |
| Mac menu bar extra | — | — | 🟡 | — | — | 2026-11-09 code audit | `MenuBarExtra` window player. |
| Siri / App Shortcuts | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | Nine shortcuts (play, likes, shuffle, similar, last set), audio-schema intents, `INPlayMediaIntent` handler on iPhone. Watch now has its own `SoundingWatchShortcuts` (Play, Pause, Next Track, Play Likes, Shuffle Likes, Like Track) in `WatchShortcuts.swift`; transport and likes playback go through the iPhone link, Like Track calls SoundCloud from the Watch. No station or playlist intent on the Watch (no entity query there). Written without a build; needs iPhone and Watch device checks. |
| Spotlight | 🟡 | 🟡 | 🟡 | ⬜ | — | 2026-11-09 code audit | `SpotlightIndexingService` plus App Entities on iPhone, iPad and Mac. |
| Handoff / Continue From | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 code audit | Shared `ContinueFromHandoff` on iPhone, iPad and Mac; TV advertises Now Playing and a pairing handoff; Watch shows the Continue card. The `nowPlaying` activity (advertised by the Apple TV with track and position) is now handled by the shared `ContinueFromHandoff` on iPhone, iPad and Mac, through the same `ContinueFrom.continueActivity` as `playing`: same track, same position, loaded paused. Written without a build; needs a TV to iPhone Handoff check. |
| SharePlay | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 code audit | See SharePlay section. |
| AirPlay / route picker | 🟡 | 🟡 | ⬜ | 🟡 | — | 2026-11-09 code audit | `AVRoutePickerView` in the iPhone/iPad Connect sheet and the TV panel. Mac has a "Bluetooth & AirPlay…" link out, no in-app picker. |
| Top Shelf | — | — | — | 🟡 | — | 2026-11-09 | Fixed without a build: tvOS only lets apps write under `Library/Caches` of the app-group container, and the snapshot was written to the container root. `SoundingAppGroup.writableURL` now picks `Library/Caches` on tvOS (root elsewhere) for the Top Shelf snapshot, shelf line art, widget artwork and the now-playing snapshot; old snapshots at the root or in Caches are still read. Both the app and the extension already carry `group.red.forbes.sounding`. Needs a check that the Top Shelf fills on the TV. |
| Share extension | 🟡 | 🟡 | 🟡 | — | — | 2026-11-09 | iOS sends to the Apple TV; the new Mac extension shares its views and hands the link to the Mac app (Play Now, Play Next, Play Last). Mac written without a build. |
| Now Playing info and remote commands | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 | One `SystemNowPlayingBridge` in Core for all four. The Watch sets its own Now Playing info and remote commands while it plays On This Watch (system Now Playing and crown volume work); otherwise it mirrors the iPhone. Watch part written without a build. |
| Watch complications | — | — | — | — | 🟡 | 2026-11-09 code audit | One Now Playing widget (accessory families, sample/empty/ended states); no Recently Played or DJ complication. |
| Watch offline playback | — | — | — | — | ⬜ | 2026-11-09 code audit | No audio engine on the Watch; Downloads and Library play through the iPhone. |
| Shazam / Identify | 🟡 | 🟡 | 🟡 | — | 🟡 | 2026-11-09 | Identify Song (branch `identify`, written without a build): microphone listen through `SHManagedSession`, the shared result (artwork, title, artist, Find on SoundCloud with top matches to play, like and add, Add to Library, Apple Music, Share) and Recently Identified (50, synced through the Apple ID preferences). iPhone and iPad: Search toolbar button, App Shortcut and Control Center control. Mac: Search toolbar button, Library › Identify Song ⇧⌘I. Watch: listens on its own mic from the root list. Identify This Track in the mix Tracklist pane opens the same result. Needs device checks: microphone prompt, playback audio session while listening, control launching the sheet. |
| HomeKit | 🟡 | 🟡 | ⬜ | 🟡 | — | 2026-11-09 code audit | Home lighting director; see Settings. |
| Keyboard shortcuts and menus | 🟡 | 🟡 | 🟡 | — | — | 2026-11-09 | Mac: Playback, Library, Social, Decks, Prep and View menus, many shortcuts. iPad now matches where it can: Playback (Space, ⌘←, ⌘→, ⌘↑ and ⌘↓ volume, ⌘L Like), View › Home ⌘1, Search ⌘2, Recently Added ⌘3, Tracks ⌘4, Albums ⌘5, Artists ⌘6, Sets ⌘7, All Playlists ⌘8, Likes ⌘9, Decks ⇧⌘D, Library menu ⌥⌘1 to ⌥⌘3, Settings ⌘, and Find ⌘F. No ⌘[ and ⌘] (no shared back and forward) and no ⌘Y (History not built yet). Written without a build; check the ⌘-hold overlay on an iPad with a keyboard. |
| Drag and drop | ⬜ | ⬜ | 🟡 | — | — | 2026-11-09 code audit | Mac DJ Prep and Perform only. Nothing drags tracks into playlists or the queue on iPad or the Mac library. |
| Multi-window | — | 🟡 | ✅ | — | — | 2026-11-12 | iPad: Open in New Window for artist and playlist (`WindowRoute`, multiple scenes on). Mac: one main window like Music (owner 2026-11-12); only Settings and About open separately; import is a sheet, effect editors are popovers. |
| Stage Manager | — | 🟡 | — | — | — | 2026-11-09 code audit | No specific code; resizable windows and multiple scenes only. Unchecked on device. |
| Apple Pencil hover | — | — | — | — | — | 2026-11-09 code audit | Not relevant; no Pencil code. |
| URL handling (`soundingtv://`, universal links) | 🟡 | 🟡 | 🟡 | 🟡 | — | 2026-11-09 | `onOpenURL` on iOS, Mac and TV. `soundingtv://widget/...` and `https://sounding.forbes.red/play` or `/now-playing` links parse in the shared `SoundingWidgetLink` and run through `WidgetLinkRouter` on iPhone, iPad and Mac (the Mac Info.plist registers the scheme). Pairing links under `/auth` stay iPhone and iPad only. The site's `apple-app-site-association` lists only `/auth`, so web `/play` links open nothing until it lists them. Written without a build. |
| Notifications (activity, sign-in) | 🟡 | 🟡 | 🟡 | — | — | 2026-11-09 code audit | iOS Notification Service extension; Mac local notifications. |
| Accessibility: VoiceOver labels | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 code audit | Counts of `accessibilityLabel`: iOS 120, Mac 137, TV 100, Watch 19, shared 46. Never audited with VoiceOver; the Watch is thin. |
| Accessibility: Dynamic Type, Reduce Motion | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 2026-11-09 code audit | Dynamic Type and Reduce Motion used widely (about 180 and 119 call sites across the repo); Watch bible rule for xxLarge exists. Not tested at accessibility sizes on device. |

## Widgets, Top Shelf, Share extension and Watch

| Feature | iPhone | iPad | Mac | TV | Watch | Last reviewed | Notes |
|---|---|---|---|---|---|---|---|
| Top Shelf | — | — | — | 🟡 | — | 2026-11-09 | Fixed without a build: tvOS only lets apps write under `Library/Caches` of the app-group container, and the snapshot was written to the container root. `SoundingAppGroup.writableURL` now picks `Library/Caches` on tvOS (root elsewhere) for the Top Shelf snapshot, shelf line art, widget artwork and the now-playing snapshot; old snapshots at the root or in Caches are still read. Both the app and the extension already carry `group.red.forbes.sounding`. Needs a check that the Top Shelf fills on the TV. |
| Widgets and Live Activity | 🟡 | 🟡 | 🟡 | — | 🟡 | 2026-11-09 | Now Playing (small, medium, Lock Screen) and new Recently Played (small, medium, Lock Screen) with artwork from the app-group cache, `soundingtv://widget` taps, Play or Pause and Resume controls; watch widget gets sample, empty and end-of-track states. Live Activity iPhone only. Mac widget extension shares the iOS widget sources (no accessory families, no Live Activity) and needs the Mac app group before it shows data. Written without a build; needs a device check of accented and clear modes and of the tap-to-play links. |
| Share extension | 🟡 | 🟡 | 🟡 | — | — | 2026-11-09 | Unreviewed. Mac extension added 2026-11-09 (opens the link in the Mac app), written without a build. |
| Watch app (Home, Library, Now Playing, DJ, Downloads) | — | — | — | — | 🟡 | 2026-11-09 code audit | Real queue, Volume slider in Output; plus Search and Settings. A remote only: no local audio, no Feed or Social, no Add to Playlist or Sleep Timer. |
| Siri, App Intents, Action button | 🟡 | 🟡 | 🟡 | 🟡 | ⬜ | 2026-11-09 code audit | Needs iPhone device checks. Action button via Control widgets and intents. |
| CarPlay (Listen Now, Library, Stations, Search, Now Playing) | 🟡 | — | — | — | — | 2026-11-09 | Built as a CarPlay audio app on the iPhone; dormant until Apple grants `com.apple.developer.carplay-audio` and the entitlement is added. Never run in a car or the CarPlay simulator yet. Search is the Siri cell plus recent searches over the library (`CPSearchTemplate` is navigation-only). |

## Website

| Feature | Status | Last reviewed | Notes |
|---|---|---|---|
| Homepage | 🟡 | 2026-11-09 | Refreshed: own music and DJ-in-your-pocket story, iPad Library scene, TV sign-in screen and nearby card, "The small stuff.", plan rules. Not yet seen in a browser; six `data-shot` screenshots still to capture. |
| DJ page | 🟡 | 2026-11-09 | Controllers own-music only and Go+ for decks added; USB copy unchecked against the current app. |
| Privacy page | 🟡 | 2026-11-09 | Lyrics, Mac AI, promoted tracks and network log restored after a merge dropped them; library database, settings sync, own music and nearby card added. |
| Support page | 🟡 | 2026-11-09 | Plan rules and the nearby-card and QR sign-in path updated. |

## How to update

- Anyone finishing work updates the rows they touched: new status, date and a short note on what is left.
- Reviews add a date to the rows they covered, even when the status doesn't change.
- Rows marked "in merge" are re-audited by whoever lands the branch.
- Design/DESIGN-BIBLE.md §12 points here.
