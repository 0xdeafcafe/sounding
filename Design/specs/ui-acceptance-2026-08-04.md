# UI acceptance ledger — 2026-08-04

This is the acceptance list for the owner’s macOS/iOS/tvOS review. It is
separate from `BACKLOG.md`: that file tracks architecture and product work;
this one tracks the concrete behaviour and visual defects reported during the
live UI pass.

Status:

- `[ ]` open
- `[-]` implemented or partially implemented, awaiting live visual/interaction verification
- `[x]` verified in a fresh build and in the running app where interaction matters

## App identity and colour

- [ ] Ship a real, branded AppIcon for macOS, iOS, tvOS, watchOS and extension
  targets that surface an icon; verify each target’s asset/build setting.
- [-] Use Sounding orange as the product accent for selection, active
  state and meaningful actions.
- [-] Keep neutral toolbar/view/filter/overflow controls neutral; do not tint
  every utility icon orange.
- [ ] Replace unavailable, visually odd or semantically wrong SF Symbols.

## Navigation and chrome — all apps

- [ ] Remove the standalone Stream destination and fold the feed into Home.
- [ ] On iOS, use Companion as the primary tab in Stream’s former place.
- [ ] Give Search a useful default/empty page and a quiet cache-first loading
  state on macOS, iOS and tvOS.
- [ ] Keep search centred in macOS title-bar chrome; prevent it colliding with
  sidebar/queue/view buttons at narrow widths.
- [ ] Normalize sidebar icon size, optical alignment and label baseline.
- [ ] Make playlist groups collapsible and preserve collapse state.
- [ ] Treat Library as a sidebar section, not a selectable pseudo-table.
- [ ] Add clear scanning/syncing feedback in the sidebar/account footer.
- [ ] Restore standard macOS window chrome and traffic-light/title-bar behaviour
  in the Settings window.

## macOS library, playlists and tables

- [ ] Put the centred in-view search in title-bar chrome and keep distinct,
  neutral View and Filter controls on the trailing side.
- [ ] Remove the redundant leading list/queue toolbar button; queue is opened
  from the player’s queue control.
- [ ] Make the library overflow menu complete and reliable on all library views.
- [ ] Give playlist views useful pin, download, Play Next, share, window, view,
  filter and sort actions where applicable.
- [ ] Replace the ambiguous orange download-looking Decks control with clear
  Deck A (left) and Deck B (right) actions, with a labelled column.
- [ ] Make rows clickable across their useful width; keep buttons and context
  menus reachable without stealing row selection.
- [ ] Support column customization and sorting for BPM/tempo, key, genre,
  beats, duration, date and other available analysis fields.
- [ ] Support a compact table mode when artwork is hidden.
- [ ] Virtualize large collections and eliminate scroll/selection lag.
- [ ] Fix table leading padding, title/art alignment, clipped time cells and
  inconsistent genre rendering everywhere.
- [ ] Fix card/text clipping everywhere, including playlist artwork captions.
- [-] Align the Playlists title, sections and grid to one content column.
- [-] Hydrate Albums from real cached/fetched SoundCloud album collections;
  never fabricate albums and never flash a false empty state.
- [-] Add generated Sets to every applicable library surface using cached
  long-form tracks (45+ minutes by default), with a shared configurable
  duration threshold in standard platform Settings.
- [ ] Explain album availability accurately: hydrate real SoundCloud album-kind
  collections and distinguish empty, unavailable and SoundCloud Go-gated data.
- [ ] Use the same three-state track-row interaction everywhere: neutral,
  full-width hover with play affordance, and full-width selected/active state.
- [ ] Mark a selected track as loading/playing immediately in every track list,
  before enough audio has buffered to begin playback.
- [ ] Replace top-level “Load More” with background pagination and an inline
  end-of-table progress indicator that never overlaps the player.
- [-] Make Music Intelligence summary-first and Mac-like; verify the remaining
  disclosure/detail density live.

## macOS now playing bar and waveform

- [ ] Reduce the bar height and give it consistent outer/inner padding.
- [ ] Give the playing region most of the width: artwork at one end, time at
  the other, waveform filling the full available middle width and height.
