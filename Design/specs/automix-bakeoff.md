# Auto Mix bake-off: who should judge and choose transitions?

Status: results, 2026-11-09. Rerun with `tools/AutoMixBakeoff/run.sh` whenever new data lands. The full generated tables are in `automix-bakeoff-results.md`.

## The short answer

**Ship the gates plus the current planner score now. Don't ship a learned model yet.** On this data nothing learned is reliably better than the hand rules, and what the models "learn" is mostly the fault definitions read back to them. The one combination worth keeping warm is **gates as hard vetoes, then logistic regression as a small tie-breaker** among the plans that survive. It's the only learned setup that never made a choice worse than the gates did. Turn it on as the existing ±0.03 term only once it's trained on real owner ratings. The MLP needs to beat logistic regression in grouped CV first, and it doesn't today. Claude vision review is a dev-time check, not a judge.

| ship now | collect for | then |
|---|---|---|
| gates (planner vetoes, `DJMixRules`) | — | keep forever as hard vetoes |
| planner score at defaults, plus Your Moves | — | stays the main ranker |
| — | ~150 owner Nice / Not Great ratings on the planner's own picks, across 30+ track pairs | gates + logistic as a ±0.03 tie-breaker |
| — | ~500 ratings and 100+ track pairs | retry the MLP; ship it only if it beats logistic in grouped CV with a CI that excludes 0 |
| — | many more human sets, measured the same way as the planner | priors as a style nudge, never as a judge |
| Claude review as a dev-time regression check | — | — |

## What was compared

1. **Gates:** the hard rules. On the labelled renders these are the eval's hard gates (vocal overlap, level step, double bass, phase, clicks, payoff, entry energy). On the synthetic and real sets they are the lab's feature-level stand-ins for `DJMixRules`.
2. **Planner score** (hand-tuned weights plus Your Moves at defaults): this can only be judged by its own top pick, because it only scores its own candidates.
3. **Logistic regression** and 4. **the MLP (24-16)**, both from `tools/AutoMixNetLab`.
5. **Gates, then learned:** a vetoed plan scores below every survivor.
6. **Priors from real DJ sets:** `LearnedSetPriors.json` doesn't exist yet, so the tool fits a robust typicality score (median and MAD of blend length, energy step, vocal overlap, double bass and level jump) from the 46 transitions in `set-learning/reports-v2`.
7. **Claude vision reviewers:** Opus covers all 69 renders. Sonnet only exists as `reviewer-sonnet.partial.json`, so it is left out.
8. **AI audio features:** Beat This! grid confidence, plus Open-Unmix vocal and bass stem overlap across the blend, added as inputs to 3 and 4. They come from `tools/AIAudioHarness` output on this Mac (`/tmp/ai-audio-out`, four tracks).

Method:

- Leave-one-track-pair-out CV, where A>B and B>A count as the same pair.
- A stricter leave-one-track-out split, as a check.
- 1,000 bootstrap resamples over track pairs for the confidence intervals.
- Calibration as Brier score and 5-bin ECE.
- "Choosing": in each held-out ordered pair, each scorer picks its top candidate.
- A leakage ablation that removes the features each fault was defined by.

## The data, and what's wrong with each set

- **(a) 69 labelled renders.** Only 4 tracks and 6 track pairs.
  - The label is the gates. "Good" means a planner or forced move passed every hard gate. "Bad" means an injected fault measurably present, or two or more failed gates.
  - So the gates scoring about 1.0 here is circular, not a win.
  - The injected faults are almost all `bassSwapBlend`, while the goods are mostly cuts, loops, echoes and filters. That makes move type a free tell (see the ablation).
  - 12 borderline renders are left out of the binary metrics.
- **(b) 206 synthetic transitions** (the lab, re-rendered today through `MixRenderCore`).
  - Every fault is defined by the feature that measures it.
  - Same 4 tracks.
  - All 17 vocal-over-vocal faults come from one self-pair, so grouped CV leaves the models with no vocal faults to learn from when that pair is held out. That's honest, and it's exactly the situation a new genre puts a model in.
