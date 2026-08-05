# Shared design-system adoption map — tasks #112, #114, #116

Written by the shared-design-system owner in the current backlog-sweep
session. **This is a map, not a migration** — per the owning tasks' scope
boundary, nothing in this pass touches a view file. Six other agents are
editing `SoundingTV-iOS/Sources/**`, `SoundingTV-macOS/Sources/**`,
`SoundingTV.swiftpm/Sources/Views/**` and the Services layer concurrently;
this document is what the main session hands to whoever picks up adoption
next, so they don't have to re-derive which call site maps to which shared
type.

**Read `SoundingTV.swiftpm/Sources/Design/ContentStyle.swift`'s header first**
— it explains why every shared type takes an explicit `SCContentStyle`
instead of reaching for `Space`/`Corner`/`Font.tv*`/`Color.sc*`/`AppClipDesign`
directly, and why that is a compilation requirement (three targets, only one
token file guaranteed to exist on all three), not a style preference.

Every substitution below is presentational only. Per `ContentStyle.swift`:
**interaction is not part of the shared contract.** A tvOS adoption still
wraps the shared view in its own `Button(...) { }.buttonStyle(SCCardButtonStyle())`
+ `.focusable()`/`.focused($…)`/`scFocus`; an iOS adoption keeps its own
`DragGesture`/press feedback; a macOS adoption keeps its own `.onHover`/
context menu. Only the content inside changes.

---

## 1. Waveform (#112, #114)

`SoundingTV.swiftpm/Sources/Design/WaveformRenderer.swift` → `SCWaveformRenderer`,
`SCWaveformStyle`, `SCWaveformMarker`, `SCBeatGrid`, `SCWaveformSampler`.

| Platform | File : type replaced | Substitution |
|---|---|---|
| tvOS | `SoundingTV.swiftpm/Sources/Views/Player/PlayerView.swift:1339` — `struct WaveformScrubber: View`, specifically its `draw(in:size:pulse:)` / `drawBars(in:size:pulse:)` / `drawFallback(in:size:)` methods (~lines 1595–1851) | Keep `WaveformScrubber` as the focusable/interactive shell (focus ring, `.onMoveCommand` scrub, cue placement, comment bubble, `PulseTimeline`) but replace its internal `Canvas { draw(...) }` with `SCWaveformRenderer(envelope: bars.map(Float.init)… , duration:, progress: displayedProgress, mode: .fixed, beatGrid: nil, cueMarkers: cues.sheet.entries.map { SCWaveformMarker(id: $0.id, position: $0.positionSeconds / duration, color: $0.color.color) }, commentMarkers: clusters.map { … }, playheadEmphasis: pulse.impact, pulseEnergy: pulse.energy, style: .tv)`. `WaveformScrubber`'s own `drawFallback` (the "sleeping bars" loading state) has no shared equivalent yet and should stay local — `SCWaveformRenderer` has no opinion on loading states, by design (see its header). |
| iOS | `SoundingTV-iOS/Sources/TransportBarView.swift:1939` — `private struct PhoneWaveformScrubber: View`, its `drawBars(in:size:pulse:)` (~2296–2395) | Same substitution as tvOS, `style: .phone`, `pulse.impact`/`pulse.energy` from the same `Pulse` type (`Services/WaveformService.swift`, already shared — both platforms already read the identical `MusicPulse.shared`). Keep `PhoneWaveformScrubber`'s variable-speed `DragGesture`, `LongPressGesture` cue placement, and scrub-rate badge untouched — those are interaction, out of the shared contract. |
| macOS | `SoundingTV-macOS/Sources/MacWaveformViews.swift:100` — `struct MacWaveformOverview: View` (whole-track thumbnail) | `SCWaveformRenderer(envelope:, duration:, progress:, mode: .fixed, style: .decks)`. Note `.decks`'s `shellDepths = [1.0, 0.62, 0.28]` already reproduces this file's nested-shell look; `MacWaveformOverview` currently draws only one flat shell, so adopting `.decks` here is a strict visual upgrade, not a like-for-like swap — flag that to the owner before landing. |
| macOS | `SoundingTV-macOS/Sources/MacWaveformViews.swift:159` — `struct MacWaveformDetail: View` (scrolling CDJ-style zoom, `drawBeatGrid`) | `SCWaveformRenderer(envelope:, duration:, progress:, mode: .centered(windowSeconds: 8), beatGrid: bpm.map { SCBeatGrid(bpm: $0) }, style: .decks)`. This is the closest of the four to a like-for-like swap — `.decks`'s shell colours, beat-grid tick weights/opacities and the centre-fixed playhead were all reverse-derived from this exact file. |

