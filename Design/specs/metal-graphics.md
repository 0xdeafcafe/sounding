# Metal graphics and GPU analysis

Status: first slice landed on `metal-graphics` (2026-11-08). Measured on an M1 Max MacBook Pro, macOS 27, release (`-O`) builds, no simulators.

## Benchmarks

To reproduce:
- `tools/MetalWaveformBench/run.sh <out-dir> <audio files…>`: analysis, LOD pyramid, rendering, 120 fps follow, PNGs.
- `tools/MetalWaveformBench/test.sh`: runs `MetalWaveformParityTests` on the Mac.
- `tools/MetalWaveformBench/canvas.sh`: the existing `SCWaveformRenderer` Canvas baseline.

Real audio: "5 Mins Of Acid", "1993 Nighttrain" and "Omen" (14.7 min in total). The 2-hour set is the first track tiled to 7200 s of 44.1 kHz mono.

## 1. Audit

### Renderers

| Surface | File | Drawing today | Status |
|---|---|---|---|
| Mac deck lanes (10 s, scrolling) | `SoundingTV-macOS/.../DJ/MacWaveformViews.swift` `MacMixLane` | SCWaveformRenderer Canvas, redrawn on every deck update | **Now Metal** |
| Mac deck overview strip | same file, `MacWaveformOverview` | SCWaveformRenderer Canvas | **Now Metal** |
| Apple TV DJ mode lane | `Apps/tvOS/.../DJModeView.swift` | SCWaveformRenderer Canvas | Next |
| Track Map (iOS, tvOS) | `TrackMapSheet.swift`, `TrackMapView.swift` | SCWaveformRenderer Canvas | Next |
| iOS Now Playing scrubber | `SoundingTV-iOS/Sources/Playback/NowPlayingScrubber.swift` | own Canvas + TimelineView | Wait for the scrolling Now Playing design, then build on MetalWaveformView |
| Mac Now Playing scrubber | `MacWaveformScrubber` (MacNowPlayingView) | Canvas | Same |
| tvOS Now Playing waveform | `TVNowPlayingWaveform.swift` | Canvas + TimelineView | Same |
| Prep overview (Mac) | `MacPrepView.swift` | Canvas at 15 fps | Next; it's a clean `.range` + playhead fit |
| Auto Mix live two-deck view | `AutoMixLiveViews.swift` | Canvas, 20 to 24 fps | Wait for the decks redesign; `.following` with two sources fits |
| Mix history set overview | `MixHistoryViews.swift` `MixSetTimelineCanvas` | Canvas | Next; one 2 h source with regions per segment |
| Track Trim editor | `TrackTrimEditor.swift` | Canvas | Keep; static and small, no win |
| Now Playing line art | `NowPlayingBackdrop.swift`, `MacNowPlayingBackdrop.swift` | Canvas paths | Keep; it isn't a waveform, and it's within its 3 % budget |

### Analysis pipelines

| Step | File | Engine | Status |
|---|---|---|---|
| Waveform peaks and 3-band energy (USB export, Prep) | `Core/DJMedia/DJAudioAnalysis.swift` | was a serial one-pole filterbank in Swift | **Now Metal compute, with a CPU-parallel fallback** |
| LOD pyramid for display | new `WaveformPyramid` | CPU or Metal | Metal when building from a 689/s base |
| ANLZ waveform encoding | `DJWaveformSynth` (DJMediaMapping) | CPU resampling of the above | Keep; microseconds |
| Beat tracking, onset, energy, vocal curve | `Core/Analysis/BeatTracker.swift` | vDSP STFT + serial tempo and beat search | Keep on CPU (see below) |
| Playback BPM, key, energy, intro | `Core/Playback/AudioAnalyzer.swift` | vDSP FFT on the first minutes | Keep on CPU |
| SoundCloud waveform fetch | `WaveformService.swift` | network JSON | n/a |

## 2. Before and after

### Rendering (per frame)

| Case | Before: Canvas, main thread | After: Metal, main thread (encode) | After: GPU |
|---|---|---|---|
| Mac deck lane, 10 s window, 1200×120 pt @2x | 0.28 ms median, 1.73 ms p95 | 0.003 ms mean | 0.22 ms mean, 0.54 ms worst (2400×240 px) |
| 2 h set, whole, 1200×120 pt | 2.02 ms median, 2.60 ms p95 | 0.005 ms | 0.25 ms (three-band, 120 grid lines) |
| Track, 16 s window | not possible at this detail (fixed 1800-point envelope) | 0.005 ms | 0.14 ms |
| Track, 12 ms window (sample level) | not possible | 0.004 ms | 0.14 ms |
| Overview strip, 600×24 pt | 0.22 ms median, 1.43 ms p95 | 0.005 ms | ~0.14 ms |

At 120 fps the deck lane used about 34 ms of main-thread time per second, plus SwiftUI body evaluation on every engine tick. It now uses about 0.4 ms. Between engine updates the lane scrolls on the GPU from an anchored clock (`MetalWaveformTimeline.following`), so it moves at display rate rather than at the engine's publish rate.

### Analysis (2-hour set, 150 entries/s, 1.08 M entries)

