# tvOS Apple Music alignment — executable plan

Status: active, 2026-08-04. The source audit is complete; implementation starts with Library.

This file is the resume contract for the current tvOS UI pass. After a context
compaction, read this file and the reference observations below, inspect the
unchecked phase, and continue there. Do not infer completion from the presence
of an existing view: each phase is complete only when its acceptance captures
exist and the checks in "Definition of done" pass.

## Outcome

Make Library, Home, Feed, artist detail, and album/playlist detail feel native
to Apple Music on tvOS 27 while retaining SoundCloud's content model and orange
accent. This pass is structural, not a colour-only reskin.

Physical Apple TV captures from 2026-08-04 also put Now Playing, Search, Cues,
and Behind This Track in scope. They expose shared layout/focus failures that
must be fixed at the primitive level rather than hidden on individual screens.

The reference hierarchy and geometry come from:

- `Design/reference/appletv-music/OBSERVED.md`
- `Design/reference/appletv-music/library recently added Medium.jpeg`
- `Design/reference/appletv-music/library artists Medium.jpeg`
- `Design/reference/appletv-music/librry albums Medium.jpeg`
- `Design/reference/appletv-music/library playlists Medium.jpeg`
- `Design/reference/appletv-music/artist Medium.jpeg`
- `Design/reference/appletv-music/album Medium.jpeg`
- `Design/reference/appletv-music/playlist Medium.jpeg`
- `Design/reference/appletv-music/home Medium.jpeg`
- `Design/reference/appletv-music/new Medium.jpeg`
- `Design/reference/appletv-music/new down Medium.jpeg`

SoundCloud remains visible in editorial kickers, repost attribution, waveform
accents, and selective orange emphasis. Orange must not become a focus ring.

## Current truth

- Library has a 340pt rail and five-column grids, but its information
  architecture is `Liked Songs / Liked Artists / Liked Albums / Playlists /
  Following`, and liked albums currently show every liked collection.
- Artist and playlist destinations exist, so navigation is not absent. Their
  current generic segmented/stacked layouts do not match the Apple TV reference.
- Home has useful shelf primitives and approximately correct tile/card metrics.
  It needs deliberate shelf ordering, first-screen hierarchy, and consistent
  focus/spacing rather than another component rewrite.
- Feed currently shows three hero cards followed by one long vertical list. It
  should use the Apple Music New rhythm: two editorial heroes, then dense
  horizontal content modules.
- The source tree migration is in progress. Preserve the logical homes under
  `SoundingTV.swiftpm/Sources/Apps/tvOS`; do not move these files back to their
  old paths. Do not restore the intentionally deleted `DemoSeed.swift`.
- Physical-device before captures show whole-label focus wash, navigation chrome
  overlapping content, unconstrained long titles, giant full-width row pills,
  an oversized loading panel, and unrelated Now Playing layout islands. Treat
  those as blocking defects, not polish.

## Phase 1 — shared tvOS browse grammar

- [ ] Put layout constants for rail, five-column grids, tiles, large cards,
  heroes, detail artwork, gutters, and page lead in one tvOS design namespace.
- [ ] Give `SCCardButtonStyle` explicit size classes: tile 1.15, editorial 1.08,
  hero 1.05. Use restrained lift/downward shadow and label promotion with no
  outline, glow, or blanket static shimmer across text and irregular layouts.
- [ ] Keep artwork focus local to the visual surface. Text, row chrome, and
  transparent padding must not become one glowing rounded rectangle.
- [ ] Establish one content-safe top origin below the root navigation capsule.
  No screen title, shelf header, search field, or focused card may sit beneath it.
- [ ] Give text containers explicit width budgets and line limits. Long SoundCloud
  titles may truncate or wrap deliberately; they may not collide with chrome or
  disappear beyond the right safe area.
- [ ] Standardize section headers at 28–33pt, ~76% white, with 24–30pt content
  gap and 54–84pt inter-section gap.
- [ ] Keep tile art at 260pt, ~40pt gutters, and 12–16pt artwork radii. Large
  cards remain approximately 410×550pt and heroes 860×650pt.