- **(c) 46 human DJ transitions** from 4 sets, 23 with detection confidence ≥ 0.2.
  - These are positives only.
  - They're measured from a full-mix recording, not from planner features, so level jumps and keys aren't measured the same way. Domain shift and over-strict rules can't be told apart here.
- **(d) Owner ratings:** none on this Mac. `transition-ratings.json` wasn't found.

## Results

### Judging (AUC with 95 % CI over track pairs; false alarms = good transitions flagged bad)

| contender | labelled AUC | labelled false alarms | synthetic AUC | synthetic bad recall | synthetic false alarms | human DJ transitions called good |
|---|---|---|---|---|---|---|
| 1 gates | 0.99 [0.96, 1.00] (circular) | 0 % | 0.63 [0.55, 0.72] | 52 % | 30 % | 9 % |
| 3 logistic | 0.93 [0.86, 1.00] | 27 % | 0.92 [0.77, 1.00] | 80 % | 1 % | 33 % |
| 4 MLP | 0.93 [0.85, 0.99] | 33 % | 0.94 [0.85, 1.00] | 83 % | 3 % | 30 % |
| 5 gates + logistic | 0.99 [0.98, 1.00] | 27 % | 0.89 [0.86, 0.91] | 97 % | 31 % | 4 % |
| 5 gates + MLP | 0.99 [0.97, 1.00] | 33 % | 0.93 [0.90, 0.96] | 97 % | 33 % | — |
| 6 real-set priors | 0.40 [0.16, 0.59] | 67 % | 0.77 [0.73, 0.80] | 84 % | 64 % | 28 % (leave one set out) |
| 7 Claude Opus | 0.64 [0.56, 0.74] | 40 % | — | — | — | — |
| 8 logistic + AI | 0.92 [0.87, 0.99] | 27 % | 0.87 [0.64, 1.00] | 81 % | 1 % | — |
| 8 MLP + AI | 0.95 [0.92, 0.99] | 33 % | 0.97 [0.94, 0.99] | 80 % | 2 % | — |

Significance (paired bootstrap of AUC differences):

- **MLP vs logistic:** not significant on either set (+0.00 labelled, +0.02 synthetic).
- **AI features vs without:** not significant for either model on either set.
- **Logistic vs gates:** not significant on the labelled set. On the synthetic set logistic wins by +0.29 [0.05, 0.43]. That set was built from faults the gates don't model (cuts and slams), so the win is expected.
- **Gates + MLP vs gates + logistic:** +0.04 [0.02, 0.06] on synthetic only. The interval is narrow because there are only 7 pairs; treat it as a hint.

Calibration: logistic is the best calibrated learned model (ECE 0.04 labelled, 0.08 synthetic). The gates are a step function, so their ECE (0.22 / 0.34) is poor by construction.

### Per-fault catch rate (synthetic, grouped CV)

| fault | gates | logistic | MLP | gates + logistic |
|---|---|---|---|---|
| cut (off-phrase hard cut) | 0 % | 100 % | 100 % | 100 % |
| slam (2-bar blend into a peak) | 5 % | 100 % | 100 % | 100 % |
| double bass | 24 % | 71 % | 76 % | 82 % |
| phase | 100 % | 100 % | 100 % | 100 % |
| tempo | 100 % | 95 % | 100 % | 100 % |
| vocal over vocal | 100 % | **0 %** | 6 % | 100 % |
| good (false alarms) | 30 % | 1 % | 3 % | 31 % |

On the labelled set every learned model, and the gates, catch 100 % of each injected fault type (2 to 6 examples each), except mid-phrase hard cuts (1 of 2). Claude Opus misses all the phase and payoff faults (0 %) and only 20 % of the gate-only failures.

### Choosing (best of each held-out pair's candidates)

