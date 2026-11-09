# GPU track analysis

Status: profile done 2026-11-09, onset/chroma feature extraction ported to Metal; CPU wave (one decode, vDSP vocal pre-filter) done the same day. Own-model distillation of the vocal detector and timbre embedding tried the same day: both failed their gates, so both stay on Apple. Library throughput (N analysis lanes) done 2026-11-09.

## Profile

Harness: `tools/GPUAnalysisBench` (`run.sh <out> profile 30`). It compiles the shipping sources with `swiftc -O` and runs every whole-track stage, one track at a time, on 30 corpus tracks spread evenly through `automix-corpus/tracks.tsv` (135.3 audio minutes). Mac: Apple M1 Max, macOS 27. Per-stage wall-clock timers, plus `sample` on the running process to check where time goes inside each stage.

| Rank | Stage | Owner | ms per audio minute | Share | Accelerate / GPU before this work |
|---|---|---|---|---|---|
| 1 | Vocal detection, `SNClassifySoundRequest` (SoundAnalysis) | Apple | 2,440 | 54.1% | Apple CoreML, not ours |
| 2 | Timbre, `AudioFeaturePrint` incl. its own decode | Apple | 954 | 21.1% | Apple CreateMLComponents, not ours |
| 3 | Decode to 22.05 kHz mono (`AVAssetReader`) | Apple | 575 | 12.7% | AVFoundation |
| 4 | Decode to 44.1 kHz stereo (`MixSource`, plan time) | Apple | 276 | 6.1% | AVFoundation |
| 5 | Onset + chroma features (STFT 1024 every hop, STFT 4096 every 8 hops) | ours | 102.5 | 2.3% | vDSP FFT, `vvlog1pf`, vDSP means; chroma binning is a scalar loop |
| 6 | Per-bar K-weighted loudness (`LocalLoudness.measure`, plan time) | ours | 91.4 | 2.0% | none: six scalar `Double` biquads per stereo frame |
| 7 | Vocal pre-filter (four `Double` biquads before SoundAnalysis) | ours | 47.1 | 1.0% | none |
| 8 | Tempo, beats, downbeats, phrases, bar profile (`BeatTracker.analyze`) | ours | 25.5 | 0.6% | ACF uses `vDSP_dotpr`; beat DP is scalar |
| 9 | `TrackArrangement.build` sections | ours | 0.1 | 0.0% | n/a |

Total ≈ 4,510 ms per audio minute, so a 4-minute track costs about 18 s of one core. Inside rank 8: beat DP 6.9, tempo map 10.8, downbeats 5.2, ACF tempo search 0.3, phrases 0.2, bar profile 0.5 ms per minute. Key comes from chroma (rank 5) and costs nothing beyond it; `MusicUnderstanding` key detection is Apple's and was not measured.

Our own code is 5.9% of the analysis cost. 92% belongs to Apple frameworks we call: SoundAnalysis, AudioFeaturePrint and AVFoundation decoding. The on-device AI pack (Beat This, Open-Unmix) is opt-in, Mac only and already on the GPU through MLX, so it is not in the table.

### Auto Mix playback render

`gpu-analysis-bench mixcpu`: 10 minutes of two-deck `MixRenderCore` render (crossfade, rate 1.02, EQ cut, low-pass) in 512-frame blocks. Result: 5.0 s of render-thread CPU for 600 s of audio, which is 0.83% of one core. `/usr/bin/time` agrees (5.97 s user for the whole process, decode included). The live mix stays on the CPU.

## What was ported

Only rank 5. It is the largest stage that is ours, and it is pure data-parallel DSP.

- `Core/Analysis/GPU/GPUAnalysisShaders.swift`: two Metal compute kernels, compiled at runtime with `mathMode = .safe`.
  - `onsetBands`: one threadgroup per 64 consecutive hops. A 1024-point real FFT runs in threadgroup memory (512-point complex FFT plus the real split), then log magnitude, the lag-2 positive flux and the four band means. It warms up on the two hops before its run, so the flux history matches the streaming CPU extractor.
  - `chromaBands`: one threadgroup per 4096-sample chroma frame. It does the FFT, 12-class chroma, its normalisation, and the four log band energies.
