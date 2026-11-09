# On-device AI audio for Auto Mix (MLX Swift)

Status: wired into the macOS app behind an opt-in setting (off by default), 2026-11-09. Measured on the Mac (M1 Max, 64 GB, macOS 27.0). Swift only, using MLX Swift. No Python and no pickle loaders.

## What exists

| File | What |
|---|---|
| `SoundingTV.swiftpm/Sources/Core/Analysis/AI/AIAudioStream.swift` | Streaming decode and resample (AVAudioConverter, mastering quality). Never loads a whole set into memory. |
| `SoundingTV.swiftpm/Sources/Core/Analysis/AI/BeatThisModel.swift` | Beat This! (final0) written in MLX: log-mel front end (torchaudio-equivalent: 22.05 kHz, n_fft 1024, hop 441, slaney mel 30 Hz to 11 kHz, 128 bins, log1p(1000x)), conv stem, three partial frequency/time RoFormer blocks, six RoFormer layers with gated attention and RoPE, sum head. Then the reference chunking (1500 frames, 6-frame border, keep-first), the reference "minimal" peak picking, and a bar-phase vote that produces a constant `barDownbeats` grid plus confidences. |
| `SoundingTV.swiftpm/Sources/Core/Analysis/AI/OpenUnmixModel.swift` | Open-Unmix UMX-HQ written in MLX: STFT 4096/1024, the per-stem fc + 3-layer BiLSTM + fc decoder, and ratio masks with the mixture's magnitude. The LSTM runs all four stems, both directions and eight 12-second chunks as one batched recurrence. Output is a per-frame (23 ms) energy curve per stem, plus `StemTimeline`: vocal ranges, drums-only ranges, bass ranges, bass entries and exits, and a bass-overlap check for double-bass detection. |
| `tools/AIAudioHarness/` | Mac harness. `ai-audio-harness beats` and `ai-audio-harness stems` compare against the cached `BeatTracker` v2 analyses in `/tmp/automix-moves-src`. |

| `SoundingTV.swiftpm/Sources/Core/Analysis/AI/AIAudioAnalysis.swift` | Shared by tvOS, iOS and macOS, no MLX: the cached `AIAudioAnalysisResult`, the trust gate, `BeatTracker.imposing` (rebuilds phrases and the bar profile on the AI grid), the setting, and the model store (download, size and SHA-256 check, delete). |
| `SoundingTV.swiftpm/Sources/Core/Analysis/AI/AIAudioProducer.swift` | macOS only (`#if canImport(MLX) && os(macOS)`). The analysis producer and its runner. |
| `SoundingTV-macOS/Sources/Features/DJ/MacAIAnalysisSettings.swift` | Settings > Audio > Analysis: the toggle, download progress, and Delete Models. |

mlx-swift 0.33.0 (exact) is an `XCRemoteSwiftPackageReference` in the pbxproj. Its `MLX` product is linked only into `SoundingTV macOS`. The model files are compiled only into the macOS target, and the shared file has no MLX dependency, so tvOS, iOS and watchOS build without MLX.

## How it runs in the app