- [ ] Make browse backgrounds cool and downward-darkening; detail backgrounds
  may derive a restrained wash from artwork.

Primary files:

- `SoundingTV.swiftpm/Sources/Apps/tvOS/Design/DesignSystem.swift`
- `SoundingTV.swiftpm/Sources/Apps/tvOS/Features/Home/HomeView.swift`
- `SoundingTV.swiftpm/Sources/Shared/Design/ContentComponents.swift`
- `SoundingTV.swiftpm/Sources/Shared/Design/ContentStyle.swift`

## Phase 2 — Library information architecture

- [ ] Replace the primary rail with `Recently Added / Artists / Albums / Songs /
  Playlists`, in that order. Keep `Following` in a separated SoundCloud group;
  it must not substitute for Artists.
- [ ] Split collections with `Playlist.isAlbum`: Albums contains albums only;
  Playlists contains non-album liked and owned playlists, de-duplicated by ID.
- [ ] Artists is a stable de-duplicated union of artists from saved tracks and
  followed users. Songs is the saved/liked track list.
- [ ] Recently Added is a mixed, date-descending collection grid. Use available
  like timestamps for tracks and the best honest collection timestamp; do not
  invent precision the SoundCloud API did not return.
- [ ] Preserve the persistent white selected rail pill when focus moves into
  content. Focused rail rows use white material with black text.
- [ ] Add a Library header action row. Play and Shuffle apply to sections that
  resolve to tracks; filter/sort are shown only where they perform a real action.
- [ ] Keep loading, empty, pagination, and stale-refresh behavior per section.
  A new layout must not collapse all sections into one load state.

Primary files:

- `SoundingTV.swiftpm/Sources/Apps/tvOS/Features/Library/LibraryView.swift`
- `SoundingTV.swiftpm/Sources/Apps/tvOS/UI/Components/PlaylistGridView.swift`
- `SoundingTV.swiftpm/Sources/Apps/tvOS/UI/Components/UserGridView.swift`
- `SoundingTV.swiftpm/Sources/Apps/tvOS/UI/Components/TrackListView.swift`

Library acceptance:

- The first frame reads as a fixed ~340–360pt rail plus content beginning near
  x=440pt, with five tiles across at 1080p.
- Artists are circular and open artist detail. Albums and playlists are square
  art tiles and open their correct detail destination. Songs open/play normally.
- Albums never contain a non-album playlist; Playlists never contain an album.
- Directional focus can leave and re-enter the rail without losing selection.

## Phase 3 — artist and collection destinations

- [ ] Replace the Artist segmented-control-first layout with a compact circular
  avatar/title header, Play and Shuffle actions, top tracks, albums, and
  playlists/reposts as titled shelves. Empty secondary shelves simply disappear.
- [ ] Make album and playlist detail a two-column composition: approximately
  800pt artwork at left; type, title, artist, metadata, actions, description,
  and track list at right. Adapt below the fold without shrinking the hero art
  to the current 320pt thumbnail.
- [ ] Album labels and metadata say Album; playlist labels say Playlist. Both
  retain pagination/hydration, unavailable-track states, and playback context.
- [ ] Back navigation restores focus to the originating tile.

Primary files:

- `SoundingTV.swiftpm/Sources/Apps/tvOS/Features/Library/ArtistDetailView.swift`
- `SoundingTV.swiftpm/Sources/Apps/tvOS/Features/Library/PlaylistDetailView.swift`
- `SoundingTV.swiftpm/Sources/Apps/tvOS/ViewModels/ArtistDetailViewModel.swift`
- `SoundingTV.swiftpm/Sources/Apps/tvOS/ViewModels/PlaylistDetailViewModel.swift`

## Phase 4 — Home

- [ ] Open directly on `Top Picks for You`; Home has no full-bleed hero.
- [ ] Alternate a large editorial shelf with dense 260pt square shelves when
  the API provides suitable content. Avoid consecutive large-card shelves.