- `Core/Analysis/GPU/GPUFeatureExtractor.swift`: a streaming extractor with the same contract as `BeatTrackerFeatureExtractor`. Samples go straight into one shared `MTLBuffer`. The whole track is dispatched as one batch, with blocks of up to 2²³ samples (6.3 min) so that DJ sets up to 150 minutes stay within memory. Per-hop mean square (`level`) stays on vDSP, so it is bit-identical. If a command buffer fails, that block is recomputed on the CPU extractor with a 4096-sample pre-roll, and that output is bit-identical to a continuous CPU run.
- `Core/Analysis/GPU/AnalysisBackend.swift`: the single switch.
  - `AnalysisBackend.preferred` is `.gpu` when a Metal device and pipelines exist, otherwise `.cpu`.
  - `SOUNDING_ANALYSIS_BACKEND=cpu|gpu` (environment variable or `UserDefaults`) forces either backend.
  - `AnalysisFeatureBackend.options(_:)` installs the extractor into `BeatTracker.Options`.
- watchOS has no `BeatTracker` and the GPU files are not in its target. The files are also `#if canImport(Metal) && !os(watchOS)` guarded.

Not ported, by the stop rule: once rank 5 moves, the stages that are ours and still on the CPU add up to 3.6% of total analysis time. The CPU follow-ups (one decode, SoundAnalysis overlap, biquads) were done in the CPU wave below.

## Wiring

`BeatTrackerProducer` (scheduler `.materialisedAudio` tier) and `AIAudioRunner` pass `AnalysisFeatureBackend.options(...)`. Analysis already runs off the main actor: the scheduler lane is a `Task.detached` on an actor, and `extractFeatures` is a nonisolated async static. The GPU wait is a `waitUntilCompleted` on that background task, once per 6-minute block. `BeatTracker.analyze(samples:)`, the path the tests use, still runs on the CPU. `BeatTracker.version` is unchanged, because the outputs pass the parity gate below, so cached results stay valid.

## Parity gate: all 313 corpus tracks

Run: `tools/GPUAnalysisBench/run.sh <out> parity 0`. For each track it decodes once, extracts features on both backends, runs `BeatTracker.analyze` and `TrackArrangement.build` on each, and compares the outputs. Result: **313 of 313 pass, no mismatches.**

| Check | Gate | Worst case over 313 tracks |
|---|---|---|
| Beat positions | within 1 ms | 0.000 ms (all identical) |
| Downbeats | within 1 ms | 0.000 ms (all identical) |
| BPM | equal to 0.01 | identical on every track |
| Key (Krumhansl on whole-track chroma) | identical | identical on every track |
| Per-bar level (`BarProfile.level`) | within 0.1 LU | 0.00 (level stays on vDSP) |
| Section and phrase starts, arrangement intervals and boundaries | identical | identical on every track |
| Raw features | none | onset bands: worst relative error 0.21, only on near-silent frames. Chroma and band energy: worst absolute error 7.4e-6 |

The float differences between the GPU FFT and vDSP stay under every decision threshold in the tracker. So `BeatTracker.version` stays at 3, and cached analyses stay valid.

`LocalLoudness` (K-weighted per-bar loudness) was not ported, so its output is unchanged by construction.

## Speed

The Mac was heavily shared during these runs: load average was about 750 on 10 cores, from other agents. Wall-clock times are inflated and noisy, so thread CPU time is the steadier number.

| Stage | CPU backend | GPU backend | Speed-up |
|---|---|---|---|
| Features, wall, 30-track profile | 102.5 ms per audio minute | 14.4 ms per audio minute | 7.1× |
| Features, wall, 313-track parity run | 111.1 ms per audio minute | 9.8 ms per audio minute | 11.3× |
| Features, host thread CPU, 313-track run | 32.7 ms per audio minute | 1.3 ms per audio minute | 25× less CPU |

End to end, whole-track analysis drops from about 4,510 to about 4,420 ms per audio minute, about 2%. The BeatTracker producer alone drops from about 3,190 to about 3,100 ms per audio minute, about 3%. The end-to-end gain is small because 92% of the cost is in Apple frameworks.