| scorer | labelled: pick is good (12 pairs) | labelled: level jump of pick (dB) | synthetic: pick is good (13 pairs) | synthetic: passes gates |
|---|---|---|---|---|
| random candidate | 23 % | 7.6 | 44 % | 58 % |
| 2 planner (its own top pick, 7 pairs) | 86 % | 2.5 | — | — |
| 1 gates | 60 % | 8.0 | 56 % | 100 % |
| 3 logistic | 58 % | 4.1 | 92 % | 46 % |
| 4 MLP | 58 % | 4.4 | 92 % | 46 % |
| 5 gates + logistic | **75 %** | 3.8 | **100 %** | **100 %** |
| 5 gates + MLP | 75 % | 4.1 | 100 % | 100 % |
| 6 priors | 25 % | 5.4 | 65 % | 35 % |
| 7 Claude Opus | 21 % | 6.1 | — | — |

On its own, a learned model picks a plan that fails a gate in more than half the synthetic pairs. On the synthetic set it chose blends with 3.5 s of vocals over vocals. The gates can't rank anything, which is why they need a ranker. The two together are best on both sets. On the labelled set they reach the oracle rate (75 %: 3 of the 12 pairs have no good candidate at all).

The planner's own top pick is good in 6 of 7 pairs and has the smallest level jump of any pick. But it's labelled by the same gates it was built to pass.

### Leakage ablation

- **Synthetic:** remove the feature that defines a fault and the models stop catching it. Phase drops 100 % → 5 %, tempo 95 % → 11 %, double bass 71 % → 0 %, slam 100 % → 33 %. Remove every fault-defining feature and AUC falls from 0.92 to 0.61. Cuts are still caught, through move type.
- **Labelled:** removing any single fault's features changes almost nothing, because the injected renders trip several gates at once. Removing every fault-defining feature still leaves AUC 0.92, carried by move type and blend length. Removing those as well puts the models at chance (logistic 0.46, MLP 0.50).
- **So:** the models learned the thresholds we wrote down, plus "injected renders are bass-swap blends". They learned no taste beyond that.

### Leave one track out

On the labelled set, logistic swings from 0.30 (darkknight held out) to 0.99 AUC; the MLP stays between 0.90 and 0.99. On the synthetic set both stay at 0.89–0.99. Four tracks are far too few to say whether either generalises to new music.

### Cost

| scorer | per plan | size | needs |
|---|---|---|---|
| gates | ~2 µs | thresholds in code | nothing |
| logistic | ~1 µs | 37 weights, 1.7 KB JSON | ~100+ labelled transitions to fit |
| MLP 24-16 | ~2 µs | 1,305 weights, 17 KB JSON | many hundreds of labels |
| priors | ~0.2 µs | 10 numbers | human sets, no labels |
| Claude vision | seconds, plus an API call | — | a rendered PNG per transition |

Every on-device option is cheap enough to score every candidate. Cost doesn't separate them; data does.

## Plain-English conclusions

