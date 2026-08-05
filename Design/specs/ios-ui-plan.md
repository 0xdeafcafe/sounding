# iOS Apple Music alignment — implementation plan

Status: queued after the active tvOS structural pass, 2026-08-04.

This is the durable follow-on plan for closing the remaining gap between the
iPhone app and Apple Music on iOS. It consumes the same content hierarchy as
the tvOS work but uses iPhone-native navigation, sheets, safe areas, and compact
player behavior.

## Ground truth

- `Design/reference/apple-music-ios/OBSERVED.md`
- `Design/reference/apple-music-ios/IMG_9248.jpeg` through `IMG_9253.jpeg`
- `Design/specs/ios-design-spec.md`
- tvOS content/focus decisions in `Design/specs/tvos-ui-plan.md`

## Phase 1 — app shell and content grammar

- [ ] Unify page margins, section spacing, type scale, artwork radii, separators,
  and artwork-derived backgrounds in shared iOS tokens.
- [ ] Keep glass for navigation/player chrome. Content cards remain opaque and
  readable rather than turning every row into a glass capsule.
- [ ] Match Apple Music's navigation-title collapse, tab bar, sheet detents, and
  safe-area behavior on the 402×874pt reference viewport and smaller phones.
- [ ] Keep SoundCloud orange as selective action/brand emphasis, not a border
  around every selected or interactive element.

Primary files:

- `SoundingTV-iOS/Sources/App/PhoneRootView.swift`
- `SoundingTV-iOS/Sources/Design/`
- `SoundingTV.swiftpm/Sources/Shared/Design/`

## Phase 2 — mini player and Now Playing

- [ ] Rebuild the mini player as one compact bar with stable artwork, bounded
  title/artist, play/pause, and an expansion target. Remove excess padding,
  competing capsules, and layout jumps between connection/playback states.
- [ ] Match the Apple Music Now Playing vertical rhythm: artwork, metadata,
  timeline, transport, secondary controls, then queue/lyrics-style destinations.
- [ ] Preserve SoundCloud waveform/comment personality without making the
  waveform compete with transport or clipping long metadata.
- [ ] Verify swipe-to-expand/dismiss, skip gestures, Dynamic Type, Reduce Motion,
  and no-current-track behavior.

Primary files:

- `SoundingTV-iOS/Sources/Playback/TransportBarView.swift`
- `SoundingTV-iOS/Sources/Playback/PhonePlaybackCoordinator.swift`
- `SoundingTV-iOS/Sources/Features/Queue/QueueManagerView.swift`

## Phase 3 — Home, Feed, Search, and Library

- [ ] Apply the tvOS content taxonomy consistently: Recently Added, Artists,
  Albums, Songs, Playlists, and Following where SoundCloud-specific.
- [ ] Home alternates editorial reasons with dense media shelves; Feed keeps
  repost attribution but uses compact Apple Music-style rows/cards.
- [ ] Artist, album, and playlist destinations share artwork/metadata/action
  ordering and have intentional compact/regular-width adaptations.
- [ ] Search uses Apple Music's field, recent-search, category, result-section,
  and empty/loading hierarchy.

Primary files:

- `SoundingTV-iOS/Sources/Features/Home/PhoneHomeView.swift`
- `SoundingTV-iOS/Sources/Features/Feed/FeedView.swift`
- `SoundingTV-iOS/Sources/Features/Search/GlobalSearchView.swift`
- `SoundingTV-iOS/Sources/Features/Library/LibraryBrowserView.swift`
- `SoundingTV-iOS/Sources/Features/Library/ArtistDetailView.swift`
- `SoundingTV-iOS/Sources/Features/Library/PlaylistDetailView.swift`

## Acceptance matrix

- [ ] Capture Home, Feed, Search, each Library root, artist, album, playlist,
  mini player, expanded Now Playing, queue, loading, empty, error, and signed-out
  states at 402×874pt.
- [ ] Capture mini player and Now Playing with short/missing/very long metadata.
- [ ] Compare side-by-side with all six Apple Music iOS references.
- [ ] Run Swift LSP indexing and signed iOS simulator/device builds.
- [ ] Walk VoiceOver, Dynamic Type, Reduce Motion, dark appearance, tab changes,
  player expansion/dismissal, and auth/pairing overlays.
- [ ] Deploy to `iPhone van Alexander` only after the visual and interaction pass.

## Resume rule

Do not start by recolouring individual screens. First finish the shell/tokens,
then mini player/Now Playing, then browse and destination screens. A phase is
complete only when its screenshot matrix has been visually compared with the
Apple references on an iPhone simulator and the physical phone.