iPhone and iPad: not measured, because simulators are out for audio work. The same kernels run on any Apple GPU with 32 KB of threadgroup memory. The chroma kernel uses about 18 KB, and every A-series and M-series GPU qualifies. Expect a similar ratio for this stage.

Energy: `powermetrics` needs sudo, so energy was not measured.

## CPU wave (2026-11-09)

Three CPU-side changes the owner approved, each gated on all 313 corpus tracks. Gate run: `run.sh <out> wave` sharded with `WAVE_SHARD`/`WAVE_SHARDS`, then `wavesum`. Each track is decoded once by the production path. A tee sink feeds the same PCM to a copy of the old pipeline (`tools/GPUAnalysisBench/Legacy.swift`), so old and new see identical samples.

Note on the old profile above: `run.sh` compiled without `-wmo`, so `@inline(__always)` filter code in another file was not inlined, and the Mac was under load ~750. The scalar loudness meter is really ~14 ms per audio minute, not 91. `run.sh` now builds with `-wmo`, as Xcode does.

### What shipped

1. **One decode.** `AnalysisPCMDecode.read` (in `BeatTracker.swift`) is the one 22.05 kHz mono `AVAssetReader` loop, with the same settings as before. `BeatTracker.extractFeatures` takes `sinks: [any AnalysisPCMSink]`. `TimbreFeatureSink` (in `TimbreEmbedding.swift`) streams those buffers into `AudioFeaturePrint` on a detached task, so timbre runs alongside SoundAnalysis instead of decoding the file again after it. The scheduler creates an `AnalysisDecodeShare` for each job. `BeatTrackerProducer` (tvOS) or `AIAudioProducer` (Mac with AI on) fills it, and `TimbreEmbeddingProducer` takes the shared embedding. It falls back to its own decode through the same 22.05 kHz reader, so every embedding comes from the same input path. Timbre engine is bumped to `apple.audioFeaturePrint` v2, because the input changed from the file's native rate to 22.05 kHz mono.
2. **SoundAnalysis overlap stays 0.5.** Both cheaper settings failed the gate badly (table below). `VocalClassifier.overlapFactor` is now a constant and an `init` parameter. The observer fills interior gaps by linear interpolation, which is a no-op at 0.5.
3. **Vocal pre-filter on `vDSP_biquadD`** (`DoubleBiquadCascade`): 4.3× faster than the scalar loop, 22 → 5 ms per audio minute. A `Float` `vDSP_biquad` was tried first. Its output was 97 dB below signal, but it still moved SoundAnalysis confidences by 0.001 on some tracks. The double version leaves every vocal curve bit-identical. **The K-weighted loudness meter stays scalar.** With whole-module optimisation the scalar meter runs six filters per sample in parallel, at 14 ms per minute. `vDSP_biquad` was 3–4× slower (59 ms) and `vDSP_biquadm` 3× slower (44 ms), both within 0.018 LU. A speed change that makes it slower does not ship.

`BeatTracker.version` stays 3, because no tracker output changed. `TrackArrangement.version` is unchanged.

### Gates, 313 tracks

| Gate | Result |
|---|---|
| BeatTracker result (`==` on the whole struct: beats, downbeats, BPM, sections, phrases, bar profile, vocal curve and ranges) | 313 / 313 identical |
| Key, arrangement intervals and boundaries | 313 / 313 identical |
| Vocal curve, `vDSP_biquadD` pre-filter vs scalar | 0 points differ; filter output max abs error 6e-8, worst SNR 197 dB |
| Overlap 0.25 vs 0.5, sung bars (bar has > 0.01 s vocal, the planner rail threshold) | 96.1% bar agreement; 215 tracks under 99%; 220 tracks change by more than 1 bar; worst 60 bars. **Fail** |
| Overlap 0 vs 0.5 | 95.9% agreement; 205 under 99%; 210 change by more than 1 bar; worst 68 bars. **Fail** |
| K-weighted loudness, vDSP candidates | within 0.018 LU over 51,104 bars (pass), but slower, so not shipped |
| Timbre v2 vs v1, self-cosine of `whole` | min 0.985, median 0.995 (opening min 0.974, closing min 0.981). Old-vs-old run-to-run: min 0.9995 |
| Timbre v2 vs v1, `TimbreScoring.cost` over 97,656 track pairs (range 0–0.7) | median Δ 0.019, p99 0.119, max 0.301 |

