# Auto Mix AI picking: experiments

Status: working prototype on branch `ai-picking`, 2026-11-09. On-device only. No network, no third-party model.

## What was built

| Piece | File | State |
| --- | --- | --- |
| Sound embedding per track | `Core/Analysis/TimbreEmbedding.swift`, `TimbreEmbeddingProducer.swift` | Runs in the background audio tier after MusicUnderstanding, stored in `AnalysisCache` as engine `apple.audioFeaturePrint` v1 |
| Sound + energy-trajectory cost in the picker | `Core/DJ/DJFlowSelector.swift` (`stepCost`, `reasons`) | Live in Auto Mix's flow selector |
| Set journey planner | `Core/DJ/SetJourney.swift`, `DJFlowSelector.search` | Beam search over the whole arc; the live picker uses the same search, three tracks deep |
| `SetIntent` and its deterministic parser | `Core/DJ/SetIntent.swift` | Drives energy goals, vocal and BPM penalties through `SetHistory.intent` |
| Foundation Models: intent, "why" lines, Flair summary | `Core/DJ/AutoMixLanguage.swift`, `AutoMixLanguageModel.swift` | `@Generable` structures, a guard on the output, and a deterministic fallback |
| UI | `Core/DJ/AutoMixIntentViews.swift`, `AutoMixMovesViews.swift`, `AutoMixLiveViews.swift` | A **Tonight** section in Your Moves ("Tell Auto Mix…"), a Flair summary row, and a natural "Why" line in the live view |
| Tests | `Tests/SoundingTVTests/Sources/AutoMixAIPickingTests.swift` | 14 tests. They run on the Mac via `tools/AIPickingEval/run-tests.sh` (no simulator); all pass |
| Evaluation | `tools/AIPickingEval/main.swift` | Runs on local files in `~/Music/SoundCloud` |

## 1. The embedding

**Choice: `CreateMLComponents.AudioFeaturePrint`.** This is Apple's built-in audio feature extractor, the backbone of the Sound Classifier. It is available on iOS 16+, macOS 13+ and tvOS 16+ and is in the watchOS SDK. It gives a 512-dimensional vector per 0.975 s window.

The options I checked, in the order you gave them:

- **SoundAnalysis `SNClassifySoundRequest`.** It exposes no embeddings or intermediate features in the 27.2 SDK, only class labels. The repo already uses it for vocal detection.
- **MusicUnderstanding (new in 27).** It gives rhythm, key, loudness, structure and instrument activity, but no embedding. We already use all of it.
- **Vision feature prints.** Image only.
- **`AudioFeaturePrint`.** It works and it's free. **Picked.**
- **Third-party models (CLAP, VGGish, YAMNet).** Not needed for the prototype. If we ever want text-to-sound search ("dark rolling techno"), the candidates are LAION-CLAP (Apache-2.0, about 600 MB, too big to ship) and YAMNet/VGGish (Apache-2.0, TF-Hub, about 15 MB once converted to Core ML). VGGish/YAMNet would be no better than AudioFeaturePrint for similarity, and AudioFeaturePrint is the same idea built into the OS. I would only revisit this for CLAP-style text queries.

**What we store per track:** three unit vectors (whole track, first 30 %, last 30 %), mean-pooled and quantised to Int8. That's **3.3 KB of JSON per track**. Cosine similarity runs on the Int8 vectors. The opening and closing vectors give a "seam" score: how well the end of track A sounds against the start of track B.

**Energy trajectory** uses the envelope we already have (the SoundCloud waveform): it compares the opening, closing and peak levels. Nothing extra is stored.

**Cost** (local eval, M-series Mac, 40 tracks): 169 minutes of audio embedded in **64 s, about 160× real time**, which is 0.3–2.3 s per track. MusicUnderstanding takes 2–28 s per track, so the embedding adds about 25 % to the audio tier.

## 2. Picking with it

`DJFlowSelector.stepCost` gains two terms:

- **Sound.** The cost is 0 when the blend of whole-track similarity (65 %) and seam similarity (35 %) is at least 0.93, and rises to 0.7 at 0.80 or below. Tracks with no embedding pay a flat 0.1, so tracks that haven't been analysed yet aren't punished relative to each other.
- **Energy trajectory.** Up to 0.4 when the incoming track's opening is more than 1.5 levels away from the outgoing track's closing.