- [ ] Put resume/recently-played content near the top without allowing it to
  erase the editorial first-screen identity.
- [ ] Make every kicker explain why the item is present (`Made for You`, `New
  Release`, `Because you played…`, `Station`, `Album`, `Playlist`).
- [ ] Keep the right-edge bleed and approximately 4.2 editorial or 6.3 square
  items visible. Verify title/subtitle promotion on focus and truncation.
- [ ] Preserve discovery loading, partial endpoint failure, stale refresh, and
  playback behavior.

Primary files:

- `SoundingTV.swiftpm/Sources/Apps/tvOS/Features/Home/HomeView.swift`
- `SoundingTV.swiftpm/Sources/Apps/tvOS/ViewModels/DiscoveryHomeSource.swift`

## Phase 5 — Feed

- [ ] Treat Feed as SoundCloud's version of Apple Music New: exactly two large
  leading editorial cards, then titled horizontal modules.
- [ ] Render track activities as dense horizontal song lockups rather than one
  full-width vertical stack. Render playlists/albums as square collection shelves.
- [ ] Preserve repost attribution as a SoundCloud-specific kicker, not a badge
  that competes with the title.
- [ ] Keep pagination attached to the final visible activity across modules and
  preserve playlist navigation and track playback context.
- [ ] Retain signed-out, loading, error, and empty states.

Primary files:

- `SoundingTV.swiftpm/Sources/Apps/tvOS/Features/Feed/FeedView.swift`
- `SoundingTV.swiftpm/Sources/Apps/tvOS/ViewModels/FeedViewModel.swift`

## Phase 6 — Now Playing and secondary surfaces

- [ ] Recompose Now Playing on a shared grid: artwork at left; bounded title,
  artist, actions, and compact Up Next at right; one aligned waveform/timeline;
  one anchored transport surface. Remove the large unrelated empty zones.
- [ ] Long titles use a two-line maximum and never run under the system Now
  Playing HUD. Missing artwork remains an intentional quiet placeholder rather
  than a dominant error symbol.
- [ ] Replace the detached `Live Mix`/transport stack with one coherent control
  region. SoundCloud/DJ actions remain secondary to playback.
- [ ] Behind This Track uses two readable sections: engagement and track facts.
  Wrap each number in a consistent card, align baselines, and avoid five unequal
  tiles stretching across the screen.
- [ ] Cues uses compact grouped rows and a dense hot-cue grid. Empty slots are
  visually subordinate; the screen must not read as a form blown up to 1080p.
- [ ] Search uses the Apple Music keyboard/category hierarchy and shares the
  browse screen top origin, tile metrics, and restrained focus behavior.
- [ ] Loading and empty states are quiet inline states on the screen background;
  never put a spinner inside a near-full-screen light rectangle.

Primary files:

- `SoundingTV.swiftpm/Sources/Apps/tvOS/Features/Player/NowPlayingView.swift`
- `SoundingTV.swiftpm/Sources/Apps/tvOS/Features/Player/PlayerView.swift`
- `SoundingTV.swiftpm/Sources/Apps/tvOS/Features/Player/BehindTheTrackView.swift`
- `SoundingTV.swiftpm/Sources/Apps/tvOS/Features/Player/CueSheetView.swift`
- `SoundingTV.swiftpm/Sources/Apps/tvOS/Features/Search/SearchView.swift`
- `SoundingTV.swiftpm/Sources/Apps/tvOS/Design/GlassComponents.swift`

## Deterministic simulator states

Do not depend on the developer's live SoundCloud account for visual approval.
Add debug-only tvOS fixtures in the logical tvOS tree, not in the deleted
`DemoSeed.swift`, and activate them only through launch environment variables.
They must never persist credentials or demo data.

Required launch states:

