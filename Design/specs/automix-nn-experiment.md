# Auto Mix transition net: a hand-written experiment

Status: experiment. Off by default, DEBUG only. Hard rules always win.

## What it is

A small neural net, written from scratch in plain Swift, that scores one Auto Mix transition as good or bad (sigmoid head) and predicts a 1–5 rating (second head). There is no Core ML, Create ML, BNNS or Python. Weight init (He), forward pass, backprop, Adam, L2, dropout, early stopping, stratified k-fold and permutation importance are all hand-written. Seeds are fixed, so the same data gives the same weights (the lab self-test checks this).

- Network: 38 inputs → 24 ReLU → 16 ReLU → {good logit, rating logit}. Dropout 0.2 on hidden units, L2 1e-3, Adam lr 3e-3, batch 16, up to 600 epochs, early stopping on a 20 % validation split with patience 50.
- Baseline: logistic regression, the same code with no hidden layers.
- Exported weights: JSON (`AutoMixNetModel`), about 18 KB pretty, 5.6 KB compact. Inference takes about 1 µs per plan on the Mac, so it is cheap enough to score every candidate plan.
- No 1D conv front-end. With a few hundred samples, an envelope conv would only add parameters to overfit. Revisit at about 1,000 or more labelled transitions.

## Features (`Core/DJ/AutoMixNetFeatures.swift`)

These are pure, `nonisolated` functions. `AutoMixNetFeatures.vector(_:)` turns an `AutoMixNetObservation` into 38 floats, with `NaN` for missing values (standardised to the mean, so missing means "no evidence").

- Energy step: incoming level for 8 bars after the blend, minus outgoing level for 8 bars before.
- Low, mid and high band energy before, during and after the blend. There are two sources:
  - `estimatedBands`, built from the two tracks' `BarProfile.bands` with the planned crossfade and bass swap. The planner can compute this.
  - `measuredBands`, taken from a rendered mix.
- Vocal overlap seconds (`DJMixRules.vocalOverlapSeconds`).
- Phase error, in beats off the downbeat at exit or entry.
- Grid confidence.
- Camelot key distance.
- Residual tempo mismatch: the % left after the planned rate.
- Peak/drop proximity: bars to the next 4 dB level jump.
- Max level jump.
- Spectral flux (rendered only).
- Low-band overlap ("double bass").
- Blend length (log2 bars).
- One-hots: exit section (6), entry section (6), move group (6).

`AutoMixNetObservation(plan:outgoing:incoming:)` in `AutoMixNetPlanning.swift` builds the observation from a `DJTransitionPlan` and `TrackFeatures` inside the planner. `AutoMixNetRatings` loads the on-device Nice / Not Great file (`[AutoMixRating]`, `transition-ratings.json`) as training samples. Those samples carry only move, length, energy, BPM, key, sections and vocal overlap. The band and render features stay missing.

## Planner hook

- `SetHistory.transitionNet` is set by `DJSessionDirector.currentSetHistory()` from `AutoMixNetExperiment.model()`. That returns nil unless all three of these hold:
  - the build is DEBUG;
  - `UserDefaults` `AutoMixNetExperiment` is true;
  - a valid weights file exists, at `AutoMixNetExperimentWeights` (a path) or at `Application Support/AutoMix/transition-net.json`. The feature names must match.
- In `DJPlanner` the net's term is added only on the non-vetoed branch, next to the learned and style terms. It is `clamp((p − 0.5) × 0.06, ±0.03)`. A veto is never rescued, and the score stays clamped to 0…1.
- To try it: `defaults write <bundle id> AutoMixNetExperiment -bool YES`, then copy `tools/AutoMixNetLab/weights/transition-net-synthetic.json` to the weights path.

## Data used so far

The labelled set at `automix-eval/truth/labels.json` did not exist when this was written. All the numbers below come from a synthetic set:

- Sources: the four local tracks (jungle, voodoo, marionette, darkknight) with cached analysis.
- Rendering: each transition was rendered through the real `MixRenderCore` and `MixTimeline.transition`.
- Good plans: phrase-aligned, tempo-matched, phase-locked blends of 8, 16 or 32 bars with a bass swap.
- Bad plans: injected faults:
  - phase (entry 0.3–0.5 beats off, no phase lock);
  - tempo (rate left about 3 % off);
  - double bass (no bass kill or swap);
  - slam (2-bar blend into the loudest phrase);
  - cut (off-phrase hard cut into a loud bar);
  - vocal (vocals over vocals for more than 4 bars).