**#112 status.** `SCWaveformStyle` now carries `unplayedSheen`/`playedSheen`
(vertical glass-sheen gradients), `nearHighlightBase`/`nearHighlightGain`
(the near-playhead highlight wash), and `glowBaseOpacity`/`glowEnergyGain`
(energy-breathing glow), and `SCWaveformRenderer` takes a new `pulseEnergy`
parameter alongside the existing `playheadEmphasis`. These were derived by
reading `WaveformScrubber` and `PhoneWaveformScrubber`'s current
`drawBars` side by side — both already carry this exact treatment
independently (tvOS: `0.38 + 0.24 * pulse.energy`, `0.05 + 0.08 * pulse.impact`;
iOS: `0.34 + 0.22 * pulse.energy`, same impact formula) — so adopting
`SCWaveformRenderer` on tv/phone is a **behaviour-preserving** swap, not a
downgrade; the Decks preset opts out of all three (`nil`/`0`), preserving
`MacWaveformDetail`'s flat hard-edged look exactly. The one thing this
renderer does **not** yet replicate: `WaveformScrubber`'s honest "sleeping
bars" loading fallback and its focus-triggered scrub knob — those stay in
the per-platform shell, as noted in the table above.

---

## 2. Generated artwork / "colour blob" cards (#116)

`SoundingTV.swiftpm/Sources/Design/GeneratedArtwork.swift` →
`GeneratedArtworkCard`, `GeneratedGradient`, `GeneratedArtworkGlyph`.

| Platform | File : type replaced | Substitution |
|---|---|---|
| tvOS | `SoundingTV.swiftpm/Sources/Views/Search/SearchView.swift:328` — `private struct GenreTileButton: View`, plus its whole `private enum GenreTilePalette` (hue table + `color(for:)`/`icon(for:)`, ~lines 371 onward) | Replace the `ZStack { GenreTilePalette.color(for: genre); Image(systemName: …).opacity(0.18)… }` body with `GeneratedArtworkCard(identity: GenreProfile.of(genre).displayName, mode: .blob, style: .tv)`. This is the single best adoption target in the app: hand-rolled deterministic hue-from-genre-family + oversized rotated glyph is *exactly* what `GeneratedArtworkCard`/`GeneratedGradient` already do, just duplicated. Keep `GenreTilePalette`'s `familyHue` table only if the owner wants genre-family-clustered hues specifically (adjacent genres landing near each other on the wheel) — `GeneratedArtworkIdentity.hue(for:)` is a pure string hash instead, which will assign unrelated hues to e.g. "Techno" and "Trance". Flag this trade-off rather than silently picking one. |
| tvOS | `SoundingTV.swiftpm/Sources/Views/Components/ArtworkImage.swift` and every call site that falls back to a system-grey placeholder when a URL fails to load or is `nil` | Wrap `ArtworkImage` (which owns request coalescing/resolution upgrading — keep that) so its failure/`nil` branch renders `GeneratedArtworkCard(identity: track.title, mode: .blob, style: .tv)` instead of nothing/grey. |
| iOS | `SoundingTV-iOS/Sources/LibraryBrowserView.swift:1538` — `struct ArtworkThumbnail: View`, its `default:` `AsyncImage` phase (grey `Color.primary.opacity(0.08)` + `systemImage`) | `SCArtwork(image: nil, identity: <title>, isAvailable:, style: .phone)` in place of the whole `ZStack { Color.primary.opacity(0.08); Image(systemName: …) }` block — `SCArtwork` already falls back to `GeneratedArtworkCard(mode: .blob)` internally (see `ContentComponents.swift`), so this one substitution gets both the artwork-loading *and* the generated-fallback problem in one move. |
| macOS | `SoundingTV-macOS/Sources/MacHomeView.swift:572` (`HomeTrackTile.artworkTile`) and the equivalent pattern in `MacLibraryBrowserView.swift`/`MacPlaylistDetailView.swift`/`MacSearchView.swift` — every `Rectangle().fill(Color.primary.opacity(0.08))` fallback | `SCArtwork(image: artwork.map(Image.init(nsImage:)), identity: track.title, isAvailable: isPlayable, style: .mac)`. Note: `HomeTrackTile` currently marks unavailable with a `lock.fill` glyph over a black scrim; `SCArtwork` uses `slash.circle` — same affordance, different glyph. Pick one and update whichever loses; don't let both ship (a locked track must read identically wherever it appears, per `CLAUDE.md`'s content-components law). |
| All three | Any shelf that mixes real cover art with category/mood tiles that have no art at all (tvOS "Browse Categories"-style rows once built, a future iOS/macOS equivalent) | `GeneratedArtworkCard(identity:, mode: .duotone(artworkImage), style:)` for tiles that *do* have art but need to read as a category tile rather than a literal photo — see that file's header for the reference screenshots this was measured against (`Design/reference/macos-glass/Screenshot 2026-08-03 at 21.20.50.png`). No current call site does this yet; it's new surface, not a replacement. |