- [ ] Use real amplitude variance; avoid uniform fence-post waveforms and
  avoid compressing all data into one end of the range.
- [ ] Make the waveform a reliable scrub target with a generous hit area and
  visible playhead/drag feedback.
- [x] Prevent waveform played/playhead glow from clipping at renderer bounds on
  macOS, iOS and tvOS.
- [ ] Hide or aggregate waveform comment avatars when density becomes noisy.
- [ ] Clicking a waveform comment opens Comments, scrolls to the matching
  comment and highlights it.
- [ ] Keep transport and utility buttons at standard Mac sizes with at least a
  44-point effective hit target where feasible.
- [ ] Keep enough safe-area/padding below the floating bar; it must not cover
  table pagination or content.

## Now Playing presentation, queue and detail panes

- [ ] Present the full player as a stable app-style rising pane; artwork and
  controls must animate as one surface without flying into the album cover.
- [ ] Keep the presenting page’s buttons/artwork from ghosting through or
  remaining pinned during presentation.
- [ ] Make Close visibly enabled with a large hit target; support Escape.
- [ ] Support a two-finger downward scroll/drag on the background or artwork to
  dismiss the full-player pane.
- [ ] In non-development builds, enforce exactly one music window/presentation:
  full and mini players must replace each other, never coexist.
- [ ] Prevent the AppKit toolbar/update-constraints crash when opening queue or
  now-playing surfaces.
- [ ] Make the queue panel vibrant from the window/artwork while keeping text
  contrast accessible.
- [-] Include Playback History above Continue Playing with separate clear
  actions.
- [ ] Include subtle Up Next access from the main player without relying on the
  overflow menu.
- [ ] Keep AutoMix/Auto DJ text readable in every artwork palette; style DJ
  profile selection as a real control with good padding.
- [ ] Improve queue rows, buttons, colours and spacing; no oversized empty pane.
- [ ] Redesign Comments with threading/nesting and search by mentioned track.
- [ ] For waveform markers, navigate to and highlight their comments.
- [ ] Run tracklist detection only for eligible DJ mixes and explain that
  quietly for other tracks.
- [ ] Handle unavailable Shazam/recognition without exposing raw framework
  errors such as `com.apple.ShazamCore error 102`.
- [ ] Redesign About and Tracklist detail views so they are cohesive rather
  than isolated cards/info dumps.

## Loading, cache and background sync

- [ ] Never replace useful cached Home/Search/Library content with a transient
  initial error or empty state while live data is loading.
- [ ] Preload/cache commonly selected sidebar destinations to avoid repeated
  distracting spinners.
- [ ] Persist and background-refresh metadata for all likes, playlists, sets,
  albums, artists, stations and saved collections across apps.
- [ ] Continue pagination in the background over time until the complete saved
  metadata collection is in the database.
- [ ] Do not download track audio unless the user explicitly asks or enables an
  applicable offline policy.
- [ ] Give background sync/scanning a subtle status, retry and last-success UI.

## Settings

- [ ] macOS Settings must use standard Mac settings chrome/layout and expose
  every applicable iOS option plus session sync.
- [ ] iOS Settings must remain standard iOS `List`/`Form` settings UI.
- [-] Replace the bespoke/awkward Downloads manager with standard grouped
  sections, clear policy, progress, storage and per-item actions.
- [ ] Make storage limit and quality controls self-explanatory and native; no
  giant stepper arrows or dense diagnostic card.
- [ ] Keep account/session sync actionable without raw provisioning errors in
  normal product UI.

## Interaction and regression verification

- [ ] Live-run the macOS app throughout the pass with a fresh derived-data build.
- [ ] Regression-test opening/closing Queue, Comments, Tracklist, About, full
  Now Playing and mini player repeatedly without crash or duplicate windows.
- [ ] Build macOS, iOS, tvOS and affected extension/watch targets from clean
  derived-data directories.
- [ ] Validate narrow and wide macOS windows for toolbar collision, clipping,
  table compaction and player layout.