When a `SetIntent` is active:

- the energy goal at each step comes from the intent's curve, at the set time that step lands on;
- a vocal track before the vocal time costs +1.5. This is a penalty, not a veto, so a vocal-only library still plays;
- each BPM outside the range costs 0.15, folded through half and double time, capped at 1.2.

The existing BPM, key, energy and genre rules and their vetoes are unchanged. When a track sounds alike, "sounds alike" (or "smooth handover") joins the reasons.

**Set journey.** `DJFlowSelector.search` is the beam search the picker already had, now generalised. It takes a depth, a width and a per-minute energy goal. The live picker searches three tracks deep. `SetJourney.plan` searches the whole pool with width 8 and no discount, so it optimises the whole arc rather than taking one greedy pick at a time.

### Results on 40 local tracks (`~/Music/SoundCloud`, every n-th file, under 10 min)

The thresholds come from the measured spread:

| min | p25 | median | p75 | max |
| --- | --- | --- | --- | --- |
| 0.560 | 0.859 | 0.893 | 0.918 | 0.971 |

The outlier (`1602348332_I can't tell you…`, the only non-club track) is at most 0.708 from everything else. The embedding finds that immediately.

**Ranking after *DJ Daddy Trance – I'm Bringin' Sexy Back* (145 BPM, 6A, energy 9):**

| # | Before (BPM, key, energy, genre) | After (+ sound, trajectory) |
| - | --- | --- |
| 1 | Diffrent – A Little Closer 0.20 | Diffrent – A Little Closer 0.15 (cos 0.93) |
| 2 | GottaGetGet 0.35 | GottaGetGet 0.25 (0.95) |
| 3 | Dissolver & Vall Du Son 0.56 | Dissolver & Vall Du Son 0.59 (0.91) |
| 4 | Gala – Freed From Desire 0.87 | **Elley Duhé – Money On The Dash** 0.87 (0.95) |
| 5 | Elley Duhé 0.97 | **Benwal – Just Go** 0.98 (0.94) |
| 6 | Cotto – Chopped Up Charlie 1.00 | Cotto 1.08 (0.92) |
| 7 | Benwal 1.07 | **Hammer House – The Jumper** 1.11 (0.94) |
| 8 | DJ Pooch 1.15 | Gala 1.13 (0.89) |

The top three hold: they already matched on key and tempo, and they also sound alike. Gala, the least similar track in the set (0.89), drops from 4th to 8th. Three tracks that sound closer move up into its place. That is the intended behaviour: sound breaks ties among harmonically valid candidates, and it never overrides key or tempo.

**Ranking after *Sunset Regime – I've Got the Real Feel* (129.7 BPM, 7A, energy 5):** only five candidates survive the key and tempo vetoes. Dua Lipa (cos 0.95) overtakes A1 – Trance 29 (0.88). The rest hold. With a small library, **the vetoes, not the sound, decide most picks**: only 23 of 40 tracks have six or more admissible next tracks.

**Journey vs greedy**: a 10-track warm-up from the lowest-energy connected track, for the request "warm-up set, building to peak in 45 minutes, no vocals for the first 15 minutes".

| | Greedy | Journey |
| --- | --- | --- |
| Mean distance from the energy arc | 3.60 | 3.10 |
| Vocal tracks before the vocal time | 5 | 4 |

The journey moves through 148 → 142 → 140 → 138 → 137 → 130 → 128 BPM and lifts energy 7 → 8 → 9 near the end. The greedy pick stays on 145 BPM bangers. Neither can fully follow the arc, because this sample of the library has no tracks below energy 5, and MusicUnderstanding marks every one of the 40 as having vocals. The planner can only shape what the crate holds. The full output is in `/tmp/aipick/run3.txt`; rerun it with `tools/AIPickingEval`.

**Caveats:**

- Within-track variation is as large as variation between tracks: opening vs closing of the same track scores 0.64–0.97. The whole-track mean is a coarse "vibe" descriptor, which is why the seam term exists.
- The eval's energy level is a stand-in (loudness and tempo). In the app it comes from the existing energy source.
- Tracks without MusicUnderstanding vocal ranges look instrumental to the vocal rule. That's optimistic.