The timbre change is real: it is 30× the run-to-run noise. It is consistent within v2, because both the shared path and the fallback feed `AudioFeaturePrint` 22.05 kHz mono. But pair costs move enough that set ordering by timbre will shift. The version bump re-embeds every track. Owner call: keep v2, or go back to native-rate input and give up the timbre share of the speed-up (see the table below).

Decoder determinism, found along the way: `AVAssetReader` at 22.05 kHz is not bit-reproducible run to run. Only 36 of 312 files decoded to identical PCM twice (250 m4a, 17 mp3, 9 wav differed). Results from two separate decodes can differ even with no code change. That is why the gate tees one decode into both pipelines.

### Speed, before and after

`run.sh <out> pipe 30`, the same 30 tracks (135.3 audio minutes). It was built once against the pre-wave tree (`SOURCE_REPO=<export of 69b22665>`) and once against this branch, then run back to back. Load average was 68 → 14 during the before run and 14 → 10 during the after run, so the after run had a slightly quieter machine. CPU time is process user+sys, which includes Apple's worker threads.

| Stage | Before wall | Before CPU | After wall | After CPU |
|---|---|---|---|---|
| Decode 22.05 kHz mono | 47.7 | 54.5 | 47.0 | 53.9 |
| Features, GPU | 3.7 | 1.3 | 3.5 | 1.1 |
| Vocal pre-filter + SoundAnalysis | 394.8 | 401.1 | 351.0 | 357.4 |
| Tracker + arrangement | 3.8 | 3.8 | 3.8 | 3.8 |
| Timbre `AudioFeaturePrint` (before: own native-rate decode; after: shared 22.05 kHz PCM) | 193.8 | 196.1 | 148.0 | 150.9 |
| Decode 44.1 kHz stereo (plan time) | 45.6 | 45.4 | 46.6 | 45.9 |
| Per-bar K-weighted loudness (plan time) | 13.8 | 13.7 | 13.8 | 13.7 |
| **End to end, production entry: beats + vocals + timbre** | **597.0** | **657.6** | **377.8** | **600.6** |

All figures are ms per audio minute. End to end, a track analyses 1.58× faster in wall time and uses 9% less CPU. Most of the wall gain comes from timbre now running alongside SoundAnalysis on the same stream. The 2× target is not reached, because the one large lever, SoundAnalysis overlap, fails the vocal gate. SoundAnalysis is now 60% of end-to-end CPU, and nothing that is ours remains above 1%.

## Own models (2026-11-09): tried, not shipped

Goal: replace SoundAnalysis (vocal curve) and `AudioFeaturePrint` (timbre) with small networks of our own on the GPU, distilled from Apple's outputs on the corpus, shipping only a stage that passes its gate. **Neither passed. Both stages stay on Apple.** `BeatTracker.version` stays 3 and the timbre engine stays `apple.audioFeaturePrint` v2, because no shipping output changed.

### What was built

- `tools/GPUAnalysisBench/GPUAudioModels.swift`: the runtime, kept in the bench and out of the app targets until a model passes.
  - `melFrames`: a Metal kernel that reuses the FFT helpers in `GPUAnalysisShaders` (1024-point FFT, hop 441 = 20 ms, 64 mel bands from 30 Hz to 11 kHz, log power, stored as fp16). `GPUMelSink` is an `AnalysisPCMSink`, so it rides the one shared decode.
  - `GPUAnalysisNet`: generic plain-Metal inference (`normaliseInput`, dilated `conv1d` + ReLU, `windowPool` mean+max, `dense`), loaded from safetensors at runtime. No MLX or MPSGraph, so it runs on iOS, tvOS and macOS. Long tracks are run in 1,024-window segments with receptive-field margins, so the output does not depend on the segment size.
  - Window grids match Apple's exactly: the vocal curve has `(samples − 22050) / 11025 + 2` points (checked on all labelled tracks) with point 0 = 0; timbre has `samples / 21498` windows.
