# Auto Mix blind A/B benchmark

Waveform review by Claude agreed with the owner about 60% of the time and can't judge taste. This benchmark lets the owner hear two versions of the same transition, without knowing which is which, and says whether a change is actually better.

Everything lives in `tools/AutoMixAB/`, uses Swift only, and runs on the Mac. It needs no network, simulator or SoundCloud account.

## Commands

```
tools/AutoMixAB/run.sh open <manifest.json>                  # rate transitions (clips)
tools/AutoMixAB/run.sh open <manifest.json> --long           # rate long excerpts (flow)
tools/AutoMixAB/run.sh analyse <manifest.json> [--json]      # preference, intervals, faults, held-out splits
tools/AutoMixAB/run.sh check <manifest.json>                 # list renders, clip lengths, loudness
tools/AutoMixAB/run.sh add <manifest.json> <render.json>...  # upsert render entries
tools/AutoMixAB/run.sh pack <corpus.tsv> <pack dir> <cache dir> [pairs 12] [longs 4] [seed 2026]
tools/AutoMixAB/run.sh selftest                              # loudness and statistics checks
```

`open` and `analyse` also take `--variants after,before`, which is needed when a manifest has more than two variants, and `--pad 25`, the seconds kept either side of a transition. `open` also takes `--seed N`, which fixes the trial order and the A/B sides. Each session records its seed. The first build compiles into `~/Library/Caches/automix-ab` (set `AUTOMIX_AB_BUILD` to change this) and takes about 20 seconds.

## What the rater sees

- Trials come in random order, and A and B are assigned at random per trial. The window never shows which variant is which.
- **Clips** run from 25 s before the first transition region to 25 s after the last one.
- **Long excerpts** play the whole render, which is 3–6 minutes spanning two transitions.
- **Loudness matching:** each clip's BS.1770-4 integrated loudness (K-weighted, gated) is measured over the exact window that plays. The louder clip is then turned down to match the quieter one. Gain is never added, so nothing clips. Dynamics inside a clip are left alone.
- **Keys:**
  - A and B switch sides, and the playhead stays in place;
  - Space plays or pauses;
  - ← and → skip 10 s;
  - ⌘↩ goes to the next trial.
- **Recorded per trial:**
  - preference: A, B or no preference;
  - fault tags for each side: flam/phase, muddy bass, bass hole, vocal clash, level dip/swell, pumping, bad landing, too long, too short, gimmicky effect;
  - an optional note;
  - seconds spent listening to each side;
  - the measured loudness and applied gain of each side.
- **Saving:** results are written after every trial to `<manifest dir>/results/<timestamp>-<mode>.json`, so a session can be stopped at any point.

## Manifest format (`automix-ab/1`)

A JSON file. Audio paths are relative to the manifest's folder, unless they are absolute.

```json
{
  "format": "automix-ab/1",
  "name": "pack1-main-vs-baseline",
  "created": "2026-11-09T12:00:00Z",
  "renders": [
    {
      "id": "p03-after",
      "pair": "p03",
      "kind": "transition",
      "variant": "after",
      "audio": "renders/p03-after.wav",
      "transitions": [{ "start": 32.0, "end": 58.3 }],
      "tracks": [
        { "id": "c014", "title": "Let It Go (Terrace Dub)", "artist": "Gorgon City", "source": "/Users/afr/Music/…", "bpm": 124 },
        { "id": "c021", "title": "…", "artist": "…", "source": "/Users/afr/Music/…", "bpm": 125 }
      ],
      "plans": [ { "…": "MixPlanRecord JSON, exactly as the app stores it" } ],
      "executions": [ { "…": "MixExecutionRecord JSON" } ],
      "provenance": {
        "analysisVersion": "BeatTracker v2; …",
        "engineCommit": "abc1234",
        "lane": "B",
        "renderer": "tools/AutoMixAB/Pack via MixRenderCore",
        "notes": "free text, never shown to the rater"
      }
    }
  ]
}
```

Fields:

- **`pair`**: the comparison key. Two renders with the same `pair` and `kind` but different `variant` become one trial. Keep the outgoing and incoming tracks identical within a pair.
- **`kind`**: `transition`, or `long` for two transitions in one file.
- **`variant`**: a free label, such as `main`, `baseline`, `before`, `after` or `laneA-v2`. Any two variants can be compared.
- **`transitions`**: transition windows in seconds of the audio file, measured from the engine's anchor clock, not predicted from the plan. Clip windows are cut from these. For `long` renders, list both transitions.
- **`plans`**: the exact `MixPlanRecord` per transition, in order (`MixPlanRecord.swift`).
- **`executions`**: optional `MixExecutionRecord`s, if the renderer knows the real rates and window.
- **`provenance.analysisVersion`**: the analysis version used. Make it specific enough to reproduce: the BeatTracker version plus anything the loader fixed or assumed.