## 3. On-device language model

The FoundationModels framework (macOS and iOS 26+, 27.2 SDK) is guarded by `canImport(FoundationModels) && !os(tvOS) && !os(watchOS)` and checked with `SystemLanguageModel.default.availability`. It is off under XCTest. This is the same pattern as `GeneratedInsightsModel`.

- **Set requests.** `GeneratedSetIntent` (`@Generable`) has:
  - energies bounded `.range(1...10)`;
  - clock times as `HH:mm` strings;
  - durations in minutes;
  - a `noVocalsAtAll` flag;
  - BPMs bounded `.range(60...200)`.

  The model never computes times. `SetIntentDraft.intent(now:)` turns clock strings into minutes deterministically, using the next occurrence. Out-of-range values are clamped or dropped. With no model, or if the model throws, `SetIntentParser` handles the same requests with rules. It covers warm-up, peak, build and wind-down; "by midnight" and "until 11"; "no vocals for 20 minutes" and "instrumental"; "120-126 bpm", "around 124 bpm", "under 125 bpm"; and "2 hour set". The owner's example parses to *"Builds from energy 3 to 9 over 2 hours · No vocals for 1 hour"* at 22:00.
- **"Why this track".** The model gets the planner's reasons as a numbered list and returns `GeneratedGroundedLine { usedFacts: [Int], line }`. `GroundedLineGuard` rejects the line and falls back to the deterministic "Same key · 124 → 126 BPM" text when:
  - an index is out of range;
  - the line is too long;
  - any number appears that isn't in the facts it cited;
  - any Camelot key appears that isn't in those facts.

  This blocks invented tempos and keys. It cannot block invented adjectives ("a disco classic" with no number gets through). The prompt forbids them, but that is prompt-level only.
- **Your Flair summary.** The Flair lines themselves are the facts, through the same guard. The fallback joins the first three lines into one sentence.

I couldn't test the model output on this Mac in the time available: the Mac app needs a signed build with Apple Intelligence on, and I didn't launch the owner's app. The stubbed-model tests cover the plumbing and the guard. **To verify:** run the Mac Debug app with Apple Intelligence on, open Your Moves, and type the example.

## 4. UI

- **Your Moves › Tonight** (first section, every platform): a "Tell Auto Mix…" `TextField` in the grouped Form, with an example prompt. Submitting shows a centred `ProgressView` while it works, then the parsed rules as plain rows, plus **Clear**. If the request isn't understood, the footer says "Auto Mix didn't catch that. Try energy, vocals, tempo or a time."
- **Your Flair:** a one-sentence summary row once there are two or more lines.
- **Live "Why":** `AutoMixWhyText` upgrades the line once the model has answered and keeps the deterministic text otherwise.

All of it is system controls with no glass, because these are content rows. The intent persists for its length (6 hours by default) and changing it replans the current mix. Bible decision log updated.

## What to ship

1. **Ship the embedding and the sound term now.** It is cheap (160× real time, 3 KB), built in, and makes no network calls. It only reorders candidates that are already valid. Before shipping, run it on the owner's full library and A/B it with the offline render harness.
2. **Ship `SetIntent` with the deterministic parser first** and the model as an upgrade. The parser covers the requests people actually type. The model mainly adds paraphrase tolerance.
3. **Ship the journey planner to drive the Up Next preview** ("the next hour"), not only the live pick. It's the same search, and it costs milliseconds for 30 tracks.
4. **Hold the natural "why" lines** until we have eyes on real model output. The guard blocks invented numbers and keys but not invented descriptions. A safer v2 has the model choose from enumerated phrasings (`@Guide(.anyOf(...))`) and fills in the facts deterministically.
5. **Follow-ups:**
   - Use `DJProfile.timbreTargetDistance`, which already exists and is unused, instead of the constants.
   - Let the clock regex consider every match, not just the first.
   - Show "No vocals until 23:00" as a clock time instead of minutes.
   - Backfill embeddings for tracks already analysed. The scheduler now treats "MusicUnderstanding stored, no embedding" as incomplete, so the next pass catches them.