| Path | Wall | CPU time | Max relative error vs the old loop |
|---|---|---|---|
| Old serial loop (shipping before) | 2065 ms | 2062 ms | reference |
| CPU parallel, warm-up split | 158 ms | 1259 ms | 0 (bit-identical) |
| Metal compute, one shot | 182 ms | 146 ms | 3.5e-7 |
| **Stream, Metal segments (new default)** | 410 ms | 187 ms | 8.2e-7 |
| Stream, CPU-parallel segments (fallback) | 333 ms | 1209 ms | 0 |
| Decode for comparison (AVAudioFile, m4a/mp3) | ~50 ms per minute of audio, so ~6 s for 2 h | | |

Decision: **Metal is the default.** It's about 80 ms slower than the all-cores CPU path on a 2-hour file, but it uses 6.5 times less CPU time. That's the better energy and thermal trade for a background job, and decode dominates the wall time anyway. Both are 5 to 13 times faster than before. The CPU-parallel path is the fallback wherever Metal isn't available (the watch doesn't compile this code at all). GPU power wasn't measured, because `powermetrics` needs root; CPU time is the proxy.

### LOD pyramid (2-hour set)

| Base | CPU | Metal |
|---|---|---|
| 150/s (1.08 M bins) | 14.3 ms | 1.6 ms |
| 689/s (5.4 M bins) | 71.4 ms | 7.7 ms |

The GPU pyramid is bit-identical to the CPU one (a test checks every bin).

### Beat tracking: stays on the CPU
The tempo and beat search is a serial dynamic programme over onset frames, and the STFT is already vDSP. Beat tracking still decodes with AVAssetReader, so decode bounds it the same way as the band analysis above. A Metal STFT could at most save the vDSP share, which is a fraction of the decode. Not measured in isolation this slice: `BeatTracker.swift` doesn't build standalone without `DJTypes.swift`. That's the follow-up if anyone wants the number.

## 3. The component

`SoundingTV.swiftpm/Sources/Shared/Design/MetalWaveform/`:
- `MetalWaveformView(source:timeline:grid:overlays:style:)` wraps `MTKView` on macOS, iOS and tvOS. It runs at 120 fps only while `timeline.isAnimating`; otherwise it's paused and redraws on change. It drops to 30 fps in Low Power Mode or when thermal state is serious.
- `MetalWaveformSource` holds immutable GPU buffers: a min/max/rms/low/mid/high pyramid (8 bytes per bin) and optionally Int16 PCM for sample-level zoom. You build one from a SoundCloud envelope (`.envelope`), from band frames (`.bands`), from mono PCM (`WaveformPyramid(mono:sampleRate:)`), or from base bins with a GPU-built pyramid. `MetalWaveformSourceCache` keeps the last 16 envelope sources.
- `MetalWaveformTimeline` has two cases:
  - `.range(start...end, playhead:)` for static views;
  - `.following(anchor:hostTime:rate:window:playheadFraction:)` for scrolling views, evaluated per frame on the GPU path.
- `MetalWaveformOverlay`: `.cue`, `.loop`, `.region`. Times are stored as double-float pairs, so lines stay put at sample zoom 2 hours into a set.
- `MetalWaveformBeatGrid` draws beat, bar and phrase lines, thinned automatically as you zoom out.
- `MetalWaveformStyle` presets: `.blue`, `.rgb`, `.threeBand`, `.mono(color)`. Also played and unplayed tints, playhead, grid colours, vertical scale.
- Each frame is at most 5 instanced draws. The only CPU work per frame is about 30 scalars of uniforms (a few µs). Columns are anchored to absolute time, so scrolling doesn't shimmer. Pyramid levels are min/max of min/max, so zooming doesn't pop.
- Shaders are compiled at runtime from `MetalWaveformShaders.source`, once per process. That avoids a `.metal` build phase in four targets and the "no default library" trap recorded in `tools/MetalPreview/build.sh`.

Screenshots (Mac, offscreen render of the shipping shaders, real audio):
- zoom 1, the whole 2-hour set, three-band: `Design/specs/artifacts/metal-graphics/zoom1-whole-2h-set-threeband.png`
- zoom 2, a 16 s window, RGB, loop and grid: `Design/specs/artifacts/metal-graphics/zoom2-track-16s-rgb.png`
- zoom 3, a 12 ms window, sample level: `Design/specs/artifacts/metal-graphics/zoom3-track-12ms-samples-blue.png`

## 4. Constraints kept
- No GPU work on the audio thread. Compute runs inside `DJAudioAnalysis.waveform`, which already runs off the main actor.
- Nothing on the main thread except encoding and uniforms.
- watchOS compiles none of the Metal files (`#if canImport(Metal) && !os(watchOS)`). The band analysis types in `WaveformBands.swift` are plain Swift.

## 5. Follow-ups
1. Move Apple TV DJ mode, Track Map, Prep overview and the mix history set overview to MetalWaveformView.
2. Feed the deck lanes the analysis bands (`DJAudioAnalysis`) rather than the SoundCloud envelope, so they show real three-band colour.
3. Render off the main thread with `CAMetalDisplayLink` on its own run loop, to take even the encode off main.
4. Precompile the shaders into `default.metallib` per target once the pbxproj is quiet.
5. Parallelise decode across cores (segmented `AVAudioFile` reads). Decode is now about 95 % of analysis wall time.
