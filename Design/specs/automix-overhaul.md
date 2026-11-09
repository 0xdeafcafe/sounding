# Auto Mix overhaul

Status: phases A, B, B′ (TV beat tracker, §5.5) and C ("Play like a DJ", §6.8) landed (2026-11-06). Phase D selection and settings landed (2026-11-07, §7); Mix Now/Extend and the live status line belong to the Now Playing work. Everything is gated by the render harness.

Sources: three independent reviews (Terra, Opus, Sonnet, 2026-11-06), consolidated below, plus what the offline render harness measured once it existed. Where a review and a measurement disagree, the measurement wins. Paths are under `SoundingTV.swiftpm/Sources/Core/` unless stated.

The design bible governs any UI or copy that comes out of this work (native `Form`s, terse copy, "Auto Mix", no implementation prose).

---

## 1. Diagnosis

The planner's shape is sound: features, then templates, then scored plans, then stages. What's wrong sits on either side of it. The analysis claims more than it measured, the executor doesn't do what the plan says, and nothing measured the audio. All three reviews agree on the root causes. The harness then found a fault none of them could see from the code.

### 1.1 The incoming deck was silent through the blend (found by the harness)
`MixEngine.cue` scheduled the incoming segment at an absolute node time. `AVAudioPlayerNode` reads a segment's `when` as a sample time relative to *the player's own start*, so the incoming deck played silence for as long as the engine had been running, then appeared after the blend had finished. Every aligned transition was a fade-out into silence followed by a late entry. Fixed in phase A: the segment is scheduled with `when: nil` and the player starts at the shared node time.

### 1.2 Phase claimed without being measured (all three reviews)
- A bare BPM became a grid with `anchor: 0`, tagged `.measuredBeatGrid`, at confidence 0.85 (MusicUnderstanding summary without bars) or 0.7 (legacy analyser). Auto Mix's phase-lock threshold is 0.65, so both passed and the incoming deck was lined up to a downbeat that doesn't exist.
- `anchor` (first beat) and `firstDownbeat` were used interchangeably: phrase exits and entries, the clean-cut snap and stage quantisation used `anchor`; the cue used `firstDownbeat`. With a pickup or a non-zero downbeat offset every "bar" snap was one to three beats off.
- Entries were never snapped to the incoming track's own downbeats. The usual entry was 0 s; leading silence or a pickup became a permanent flam.
- The grid is one constant tempo extrapolated from the first beat. The measured `beats` array was stored and ignored, so drifting material (live sets, live drummers) drifts against it.