- **Setting.** Settings > Audio > Analysis > On-Device AI Analysis, off by default (`red.forbes.sounding.aiAudioAnalysis.enabled`). Turning it on downloads Beat This! first, then Open-Unmix, into `Application Support/AIModels`. Every file is checked for its exact size and SHA-256 before it's moved into place. Grid analysis starts once Beat This! is installed, and stems once Open-Unmix is.
- **Producer.** While the setting is on and Beat This! is installed, `AIAudioProducer` joins the audio tier next to MusicUnderstanding (or BeatTracker). Its result is cached under the engine `sounding.aiAudio` v1. Tracks that already have MusicUnderstanding results are still queued until they have an AI result.
- **Background work.** `BeatTracker.extractFeatures` runs first, then inference on a serial utility-QoS dispatch queue. It waits while playback is critical, and stops (without caching) on task cancellation or when `ProcessInfo.thermalState` reaches `.serious`. Models are loaded per job and released afterwards.
- **Planner.** `assembleFeatures` takes `AIAudioAnalysisResult.plannerGrid(phaseFrom:)` (owner decision, 2026-11-09). When `confidence >= 0.8` and the meter is 4, the AI **beats** are used. If `downbeatConfidence >= 0.5` the AI bar phase comes too, and the bar profile and phrases are re-measured on it. Otherwise BeatTracker's bar phase is kept, snapped onto the AI beats: each tracker downbeat within 0.2 beat of an AI beat votes for that beat's slot mod 4, the most-voted phase is used for the whole track, phrase and section starts move to the nearest new downbeat, and the bar profile is remapped bar by bar. The grid's confidence is min(beat confidence, vote agreement). It replaces both the MusicUnderstanding grid and BeatTracker's. With no tracker result the AI grid isn't used.
- **Gaps and extra beats.** Beat This! drops beats in beatless breaks (darkknight 14 in a row, marionette 58) and adds a few spurious ones (voodoo 20). `BeatTracker.beatSlots` numbers beats by elapsed beat periods, dropping a beat closer than half a period to the previous one. Smoothing, bpm, tempo segments and the phase vote all use slots. Before this, bpm came from beat count over span: darkknight 123.41, marionette 113.66, voodoo 128.77 instead of 126.98 / 121.98 / 125.00, so a trusted AI grid could have rate-matched voodoo 3 % off. Across a gap longer than 2 beats the phase is re-voted, because counting slots across a long break isn't reliable.
- **Measured** with `tools/AutoMixGates/run-ai-gate.sh` (independent low-band flux, 30–650 Hz, as a multiple of the track mean): darkknight, jungle and marionette now take AI beats with the tracker's phase, voodoo keeps the full AI grid. darkknight on-beat/off-beat: tracker 3.12/2.99, new grid 4.25/2.28, so it's on the kick. Tracker downbeats that sat on an AI beat and are still downbeats: jungle 100 %, marionette 99 %, voodoo 88 % (AI phase, unchanged rule), darkknight 80 % (its tracker phase confidence is 0). bpm: darkknight 127.00, jungle 124.00, marionette 122.11, voodoo 125.32. The AI beats are smoothed with a 17-beat local line fit, to remove the 20 ms frame quantisation. Otherwise the existing chain is unchanged. Stem results set the vocal and bass ranges plus `FeatureProvenance.measuredStems`, and the drums-only spans become `TrackFeatures.loopRanges`. When both tracks have stems, loop windows must sit inside a drums-only span, and `SpectralClashTerm` adds a bass check: more than a bar of double bass during the swap ramp costs 0.6, and a bass hole at the swap costs 0.3. Tracks without stems score exactly as before.

## Weights

All weights are loaded with MLX's safetensors reader only, and every tensor name and shape is checked before use.

| Model | Source | Licence | Size | SHA-256 |
|---|---|---|---|---|
| Beat This! final0 (CPJKU, ISMIR 2024) | `huggingface.co/safe-models/beat-this-final0` @ 39ec64821baf38aa16fafa500a91379c16db0062, `model.safetensors` (official weights are a pickled `.ckpt`, not used) | MIT (code and weights) | 81.0 MB fp32 (20.25 M params). fp16 would be 40.5 MB. | f758c77b…0f2e |
| Open-Unmix UMX-HQ (sigsep) | `huggingface.co/aufklarer/OpenUnmix-HQ-MLX` @ 1e9976cf6447377821e4293841124eedcc9b9823, four `*.safetensors` | MIT | 4 × 35.6 MB = 142.5 MB fp32 (8.9 M params per stem) | vocals 886759bc…, drums 3bb9b60b…, bass cc051f71…, other 7fcaea35… |
| mlx-swift 0.33.0 | `github.com/ml-explore/mlx-swift` | MIT | code | n/a |