That gives 206 transitions: 91 good, 115 bad. Ratings are 5/4 for good and 2/1 for faults.

## Results (5-fold stratified CV, seed 7)

Planner features (what the hook can actually see):

| model | accuracy | AUC | bad recall | bad precision |
|---|---|---|---|---|
| hard-rule gates | 0.602 | 0.628 | 0.522 | 0.690 |
| logistic regression | 0.951 | 0.983 | 0.939 | 0.973 |
| MLP 24-16 | 0.913 | 0.965 | 0.861 | 0.980 |

Rendered features:

| model | accuracy | AUC | bad recall | bad precision |
|---|---|---|---|---|
| hard-rule gates | 0.621 | 0.658 | 0.791 | 0.628 |
| logistic regression | 0.976 | 0.995 | 0.974 | 0.982 |
| MLP 24-16 | 0.966 | 0.994 | 0.957 | 0.982 |

Rating MAE on the 1–5 scale: MLP 0.56 and logistic 0.52 with planner features; 0.39 and 0.50 with rendered features.

Beyond the gates, with planner features: 119 transitions pass every gate, and 55 of those are bad. On that subset the MLP scores AUC 0.957 (bad recall 0.855) and logistic regression scores AUC 0.972 (bad recall 0.927).

The gates are the feature-level stand-ins for the planner's rules: vocal more than 4 bars, phase more than 0.15 beat, tempo more than 1 %, level step more than 6 dB, and key more than 2 over more than 4 bars. Here is how many of each group they flagged:

| group | flagged |
|---|---|
| phase | 19/19 |
| tempo | 19/19 |
| vocal | 17/17 |
| double bass | 4/17 |
| slam | 1/21 |
| cut | 0/22 |
| good | 27/91 (false alarms) |

The false alarms come from the level-step gate reading the estimated band levels.

Permutation importance (AUC drop), planner features: bpmDelta 0.15, phaseError 0.15, lowOverlap 0.12, blendLength 0.11, vocalOverlap 0.08. Everything else is under 0.03.

## Honest reading

- **The synthetic numbers prove the plumbing, not the taste.** The faults were defined by the same quantities the features measure, so near-perfect AUC is expected. The interesting part is that the net catches what the gates miss, mostly double bass, slams and cuts, through lowOverlap and blendLength. But the real planner already never ships those, because it always swaps bass and never slams a 2-bar blend into a peak.
- **The MLP does not beat logistic regression here.** On about 200 samples the linear model is as good or better, and it is easier to read. Early stopping halts after 12–146 epochs, which is the overfitting guard working.
- **With about 100 real labels, expect the MLP to overfit.** Start with logistic regression and use the MLP only once it wins in cross-validation.
- **What it would need to be worth turning on:**
  - 500 or more real, owner-rated transitions across many genres and BPMs, ideally ones the planner actually made, so the data matches what it will judge;
  - balanced Nice / Not Great ratings;
  - enough labels that the grouped CV is by track pair, not by transition, so the net cannot memorise tracks. The current CV is not grouped.
- **Keep the term small.** The ±0.03 clamp keeps it to a tie-breaker. It can reorder close candidates but cannot override any rule.

## How to run

- `tools/AutoMixNetLab/run.sh <out dir>` runs the self-tests:
  - backprop learns XOR, and logistic regression cannot;
  - training is deterministic;
  - exported JSON matches the lab net;
  - inference cost;
  - ratings loader;
  - clamp;
  - double-bass estimator.
- `run.sh <out dir> synth /tmp/automix-moves-src <analysis dir with *-bands.json> <out>/synthetic.json` renders the synthetic set.
- `run.sh <out dir> train <dataset.json> <out dir>` runs the CV report and writes the weights.

Training on `labels.json` still needs a small adapter from its format to `SyntheticPair` (`estimated`, `measured`, `good`, `rating`). That adapter waits until the file exists and its schema is known.