### 1.3 The TV, the main speaker, has the weakest analysis
- MusicUnderstanding is disabled on tvOS: `MusicUnderstandingSession(asset:)` aborts the process there (task #168), and `structure` alone peaks at about 620 MB (`mu-findings.md`). It stays off in phase A.
- The legacy `AudioAnalyzer` read only the first 60 s, used integer autocorrelation lags at 43 frames/s (123.0 or 129.2 BPM at 128) with no octave handling, and shifted every key by a minor third (`(pc + 3) % 12` against C-indexed names).
- The director looked up synced MusicUnderstanding results with one transcoding key (`max(playbackRank)`), while the producer stored them under the transcoding it analysed (`mixSource`). A result synced from a Mac or iPhone was often present and never found.

### 1.4 Wrong points, short blends, tracks cut in half
- Auto Mix picked the *earliest* exit within 0.08 of the best score, with an exit floor at 45%. Tracks left at about half way.
- A user's mix-out cue before 45% was silently discarded.
- The 8 s "Transition length" setting capped every Auto Mix blend at `max(1.5x, x+4)` = 12 s, and templates offered 4 to 16 bars against a 28 s hard cap. House wants 16 to 32 bars.
- With no analysis, Auto Mix cut at an envelope valley after 55%, or at 60%.

### 1.5 How the blend sounded
- Master dropped to 0.707 on top of an equal-power fader: a 3 dB dip, then a 2 s swell.
- `resetProcessing` at the start of every transition set the incoming deck's gain back to 1, discarding loudness normalisation.
- The incoming track glided back to its native tempo over 8 s after every mix: an audible tempo wobble, and a follow-up mix could start mid-glide.
- Echo Out left the dry signal running under the echo and then cut the tail with the fader, because the delay sits before the fader.
- The bass kill is a 200 Hz low shelf at −26 dB, not an isolator (phase B).

### 1.6 Execution is wall-clock on the main actor
Ramps stepped every 16 ms from `Task.sleep`; stage starts and the bass swap fired from `Date` offsets. A main-thread hitch moved the bass swap. Pausing let the transition keep running and finish while paused; seeking moved only the outgoing deck. (Pause and seek are fixed in phase A; sample-accurate automation is phase B.)

### 1.7 Selection, sets and control
- Auto Mix evaluates one candidate (`lookaheadCandidates: 1`). Harmonic confidence is fixed at 0.45 with no veto. "Energy" is integrated LUFS mapped to 1–10, so every club master reads 9–10. `energyTrace`, `arc` and `recentTrackIds` are never populated.
- Sets (60–120 min) are treated as tracks: exited mid-way through the set's own internal transition; analysis skips anything over 20 min; loading one as the next deck materialises about 1.9 GB of float PCM.
- Only the first mix-in/mix-out cue is read; hot cues, memory cues and loops are ignored (the DJ prep work adds these).
- The guide is a custom card with implementation prose, and length is set in seconds rather than bars.

### 1.8 Tests measured arithmetic, not sound
Planner self-tests asserted scores. The only audio test recorded a real-time tap of two hand-driven tones to a hard-coded scratch path. Nothing measured phase, loudness, vocal overlap or the plan-to-audio path, which is how 1.1 survived.

---

## 2. Target design

### 2.1 Analysis
- **Honest grids.** A grid carries provenance: `.measuredTempo` alone means "tempo known, phase unknown"; `.measuredBeatGrid` requires measured beats and downbeats. A BPM-only grid sits at confidence 0.3, below every profile's phase-lock threshold, and admits only cuts (and beatless fades). Phase A implements this.
- **Tempo map (phase B).** Phase from the nearest measured beats, a local period per bar (`BeatGrid.localBeatPeriod(at:)` lands in phase A as the first step), a grid-quality score from inter-beat-interval variance, and explicit half/double alternatives.
- **Phrases and sections.** 8/16/32-bar phrases from measured bars; sections labelled from drums, bass and vocal presence plus energy slope, not loudness against the median.
- **Real energy.** A per-section 1–10 curve from low-band level, onset density and high-band flux.
- **TV path.** A whole-track onset/beat tracker (tempogram plus dynamic-programming beats, regressed to 0.01 BPM, octave-folded with a genre prior, downbeat from low-band periodicity), run on the TV when nothing better exists and on Mac/iPhone ahead of the queue, synced through `AnalysisSync`. Until then the TV prefers synced MusicUnderstanding results (phase A fixes the lookup).
- **Sets.** Windowed analysis around candidate exits (last 10 minutes first), tracklist boundaries (description, comments, ShazamKit) as exit and jump candidates, and windowed deck storage.

### 2.2 Planning
- **Queue first.** "Keep Queue Order" is the default; suggestions fill in after the queue and are marked.
- **Cue hierarchy.** User mix-in/out cues, then user hot and memory cues and loops, then imported rekordbox cues, then suggestions. A user cue is honoured wherever it is, subject to runway.
- **Play-out by default.** The default exit is a phrase-aligned 16–32-bar blend that ends in the outro. Mid-track exits belong to the adventurous personalities and to phase C moves.
- **Safety ladder.** Blend → filter or echo → phrase-aligned cut. No beat-matched overlap without measured downbeats on both decks. Vocals on both decks veto an overlap when both are measured. Unknown evidence shortens the overlap rather than scoring as neutral.

### 2.3 Execution (phase B)
- **`MixTimeline`:** a sample-timestamped list of automation events, consumed on the render thread by a custom mixer (`AVAudioSourceNode` or an in-process AU) and identically by the offline renderer. Deck starts, fader, EQ, filter, delay send, rate and loop events all land on exact samples.
- **Transport:** pause freezes the timeline, resume restarts both decks at one shared `AVAudioTime`, seek moves both decks and the timeline together, and interruption or route change cancels cleanly.
- **Phase lock:** a per-bar onset PLL nudges the incoming deck to within 5 ms.
- **Mixer:** Linkwitz–Riley 3-band isolators with true kills, an equal-power fader with no master move, a post-fader echo/reverb send, limiter-guarded loudness matching that may boost.
- **One engine:** once Auto Mix is on, playback stays in the mix engine; no mid-song AVPlayer handover.

### 2.4 Steering (native UI, phase D)
Now Playing ••• → Auto Mix, a grouped `Form`:
- **Auto Mix** toggle.
- **Style** picker: Smooth (Wedding DJ), Club (Auto Mix), Adventurous (Junkie).
- **Energy** slider: Chill to Peak.
- **Blend** picker: Short, Normal, Long (8, 16, 32 bars). Replaces "Transition length" in seconds.
- **Keep Queue Order** toggle, on by default.

Beside the transport: **Mix Now** and **Extend** (+8 bars) when the next deck is ready; focusable side-panel buttons on tvOS. The status line reads "Into *Track* at 4:32 · 32 bars". Scores and rationale stay behind a DEBUG inspector. The guide becomes a native `Form`.

---

## 3. Evaluation: the render harness

`Tests/SoundingTVTests/Sources/` — `MixFixtures.swift`, `MixRenderer.swift`, `MixMetrics.swift`, `AutoMixHarnessTests.swift`.

- **Fixtures.** Synthesised, deterministic tracks with known BPM, beats, downbeats, key, vocal and bass ranges: house at 124/125/126 BPM, a track with a two-beat pickup, a track with 0.43 s of leading silence, a 7-minute "live set" drifting 122→126 BPM, and vocal-heavy intro/outro tracks. Cached as 16-bit CAF in the output directory.
- **Analysis modes.** `measured` (MusicUnderstanding-shaped: beats, bars, phrases, vocals, bass), `bpmOnly` (a synced summary with no bars), `legacy` (the real `AudioAnalyzer` run on the fixture file: the TV path) and `none`.
- **Renderer.** `MixRenderer` builds `TrackFeatures` with the director's own `assembleFeatures`, plans with the director's own `decidePlan`, then runs the real `MixEngine` in `AVAudioEngine` offline manual rendering with the shared `MixTransitionPerformer`. Ramps and scheduled actions run on the engine's automation clock, which advances with rendered samples. It renders the mix and each deck solo, so metrics can tell the decks apart.
- **Metrics per transition:**
  - plan: play fraction, blend length in bars, entry and exit distance from a true downbeat;
  - beat phase: kick onsets of each deck in the overlap, median/p95/max error, drift range and slope per bar;
  - downbeat offset in beats and phrase offset in bars (true downbeats mapped through the deck timeline);
  - loudness: short-term (3 s) and momentary (0.4 s) dips below the lower of the before/after levels, swell, and step;
  - true peak (4× oversampled);
  - bass clash seconds (both decks' sub-150 Hz within 12 dB);
  - audible vocal overlap seconds;
  - clicks against the pre-transition sample-delta ceiling;
  - tempo change in the 30 s after the blend;
  - pause: fader progress during a pause, phase after resume; seek: phase after a seek.
- **Analyser accuracy.** BPM error and key correctness of `AudioAnalyzer` on every fixture.
- **Output.** `$AUTOMIX_OUTPUT_DIR/<label>/` holds `report.json`, `report.md` and one `.wav` per scenario (10 s before the blend to 15 s after). Pass `TEST_RUNNER_AUTOMIX_OUTPUT_DIR` and `TEST_RUNNER_AUTOMIX_LABEL` to `xcodebuild test`.
- **Gates.** `AutoMixGates` fails the test on regressions against the phase A numbers (§5.2), with a margin, not invented targets:
  - every measured blend (`measured-blend`, `grid-without-sections`, `silent-lead-in`, `pickup-downbeat`): play fraction ≥ 0.65, ≥ 8 phase pairs, phase p95 ≤ 12 ms, downbeat offset 0, short-term dip ≤ 5 LU, bass clash ≤ 1 s, no clicks, true peak ≤ −0.3 dBTP, tempo change after the blend ≤ 0.05%;
  - entries ≤ 1 ms from a downbeat; Auto Mix blends ≥ 16 bars on the measured pair;
  - no blend without measured downbeats (BPM-only and legacy pairs);
  - live set: audio phase median ≤ 10 ms, downbeat offset 0; vocal pair: overlap ≤ 0.5 s; echo tail ≥ 1 s; an early mix-out cue is used;
  - pause: the fader doesn't move while paused, the blend doesn't finish while paused, phase after resume ≤ 2 ms at native tempo; seek: the incoming deck moves with the outgoing, phase after ≤ 2 ms at native tempo (the stretched case is reported, not gated, until phase B; §5.3);
  - analyser: BPM within 0.1% and the right key on the steady fixtures and the live set.

  Each engine PR attaches the `.wav`s for the owner's ear.
- **Not yet covered:** real music (a private, owner-rated corpus of licensed pairs and two sets with hand-labelled downbeats), blind listening, and device CPU cost. Metrics are proxies; listening decides.

---

## 4. Phases

### Phase A — stop the bleeding (landed)
Harness first, then quick fixes, each measured. Results in §5.

### Phase B — the executor (sample-accurate `MixTimeline`)
Effort 3–4 weeks. Risk high: audio-thread code on every platform. Gated by the harness: no metric may regress, and phase metrics must improve.
- `MixTimeline` value type: events `(sampleTime, deck, parameter, target, curve, duration)` plus deck start/stop/seek/loop events. Built from a plan by a pure function so the offline renderer and the live engine consume the same list.
- Render-thread consumer: a custom mixer node owning per-deck gain, isolator EQ, filters, send levels and the fader, reading parameter ramps per sample from a lock-free ring the main actor writes. Deck starts via `play(at:)` on the shared node time.
- Transport: pause, resume, seek, interruption and route change are timeline operations; the automation clock introduced in phase A becomes the timeline's position.
- Phase lock: per-bar onset PLL on the incoming deck during the overlap.
- Isolator EQ and a post-fader echo/reverb send; limiter-guarded loudness match that may boost.
- Engine-owned playback when Auto Mix is on (no AVPlayer handover).
- Harness additions: render the same plan through the live consumer at faster than real time and compare sample-for-sample with the offline path; add CPU per render quantum on the TV.
- Exit criteria: phase median ≤ 3 ms and p95 ≤ 8 ms on measured pairs, zero clicks, no loudness dip over 1 LU, bass clash ≤ 1 beat, pause/seek within 5 ms after resume.

### Phase B′ — analysis (can run beside B)
Effort 2–3 weeks. Risk medium: tvOS CPU and memory budget (bible §6).
- TV beat/downbeat tracker and tempo map (§2.1); analyser accuracy gates move to beat F-measure and downbeat accuracy. **Landed; results in §5.5.**
- Mac/iPhone pre-analyse the queue with MusicUnderstanding and sync; the TV analyses only what nobody else has.
- Section labels from drums/bass/vocals; per-section energy.
- Set windows and tracklist boundaries.

### Phase C — "Play like a DJ"
See §6. Effort 5–7 weeks after B. Risk medium–high.

### Phase D — selection and steering
Effort 2–3 weeks. Risk medium. **Selection and the settings landed (2026-11-07); results in §7.**
- Flow mode: beam search over the next 8–12 candidates (queue first) with Camelot distance (veto beyond 2 steps unless beatless), octave-folded tempo within ±6%, energy against an arc, genre distance, repeat avoidance (populate `recentTrackIds`, artist and track cooldowns).
- Steering UI (§2.4) and the guide as a native `Form`, verified with screenshots per bible §12.

---

## 5. Phase A results

### 5.1 What phase A changed
In landing order; each step was rendered and measured before the next.

0. **Incoming deck on the player timeline** (found by the harness). `MixEngine.cue` queues the segment with no time and starts the player at the shared node time.
1. **Honest grids.** A BPM without measured bars is a tempo-only grid at confidence 0.3 with only `.measuredTempo`; overlap templates (bass swap, filter fade, filter bloom) need measured downbeats on both decks, otherwise the planner cuts on the bar. `firstDownbeat` prefers the measured first bar, and phrase exits, entries, the clean-cut snap and stage quantisation all use it. Entries snap to a measured downbeat of the incoming track. Rate matching and the tempo term use the mean measured beat period across the blend window. The director finds synced MusicUnderstanding results under any of the track's transcodings.
2. **Analyser.** Key pitch classes fixed (the +3 shift), up to 240 s analysed, 256-sample onset hop, beat lag scored with its multiples, sub-frame period refinement, octave folding into 78–180 BPM; legacy results move to `dj-cache-v2.json`.
3. **Gain staging.** No master dip; the incoming deck keeps its normalised gain through the transition reset.
4. **Tempo hold.** The incoming deck holds the matched tempo; a deliberate 32-bar return starts at the first phrase at least 32 bars later and is cancelled by the next transition, which matches against the outgoing deck's actual rate.
5. **Echo Out.** A one-bar beat-synced throw, then the dry input is muted ahead of the delay, the outgoing fader is held for the tail, and the tail rings out over two bars while the incoming lands on the downbeat.
6. **Play out.** Auto Mix (`allowMidTrackExit: false`) exits from phrase lines 16–64 bars before the end, prefers any firing blend of 16–32 bars, then the longest blend at the latest exit; the cap rises to 64 s and sweeps are quantised to 8/16/32 bars; the seconds-based Transition Length no longer clamps Auto Mix. A user mix-out cue is honoured anywhere: blend there if a blend fires, otherwise cut on its bar. With no analysis, Auto Mix plays out to the end.
7. **Transport.** Pause freezes the automation clock (ramps and stage timers stop with the audio); resume restarts both decks at one shared node time; a seek during a blend moves both decks and the automation clock together, completes the blend if it lands past the end, and cancels it cleanly if it lands before the start.
8. **MusicUnderstanding on tvOS** stays off: `MusicUnderstandingSession(asset:)` aborts the process on tvOS (task #168) and `structure` alone peaks around 620 MB. The TV instead finds Mac/iPhone results synced over iCloud whichever transcoding they were made from (step 1).

Supporting infrastructure: `MixAutomationClock` and `MixEngine.after(_:)` (wall time live, rendered samples offline, pausable), `MixTransitionPerformer` (the director's transition execution, shared with the harness), `MixEngine(offline:)` with `renderOffline`, `DJSessionDirector.assembleFeatures` and `decidePlan` (pure, shared with the harness).

### 5.2 Per-fix measurements
Synthetic fixtures, offline render through the real planner and engine. Rows are cumulative; "n/a" means the metric can't be measured in that state (no overlap, or the scenario didn't exist yet). Phase is the true-beat offset between decks mapped through each deck's rendered timeline; for the live set it is measured on the kick onsets, because a stretched deck's player time drifts from its audio (§5.3).

Notes on the baseline row: the short-term and momentary "dips" of 100–300 LU are the incoming deck being silent through the whole blend (fix 0). Echo Out before fix 5 cut its tail with the fader by construction, so its tail after takeover was 0 s; the metric was added with the fix.

**Measured pair (house A 124 → house B 125, MusicUnderstanding-shaped analysis)**

| Stage | Move | Play fraction | Blend bars | Phase pairs | Phase median / p95 ms | Short-term dip LU | Momentary dip LU | Bass clash s | True peak dBTP | Tempo change after % |
|---|---|---|---|---|---|---|---|---|---|---|
| Baseline (today) | filterFadeOut | 0.52 | 6.2 | 0 | n/a / n/a | 106.4 | 291.8 | 0.0 | -2.3 | 0.80 |
| 0 · cue on the player timeline | filterFadeOut | 0.52 | 6.2 | 12 | 4.4 / 4.8 | 16.0 | 17.2 | 0.0 | -1.8 | 0.80 |
| 1 · honest grids, downbeat snaps, local tempo | filterFadeOut | 0.52 | 6.2 | 12 | 4.4 / 4.8 | 16.0 | 17.2 | 0.0 | -1.8 | 0.80 |
| 2 · analyser key/tempo/window | filterFadeOut | 0.52 | 6.2 | 12 | 4.4 / 4.8 | 16.0 | 17.2 | 0.0 | -1.8 | 0.80 |
| 3–5 · no master dip, hold tempo, echo out | filterFadeOut | 0.52 | 6.2 | 17 | 4.4 / 5.0 | 12.6 | 13.9 | 0.0 | -2.3 | 0.00 |
| 6 · play out, 16–32 bars, early cues | filterFadeOut | 0.90 | 8.0 | 22 | 4.1 / 4.9 | 3.4 | 11.7 | 0.2 | -1.3 | 0.00 |
| 7 · pause freezes, seek moves both | filterFadeOut | 0.90 | 8.0 | 22 | 4.1 / 4.9 | 3.4 | 11.7 | 0.2 | -1.3 | 0.00 |
| Final · cue fallback, prefer 16+ bars | bassSwapBlend | 0.71 | 32.0 | 92 | 2.1 / 3.9 | 3.7 | 9.2 | 0.4 | -1.8 | 0.00 |

**Grid truth**

| Stage | BPM-only grids: move | BPM-only: phase ms / downbeat off | Legacy analyser: move | Legacy: phase ms / drift ms | Grid, no sections: entry off downbeat ms | Grid, no sections: phase ms / downbeat off |
|---|---|---|---|---|---|---|
| Baseline (today) | bassSwapBlend | n/a / 1 | bassSwapBlend | n/a / n/a | n/a | n/a / n/a |
| 0 · cue on the player timeline | bassSwapBlend | 96.1 / 1 | bassSwapBlend | 31.5 / 61.2 | 1200 | 223.4 / 1 |
| 1 · honest grids, downbeat snaps, local tempo | cutOnTheOne | n/a / n/a | cutOnTheOne | n/a / n/a | 0 | 10.7 / 0 |
| 2 · analyser key/tempo/window | cutOnTheOne | n/a / n/a | cutOnTheOne | n/a / n/a | 0 | 10.7 / 0 |
| 3–5 · no master dip, hold tempo, echo out | cutOnTheOne | n/a / n/a | cutOnTheOne | n/a / n/a | 0 | 10.6 / 0 |
| 6 · play out, 16–32 bars, early cues | cutOnTheOne | n/a / n/a | cutOnTheOne | n/a / n/a | 0 | 4.1 / 0 |
| 7 · pause freezes, seek moves both | cutOnTheOne | n/a / n/a | cutOnTheOne | n/a / n/a | 0 | 4.1 / 0 |
| Final · cue fallback, prefer 16+ bars | cutOnTheOne | n/a / n/a | cutOnTheOne | n/a / n/a | 0 | 4.1 / 0 |

**Other moves**

| Stage | Live set: move | Live set: audio phase median ms | Live set: blend bars | Echo out: tail after takeover s | Early cue: exit s (cue at 71.7) | Vocal pair: move | Vocal overlap s |
|---|---|---|---|---|---|---|---|
| Baseline (today) | bassSwapBlend | n/a | 6.2 | n/a | 123.9 | bassSwapBlend | 0.0 |
| 0 · cue on the player timeline | bassSwapBlend | 9.7 | 6.2 | n/a | 123.9 | bassSwapBlend | 0.0 |
| 1 · honest grids, downbeat snaps, local tempo | bassSwapBlend | 9.7 | 6.2 | n/a | 123.9 | bassSwapBlend | 0.0 |
| 2 · analyser key/tempo/window | bassSwapBlend | 9.7 | 6.2 | n/a | 123.9 | bassSwapBlend | 0.0 |
| 3–5 · no master dip, hold tempo, echo out | bassSwapBlend | 9.0 | 6.2 | 1.41 | 123.9 | bassSwapBlend | 0.0 |
| 6 · play out, 16–32 bars, early cues | filterFadeOut | 3.9 | 16.2 | 1.41 | 216.8 | cutOnTheOne | 0.0 |
| 7 · pause freezes, seek moves both | filterFadeOut | 3.9 | 16.2 | 1.41 | 216.8 | cutOnTheOne | 0.0 |
| Final · cue fallback, prefer 16+ bars | filterFadeOut | 3.9 | 16.2 | 1.41 | 71.7 | cutOnTheOne | 0.0 |

**Transport**

| Stage | Pause: fader moved while paused | Pause: phase after resume ms (stretched / native tempo) | Seek: incoming moved s | Seek: phase after ms (stretched / native tempo) |
|---|---|---|---|---|
| Baseline (today) | 0.334 | n/a / n/a | 0.06 | n/a / n/a |
| 0 · cue on the player timeline | 0.334 | n/a / n/a | 0.06 | 223.3 / n/a |
| 1 · honest grids, downbeat snaps, local tempo | 0.334 | n/a / n/a | 0.06 | 223.3 / n/a |
| 2 · analyser key/tempo/window | 0.334 | n/a / n/a | 0.06 | 223.3 / n/a |
| 3–5 · no master dip, hold tempo, echo out | 0.334 | n/a / n/a | 0.06 | 223.2 / n/a |
| 6 · play out, 16–32 bars, early cues | 0.259 | 89.1 / n/a | 0.06 | 222.9 / n/a |
| 7 · pause freezes, seek moves both | 0.000 | 89.8 / n/a | 3.93 | 46.7 / n/a |
| Final · cue fallback, prefer 16+ bars | 0.000 | 231.9 / 0.0 | 3.82 | 152.3 / 0.0 |

**Analyser (legacy `AudioAnalyzer`, the TV path)**

| Fixture | Truth | Baseline | Final |
|---|---|---|---|
| house-a | 124.00 BPM, Am | 123.05 BPM, Cm | 124.00 BPM, Am |
| house-b | 125.00 BPM, Em | 63.02 BPM, Gm | 125.00 BPM, Em |
| live-set-d | 124.00 BPM, Gm | 61.52 BPM, A#m | 122.84 BPM, Gm |
| pickup-c | 126.00 BPM, Dm | 63.02 BPM, Fm | 126.00 BPM, Dm |
| vocal-intro-f | 124.00 BPM, F# | 123.05 BPM, Am | 124.00 BPM, F#m |
| vocal-outro-e | 124.00 BPM, C | 123.05 BPM, D# | 124.00 BPM, Am |

### 5.3 What the harness taught us (inputs to phase B)
- **Stretched decks lose position accounting.** Each deck's audio trails its `AVAudioPlayerNode` player time by a steady ~95 ms (the `AVAudioUnitTimePitch` pipeline), identical on both decks at native tempo. Once a deck is stretched (rate ≠ 1), the player time drifts from the audio (about 0.4% on the live-set pair), and after a pause or seek the two measures disagree: player times say the decks are 47–232 ms apart, kick onsets say 13–97 ms, and the size depends on the plan. The same pause or seek at native tempo keeps the decks within 0.001 ms. Phase A therefore measures phase on the audio for stretched pairs, gates pause/seek alignment at native tempo, and leaves the stretched case to phase B: the timeline must own position accounting through the stretcher (or use its own varispeed/time-stretch with a known latency) and re-cue the incoming deck to its analytic position after any transport event.
- **A constant 4–9 ms offset on stretched entries** (0 ms at native tempo) comes from the same pipeline; phase B's per-bar PLL removes it.
- **The default plan now leaves BPM-only and legacy-analysed pairs as cuts.** That is correct but means the TV only beat-matches tracks a Mac or iPhone has analysed. Phase B′'s TV beat tracker is what turns those cuts back into blends.

### 5.4 Listening packs
`$TMPDIR/automix/<label>/<scenario>.wav` (10 s before each blend to 15 s after). `baseline/` is today's engine (the incoming deck is silent through every blend); `fix0-cue/` isolates the cue fix; `after/` is phase A.


### 5.5 Phase B′: the TV beat tracker
`Core/Analysis/BeatTracker.swift` (decode and features) and `BeatTrackerCore.swift` (analysis). Gated by `Tests/SoundingTVTests/Sources/BeatTrackerTests.swift` and the tracker scenarios in `AutoMixHarnessTests`.

**How it works**
- Decodes in chunks with `AVAssetReader` to 22.05 kHz mono and keeps no PCM: per 128-sample hop (256 above 20 minutes) it stores four log-spectral-flux bands, and every 8 hops 12 chroma bins and 4 band energies.
- Tempo: windowed autocorrelation (8 s windows, 4 s hop) scored with its 2× and 4× multiples, folded into 78–180 BPM with a weak genre prior (`GenreProfile.bpmCenter`); a local period per window gives the tempo map.
- Beats: Ellis dynamic programming against the local period, then onset-refined anchors that must sit on the running grid (off-grid runs shorter than 48 beats are rejected), a local linear fit over ±8 beats, and gaps filled at the measured period. The final BPM is a regression over all beats.
- Downbeats: a Viterbi over 32-beat windows for the bar phase. Backbeat parity comes from snare/clap flux on beats 2 and 4. Beat 1 versus beat 3 comes from peak-picked whole-bar novelty (section changes), cymbal flux and kick weight; if that evidence points the other way, the phase flips by two beats.
- Phrases: 8-bar lines from bar novelty, with a phrase offset when the evidence is clear (`BeatGrid.phraseOffsetBars`).
- Confidence = 0.92 × min(beat confidence, downbeat confidence). Beat confidence: tempo clarity, the share of beats with an onset, and the residual against the fit. Downbeat confidence: the weighted vote strength and agreement for parity and for beat 1 versus 3. Below 0.5 the grid is tempo-only; below 0.6 beat confidence there is no tempo at all.
- **On the TV**, it is the audio-tier producer (`AnalysisProducerRegistry.audioTier`) for deck-loaded and requested tracks. It runs at utility priority, one job at a time in the existing lane, skips tracks that already have a synced MusicUnderstanding result, and sleeps while a deck loads or a blend is running (`AnalysisPlaybackGuard`). Results are cached and synced as `sounding.beatTracker` v1. The director uses them only when no MusicUnderstanding bars exist (`assembleFeatures(trackedBeats:)`).
- The tempo term now counts tempo-map curvature (the best constant rate's worst deviation across the blend) as drift, so drifting sets get blends the constant-rate executor can hold.

**Accuracy** (tvOS simulator; beat and downbeat F-measure at ±70 ms, first 5 s ignored; "reliable" means the grid admits phase-locked blends)

| Material | Truth BPM | Tracked BPM | BPM err % | Beat F | Median beat err ms | Downbeat F | Confidence | Reliable | Max local-tempo err BPM |
|---|---|---|---|---|---|---|---|---|---|
| house-a | 124.00 | 124.00 | 0.000 | 1.000 | 2.1 | 1.000 | 0.92 | yes | – |
| house-b | 125.00 | 125.00 | 0.000 | 1.000 | 1.6 | 1.000 | 0.69 | yes | – |
| pickup-c | 126.00 | 126.00 | 0.000 | 1.000 | 2.0 | 1.000 | 0.00 | no | – |
| live-set-d (122→126) | 124.00 | 123.94 | 0.048 | 1.000 | 2.0 | 1.000 | 0.92 | yes | 0.04 |
| vocal-outro-e | 124.00 | 124.00 | 0.000 | 1.000 | 1.5 | 1.000 | 0.18 | no | – |
| vocal-intro-f | 124.00 | 124.00 | 0.000 | 1.000 | 1.8 | 1.000 | 0.63 | no (Club needs 0.65) | – |
| breakbeat-g (kick 1 + 3&, snare 2/4) | 96.00 | 96.00 | 0.000 | 1.000 | 1.0 | 1.000 | 0.92 | yes | – |
| swung-drums-h | 88.00 | 88.00 | 0.000 | 1.000 | 0.2 | 1.000 | 0.92 | yes | – |
| live-drummer-i (118→128, ±8 ms jitter) | 122.66 | 122.69 | 0.021 | 1.000 | 3.6 | 1.000 | 0.92 | yes | 0.12 |
| kick-only-j (no bar cues) | 124.00 | 124.00 | 0.000 | 1.000 | 2.0 | – | 0.00 | no | – |
| beatless-k (pads) | – | no tempo | – | – | – | – | 0.00 | no | – |

Gates: BPM within 0.1%, beat F ≥ 0.97, median beat error ≤ 5 ms and downbeat F ≥ 0.95 on every rhythmic fixture; confidence ≥ 0.65 where the bar evidence is strong; drift error ≤ 0.2 BPM (live set) and ≤ 0.5 BPM (live drummer); no reliable grid on the kick-only or beatless material; and **never reliable and wrong** (a reliable grid with downbeat F < 0.95 fails).

The synthetic fixtures carry few bar cues (identical kicks, one crash every 8 bars, two or three section changes), so confidence there is deliberately modest. pickup-c and vocal-outro-e get every downbeat right, but the votes against are too strong to claim it, so they cut.

**Resources** (tvOS simulator on the development Mac, Debug build, so on the conservative side; peak is the process's physical footprint over baseline, sampled every 2 ms)

| Input | Audio | CPU s | CPU s per audio minute | × real time (CPU) | Peak footprint |
|---|---|---|---|---|---|
| house-a | 4 min | 2.34 | 0.59 | 103× | +0.9 MB |
| live-set-d | 7 min | 4.06 | 0.58 | 104× | +0.9 MB |
| 60-minute synthetic set | 60 min | 15.7 | 0.26 | 229× | +4.6 MB |

Gated at ≤ 60 MB and ≥ 10× real time. An Apple TV 4K's A15 has not been measured; allowing 3× for the device leaves it above 30× real time.

**Blend versus cut on the TV path** (render harness, Club profile; the TV path is the legacy analyser for key plus the tracker)

| Scenario | Move | Play fraction | Blend bars | Entry off downbeat ms | Phase pairs | Phase median / p95 ms | Audio phase median ms | Downbeat offset | Short-term dip LU | Bass clash s | True peak dBTP | Clicks |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| legacy-analyser (A→B, before) | cutOnTheOne | 1.00 | 0 | 430 | 0 | n/a | n/a | n/a | 0.9 | 0.0 | −2.2 | 0 |
| **tracker-blend (A→B)** | **bassSwapBlend** | 0.71 | **32.0** | 2.8 | 93 | **4.2 / 7.9** | 18.0 | **0** | 4.1 | 0.4 | −1.8 | 0 |
| measured-blend (A→B, MusicUnderstanding-shaped) | bassSwapBlend | 0.71 | 32.0 | 0.0 | 92 | 2.1 / 3.9 | 17.7 | 0 | 3.7 | 0.4 | −1.8 | 0 |
| **tracker-live-set (D→B)** | **bassSwapBlend** | 0.89 | 16.2 | 2.8 | 42 | 59.7 / 82.5 | **28.0** | 0 | 4.3 | 0.3 | −2.1 | 0 |
| live-set-drift (D→B, measured) | filterFadeOut | 0.89 | 16.2 | 0.0 | 41 | 61.4 / 84.8 | 3.9 | 0 | 4.2 | 0.4 | −2.1 | 0 |
| tracker-pickup (A→C) | cutOnTheOne | 0.99 | 0 | – | 0 | – | – | – | 2.7 | 0.0 | −2.2 | 0 |
| tracker-same-tempo (A→F) | cutOnTheOne | 0.99 | 0 | – | 0 | – | – | – | 0.0 | 0.0 | −2.2 | 0 |
| tracker-vocal-pair (E→F) | cutOnTheOne | 1.00 | 0 | – | 0 | – | – | – | 0.3 | 0.0 | −1.9 | 0 |

`tracker-blend` passes every phase A blend gate. "Audio phase" on stretched pairs is measured on kick onsets (§5.3); grid phase is the truth-mapped figure.

**Open: stretched-deck sensitivity (for phase B).** The tracked live-set beats are within ±2 ms of truth across the blend window, yet `tracker-live-set` measures 28 ms of audio phase against 3.9 ms for the measured grid. The probes `probe-tracked-out` (tracked outgoing grid, 31.0 ms) and `probe-truth-beats-out` (the same tracker result carrying true beats, 3.9 ms) isolate the cause. The only planning difference is an incoming rate of 1.00489 against 1.00475 (0.014%, about 4 ms over the blend), but the audio drifts about 0.2% (−20 → −47 ms over 13 s). `MixEngine` applies rates linearly, so the extra drift comes from the `AVAudioUnitTimePitch` stretch path: the same position-accounting fault as §5.3. The measured live-set result passes because of where its rate happens to land. Phase B's timeline and per-bar PLL must remove it; until then drifting sets can blend audibly loose on the TV. The harness gates the live set's grid quality (downbeat offset 0, ≥ 8 phase pairs, play fraction ≥ 0.65), not its audio phase, and reports the audio figure.

**Still open**
- No real-music evaluation yet: the owner-rated corpus (§3) is the next gate, especially downbeats on music without backbeats and the octave choice around 85–90 versus 170–180 BPM.
- The 60-minute synthetic set tracks its tempo but gets no downbeat confidence, so a set blends only where its bars are clear; set windows and tracklist boundaries are the remaining B′ items.
- Mac and iPhone keep MusicUnderstanding as the audio tier; the tracker runs there only where MusicUnderstanding isn't available (below OS 27). Pre-analysing the queue on those devices for the TV is still to do.
- No device run yet: CPU and memory come from the simulator.

---

## 5b. Phase B results

### 5b.1 What phase B built
- **One render core.** `MixRenderCore` (`DJ/MixRenderCore.swift`) is the mixer: an `AVAudioSourceNode` render block that owns both decks, the fader, the FX buses and the limiter. The main actor talks to it through a lock-free command ring; the core publishes a seqlocked snapshot (positions, parameters, meters, CPU) back. There is no per-deck `AVAudioPlayerNode`, `AVAudioUnitTimePitch` or EQ unit any more.
- **`MixTimeline`** (`DJ/MixTimeline.swift`): `(sample offset, action)` events — parameter ramps, deck start/stop/seek/linked seek, loops, echo time, phase lock. `MixTimeline.transition(_:)` is a pure function of the plan and deck state. The timeline is anchored to the outgoing deck's source position, and the core resolves the anchor on the exact sample the deck crosses it, so the incoming start and every stage land on samples whatever the main actor is doing. Parameters are evaluated on a fixed 32-sample grid with per-sample interpolation, so output doesn't depend on render block size.
- **Position accounting and stretch.** Each deck has an exact nominal clock (`rate` source frames per output frame) and a content pointer that plays at the source's pitch. The stretcher splices content back to the clock with a correlation-matched 256-sample crossfade when it drifts past 4 ms, and always before each measured beat, so kicks land on the clock. The core records every stretched kick's placement error: 0.56 ms worst at 0.8 %, 0.87 ms at 2.4 %. Reported positions are the clock, so pause, resume and seek are exact by construction. Pitch and varispeed use the same path with Hermite interpolation.
- **Phase lock.** During a blend the incoming deck follows the outgoing deck's measured beats: each outgoing beat sets the incoming rate from both decks' local 8-beat periods, and each outgoing downbeat corrects any phase error. It is a tempo-map loop, not an onset listener; it holds the drifting live set at 0.03 ms.
- **DSP.** Linkwitz–Riley 3-band isolator (LR4 at 250 Hz and 2.5 kHz with an all-pass on the low band; −60 dB is a true kill). TPT state-variable low- and high-pass filters. Echo and an 8-line FDN reverb as post-fader sends, so a throw keeps ringing after the fader closes; Echo Out cuts the dry signal on the one, holds feedback for two release lengths, then fades it. A 64-sample look-ahead limiter at −1 dBFS on the master. Long phase-locked blends use a "full through the middle" fader curve (both decks at unity from the fader's midpoint), which removes the equal-power dip.
- **Audio Units.** Each deck has an insert slot after EQ and filter; the master has a send slot fed by a per-deck post-fader send (`MixAudioUnitHost`; `MixEngine.loadEffect`, `removeEffect`, `setEffectBypassed`, `setEffectSend`). Bypass crossfades over 256 samples. The Mac Decks carry the UI: an Effect menu per deck, a Send effect in the mixer, the effect's own view in a panel (a generic `Form` when it has none), per-slot presets and restore on open.
- **Sources.** `MixSource` streams decks in 0.74 s chunks (4 s behind, 30 s ahead of the playhead and any pinned cue) decoded off the render thread, so a long set no longer needs gigabytes of PCM. Non-44.1 kHz sources are decoded whole (up to 20 minutes).

### 5b.2 Harness changes
- Every measured blend (`measured-blend`, `grid-without-sections`, `silent-lead-in`, `pickup-downbeat`, `wide-stretch`) is gated at the exit criteria:
  - grid phase median ≤ 3 ms and p95 ≤ 8 ms;
  - kick-onset phase median ≤ 3 ms and p95 ≤ 8 ms;
  - stretched-kick placement ≤ 1 ms;
  - dip ≤ 1 LU;
  - bass clash ≤ 1 beat;
  - no clicks in the mix or either stem;
  - true peak ≤ −0.3 dBTP;
  - no tempo change after.
- Stretched pause and seek (`pause-mid-blend`, `seek-mid-blend`, `wide-stretch-seek`) are gated at 5 ms of grid phase and 1 ms of kick placement. CPU is gated at 3 % of real time.
- **Live against timeline.** Six scenarios replay the posted timeline straight into a fresh `MixRenderCore` in 333-frame blocks, with no main actor and no `AVAudioEngine`. The output is compared with the live consumer: the command ring, main-actor timers and `AVAudioEngine` manual rendering in 128-frame quanta. The maximum difference is 0 on all six.
- New scenarios: a 2.4 % stretch (`house-g`, 127 BPM), with and without a seek.
- `MixEffectHostingTests` loads Apple's AUDelay into a deck insert and into the send, then checks that it is audible and that bypass returns the dry signal (< 1e-6).
- **Onset metric.** It now pairs only incoming onsets within 40 ms of a true incoming beat; offbeat basslines were reading as half-beat errors.
- **Click metric.** It compares each mix sample delta with what the two stems predict, and checks each stem against its own steady state. Two phase-aligned kicks summing at full had read as a click.

### 5b.3 Measurements (TV simulator, optimised build)
| Scenario | Metric | Phase A | Phase B | Exit criterion |
|---|---|---|---|---|
| measured-blend | phase median / p95 (grid) | 2.12 / 3.95 ms | 0.00 / 0.00 ms | ≤ 3 / ≤ 8 ms |
| measured-blend | phase median / p95 (kick onsets) | 17.65 ms / n/a | 2.63 / 6.11 ms | ≤ 3 / ≤ 8 ms |
| measured-blend | loudness dip | 3.75 LU | 0.73 LU | ≤ 1 LU |
| measured-blend | bass clash | 0.40 s | 0.10 s (0.21 beat) | ≤ 1 beat |
| measured-blend | clicks | 0 | 0 | 0 |
| pickup-downbeat | phase median / p95 (grid) | 4.14 / 9.14 ms | 0.00 / 0.00 ms | ≤ 3 / ≤ 8 ms |
| live-set-drift | phase median / p95 (grid) | 61.44 / 84.83 ms | 0.03 / 0.06 ms | ≤ 3 / ≤ 8 ms |
| live-set-drift | phase median / p95 (kick onsets) | 3.85 ms / n/a | 1.61 / 2.43 ms | ≤ 3 / ≤ 8 ms |
| pause-mid-blend (stretched) | phase after resume, grid / onsets | 231.85 ms / n/a | 0.00 / 5.09 ms | ≤ 5 ms |
| seek-mid-blend (stretched) | phase after seek, grid / onsets | 152.34 ms / n/a | 0.00 / 2.79 ms | ≤ 5 ms |
| wide-stretch (2.4 %) | phase median, grid / onsets; worst kick | n/a | 0.01 / 2.40 ms; 0.86 ms | ≤ 3 ms |
| wide-stretch-seek | phase after seek (grid); worst kick | n/a | 0.02 ms; 0.87 ms | ≤ 5 ms |
| echo-out | tail after takeover | 1.41 s | 1.32 s | ≥ 1 s |
| six replayed scenarios | live vs timeline, max difference | n/a | 0 | identical |
| all scenarios | render CPU | n/a | 0.82 % of real time (23.7 µs per 128 frames) | ≤ 3 % |

The onset-based phase carries a fixed detector bias of about 2 ms between these synthetic kicks: it reads 2.2 ms on unstretched pairs whose grid phase is 0.02 ms. It also wanders ±3 ms on kicks whose lows are killed. That is why stretched pause and seek are gated on the exact grid phase and on kick placement, which the core measures directly.

CPU is measured on the simulator, which runs on a Mac core. The Apple TV's core is slower, so the 3 % gate leaves a device budget of about 2 %. The worst single quantum, 2.2 ms, happens offline when a chunk is decoded inline; live, decoding runs off the render thread.

### 5b.4 Listening packs
`$TMPDIR/automix-b/before/` (phase A) and `$TMPDIR/automix-b/after/` (phase B): one `.wav` per scenario, from 10 s before each blend to 15 s after.

### 5b.5 Known limits
- The phase lock follows measured beats; it doesn't listen for onsets. A grid that is wrong on the audio stays wrong; phase B′'s tracker is the fix.
- The stretcher splices. It keeps kicks exact and is cheap, but sustained pads can show a soft splice about every 100 ms on stretches over 2 %; listen to `wide-stretch.wav`. (Reduced in §6.10.)
- ~~Audio Unit latency isn't compensated~~ (§6.10).
- ~~The filter-fade template still dips 2.0 LU on the live set~~ (§6.10, gated at 1 LU).

## 6. Phase C: "Play like a DJ"

The owner's brief: Auto Mix should feel like a DJ performing, not a crossfader on a timer. It enters and leaves at musical moments, moves within a long set as well as between tracks, builds tension with loops and effects, steers energy with tempo, and never lands off the beat.

Phase C is built on phase B's sample-accurate timeline. Every move below is a function that emits `MixTimeline` events; nothing in phase C schedules from the main actor.

### 6.1 Move vocabulary
Each move has preconditions, a shape in bars, and a safety envelope.

| Move | What it does | Needs |
|---|---|---|
| **Blend + bass swap** | 16–32-bar phrase-aligned overlap, lows swapped on a phrase line. The default. | Measured downbeats on both decks, compatible keys, tempo within the profile's range. |
| **Drop-in** | The incoming deck enters *just before* its drop (the last 4–8 bars of its build) so its drop lands on the outgoing deck's phrase line; or *just after* the drop, on the first downbeat of the drop. | Labelled drop and build sections on the incoming track; outgoing at a phrase end or breakdown. |
| **Breakdown exit** | Leaves the outgoing track on its breakdown instead of its outro. | Labelled breakdown; the incoming has a mixable intro or build. |
| **Jump within a set** | With one long set loaded on both decks, mixes from the current point to a later phrase of the *same audio* (e.g. 10 minutes on), beat-matched. Skips a dull section or an internal transition. | Local tempo map at both points; tracklist boundaries or section labels; the second deck holds a window of the same file. |
| **Jump within a track** | The same move inside one long track: skip a dull section by mixing into a later phrase. | As above, plus a phrase-aligned target at least 32 bars ahead. |
| **Loop-roll build** | Loops a clean phrase on the outgoing deck and halves it 8→4→2→1 bars, optionally with filter, echo, reverb wash and a riser; the incoming deck is cued and phase-aligned meanwhile, and released on the downbeat at its intended entry (drop or loop point). | Verified loop points (zero-crossing, on a downbeat, energy-stable), loop limits per profile. |
| **FX build** | Filter sweep (high-pass up), echo throw, reverb wash or riser over 4–16 bars into a cut or a drop-in. | Post-fader send (phase B). |
| **Tempo ramp** | Moves the master tempo over 8–32 bars to steer energy (e.g. 122→126 across two tracks), at most about 0.5%/bar while blending and 0.5%/min while not. | Key lock on; harmonic cost includes any varispeed. |
| **Half/double-time bridge** | Blends across a 2:1 relation where both grids fold exactly (e.g. 87 → 174 DnB, 70 → 140 trap). | Measured grids; residual under 1% after folding. |
| **Echo out** | Echo throw on the last beat, dry cut on the one, tail rings for 1–2 bars, incoming lands on the downbeat. | Beat-synced delay. |
| **Cut** | Phrase-aligned cut on the one into a drum downbeat. The universal fallback. | Nothing, except a downbeat to land on when available. |

3:2 and 4:3 relations never make a blend.

### 6.2 How the planner chooses
The planner already scores template proposals with weighted terms; phase C extends it rather than replacing it.

1. **Candidate moments.** For the outgoing deck: phrase starts in the outro, breakdowns, the bar before a drop, and (for sets) tracklist boundaries and dull sections (low novelty, flat energy for 32+ bars). For the incoming deck: intro phrases, the bar before a build, the drop downbeat, user cues. Every candidate sits on a measured downbeat.
2. **Proposals.** Each move proposes `(exit moment, entry moment, length, FX, tempo path)` tuples that satisfy its preconditions.
3. **Scoring terms** (existing plus new):
   - *phrase*: both ends on 8/16/32-bar lines;
   - *structure*: exit section into entry section (breakdown→build, outro→intro, build→drop);
   - *energy*: the section energies against the set's energy arc and the Energy slider;
   - *harmonic*: Camelot distance after any varispeed; veto beyond the profile's limit;
   - *vocal/bass clash*: measured overlap, vetoed when both are measured;
   - *heat*: listening heat (where people seek to and replay, from the user's own plays and SoundCloud comments density) as a bonus for entry moments and a penalty for skipping them;
   - *cue*: user cues dominate; hot/memory cues and loops are strong candidates;
   - *novelty*: repeated moves and recently used FX cost more;
   - *risk*: each move carries a base risk; the personality sets how much risk it buys.
4. **"How adventurous"** maps onto the existing personalities:

| | Wedding DJ (Smooth) | Auto Mix (Club, default) | Junkie (Adventurous) |
|---|---|---|---|
| Moves | Blend, echo out, cut | + breakdown exit, drop-in, FX build (filter, echo) | + jump within set/track, loop-roll build, reverb/riser, tempo ramp, half/double bridge |
| Exits | Outro only | Outro, breakdown, user cues | Anywhere on a phrase line with a strong score |
| Loops | None | 8→4 bars, once | Up to 8→1 bars, two per hour |
| Tempo | ±2%, no ramps | ±4%, gentle ramps between tracks | ±8% with ramps and 2:1 bridges |
| Keys | ≤1 Camelot step | ≤1 step or relative | ≤2 steps, or a key-shift of ±1 semitone |

5. **Commit and revalidate.** The chosen move is frozen 16 bars before its first event, then revalidated against the live playhead, the queue and deck readiness one bar before. If revalidation fails it steps down the safety ladder, never up.

### 6.3 Safety rails
- **Never off-beat.** Every event that changes what you hear lands on a measured downbeat of the deck it affects, quantised by the timeline; a move whose landing point isn't measured can't be proposed.
- **Keys.** A blend longer than 4 bars needs harmonic compatibility within the profile limit; otherwise the move degrades to echo out or cut.
- **Vocals.** No overlap of measured vocals on both decks for more than one beat; unmeasured vocals cap the overlap at 8 bars.
- **Loops.** Loop length divides the phrase; at most 16 bars of looping per move and a profile limit per hour; loops start on a downbeat at a zero-crossing with a 2 ms fade; a loop never runs under a vocal.
- **Tempo.** No tempo step: every change is a ramp no faster than 0.5%/bar, and the set's tempo never leaves the profile range around the native tempo of the playing track.
- **Jumps.** A jump within a set needs a local tempo map at both points with grid quality above threshold and a target at least 32 bars ahead; never into the middle of the set's own internal transition.
- **Deadline.** If the incoming deck or window isn't ready 8 bars out, extend with a phrase loop (when allowed) or play out to a cut.
- **User intent.** Mix Now, Extend and Keep Queue Order override the planner; a user cue beats any heat or structure score.

### 6.4 How the harness evaluates moves
- **New fixtures:** tracks with labelled builds and drops; a 20-minute synthetic "set" with three internal transitions, drifting tempo and dull 32-bar stretches; loopable phrases with known zero-crossings.
- **Per-move metrics:**
  - landing accuracy: the incoming drop or entry downbeat against the outgoing phrase line, in ms and bars;
  - loop seams: click metric at every loop boundary, and phrase length divides correctly;
  - tension curve: momentary loudness and spectral centroid rise through a build, then the release lands within one beat;
  - tempo path: maximum tempo slope (%/bar) and no step larger than 0.05%;
  - jump continuity: phase error across the jump and no section repeated within 32 bars;
  - all phase A metrics (phase, downbeat, loudness, peak, bass, vocals) on every move.
- **Planner tests:** for each personality, the move distribution on a fixed playlist matches the table in §6.2 (Wedding never loops, Junkie never exceeds its loop budget).
- **Listening packs:** each move renders a before/after `.wav` set for the owner; a move ships only after he signs it off by ear.

### 6.5 Effort
5–7 engineer-weeks after phase B, plus listening sessions:
- move vocabulary on the timeline: 2 weeks;
- planner moments, scoring terms and personality mapping: 1.5 weeks;
- set/track jumps (windowed decks, tracklist boundaries, dull-section detection): 1.5 weeks;
- harness fixtures and move metrics: 1 week;
- tuning by ear: ongoing.

### 6.6 What phase A keeps open for phase C
- Grids keep the measured `beats` and `downbeats` arrays, and phase A adds `nearestDownbeat`, `phraseStarts` and `localBeatPeriod` on `BeatGrid`, so moments can be found on measured downbeats in drifting material.
- Exits and entries are `ExitPoint`/`EntryPoint` values with kind, phrase flag and confidence; phase C adds moment kinds (pre-drop, drop, dull) without changing the shape.
- Cue consumption stays in `assembleFeatures`; the DJ prep work's memory, hot and loop cues feed the same features.
- Execution goes through `MixTransitionPerformer` and the automation clock; phase B swaps the consumer underneath without touching the planner.

### 6.7 What phase B gives phase C
- Every move is a function returning a `MixTimeline`, anchored to a deck position and resolved on the exact sample. Moves compose, cancel as a group (`cancelTimeline`), freeze with pause, and replay offline sample for sample.
- Loops are sample-exact and loop in without jumping: the region is set, the deck plays into it and wraps with a 2 ms crossfade. That is the loop-roll build's foundation.
- Rate ramps, pitch, phase lock and linked seeks are timeline actions; tempo ramps and half/double bridges only need the planner to emit them.
- Echo and reverb are post-fader sends with their own feedback and return parameters, plus a send AU slot; FX builds, throws and washes are parameter ramps.
- Decks stream in windows, so a jump within a set (a second deck on a window of the same file) needs no new storage work.
- The harness replays any timeline through the core, measures kick placement per beat and clicks per stem; phase C's landing-accuracy and loop-seam metrics plug into the same report.

### 6.8 Phase C results
**What was built.**
- **Moves are timelines.** `MixMove` (`DJ/MixMoves.swift`) describes a move in bars; `MixMoveBuilder` turns it into a `MixTimeline` anchored on the exit downbeat. Every bar boundary is read from the measured downbeats, loops use whole-sample lengths, and tempo ramps are integrated, so a landing is a sample, not a guess. `MixTimeline.transition` hands any plan with a move to the builder; the performer, the live engine and the offline replay are unchanged.
- **Vocabulary.** Blend with bass swap; cut on the one; echo out (one-beat throw, two-bar tail); breakdown exit (low-pass on the outgoing breakdown, lows swapped mid-way); drop-in (the incoming build fades in under a rising high-pass on the outgoing, then lows swap on the drop downbeat, which lands on the outgoing phrase line); cut on the drop (echo throw, incoming starts on its drop downbeat); loop build (8×1, 4×1, 2×1, 1×2 = 16 bars, 8 of them repeats, with a high-pass sweep and reverb, cut into the drop); filter, echo and reverb builds over 4–8 bars into a cut; tempo ramp (outgoing ramps to the incoming tempo at ≤ 0.5 %/bar, then a 16-bar blend at the incoming's own tempo, so nothing drifts back afterwards); double-time bridge (2:1, residual ≤ 1 %); jump within a track or set (the second deck holds the same file; 16-bar locked blend into a phrase at least 32 bars and up to 12 minutes ahead).
- **Planner.** Move templates (`DJ/DJMoveTemplates.swift`) propose from phrase-line exits, labelled sections (MusicUnderstanding, or the user's Prep phrases, which win), `Drop`/`Break` hot cues, listening heat and tracklist boundaries. Scoring keeps the phase B terms and adds: a move-aware structure cost (build→drop, breakdown→intro), risk scaled by the personality, novelty against the last three moves, +0.1 for landing on the user's cue, heat (enter on replayed parts, don't skip them) and the energy target. Jumps are planned separately (`DJJumpPlanner`): dull, flat stretches are worth skipping, labelled builds and drops are worth landing on, the set's own transitions (tracklist boundaries ± 16 bars) are never touched, and waiting longer costs a little.
- **How adventurous.** Wedding DJ: legacy blends, echo out, cut. Auto Mix: plus breakdown exit, drop-in, cut on the drop, filter and echo builds, only in the last 30 % of a track and only when they beat the best long blend. Junkie: everything, including loop builds (two an hour), reverb washes, tempo ramps, bridges and jumps. Junkie's old `loopRollDown` (whose rungs didn't actually halve) and `tempoRampBlend` (no slope limit) are no longer admissible.
- **Rails** (`DJMoveRails`, applied to every plan, not just moves): a blend over 4 bars across keys beyond the profile's Camelot limit is vetoed; measured vocals on both sides may overlap at most a beat, and unmeasured vocals cap a move's overlap at 8 bars (the play-out blends keep their phase B lengths, which the TV tracker relies on); loops are capped at 16 repeated bars and the hourly budget; tempo moves at 0.5 %/bar and the profile range; every move needs measured downbeats on both decks, otherwise the planner cuts on the bar. Skip completes a move at once (or cancels a jump and skips), Pause freezes the timeline, a seek during a loop build cancels it, and Keep Queue Order still decides the incoming track.
- **Energy.** `AutoMixEnergy` gives a 1–10 target from, in order: a fresh heart rate while Match My Workout is on, a target sent from the iPhone over Companion (when the Apple TV is the Output), Follow the Night (warm-up, peak around midnight, cool-down), or the Energy slider. The planner prefers candidates near the target and moves that push towards it.
- **Heart rate.** iPhone: `HKAnchoredObjectQuery` on heart rate, primed by a centred "Match Your Workout" screen. Watch: Match My Workout starts an `HKWorkoutSession` with a live builder and sends heart rate to the iPhone every 5 s. The iPhone forwards the target to the TV (`dj_energy`). Both apps carry the HealthKit entitlement and usage strings; the Watch adds the workout background mode.
- **UI.** Settings › Auto Mix: Personality (with a one-line description of how adventurous it is), Follow the Night, Energy (Chill–Peak; a picker on tvOS), Match My Workout (iPhone, Watch). Now Playing ••• on iPhone/iPad: the next move as the section title ("Loop build into Glue, 16 bars"), Mix Now, Extend This (+8 bars). The Apple TV DJ panel and the Watch gain Extend; Companion carries `dj_extend`.

**Harness.** `AutoMixMovesTests` renders 15 move scenarios through the real planner, performer and render core (fixtures: a drop track with a labelled build, a 20-minute drifting set with three internal transitions, 87 and 174 BPM tracks, plus the phase A/B tracks with Prep labels), and gates each one:

| Scenario | Landing error (grid / kick audio) | Phase median / p95 | Dip / swell LU | Other |
|---|---|---|---|---|
| bass-swap | 0.009 ms | 0.009 / 0.009 ms | 0.0 / 0.6 | |
| cut | 0.009 / 0.08 ms | | 0.0 / 0.2 | |
| echo-out | 0.014 / 0.10 ms | | 0.0 / 0.2 | tail 2.9 s |
| breakdown-exit | 0.007 ms | 0.007 / 0.007 ms | 11.4 / 0.0 | the dip is the outgoing breakdown |
| drop-in | 0.003 / 1.7 ms | 0.003 / 0.003 ms | 4.9 / 0.2 | drop on the target bar (offset 0) |
| drop-on-the-one | 0.003 / 0.12 ms | | 0.1 / 0.5 | drop on the target bar (offset 0) |
| loop-roll | 0.025 / 0.09 ms | | 17.2 / 0.7 | high-pass sweep to 1.4 kHz |
| loop-roll-dry | 0.025 / 0.09 ms | | 1.4 / 0.2 | 5 seams, lag 0 samples, correlation 1.000 |
| filter-build | 0.003 / 0.14 ms | | 6.8 / 0.8 | |
| echo-build | 0.003 / 0.14 ms | | 5.3 / 0.6 | tail 1.6 s |
| reverb-wash | 0.003 / 0.14 ms | | 6.5 / 0.0 | tail 1.4 s |
| tempo-ramp | 0.001 ms | 0.007 / 0.007 ms | 13.1 / 0.6 | 0.31 %/bar, steps ≤ 0.004 %, no change after |
| bridge (87→174) | 0.005 ms | 0.005 / 0.005 ms | 0.4 / 0.4 | |
| jump-set | 0.003 ms | 0.002 / 0.003 ms | 0.1 / 0.5 | 232 bars (7:32) ahead |
| jump-track | 0.009 ms | 0.008 / 0.009 ms | 0.0 / 0.9 | 40 bars ahead |

Gates on every move: landing ≤ 3 ms from the true downbeat, entry on a downbeat, no clicks in the mix or either stem, true peak ≤ −0.3 dBTP, swell ≤ 3 LU, no near-silent hole (≤ 0.25 s more than 24 LU down), no missed anchors, a firing plan. Overlaps: phase median ≤ 3 ms, p95 ≤ 8 ms (beat-folded for 2:1). Blends and jumps: dip ≤ 1.5 LU; cuts and drop-ins ≤ 14 LU; builds ≤ 20 LU (the build is the dip). Cut landings: kick onset within ±5 ms of the outgoing kick clock. Loops: lag 0 samples, correlation ≥ 0.999. Drop-ins: target bar offset 0. Jumps: ≥ 32 bars. Tempo ramp: ≤ 0.5 %/bar, no step over 0.05 %, no change after. `testPersonalityMoveDistribution` plans an 11-track playlist with each personality and checks the table above (Wedding never loops, Junkie stays within its loop budget and uses at least three kinds of move); `testSafetyRails` checks the key, loop-budget and unmeasured-grid rails.

Phase B fixtures changed so the key rail doesn't turn their blends into cuts: `live-set-d` is now E minor and `vocal-intro-f` A minor.

**Listening packs.** `$TMPDIR/automix-c/listening/<scenario>.wav`, 10 s before each move to 15 s after. Start with `loop-roll.wav`, `drop-in.wav` and `jump-set.wav`.

**Phase B harness on this branch.** Every phase A/B gate passes (optimised build). `tracker-blend` misses two of the B′ gates added after the merge, with the same plan and the same render core as on the B′ branch: audio phase median 5.37 ms (gate 5) and dip 1.42 LU (gate 1). Its grid phase is 3.63 ms. In a Debug build the CPU gate also fails (30 % of real time), as it always has; CPU is gated on optimised builds.

**Known limits.**
- Synthetic fixtures only; nothing here has been checked on the owner's music yet, and every move still needs his sign-off by ear.
- Jumps run on the Junkie personality only and need measured downbeats on the set; on the TV that means a synced MusicUnderstanding result or the phase B′ tracker. The second deck reloads the same file from the mix cache, which costs a moment of disk work before each jump.
- ~~There is no riser sound~~ (§6.9).
- ~~The deadline rail plays out to a cut~~ (§6.9): it now loops the last clean phrase when the outgoing would run out.
- Match My Workout needs HealthKit on the App ID (see the report); the Watch workout is saved to Health.

### 6.9 Phase C follow-ups: riser and loop on deadline (2026-11-07)

**Riser.** `MixRiser` (`DJ/MixDSP.swift`) is synthesised in the render core, not a sample: band-passed stereo noise swept 350 Hz → 7 kHz with rising resonance, plus a pair of detuned sines gliding 110 → 880 Hz, swelling with the sweep. Two global parameters drive it (`riserLevel`, `riserSweep`), so it is sample-accurate like every other automation. `MixMoveBuilder.riser()` adds it to drop-ins, loop builds and filter or echo builds (never reverb washes, which bring energy down): over the last 8 bars (at least 2) before the landing, level up over the first third, sweep 0 → 1 to the landing, and a 1,024-sample release that ends exactly on the landing downbeat. Level is the owner's **Riser** setting (Off / Soft / Medium / Loud on tvOS, a slider on iPhone, iPad and Mac; default 0.5 of `MixRiser.fullScale` = 0.32 linear). Wedding DJ (the subtle personality) never plays it. The harness renders a riser-only stem (`solo` 2) for gating.

**Loop on deadline.** `MixDeadlineLoop.lastCleanPhrase` picks the latest 8-bar (else 4-bar) span of evenly spaced measured downbeats that ends at least 0.5 s before the end of the file and after the playhead. Two paths use it:
- *Outro too short / short track:* `MixTransitionPerformer.begin` works out where the outgoing would be when the timeline ends; if that is past the end of the file, it sets the phrase loop before scheduling, and moves the anchor to the loop start if the planned exit was beyond it. Loop builds and jumps are exempt.
- *Late incoming load:* when the next track isn't ready at the planned point and the last clean phrase is within reach, `DJSessionDirector` loops it ("Next track isn't ready yet — looping the last phrase.") and shifts the plan's exit to the loop start. When the deck is ready the transition anchors on the **next pass** of the loop: the core's deck-position anchors now know about loops (an anchor inside an active loop that the deck has already passed waits for the wrap, then resolves on the exact sample). A seek releases the loop; finishing the transition clears it.

**Harness** (`AutoMixMovesTests`, Debug build, TV simulator):

| Scenario | Result |
|---|---|
| riser-loop-roll (level 1.0) | landing 0.025 ms; riser peak −10.0 dBFS, −7.5 dB under the mix |
| riser-filter-build, riser-drop-in (default 0.5) | landing 0.003 ms; riser peak −16.5 dBFS, −13.8 dB under the mix |
| deadline-loop (16-bar blend from 6 bars before the end) | 8-bar loop on measured downbeats (0.01 ms), outgoing plays to the end of the blend, dip 0.0 LU, phase 0.01 ms |
| deadline-late (already looping, blend anchors on the next pass) | anchor on the wrap, landing 0.000 ms, phase 0.01 ms, no clicks |
| deadline-control (same as deadline-loop, loop off) | outgoing ran out 17.5 s before the blend finished; proves the case bites |

Click gates count the riser stem as part of the expected signal, alongside both deck stems: the riser is an intended sound. Riser gates: peak ≤ −9 dBFS at any level, ≤ −3 dB under the pre-move mix, present before the landing (≥ −40 dBFS), last sample above −60 dB within [−5, +0.1] ms of the landing (measured after the limiter's 64-sample look-ahead), silent (≤ −90 dBFS) after it. Deadline gates: loop 4 or 8 bars, both ends within 1 ms of a measured downbeat, the outgoing never stops more than 50 ms before the move finishes; the control must stop at least 1 s early.

**Real-music pack.** `testRealMusicPack` (skipped unless `AUTOMIX_REAL_SRC` and `AUTOMIX_REAL_OUT` are set) renders transitions between the owner's own tracks, analysed by the TV beat tracker, through the real performer and render core, and prints the timestamps to listen at. Audio stays local; nothing is committed.

**Still open.** ~~The deadline loop doesn't check for vocals in the looped phrase~~ (§6.10), and the late-load path is covered by the harness's pre-looped scenario rather than a director-level test. The riser has one voice; its timbre needs the owner's ear.

### 6.10 Engine quality follow-ups (2026-11-07)
- **Hand-over.** Playback is engine-owned from the first note, so the only same-track AVPlayer ↔ `MixEngine` hand-overs left are a track replayed into the engine while its AVPlayer still holds it, and the hand-back when Auto Mix turns off or the engine fails. On iOS and tvOS 27 `PlayerService` now parks that AVPlayer (paused, `setDisconnectedFromSystemAudio(true)`, item kept) instead of tearing it down, and on hand-back reconnects it (awaiting the completion) and reuses the item, but only after `endMixSession` has stopped the engine and only while no AVPlayer is active, so the two never play at once. Any other track, a deck hand-off, Clear Queue or a teardown discards it. macOS and older OSes keep the teardown.
- **Errors.** `MixEngineError.displayMessage`: "Couldn't download the audio.", "This track can't be mixed.", "Mixing isn't available right now." Decks, the Auto Mix fallback reason and the Mac Decks show it; the detail goes to `Log.dj`. Auto Mix works over AirPlay (§ decision 2026-11-06), so no AirPlay error is raised any more and the AirPlay line has no case.
- **Audio Unit latency** (§5b.5). `MixAudioUnitHost.latencyFrames` is read once when the unit is allocated. Each deck's dry path is delayed by its own insert's latency (so the insert's dry/wet bypass crossfade stays aligned), every deck is delayed by the worst insert latency minus its own, and the dry master waits for the send's latency before the send return is added. Delay changes crossfade over 256 samples. The audio is compensated, not the automation, so a deck's fader and EQ moves land up to one insert latency early. Gate: `MixEffectHostingTests.testAudioUnitLatencyIsCompensated` registers an in-process 1,000-sample delay unit that reports its latency and requires the two-deck and send renders to match the uncompensated reference shifted by exactly that latency (≤ 1e-4).
- **Stretcher on sustained sounds** (§5b.5). Drift splices search the whole ±4 ms drift range (was 60 %) and, when the best match correlates at 0.8 or better, crossfade over up to 1,024 samples (23 ms) instead of 256, bounded so the fade always ends before the next measured beat's anchor window; beat-anchored splices keep 256, so kick placement is unchanged. Gate: `StretchPadSpliceTests` stretches a six-partial sustained pad at 0.8, 2.4 and 4 % and requires the worst 10 ms level dip under 1.5 dB above 2 %; with `AUTOMIX_OUTPUT_DIR` set it writes `pad-stretch-2.4.wav`.
- **Deadline loop and vocals** (§6.9). `MixDeadlineLoop.lastCleanPhrase(vocals:)` takes the outgoing track's measured vocal ranges (`MixVocalMap`, recorded when the director builds the outgoing features; nil when vocals aren't measured). It picks the latest vocal-free 8- or 4-bar phrase, then a vocal-free 2- or 1-bar loop, and loops a phrase with vocals only when nothing else exists, because running out is worse. The loop seam crossfade is 256 samples (was 88). Gates: `MixDeadlineLoopVocalTests`, and `deadline-loop`/`deadline-late` at ≤ −1 dBTP true peak and no clicks in the mix or either stem.
- **Filter fade.** On phase-locked blends ("full through the middle" fader) the outgoing low-pass now sweeps over the second half of the window, once the incoming is at full, instead of over the whole window. Gate: `live-set-drift` dip ≤ 1 LU (was 2.0 LU, ungated).
- **Vocals rail.** `DJMoveRails.veto` now refuses any overlap longer than a beat while the outgoing's measured vocal is still going, or over measured vocals on the incoming, so a blend starts after the outgoing line has ended and lands where the incoming has none. Unmeasured vocals keep the 8-bar cap for moves.
- **Loop seams.** The deadline loop also rejects a phrase whose first and last bars differ by more than 6 dB on the track envelope (a fading tail wrapping back to a loud head was the "clip" in the owner's `6-deadline-short-outro.wav` at 22.29 s: the level falls to −42 dBFS RMS and jumps to −13 dBFS in 10 ms; no sample reached full scale and the peak sat at the −1 dBFS limiter ceiling).
- **Real-music pack was blind.** `AutoMixRealPack` fed the planner "measured" features with no vocals, no bass and A minor for every track, so it blended over lyrics and couldn't see key or bass clashes. It now plans on the TV tracker's own analysis (vocals and bass unmeasured, no invented key), which is what the Apple TV actually has. Real vocal ranges on the TV need MusicUnderstanding results from the Mac or iPhone (§5.5 queue pre-analysis).
- **Not yet measured.** The simulators were reassigned before the harness could run on this branch, so the new gates and the phase A/B/C harness have compiled (optimised tvOS test build) but not run; the next run must confirm them before merge. No real-music or Mac renders were made.

### 6.11 Loop mix, the owner's default (2026-11-07)
- **Move.** `MixMove.loopMix` (`LoopMixPlanner`, `MixMoveBuilder.loopMix`): loop 4 or 8 sparse, vocal-free bars of the outgoing after its payoff, start the incoming on its own sparse, vocal-free 4- or 8-bar loop with its lows killed, bring it to full over 16 bars, release both loops on a downbeat with a one-beat bass swap, then take the outgoing out over 4 bars (measured, it is more than 20 dB under the incoming two bars after the release, so a longer fade only adds bars of the incoming alone). The planner offers it before any other move when both tracks have measured vocals, a bar profile and measured downbeats or beat parity, and the levels and bodies either side are within 6 dB.
- **The outgoing only falls after the release.** Through the 8-bar fade-out the outgoing's mid and high bands fall linearly from 0 to −40 dB (`loopMixFadeDecibels`, about 5 dB a bar), on top of the low kill, the 900 Hz high-pass sweep and the fader. The old fade (the fader alone, held near full for the first bars, and a −12 dB high shelf in the second half) let a loop's own bar-to-bar movement read as a 4–7 dB "comeback". Most of that figure was measurement: 400 ms blocks caught an off-beat gap followed by a kick.
- **One shared gate** (`LoopMixMeasure` in `MixMetrics.swift`). The real-music pack and the offline check (`swiftc check.swift MixMetrics.swift`) run the same code on the same files, so their numbers agree to 0.1 LU. Each transition writes the mix, the post-fader stems and dry source stems. A dry stem is the source audio at the deck positions in the render log, loops included, with no fader, EQ or filter.
  - *Level step:* short-term loudness (3 s windows, K-weighted, 0.1 s hop), median over the 8 bars before the loops start and the 8 bars after the outgoing is gone. Gate: |step| ≤ 6 LU.
  - *Engine-caused holes:* in 400 ms blocks, the expected level is each active deck's dry level plus its slow engine gain (the median stem-minus-dry over ±2 s), summed by power. A block more than 3 dB under that is a hole. A dip in the only source playing is the music and doesn't count. Gate: none.
  - *Comeback:* the outgoing post-fader stem in 1-bar windows at a 1-beat hop, from the release to the end. Gate: no window more than 1 dB above the quietest window before it. *Gone:* outgoing below −60 dBFS after the finish.
  - *True peak:* ≤ −0.5 dBTP.
  - *Vocals and density:* no measured vocal in either loop or the incoming's release bars; both loops at or under the sparse density.
  - *Rule 21 (engine-caused dip ≤ 1.5 LU, swell ≤ 3 LU):* a hard gate in the verdict. The dip is the short-term mix level under the lower body, minus the music's own drop at that moment: each deck's dry stem against its own body (the outgoing's 8 bars before the loops, the incoming's 8 bars after the finish), taking the deck nearer its body. So a quieter bar in the incoming, or the outgoing's sparse loop, doesn't count; a fader, EQ or filter that takes level away does. The raw dip is printed beside it.
- **Real pack (5 pairs).** pretend→marionette and voodoo→pretend choose `loopMix` and pass every core gate. pretend→marionette: step −3.1 LU, comeback −1.1 dB, true peak −1.13 dBTP, rule-21 dip 1.8 LU. voodoo→pretend: step +3.2 LU (+3.1 in the offline check), comeback −0.6 dB, true peak −1.21 dBTP, rule-21 dip 0.4 LU. Moves harness: everything passes except `riser-loop-roll` clicks.count = 1 (maxRatio 1.723), which is identical in the earlier riser run and so predates this work. The other three pairs lack downbeats or parity on one side (jungle, darkknight, domino) or have no sparse windows.
- **Parity from harmonic change, tried and not trusted.** The tracker also votes parity from per-beat chroma and bass change (changes land on beats 1 and 3). On the real pack these votes disagree with drum parity on arise and marionette, where the drums are confident, and are weak everywhere (agreement 0.05–0.47). So they decide nothing unless the drums say nothing (|z| < 1.5) and the changes agree at 0.6 or better. No track in the pack reaches that, so darkknight and domino still have no parity. `BeatTrackerResult.parityEvidence` records drum, change and half-bar strength and agreement.
- **Rule 13, unknown vocals.** The 8-bar overlap cap applies to every plan, play-out blends included (`DJMoveRails.veto` runs on every proposal). When either side's vocals aren't measured, `Plan.incomingMidCutDecibels` is −9 dB. The incoming's mid band is held there from its start until the outgoing stops, then restored over 250 ms, on plain blends and on every move with an overlap except the loop mix, which needs measured vocals anyway.
- **Rules 11 and 12** (`DJMoveRails.vocalPhraseVeto`, every move except the loop mix). The outgoing may not start dropping inside a measured vocal phrase, unless that phrase ends within a beat. The incoming may not be entered inside a measured vocal phrase. With both sides measured, the incoming's first vocal must start at least a bar after the outgoing's last vocal in the window.
- **Exit placement (rule 5 and breakdowns), 2026-11-07.** `DJMoveRails.exitPlacementVeto`: a template blend or fade (no `MixMove`) may not start inside a breakdown (`exit.kind` or a breakdown section) or before `DJMoveRails.payoffEnd` (last measured-structure drop end, or last measured vocal phrase end, whichever is later), unless the exit is the user's preferred exit or the profile is Adventurous. Moves keep their own placement. When nothing passes, the existing ladder (clean cut at the end) applies.
- **Splices on sustained material, 2026-11-07.** When the nearby splice candidates correlate below 0.8 the stretcher also searches up to 1024 frames ahead (a full period down to 43 Hz) and takes that match if it correlates at 0.8 or better; drift splices only fire when the content has fallen behind (or run more than 1024 frames ahead). Every crossfade (splice, loop seam, seek) is gain-compensated from the measured energies and cross-correlation of the two streams, so its power stays constant (at most +6 dB). `StretchPadSpliceTests` now uses a level pad (harmonics of 100 Hz); the old triad beat by 9.6 dB in 10 ms windows with no stretch at all. Real pack at 0.97 and 1.024: fewer splices (about half) and lower worst splice dips.
- **Engine-caused blend dip, 2026-11-07.** `loudness.engineDipLU` replaces the raw dip in the blend gates: the short-term mix level under the lower body, minus the smallest own drop (dry level against its body) among the decks audible at that moment (post-fader within 12 dB of the louder). `grid-without-sections`, `silent-lead-in` and `live-set-drift` read 1.01–1.05 LU raw and 0.00–0.04 LU engine-caused: the outgoing's outro and the incoming's intro are about 1 dB under their bodies.
- **CPU gate.** Measured on an optimised build (`SWIFT_OPTIMIZATION_LEVEL=-O`), where it passes; a Debug build reads about 30 % from unoptimised Swift, not load.
- **Vocals on the tracker path, 2026-11-07.** The TV path already ran SoundAnalysis (`VocalClassifier`, `SNClassifySoundRequest` `.version1`, which tvOS has); its 0.4/0.22 hysteresis missed weak, steady voices (the house-a fixture voice reads 0.1–0.5 "humming"/"singing" against a 0.02 baseline, so only bars 41.6–42.9 were found). `VocalClassifier.ranges` adds a sustained path: the 8 s mean of the vocal curve at or above max(0.12, 3 × the curve's 20th percentile), trimmed to the first and last window that clears it, kept only when it holds for 16 s or more (a phrase; shorter weak evidence stays unmeasured, so brass in voodoo and pretend is not called a voice). `BeatTrackerResult.vocalSeconds` derives from the stored curve, so cached analyses pick it up without a re-analysis. house-a now reads 31.8–63.8 and 80.9–96.1 bars (truth 32–64, 80–96); house-g and vocal-intro-f, previously near empty, read 97 % and 62 % recall at 98–99 % precision. Real pack vocals are unchanged.
- **Runway decides the move (rules 14 and 27), 2026-11-07.** When both decks' vocals are measured, the outgoing has 16 or more vocal-free bars after its last vocal and the incoming 16 or more before its first, a firing long blend is kept over an FX move unless the profile is Adventurous (`PhantomDJEngine.runwaysFavourBlend`). The tracker pair offered an 8-bar echo build into the incoming's intro (structure cost 0.2 against 0.35, score 0.81 against 0.72); `tracker-blend` now takes the 16-bar bass swap at bar 96, as `measured-blend` does (engine-caused dip 0.65 LU, 58 phase pairs).
- **Rule 33 step-down, 2026-11-07.** When nothing fires and no user cue is involved, `PhantomDJEngine.stepDown` takes the latest unvetoed echo out (template or move), else the latest unvetoed blend of 8 bars or less, before falling back to the clean cut. The reasoning says it stepped down and why.
- **True-peak limiter, 2026-11-07.** `MixLimiter` detects peaks with the ITU-R BS.1770-4 4× polyphase interpolator (48 taps, 12 per phase) plus the sample itself, holds the worst peak over a 64-sample window, releases over 120 ms, and smooths the gain with a 64-sample moving average, so the gain is already down when the peak leaves the 69-sample delay (`lookahead`, which the engine's latency includes). Detection aims 0.1 dB under the ceiling; the sample clip stays only as a backstop. It runs in 512-frame chunks with `vDSP_conv`, preallocated buffers, no locks. `deadline-late` −0.82 → −1.08 dBTP, `deadline-loop` −0.92 → −1.08; CPU 0.59 % of realtime, max quantum 155 µs. Not yet located: why the deadline loops overshoot before the limiter. The likely place is the loop seam crossfade, whose correlation-based gain compensation can lift the sum by up to +6 dB; unmeasured, and the seam is unchanged.
- **Seek past the bass swap, 2026-11-07.** `wide-stretch-seek` seeks 7 s at half way, which lands after the bass swap: the outgoing's lows are killed and its fader falls from −33 to −58 dB over the 8 s left, so it has no kick for the A-against-B onset pairs, and the old nearest-onset match paired the incoming with kicks from before the seek (the ±225 ms "phase" was that). Onset pairs are now bounded to 0.6 of a beat. With no pairs after a seek, the gate uses each deck against its own grid: the incoming's kicks against its source beats after the seek, minus the outgoing's offset before it, plus the logged grid error. 16 pairs, 0.36 ms. Grid phase after the seek was 0.03 ms throughout, so the engine was in phase; the measurement was blind.



### 6.12 Timing: enable mid-track, content end, ratings (2026-11-08)
- **Enable mid-track (root cause).** With Auto Mix off the track streams on AVPlayer. Turning it on called `armMixSession`, which only starts the stream→engine handover for a track begun with `beginStreamingStart`, and `refreshPhantomPlan` refuses to plan while AVPlayer holds the track; so nothing happened until the next track started in the engine. Separately, a cached plan whose mix point had already passed was invalidated on every tick and recomputed to the same past point. Now `armMixSession` starts a mid-track handover (`EngineHandoverPolicy.midTrackHandover`: at least 8 bars to the end plus 4 bars of lead), the deck load schedules analysis, and every plan for the playing track takes `earliestExit` = playhead + 8 s (`DJSessionDirector.earliestExit(position:)`), which filters exits and loop-mix windows. `autoMixDidTurnOff` cancels the armed plan, the deadline loop and pending moves; an in-flight blend finishes.
- **Content bounds** (`DJ/DJContentBounds.swift`). From the 1 s envelope (2 s smoothing): body = 75th percentile of audible buckets, floor = 0.25 × body. Content runs from the first to the last bucket at or above the floor; a run of 20 s or more below it followed (or preceded) by at most min(60 s, 20 % of the track) is broken silence and trimmed too. Bar levels (floor = body − 18 dB) refine the bounds only where the tracker's bars cover the file. `decidePlan` plans on `planningView`: the outgoing trimmed to the content end (and the track's End time), with the energy floor and, when the outro (last bar at 0.6 × body to the content end) is 16 bars or longer, `latestMixStart` = content end − 8 bars. Incoming entries start at or after the content start (and Start time).
- **Rails** (`DJMoveRails.contentVeto`, every plan except a user mix-out cue): no mix start below the floor, none after `latestMixStart` (unless the payoff ends later), no entry before the incoming's content. Loop-mix windows must lie inside content and above the floor. The clean-cut fallback moves to `latestMixStart` on a downbeat. The deadline loop never loops past the content end.
- **Gates** (`AutoMixTimingTests`, 18 tests, also run on the Mac by compiling the planner sources with XCTest): six shapes (trailing silence, long fade, long outro, outro then silence, leading and trailing silence, broken silence) must start the mix above the floor and more than a bar before content end, and long outros at least 8 bars before it. Against the previous planner the gates fail on four shapes (mix at 263 s in silence after a 260 s content end; 6 and −1 bars before the end of a long outro), so they bite.
- **Real tracks** (`/tmp/automix-moves-src`, the moves harness pack, envelopes from the WAVs, the tracker's bars): darkknight, jungle and voodoo trim 2–6 s of tail; marionette's 30 s breakdown at 189–219 s is kept (music follows it). Plans: darkknight loop mix at 303 s (16 bars before content end), jungle 32-bar blend at 434 s (was 449 s, which ended exactly as the music stopped), marionette and voodoo unchanged. The pack has no long fading outro, so the long-outro rule is gated on fixtures only.
- **Ratings** (`DJ/AutoMixFeedback.swift`, `DJ/AutoMixRatingView.swift`). `Plan.feedback` records move, blend bars, energy, folded BPM distance, Camelot distance, section kinds and vocal overlap; after each Auto Mix transition `AutoMixFeedbackStore` offers it for 20 s. Ratings live in a local JSON file (Application Support, Caches on tvOS, excluded from backup), at most 500. `DJLearnedPriors` (last 200): signal = (up − down) / (n + 4) per move and per blend-length bucket; adjustment = 0.04 × move + 0.03 × length, clamped to ±0.06, added after the rails' adjustment. A move with signal ≤ −0.5 (for example 6 dislikes and no likes) is not chosen as the loop-mix override.
- **Performance moves.** After a plan for the playing track lands, the director plans `MixEngine.planPerformance` from max(content start, playhead + 4 s) to the mix point, avoiding the transition window, and schedules it once per track; a re-plan cancels moves overlapping the new window, a transition cancels the outgoing's moves in its window and all of the incoming's.

---

## 7. Phase D results (2026-11-07)

**Flow mode.** `DJFlowSelector` (`DJ/DJFlowSelector.swift`) is a pure beam search (width 4, depth 3) over the next 12 queued tracks, queue order first. Each step costs:
- *key:* Camelot distance (wheel steps, plus one for a mode change): 0 same, 0.15 for one, 0.4 for two; **vetoed beyond 2** unless either track is beatless (ambient genre, or only ambient sections);
- *tempo:* octave-folded (×2, ÷2) difference, scaled to the limit; **vetoed beyond ±6 %** unless beatless;
- *energy:* distance from the arc, which moves from the playing track's energy towards `AutoMixEnergy.target` (Energy slider, Follow the Night, heart rate, the iPhone's target) by at most the style's energy step per track;
- *genre:* family distance from `GenreFamilyGraph`;
- *repeats:* a track in the last 30 plays is vetoed; an artist from the last two plays (or earlier in the path) costs 0.8;
- *queue position:* 0.04 per place, so the queue wins ties.

Later steps are discounted (×0.7 per step) and the best path's first track is chosen. If everything is vetoed, the queue's next track plays. The planner then plans only the transition into that track (`DJSessionDirector.decideFlowPlan`), so moves, rails and fallbacks are unchanged.

**History.** The director keeps a log of the last 50 tracks that actually played (skips, reorders and queue changes included) and merges it with the queue's history: `recentTrackIds` (30) and `recentArtists` (6) are now real.

**Settings** (Settings › Auto Mix on iPhone/iPad, Mac and Apple TV, and the start sheet):
- **Style:** Smooth (Wedding DJ), Club (Auto Mix), Adventurous (Junkie).
- **Energy:** unchanged (Chill–Peak, Follow the Night, Match My Workout).
- **Blend:** Short, Normal (default), Long = 8, 16, 32 bars. It caps the style's bar range (Club: 16, 16, 16–32; Smooth: 8, 8–16, 8–32; Adventurous: 4–8, 4–16, 4–64). Transition length in seconds is no longer read by the planner.
- **Keep Queue Order:** on by default. On: only the next queued track is considered and nothing is reordered (Adventurous no longer reorders by default). Off: flow mode for every style, except where a collection or the start sheet says Preserve or Random.

**Published.** `PhantomDJEngine.Plan.selection` carries the chosen track, its queue index, the beam path and a short why ("Same key · 124 → 126 BPM · energy up"; "Next in the queue" when nothing is known). It reaches `DJSessionSnapshot.upcomingPlan` and `DJAutomaticMixDecision.selectionReason` for the live UI.

**Tests.** `AutoMixFlowTests` (12 deterministic tests): key veto at 3 steps and the beatless exception, folded tempo (62.5 and 250 BPM against 124 are 0.8 %; 133 is vetoed), track and artist cooldowns, the energy arc going up and down, queue first when everything fits, Keep Queue Order (no reorder even when the next track is vetoed, and Preserve/Random win over the toggle), beam look-ahead, the why string, history de-duplication, and Blend bars per style.

**Still open.** Suggested tracks after the queue (§2.2) aren't marked yet. The why string isn't shown anywhere until the live UI lands. Energy readings are still LUFS-based (§1.7), so the arc term is coarse on club masters.