- `tools/AnalysisModelTrainer/`: SwiftPM, Mac only, MLX Swift against Homebrew `mlx`/`mlx-c` (`build.sh`, same recipe as `AIAudioHarness`). Hand-written Adam, safetensors writer, and the gate proxies. No Python.
- Bench modes: `labels` (one decode per track tees PCM into `GPUMelSink`, production SoundAnalysis and `AudioFeaturePrint`; writes the mel, curve, frames and downbeats), `modelgate` / `modelgatesum` (held-out gate with production code and Metal inference on the same decode), `modelspeed`.

Labels: 309 of 313 corpus tracks (4 failed to decode). Split by corpus index: test = index % 5 == 0 (63 tracks, 20%), validation = index % 10 == 1, the rest train. Architecture tuning used validation only; the gate below is the test split, run once per final model.

### Gates, 63 held-out tracks (Metal inference, same decode as Apple)

Vocal model: 5 dilated conv layers × 128 channels over log-mel, mean+max pooled over SoundAnalysis's own 1 s windows, 2 dense layers, sigmoid; 1.6 MB.

| Gate | Needed | Result |
|---|---|---|
| Sung-bar agreement (bar sung if > 0.01 s vocal) | ≥ 99% | **85.0%** of 10,488 bars. **Fail** |
| Tracks within ±1 bar | ≥ 99% | **4 of 63 (6.3%)**; 45 tracks differ by 10+ bars, worst 95. **Fail** |
| Curve MAE vs SoundAnalysis | none | 0.103 |
| Sung bars, ours vs Apple | none | 3,624 vs 4,027 (ours under-calls) |
| Planner rail decisions, 160 pairs | unchanged | not run: the bar gate already fails |

On validation, a 4× larger model moved agreement only from 86.5% to 88.7% with the same MAE (0.084 → 0.086), so the gap is generalisation from 250 training tracks, not capacity. For scale: Apple's own classifier at overlap 0.25 instead of 0.5 scores 96.1% on this gate (CPU wave), so the gate asks for a closer match than Apple's model has with itself at a different hop.

Timbre model: 4 dilated conv layers × 128, mean+max pooled over `AudioFeaturePrint`'s 0.975 s windows, dense 256 → 512 → 512 regressing the 512-d frame vectors (standardised MSE, de-standardisation folded into the last layer); 2.7 MB. Pooling and quantisation are the production `TimbreEmbedding(frames:)`, costs are `TimbreScoring.cost`.

| Gate | Needed | Result |
|---|---|---|
| Pair-cost Spearman vs v2, 3,906 ordered pairs | ≥ 0.95 | **0.614**. **Fail** |
| Top-5 neighbour overlap | ≥ 80% | **33.7%** by cost (43.8% ranking by the unclamped blend). **Fail** |
| `whole` self-cosine | none | min 0.924, median 0.975 |
| Pairs at cost 0 | none | Apple 694, ours 2,738: regression to the mean collapses differences |

Frame cosine to Apple is 0.83 on validation whatever the size (96 or 128 channels, 256 or 512 hidden). Scaling deviations from the mean embedding by 1.5 (foldable into the last layer) lifts validation Spearman from 0.73 to 0.81 and top-5 to 52%, still far under the gate. A hand-built MFCC/spectral descriptor was not tried: it would be further from Apple's embedding than a model trained to imitate it.

### Speed (would-be), `modelspeed`, 12 held-out tracks, 50 audio minutes

ms per audio minute, wall / process CPU, M1 Max under shared load (load average ~30).

| Stage | Wall | CPU |
|---|---|---|
| Apple vocal: pre-filter + SoundAnalysis | 505.5 | 427.3 |
| Apple timbre: `AudioFeaturePrint` | 199.8 | 175.8 |
| Ours: GPU mel | 3.1 | 2.5 |
| Ours: vocal net | 46.9 | 0.6 |
| Ours: timbre net | 36.0 | 0.3 |