1. **The rules are doing the real work.** On the labelled set they *are* the label. On the synthetic set they miss exactly the faults nobody wrote a rule for (cuts, slams, most double bass), and the planner already avoids those by construction.
2. **The learned models don't know more than we told them.** The ablation shows they read the fault definitions back. With 4 tracks the differences between them aren't significant.
3. **Logistic beats or ties the MLP everywhere it matters.** It's better calibrated, 35× smaller and readable. MLP + AI has the highest synthetic AUC (0.97), but that's not significantly different from the others.
4. **A learned model must never choose alone.** It happily picks vocal-over-vocal blends the gates would veto. As a ranker *behind* the gates it is the best chooser on both sets.
5. **The AI stem and grid features add nothing measurable yet.** The vocal stem overlap duplicates the existing vocal feature, and the stem bass overlap can't see the EQ swap.
6. **The real-set priors measure style, not correctness.** Human DJs blend for 32 bars, so the priors mark cuts and echoes as "bad" (AUC 0.40 on the labelled set). Use them only as a style nudge.
7. **The gates veto 91 % of what human DJs actually did.** The level-step gate fires on 33 of 46 transitions and the key gate on 27. Part of that is measurement mismatch (a whole-mix recording isn't planner features). But this is the strongest hint in the bake-off that some thresholds may be too strict for real sets. It's worth a listen before anyone tightens them further.
8. **Claude Opus is a weak judge of these images.** AUC 0.64, 40 % false alarms, and its picks are worse than random (21 %). It misses phase and payoff faults entirely. It's good for spotting gross breakage at dev time, not for scoring.

## Gate measurement mismatch on human sets (2026-11-09)

The "91 % vetoed" figure was mostly the level gate measuring something the planner never gates on.

- **Level.** `SetLearning` reports `maxLevelJumpDecibels` as the largest bar-to-bar jump of the whole mix from 4 bars before the blend to 4 bars after it. That catches the DJ's own bass kills, filter sweeps and the incoming drop: 22 of the 33 firings had a before/after step under 6 dB. The planner's level rule (`LoopMixPlanner`: loop window step and the 8-bars-before vs 8-bars-after body step) compares the two tracks' levels, which on a recording is `energyStepDecibels` (8 bars after vs 8 before). The bake-off now uses |energy step| for the human rows. Firings: 33 → 12 at 6 dB, 11 at 8 dB, 4 at 10 dB.
- **Key.** `SetLearning.camelotDistance` counted relative major/minor (8A ↔ 8B) as 1; `DJMixRules.keySteps` counts it as 0. Fixed to match (2 transitions change, neither near the gate). The bake-off's key gate (> 2 steps over a blend longer than 4 bars) is already looser than the shipped profiles (`maxCamelotSteps` 1), so it under-counts real vetoes: at the shipped limit it would fire on 34 of 46, at 2 on 27, at 3 on 19. The measured distances are spread almost evenly over 0–6 steps, which is what unrelated keys look like. Whole-mix chroma can't tell "these DJs don't key-mix" from "key detection on a mix is noise" (each track's key is measured once and reused for both of its transitions, so there's no internal check). Measuring the isolated tracks with the planner's own key detector is the only way to separate them.
- **Combined** (level or key, as the bake-off defines them): 39 of 46 → 30 of 46.

`tools/AutoMixGates/run-pack.sh` renders a listening pack for the looser settings; the shipped thresholds stay until the owner has listened.

## What would change the answer

- **Real labels:** owner ratings on the planner's own picks, across many track pairs. This is the only thing that tests taste rather than our thresholds. Pipe `transition-ratings.json` in via `BAKEOFF_RATINGS=/path/a.json:/path/b.json`.
- **More tracks:** grouped CV with 4 tracks has 6 or 7 groups, so every confidence interval is wide and the bootstrap is coarse.
- **Measure human sets like the planner:** measure human-set transitions with the same feature code as the planner, so dataset (c) can test the gate thresholds directly.

## How to rerun

```
tools/AutoMixBakeoff/run.sh [out dir]
```

- **Defaults:**
  - Output goes to `/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/automix-bakeoff`.
  - Audio is read from `/tmp/automix-moves-src`.
  - AI features are read from `/tmp/ai-audio-out`; if they're missing, the script regenerates them with `/tmp/ai-harness-bin/ai-audio-harness`.
- **What it does:**
  - re-renders the synthetic set only if `synthetic.json` is missing, or `BAKEOFF_RESYNTH=1` is set;
  - picks up `automix-eval/reviewer-*.json`, `set-learning/reports-v2/*.json` and `Core/DJ/LearnedSetPriors.json` automatically;
  - writes `results.md`.
- **Overrides:** `BAKEOFF_ROOT`, `BAKEOFF_AUDIO`, `BAKEOFF_AI`, `BAKEOFF_AI_HARNESS`, `BAKEOFF_RATINGS`.
- **Known gap:** when `LearnedSetPriors.json` lands, the tool only notes that it exists. Wiring its schema in as contender 6 is a small follow-up.