| Environment | Result |
|---|---|
| `SOUNDING_TV_LIBRARY_SECTION=recentlyAdded` | populated mixed Library grid |
| `SOUNDING_TV_LIBRARY_SECTION=artists` | populated circular artist grid |
| `SOUNDING_TV_LIBRARY_SECTION=albums` | populated album grid |
| `SOUNDING_TV_LIBRARY_SECTION=playlists` | populated playlist grid |
| `SOUNDING_TV_LIBRARY_SECTION=songs` | populated songs list |
| `SOUNDING_TV_HOME_STATE=loaded` | stable Home editorial/square shelves |
| `SOUNDING_TV_FEED_STATE=loaded` | stable Feed heroes and modules |
| existing `loading / error / empty` values | status-state regression checks |

Put final 1920×1080 screenshots in `Design/reference/verify/tvos-ui/` with
names matching those states, plus `artist-detail.png`, `album-detail.png`, and
`playlist-detail.png`, `now-playing.png`, `behind-track.png`, `cues.png`, and
`search.png`. Capture one focused tile, hero, row, and chrome control state.

## Verification commands

Use the tvOS 27 simulator `SoundingTV-Verify27`
(`25655ABD-99B9-421C-9746-98F7234BEAA9`). Keep build output outside the repo.

```sh
xcrun sourcekit-lsp debug index --project .

xcodebuild \
  -project SoundingTV.xcodeproj \
  -scheme SoundingTV \
  -configuration Debug \
  -destination 'platform=tvOS Simulator,id=25655ABD-99B9-421C-9746-98F7234BEAA9' \
  -derivedDataPath /tmp/SoundingTV-tvOS-ui \
  CODE_SIGNING_ALLOWED=NO build

xcrun simctl bootstatus 25655ABD-99B9-421C-9746-98F7234BEAA9 -b
xcrun simctl install 25655ABD-99B9-421C-9746-98F7234BEAA9 \
  /tmp/SoundingTV-tvOS-ui/Build/Products/Debug-appletvsimulator/SoundingTV.app
xcrun simctl launch --terminate-running-process \
  25655ABD-99B9-421C-9746-98F7234BEAA9 red.forbes.sounding
xcrun simctl io 25655ABD-99B9-421C-9746-98F7234BEAA9 screenshot \
  /tmp/soundingtv-tvos.png
```

For launch-state variables, terminate first and use `simctl launch` with
`SIMCTL_CHILD_<NAME>=<value>` in the command environment.

After simulator approval, make a signed device build and deploy only the tvOS
target to the paired Apple TV:

```sh
xcodebuild \
  -project SoundingTV.xcodeproj \
  -scheme SoundingTV \
  -configuration Debug \
  -destination 'platform=tvOS,id=00008110-0006304002EB801E' \
  -derivedDataPath /tmp/SoundingTV-tvOS-device build

xcrun devicectl device install app \
  --device 00008110-0006304002EB801E \
  /tmp/SoundingTV-tvOS-device/Build/Products/Debug-appletvos/SoundingTV.app
xcrun devicectl device process launch \
  --device 00008110-0006304002EB801E \
  --terminate-existing red.forbes.sounding
```

## Definition of done

- [ ] Swift LSP index completes without errors.
- [ ] tvOS simulator build succeeds with signing disabled.
- [ ] All required loaded and status-state screenshots exist and were visually
  compared side-by-side with the Apple references.
- [ ] A remote focus walk covers rail → grid → detail → back, Home shelves, and
  Feed modules without traps, jumps, outlines, clipping, or lost selection.
- [ ] Focused/unfocused comparison captures show no orange ring, halo, washed-out
  labels, or generic shimmer pasted over rows and controls.
- [ ] VoiceOver labels distinguish artist, album, playlist, and track actions.
- [ ] `git diff --check` is clean.
- [ ] Signed tvOS device build installs and launches on `Living Room`.
- [ ] Physical-device smoke test confirms Library destinations, Home, Feed,
  playback, and back navigation.

## Resume order

1. Read this file and `Design/reference/appletv-music/OBSERVED.md`.
2. Run `git status --short`; preserve unrelated/user changes and the current
   source-tree migration.
3. Find the first unchecked phase above. Implement it and its fixtures.
4. Build, launch, capture, and visually compare before marking the phase done.
5. Continue through physical deployment; do not call the redesign complete on
   compile success alone.
