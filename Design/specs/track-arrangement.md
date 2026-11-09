# Track arrangement: musical roles per bar

`TrackArrangement` (`SoundingTV.swiftpm/Sources/Core/DJ/TrackArrangement.swift`) says what each bar of a track is for a DJ: intro, groove, breakdown, build, the opening of a drop, the later groove of a drop, a vocal hook, or the outro. Each role carries a confidence. It replaces the duration-based labelling in `DJSessionDirector.classifyStructure` (first and last 12 % called intro and outro, every phrase treated as a section).

Owner rules it serves: never mix over meaty or vocal peaks, never double-drop, and "74 % leave from a drop" means the full-energy groove later in a drop, not its first bars.

## API

| Member | Meaning |
|---|---|
| `TrackArrangement.build(_ tracked: BeatTrackerResult, ai: AIAudioAnalysisResult?) -> TrackArrangement?` | Builds from the cached tracker result. Uses the Beat This! grid when `ai.isGridTrusted`, and Open-Unmix vocal, drums-only and bass spans when `ai.stems` is present. Returns nil without a `BarProfile` or with fewer than 16 bars. |
| `TrackArrangement.cached(trackId:tracked:ai:)` | Same, memoised in process (64 entries, keyed by track, `TrackArrangement.version`, tracker version, grid and evidence fingerprint). |
| `build(_:evidence:)` | The underlying builder. `Evidence` carries optional vocal, drums-only and bass spans and their source; harnesses use it directly. |
| `barStarts: [Double]` | Downbeat times in seconds, one per bar. `bar(at:)` maps seconds to a bar. |
| `intervals: [Interval]` | Contiguous, non-overlapping `{role, bars: Range<Int>, confidence: Float}` covering every analysed bar. `interval(atBar:)`, `role(atBar:)`, `role(at:)`. |
| `boundaries: [Boundary]` | `{bar, confidence, isSection}`. Section boundaries are where the arrangement changes; the rest are 8-bar phrase lines with lower confidence. Confidence already includes grid confidence. |
| `vocal: [Float?]` | Per bar, the share of the bar with vocals (0–1). `nil` means not measured: that bar's vocals are unknown, never instrumental. `vocal(atBar:)`. |
| `density: [Float]` | Per-bar onset density rank (0–1) from `BarProfile`. |
| `coverage` | `bars`, `grid` (beatTracker or beatThis), `gridConfidence`, `vocals` (soundAnalysis, openUnmix or nil = unknown), `vocalBars` (bars with measured vocals), `drums` (openUnmix or nil). |
| `isPeak(bars:) -> Bool?` | True if any bar in the range is a drop opening or a vocal hook. False only when vocals are measured for every bar in the range and neither holds. Nil when vocals are unknown and no peak was found: unknown never means safe. The per-bar `vocal` share stays available to the separate vocal-collision rails. |
| `sections(duration:) -> [TrackSection]` | The intervals as today's `SectionKind`s, for code that still reads `TrackFeatures.sections`. |

### Roles

| Role | `SectionKind` | Safe to overlap? |
|---|---|---|
| `introDrums`: intro with a usable beat | `.intro` | yes |
| `introQuiet`: beatless, dull or quiet intro | `.ambientIntro` | entry only, skip if long |
| `groove`: body without a preceding breakdown | `.bridge` | yes |
| `breakdown` | `.breakdown` | no exit into it |
| `build`: rising tail of a breakdown, leads into the drop | `.buildup` | no |
| `dropOpening`: first ~16 bars after a breakdown/build | `.drop` | **no (peak)** |
| `dropGroove`: the rest of that drop | `.drop` | yes |
| `vocalHook`: ≥ 4 bars of vocals over body level in a groove or drop groove | `.drop` | **no (peak)**; lyric loops only as a complete phrase |
| `outroUsable`: tail with a beat, ≥ 4 bars | `.outro` | yes |
| `outroDead`: beatless or quiet tail | `.ambientOutro` | no |

## Evidence and method

All inputs are already cached on every device; no extra audio pass.
1. **Per bar** from `BarProfile`: level (dB), the four bands (30–150 Hz, 150 Hz–1 kHz, 1–5 kHz, 5–11 kHz), onset density rank, 8-bar repetition (`loop8`). Body level is the 75th percentile of bar levels; band levels are relative to their median over body bars.
2. **Level class** per bar, from 3-bar running means: dead (24 dB under body); dip (6 dB under body, or low band 6 dB under, or sparse: density ≤ 0.25 and 3 dB under; with Open-Unmix, a missing bass stem also counts once the low band is 3 dB under); body (within 3 dB, low band within 3 dB); else mid.
3. **Boundaries**: level-class changes held for 2 bars, the tracker's `sectionStarts` (wired here, not every phrase), and novelty peaks of a 4-bar checkerboard over level, low, high and density (self-similarity). Snapped to the 4-bar grid when the grid is trusted. Segments under 3 bars merge.
4. **Roles**: dips shorter than 4 bars between louder segments are fills and stay in the groove. Segments before the first 4-bar body segment are intro (drums if density ≥ 0.15, within 15 dB and low band within 9 dB, or Open-Unmix drums-only); after the last, outro (usable under the same test and ≥ 4 bars). In between, dips are breakdowns, with a rising 4–8-bar tail (+3 dB level or high band) split off as a build; a mid-level segment of ≤ 8 bars between a breakdown and the body is also a build. A body segment after ≥ 4 breakdown or build bars is a drop: its first 16 bars are the opening, and everything until the next breakdown is drop groove. The first body after a beatless intro of ≥ 8 bars is a drop too; after a shorter pickup it is groove. Other body is groove; its confidence rises with `loop8`.
5. **Vocal hooks**: inside groove or drop groove, runs of ≥ 4 bars where the 4-bar running mean of hook strength is ≥ 0.5 and the level is within 4 dB of body, bridging gaps of up to 2 bars. Hook strength is the Open-Unmix vocal share when present; otherwise the SoundAnalysis share capped by the bar's mean vocal-curve value ÷ 0.5, so faint sustained "vocals" (synths, chants) don't count; otherwise unknown.