### Adding before/after renders (lanes A and B)

1. Render the same pairs twice, once on the old code and once on the new. Use the same tracks, and keep the outgoing region if you can.
2. Write one `ABRender` JSON object (or an array of them) per render, using `variant: "before"` / `"after"`, and put the wavs next to the manifest.
3. Run `tools/AutoMixAB/run.sh add <manifest.json> renders.json`, then `run.sh check <manifest.json>`.

The quickest route is to copy `tools/AutoMixAB/Pack/main.swift`. Its `renderChain` drives `MixRenderCore` the way the app does, with one continuous engine, anchored legs and decks that alternate. It records the anchor-clock regions and the plan record for you. To get "before" renders, run the pack on a checkout of the old commit into the same manifest under a different variant name.

## First pack: current main vs simple baseline

`run.sh pack` draws pairs from the shared corpus (`automix-corpus/tracks.tsv`: 313 real tracks, of which the 300 that run 2.5–10 minutes are used).

1. **Pairing.** Tracks are shuffled with seed 2026 and analysed in that order. A track pairs with an earlier unpaired track if:
   - their tempos are within 6%, after folding to 90–180 BPM;
   - their artists differ;
   - its 10-BPM tempo band isn't full. Each band holds at most a quarter of the pairs, which spreads pairs across tempos.

   Tracks without a reliable phase grid are skipped.
2. **Long excerpts.** Each one extends a pair with a third tempo-compatible track.
3. **The two variants.**
   - **main:** `DJSessionDirector.decidePlan` on this commit, with `earliestExit 0` for clips. The second leg of a long excerpt uses `earliestExit` = 45 s after the first transition, as the app would replan.
   - **baseline:** a 16-bar equal-power (sin/cos) crossfade. Both decks are phase-locked and tempo-matched, and the bass swaps at the halfway point. The blend starts on the outgoing phrase boundary closest to centring on the planner's transition. The incoming deck enters at its first phrase at or after the content start. The baseline therefore uses the same part of the outgoing track but none of the planner's choices: no move or entry choice, no filters, no loops and no length choice. A plain crossfade with both basslines running for 16 bars would only test "does Auto Mix swap the bass". The halfway bass swap is the one DJ basic the baseline keeps.
4. **Analysis cache.** `automix-corpus/cache/beattracker-v<N>/<fnv64(path)>-<mtime>.json` holds `BeatTrackerResult`, measured on a 44.1 kHz stereo conversion. Other lanes may read it. The key changes when the file, its mtime or the BeatTracker version changes.
5. **Loader limitations.**
   - Key is fixed at 8A and energy at 6, as in `AutoMixEval`. The planner's key and energy terms are therefore neutral in this pack.
   - Tempo, grid, phrases, sections, vocals and bar bands are all measured.

## Analysis

`analyse` merges every results file next to the manifest (or the files you pass) and reports one block per variant pair, as text or `--json`:

- **Preference rate** for the first variant, pair-weighted. Each judgment scores 1 for a win, 0 for a loss and ½ for no preference. Each pair's score is the mean of its judgments, and the rate is the mean over pairs, so re-rating a pair doesn't add weight.
- **95% bootstrap interval** from 5,000 resamples of pairs (seeded). The verdict reads "better" only when the whole interval is on one side of 50%.
- **Fault-tag counts** per variant, which follow the variant rather than the A/B side.
- **Held-out splits:** leave one artist out and leave one track out. Each reports the range of the rate across splits and how many splits flip the verdict. A change that wins only because of one artist shows up here.
- **Breakdowns** by `transition` and `long` when both kinds were rated.
- **Training readiness:** progress towards about 150 ratings across 30+ pairs, the threshold before a logistic tie-breaker is worth trying (see below).

## In-app ratings (AutoMixFeedback)

Ratings from the Nice / Not Great prompt are now stored as `AutoMixRatingRecord`, which is the old `AutoMixRating` fields plus an optional `context`:

- `historyEntryId` and `sessionId`, linking to `MixHistoryEntry`;
- outgoing and incoming track identity (id, title, artist, BPM, Camelot, energy);
- `plan`: the final `MixPlanRecord`;
- `execution`: the `MixExecutionRecord` (real start, window, rates, sample rate);
- `performance`: the mid-track moves played before the mix;
- `analysis`: `AutoMixAnalysisProvenance` (BeatTracker version, outgoing and incoming `FeatureProvenance`, app build).

The context is filled at rating time from the `MixHistoryStore` entry for the same incoming title within 10 minutes. `offer(_:incomingTitle:analysis:)` accepts provenance from the director. Until the director passes it, ratings record only the BeatTracker version and app build.

The file is backward compatible: old files decode with `context` nil, and old builds decode new files by ignoring the extra key. Nothing learns from it yet. `AutoMixNet` and `LearnedSetPriors` stay off.