The Beat This! safetensors file is a third-party mirror (PytorchModelHubMixin) and has not been checked byte-for-byte against JKU's checkpoint. **The owner accepted this mirror for now (2026-11-09).** The app pins it by revision and SHA-256, so a changed upload fails the check rather than loading. It loads with every expected name and shape, and its output matches the paper's behaviour (below). UMX-L is CC BY-NC-SA, so it is not usable. HT-Demucs (MIT, `mlx-community/demucs-mlx`, 160 MB fp32 / 80 MB fp16) is the upgrade path if Open-Unmix quality isn't enough.

## Beats: measured against `BeatTracker` v2

F-measure uses a 70 ms window. "Onset" is the mean low-band (mel 0–19) spectral flux at each grid's beats, as a multiple of the track mean. It's an independent tie-break: the grid that sits on the kicks scores higher.

| Track | AI bpm / current | Beat F | Downbeat F (raw) | Notes |
|---|---|---|---|---|
| darkknight | 126.98 / 126.89 | 0.29 | 0.21 | They agree in 0–30 s and 300–330 s only. Everywhere else the current grid is on the off-beat. Onset at beats, current/AI: 30 s 2.6/5.4, 60 s 1.9/3.7, 270 s 2.5/5.2, 330 s 2.4/4.0. **The current darkknight grid is wrong, and the AI one is right.** |
| jungle | 124.03 / 124.00 | 0.99 | 0.73 | Beats are identical (onset equal in every window). Bar phase disagrees at 0–60 s and 390–430 s. Current phrase starts land on AI downbeats 27/34, but their AI bar index mod 8 is split 2:14, 0:5, 7:5, so the phrase grid isn't consistent under either. |
| marionette | 121.98 / 121.95 | 0.95 | 0.66 | The current tracker places downbeats one beat late (first downbeat 1.03 s vs the AI's 0.04 s), with `phraseOffsetBars` 7. |
| voodoo | 125.00 / 124.99 | 0.95 | 0.94 | Agreement. All 13 phrase starts land on AI downbeats. |

Raw Beat This! downbeats sometimes fire weakly two beats early (logit just above 0, while the true downbeats are at 4–7). That's why the planner should use `barDownbeats`, the per-track phase vote over all beats, rather than the raw list. `downbeatConfidence` = (share of raw downbeats on the voted grid) × (separation from the runner-up phase).

Speed (beats, Mac GPU): 4.8 s for darkknight (339 s), 6.1 s for jungle (517 s), 70–85× realtime once warm (36–40× on the first, cold run). Weights load in 0.06 s. A 6-minute track takes about 5 s. A 2-hour set takes about 90–100 s, extrapolated linearly because chunking is fixed-size. MLX peak is 1.87 GB, almost all of it the 32 × 1500 × 1500 attention matrices of the time-direction partial transformers in the first frontend block. Batching a single chunk keeps this flat regardless of length. Process RSS is 140–165 MB. The mel store for a 2-hour set would be 184 MB.

## Stems: measured

Ratio masks, no Wiener EM, no ISTFT. Analysis only needs magnitudes.

| Track | Time | Realtime | Vocals (AI vs current) | Drums-only, bar-snapped |
|---|---|---|---|---|
| darkknight | 2.5 s | 135× | 11 s vs 0 s | 143.9–151.5, 189.2–196.8 |
| jungle | 3.7 s | 139× | 441 s vs 409 s, IoU 0.81 | 0.1–54.3 (intro), 452.6–510.6 (outro) |
| marionette | 2.8 s | 135× | 32 s vs 0 s | intro to 75.8, 249–263, 296–302, outro 329.7–375 |
| voodoo | 1.7 s | 118× | 62 s vs 0 s | none (bass runs throughout) |

Overall throughput is 134× realtime. A 6-minute track takes about 3 s, and a 2-hour set about 54 s. MLX peak is 1.39 GB (8 chunks × 608 frames × 2 ch × 4096-point frames, plus four stem decoders). Process peak RSS is 730 MB.

Rules in `StemTimeline`, on 0.5 s windows, ignoring windows more than 30 dB below the track peak:
- Vocals: vocal share > 12%. Spans of at least 1.5 s, bridging gaps under 1 s.
- Drums-only: drums > 60%, vocals + other < 15%, bass < 20%. At least 4 s. Snapped to `barDownbeats`. These are the sparse loopable sections for the owner's loop technique.
- Bass: bass share > 15%. Entries and exits are the bass-swap points. `bassOverlap(with:incomingStartsAt:window:)` returns the seconds of double bass for a candidate alignment.

## Platforms

- **macOS**: works. Everything here was measured on it.
- **iOS and iPadOS**: mlx-swift declares iOS 17 and runs on Apple-silicon GPUs. Not measured. Expect A17/M-class iPads to be 3–6× slower than the M1 Max. Peak memory needs cutting first: use fp16, and run Beat This! attention per head.
- **tvOS**: mlx-swift 0.33 declares tvOS 17, which is unexpected. Not tried. Apple TV memory makes the 1.4–1.9 GB peaks unsafe as they stand.
- **watchOS**: unsupported (not in the package's platforms). It must stay out.

Gate all shared code on `#if canImport(MLX)` (done). Link the MLX product only into targets that use it.

## Engineering notes and blockers hit

- **Disk full.** The Mac's data volume had 130–650 MB free (886 of 926 GB used, mostly outside this repo), so neither SwiftPM nor xcodebuild could build mlx-swift's C++ core and Metal shaders. To measure anyway, the harness compiles mlx-swift's own Swift sources and links them against the Homebrew `libmlx` 0.32.1 / `libmlxc` 0.6.0 that's already installed (`tools/AIAudioHarness/build-homebrew.sh`). `mlxc-shim.c` covers the mlx-c symbols that are newer than 0.6.0. The harness uses none of them.
- Because of that C ABI mismatch, `MLXFast.scaledDotProductAttention` failed ("expected a non-empty mlx_stream") in the Homebrew harness. The app links the real mlx-swift build, so Beat This! attention now uses `MLXFast.scaledDotProductAttention` again. The Homebrew harness can no longer run Beat This!, so measure with the SwiftPM harness, built with `xcodebuild -scheme AIAudioHarness` (plain `swift build` doesn't compile MLX's Metal shaders). With fused attention, all four tracks give exactly the same beats, downbeats and confidences as before. MLX peak stayed at 1868 MB, so fused attention bought no memory saving here.
- **Gate versus the measured confidences.** `downbeatConfidence` on the four tracks is 0.29 (darkknight), 0.44 (jungle), 0.20 (marionette) and 0.72 (voodoo), with grid confidence 0.88–0.99. At the agreed 0.5 gate, only voodoo uses the AI grid. darkknight, the track it fixes, falls back to the existing grid.
- Threading: both analysers are synchronous and take a `shouldContinue` closure. The app should run them on a utility-priority detached task, never the main or audio thread. Check `ProcessInfo.thermalState` in `shouldContinue`, and stop at `.serious` or above.

## Not done (follow-ups)

1. Phrase offset on the AI bar grid: jungle's phrase grid is inconsistent under both trackers. `estimatePhrases` now runs on the AI grid, but it hasn't been measured against the owner's phrasing.
2. An fp16 conversion of the weights, done in Swift with MLX, to halve the download.
3. iOS and iPad: measure first, then cut peak memory before enabling there.

## Recommendation

Ship Beat This! first, behind the opt-in, as the grid source on the Mac. It fixed the darkknight grid, which is visibly wrong today (off-beat for most of the track). It matches `BeatTracker` wherever `BeatTracker` is right, and it costs about 5 s per track. Ship Open-Unmix second, for analysis only (vocal ranges, drums-only loops, bass swaps). It's fast enough that a 2-hour set takes under a minute. Keep HT-Demucs in reserve for audible stems.