## Cost and cache

- **Cost**: 0.16 ms per track on the Mac (mean of 6,260 builds over the 313-track corpus), 0.004 % of the beat tracker's own cost (69× realtime here: 1,303 s of decode and features plus 6 s of analysis for 25.1 h of audio). Encoded, a 92-bar arrangement is 2.5 KB. It reads the cached `BeatTrackerResult` only, so iPhone and Apple TV pay nothing beyond today's tracker, and nothing on the TV changes when MusicUnderstanding is off.
- **Cache and version**: `TrackArrangement.version` (1). Inputs are cached by the tracker (`BeatTracker.version` in the analysis cache key); `cached(trackId:tracked:ai:)` memoises the derivation. A new version only needs a re-derive, never a re-analysis.

## Results (2026-11-09)

**Ground truth.** 67 tracks from the shared corpus (`automix-corpus/tracks.tsv`, 313 tracks, 25 h), spread across hard techno, techno, house, trance, Eurodance edits, pop remixes and disco. Each was annotated per bar by a separate annotator working only from the evidence plot (`<id>-plain.png`: level, four bands, density, repetition and the SoundAnalysis vocal curve), never from the algorithm's output, following `/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/arrangement/RUBRIC.md` (annotations in `annotations-{A,B1,B2,C}.json` beside it). **Every annotation is an estimate from plots, not a listening judgement.** Vocal-hook truth reads the same SoundAnalysis curve the builder uses, so hook numbers test the run logic more than vocal detection.

The algorithm was tuned on batches B1, B2 and C (47 tracks). Batch A (20 tracks) was scored once, after tuning.

"Unsafe" windows are annotated drop openings and vocal hooks (the owner's peaks). A **false negative** is an unsafe window where under half the bars are flagged by `isPeak`. An **unnecessary refusal** is a safe bar (intro with drums, groove, drop groove, usable outro) flagged as a peak.

| | Peaks/hooks missed | Bar recall | Safe bars refused | Safe ≥ 8-bar windows mostly refused | Role accuracy (exact / coarse) | Section boundaries ±2 bars (P / R) |
|---|---|---|---|---|---|---|
| **TrackArrangement, held-out (A, 20)** | **5 / 63** | 92 % | **5 %** | 4 / 77 | 74 % / 82 % | 79 % / 74 % |
| TrackArrangement, tuning set (47) | 18 / 147 | 83 % | 7 % | 15 / 178 | 71 % / 79 % | 75 % / 73 % |
| TrackArrangement, all 67 | 23 / 210 | 85 % | 7 % | 19 / 255 | 72 % / 80 % | 76 % / 73 % |
| Today's `meatyBars` peak rule, all 67 | 41 / 210 | 79 % | 17 % | 49 / 255 | — | — |
| Legacy `classifyStructure` (loud phrase = drop), all 67 | 174 / 210 | 13 % | 6 % | 15 / 255 | 40 % / 60 % | 53 % / 46 % |

On the held-out set today's peak rule misses 13 / 63 and refuses 12 % of safe bars.

Remaining misses: vocal hooks the SoundAnalysis curve barely sees (c095, c117, c227, c272, c300), drops after a 4-bar kick-out that the builder treats as a fill (c214, c277), and drops whose preceding breakdown is shallow (c138, c208, c219, c297). Remaining refusals are mostly the first body after a short quiet intro, which annotators split between "drop" and "groove". Intro end is off by 14 bars on average: when a track opens near body level, where the intro stops is a phrase guess for annotators and the builder alike.

**Open-Unmix stems** were only available for 3 annotated tracks (the Mac MLX harness no longer links against Homebrew's current `mlx-c`). On those, stems found every peak (0 / 8 missed, 1 / 8 without stems) but refused 8 % of safe bars against 1 %. Too small a sample to call; the cheap path is the reference.

PNGs: `/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/arrangement/lab/png/<id>-roles.png` show truth, the new roles and the AI roles over the evidence.

## Owner decisions

- **Short quiet intros.** The first body after a beatless intro of 8 or more bars counts as a drop, so Auto Mix won't land a long overlap on it. 16 bars would refuse fewer entries (6 % against 7 %) but miss two more drops in 47 tracks. Recommendation: keep 8 until listening says otherwise.

## Tooling

`tools/ArrangementLab/run.sh <out dir> <mode>`, compiled with `swiftc` from the app's `BeatTracker`, `BeatTrackerCore`, `AIAudioAnalysis` and `TrackArrangement` sources. Mac only.
- `analyse <tracks.tsv>`: runs the tracker over the corpus into the shared cache (`automix-corpus/cache/beattracker-v2/`, keyed by path, mtime and `BeatTracker.version`).
- `plot`: two PNGs per track, `-plain` (evidence only, for annotating) and `-roles` (truth, new, AI strips).
- `score [ai]` (annotation sets chosen with `ANNOTATION_SETS=A,B1,B2,C`): per-bar role accuracy, boundary precision and recall, unsafe-window false negatives and unnecessary refusals, against the legacy labeller and today's `meatyBars` rule.
- `ai <dir>`: attach Open-Unmix stems (`stems-<id>.json` from `tools/AIAudioHarness`).
- `bench`: per-track cost.