The models would cut these two stages from about 705 to about 86 ms wall per audio minute and from about 600 to about 3.4 ms of CPU, with naive one-thread-per-output kernels. The speed is there; the fidelity is not. Apple TV GPU not measured, and the tvOS simulator load check was skipped, because nothing was wired into the app.

### Reproduce

```
tools/GPUAnalysisBench/run.sh <out> labels 0            # sharded with LABEL_SHARD / LABEL_SHARDS; ~520 MB of labels
tools/AnalysisModelTrainer/build.sh <bin>
DEPTH=5 <bin>/analysis-model-trainer vocal <labels> <run> 6000 128
DEPTH=4 HIDDEN=512 <bin>/analysis-model-trainer timbre <labels> <run> 8000 128
VOCAL_MODEL=<run>/VocalModel.safetensors TIMBRE_MODEL=<run>/TimbreModel.safetensors <bench> modelgate <tracks.tsv> <gate dir> 0
<bench> modelgatesum <tracks.tsv> <gate dir> 0
```

What would need to change for another attempt: far more labelled audio than 313 tracks (distillation labels are free, but they need local audio, and the owner keeps real-account use rare), or gates defined on downstream decisions rather than on exact agreement with Apple.
## Library throughput (2026-11-09)

Per-track cost was already down to about 378 ms per audio minute. The scheduler was the bottleneck: one serial lane, then a 2 s sleep after every job, so a 5-minute track (about 1.9 s of work) spent half its slot asleep, and a 10-core Mac sat mostly idle.

### What shipped

- `Core/Analysis/AnalysisLanePolicy.swift` picks how many background jobs run at once from the device and its state (`AnalysisLaneConditions`):

| Device and state | Lanes |
|---|---|
| Mac on power | performance cores − 2 (at least 2); 6 on an M1 Max |
| Mac on battery | 2 |
| iPhone, iPad charging, or app in the background | 2 |
| iPhone, iPad in use on battery | 1 |
| Apple TV | 2 |
| Anything during playback | 1 |
| Low Power Mode, low battery, serious or critical heat | 0 (requests still run, one at a time) |

- The 2 s rest between jobs is gone on power when nothing is playing. On battery or during playback each lane still rests 2 s after a job.
- `AutomaticAnalysisScheduler` now runs that many lanes. A key never runs twice at once. A requested or deck-load analysis always gets a slot even when background lanes are full. Jobs stay at `.background`: 6 lanes at `.background` and at `.utility` measured the same (116 vs 114 tracks per minute).
- Tests inject the conditions (`init(backgroundPriority:waitsForInitialSync:conditions:)`).

### Waiting for iCloud before burning CPU

Results arriving from another device already skip work: the backlog admits a track only when `hasStoredMusicUnderstanding` is false, and `run` checks the cache again just before decoding. What was missing was ordering. The download index starts the backlog at launch, often before the first CloudKit fetch has adopted the other devices' rows, so a fresh device re-analysed tracks whose results were seconds away. The shared scheduler now holds background jobs until the first analysis relay round ends (`CloudSyncEngineController.runAnalysisRelay` calls `noteAnalysisSyncSettled()`, also on error or when iCloud isn't ready), or 60 s at most. Requests and deck loads don't wait.

Still re-done on each device: the timbre embedding (`apple.audioFeaturePrint` is not in `AnalysisSyncEngineScope.default`), and any track whose other-device result was made from a different transcoding, since the cache key includes the audio fingerprint.

### Concurrency safety

- SoundAnalysis: each `VocalClassifier` owns its `SNAudioStreamAnalyzer` and request. No shared state.
- GPU feature extractor: each `GPUFeatureExtractor` owns its staging and output buffers. `GPUAnalysisContext` shares only immutable pipelines and tables plus one `MTLCommandQueue`, which is thread-safe.
- `AudioFeaturePrint`: one per `TimbreFeatureSink`.
- `MusicUnderstandingSession` (the Mac and iOS audio tier): concurrent sessions ran without `sessionInProgress`.
- The MLX AI pack already runs on its own serial queue, so it stays one at a time.