---

## 3. Content components (#114) — rows, cards, headers, empty states

`SoundingTV.swiftpm/Sources/Design/ContentComponents.swift` → `SCArtwork`,
`SCSectionHeader`, `SCTrackRow`, `SCMediaCard`, `SCHeroCard`, `SCEmptyState`.

| Shared type | Platform : file : type replaced | Notes |
|---|---|---|
| `SCTrackRow` | tvOS: `SoundingTV.swiftpm/Sources/Views/Components/TrackListView.swift:208` — `private struct TrackRow: View` | Its artwork is already `84×84` — identical to `SCContentStyle.tv.rowArtworkSize`, confirming the preset was tuned against this exact call site. Its `Label(badge, systemImage: "waveform")` string (see §4) becomes `SCAnalysisBadgeRow`. |
| `SCTrackRow` | iOS: `SoundingTV-iOS/Sources/LibraryBrowserView.swift:1196` — `struct TrackRow: View`, and `:1148` `struct TrackListRow: View` | Two near-duplicate row types in one file already — a second, smaller instance of exactly the fragmentation task #114 exists to close, even before crossing platforms. |
| `SCTrackRow` | iOS: `SoundingTV-iOS/Sources/FeedView.swift:369` — `private struct FeedTrackRow: View` | Feed-specific trailing content (like/repost affordances) fits `SCTrackRow`'s `@ViewBuilder trailing` slot. |
| `SCTrackRow` | iOS: `SoundingTV-iOS/Sources/QueueManagerView.swift:221` — `private struct QueueRow: View` | Trailing slot: drag handle / remove button. |
| `SCTrackRow` | macOS: `SoundingTV-macOS/Sources/MacLibraryBrowserView.swift:526` — `struct MacLibraryTable: View`'s per-row content | macOS's is a `Table` column, not a free-standing row view — adopting `SCTrackRow` here means using it *inside* a `TableColumn`'s content closure, not replacing the `Table` itself (macOS keeps its own sortable-column chrome; only the row's internal layout unifies). |
| `SCMediaCard` | tvOS: `SoundingTV.swiftpm/Sources/Views/Home/HomeView.swift:295` — `struct TrackShelf: View` / `:390` `private struct ShelfArtwork: View` | |
| `SCMediaCard` | iOS: `SoundingTV-iOS/Sources/LibraryBrowserView.swift:268` — `private struct RecentlyAddedTile: View` | |
| `SCMediaCard` | macOS: `SoundingTV-macOS/Sources/MacHomeView.swift:572` — `private struct HomeTrackTile: View` (whole card, not just its artwork — see §2) | |
| `SCHeroCard` | tvOS: `SoundingTV.swiftpm/Sources/Views/Home/HomeView.swift:229` — `private struct HeroBackground: View` | |
| `SCSectionHeader` | tvOS: inline title/eyebrow `Text` pairs in `HomeView.swift`/`LibraryView.swift`/`FeedView.swift` (no single extracted type today — grep `\.uppercased()` near a `Text(title)` in those files) | No existing named type to point at; this is new consolidation, not a rename. |
| `SCSectionHeader` | iOS/macOS: `AppClipDesign.swift:479` — `struct ScSectionHeader: View` (iOS's own, already extracted) already matches this shape closely | Closest existing 1:1 match of any row in this table — mostly a rename + restyle, not a redesign. |
| `SCEmptyState` | iOS: `SoundingTV-iOS/Sources/LibraryBrowserView.swift:1594` — `struct StateMessage<Action: View>: View`, and `:1571` `struct LoadingState: View` | |
| `SCEmptyState` | iOS: `SoundingTV-iOS/Sources/FeedView.swift:741` — `private struct FeedStateMessage<Action: View>: View` | Third near-duplicate empty-state type found in iOS alone. |
| `SCEmptyState` | iOS: `SoundingTV-iOS/Sources/QueueManagerView.swift:296` — `private struct MessageState<Action: View>: View` | Fourth. |
| — (do not adopt) | tvOS: `StatusPanel` (`GlassComponents.swift`, tvOS-only) | Per `ContentComponents.swift`'s own header: tvOS's focus-enterability guarantee is load-bearing there (an empty focus region strands the remote cursor). Keep `StatusPanel` on tvOS; `SCEmptyState` has no focus wiring at all. |

**Fragmentation found, not just cross-platform.** iOS alone has three
separate "empty/loading state" types (`StateMessage`, `LoadingState`,
`FeedStateMessage`, `MessageState` — four, actually) and two near-duplicate
track-row types (`TrackRow`, `TrackListRow`). Adopting `SCEmptyState`/
`SCTrackRow` collapses same-platform duplication as a side effect, not only
cross-platform duplication — worth calling out to whoever picks this up,
since it's a bigger win than the task's framing (three platforms) suggests.

---

## 4. Analysis badges (#114)

`SoundingTV.swiftpm/Sources/Design/AnalysisBadge.swift` → `SCAnalysisBadge`,
`SCAnalysisBadgeRow`, `SCAnalysisProvenance`, `SCAnalysisKind`.

**No platform currently distinguishes measured from inferred visually** —
all three render BPM/key/genre as one concatenated string, "128 BPM · 8A ·
House", with no indication of confidence. This is the strongest gap
`SCAnalysisBadge` closes (see `AnalysisBadge.swift`'s header for the
0.058-mean-confidence genre finding in `CLAUDE.md` this exists to make
visible): adopting it is not just a style unification, it fixes a real
"guess presented as a reading" defect.

| Platform | File : call site |
|---|---|
| tvOS | `SoundingTV.swiftpm/Sources/Views/Components/TrackListView.swift:265` — the `analysisBadge` computed property building `"128 BPM · 8A · House"`, consumed by `TrackRow`'s `Label(badge, systemImage: "waveform")` (~line 232) |
| iOS | `SoundingTV-iOS/Sources/LibraryBrowserView.swift:1457` — same string-building pattern, `"128 BPM · 8A · House"` |
| macOS | `SoundingTV-macOS/Sources/MacLibraryBrowserView.swift` — `LibraryRow.bpmKey`/`genreKey` (~174–182) feed `MacLibraryTable`'s sortable columns; badge *rendering* (as opposed to the sort keys) is presumably in the row's cell view — not located precisely in this pass, flag for the adopting agent to grep `MacLibraryTable`'s `TableColumn` closures |

Each of these needs `AnalysisLookup`/`AnalysisCache`'s own confidence value
translated into `SCAnalysisProvenance` (`.measured` vs `.inferred` vs
`.unavailable`) at the call site — `SCAnalysisBadge` deliberately has no
opinion on where that comes from (see its header: "does not import
`MusicUnderstanding`… never sees a confidence float"). That threshold
decision (what confidence counts as "measured" vs "inferred") belongs to
whoever owns `AnalysisLookup`, not to this file.

---

## 5. Design tokens (#114)

`SoundingTV.swiftpm/Sources/Design/ContentStyle.swift` → `SCContentStyle`
(`.tv` / `.phone` / `.mac` / `.decksConsole` presets),
`SoundingTV.swiftpm/Sources/Design/Tokens.swift` → `SCAmbient` (artwork-palette
contrast, already shared between tvOS `DesignSystem.swift` and iOS
`AppClipDesign.swift` — see that file's own "SHARED CONTRACT" block; no
action needed there beyond what already exists).

This layer is **additive, not a replacement** for the three existing token
files (`SoundingTV.swiftpm/Sources/Design/DesignSystem.swift` tvOS,
`SoundingTV-AppClip/Sources/AppClipDesign.swift` iOS, and macOS's ad hoc
`Color.primary`/`.secondary` usage). Per `ContentStyle.swift`'s header, chrome
(tab bars, nav titles, the tvOS sidebar, macOS's toolbar) keeps reading its
own platform's token file — only components built from the *shared* content
types in §§1–4 take `SCContentStyle`. Do not attempt to delete
`DesignSystem.swift`/`AppClipDesign.swift`'s `Space`/`Corner`/`Font.tv*`
tables; they still back every piece of platform chrome and every existing
non-adopted view.

`SCContentStyle.decksConsole` is the one preset with no existing token file
to mirror — macOS's Decks console currently hand-picks values per file
(`MacDeckPanel.swift`, `MacMixerControls.swift`, etc.). Adopting it there is
new consolidation, same caveat as `SCSectionHeader` on tvOS above.

## 6. Motion (#114)

`SoundingTV.swiftpm/Sources/Design/ContentStyle.swift` → `SCContentMotion`
(`.press` / `.focus` / `.settle` / `.ambient`).

Deliberately a **new name**, not `Motion` — `Motion` already exists once in
`DesignSystem.swift` (tvOS-only) and once in `AppClipDesign.swift` (iOS-only)
for *chrome* motion, which legitimately stays platform-specific per
`CLAUDE.md`'s "chrome follows the platform" law. `SCContentMotion` is for
motion on the shared *content* components in §§1–4 only — a call site
animating `SCTrackRow`'s appearance, `GeneratedArtworkCard`'s idle drift, or
a waveform crossfade uses `SCContentMotion`; a call site animating a tab
switch, a sidebar collapse, or a sheet presentation keeps using its own
platform's `Motion.*`. No existing call site needs migrating for #114's
motion piece specifically — it's new API for the new shared components to
use, most of which (`GeneratedArtworkCard`'s drift) already does.

---

## What was NOT done in this pass, and why

- **No view file was edited.** Per the owning tasks' explicit scope boundary
  — five other agents are inside the view/service layers concurrently.
- **No `project.pbxproj` edit.** The five new files below are not yet
  registered in any target; they will not compile as part of an app build
  until the main session adds them. See the parent report's "NEW FILES TO
  REGISTER" section for exact target membership.
- **The macOS badge call site (§4)** was not pinned to an exact line —
  `MacLibraryTable`'s cell-rendering closures are large and the badge string
  wasn't isolated with confidence in the time this pass had. Grep
  `MacLibraryTable` for a BPM/key/genre string build before adopting.
- **The tvOS/iOS "loading" and "sleeping bars" waveform fallback states**
  have no shared equivalent — `SCWaveformRenderer` takes a stance ("an empty
  envelope renders an empty lane; the loading affordance around it is the
  caller's job") rather than reproducing three different loading treatments.
  If the owner wants one shared loading treatment too, that's new scope, not
  covered by #112/#114 as briefed.