No extra limiter was needed. Gate: `run.sh <out> lanesparity 64` decodes each track once and analyses the same PCM serially and then with 6 concurrent lanes. **64 / 64 identical** (`BeatTrackerResult ==`, including the vocal curve, and `TimbreEmbedding ==`).

### Speed, before and after

`LANES=<configs> run.sh <out> lanes 60`, one process, all configurations back to back on the same 60 tracks (286.9 audio minutes) on the M1 Max on AC power. A configuration like `1by` means 1 lane, `.background`, 2 s rest after each job, which is the old scheduler. Each job is the production entry: one 22.05 kHz decode feeding GPU features, SoundAnalysis vocals and the timbre sink, then the tracker and arrangement. Load average is from start to end of each configuration. The Mac was shared with other agents.

| Configuration | Tracks per minute | Audio minutes per wall minute | Load |
|---|---|---|---|
| Before: 1 lane, 2 s rest | 13.0 | 62 | 187 → 15 |
| **After, Mac on power: 6 lanes, no rest** | **113.9** | **545** | 15 → 29 |
| 6 lanes at `.background` | 116.4 | 557 | 29 → 49 |
| 2 lanes, no rest (Apple TV; Mac on battery has 2 lanes plus the rest) | 57.5 | 275 | 49 → 30 |
| 6 lanes, next track decoded ahead into memory | 83.9 | 401 | 30 → 24 |
| 8 lanes | 88.6 | 424 | 24 → 22 |

Mac on power: **8.7× more tracks per minute**. Eight lanes is slower than six, so performance cores − 2 is the right ceiling here. The before run started under heavier load (187), so part of the gap is the machine. An earlier before run at load 11 → 382 measured 8.3 tracks per minute.

The Mac and iOS app's audio tier on OS 27 is Apple's `MusicUnderstandingSession`, not the tracker, followed by the timbre decode. `LANES_ENGINE=mu`, 30 tracks: **5.7 → 18.2 tracks per minute (3.2×)** with 6 lanes. `MusicUnderstanding` doesn't scale as well across lanes as our pipeline.

**Pipelining not shipped.** Decoding the next track while the current one is in SoundAnalysis made 6 lanes 26% slower (84 vs 114), because the lanes already overlap one track's decode with another's SoundAnalysis. It also holds a whole decoded track in memory per lane.

Apple TV, iPhone and iPad were not measured: audio work stays off simulators. Their lane counts come from the same policy, and the 2-lane row is the Mac-hardware equivalent.

## Own models, second attempt (2026-11-09): more data, full distillation, not shipped

Owner asked for more training data and the richest distillation. **Neither stage passes; both stay on Apple.** No version bump, nothing wired.

### Data

| Source | Files | Hours | Used for |
|---|---|---|---|
| Corpus, train split (index % 5 ≠ 0, % 10 ≠ 1) | 216 | 17.4 | vocal, timbre |
| Local music not in the corpus (Serato demos, short SoundCloud files) | 13 | 0.6 | vocal, timbre |
| Local DJ sets (Music app, two HÖR sets) | 4 | 4.0 | vocal only |
| SoundCloud downloads and downloaded sets | 0 | 0 | skipped |

Total 21.9 hours, up from about 17 before. The corpus *is* `~/Music`, so local music added almost nothing.

The downloads were skipped. The sandboxed Debug build's `list` step (now with `SOUNDING_TV_SET_ANALYSIS_MIN_SECONDS`) found 0 usable downloads in the container. It also cannot write outside its container, and the container is closed to the shell, so a decrypted file could not have reached the labeller anyway. The non-container store the set-learning run used now holds 13 encrypted files. Going further would need an unsandboxed build reading the download key from the keychain, which this run may not do. The owner's Sounding was not running at any point.

Dedupe: triplet-landmark fingerprints from the label mel against the 63 test tracks. The calibration scores best block votes. A test track matching itself scores 4,830 or more; non-test corpus tracks score a median of 66 and a p99 of 917. With the threshold at 1,000, no local file or set matched. Two corpus *train* tracks did match test tracks and are now left out of training: 0199 is the same track as a test track (6,363 votes), and 0162 is probably a remix (1,351).

### Labels

`labels2` writes the full SoundAnalysis class vector (303 classes, fp16) for every 1 s window of the prefiltered audio. It also writes the production vocal curve, AudioFeaturePrint frames (fp16), downbeats and the GPU mel, all from one decode. On 4 tracks its curve and downbeats are byte-identical to `BeatTracker.extractFeatures`. Labels come to about 0.4 s of CPU per audio minute.

### Training changes

- Augmentation: gain ±6 dB, tilt ±3 dB, noise floor on 30% of crops, ±2-frame shift.
- Vocal:
  - a multi-head net with the vocal logit, 303 soft-target class BCEs and a bar head (BCE of the max logit per bar against Apple's sung bar);
  - pruned to the vocal head on export, which keeps it at 1.6 MB;
  - an affine logit calibration fitted on validation and folded into the last layer.
- Timbre: frame MSE plus an in-batch cosine-similarity-matrix loss on crop means (24 windows, 32 distinct tracks), and an output scale fitted on validation (1.2).

### Full class vector vs vocal only (validation, 17.4 h, same steps and seed)

| Targets | Bar agreement | Curve MAE |
|---|---|---|
| Vocal curve + bar head | 88.6% | 0.088 |
| + all 303 classes | 88.4% | 0.085 |

The extra targets slightly improve the curve but do not move the bar decisions.

### Learning curves (validation, 32 tracks, before calibration)

| Train hours | Vocal bar agreement | Timbre Spearman | Timbre top-5 |
|---|---|---|---|
| 5 | 86.2% | 0.744 | 39% |
| 10 | 85.7% | 0.786 | 45% |
| 17.4–17.9 | 88.4% | 0.764 | 40% |
| 21.9 (vocal) | 89.6% | n/a | n/a |

Vocal gains about 1.5 points per doubling, which puts 99% around 30 times more audio (several hundred hours). Timbre is flat from 5 hours up: more data of this kind will not reach 0.95.

### Gates, 63 held-out tracks (Metal inference, production code, same decode)

| Gate | Needed | Before | Now |
|---|---|---|---|
| Sung-bar agreement | ≥ 99% | 85.0% | **86.0%**. **Fail** |
| Tracks within ±1 bar | ≥ 99% | 6.3% | **1.6%**. **Fail** |
| Sung bars, ours vs Apple | none | 3,624 vs 4,027 | 4,018 vs 4,027 |
| Timbre pair-cost Spearman | ≥ 0.95 | 0.614 | **0.753**. **Fail** |
| Timbre top-5 overlap | ≥ 80% | 33.7% | **32.1%**. **Fail** |
| Pairs at cost 0 (Apple 694) | none | 2,738 | 219 |

Calibration fixed the vocal under-calling, and the similarity loss fixed timbre's regression to the mean, which now overshoots. The model's embeddings no longer sit near Apple's (whole-track self-cosine has a median of 0.59), because the loss matches pairwise geometry rather than position. The fidelity the gates ask for is still out of reach.

Speed is unchanged (12 tracks, ms per audio minute, wall / CPU): Apple vocal 351 / 350, Apple timbre 146 / 147, our GPU mel 2.3 / 1.8, vocal net 48 / 0.5, timbre net 36 / 0.3.

### Reproduce

```
tools/GPUAnalysisBench: compile as run.sh does, then  <bench> labels2 <tracks.tsv> <labels>/<source> 0   # LABEL_INDEX_BASE, LABEL_DELETE_AUDIO
SOURCES=corpus,local,sets THRESHOLD=1000 <trainer> dedupe <labels> <out>                      # writes <labels>/exclusions.tsv
SOURCES=corpus,local,sets CLASS_WEIGHT=1 BAR_WEIGHT=0.5 DEPTH=5 <trainer> vocal <labels> <run> 6000 128
SOURCES=corpus,local SIM_WEIGHT=1 DEPTH=4 <trainer> timbre <labels> <run> 8000 128
```
