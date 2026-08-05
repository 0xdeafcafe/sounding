# In-Track Gestures and Tension — Architecture Spec

**Status:** design only. No repo file was edited.
**Companion to:** `design/specs/dj-engine-spec.md` (the transition engine). Read that first; this composes with it and reuses its scoring machinery verbatim.
**Author:** design agent, job 3fc7cb5a.

**Core thesis, in one paragraph.** A transition is a decision about two tracks at a boundary. A **gesture** is a decision about *one* track in its middle, and it is a different kind of object with different preconditions, a different budget, a different failure cost and — crucially — a different default. A transition *must* happen; the engine's fallback is `cutOnTheOne`. A gesture *need not* happen; the engine's fallback is silence. That asymmetry is the single most useful structural fact in this document, because it means the gesture planner can afford to veto on any doubt rather than costing it, and it means the null option must be a first-class candidate in the selection, not an afterthought.

---

## 0. What to build, in order

Ranked by musical payoff per engineering hour, against the graph as it exists today.

| # | Thing | New DSP | Size | Why first |
|---|---|---|---|---|
| 1 | **`buildToTheOne`** — bass out + low-pass closing over 8 bars, both snapping back on the one (§4.2) | **none** | S | The one gesture that is a complete, recognisable, genuinely musical DJ move using only `setEQ` and `setFilterCutoff`. This is the whole v1 in one template. |
| 2 | **`snap(on:toDeckSeconds:)`** — a 2 ms-resolution scheduler for the *release instant* (§6.5) | none | ~25 lines | The engine's `ramp` sleeps 16 ms. A release that lands ±16 ms late is at the flam threshold. Gestures do **not** need `play(at:)`/`sampleAccurateCue` — they need this, and it is an order of magnitude cheaper. |
| 3 | **The pure gesture core** — `GestureTemplate`/`GestureScoringTerm` registries, the softmax selector, the memory decay, the rate controller (§5, §6) | none | M | Nothing here touches audio. All of it is testable offline. |
| 4 | **`envelopeReEntry`** — the one structural feature the SoundCloud waveform can actually give us mid-track (§3.3) | none | S | Turns "self-releasing gestures only" into "gestures that land on the drop". |
| 5 | **`bassDrop`, `dropOut`, `gate`, `brake`** (§4.3–4.6) | none | S each | All four are pure parameter automation on nodes that already exist. `brake` in particular is free and nobody expects it to be. |
| 6 | High-pass band on the existing filter node → **`thinOut`** | `.highPassFilter` | S (~40 lines, already priced in the transition spec §3.2/T4) | The correct exit filter, and the second-best build filter. |
| 7 | Gapless loop re-arm → **`loopRollDown`, `loopHold`, `beatRepeat`** | `.loopResize` + `.sampleAccurateCue` | M (2–4 days) | The owner's headline ask. **It is not v1, and §4.7 explains exactly why in samples.** |
| 8 | `AVAudioUnitDelay` per deck → **`echoThrow`** | `.delayPerDeck` | M | |
| — | `backspin`, risers, reverb freeze | reverse playback / synthesis / reverb | L | Out of scope. §4.10. |

**The headline finding that changes the staging.** The owner's mental model is "low-pass filter and a looper". The low-pass is real and clean. **The looper is not clean**: `MixEngine.setLoop` re-arms via `player.stop()` + `scheduleBuffer(at: nil)` + `play()`, which drops one render quantum of audio (≈11.6 ms at 512 frames / 44.1 kHz, plus main-actor jitter) *on the downbeat transient* — the worst possible place. One arm is arguably maskable. A roll-down is four arms, so four dropouts, each on a "one". That is not a tension build; it is four glitches in a row. So **v1's gestures are the ones made of parameter ramps, not the ones made of transport moves**, and that is a happy accident rather than a compromise: parametric gestures are also the ones that abort inaudibly (§8) and the ones that are safe over a vocal (§4.1), which are the two properties that matter most when you cannot measure the material.

---

## 1. The reframe, made precise

### 1.1 Two objects, one engine

| | **Transition** | **Gesture** |
|---|---|---|
| Decks involved | 2 | 1 (the live deck) |
| Changes what is playing | yes | **no** |
| Must happen | **yes** — every track ends | **no** — silence is a valid answer |
| Fallback | `cutOnTheOne` | do nothing |
| Timing anchor | `(exitPoint, entryPoint)` pair | `(onset, release)` pair *inside one track* |
| Preconditions about | compatibility of two tracks | structure of one track |
| Failure cost | trainwreck; unrecoverable once committed | recoverable — abort and the record just plays |
| Frequency | ~12.9 per hour (Kim et al., 20,765 real transitions) | discretionary: 2/hr (Wedding) to 7/hr (Junkie) |
| Repetition tolerance | high — every mix is "a mix" | **low** — a repeated trick is the failure |

The last row is the reason this needs its own selection model. Nobody notices that you bass-swapped twelve times in an hour; that is just competent mixing. Everybody notices that you did the same filter build four times.

### 1.2 The line between them, stated so it never has to be re-litigated

> **If the release returns to the same track, it is a gesture. If the release hands over to a different track, it is a transition template with a staged lead-in.**

This is not a technicality — it settles a real ambiguity in the existing code. `LoopRollDownTemplate` in `DJTemplates.swift` builds an 8→4→2→1 ladder and then *cuts to deck 2*. Under this rule it is correctly a `TransitionTemplate`, and it stays exactly where it is. The identical ladder that releases back into the same record is a `GestureTemplate`. Same stage vocabulary, same capabilities, different registry, different budget, different scoring terms. That is the whole relationship.

### 1.3 The release contract

Every gesture is a triple `(onset, hold, release)`:

- **`onset`** — a grid instant where the gesture begins.
- **`hold`** — the span over which expectation is denied.
- **`release`** — a grid instant where normal playback resumes **and something arrives**.

There are exactly two ways to satisfy "something arrives", and the distinction is load-bearing because it decides what the engine needs to know:

**Class 1 — self-releasing.** The arrival *is* the gesture's own termination. The bass coming back, the filter snapping open, the loop letting go, the silence ending. The release event is manufactured by the engine and therefore guaranteed. **These need only a trustworthy downbeat at the release instant.** No structure, no sections, no drop detection.

**Class 2 — event-seeking.** The release must coincide with an arrival *in the material* — a drop, a section boundary, a re-entry. The engine is riding the record's own architecture. **These need structural knowledge we mostly do not have** (§3), and when the predicted event fails to arrive the gesture has nothing to land on.

> **v1 is Class 1 only.** Class 2 is admitted exactly when `envelopeReEntry` (§3.3) or a user cue point (§3.4) supplies the target, and it degrades to Class 1 on failure (§8.3) rather than continuing to build into nothing.

That split is the design's main simplification and it is the reason a good gesture system is affordable at all. **A gesture does not need to understand the track to work; it needs to understand the track to avoid doing damage.** The mechanism (§2) runs on the metrical grid, which we can measure well. The damage-avoidance runs on arrangement, which we cannot. So the constraint set is "what must I know to not make a mistake", and that set is much smaller and much cheaper than "what must I know to be right".

### 1.4 Composition with the transition engine

Three rules, all checkable:

1. **The transition owns the deck from `exit.seconds − lockout` onward**, where `lockout = max(8 bars, plan.overlapSeconds)`. No gesture may be *admitted* whose `release` falls inside that window.
2. **A gesture in flight when a transition becomes due aborts immediately** via its `AbortPlan` (§8). The transition never waits.
3. **A gesture and a transition never share a stage list.** If you want a build into a swap, that is `loopRollDown`/`filterBuildOut` in the *transition* registry, and it is planned by `DJPlanner` with the incoming track in scope.

---

## 2. The mechanism — why any of this works

Labels: **[V]** verified against a fetched source with a URL. **[V-dossier]** verified in the transition engine's own research pass (`dj-engine-spec.md` §1, which carries the URL). **[R]** recalled and **not** independently verified in this pass — treat as a hypothesis, not evidence. **[A]** my own arithmetic or derivation, checkable.

### 2.1 Tension is expectation plus delay, and that is a mechanism, not a metaphor

**Meyer, *Emotion and Meaning in Music* (1956).** The central claim is that affect arises when a tendency to respond is *arrested or inhibited* — not when something unexpected happens, but when something expected is prevented from happening. Expectation itself is learned from style: the listener has internalised what this kind of music does, and meaning is generated by the interaction between that internalised grammar and what actually occurs. **[R]**

**Huron, *Sweet Anticipation* (2006)** — the ITPRA theory, five response systems across the outcome:

| | System | Timescale | What it does |
|---|---|---|---|
| **I** | Imagination | long, before | imagining possible futures motivates present behaviour |
| **T** | Tension | immediately before | arousal and attention rise in proportion to the **uncertainty** and the **importance** of the impending event; the body physiologically prepares |
| **P** | Prediction | immediately after | rewards *accurate prediction*, **independently of whether the outcome was good** |
| **R** | Reaction | fast, after | automatic, worst-case-biased |
| **A** | Appraisal | slow, after | conscious evaluation |

**[R]** for the five names and their ordering; the *interpretation* below is mine.

Huron also separates three kinds of expectation, and the distinction does real work here: **schematic** (learned from the style — "dance music moves in eights"), **veridical** (memory of *this specific track*), and **dynamic** (statistics of the piece as it unfolds). **[R]**

**Three consequences that the design is actually built on.** These are derivations **[A]** from the above, and each of them is a rule elsewhere in this document rather than colour.

**(a) The prediction response is why the release must land exactly where expected.** If accurate prediction is rewarded *independently of outcome quality*, then a release that lands precisely on the beat the listener was counting toward is rewarded twice — once for the resolution, once for having been right. A release that lands 200 ms late is not "slightly worse"; it converts a double reward into a prediction *failure*, which is the one thing the mechanism punishes. **This is why §6.5's `snap` helper is item 2 in the whole build order, ahead of every gesture but one.** The travel can be sloppy. The arrival cannot.

**(b) The tension response scaling with *uncertainty* is why a build with an obvious endpoint builds less.** A 32-bar trance riser telegraphs exactly when it lands; the listener's uncertainty is near zero, so the tension response has little to work with — what carries it is *importance*, not uncertainty. A loop roll-down does the opposite: it keeps importance constant and *raises uncertainty about when*, by shortening the period at which the release could plausibly occur. **This is a real, structural argument that the roll-down is the strongest gesture in the catalog** and that the owner's instinct to want it is correct, quite apart from taste.

It is also the argument behind §5.6's `breakdownLength` inversion: a genre that supplies its own long, legible, high-importance builds does not need the engine to add uncertainty on top, and a genre that supplies none has nothing but what the engine adds.

**(c) Schematic expectation has to be *established* before it can be violated.** The 8-bar grammar is learned from the style, so it transfers across tracks — but the *phase* of it does not. A listener 8 bars into an unfamiliar record does not yet know where its downbeats sit relative to its phrases. **This is the entire justification for the "no gesture in the first 16 bars" gate** (§4.2, §5.2's `placement` term). The number 16 is inferred, not measured — **E-G4**.

And **veridical** expectation is why §5.7 recommends treating a track the user has *liked* as higher-risk: they know where this record's payoff is, so a gesture that agrees with it is amplified and one that contradicts it is heard as an error rather than as a surprise.

**Contrastive valence.** Huron's account of why a violated-then-resolved expectation can feel *better* than an unviolated one: the fast, worst-case-biased reaction response is negatively valenced, the slower appraisal is positive, and the contrast between them amplifies the pleasure. **[R]** — the concept and the name are recalled and the mechanism should be treated as a plausible account rather than a settled finding. What matters for the design is weaker and safer: **a gesture must resolve, because the whole affective payoff is in the resolution, not in the disruption.** Every abort path in §8 exists to honour that.

### 2.2 Phrase structure is the grid being violated

The 8/16/32-bar grammar is what a mid-track gesture actually operates on, and the transition engine's research pass established the practitioner side of it directly:

- 4 beats = 1 bar; **8 bars = 32 beats = one phrase**; "music changes *naturally* at the end of these 32-beat phrases". Failure symptoms named explicitly: "Melodies clash", "Drops hit at the wrong time", and — the line that matters most — **"your mix will sound forced, even if the BPMs are matched perfectly."** **[V-dossier]** (`dj-engine-spec.md` §1.5, djkit.com / djtechtools.com)
- Applies to "house, techno, trance, drum & bass, and EDM"; "hip-hop, open-format, or older disco can be less rigid". **[V-dossier]** — which is exactly the `GenreProfile.phraseStrictness` axis, already in the codebase.
- Kim et al.'s 20,765 real transitions: the transition-length histogram **"has peaks at every phrase"**, marked every 32 beats. **[V-dossier]**

**What goes wrong at each offset** — from the same pass, and it transfers directly to a gesture's release **[V-dossier]/[A]**:

| Release offset | Result | Severity for a gesture |
|---|---|---|
| **1 beat** | in 4/4 the kick is on every beat, so there is **no flam at all** — but the backbeat inverts | **Fatal, and invisible to any timing metric.** This is why §4.4 requires *measured* downbeats and not merely a grid. |
| 2 beats | snares land on kicks | fatal |
| **1 bar** | beat- and backbeat-aligned; the release simply arrives 1.875 s early at 128 BPM | survivable, structurally wrong — reads as "it let go too soon" |
| 8 bars | the release lands in the middle of the next phrase | the gesture reads as arbitrary |

**Academic grounding for EDM's metrical grammar.** Butler, *Unlocking the Groove: Rhythm, Meter, and Musical Design in Electronic Dance Music* (2006), is the standard reference for metrical structure, ambiguity and the role of cyclic repetition in this repertoire. **[R]** Solberg & Jensenius have run empirical work on break–buildup–drop sequences and listener response. **[R]** Neither was fetched in this pass; both are the right places to look for **E-G4**'s prior art.

**Phrase durations [A]** — worth having in the fixture library, and the 128 BPM column is the tidy one:

| Tempo | 1 bar | 4 bars | 8 bars | 16 bars | 32 bars |
|---|---|---|---|---|---|
| 90 | 2.667 s | 10.7 s | 21.3 s | 42.7 s | 85.3 s |
| 128 | 1.875 s | 7.5 s | **15.0 s** | **30.0 s** | **60.0 s** |
| 140 | 1.714 s | 6.9 s | 13.7 s | 27.4 s | 54.9 s |
| 174 | 1.379 s | 5.5 s | 11.0 s | 22.1 s | 44.1 s |

### 2.3 Spectral tension — the one claim I would not bet the design on

The DJ convention is unanimous and directly sourced: **"Turn the filter knob to the left, and you progressively introduce a low pass filter… Turn it to the right, and you're getting a high pass filter."** Low-pass brings a track in "underwater" and opens it — the build/reveal move. High-pass thins the outgoing, stripping kick and bass first. Durations: **2–4 bars for a flavour move, 8–16 bars for a full build/reveal**; Traktor's own tutorial moves the filter "over… the last four bars of a musical phrase". Resonance guidance: Q ≈ 0.7 wide vs 1.5 narrow, resonance up to 2.5 "for added energy", watch the 2–4 kHz "resonance concern range"; and the practitioner rule **"keep filter resonance low: a little movement helps, squealing does not."** **[V-dossier]** (`dj-engine-spec.md` §1.10 — digitaldjtips, learningtodj, unison.audio, Traktor)

Those numbers are why §4.2 uses an 8-bar default with a `{4, 8, 16}` parameter space and caps resonance at 0.25 (→ `bandwidth = 1.525` octaves), and why Wedding caps it lower still at 0.15.

**But the *mechanism* is weaker evidence than the practice.** The claim "closing a low-pass raises perceived tension" is DJ consensus, and there is a plausible psychoacoustic story — spectral centroid correlates with perceived arousal in continuous emotion-rating studies **[R]** — but I have not verified a controlled study showing that *removing high frequencies raises tension* as distinct from *lowering arousal*, which is arguably the opposite prediction. There is a real possibility that the filter build works for a different reason entirely: not because muffling is tense, but because **it is a legible, monotonic, reversible removal of information whose restoration is a guaranteed event**. On that account the tension is in the *pending restoration*, not in the spectrum — which is a purely Meyer/Huron account and needs no spectral claim at all.

That distinction is not academic. If the second account is right, then:

- the depth of the filter matters less than the *legibility* of its trajectory (favour a smooth monotonic sweep over a deep one),
- and the `brightness` gating axis in §5.6 is the wrong control — it should be gated on whether the *removal is audible at all*, which is closer to "does this record have anything above the cutoff", which `brightness` approximates but does not measure.

**E-G5** settles it cheaply: A/B `buildToTheOne` with and without the filter leg, holding the bass drop constant. Until then, the filter leg's weight is folklore-backed practice, and the document should say so rather than dress it up.

**Density and layer-addition as build.** Farbood's parametric temporal model of musical tension (Music Perception, 2012) treats tension as a weighted function of several parameters — loudness, pitch height, harmony, onset frequency, tempo — integrated over a memory window, and reports an **asymmetry between how tension rises and how it falls**. **[R]** — the existence of the model and the asymmetry are recalled; **no parameter values or time constants should be taken from this document.** §5.5's ratchet (tension rises in steps of ≤0.09 per gesture, discharges by ×0.55 on a re-entry) is *shaped* by that recalled asymmetry and calibrated against nothing.

### 2.4 Repetition, habituation, and why there is a budget

Margulis, *On Repeat: How Music Plays the Mind* (2014), is the standard treatment of repetition's psychological effects — the shift toward participatory, embodied listening; the speech-to-song illusion; the inverted-U of the mere-exposure effect. **[R]**

**The thesis, cited.** Bhandari & Colton, EvoMUSART 2024, arXiv:2403.07995 **[V]** (https://arxiv.org/pdf/2403.07995), summarising Burns:

> "**Repetition gains meaning through its relationship with change. Both endless repetition and constant variation could lead to monotony.** Thus, repetition and change are opposite possibilities from moment to moment in music. The tension between them can be a source of meaning and emotion."

That is §5.1(c)'s budget argument almost word for word, and it is the reason budget and memory are two dials and not one: *endless repetition* is the memory failure, *constant variation* is the budget failure, and both end in the same place.

Two further points from the same source that usefully limit how hard this has to work. Listeners "remember specific impactful moments and distinct fragments rather than entire compositions, highlighting the selective nature of musical memory" **[V]** — **the engine only has to be non-repetitive at the granularity a listener actually retains**, which is direct support for §5.4's deliberately coarse signature quantisation. And an explicit carve-out for exactly this case: "some contexts like video game and social media music require adaptive, event-driven approaches… long-term structural plans around musical form might be impractical, as the musical narrative needs to be flexible and responsive." **[V]** A DJ set built from a live queue is that case.

**A real habituation number, at last.** Schellenberg, Corrigall, Ladinig & Huron (2012) used exposure counts of **1, 2, 4, 8 and 13**, and found liking for a repeated item **declining at p < .001** while a contrasting item held its value (F(1,44) = 8.32, p = .006). **[V]** So the inverted-U's downslope is reachable inside a single listening session at single-digit exposure counts. Over a two-hour set at Junkie's 7/hour, an exact signature that recurred freely would hit 14 exposures — past the top of that range. §5.4's decay holds it to 3–4. **That is the first piece of quantitative support this document has for the memory half-lives**, and it is the number to re-derive them against if they ever need tuning.

The rate anchor is still the empirical one: **Kim et al. measured 12.9 transitions per hour** across 1,557 real mixes and 20,765 transitions. **[V-dossier]** That is the *mandatory* event rate. §5.5's discretionary budgets — 2/hour for Wedding, 7/hour for Junkie — put gestures at **15%** and **54%** of it. **[A]** Above the mandatory rate, a gesture stops being punctuation and becomes processing.

### 2.5 Where a gesture may go — what is musically defensible from what we can detect

Pulling §2.1–2.4 together with §3's signal ledger, the placement rules and their justifications:

| Rule | Justification | Detectable? |
|---|---|---|
| **Not in the first 16 bars** of a track | schematic expectation transfers across tracks but its *phase* does not — §2.1(c) | yes, trivially. **E-G4** for the number |
| **Not inside a low-energy region** | a subtractive gesture in a breakdown removes nothing, and there is no established full-band state to deviate from | **yes** — this is exactly what the envelope *can* see (§3.2) |
| **Not within 8 bars after an energy return** | the record just discharged its own tension; adding more immediately reads as not listening | yes, from `envelopeReEntry` |
| **Preferentially in the 8–16 bars before a detected energy return** | you are riding the record's own build, and the release gets the record's payoff — the strongest placement available | **only when `envelopeReEntry` fires**, which is the fraction **E-G3** measures |
| **Never across a vocal hook** | a loop repeats a word, a cut truncates one — the loudest possible mistake, and the one a listener attributes to the machine rather than to the music | **no, not today.** Cue, then MU, then genre prior — §8.4. This is why the rhythmic family is gated on it and not on the DSP |
| **Release on a phrase boundary, not a bar line** | §2.2's offset table: a bar-early release is "it let go too soon"; a phrase-aligned one is a decision | yes, when the grid is measured |
| **32-bar boundaries in strict genres** | `phraseStrictness ≥ 0.85` (trance, big room) — the arrangement genuinely moves in 32s and a 16-aligned release is audibly early | yes, from the genre profile |

Two of those seven are fully detectable today, three are detectable when a grid exists, one depends on `envelopeReEntry` firing, and one is not detectable at all. **That ratio is the honest summary of this whole design's evidential position**, and it is why the parametric family — the one whose worst failure is a slightly-short filter sweep — is what ships first.

### 2.6 What the literature does not support, said plainly

- **No quantitative threshold for how long a build can be sustained before it stops working.** I could not source one, and I doubt a general figure exists — it is plainly genre- and context-dependent. §4's ladder caps (4/8/16 bars; `maxLoopBars` 8/32) come from **DJ hardware conventions**, not from perception research: rekordbox's beat loop spans 1/32–32 beats, the CDJ-3000's BEAT LOOP defaults to 4 with halve/double, Serato's Loop Roll spans 1/32–32. **[V-dossier]**
- **Nobody could source who originated the loop roll.** **[V-dossier]** — the transition spec's research pass tried and failed. Do not attribute it.
- **The 4 → 2 → 1 → ½ → ¼ halving build is given identically by two independent practitioner sources** and is therefore convention, not theory. **[V-dossier]**
- **No source states a single flam threshold.** It is transient-dependent: ~7.5 ms for a castanet-class attack, ~75 ms for a soft one; Mixxx's design document uses **±25 ms** and is the only figure from an actual DJ-software design process. **[V-dossier]** The profiles' `maxDriftMs` (10/25) already encode this and gestures reuse it rather than inventing a second budget.
- **The contrastive-valence account, Farbood's asymmetry, the spectral-centroid/arousal link, and the 16-bar entrainment floor are all [R].** Four load-bearing pieces of §2 are recalled rather than verified. They are labelled as such at each use, and the design is arranged so that each one being wrong costs a parameter rather than a structure: if spectral tension is folklore, `buildToTheOne` loses its filter leg and keeps its bass leg; if 16 bars is wrong, one gate moves.

**Citation-hardening — partially delivered.** A dedicated literature pass was commissioned alongside this document. **Its stochastic-selection and repetition findings have landed and are integrated** — into §2.4 (Bhandari & Colton; Schellenberg et al. 2012), §5.3 (Holtzman et al.; Performance RNN; CTRL; Paulus et al.), §5.4 (Vande Veire's transition matrix, which produced a real design change) and §10 item 24 (novelty search). **The expectation-theory half — Meyer, Huron/ITPRA, Farbood — has not.**

**Five specific claims should still be upgraded from [R] to [V] or struck**, in descending order of how much they matter:

1. **Huron's prediction response rewarding accurate prediction independently of outcome valence.** This is the single most load-bearing recalled claim in the document — it is the argument for §2.1(a), which is the argument for `snap` being build-order item 2. If it does not survive contact with the source, the timing precision is still justified by the §2.2 phrase-offset table, but the *reason* changes.
2. **Whether closing a low-pass genuinely raises tension**, or whether the effect is entirely the pending-restoration account. §2.3 and **E-G5**.
3. **Whether "contrastive valence" is Huron's own named concept** and what its mechanism actually is.
4. **Farbood's rise/fall asymmetry**, and whether any of her time constants are usable for §5.5's ratchet.
5. ~~**Any quantitative habituation threshold.**~~ **Answered** — Schellenberg et al. (2012), exposure counts 1/2/4/8/13, liking declining at p < .001. Integrated into §2.4 and now the anchor for §5.4's half-lives. Margulis herself remains **[R]** but is no longer load-bearing.

None of the remaining four changes the architecture. All four change a number or a justification, and §12 lists each of them again under "inferred".

**And one honest negative result that the pass did establish:** **no perceptual study anywhere validates weighted-stochastic gesture selection over deterministic selection, in DJ or game audio.** Vande Veire's FSM was never ablated; their evaluated claims were about track selection, not the selector. §5.3 carries the caveat at the point of use. The argument for §5 is a good argument from mechanism and from cross-domain evidence — it is not an evidenced result in this domain, and **E-G10** below is what would make it one.

---

## 3. What the system can actually know

This section constrains everything else, so it comes before the catalog rather than after it.

### 3.1 The signal ledger

| Signal | Available for | Resolution | Trust | Source of the claim |
|---|---|---|---|---|
| **User cue point** | tracks the user has marked | exact | **highest** | a human said "this moment matters" |
| **`BeatGrid`** (MU `.rhythm`) | deck-loaded tracks only (local `.caf`) | `beats: [CMTime]`, `bars: [CMTime]` | **high** — 10/11 exact vs Serato ground truth, one clean 2× octave error | `mu-findings.md` Q3 |
| **SoundCloud waveform envelope** | **every track, free, no analysis** | `width` samples over the whole track (typically 1800) → `duration/1800` s per bucket | **medium in quiet regions, near-useless in the loud body** | `WaveformService.swift` + measurement below |
| MU `.structure` `sections` | deck-loaded only | often degrades to periodic ~8-bar chunking | **low — do not build on it** | `mu-findings.md` Q4 |
| MU `.structure` `phrases` | deck-loaded only | base grain 1–4 bars, not 8/16/32 | **low as delivered**; needs aggregation | `mu-findings.md` Q4 |
| MU `.key` | deck-loaded only | 8/11 (73%) exact | medium-low | `mu-findings.md` Q3 |
| MU `.instrumentActivity[.vocal]` | deck-loaded only | ranges | **unmeasured — name the experiment (E-G6)** | not exercised in the spike |
| `GenreProfile` axes | metadata, always | 8 perceptual axes + `phraseStrictness`, `breakdownLength`, `halfTimeAffinity` | medium | `GenreTaxonomy.swift` |
| `SetArc`, gesture history, elapsed time | bookkeeping | exact | 1.0 | injected values, §7 |
| User likes / play count | metadata, always | boolean / integer | medium, **unused today** | §5.7 |

### 3.2 The picket fence — the fact that constrains this whole design

`WaveformService.displayBars`' own documentation records a measurement over five real tracks from the owner's library (a Darude edit, a Bicep/Switch Disco edit, a Cosmic Ratio bootleg, an Adriatique edit, a CYRIL remix), resampled to 200 buckets:

> p50 ≈ **0.82–0.92**, p95 ≈ **0.89–0.95**, and **within the loud body the standard deviation is 0.011–0.06**.

That is not a downsampling artefact — the same material measured with more mean weight is no better. It is a property of modern mastering: a limiter's whole job is to make the loud parts the same loudness.

**Consequence, stated bluntly: the SoundCloud envelope cannot see mid-track structure in loud material.** Between the first drop and the outro, every bucket is within a couple of percent of every other bucket. A build, a drop, a chorus, a bar of hats — all identical to the envelope. `PhantomDJEngine` works *because it only looks at the outro*, where the envelope finally has dynamic range. Point the same walk at bar 96 of a limited techno record and it returns nothing.

Two things survive, and they are the only two:

1. **Amplitude falls below the local median.** A limiter can make loud things equally loud; it cannot make silence loud. Real dropouts — a breakdown that actually strips the kick, a bar of near-silence, a beat drop-out before a drop — are visible as genuine dips. This is what Phantom's `quietThreshold = max(0.05, median · 0.55)` already keys on.
2. **The rising edge back out of one.** Which is the drop. See §3.3.

Everything else the envelope "shows" mid-track is noise, and the design must not read structure into it.

**Resolution, done properly.** The envelope is *not* one bucket per second — that is `PhantomDJEngine`'s own resampling, not the source. The raw document has `width` samples (usually 1800) spanning the whole track:

| Track length | s/bucket at 1800 | buckets per bar @128 BPM (1.875 s) | buckets per beat |
|---|---|---|---|
| 3:00 (180 s) | 0.100 | 18.8 | 4.7 |
| 5:00 (300 s) | 0.167 | 11.2 | 2.8 |
| 7:00 (420 s) | 0.233 | 8.0 | 2.0 |
| 10:00 (600 s) | 0.333 | 5.6 | 1.4 |

So **bar-level resolution is genuinely available for anything under ~8 minutes** and beat-level is not. Gesture placement is a bar-level decision, so this is adequate — but only if the gesture code reads the raw `Waveform.samples`.

**It does not today, and this is a real defect for gestures.** `PlayerService` (≈line 1926) builds the feature envelope as:

```swift
let bucketCount = max(8, Int((track.duration / PhantomDJEngine.bucketSeconds).rounded()))  // bucketSeconds == 1.0
envelope = waveform.resampled(to: bucketCount)
```

**One bucket per second — 0.53 buckets per bar at 128 BPM.** That is below bar resolution, and it throws away a factor of 6–10 of information that arrived over the network for free. It is entirely correct for Phantom's outro walk, which is looking for multi-second calm regions and explicitly documents 1 Hz as "enough resolution to find a breakdown without chasing noise". It is not correct for anything that has to name a bar.

> **Recommendation: `TrackFeatures.envelope` carries the raw document at its native `width`, and `PhantomDJEngine.plan` resamples to 1 Hz itself at its own call site.** One line moves, no behaviour changes for the existing outro walk, and the entire gesture layer becomes possible. This is v1 item 4 and it is the cheapest enabling change in the document after `snap`.

### 3.3 `envelopeReEntry` — the one mid-track structural feature worth extracting

The only defensible mid-track structural claim the envelope supports is: *the energy went away and came back*. That returning edge is a drop, or at minimum the return of the beat, and it is the highest-value release target in the whole track — a Class 2 gesture that lands there gets the record's own payoff for free.

```
Pure. Input: raw envelope, duration, optional BeatGrid. Output: [ReEntry].

let bucketSeconds = duration / Double(envelope.count)

// Smooth FIRST, and with a MEDIAN filter, not a mean. At native resolution
// (0.10–0.33 s/bucket) a single loud transient or one quiet 16th will break an
// otherwise-clean run, and a mean filter would smear the very edge we are
// trying to find. A median filter suppresses impulses and preserves step
// edges, which is exactly the trade this needs.
let w = max(3, oddNearest(barDuration / bucketSeconds))   // ~1 bar, forced odd
let e = medianFilter(envelope, window: w)

let median   = median(e)                              // whole-track, as Phantom
let lowGate  = max(0.05, median * 0.60)
let highGate = median * 0.90

Walk forward. A candidate is a maximal run [i, j) with e[k] <= lowGate
for all k in [i, j), followed by the first index j where e[j] >= highGate.

Admit the run when ALL of:
  * (j - i) * bucketSeconds >= 2 bars              (a dip, not a snare gap)
  * (j - i) * bucketSeconds <= 128 bars            (a breakdown, not the outro)
  * mean(e[j ..< j + 2 bars]) >= highGate           (it stayed back, not a blip)
  * j is not within 8 bars of the end of the track (that is the outro, Phantom's job)

Emit ReEntry {
  seconds:     j * bucketSeconds, snapped to the nearest bar line when a grid exists
  dipBars:     (j - i) * bucketSeconds / barDuration
  lift:        mean(e[j ..< j+2bars]) - mean(e[i ..< j])                 // 0…1
  confidence:  min(0.75, 0.30 + 0.06 * dipBars + 0.8 * lift)
}
```

Confidence caps at **0.75** deliberately: this is an amplitude heuristic, not a section detector, and it must never outrank a measured section or a user cue. The `reasoning` string must say "energy returns at 3:12" and never "the drop is at 3:12".

**What it will and will not find.** It will find breakdown→drop on anything with a real breakdown. It will find nothing at all on a relentless tool track, and nothing at all where the "breakdown" is a filtered-but-equally-loud atmospheric section — which on limited masters is common. **That is the correct behaviour**: no re-entry means no Class 2 gesture, and the engine falls back to Class 1 self-releases, which is exactly the honest degradation. Expect this detector to fire on somewhere between a third and two thirds of the library; **E-G3 measures it** (§11).

**Symmetrically**, the falling edge (`envelope` crossing below `lowGate` for ≥2 bars) marks the start of a low-energy region, and that is a **hard veto zone** for every subtractive gesture — there is nothing left to remove, and removing it anyway is inaudible noodling. This is the "never redundantly inside a breakdown" rule, implemented.

### 3.4 Cue points — the interface I want

The cue-point design is in flight. Rather than assume its shape, here is the interface this system needs, stated as requirements on it:

```swift
/// One authored or suggested point of interest in a track.
struct TrackCue: Sendable, Equatable, Codable {
    let trackId: String
    let seconds: TimeInterval
    let role: CueRole
    let origin: CueOrigin
    /// 0…1. `.userPlaced` must be 1.0. Suggestions carry their detector's own.
    let confidence: Double
    let label: String?
}

enum CueRole: String, Codable, Sendable {
    case mixIn, mixOut          // transition points — the transition engine's business
    case drop                   // "the payoff lands here"
    case buildStart             // "start building here"
    case breakdownStart
    case vocalStart, vocalEnd   // the single most useful thing a human can mark
    case doNotTouch             // ← see below
    case generic
}

enum CueOrigin: String, Codable, Sendable {
    case userPlaced             // authority 1.0, never overridden
    case importedFromRekordbox  // authority 0.9
    case suggestedFromAnalysis  // authority = detector confidence, ≤0.75
    case suggestedFromEnvelope  // authority ≤0.55
}
```

Four requirements on whatever ships:

1. **`origin` must be preserved, not collapsed into a confidence number.** "A human placed this" and "a detector scored 1.0" are different facts, and the gesture engine treats them differently: a `.userPlaced` cue can *create* a feasible gesture that no heuristic would have proposed, whereas a suggestion can only ever *rank* one.
2. **`role: .doNotTouch` must exist.** It is the cheapest, highest-value control the user can be given: one marker that says "play this bit straight". A single flag beats any amount of automatic vocal detection, and it is the only mechanism by which a user can correct a gesture that annoyed them. **If the cue design ships nothing else from this list, ship this.**
3. **`vocalStart`/`vocalEnd` must be expressible**, because `MusicUnderstanding.instrumentActivity` is unproven (E-G6) and genre priors are a blunt instrument (§5.6). A user who marks the vocal once has permanently solved the hardest precondition in the catalog for that track.
4. **Cues must be queryable as a sorted array on `TrackFeatures`**, not fetched. The planner is pure and synchronous; it cannot await anything.

**How gestures use them** — in strict order of authority:

- A cue with `role == .buildStart` and `origin == .userPlaced` **creates** a Class 2 candidate with `onset` at the cue and `release` at the next `.drop` cue, or at the next `envelopeReEntry`, or at the next phrase boundary ≥8 bars later, in that order.
- A cue with `role == .drop` is a release target with confidence 1.0 — strictly better than any `envelopeReEntry`, and it should *replace* rather than supplement one within 2 bars.
- A `.doNotTouch` cue vetoes every gesture whose `[onset, release]` span intersects `[cue, cue + 32 bars]` (or up to the next cue, if sooner).
- `.vocalStart…vocalEnd` spans veto rhythmic gestures outright and cost parametric ones 0.25 (§4.1).
- Everything else is a `placement` bonus: a gesture that releases on *any* cue scores better than one that releases on a bare grid line, because a human thought that instant was worth marking.

### 3.5 `MusicUnderstanding` — design around it, not on it

The spike's own conclusions, taken at face value:

- **`asset:` accepts local `file://` only.** Six remote sources (HLS and progressive, localhost and public CDN) failed `invalidAsset`. Anything on a deck is already a local `.caf` from `SourceImporter`, so **the live deck is always analysable** — which is precisely the track a gesture applies to. **Gestures are therefore in the lucky tier.** Candidate-track analysis is the hard problem, and that is the transition engine's problem, not this one.
- **Rhythm is good enough to build on.** 10/11 exact. Watch the 2× octave error: a gesture ladder computed against a doubled grid produces 4-bar rungs where 8 were meant. **Mitigation: sanity-check `beatsPerMinute` against the genre's `bpmRange` before trusting the grid for a gesture, and drop grid confidence to 0.4 on a mismatch** — which, given the profile floors (Wedding 0.75, Junkie 0.55), disables rhythmic gestures without disabling parametric ones. Exactly the right degradation.
- **`structure`/`phrases` are not usable as delivered.** On 2 of 3 real tracks, `sections` was near-perfectly periodic 8-bar chunking with no evidence of arrangement-level segmentation; `phrases` runs at a 1–4-bar grain. **Do not let a gesture precondition read `sections` directly.** If structure is used at all, it must be through an aggregation layer that (a) discards boundaries whose spacing matches the modal spacing to within 5% — i.e. discards the periodic chunking — and (b) keeps only the survivors. On the one real track that showed genuine shape, that filter would have kept the 12.5 s/9.0 s build cluster, the 35.8 s drop and the 28.7 s breakdown chunks and thrown away the 8-bar grain. **That aggregation is worth building; reading `sections` raw is not.**
- **Loudness streams live at ~10 Hz via `audioProvider:`.** That is a genuinely useful, unused input for gestures: it is a *live* level meter on the deck that is playing. It cannot see the future, so it cannot plan — but it can **verify**, and the abort logic (§8.2) should use it: if a gesture is building and the measured short-term loudness is already falling, the material is doing something other than what the plan assumed, and the gesture should bail.

**What degrades when all we have is the envelope.** This is the honest floor and it is where most tracks will sit:

| With grid + envelope + cues | Envelope only |
|---|---|
| Class 1 and Class 2 gestures | **Class 1 only**, and only if a grid exists |
| Release snapped to a downbeat | No downbeat → no rhythmic gesture at all; parametric releases snap to the `envelopeReEntry` or to nothing |
| Ladder lengths in bars | Ladder lengths in seconds, which is not a musical unit — **so no ladders** |
| Vocal veto from cues or MU | Genre prior only (§5.6) |
| `dropOut`, `gate`, `beatRepeat`, `loopRollDown` | **all vetoed** |
| `filterBuild`, `bassDrop`, `brake` | available, releasing on `envelopeReEntry` or aborting to neutral |

So the envelope-only floor is: **a filter/EQ build that releases on a detected energy return, and nothing else.** That is still worth having, and it is a strictly better answer than what the engine does today, which is nothing.

---

## 4. The gesture catalog

Every entry gives: **sound · mechanism · preconditions · parameters · executability · abort**.

Executability is graded against the graph as read from `MixEngine.swift`:

```
player(AVAudioPlayerNode) → timePitch(AVAudioUnitTimePitch) → eq(AVAudioUnitEQ, 3 band)
    → filter(AVAudioUnitEQ, 1 band, .resonantLowPass) → deckMixer → mainMixer → output
```

| Primitive | Present | Numbers |
|---|---|---|
| Per-deck gain ramp | ✅ | `setGain(_:on:over:)`, `RampKey.gain(Deck)` |
| 3-band EQ | ✅ | low `.lowShelf` @ **200 Hz** (already moved from 120), mid `.parametric` @ 1 kHz BW 1.2 oct, high `.highShelf` @ 6 kHz, `eqGainRange = −60…12 dB` |
| Resonant low-pass | ✅ | `filterCutoffRange = 30…20 000 Hz`; **hard-bypasses at ≥ `filterOpenHertz` = 19 kHz**, so "open" is bit-transparent; `setFilterResonance` maps 0…1 → `bandwidth = 2.0 − 1.9v` octaves |
| Time/pitch | ✅ | `rateRange = 0.5…2.0`, `pitchCentsRange = −2400…2400`, both rampable |
| Loop | ⚠️ | `setLoop` reads a PCM buffer and `scheduleBuffer(.loops)` — the *wrap* is render-thread and gapless; the **arm and the clear are not** (§4.7) |
| Ramp engine | ⚠️ | `Task` at **16 ms** sleep, main-actor, `Date()`-driven, one in-flight ramp per `RampKey` (a new one cancels the old) |
| High-pass, delay, reverb, reverse, master limiter | ❌ | none in the graph |

**Tier key.** **A** = ships on today's graph. **B** = one small change (< 1 day). **C** = medium (2–4 days). **D** = out of scope.

### 4.1 The family split that decides everything

| Family | Members | Aborts | Safe over a vocal? | Needs a downbeat? |
|---|---|---|---|---|
| **Parametric** — automate a filter/EQ/gain/rate parameter on a node that never stops rendering | `buildToTheOne`, `bassDrop`, `thinOut`, `brake` | **inaudibly** — ramp the parameter home over ≤250 ms | **yes** — filtering a vocal is normal DJ practice; it does not repeat, reorder or cut a word | only for the *release*, not the hold |
| **Gating** — automate gain rhythmically | `dropOut`, `gate` | inaudibly (return to unity) | borderline — chopping a syllable is audible; costs 0.25 | yes, tightly |
| **Rhythmic** — manipulate the transport | `loopHold`, `loopRollDown`, `beatRepeat` | audibly (the loop has to end somewhere) | **no — veto** | yes, tightly |
| **Substitutive** — replace the source with a processed version of itself | `echoThrow` | audibly (the tail has to decay) | no — veto | yes |

Two consequences worth stating on their own:

- **The parametric family is the only one that satisfies "a gesture that cannot complete cleanly must degrade to something inaudible" unconditionally.** That is why it is v1.
- **The vocal problem largely disappears for the parametric family.** The reason "never across a vocal hook" is a real rule is that loops repeat words and cuts truncate them. A filter sweep over a vocal is something DJs do on purpose. So the hardest precondition in the catalog — the one we cannot measure — applies to precisely the gestures we cannot execute yet. That is a lucky alignment and the staging should exploit it rather than fight it.

---

### 4.2 · `buildToTheOne` — **Tier A, the flagship**

*The v1 deliverable. Two ramps, no new DSP, and a complete DJ move.*

**Sound.** On a phrase downbeat the bass vanishes in a beat; over the next eight bars the record closes down under a low-pass until it is a muffled band-limited version of itself, tightening; a hair of resonance comes up in the last two bars; then on the one, everything is back at once and the record hits like it was never gone.

**Mechanism.** Two independent tension axes moving together — spectral subtraction (the low-pass, §2) and the removal of the physical low-frequency component (the bass), while the metrical grid is left completely intact so the listener keeps counting and keeps waiting. The release is a Class 1 self-release: it is guaranteed to arrive, and it arrives exactly where the 8-bar schematic expectation says it should.

**Preconditions** (all hard; any failure removes the candidate rather than costing it):

| Gate | Value | Why |
|---|---|---|
| Bar grid present, `confidence ≥ profile.minGridConfidence` | Wedding 0.75 / Junkie 0.55 | Only the *release instant* needs it — but it needs it badly |
| Runway to the transition lockout | ≥ `ladderBars + 2` bars | Never collide with a planned exit |
| Elapsed since track start | ≥ 16 bars (Junkie) / 32 bars (Wedding) | §2 — you cannot violate an expectation the listener has not formed |
| Bars since the last `envelopeReEntry` | ≥ 8 | Do not build immediately after a drop lands; let it breathe |
| Not inside a low-energy region | `envelope[onset] ≥ 0.80 × median` | Nothing to subtract in a breakdown |
| No `.doNotTouch` cue in `[onset, release]` | — | §3.4 |
| Genre gate | `brightness ≥ 0.25` **or** `energy ≥ 0.70` | A low-pass on a dark, sub-heavy record with no top removes nothing |

**Stages** (8-bar form at 128 BPM; `bar = 1.875 s`, total 15.0 s):

| t | Stage | Rationale |
|---|---|---|
| 0 | `eqLow(−60 dB, over: 1 beat = 0.469 s)` | Fast, decisive. `−60 dB` on a 200 Hz shelf is effectively −∞ and takes the kick body with it, not just the sub. |
| 0 → 8 bars | `lowPassTo(hertz: 800, over: 15.0, curve: .logarithmic)` | From bypassed (20 kHz). Log travel ≈ linear in perceived pitch. `setFilterCutoff`'s default curve is already `.logarithmic`. |
| 6 bars | `filterResonance(0.25, over: 2 bars)` | "A little movement helps, squealing does not." `0.25` → `bandwidth = 1.525` octaves. |
| 7.5 bars *(Junkie only)* | `lowPassTo(1200, over: 0.5 bar)` | The **breath** — a small re-open just before the release makes the snap read bigger. |
| **8 bars, exactly** | `lowPassTo(20000, over: 0.03)` **+** `eqLow(0 dB, over: 0.03)` **+** `filterResonance(0, over: 0.03)` — **all three via `snap`, not `ramp`** | ≥19 kHz hard-bypasses the band, so the release is genuinely *back to the record*, bit-transparent, not "a filter set wide". |

**Parameters** (the space the selector samples over):

- `ladderBars ∈ {4, 8, 16}` — 4 for hard/dense material, 16 only where `phraseStrictness ≥ 0.7`
- `cutoffFloor ∈ {600, 800, 1200} Hz`
- `dropBass ∈ {true, false}` — `false` gives a pure filter build, which is a genuinely different-sounding gesture and counts as a different signature (§5.4)
- `resonancePeak ∈ {0.0, 0.15, 0.25}` — Wedding capped at 0.15
- `breath ∈ {true, false}` — Junkie only
- `releaseShape ∈ {snap, bloomOneBar}` — `bloom` opens over one bar instead of snapping; use where `melodicContent ≥ 0.7`

**Executability: Tier A.** `setEQ(.low, on:toDecibels:over:)` and `setFilterCutoff(_:on:over:curve:)` both exist and both ramp. The only new code is the `snap` helper (§6.5) for the release instant.

**Abort:** `lowPassTo(20000, over: 0.25)` + `eqLow(0, over: 0.25)` + `filterResonance(0, over: 0.25)`. Inaudible — a filter that stopped closing and opened up is just a shorter sweep.

**Tension:** `deltaDuring = +0.35`, `residualAfter = −0.05`. Budget cost **1**.

---

### 4.3 · `bassDrop` — Tier A

**Sound.** The low end vanishes in a beat. The track carries on thin and hollow for 2–16 bars. The bass returns on the one.

**Mechanism.** Removes the body of the groove while leaving the rhythmic grid entirely intact. This is the purest form of "the expected continuation is denied but the clock keeps running" available on this graph, and because 4/4 dance music puts the kick on every beat, the listener's counting survives the removal perfectly. Also the cheapest to execute correctly: two `setEQ` calls.

**Preconditions:** as `buildToTheOne`, plus the region must actually *have* bass. The only proxy available without `instrumentActivity` is amplitude: `envelope[onset] ≥ 0.5 × median` — the existing `DJPointFinder.hasBody` rule. **The reasoning string must not claim "took the bass out"; it must say "cut the low shelf", because we did not measure that there was a bassline.**

**Parameters:** `outBeats ∈ {0.25, 1}` · `holdBars ∈ {2, 4, 8, 16}` · `inBeats = 0.25` · `alsoTrimHighs ∈ {0, −4 dB}` (trimming the high shelf too makes it read as a filter rather than an EQ move) · `releaseOn ∈ {phrase, bar}`.

**Executability: Tier A.** Note this gesture became materially better the moment the low shelf moved 120 Hz → 200 Hz: at 120 Hz a −60 dB cut left the whole 120–250 Hz kick-body region in place, which is the mud band, and the gesture read as "the sub went away" rather than "the bass went away". It is now the latter. **A second, independent argument for a change the transition spec already made.**

**Abort:** `eqLow(0 dB, over: 0.15)`. Inaudible.

**Tension:** `deltaDuring = +0.25`, `residualAfter = −0.04`. Cost **1**.

---

### 4.4 · `dropOut` — Tier A, jitter-critical

**Sound.** Everything stops. One or two beats of nothing. The track returns on the downbeat.

**Mechanism.** Maximal expectation violation at minimal cost — the listener's internal entrainment continues through the silence, and the return either confirms it (elation) or contradicts it (a stumble). There is no middle outcome, which is what makes it the highest-variance gesture in the catalog.

**Preconditions.** The strictest in the catalog:

- `grid.confidence ≥ profile.minGridConfidence + 0.10` — a stricter floor than every other gesture, because this one has *nothing* to hide a timing error behind
- Measured downbeats (`provenance.measuredDownbeats`) — not inferred
- No vocal in `[onset − 1 bar, release + 1 bar]` (cue or MU); where unknown, veto when `genre.vocalPresence ≥ 0.55`
- `release` on a **phrase** boundary, never a bare bar line
- ≥ 32 bars since track start (Wedding: not admitted at all)

**Parameters:** `silenceBeats ∈ {0.5, 1, 2}` · `fadeOutMs = 8` (click guard only) · `fadeInMs = 3` · `preRoll ∈ {none, filterSnapClosed}` — a 1-beat filter slam before the silence telegraphs it and makes it read as deliberate rather than as a dropout.

**Executability: Tier A with a caveat that matters.** `setGain(0, on: deck, over: 0.008)` then `setGain(1, over: 0.003)`. The audio never stops rendering, so — unlike a transport move — there is **no render-quantum latency at all**. The only error is scheduler jitter, and the `ramp` loop's 16 ms sleep puts that at up to ±16 ms. Against a 7.5–25 ms flam band that is not acceptable for the *return*.

> **This is the gesture that justifies the `snap` helper on its own.** With `snap` (§6.5) the jitter drops to ~2–3 ms, comfortably inside Wedding's 10 ms budget. Without it, `dropOut` is Junkie-only and should honestly be graded Tier B.

**Abort:** `setGain(1.0, over: 0.02)`. Inaudible unless it lands mid-silence, in which case the silence was simply shorter.

**Tension:** `deltaDuring = +0.55` (the highest), `residualAfter = −0.12`. Budget cost **2** — it is a high-impact move and should be rationed accordingly.

---

### 4.5 · `gate` — Tier A, and unusual

**Sound.** The track is chopped rhythmically at 1/8 or 1/4 notes for 1–2 bars — a trance gate applied live.

**Mechanism.** Substitutes a faster metrical layer for the one the listener is tracking, which raises the perceived event rate without changing the tempo. The same "acceleration" mechanism a loop roll-down uses, achieved with gain instead of transport.

**Executability: Tier A at 1/8, Tier B at 1/16.** A sequence of short `setGain` ramps driven by one scheduler task. At 128 BPM an eighth is 234 ms, so 16 ms granularity is a 7% edge error — audible as softness, not as wrongness. A sixteenth is 117 ms and 14% error, which is too loose without `snap`.

**Preconditions:** `grid.confidence ≥ profile.minGridConfidence` · `genre.swing ≤ 0.55` (a straight gate over a shuffled record fights the groove — this is the one place the `swing` axis earns its keep for gestures) · `fourFourness ≥ 0.6` · no vocal.

**Parameters:** `division ∈ {1/4, 1/8}` · `duty ∈ {0.5, 0.65}` · `bars ∈ {1, 2}` · `depthDb ∈ {−18, −60}` (a partial gate is a different, gentler gesture).

**Abort:** return gain to unity at the next gate edge. Inaudible.

**Tension:** `+0.30`, residual `−0.03`. Cost **1**. Note this one is genre-narrow: excellent in trance/hard techno/big room, wrong almost everywhere else, and `gestureAffinity` (§5.6) should reflect that sharply.

---

### 4.6 · `brake` (tape stop) — Tier A, and the surprise

**Sound.** The record slows and drops in pitch over half a beat to a beat, then snaps back on the one. A machine winding down.

**Mechanism.** Violates the tempo itself — the most fundamental expectation in the stack — while keeping the material continuous. Extremely legible. Culturally specific.

**Executability: Tier A, unexpectedly.** `AVAudioUnitTimePitch` is key-locked, so `setRate` alone gives "slower but the same pitch", which is *not* a brake and sounds wrong. A real brake needs rate and pitch coupled:

```
pitchCents(r) = 1200 · log2(r)
r = 0.5  →  −1200 cents      // one octave down, the classic tape stop
r = 0.7  →  −618 cents
```

Both `setRate(_:on:over:)` and `setPitch(_:on:over:)` exist and both ramp, on separate `RampKey`s, so they can be driven together. `rateRange` bottoms at **0.5**, so the brake can reach half speed but not a full stop — which is fine; a full stop needs a gain fade anyway to avoid a DC thud, and half speed plus a gain fade reads correctly.

**Caveat, stated honestly:** `AVAudioUnitTimePitch` at rate 0.5 with −1200 cents will produce time-stretch artefacts. For a brake that is *correct* — the effect is meant to sound mechanical. But it means the brake must never be used as a subtle move. Also unverified: whether `playerTime(forNodeTime:)` still reports true source position under a large simultaneous rate+pitch change — the transition spec's **E6** covers exactly this and this gesture inherits it.

**Preconditions:** `genre.energy ≥ 0.7` **and** `melodicContent ≤ 0.5` (a brake over a melodic progressive record is a mistake) · release on a phrase downbeat · not over a vocal · Junkie only.

**Parameters:** `targetRate ∈ {0.5, 0.65, 0.8}` · `overBeats ∈ {0.5, 1, 2}` · `returnMs ∈ {20, 40}` (snap, not ramp) · `gainFloor ∈ {0 dB, −6 dB}`.

**Abort:** `setRate(1.0, over: 0.12)` + `setPitch(0, over: 0.12)`. Audible as a shorter brake, not as an error — acceptable.

**Tension:** `+0.40`, residual `−0.10`. Cost **2**.

---

### 4.7 · `loopHold` and `loopRollDown` — Tier C, and here is exactly why

This is the owner's headline ask, so it deserves the arithmetic rather than a shrug.

**Sound.** `loopHold`: the current phrase repeats once or twice more than it should, then continues from where it would have been. `loopRollDown`: the loop halves on each bar line — 8 → 4 → 2 → 1 — so the repeat rate accelerates, then releases.

**Mechanism.** The strongest tension device available to a DJ, and the one the owner is right to want. It denies the phrase-level expectation while perfectly preserving the beat-level one, and the *accelerating* denial rate is what makes a roll-down feel like a build rather than a stall.

**Why it is not v1 — the numbers.** `MixEngine.setLoop` is, in order:

```swift
source.generation &+= 1
nodes[index].player.stop()                                   // ← flushes the schedule
… read the region into an AVAudioPCMBuffer …
nodes[index].player.scheduleBuffer(buffer, at: nil, options: [.loops])
if wasPlaying, start() { nodes[index].player.play() }        // ← starts at the next render quantum
```

The `.loops` wrap itself is genuinely gapless — the file's own comment explains why that design was chosen, and it is right. **The problem is the arm and the clear, not the wrap.** `stop()` + `play()` with `at: nil` means "as soon as possible", which is the next render quantum: **≈11.6 ms at 512 frames / 44.1 kHz**, plus main-actor scheduling. And `scheduleBuffer` here is preceded by a synchronous `AVAudioFile.read(into:)` of the whole loop region — for a 4-bar loop at 128 BPM that is 7.5 s × 44 100 × 2 × 4 bytes ≈ **2.6 MB of disk read on the main actor**, which is not free and is not bounded.

So an 8→4→2→1 roll-down is **four arms plus one clear = five dropouts, every one of them on a downbeat transient**. It is not a timing error — the loop still *starts* on the beat — it is five holes punched in the audio at the five most exposed instants in the gesture.

**What is needed** (and this is the same `.loopResize` + `.sampleAccurateCue` the transition spec already priced at **M**):

```swift
/// Pre-builds the next loop buffer and schedules it at a computed AVAudioTime
/// without stopping the node. No stop(), no play(), no read on the main actor.
func resizeLoop(on deck: Deck, toLengthSeconds: Double, atHostTime: AVAudioTime)
```

Plus the buffer read moved off the main actor and pre-staged at *plan* time, since the ladder is known in advance — every rung's buffer can be built the moment the gesture is armed.

**The honest middle position.** `loopHold` is *one* arm and *one* clear — two dropouts, and if the arm is placed exactly on a downbeat the hole sits on a transient that partially masks it. It might be acceptable. **It might also be exactly the glitch aesthetic hard techno wants.** That is a listening judgement, not an engineering one, so: **E-G1 (§11) renders one arm offline and measures the hole in samples.** If it is under ~4 ms, `loopHold` graduates to Tier A for Junkie. If it is the full quantum, it stays Tier C. Do not guess.

**When it does ship** — the ladder is data, not a halving count, exactly as `LoopRollDownTemplate` already models it:

- `halvingLadder = [8, 4, 2, 1]` — halving preserves phase against the bar grid
- `ownersLadder = [8, 6, 4, 2, 1]` — the owner's own sequence. **6 does not divide an 8-bar phrase**, so every rung after it lands on a different beat of the phrase than it started on. That is a real musical choice (it produces a deliberate metric displacement), not a bug, and it should stay a parameter until the owner says which they meant.
- `tightLadder = [4, 2, 1, 1, 1]` — repeating the last rung is a different and very common move
- `maxLoopBars` and `maxLoopHalvings` already exist on `DJProfile` (Wedding 8/1, Junkie 32/4) and govern this directly. **No new profile fields are needed.**

**Preconditions when it ships:** measured bar grid at high confidence · the loop region must be rhythmically self-sufficient — **which we cannot detect**, so the proxy is `melodicContent ≤ 0.6` from the genre profile *plus* no `envelopeReEntry` inside the loop region (a loop that straddles the return of the beat repeats the moment of arrival, which is the single worst thing this gesture can do) · **hard vocal veto** · `percussiveDensity ≥ 0.4`.

**Abort:** `clearLoop` at the next bar line — never mid-bar — followed by a 120 ms filter open to mask the seam. Audible as "the loop ended early", which is a musical outcome rather than an error, but it is not inaudible, and that is why the rhythmic family scores worse on `riskExposure` (§5.2).

**Tension:** ladder-dependent. `deltaDuring = 0.25 + 0.10 × (rungs − 1)`, capped 0.75. Residual `−0.15 × delta`. Cost **2**.

---

### 4.8 · `beatRepeat` / stutter — Tier C

Same blocker as §4.7, worse: 8–16 re-arms per bar rather than one per bar, so the dropout rate is 8–16 × 11.6 ms per bar ≈ **5–20% of the audio missing**. Not viable until `resizeLoop` lands, and even then the scheduling must be entirely pre-staged. Included in the catalog only so it is not re-proposed as "easy because we already have loops".

### 4.9 · `echoThrow` — Tier C

**Sound.** A beat-synced delay is thrown on the live deck; the source keeps playing but goes dry-to-wet for 1–2 bars; the tail rings through the release.

Distinct from the transition-engine's `echoOut` (which kills the source). As a *mid-track* gesture it is easier: the source never stops, so the "the tail must survive the fader" placement constraint disappears. It still needs `AVAudioUnitDelay` per deck, placed after `filter` and before `mixer` — the M-sized change already specified in the transition spec §3.2/T5, and this gesture is free once that lands.

One gesture-specific detail worth recording now: `delayTime` must be recomputed whenever `timePitch.rate ≠ 1`, because the beat division is in *source* beats and the delay is in wall-clock seconds — `delayTime = beatPeriod × division / rate`. That bites harder for gestures than for transitions, because a gesture can run *while* a `brake` is ramping the rate.

**Parameters when it ships:** `division ∈ {1/4, 1/2, 3/4 dotted, 1}` beat (default 1/2) · `feedback ∈ 50…60%` · `wetDryMix ∈ 30…40%` ramped in over 1 beat and out over 1 bar · high-pass the repeats so the tail does not muddy the low end.

### 4.10 · Out of scope, documented so they are not re-proposed

| Gesture | Blocker | Verdict |
|---|---|---|
| **`backspin`** | `AVAudioPlayerNode` cannot play backwards. Would need a reversed PCM buffer per deck (~50 MB for 6 minutes at the canonical format) or a reversed decode pass. | **D.** And it fails the §8.1 admissibility rule outright: once committed to a backspin there is no graceful exit within 250 ms. |
| **Riser / uplifter** | Needs a synthesised noise source; there is no generator node in the graph and adding one is a new architecture, not a new effect. | **D.** |
| **Reverb freeze / throw** | No reverb node. `AVAudioUnitReverb` exists in the SDK but adding it per deck is a real change and the payoff is much lower than the delay's. | **D for now**; revisit after `echoThrow`. |
| **Half-speed "screw"** | Achievable via `brake` held at 0.5 rather than snapped back — but the artefacts over a sustained period are severe and it is a production effect, not a DJ gesture. | **D.** |

### 4.11 Catalog summary

| Gesture | Family | Tier | Wedding | Junkie | Δtension | Cost | Needs |
|---|---|---|---|---|---|---|---|
| `buildToTheOne` | parametric | **A** | ✅ (no breath, res ≤0.15) | ✅ | +0.35 | 1 | `snap` |
| `bassDrop` | parametric | **A** | ✅ | ✅ | +0.25 | 1 | — |
| `dropOut` | gating | **A** | ✗ | ✅ | +0.55 | 2 | `snap` (hard requirement) |
| `gate` | gating | **A** (1/8) | ✗ | ✅ | +0.30 | 1 | `snap` for 1/16 |
| `brake` | parametric | **A** | ✗ | ✅ | +0.40 | 2 | E6 |
| `thinOut` | parametric | **B** | ✅ | ✅ | +0.30 | 1 | `.highPassFilter` (S) |
| `loopHold` | rhythmic | **B/C** | ✗ | ✅ | +0.25 | 2 | E-G1, then `.loopResize` |
| `loopRollDown` | rhythmic | **C** | ✗ | ✅ | +0.25…0.75 | 2 | `.loopResize` + `.sampleAccurateCue` |
| `beatRepeat` | rhythmic | **C** | ✗ | ✅ | +0.45 | 2 | as above |
| `echoThrow` | substitutive | **C** | ✅ | ✅ | +0.20 | 1 | `.delayPerDeck` (M) |

---

## 5. Not predictable, not random — the decision model

### 5.1 The dials, and one argument with the framing

The owner's framing is three dials: rules define the feasible set, weighted-stochastic selection within it, memory defeats predictability. I think that is right and I want to develop it in four ways.

**(a) The dials are not equally important, and the ordering matters for what to build first.**

> **Memory is necessary. Temperature is optional.**

Set temperature to zero — pure argmax — and keep memory, and the engine is *still* unpredictable, because the memory penalty reshuffles the argmax on every decision. Set temperature to infinity and remove memory, and the engine is random, which is a different kind of predictable: the listener cannot predict the individual choice but can absolutely predict the distribution, and "it does filter things a lot" is exactly the complaint. So temperature buys *variance*; memory buys *non-repetition*; and only the second is what a human DJ is actually doing. Build memory first, add temperature second, and if you only ever build one, build memory.

There is hard cross-domain evidence for the asymmetry, and it is worse than I assumed: **argmax over a history-conditioned distribution produces 263× the human repetition rate**, via a named positive feedback loop (Holtzman et al., ICLR 2020 — §5.3). Because the memory multiplier is applied *outside* the softmax, it survives `τ = 0`; a logit-space penalty would not. **E-G10** (§11) is the experiment that would settle whether temperature is doing anything at all once memory is in place.

**(b) The feasible set should be built out of hard gates, not low-cost terms — and this is where the gesture engine must diverge from the transition engine.**

The transition engine is right to veto almost nothing: it *must* produce an answer, so a bad pairing has to score 0.18 and lose rather than be excluded, or you end up with nothing to play. The gesture engine's default answer is silence, so it can afford the opposite discipline. **Every doubt is a veto.** A gesture on a shaky grid is not a cheap gesture, it is not a gesture. This is why §4's precondition tables are boolean and the §5.2 term set is short.

**(c) A fourth dial is warranted, and it is not the same thing as memory.**

Memory is *relative* — do not repeat. Budget is *absolute* — do not overdo. They fail differently:

- No memory → same trick every time → **predictable**.
- No budget → constant tricks, all different → **exhausting**, and each one stops being punctuation.

Kim et al. measured 12.9 transitions per hour across 20,765 real transitions. That is the mandatory event rate. If discretionary gestures fire at a comparable rate they stop reading as decisions and start reading as processing. My numbers put them at 15% (Wedding) and 54% (Junkie) of the transition rate.

**(d) A fifth thing, which the framing does not cover: the engine has to know when it is *not* the source of tension.**

A trance record with a 64-bar breakdown and a 32-bar build supplies all the tension anyone needs; a gesture on top of it is noise. A hard techno tool supplies none, and gestures are the *only* source of shape it has. So `GenreProfile.breakdownLength` is not a preference axis, it is an **inverse budget multiplier** (§5.6). That is a genuinely non-obvious use of data the app already has, and it is the difference between an engine that decorates and one that reads the material.

---

### 5.2 Dial 1 — the feasible set (fully deterministic)

Two layers, and the split is deliberate:

**Layer 1: hard gates.** The `admits(...)` method on each `GestureTemplate`, exactly mirroring `TransitionTemplate.admits`. Returns `.admitted` or `.rejected(reason:)`, and the reason string flows into the planning result so a silent engine can always explain itself. Everything in §4's precondition tables lives here, plus one **structural zero** taken from the prior art (§5.4):

> **No climactic gesture may immediately follow another climactic gesture** — `dropOut`, `brake`, `loopRollDown`, `beatRepeat`. Not decayed, not costed: removed from the feasible set until a non-climactic gesture or an energy return has intervened. This mirrors Vande Veire's `→ Double drop = 0` row, and it is the difference between a set with peaks and a set that is all peak.

Structural zeros belong here and nowhere else. **A prohibition is about what the music can support; a penalty is about variety.** Conflating them is how a novelty mechanism ends up forbidding the most useful move in the catalog (§5.4).

**Layer 2: scoring terms.** Six of them, returning `(cost, confidence, explanation)` in the *identical* `TermResult` shape the transition engine uses, and scored by the *identical* function. Memory is deliberately not one of them — see the end of this section.

> **Reuse `DJPlanner.score` verbatim.** Its formula — weighted mean by `w·κ`, capped by the single worst weighted concern `score ≤ 1 − maxᵢ(cᵢ·κᵢ·wᵢ/w_max)` — is exactly right for gestures, and the cap is what makes a single bad term decisive rather than diluted. That function should be extracted from `DJPlanner` into a free `ScoreEngine.score(terms:weights:context:)` so both engines call the same code. That is a small refactor with a large payoff: **explainability, confidence attenuation, veto handling and the concern/contribution split all come for free**, and a bug fixed in one engine is fixed in both.

| Term | Cost from | Confidence from | Notes |
|---|---|---|---|
| `gestureFeasibility` | runway shortfall, transition lockout margin, abort-path reachability, watchdog headroom | 1.0 always | **The only term allowed to veto.** Mirrors `FeasibilityTerm`. |
| `releaseQuality` | what the release lands on | grid confidence | user `.drop` cue **0.00** · user cue any role 0.08 · `envelopeReEntry` (scaled by its own confidence) 0.10–0.35 · phrase boundary on a confident grid 0.25 · bar boundary only 0.60 · nothing → **veto** |
| `placement` | position in the track and in the phrase grammar | grid confidence | penalises: < 16 bars from track start (1.0 → veto below 8), < 8 bars since the last `envelopeReEntry`, onset not on a phrase boundary, > 0.85 through the track |
| `materialFit` | envelope level at onset vs track median; genre `gestureAffinity` (§5.6); vocal risk | `0.45` when genre-only, `0.85` with measured vocals or cues | this is where "does this record support this move" lives |
| `riskExposure` | **how bad the worst case is**: the abort path's audibility (parametric 0.0 · gating 0.15 · rhythmic 0.55 · substitutive 0.45), plus `(1 − gridConfidence)`, plus 0.2 if the release target's confidence is below 0.5 | 1.0 always | the term that makes Wedding conservative without giving Wedding a different code path |
| `arcFit` | how far the gesture's `deltaDuring` is from what the arc wants | 1.0 (bookkeeping) | §5.5 |

Weights, per profile — and note the shape of the difference is the same one the transition profiles already have (Wedding weights *not being wrong*; Junkie weights *being a choice*):

| Term | **Wedding** | **Junkie** |
|---|---|---|
| `gestureFeasibility` | 1.00 | 1.00 |
| `releaseQuality` | **0.95** | 0.80 |
| `riskExposure` | **0.90** | 0.45 |
| `placement` | 0.85 | 0.65 |
| `materialFit` | 0.75 | 0.75 |
| `arcFit` | 0.35 | **0.70** |

Wedding weights the release and the downside (a gesture that lands badly is exactly the mistake it exists to avoid). Junkie weights the arc (its whole point is that it does a lot of gestures, so shaping the night is what stops that being tedious).

**`riskExposure` is what makes the family split (§4.1) *cost* something rather than merely be a fact.** Under Wedding the rhythmic family's 0.55 abort-audibility, at weight 0.90, caps any rhythmic gesture at `1 − 0.55 × 0.90 = 0.505` — below Wedding's 0.68 floor, unconditionally. **So Wedding can never fire a rhythmic gesture, and no rule anywhere says so.** Under Junkie the same figure caps at `1 − 0.55 × 0.45 = 0.752`, comfortably above its 0.52 floor. That is the profile difference falling out of a number instead of a branch, which is the test that the model is the right shape.

**Memory is deliberately *not* on that list — and this is a correction to the obvious design.** My first pass made `memory` a seventh scoring term, by analogy with the transition engine's `NoveltyTerm`. Working the arithmetic shows it does not survive contact with the cap rule:

> The cap is `score ≤ 1 − maxᵢ(cᵢ·κᵢ·wᵢ/w_max)`. A memory cost of 0.22 at weight 0.85 caps *every* candidate at 0.813. But memory cost is a function of the **history**, not of the plan, so within a family it is **identical across all candidates** — and once several candidates' weighted means exceed that shared cap, they all collapse to exactly 0.813 and tie. The softmax over a set of ties is uniform. **The memory term would destroy the very selection it exists to shape.**

The fix is to take memory out of the mean entirely and apply it as a multiplicative modifier on the finished score:

```
finalScore = ScoreEngine.score(sixTerms…) × (1 − memoryCost × profile.memoryStrength)
memoryStrength:  Wedding 0.85   Junkie 0.75
```

Three things this buys. It makes memory **decisive** rather than diluted to ~19% of a seven-term mean. It keeps memory working at `τ = 0` (§5.1(a)). And it keeps the cap doing only the job it was designed for — *one physically-bad property cannot be averaged away* — rather than also arbitrating taste.

> ⚠️ **This is a latent bug in the transition engine too.** `NoveltyTerm` returns confidence 1.0 and Junkie weights it 0.55, so a `novelty` cost of 0.6 caps every plan at 0.67 regardless of how good the mix is — and since `novelty` depends only on `history` and `templateId`, every plan from the same template ties. `DJScoringTerms.swift` should get the same treatment: novelty out of the mean, applied as a multiplier. **Worth raising with whoever owns that file.**

---

### 5.3 Dial 2 — selection (weighted-stochastic, seeded)

Two stages, and separating them is not cosmetic.

**Stage A — the gate.** A two-way logistic against the null option, so it is **invariant to how many candidates exist**:

```
P(fire) = σ( (s* − effectiveFloor) / τ_gate ),   σ(x) = 1 / (1 + e^(−x))
s*            = best candidate's score
effectiveFloor = profile.gestureFloor + rateAdjust      (§5.5)
τ_gate         = profile.temperature / 3
```

The naïve alternative — throw the null option into one big softmax with the candidates — is wrong, and it is worth saying why: with *n* candidates the partition function grows with *n*, so having more feasible options makes the engine more likely to act. That is backwards. Having six ways to do something should not make you more likely to do it.

**Stage B — the choice.** Softmax over the candidates only:

```
P(gᵢ) = exp(sᵢ / τ) / Σⱼ exp(sⱼ / τ)
```

**Temperature values.** Scores are in 0…1 and the realistic spread between a good and a mediocre candidate is 0.15–0.35, so:

| Profile | `τ` (template choice) | `τ_param` (parameter choice) | `τ_gate` | `gestureFloor` | Behaviour at Δs = 0.10 | at Δs = 0.25 |
|---|---|---|---|---|---|---|
| **Wedding DJ** | **0.06** | 0.10 | 0.020 | **0.68** | best wins 84% | best wins 98% |
| **Junkie** | **0.22** | 0.35 | 0.073 | **0.52** | best wins 61% | best wins 76% |

Worked, so the numbers are checkable. Two candidates at 0.80 and 0.70:

- Wedding, τ = 0.06: `e^(0.80/0.06) : e^(0.70/0.06)` → odds `e^(0.10/0.06) = e^1.667 = 5.29 : 1` → **84% / 16%**.
- Junkie, τ = 0.22: odds `e^(0.10/0.22) = e^0.455 = 1.58 : 1` → **61% / 39%**.

Three candidates at 0.80 / 0.70 / 0.55 under Junkie: weights `1, 0.635, 0.320` → **51% / 32% / 16%**. That is exactly the shape asked for — the engine will take a good-but-not-best option about a third of the time and a distinctly worse one about one time in six.

**Why `τ_param > τ`, and by 1.6×.** Choosing between "16-bar build" and "8-bar build" cannot make the mix *wrong* — both are musical, they just feel different. Choosing between "loop roll" and "brake" can. So parameter variety is cheap risk and template variety is expensive risk, and the adventurousness dial should be turned further on the cheap one. This also directly serves the memory system: parameter variety is what lets the engine reuse a template without repeating itself (§5.4).

**Temperature is the one number to turn.** If the engine feels mechanical, raise `τ`. If it feels silly, lower it. Everything else in this section is structure; this is taste, and it should be exposed in the DJ console as a debug slider before it is ever exposed to a user.

#### What the sampling literature actually says, and the one warning that applies to Wedding

The cross-domain evidence that argmax self-destructs is much stronger than I assumed. Holtzman, Buys, Du, Forbes & Choi, *The Curious Case of Neural Text Degeneration*, ICLR 2020 **[V]** (https://arxiv.org/pdf/1904.09751) — GPT-2 Large, 5,000 passages, "repetition %" = a phrase of length ≥2 repeating ≥3 times at the end of generation:

| Method | Repetition % |
|---|---|
| **Human** | **0.28** |
| **Greedy (argmax)** | **73.66** |
| Beam, b = 16 | 28.94 |
| Top-k = 40, t = 0.7 | 8.86 |
| Sampling t = 0.9 | 0.66 |
| Nucleus p = 0.95 | 0.36 |

**Argmax produces 263× the human repetition rate**, and the mechanism named in the paper is exactly the one this engine is exposed to: "The probability of a repeated phrase increases with each repetition, creating a positive feedback loop." **[V]** Any selector conditioned on its own recent history that always takes the mode will spiral.

Two further findings, both verbatim **[V]**: "sampling with temperatures lower than 0.9 severely increase repetition"; and "all stochastic methods face repetition issues when their tuning parameters are set too low, which tends to over-truncate, mimicking greedy search." **Over-truncation *is* determinism** — aggressive weighting has the same failure mode as no weighting.

For music specifically, Performance RNN (Simon & Oore, Magenta 2017) is the only source publishing a temperature sweep **[V]** (https://magenta.withgoogle.com/performance-rnn): at **t = 0.8** "the performance seems to overly fixate on a few patterns"; at 2.0 it is chaotic. The musical fixation threshold and Holtzman's textual one land in the same place. MusicVAE ships 1.0 **[V]** (arXiv:1803.05428, Table 1 caption); Jukebox's code ships 0.99 **[V]** (`hparams.py`, `temp_rest=0.99`). ⚠️ **Music Transformer (arXiv:1809.04281) and the Jukebox *paper* report no decoding temperature at all** — verified by exhaustive grep. Do not cite either for a temperature value.

**Does this invalidate Wedding's τ = 0.06?** Not directly — those figures are for a softmax over a ~50k-token vocabulary with logits on an unbounded scale, whereas this one runs over ≤8 candidates with scores bounded in 0…1, so the numbers are not commensurable. **But the mechanism transfers, and it is a genuine warning about Wedding specifically.** At τ = 0.06 Wedding is effectively near-greedy (§5.8: 40.6% on a flat candidate set, ~80% on a spread one), and near-greedy plus history-conditioning is the exact recipe for the feedback loop. What saves it is §5.4: the memory multiplier is applied *outside* the softmax, so it reorders candidates rather than reweighting logits, and it therefore keeps working at any temperature. **That is not a nicety — for Wedding it is the only thing standing between the engine and Holtzman's 73.66%.** If anyone ever proposes removing the memory multiplier "because temperature already handles variety", this is the citation to point at.

The soft-discount form is also independently attested. Keskar et al., *CTRL*, arXiv:1909.05858 **[V]** divides the logit of any already-emitted token by θ before the softmax and reports "**θ ≈ 1.2 yields a good balance between truthful generation and lack of repetition**". Their framing is this problem exactly: "trusts the model distribution through near-greedy sampling but prevents repetitions through a penalty." With only ~8 gestures, a *soft* discount is right and a hard n-gram block would be wrong — Paulus, Xiong & Socher **[V]** (arXiv:1705.04304) hard-zero repeated trigrams, but only after **measuring** that "ground-truth summaries almost never contain the same trigram twice". Over eight symbols a trigram block removes a large fraction of the space and would itself read as mechanical. **Hard zeros are reserved for musical prohibitions (§5.4's climactic rule), never for variety.**

> ⚠️ **The honest caveat, and it applies to this whole section.** Vande Veire's stochastic transition FSM **was never ablated** — their user study tested track selection (17/18, p = 7.25 × 10⁻⁵) and rhythmic matching (10/15, p = 0.151, n.s.), not the selector. **No perceptual study anywhere validates that weighted-stochastic gesture selection beats deterministic selection for DJ gestures.** Holtzman and Performance RNN are cross-domain proxies. The argument in §5.1 is a good argument; it is not an evidenced result, and the spec should not pretend otherwise.

---

### 5.4 Dial 3 — memory (the one that actually defeats predictability)

**The signature.** What counts as "the same gesture" is the whole design, so it is a type:

```swift
/// Three nested identities, coarse to fine. Equality at each level drives a
/// separate decay term, so "same template, different numbers" is genuinely
/// different from "the same trick again".
struct GestureSignature: Hashable, Sendable, Codable {
    let family: GestureFamily        // .parametric | .gating | .rhythmic | .substitutive
    let templateId: GestureTemplateID
    /// The parameters, quantised. Quantisation matters: a 15.8-bar build and a
    /// 16-bar build are the same gesture and must hash the same.
    let parameters: [String: Int]
}
```

Quantisation rules — deliberately coarse, because near-identical is identical to a listener:

- bar counts → nearest of `{1, 2, 4, 8, 16, 32}`
- Hz → nearest of `{300, 600, 800, 1200, 2000, 4000}`
- dB → nearest 6 dB
- ladders → the tuple itself (`[8,4,2,1]` ≠ `[8,6,4,2,1]` ≠ `[4,2,1,1,1]`)
- booleans → as-is

**The decay.** A sum of exponentials over past uses, at three granularities, in **set-elapsed minutes** rather than track count. Minutes, because the listener's habituation is in experienced time and a 3-minute track and a 9-minute track are not the same amount of listening. (The clock is *injected*, not read — §7.)

```
penalty(g) = Σ_levels λ_level · Σ_{uses u of that level} exp( −ln2 · (t_now − t_u) / H_level )

memoryCost   = 1 − exp( −penalty(g) )                       // 0…1
finalScore   = baseScore × (1 − memoryCost × memoryStrength) // applied outside the mean
```

| Level | matches on | `H` (half-life) | `λ` |
|---|---|---|---|
| **exact** | full `GestureSignature` | **12 min** | **1.8** |
| **template** | `templateId` | **10 min** | **1.2** |
| **family** | `family` | **5 min** | **0.5** |

`memoryStrength`: **Wedding 0.85, Junkie 0.75.**

#### Workhorse vs climactic — a correction, from the only comparable working system

My first pass applied that decay uniformly to every template. **That is stronger than what the closest prior art found necessary, and the prior art was evaluated.** Vande Veire & De Bie's Table 3 gives their automatic-DJ system's actual transition matrix **[V]** (https://asmp-eurasipjournals.springeropen.com/counter/pdf/10.1186/s13636-018-0134-8.pdf):

| prev \ next | Relaxed | Rolling | Double drop |
|---|---|---|---|
| **Relaxed** | **0** | 0.7 | 0.3 |
| **Rolling** | 0.2 | **0.8** | **0** |
| **Double drop** | 0.2 | 0.8 | **0** |

Three things to steal, and one to leave:

- **The workhorse is explicitly allowed to self-repeat, at 0.8.** `Rolling → Rolling` is the single largest entry in the matrix. A blanket "never repeat" rule would have forbidden the most common move in a working system.
- **The structural zeros encode musical prohibitions, not novelty bookkeeping.** `Relaxed → Relaxed = 0` and `anything-energetic → Double drop = 0` are hard, and they are about what the music can support, not about variety.
- **No row is degenerate.** Every state has at least two futures. Nothing is ever deterministic.
- **Leave the Markov formulation itself.** Their transition type is picked by the FSM *rather than by content* — the paper is explicit — which is the thing my §5.2 feasible-set model is meant to improve on. Steal the shape of the matrix, not the mechanism.

So the decay gets a per-template multiplier, and the climactic gestures get a structural zero rather than a penalty:

```swift
extension GestureTemplate {
    /// Multiplies every λ in the decay. Workhorses are allowed to recur.
    var memoryWeight: Double { … }
}
```

| Class | Templates | `memoryWeight` | Rationale |
|---|---|---|---|
| **workhorse** | `buildToTheOne`, `bassDrop`, `thinOut` | **0.7** | the `Rolling → Rolling = 0.8` case. These are the grammar, not the punctuation; suppressing them hard leaves the engine with nothing to say |
| **standard** | `gate`, `loopHold`, `echoThrow` | **1.0** | |
| **climactic** | `dropOut`, `brake`, `loopRollDown`, `beatRepeat` | **1.4** | high `deltaDuring`, budget cost 2, and the ones a listener will actually remember |

And in §5.2's hard gates, one new **structural zero**, which is a prohibition and not a preference:

> **No climactic gesture may immediately follow another climactic gesture.** Not decayed, not costed — removed from the feasible set until at least one non-climactic gesture or one energy return has intervened. This is Vande Veire's `→ Double drop = 0` row, and it is the difference between a set with peaks and a set that is all peak.

Re-running §5.4's table with `memoryWeight` applied: an exact repeat of `buildToTheOne` five minutes on gives `penalty = 0.7 × 2.447 = 1.713`, `memoryCost = 0.820`, Junkie multiplier **0.385** — still a strong suppression, but a 0.90-base candidate lands at 0.347 rather than 0.284, and by twelve minutes it is at 0.49 rather than 0.37. The workhorse comes back sooner. That is the intended correction.

**Worked, so the behaviour is checkable.** Multipliers on the base score:

| Situation | penalty | `memoryCost` | **Junkie** ×  | **Wedding** × |
|---|---|---|---|---|
| Never used | 0 | 0.000 | 1.000 | 1.000 |
| **Exact same gesture, now** | 1.8 + 1.2 + 0.5 = 3.500 | 0.970 | **0.273** | **0.176** |
| Exact same gesture, 5 min ago | 1.348 + 0.849 + 0.250 = 2.447 | 0.913 | 0.315 | 0.224 |
| Exact same gesture, 12 min ago | 0.900 + 0.522 + 0.095 = 1.517 | 0.781 | 0.414 | 0.336 |
| Exact same gesture, 30 min ago | 0.319 + 0.150 + 0.002 = 0.471 | 0.376 | 0.718 | 0.680 |
| Exact same gesture, 60 min ago | 0.056 + 0.019 + 0.000 = 0.075 | 0.072 | 0.946 | 0.939 |
| **Same template, different parameters, 5 min ago** | 0 + 0.849 + 0.250 = 1.099 | 0.667 | **0.500** | 0.433 |
| Different template, same family, 5 min ago | 0 + 0 + 0.250 = 0.250 | 0.221 | 0.834 | 0.812 |
| Different family, 5 min ago | 0 | 0.000 | 1.000 | 1.000 |

Take a strong candidate at base **0.90** and read it against the profile floors (Junkie 0.52, Wedding 0.68):

| Δt since the exact same gesture | Junkie final | fires? | Wedding final | fires? |
|---|---|---|---|---|
| now | 0.246 | no | 0.158 | no |
| 5 min | 0.284 | no | 0.202 | no |
| 12 min | 0.373 | no | 0.302 | no |
| **30 min** | **0.646** | **yes** | 0.612 | no (σ(−3.4) ≈ 3%) |
| 60 min | 0.851 | yes | 0.845 | yes |
| same template, new numbers, 5 min | 0.450 | ~28% of the time | 0.390 | no |

Read those two bold rows in the first table together: **an exact repeat is unavailable for roughly twenty to thirty minutes, but the same template with different numbers is halfway back after five.** That is precisely the property asked for — parameter variety counts as variety — and it falls out of the level structure rather than being special-cased.

**Wedding is near-absolutely repetition-averse and Junkie is not, and that is deliberate.** Two mechanisms compound: Wedding's higher `memoryStrength` (0.85 vs 0.75) and its much sharper gate (`τ_gate` 0.020 vs 0.073) mean a score that lands 0.07 below the floor fires 3% of the time for Wedding and 28% for Junkie. Correct: Wedding does 2 gestures an hour, so *any* repeat inside the hour is glaring. Junkie does 7, will have to reuse templates, and should do so gracefully rather than being forbidden and falling back to nothing.

**Why a multiplier and not a subtraction in logit space.** `s' = s − τ·penalty` makes the suppression temperature-independent, which is tidier — but it makes the penalty vanish entirely at `τ = 0`, breaking the §5.1(a) claim that memory works without temperature. A multiplier on the score survives pure argmax, because it reorders the candidates rather than reweighting their logits. That property is worth more than the tidiness.

**What the history value has to carry.** All of it injected, none of it read from the environment:

```swift
struct GestureHistory: Sendable, Equatable {
    struct Use: Sendable, Equatable, Codable {
        let signature: GestureSignature
        /// Set-elapsed seconds at which it fired. Injected, never Date().
        let atSetElapsed: TimeInterval
        let completed: Bool          // false = aborted; see §8.4
    }
    let uses: [Use]                  // most recent first, pruned to 90 minutes
    let setElapsedSeconds: TimeInterval
    let arc: SetArc
    let tension: Double              // 0…1, §5.5
    let gesturesInLastHour: Int
    let barsSinceLastGesture: Int?
    let gesturesThisTrack: Int
}
```

**Aborted gestures count, at half weight.** An aborted `dropOut` was still partially heard, and repeating it immediately would still read as a repeat. Multiply that use's contribution by 0.5.

---

### 5.5 Dial 4 — budget, rate and arc

**A proportional rate controller, not a token bucket.**

```
rateAdjust = clamp( γ · (gesturesInLastHour − targetPerHour) / targetPerHour, −0.10, +0.25 )
γ = 0.35
effectiveFloor = profile.gestureFloor + rateAdjust
```

Plus two hard gates that a controller alone cannot express:

| | Wedding | Junkie |
|---|---|---|
| `targetGesturesPerHour` | **2** | **7** |
| `minSecondsBetweenGestures` (hard refractory) | **420** (7 min) | **150** (2.5 min) |
| `maxGesturesPerTrack` | **1** | **2** |
| `gestureFloor` | 0.68 | 0.52 |

**Why not a token bucket** — which is the obvious answer and I rejected it. A bucket makes the engine fire on the *first* opportunity after a token arrives, which means gesture placement under scarcity is determined by refill timing rather than by musical quality. A rising floor does the opposite: when the budget is tight the engine becomes *more selective*, saving its remaining gestures for the best spots. That is what a DJ does.

**And the elegant part:** the rate controller and the memory penalty are the same mechanism seen twice. Firing often forces the engine into progressively more novel gestures, whose scores are lower on `materialFit` and `placement`; simultaneously the floor rises. The system self-limits through the interaction, without either mechanism knowing about the other.

**Tension as a bookkept state, and it must be labelled as such.**

There is no way to *measure* tension. So it is a state variable the shell owns and the core updates, and the reasoning string must never present it as an observation.

```swift
struct TensionState: Sendable, Equatable, Codable {
    var value: Double            // 0…1
    var lastUpdatedSetElapsed: TimeInterval
}
```

Update rules, all pure:

1. **Passive decay toward the material's own level**, evaluated once per phrase:
   `value ← value + 0.25 · (materialLevel − value)`, where `materialLevel = clamp(envelope[now] / (median · 1.15), 0, 1)`.
2. **A completed gesture:** `value ← clamp(value + delta·0.50 + residualAfter)`. `residualAfter` is negative for every gesture in §4 — a *completed* build-and-release leaves the room slightly calmer than it found it, because the payoff discharged the tension it created. Net: `buildToTheOne` **+0.125**, `dropOut` **+0.155**, `bassDrop` **+0.085**.
3. **An aborted gesture:** `value ← clamp(value + delta·0.80)`, with no residual credit. **Aborting raises tension by more than completing does and discharges none of it** — the listener heard something start and not finish. This is also what stops the engine aborting repeatedly: each abort pushes tension further above the arc target, which pushes `arcFit` away from every further tension-adding gesture. An engine that keeps failing goes quiet on its own.
4. **An `envelopeReEntry` passing under the playhead:** `value ← value · 0.55`. The record just discharged its own tension.

**Arc targets and `arcFit`:**

| `SetArc` | target tension | reading |
|---|---|---|
| `.rising` | **0.62** | building toward peak; gestures that add tension are wanted |
| `.holding` | **0.55** | a plateau; gestures should add *interest* without moving the level much |
| `.cooling` | **0.28** | coming down; gestures should be rare and small |

```
want = arcTarget − tension                       // signed
arcCost = min(1, |gesture.deltaDuring − want| / 0.60)
```

So under `.rising` at tension 0.30 the arc wants +0.32, and `buildToTheOne` (+0.35) costs 0.05 while `dropOut` (+0.55) costs 0.38. Under `.cooling` at tension 0.50 the arc wants −0.22, and *every* gesture in the catalog costs ≥ 0.78 — which with weight 0.70 caps Junkie's score at 0.45, below its own floor. **The engine stops doing gestures on the way down without anyone writing a rule that says so.** That is the test that the arc model is the right shape.

**Asymmetry, and it is deliberate.** Tension rises in net steps of at most **+0.155** per completed gesture (a `dropOut`: `0.55 × 0.50 − 0.12`) and by **+0.28** per aborted one, but discharges by **×0.55** on every energy return — from 0.70 to 0.385 in a single bar. So it ratchets up slowly and dumps in one event, which is the shape a build/drop cycle actually has, and it means the engine cannot walk itself into permanent maximum tension. Farbood's model reports an asymmetry between tension rise and fall rates **[R]** (§2.3); these numbers are *shaped* by that recollection and calibrated against nothing.

---

### 5.6 Genre governs the vocabulary

Derived from the existing `GenreProfile` axes rather than hand-authored per genre, in the same style as `GenreDistanceModel.transitionHint` — so a new genre row gets sensible gesture behaviour the moment it exists.

```swift
struct GestureAffinity: Sendable, Equatable {
    /// Multiplier on the profile's target rate. <1 = this genre wants fewer.
    let rateMultiplier: Double
    /// Families this genre's grammar supports, and ones it does not.
    let allowed: Set<GestureFamily>
    let discouraged: Set<GestureFamily>
    /// Per-template tilt, 0.7…1.15. Never removes; only ranks.
    let templateTilt: [GestureTemplateID: Double]
    let reason: String
}
```

The axis rules, each with its argument:

| Axis | Rule | Why |
|---|---|---|
| **`breakdownLength`** | `rateMultiplier ×= (1 − 0.6 · breakdownLength)` | **The inversion that matters most.** Trance (0.85) supplies 64-bar breakdowns and 32-bar builds of its own; a gesture on top is noise. Multiplier 0.49. Hard techno (0.05) supplies nothing and gestures are its only shape. Multiplier 0.97. |
| **`energy`** | `rateMultiplier ×= (0.75 + 0.5 · energy)` | Hot records tolerate — and need — more intervention. |
| **`melodicContent`** | ≥ 0.65 → discourage `.rhythmic`; ≥ 0.80 → veto it | A loop across a chord change collapses harmonically, and we cannot detect chord changes. Melodic content is the only available proxy and it is a good one. **This is the single most useful axis for gesture selection and nobody would guess it.** |
| **`vocalPresence`** | ≥ 0.55 → veto `.rhythmic` and `.gating`; ≥ 0.70 → also `rateMultiplier ×= 0.5` | The honest answer to "we cannot detect vocals": use the prior. Eurodance (0.90), vocal trance (0.85), UK garage (0.70–0.75) get the parametric family only. |
| **`fourFourness`** | ≤ 0.5 → veto `.rhythmic` and `.gating` | On a breakbeat the "one" is ambiguous to a bar-grid detector, and a gate against a broken pattern fights it. |
| **`percussiveDensity`** | ≥ 0.7 → tilt `.rhythmic` +0.15 | Dense percussion is material to chop. |
| **`brightness`** | tilt `filterBuild` by `0.85 + 0.4 · brightness` | A low-pass on a record with nothing above 4 kHz removes nothing. |
| **`swing`** | ≥ 0.55 → veto sub-beat `gate` and `beatRepeat` | A straight 1/16 gate over a shuffled record fights the groove — §1.4 of the transition spec shows the offbeat sits 18.8 ms away at 58% swing. |
| **`phraseStrictness`** | ≥ 0.85 → `release` must be on a 32-bar boundary, not 16 or 8 | Trance punishes a mis-phrased release far harder than tech house does. |
| **`halfTimeFeel`** | ≥ 0.6 → double every ladder/hold bar count | A "bar" perceptually is two bars in dubstep. |

Worked, so it is checkable:

- **Uplifting trance** (energy 0.85, breakdown ~0.9, melodic 0.95, vocal 0.45, phraseStrict ~0.95): `rateMultiplier = (1 − 0.54)(0.75 + 0.425) = 0.46 × 1.175 = 0.54`. `.rhythmic` **vetoed** on melodic content. Releases must land on 32. → *Junkie does ~3.8 gestures/hour here, parametric only, all landing on 32-bar lines.* Correct: trance does not need your help.
- **Hard techno** (energy 0.93, breakdown 0.05, melodic 0.20, vocal 0.20, perc 0.50, fourFour 1.0): `rateMultiplier = 0.97 × 1.215 = 1.18`. Everything allowed. → *~8.3 gestures/hour, the full catalog.* Correct: gestures are the arrangement.
- **Eurodance** (energy 0.62, melodic 0.75, vocal 1.00, phraseStrict low): `.rhythmic` and `.gating` **vetoed** on vocal presence and again on melodic content; `rateMultiplier = ... × 0.5 = ~0.4`. → *~2.8/hour, filter and EQ only.* Correct: this is a pop record with a topline over most of it.

---

### 5.7 "Vibe", decomposed

The owner's read is that vibe is largely genre axes + loudness envelope + set-arc position. I think that is close, and it is worth splitting into what it actually governs, because three of the four are captured and the fourth genuinely is not.

| What "vibe" governs | Captured by | Quality |
|---|---|---|
| **Which gestures are even in the vocabulary** | `GenreProfile` axes → `GestureAffinity` (§5.6) | **Good.** Eight perceptual axes plus `phraseStrictness`/`breakdownLength`/`halfTimeAffinity` is more than most commercial tools have. |
| **How much tension the material already carries** | envelope level + `envelopeReEntry` + `breakdownLength` | **Poor mid-track** (§3.2, the picket fence), good at the edges. This is the weakest link and it is a mastering artefact, not a design failure. |
| **Where in the night we are** | `SetArc` + `TensionState` + the rate controller | **Adequate**, and cheap. `SetArc` is currently set by hand; deriving it from the energy trace is a v2 nicety. |
| **What the room is doing** | **nothing** | **Not captured, and cannot be.** |

That last row deserves to be stated plainly rather than papered over. Jeff Mills' own framing of what he is reading is "the temperature in the room… where the people are positioned". There is no sensor. Any claim that the engine reads the room would be a lie.

**What we do have, and are not using.** Two signals already fetched, both worth adding:

1. **User behaviour is the only ground truth this system will ever get.** A skip within 30 s of a gesture is the strongest negative signal available; a replay is the strongest positive. Log `(signature, completed, skippedWithin30s, replayedWithin120s)` from day one, even though nothing consumes it, because it is the corpus that makes §7.5-style weight calibration possible later. **The cost of logging is nil and the cost of not having logged is a year.**

2. **Familiarity changes what a gesture does.** A listener who knows a track has *veridical* expectations about it — they know where the drop is. A gesture that agrees with the record enhances it; one that contradicts it destroys it. And the app knows which tracks the user has liked. Concretely: when `track.isLiked`, raise `releaseQuality`'s reward for landing on an `envelopeReEntry` or a `.drop` cue (they will feel the payoff), and **raise the cost of a Class 1 self-release placed at an arbitrary phrase boundary** (they will feel the arbitrariness). Under uncertainty, familiarity should make the engine *more conservative*, not less. This is a ~10-line term and it uses data already on `Track`.

**What is genuinely not captured, listed so nobody claims otherwise:** the room; whether the crowd knows the record; anything harmonic mid-track (we have per-region keys at 73% accuracy and no chord detection at all, so "does this loop straddle a chord change" is unanswerable); and the *lyrical* content of a vocal, which is why `.doNotTouch` (§3.4) is the right escape hatch rather than better detection.

---

### 5.8 A worked decision, end to end

**Setup.** Junkie. 34 minutes into the set, `arc == .rising`, `tension == 0.34` — so the arc wants **+0.28**. Four gestures in the last hour against a target of 7, so `rateAdjust = 0.35 × (4−7)/7 = −0.15`, clamped to −0.10 → `effectiveFloor = 0.52 − 0.10 = 0.42`. Playing a hard-techno track, 138 BPM, measured grid at confidence **0.82**, 3:20 into 6:40. An `envelopeReEntry` was detected at 3:52, confidence 0.61, `dipBars = 12`. Last gesture: a `bassDrop` (8-bar hold, no high trim) **6 minutes ago**. Seed `["S-91c4", "tr-88123", "gesture", "104"]`.

**Feasible set after the hard gates.** Five candidates survive. `gate` is out because the next phrase boundary is 6 bars away and it needs 8; everything rhythmic is out on `.loopResize`.

Junkie's weights: `feasibility 1.00, releaseQuality 0.80, riskExposure 0.45, placement 0.65, materialFit 0.75, arcFit 0.70`. Confidences: `releaseQuality` and `placement` take the grid's 0.82, `materialFit` is genre-only at 0.45, the rest are 1.0. So `Σw·κ = 1.000 + 0.656 + 0.450 + 0.533 + 0.338 + 0.700 = 3.6765`.

| Candidate | `release` | `risk` | `place` | `material` | `arc` | mean | cap | **base** | `memoryCost` | × | **final** |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `buildToTheOne` **8-bar**, releasing on the re-entry | 0.14 | 0.18 | 0.05 | 0.10 | 0.12 | 0.914 | **0.908** | 0.908 | 0.221 (family) | 0.834 | **0.757** |
| `buildToTheOne` **16-bar**, same release | 0.14 | 0.18 | **0.20** | 0.10 | 0.12 | 0.892 | 0.893 | 0.892 | 0.221 | 0.834 | **0.744** |
| `brake` to 0.65 over 1 beat | 0.25 | 0.18 | 0.05 | 0.05 | 0.20 | 0.883 | **0.836** | 0.836 | 0.221 | 0.834 | **0.697** |
| `dropOut` 1 beat, phrase self-release | 0.25 | **0.33** | 0.05 | 0.05 | **0.45** | 0.818 | **0.685** | 0.685 | **0.000** | 1.000 | **0.685** |
| `bassDrop` 8-bar, phrase self-release | 0.25 | 0.18 | 0.05 | 0.10 | 0.05 | 0.907 | 0.836 | 0.836 | **0.913** (exact, 6 min) | 0.315 | **0.263** |

Working row 1 so the rest is checkable.
`num = Σ w·c·κ = 0 + 0.656(0.14) + 0.450(0.18) + 0.533(0.05) + 0.338(0.10) + 0.700(0.12) = 0.3172`.
`mean = 1 − 0.3172/3.6765 = 0.914`. Weighted concerns are `release 0.092 · risk 0.081 · place 0.027 · material 0.034 · arc 0.084`, so the worst is `releaseQuality` at 0.092 and `cap = 0.908`, which binds.
Memory: same *family* as the `bassDrop` six minutes ago, but neither the same template nor the same signature, so `penalty = 0.5·e^(−ln2·6/5) = 0.250`, `memoryCost = 1 − e^(−0.250) = 0.221`, multiplier `1 − 0.221 × 0.75 = 0.834`. **Final 0.757.**

Three things worth reading off that table.

**`bassDrop` has the best raw material fit and finishes last.** Base 0.836 — joint second-best of anything here — collapsed to 0.263 purely because it was used six minutes ago. That is the memory system doing its entire job in one row.

**`dropOut` is capped by the arc, not by the material.** `arcFit` costs 0.45 because a +0.55 tension delta over-delivers against a want of +0.28, and at weight 0.70 that caps the whole plan at 0.685 regardless of how clean it would sound. **The arc is what stops the engine reaching for the biggest move it is allowed to make**, which is the failure mode a naïve "pick the most exciting gesture" engine has.

**The top four are within 0.072 of each other, and the distribution is nearly flat.** That is not a defect — it is the scoring being honest. Four decent options within 7 score-points is not a ranking the model has the precision to justify, and choosing uniformly among them is the right response.

**Stage A — the gate.** `s* = 0.757`, `effectiveFloor = 0.42`, `τ_gate = 0.22/3 = 0.0733`.
`P(fire) = σ((0.757 − 0.42)/0.0733) = σ(4.60) = 0.990`. Fires.

**Stage B — the choice.** Softmax at `τ = 0.22`, weights `e^((s − s*)/τ)`:

| | final | weight | **P** | cumulative |
|---|---|---|---|---|
| `buildToTheOne` 8-bar | 0.757 | 1.0000 | **28.3%** | 0.2833 |
| `buildToTheOne` 16-bar | 0.744 | 0.9426 | **26.7%** | 0.5503 |
| `brake` | 0.697 | 0.7613 | **21.6%** | **0.7659** |
| `dropOut` | 0.685 | 0.7209 | **20.4%** | 0.9700 |
| `bassDrop` | 0.263 | 0.1059 | **3.0%** | 1.0000 |

The seeded generator draws **0.617**, landing in `[0.5503, 0.7659)` → **`brake`**. Third-ranked, chosen 21.6% of the time, entirely reproducible from the seed.

That is the whole thesis in one table. The rules produced five options and excluded everything else deterministically. The scoring ranked them deterministically, with the arc holding back the biggest move and the memory demoting the one that would have been a repeat from joint-second to last. And the temperature took the third option, because Junkie is the profile that does that.

**Note what temperature can and cannot do here.** Wedding's τ = 0.06 on this same set gives 40.6% / 32.6% / 14.9% / 12.2% — sharper, but not decisive, because *the scores are close*. Temperature sharpens a distribution; it cannot manufacture a distinction the scoring did not find. If the engine feels like it is picking at random, the fix is usually a scoring term that discriminates, not a lower temperature.

**The reasoning string** — composed from term fragments and selector numbers, never hand-written at a branch:

> **Brake into the downbeat** at 3:37 — rate to 0.65 with pitch tracking it over one beat, snapping back on the one. Phrase boundary release, no cue and no energy return close enough to ride. Grid measured at 0.82. Bass drop used 6 minutes ago, so it is rested (0.26 against 0.84). Held back the drop-out: it adds more tension than a rising arc at 0.34 is asking for. 5th gesture this hour against a target of 7. Seed S-91c4/tr-88123/104.

And the string the console shows when nothing fires is the same machinery with `chosen == nil`:

> **No gesture at 3:22.** Best option was a filter build at 0.41 against Junkie's effective floor of 0.62 — the floor is raised because 11 gestures have fired this hour against a target of 7. Bass drop and filter build both used inside the last 10 minutes. Nothing else has a release to land on: no cue, and no energy return before the mix point at 5:48.

---

## 6. Architecture — the types, and how they compose with what exists

### 6.1 What is reused verbatim

The gesture engine adds **no new architectural ideas**. Everything below is the transition engine's own machinery pointed at a different problem, which is the strongest argument that the transition engine's shape was right.

| Reused unchanged | From |
|---|---|
| `TermResult` (cost + confidence + veto + explanation) | `DJCore.swift` |
| The score function (weighted mean capped by worst weighted concern) | `DJPlanner.score` — **extract to `ScoreEngine`, §6.4** |
| `StageAction`, `TransitionStage`, `StageSnap`, `StageDeck` | `DJCore.swift` |
| `ExecutorCapabilities` and its filtering | `DJCore.swift` |
| `SeededGenerator` (SplitMix64 + FNV-1a string seeding) | `DJCore.swift` |
| `BeatGrid`, `TrackFeatures`, `FeatureProvenance`, `SectionKind` | `DJCore.swift` |
| `PlanRationale` / `Contribution` | `DJCore.swift` |
| `DJProfile` — **five new fields, no new types** | `DJProfiles.swift` |
| `SetArc`, `GenreProfile`, `GenreDistanceModel` | `GenreDistance.swift` / `GenreTaxonomy.swift` |
| The self-test rig (`MixImportSelfTest.Report`, `SOUNDING_TV_MIXTEST=1`) | `MixEngine.swift` / `SoundingTVApp.swift` |

### 6.2 New core types

```swift
// ── Identity ──────────────────────────────────────────────────────────────

struct GestureTemplateID: Hashable, Sendable, Codable,
                          ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String
}

enum GestureFamily: String, Hashable, Sendable, Codable, CaseIterable {
    case parametric, gating, rhythmic, substitutive
}

enum GestureClass: String, Sendable, Codable {
    /// The release event is the gesture's own termination. Always available.
    case selfReleasing
    /// The release must coincide with an arrival in the material.
    case eventSeeking
}

// ── The release target ────────────────────────────────────────────────────

/// Where the tension resolves, and how much we believe in it. `nil` is not a
/// representable state: a gesture without a release target is not a gesture.
struct ReleaseTarget: Equatable, Sendable, Codable {
    enum Kind: String, Codable, Sendable {
        case userDropCue        // authority 1.0
        case userCue
        case envelopeReEntry    // §3.3
        case phraseBoundary     // self-release
        case barBoundary        // self-release, weaker
    }
    let kind: Kind
    let seconds: TimeInterval
    let confidence: Double
    /// What the reasoning string is allowed to call it. `envelopeReEntry` must
    /// render as "energy returns", never "the drop".
    var displayName: String { … }
}

// ── The plan ──────────────────────────────────────────────────────────────

struct GesturePlan: Equatable, Sendable {
    let templateId: GestureTemplateID
    let profileId: DJProfileID
    let family: GestureFamily
    let gestureClass: GestureClass
    let trackId: String
    let deck: StageDeck

    /// Both in the *track's* clock, not the schedule's.
    let onsetSeconds: TimeInterval
    let release: ReleaseTarget

    /// Reuses the transition engine's stage vocabulary exactly. `atSeconds` is
    /// relative to `onsetSeconds`.
    let stages: [TransitionStage]
    /// Executed from any instant, must complete in ≤ abortBudgetSeconds (§8.1).
    let abortStages: [TransitionStage]

    let signature: GestureSignature      // §5.4
    let deltaDuring: Double
    let residualAfter: Double
    let budgetCost: Int
    let profileFloor: Double

    var holdSeconds: TimeInterval { release.seconds - onsetSeconds }
    var stageCapabilities: ExecutorCapabilities { … }   // union, as DJTransitionPlan
}

// ── The template ──────────────────────────────────────────────────────────

protocol GestureTemplate: Sendable {
    var id: GestureTemplateID { get }
    var displayName: String { get }
    var family: GestureFamily { get }
    var requiredCapabilities: ExecutorCapabilities { get }

    /// Hard gates. §5.1(b): every doubt is a veto here, not a cost downstream.
    func admits(track: TrackFeatures,
                at onset: TimeInterval,
                context: GestureContext,
                profile: DJProfile) -> TemplateAdmission

    /// Pure. Zero or more parameterisations at this onset.
    func propose(track: TrackFeatures,
                 onset: TimeInterval,
                 releases: [ReleaseTarget],
                 context: GestureContext,
                 profile: DJProfile,
                 rng: inout SeededGenerator) -> [GesturePlan]
}

// ── Everything the planner is allowed to see ──────────────────────────────

struct GestureContext: Sendable, Equatable {
    /// Playhead position in the live track, injected.
    let nowSeconds: TimeInterval
    /// Where the transition engine intends to leave, if it has decided yet.
    /// Gestures may not be admitted whose release falls inside the lockout.
    let plannedExitSeconds: TimeInterval?
    let transitionLockoutSeconds: TimeInterval
    let reEntries: [ReEntry]              // §3.3
    let cues: [TrackCue]                  // §3.4, sorted
    let affinity: GestureAffinity         // §5.6
    let history: GestureHistory           // §5.4
    let tension: TensionState             // §5.5
    let capabilities: ExecutorCapabilities
}

// ── Result ────────────────────────────────────────────────────────────────

struct GesturePlanningResult: Sendable, Equatable {
    /// Best first. Includes plans below the floor — those are exactly what the
    /// console needs to explain a quiet engine.
    let ranked: [ScoredGesture]
    let rejections: [GestureRejection]
    /// The gate's own arithmetic, always populated even when it did not fire.
    let gate: GateDecision
    /// nil is a real answer, not a failure.
    let chosen: ScoredGesture?
}

struct GateDecision: Sendable, Equatable {
    let bestScore: Double
    let effectiveFloor: Double
    let rateAdjust: Double
    let probability: Double
    let draw: Double
    let fired: Bool
}
```

**Note the shape of `GesturePlanningResult`.** Because the default is silence, **the engine must be able to explain why it did nothing** or it is indistinguishable from broken. `gate` is always populated, `ranked` always contains the losing candidates, and `rejections` always carries the hard-gate reasons. Rendering that in the DJ console is the single best debugging affordance in this design and it costs one view.

### 6.3 New `DJProfile` fields

Nine, all values, no new types, no engine branching — consistent with the "a profile is data" rule:

```swift
// ── Gestures ──
let gestureTemperature: Double        // Wedding 0.06,  Junkie 0.22   §5.3
let gestureFloor: Double              // Wedding 0.68,  Junkie 0.52   §5.3
let memoryStrength: Double            // Wedding 0.85,  Junkie 0.75   §5.4
let targetGesturesPerHour: Double     // Wedding 2.0,   Junkie 7.0    §5.5
let minSecondsBetweenGestures: Double // Wedding 420,   Junkie 150    §5.5
let maxGesturesPerTrack: Int          // Wedding 1,     Junkie 2      §5.5
let maxGestureSeconds: TimeInterval   // Wedding 16,    Junkie 32     §8.2 watchdog
let admissibleGestures: Set<GestureTemplateID>
let gestureWeights: [ScoringTermID: Double]
```

`τ_param = 1.6 × gestureTemperature` and `τ_gate = gestureTemperature / 3` are derived, not stored — one number to turn (§5.3).

Wedding's `admissibleGestures = [buildToTheOne, bassDrop, thinOut]`. Junkie's is the full catalog. Adding a profile remains a constant in `DJProfiles.swift` and nothing else.

Existing fields that already do gesture work and need no change: `maxLoopBars`, `maxLoopHalvings`, `minGridConfidence`, `maxDriftMs`, `energyStepLimit`.

### 6.4 The refactor that makes both engines one engine

`DJPlanner.score(plan:outgoing:incoming:profile:terms:history:templateName:)` contains the formula, the cap, the veto handling, the concern/contribution split and the rationale assembly. All of that is generic; only the `ScoringContext` type is not. Extract:

```swift
enum ScoreEngine {
    static func score<Ctx>(
        terms: [any GenericScoringTerm<Ctx>],
        weights: [ScoringTermID: Double],
        context: Ctx,
        headline: String,
        provenanceCaveats: [String],
        minimumScore: Double
    ) -> (score: Double, rationale: PlanRationale)
}
```

~60 lines moved, two call sites. Payoff: the cap rule, the confidence-attenuates-weight-never-cost invariant, and the "concerns first, then contributions, caveats last" rendering order are implemented **once**. Given that the cap rule is the thing that stops a single bad term being diluted — and it is exactly as load-bearing for `memory` as it is for `tempo` — implementing it twice is asking for the second copy to drift.

### 6.5 The one executor change that matters: `snap`

`MixEngine.ramp` sleeps 16 ms and is driven by `Date()` on the main actor. That is fine for *travel* — a 15-second filter sweep does not care about 16 ms — and wrong for *arrival*. Every gesture's release is an arrival.

```swift
/// Fires `body` as close as achievable to `deckSeconds` on `deck`'s own
/// playhead clock. Coarse sleep until 60 ms out, then 2 ms polling. Returns
/// the achieved error so the caller can log it and §8.2 can act on it.
///
/// Reads the playhead through `playheadPosition(for:)`, which already carries
/// the `isSampleTimeValid || isHostTimeValid` + `sampleRate > 0` guard. Do not
/// write a second guard — the crash window is exactly "just after a node
/// starts", and a gesture can be armed there.
@discardableResult
func snap(on deck: Deck,
          toDeckSeconds target: TimeInterval,
          _ body: @escaping @MainActor (_ errorMs: Double) -> Void) -> Task<Void, Never>
```

**~25 lines, no new nodes, no graph change, no `lastRenderTime` access beyond what `playheadPosition` already does.** It takes release jitter from ±16 ms to ~±2–3 ms, which is the difference between `dropOut` being Junkie-only-and-slightly-wrong and being correct under Wedding's 10 ms budget.

**This is why gestures do not need `sampleAccurateCue`.** `play(at:)` matters when you are *starting* a node against another node's clock — that is beatmatching, and it is the transition engine's problem, gated behind experiment E1. A gesture operates on a node that is already running, so there is no start to align: the only error is when the main actor gets round to moving a parameter. That is a scheduler problem, not an audio-clock problem, and it is an order of magnitude cheaper to solve.

### 6.6 Where the impure shell hooks in

```
PlayerService (@MainActor, existing)
  ├─ mixEngineDidTick  ──── never calls the planner directly (@Published re-entrancy, §9.6
  │                          of the transition spec). Hops via Task { @MainActor in … }.
  ├─ GestureDirector (new, @MainActor)
  │    · owns sessionId, TensionState, GestureHistory
  │    · evaluates ONCE PER PHRASE BOUNDARY, not per tick
  │    · builds GestureContext from PlayerService + WaveformService + genre + cues
  │    · calls GesturePlanner.plan(...)   ← pure
  │    · arms the winner on MixEngine, schedules the release via snap()
  │    · watches for abort conditions (§8.2)
  │    · publishes GestureActivity for the console
  └─ MixEngine (existing) — gains only `snap`
```

`GestureActivity` mirrors `PhantomActivity`'s discipline exactly — `.idle`, `.armed(plan)`, `.running(plan, progress)`, `.aborted(reason)`, `.declined(GateDecision)` — and the last case is the important one: **the engine says out loud when it decided not to act.**

**Evaluation cadence.** Once per phrase boundary, not per 33 ms tick. At 128 BPM with 8-bar phrases that is every 15 s — roughly 16 evaluations per track and ~240 per hour. Each is a pure function over a handful of candidates; the cost is nil. Evaluating more often buys nothing (the answer cannot change between phrase boundaries because the onset must *be* a phrase boundary) and costs the idempotence property (§7.2).

---

## 7. Determinism and seeding

### 7.1 What is injected, and what is forbidden

The pure core has: no `Date()`, no `SystemRandomNumberGenerator`, no `.shared`, no AVFoundation, no I/O. Three things that look like ambient state are values instead:

| Looks ambient | Actually | Carried on |
|---|---|---|
| "what time is it" | `setElapsedSeconds` | `GestureHistory` |
| "where is the playhead" | `nowSeconds` | `GestureContext` |
| "randomness" | `inout SeededGenerator` | parameter |

Per `CLAUDE.md`: no `= .shared` default arguments anywhere in the core — they warn today and are a Swift 6 error. The core never references `.shared`; `GestureDirector` injects.

### 7.2 The seed, and the idempotence property

```swift
let rng = SeededGenerator([
    context.sessionId,          // stable for the DJ session
    track.trackId,
    "gesture",
    String(onsetBarIndex)       // which bar line this decision is about
])
```

Deriving the seed from the **onset bar index** rather than from a decision counter buys a property that is not optional:

> **Re-evaluating the same opportunity must return the same answer.**

Without it, an engine that re-evaluates on a timer will keep re-rolling the gate until it happens to get a "yes" — which converts a 30% firing probability into a near-certainty and silently destroys the entire rate model. It is a genuine bug class, it would be extremely hard to spot by ear (it just feels like the engine does too much), and it costs one line to prevent. **Self-test 5 (§9) asserts it directly.**

### 7.3 Where `sessionId` comes from

Generated once by `GestureDirector` when the mix session goes live, published, and printed as the tail of the first reasoning string. `SOUNDING_TV_DJ_SEED` overrides it under `#if DEBUG`, so a bug report that quotes a reasoning string replays exactly:

```
… Seed S-91c4/tr-88123/104.
```

`SeededGenerator`'s existing `init(_ components: [String])` (FNV-1a over UTF-8 with a `0x2f` separator, into SplitMix64) is used unchanged. No new randomness primitive.

### 7.4 What reproducibility actually buys

Three things, all practical:

1. **A bug report is a replay.** "It did something weird at 34 minutes" plus the seed string plus the track ids reproduces the exact decision offline, with no audio and no device.
2. **A/B on parameters is meaningful.** Change `τ` from 0.22 to 0.30, replay the same 20-track set, diff the gesture list. Without seeding that comparison is noise.
3. **The self-tests can assert on choices, not just on properties.** "This fixture with this seed chooses `buildToTheOne` 16-bar" is a much sharper assertion than "it chooses something admissible", and it is what catches a scoring regression.

---

## 8. Failure modes and the abort path

### 8.1 The admissibility rule

> **Every gesture must have a defined termination that is reachable from any instant within `abortBudgetSeconds = 0.25`, and that reads as intentional rather than as an error. A gesture whose abort path is not reachable in 250 ms is not admissible.**

This is a checkable property of a template, not a runtime hope — self-test 7 (§9) asserts it over the whole registry. It is also why `backspin` is out of scope on musical grounds and not merely on DSP grounds: once you have committed to a backspin there is no graceful exit, so it fails the rule regardless of what the graph can do.

Abort quality by family, and this is where the family split earns its keep:

| Family | Abort | Audible? |
|---|---|---|
| **parametric** | ramp every touched parameter to neutral over `min(remaining, 0.25 s)`, `.logarithmic` | **No.** A filter that stopped closing and opened up is a shorter sweep. |
| **gating** | gain to unity over 20 ms, at the next gate edge if one is imminent | **No**, unless it lands mid-silence — in which case the silence was shorter. |
| **rhythmic** | `clearLoop` at the **next bar line**, never mid-bar, then a 120 ms filter open to mask the seam | **Yes**, as "the loop ended early". Musical, not wrong. This is what the `riskExposure` weighting is pricing. |
| **substitutive** | `delayWet(0, over: 0.25)`, let the tail decay naturally | **Yes**, as a shorter echo. Acceptable. |

### 8.2 Abort triggers

Six, in priority order. The first match wins and the reason is recorded.

| # | Trigger | Detection | Why |
|---|---|---|---|
| 1 | **Transition became due** | `plannedExitSeconds` moved inside `release + lockout` | The transition never waits. |
| 2 | **Deck state changed** | user seek, pause, skip, track change, route change | Any of these invalidates the plan's clock. |
| 3 | **Grid drift** | `snap`'s reported `errorMs` on any stage exceeds `profile.maxDriftMs` (Wedding 10, Junkie 25) | Reuses the existing drift budget rather than inventing one. A gesture that is already 25 ms adrift will not land its release. |
| 4 | **The release target evaporated** | Class 2 only: the predicted `envelopeReEntry` did not arrive within 1 bar | §8.3 |
| 5 | **The material contradicted the plan** | live `loudnessResults` short-term (~10 Hz via `audioProvider:`, §3.5) fell > 6 LU during the *hold* of a build | The record went into a breakdown on its own. Building through it is redundant and wrong. **Optional — needs the live tap wired up.** |
| 6 | **Watchdog** | elapsed since onset > `maxGestureSeconds` (Wedding 16 s, Junkie 32 s) | The unconditional insurance against "the release never comes". Fires regardless of what the plan said. |

Trigger 6 exists because triggers 1–5 all depend on something working. The watchdog depends on nothing but a timer, and it is the reason a gesture cannot leave the deck filtered forever.

### 8.3 The specific failure the brief names: the release never comes

Class 2 gestures ride the record's own architecture, and `envelopeReEntry` is a heuristic at confidence ≤0.75. So it will sometimes be wrong. The design must not merely survive that — it must convert it into something musical.

**The degradation ladder**, in order:

1. **Predicted re-entry at T. Playhead reaches T. No return detected.** Wait exactly **1 bar** (the detector's snapping is bar-quantised, so one bar of slack is the honest tolerance).
2. **Still nothing.** **Convert to Class 1**: release on the next phrase boundary, self-releasing. The gesture completes normally, just without the record's payoff underneath it. The listener hears a build that resolved — slightly less exciting, entirely correct. The reasoning string records the conversion.
3. **The next phrase boundary is beyond the watchdog.** Release on the next **bar** line.
4. **No usable grid at all** (grid confidence collapsed mid-gesture — possible if the transition engine re-analysed). Full abort per §8.1: ramp to neutral over 250 ms, no snap, no attempt to land.

The key property: **at no point does the ladder produce "keep building". Every rung ends the gesture.** A build with no release is the one outcome this system exists to prevent, and it is prevented four ways.

### 8.4 The specific failure the brief names: the loop point lands mid-vocal

This is the rhythmic family's characteristic disaster and it deserves its own treatment because it is the one we cannot detect our way out of.

**Prevention, in order of authority:**

1. `.doNotTouch` or `vocalStart…vocalEnd` cue → hard veto. **This is why §3.4's requirement 2 matters more than anything else in the cue design.**
2. `MusicUnderstanding.instrumentActivity[.vocal]` where measured → hard veto. Unproven (E-G6); expectations should stay modest even if it works, since the closest prior art's vocal-clash detector runs at F1 0.62.
3. `GenreProfile.vocalPresence ≥ 0.55` → the whole rhythmic and gating families are vetoed for that genre. Blunt, and correct: a genre-wide veto costs us gestures on instrumental tracks in vocal genres, and that is a much cheaper error than looping a word.
4. `melodicContent ≥ 0.80` → rhythmic vetoed (a chord change inside a loop is the harmonic version of the same disaster).

**Mitigation when it happens anyway.** A loop is armed and the material inside it turns out to be a vocal phrase. There is no detector to notice this at runtime, so the honest answer is: **the design does not detect it, and therefore the rhythmic family must not ship until (1) or (2) is available.** That is a real constraint and it should be stated rather than hedged. It is also, conveniently, the same gate as the DSP work — `.loopResize` and cue-point authoring land in the same era.

What *can* be done cheaply: cap the rhythmic family's exposure. `loopHold` at 4 bars repeats a phrase once; at 1 bar it repeats a word four times. **So the shortest rungs are the dangerous ones**, and `maxLoopHalvings` (Wedding 1, Junkie 4) is already the right control. Wedding never gets below a 4-bar loop and therefore never chops a word into syllables.

### 8.5 Failure modes not in the brief, found by reading the code

| Failure | Cause | Mitigation |
|---|---|---|
| **Ramp collision** | `MixEngine.ramp` keeps one task per `RampKey`. A gesture's `filterCutoff` ramp and a *transition's* `.outgoingFilterClose` accent target the same key; the second silently cancels the first, leaving the filter wherever it was. | The lockout (§1.4) mostly prevents it. Belt and braces: `GestureDirector` must assert `mixWindow == nil && !isCrossfading` before arming, the same guard every other tick-driven check in `PlayerService` uses. |
| **Loop bookkeeping wiped by a seek** | `clearLoopBookkeeping` is called by `seek`, `stop(deck:)` and `clearDeckPlayback`. A user seek during a `loopHold` leaves the gesture believing a loop is armed that is gone. | Abort trigger 2. The director must observe `decks[i].loopLengthSeconds` going nil, not assume. |
| **`AVAudioFile.read(into:)` on the main actor** | `setLoop` reads the whole loop region synchronously. A 16-bar loop at 90 BPM is 42.7 s ≈ **15 MB**. On tvOS that is a visible hitch. | Pre-stage every rung's buffer at *arm* time, off the main actor, when `resizeLoop` is built. Never read inside a gesture stage. |
| **Rate/pitch left off unity** | `brake` aborts by ramping home, but `finishLiveTransition` also returns rate to 1.0 over 8 s. Two writers to `RampKey.rate(deck)`. | Same lockout. Plus: the director must restore rate and pitch on *every* exit path, including `.aborted`, not only on clean completion. |
| **Tension state survives a track skip** | The user skips; `TensionState` still reflects a build that never resolved. | On any track change, `TensionState.value ← value × 0.7` and every in-flight gesture is marked aborted in the history at half weight (§5.4). |
| **Octave-error ladder** | MU's one observed failure is a clean 2× BPM error. A ladder computed on a doubled grid produces 4-bar rungs where 8 were meant, silently. | §3.5: sanity-check `beatsPerMinute` against `genre.bpmRange`; on mismatch drop grid confidence to 0.4, which disables rhythmic gestures via the profile floor without disabling parametric ones. |

---

## 9. Testability

House pattern, unchanged: `#if DEBUG`, an `enum XSelfTest { static func run() -> MixImportSelfTest.Report }`, registered in `SoundingTVApp.swift`, run under `SOUNDING_TV_MIXTEST=1`. `PhantomPlanSelfTest` and `MixLoopSelfTest` are the shape to copy. Everything in §9.1 is pure and needs no audio, no device and no network.

### 9.1 Pure-core tests

**1 · Determinism — same seed, same choice.**
```
for i in 0..<200 {
    let ctx = syntheticContext(seed: i)
    let a = GesturePlanner.plan(ctx, rng: &SeededGenerator(["fixture", String(i)]))
    let b = GesturePlanner.plan(ctx, rng: &SeededGenerator(["fixture", String(i)]))
    expect("determinism \(i)", a == b)
}
```
`GesturePlan: Equatable` makes this a byte-for-byte comparison including the stage list. This is the assertion that catches an accidental `Date()` or `.random()` creeping into a template.

**2 · Idempotence — re-evaluating an opportunity does not re-roll.**
```
let ctx = syntheticContext(...)
let first = GesturePlanner.plan(ctx)          // seeded from (session, track, onsetBar)
for _ in 0..<30 { expect("idempotent", GesturePlanner.plan(ctx) == first) }
```
§7.2's bug class. Cheap, and the failure is otherwise inaudible-but-devastating.

**3 · Memory suppresses repeats over a simulated 20-track set.**

Fixture: 20 tracks × 4:00 = 80 minutes, phrase boundaries every 15 s (128 BPM, 8 bars), a mix of genres drawn from the real taxonomy, `arc` walking `.rising` → `.holding` → `.cooling`. Run the whole set under Junkie with a fixed session seed, collect the fired gestures, then assert:

| Assertion | Value | Why that number |
|---|---|---|
| no exact `GestureSignature` repeats within | **18 minutes** | §5.4's table puts the score ceiling at 0.34 at 12 min; 18 min is where it clears Junkie's floor with margin |
| max share of any single `templateId` | **≤ 0.45** | with 4–5 admissible templates, 0.45 means no template dominates; uniform would be 0.20–0.25 |
| distinct signatures / total gestures | **≥ 0.65** | i.e. at most a third are repeats of *anything* |
| normalised Shannon entropy over templates | **≥ 0.75** | scale-free, so it survives adding a template |
| gestures fired | **7 ≤ n ≤ 13** | 80 min at 7/hr = 9.3 expected; the band allows genre multipliers and the controller's ±10% |

**4 · Temperature demonstrably changes the distribution.**

2,000 seeded decisions over a *fixed* candidate set with scores `[0.80, 0.70, 0.62, 0.55]`, one profile each:

| Assertion | Wedding (τ = 0.06) | Junkie (τ = 0.22) |
|---|---|---|
| argmax chosen | **≥ 0.90** | **≤ 0.62** |
| worst candidate chosen | ≤ 0.01 | ≥ 0.06 |
| entropy over templates | — | **≥ Wedding's + 0.5 bits** |

Predicted analytically: Wedding weights `1, 0.189, 0.049, 0.014` → **0.80 / 0.15 / 0.04 / 0.01**; Junkie `1, 0.635, 0.427, 0.318` → **0.42 / 0.27 / 0.18 / 0.13**. The Wedding argmax bound of 0.90 is therefore *not* satisfied by τ = 0.06 on this fixture — which is exactly what a calibration test is for. **Either the bound comes down to 0.78 or τ comes down to 0.04.** Recommendation: set the assertion at **≥ 0.78 / ≤ 0.62** and treat any future weight change that breaks it as a real regression. Nail the numbers rather than the inequality, the same discipline the transition spec's §6.2 profile-differentiation test uses.

**5 · The rate controller converges.** 4 simulated hours, constant material quality. Assert the observed rate is within **±20%** of `targetGesturesPerHour` for each profile, and that `minSecondsBetweenGestures` is never violated.

**6 · Arc suppression.** Same fixture with `arc == .cooling` throughout and `tension == 0.50`. Assert **zero** gestures fire under both profiles, and that `GesturePlanningResult.gate` explains why (`bestScore < effectiveFloor`, with `arcFit` as the top concern). This is the §5.5 claim — "the engine stops on the way down without a rule that says so" — turned into an assertion.

**7 · Abort reachability across the registry.**
```
for template in GestureRegistry.all {
    for plan in template.propose(everyFixture...) {
        expect("\(template.id) abort ≤ 250 ms",
               plan.abortStages.map { $0.atSeconds + $0.duration }.max() ?? 0 <= 0.25)
        expect("\(template.id) abort needs no extra capability",
               plan.abortCapabilities.isSubset(of: template.requiredCapabilities))
    }
}
```
§8.1 as a compile-time-adjacent guarantee. An `abortStages` that needs DSP the gesture itself did not declare is unreachable exactly when it is needed.

**8 · The lockout holds.** Given `plannedExitSeconds = T`, assert no admitted plan has `release + lockout > T`, over a sweep of `T` and of `overlapSeconds`.

**9 · Hard-gate coverage.** One fixture per gate in §4's tables (16 or so), each asserting the candidate is absent **and** that a `GestureRejection` names the gate. A veto with no reason is the failure mode this whole design exists to avoid.

**10 · `envelopeReEntry` against synthetic envelopes.**

| Fixture | Expected |
|---|---|
| flat 0.85 everywhere (the picket fence) | **0 re-entries** — must not hallucinate |
| 0.85, 16-bar dip to 0.35, back to 0.88 | exactly **1**, at the return bucket ±1 bar, `dipBars ≈ 16`, `lift ≈ 0.5` |
| 0.85 with a single 1-bucket dip to 0.30 | **0** — a snare gap is not a breakdown |
| 0.85, 16-bar dip to 0.35 **with three single-bucket spikes to 0.95 inside it** | still exactly **1** — the median filter must not let a transient split the run |
| 0.85 with a 1-bucket spike to 1.0 every bar (a hot kick at native resolution) | **0** — the filter must not create a run out of the gaps between transients |
| dip that never fully returns (0.85 → 0.35 → 0.60) | **0** — `highGate` not reached |
| dip in the last 8 bars | **0** — that is the outro, Phantom's job |
| real envelopes from `~/Music/SoundCloud/`, 30 tracks | reported, not asserted — this is **E-G3** |

The first row is the one that matters. A detector that finds structure in a limiter's output is worse than no detector, because it fires confidently on nothing.

**11 · Tension bookkeeping.** Completed build+release → tension lower than before. Aborted build → tension **higher**. Re-entry passing → tension × 0.55. Five assertions, and the second is the one that stops abort loops.

**12 · Signature quantisation.** A 15.8-bar build and a 16-bar build hash equal. `[8,4,2,1]` and `[8,6,4,2,1]` do not. 790 Hz and 810 Hz do (both → 800).

**13 · The selection is not flat.** The regression test for §5.2's cap-flattening bug, and the one most likely to be reintroduced by someone helpfully "tidying" memory back into the term list:

```
let scored = GesturePlanner.rank(fixtureWithFiveCandidates)
expect("scores are distinct",  Set(scored.map { round($0.score * 1000) }).count >= 4)
expect("softmax is not uniform", scored.probabilities.max()! - scored.probabilities.min()! >= 0.15)
```

A tie set of size ≥ 2 at exactly the cap value is the signature of the bug, and it is otherwise invisible: the engine keeps working, it just chooses uniformly at random among its top options and every argument in §5 stops being true.

### 9.2 Offline-render tests

`AVAudioEngine.enableManualRenderingMode(.offline, format:maximumFrameCount:)` renders the whole graph deterministically with no device, no audio session and no real time. Same rig the transition spec's §9.5 specifies; these are the gesture-specific additions.

**R1 · The release actually snaps.** Render `buildToTheOne` over a synthetic full-band tone complex. FFT the 30 ms before and the 30 ms after the release instant; assert the energy above 4 kHz rises by **≥ 18 dB within 50 ms**. This is the assertion that catches a release accidentally routed through `ramp` instead of `snap`, which would be inaudible in a code review and obvious to a listener.

**R2 · The abort is inaudible — a click detector as an assertion.** Render a `buildToTheOne` and fire the abort at 20 evenly spaced instants through the hold. For each render, assert `max |x[n] − x[n−1]|` over the abort window does not exceed **1.6×** the same statistic over an unprocessed control window. This directly implements "a gesture that cannot complete cleanly must degrade to something inaudible, never to a mistake the listener hears" — as a number.

**R3 · `snap` accuracy.** Render 100 snapped releases at random offsets; assert median |error| **< 3 ms** and p95 **< 6 ms**. Under Wedding's 10 ms drift budget this is the gate on `dropOut` being admissible at all.

**R4 · The loop seam, measured not guessed (E-G1).** Render a `setLoop` arm on a continuous 1 kHz tone; find the longest run of samples below −60 dBFS after the arm instant. **Report it in samples and milliseconds.** If it is under ~180 samples (4 ms at 44.1 kHz) `loopHold` graduates to Tier A for Junkie; if it is a full quantum (512 samples, 11.6 ms) it stays Tier C behind `resizeLoop`. Same for `clearLoop`. **This single test decides the whole staging of the rhythmic family** and it costs an afternoon.

**R5 · No headroom excursion.** Render every Tier A gesture at full level and assert the main bus peak stays under **−1.0 dBFS**. `buildToTheOne`'s resonance peak at 0.25 (bandwidth 1.525 oct) is a **boost** at the cutoff and is the one that could clip — `AVAudioUnitEQ` resonant low-pass gain at Q is not free.

**R6 · `brake` tracks the playhead (inherits E6).** Render a brake to rate 0.5 with coupled pitch and assert `playheadPosition(for:)` tracks true source position within **20 ms** throughout. If `playerTime(forNodeTime:)` misreports under a large simultaneous rate+pitch move, every gesture that runs *during* a brake is computing against a lie.

### 9.3 The fixture library

`ffmpeg`-generated material served from a local HTTP server that mimics SoundCloud's JSON second hop, pointed at with `SOUNDING_TV_STREAM_HOST` — already documented in `CLAUDE.md` as the rig that reproduced the DJ crash. Extended with:

- a 128 BPM, 4:00 track with a **real** breakdown (kick removed for 16 bars) so `envelopeReEntry` has something true to find
- the same track **limited to −7 LUFS** so the detector can be tested against the picket fence it will actually meet
- a track with a synthetic "vocal" (a formant-ish sustained tone) at a known range, for the vocal-veto fixtures once detection exists
- a 174/87 pair, so half-time ladder arithmetic is exercised

---

## 10. Staging

### v1 — one gesture, done properly. No new DSP.

1. **`snap(on:toDeckSeconds:)`** on `MixEngine`. ~25 lines. Everything else depends on it.
2. **The pure core**: `GestureTemplateID`, `GestureFamily`, `GestureClass`, `ReleaseTarget`, `GesturePlan`, `GestureTemplate`, `GestureContext`, `GestureHistory`, `GestureSignature`, `TensionState`, the six scoring terms plus the memory multiplier (§5.4), the registry, and the two-stage selector.
3. **`ScoreEngine` extraction** from `DJPlanner.score` (§6.4), so both engines share one formula.
4. **Raise `TrackFeatures.envelope` to native resolution** (§3.2) — move the 1 Hz resample from `PlayerService`'s feature assembly into `PhantomDJEngine.plan`'s own call site, so the outro walk is unchanged and everything else gets 6–10× the resolution. Then **`envelopeReEntry`** (§3.3) on top of it.
5. **`buildToTheOne`** (§4.2), plus **`bassDrop`** (§4.3) — two templates is enough for the memory system to be meaningful and few enough to reason about.
6. **`GestureDirector`** in `PlayerService`, evaluating once per phrase boundary, with the full abort ladder (§8).
7. **Nine new `DJProfile` fields.** Junkie only in v1; Wedding's `admissibleGestures` starts empty and is opened once R1–R3 pass.
8. **Self-tests 1–12 and R1–R3.**
9. **The console line.** `GestureActivity` including `.declined(GateDecision)`. **Ship the "why nothing happened" state in v1**, not later — it is what makes the rest debuggable.
10. **Behaviour logging** — `(signature, completed, skippedWithin30s, replayedWithin120s)` to disk, consumed by nothing (§5.7).

Risk to the documented invariants: **none.** No change to the `AVPlayer`/`AVAudioEngine` handover, no new `lastRenderTime` access beyond `playheadPosition`'s existing guarded read, no new nodes, no graph change. Roughly **700–900 lines of new pure code, ~25 lines in `MixEngine`, ~150 in `PlayerService`, ~350 of self-test.**

### v1.5 — measure, then unlock

11. **R4** (the loop seam). Decides whether `loopHold` is Tier A or Tier C. **Do this before writing `resizeLoop`.**
12. **`dropOut`, `gate`, `brake`** — all Tier A, all gated on R1–R3 and (for `brake`) R6.
13. **Wedding's gestures switched on**: `buildToTheOne` (no breath, resonance ≤ 0.15) and `bassDrop`.
14. **`.doNotTouch` cue honoured** the moment the cue system lands. One veto, enormous value.

### v2 — small DSP

15. **High-pass band** on the existing filter node (`AVAudioUnitEQ(numberOfBands: 2)`, `bands[1].filterType = .resonantHighPass`, a `RampKey.filterHighPassCutoff(Deck)` case, a `setHighPassCutoff` mirroring `setFilterCutoff`). No new node, no reconnection. Registers **`thinOut`**. Shared with the transition engine's T4 — build it once.
16. **`resizeLoop(on:toLengthSeconds:atHostTime:)`** plus off-main-actor buffer pre-staging at arm time. Registers **`loopHold`** and **`loopRollDown`** (Junkie), with `maxLoopBars`/`maxLoopHalvings` already in place.
17. **Vocal veto from a real source** — either cues or `instrumentActivity` (E-G6). **`loopRollDown` must not ship before one of them exists** (§8.4).
18. **`SetArc` derived** from the energy trace rather than set by hand.

### v3 — the rest

19. **`AVAudioUnitDelay` per deck** → **`echoThrow`**. Shared with the transition engine's T5.
20. **`beatRepeat`**, once loop scheduling is fully pre-staged.
21. **The `sections` aggregation layer** (§3.5) — discard boundaries whose spacing matches the modal spacing, keep the survivors. Only then may a gesture precondition read structure.
22. **Live-loudness abort** (trigger 5, §8.2) via the `audioProvider:` tap.
23. **Weight calibration** from the v1 behaviour log. Six weights and one temperature per profile; hand-set values as the prior.
24. **Archive-sparseness novelty, replacing the per-signature decay.** Lehman & Stanley's novelty search **[V]** (https://doi.org/10.1162/evco_a_00025) scores a candidate by `ρ(x) = (1/k) Σ dist(x, μᵢ)` over the *k* nearest entries in a permanent archive, rather than by matching an identity. Applied here, the archive holds recent gesture **contexts** — `(family, templateId, deltaDuring, tension-at-onset, position-in-phrase, genre axes)` — and novelty becomes a graded distance in that space instead of a three-level exact/template/family match. Two advantages over §5.4: it degrades gracefully (a gesture becomes eligible again as the archive drifts, with no half-life to tune), and it captures "different template but functionally the same move" — a `bassDrop` and a `thinOut` at the same point in the same material are near-neighbours in context space and *should* suppress each other, which the identity-matching version cannot see. **Ship §5.4 first**: it is simpler, it is testable by the §9 assertions as written, and the archive version needs a distance metric nobody has calibrated. ⚠️ Also note novelty search has **essentially never been applied to musical decision-making** — the only adjacent work found was synthesiser sound-matching (Masuda & Saito 2023) — so this is an imported idea, not an established musical technique. Gravina, Liapis & Yannakakis' *Surprise Search* (GECCO 2016, DOI 10.1145/2908812.2908817), which rewards deviation from **prediction** rather than from history, arguably maps onto §2.1's prediction-response argument better than novelty does and is worth reading first.

### What deliberately never ships

`backspin` (no reverse playback, and it fails §8.1 anyway), risers (no generator node), reverb freeze (no reverb node, low payoff), sustained half-speed (a production effect, not a gesture).

---

## 11. Open questions, and the experiment that settles each

| # | Question | Experiment | Blocks |
|---|---|---|---|
| **E-G1** | How long is the audio hole when `setLoop` arms and when `clearLoop` releases? | R4 (§9.2): offline render on a continuous tone, longest sub-−60 dBFS run, reported in samples | **The entire rhythmic family's staging.** Do this first — it is an afternoon and it changes v2. |
| **E-G2** | Does `snap` actually reach ±3 ms on an Apple TV, or does the main actor's scheduling under SwiftUI load blow it out? | R3 offline, then repeat on device with the DJ console open and a `TabView` animating | `dropOut` under Wedding; `gate` at 1/16 |
| **E-G3** | On what fraction of the owner's real library does `envelopeReEntry` fire at all, and are its hits musically right? | Run the detector over the raw waveform documents for 100 tracks from `~/Music/SoundCloud/`; hand-check 20 against the audio | Whether Class 2 gestures are worth building. If it fires on < 25% the answer is "Class 1 only, forever". |
| **E-G4** | Is 16 bars actually long enough for a listener to form the 8-bar expectation a gesture violates? | A/B: the same gesture at 8, 16 and 32 bars into a track, blind, n ≥ 6 | The `placement` term's floor. Currently **inferred**, not measured. |
| **E-G5** | Does closing a low-pass genuinely raise perceived tension, or is that DJ folklore that happens to work for other reasons? | §2's literature answer first; then A/B `buildToTheOne` with and without the filter leg, holding the bass drop constant | Whether the filter leg of `buildToTheOne` deserves its weight, and whether `brightness` is the right gating axis |
| **E-G6** | Does `MusicUnderstanding.instrumentActivity[.vocal]` return usable ranges on real SoundCloud material? | Run `.instrumentActivity` over the 11 ground-truth tracks from the MU spike; hand-mark the vocals; compute precision/recall | **`loopRollDown` cannot ship without this or a cue** (§8.4) |
| **E-G7** | Does an `AVAudioUnitEQ` resonant low-pass at `bandwidth = 1.525` octaves boost enough at the cutoff to clip a hot master? | R5 (§9.2) | `resonancePeak`'s ceiling; possibly the master limiter's priority |
| **E-G8** | Does `playheadPosition` stay honest during a coupled rate+pitch brake? | R6 (§9.2) — the transition spec's E6 with pitch added | `brake`, and anything running during one |
| **E-G10** | Does stochastic selection actually beat deterministic selection *here*? Nobody has ever tested this in DJ or game audio (§12). | Render two 20-minute sets from the same queue and the same seed, one at `τ` and one at `τ = 0` with memory still on. Blind A/B, n ≥ 6. **The interesting arm is τ = 0 *with* memory** — if that is indistinguishable from τ > 0, §5.1(a) is right and the temperature dial can be deleted. | Whether §5.3 is load-bearing at all. Cheap, and it would be the only evidence in the literature. |
| ~~E-G9~~ | ~~Does the raw waveform document survive at full resolution?~~ **Answered by reading the code — it does not.** `PlayerService` builds `TrackFeatures.envelope` as `waveform.resampled(to: max(8, Int(duration / PhantomDJEngine.bucketSeconds)))`, i.e. **1 bucket per second**, which at 128 BPM is **0.53 buckets per bar** — below bar resolution. | — | **Fixed in v1, item 4.** No experiment needed. |

---

## 12. Verified, inferred, and unresolved

### Verified by reading the code in this repository

- The graph, per deck: `player → timePitch → eq(3 band) → filter(1 band, .resonantLowPass) → deckMixer → mainMixer → output`. No delay, no reverb, no high-pass, no limiter, no reverse.
- `lowShelfHertz = 200` (already moved from 120), mid `.parametric` @ 1 kHz BW 1.2 oct, high `.highShelf` @ 6 kHz, `eqGainRange = −60…12 dB`.
- `filterCutoffRange = 30…20 000`; `filterOpenHertz = 19 000` and cutoff ≥ that **hard-bypasses the band**, so a release to 20 kHz is bit-transparent.
- `setFilterResonance` maps 0…1 onto `bandwidth = 2.0 − 1.9v` octaves.
- `rateRange = 0.5…2.0`, `pitchCentsRange = −2400…2400`, both rampable on separate `RampKey`s.
- `ramp(_:duration:apply:)` sleeps **16 ms** in a main-actor `Task`, is `Date()`-driven, and cancels any in-flight ramp for the same `RampKey`.
- `setLoop` does `player.stop()` → synchronous `AVAudioFile.read(into:)` → `scheduleBuffer(at: nil, options: [.loops])` → `play()`. The **wrap** is render-thread and gapless; the **arm and clear are not**.
- `clearLoop` resumes from the true playhead via `LoopMath.wrap`, so a clear at the wrap point does resume on the grid — the seam is a dropout, not a timing error.
- `playheadPosition(for:)` carries the `isSampleTimeValid || isHostTimeValid` **and** `sampleRate > 0` guard, and the comment explains the Obj-C exception class it prevents.
- `DJProfile` already carries `maxLoopBars` (8/32), `maxLoopHalvings` (1/4), `minGridConfidence` (0.75/0.55), `maxDriftMs` (10/25).
- `GenreProfile` carries `energy, swing, percussiveDensity, melodicContent, vocalPresence, brightness, fourFourness, halfTimeFeel, phraseStrictness, breakdownLength, halfTimeAffinity, specificity`.
- `SetArc` is `.rising | .holding | .cooling`.
- `LoopRollDownTemplate` already exists in the **transition** registry, declares `.loopResize` + `.sampleAccurateCue`, and is filtered out of every admissible set by `.v1MixEngine`.
- `WaveformService`'s own measurement: five real tracks, p50 ≈ 0.82–0.92, p95 ≈ 0.89–0.95, **body SD 0.011–0.06**. SoundCloud serves `{"width": 1800, "height": 140, "samples": […]}`.
- `PlayerService` (≈line 1926) downsamples that document to **1 bucket per second** before it reaches `TrackFeatures.envelope` — 0.53 buckets per bar at 128 BPM, below bar resolution. Correct for Phantom's outro walk, fatal for gesture placement. §3.2.
- `MixEngine.setGain(_:on:over:)` and `RampKey.gain(Deck)` exist, so a per-deck gain gesture (`dropOut`, `gate`) needs no crossfader and no new plumbing.
- `DJPlanner.score`'s cap rule is `score ≤ 1 − maxᵢ(cᵢ·κᵢ·wᵢ/w_max)`. **`NoveltyTerm` has confidence 1.0 and depends only on `history` and `templateId`, so it produces an identical cap for every plan from the same template — and once several such plans' weighted means exceed that shared cap they tie exactly.** Verified by working the arithmetic (§5.2), not by running it. This is a latent flattening bug in the transition engine and the same fix applies: take novelty out of the mean and apply it as a multiplier on the finished score.

### Verified by reading `mu-findings.md`

- `MusicUnderstandingSession(asset:)` accepts local `file://` only; six remote sources failed `invalidAsset`.
- BPM 10/11 exact against Serato ground truth; the one miss is a clean 2× octave error on a slow track.
- Key 8/11 (73%) exact.
- `sections` on 2 of 3 real tracks was near-uniform ~8-bar chunking with no arrangement-level structure; `phrases` base grain 1–4 bars.
- `loudnessResults` via `audioProvider:` streams at ~10 Hz, tracking real playback 1:1.

### Verified by the literature pass (URLs at the point of use)

- **Holtzman et al., ICLR 2020** — argmax yields 73.66% repetition against a human 0.28%; "the probability of a repeated phrase increases with each repetition, creating a positive feedback loop"; temperatures below 0.9 severely increase repetition; over-truncation mimics greedy search. §5.3.
- **Performance RNN (Magenta 2017)** — at t = 0.8 "the performance seems to overly fixate on a few patterns". The only published temperature sweep for music. §5.3.
- **CTRL (arXiv:1909.05858)** — soft repetition penalty θ ≈ 1.2 divides the logit of already-emitted tokens. **Paulus et al. (arXiv:1705.04304)** hard-zero repeated trigrams, but only after measuring the corpus statistic first. §5.3.
- **Vande Veire & De Bie (2018) Table 3** — the actual transition matrix: `Rolling → Rolling = 0.8`, `Relaxed → Relaxed = 0`, `→ Double drop = 0` from any energetic state. **This produced a real design change** (workhorse vs climactic memory weights, and the structural zero). §5.2, §5.4.
- **Bhandari & Colton, EvoMUSART 2024** — "repetition gains meaning through its relationship with change. Both endless repetition and constant variation could lead to monotony"; listeners retain "specific impactful moments and distinct fragments rather than entire compositions". §2.4.
- **Schellenberg, Corrigall, Ladinig & Huron (2012)** — exposure counts 1/2/4/8/13; liking for the repeated item declines at p < .001 while a contrasting item holds (F(1,44) = 8.32, p = .006). The anchor for §5.4's half-lives. §2.4.
- **Lehman & Stanley (2011)** — novelty search sparseness `ρ(x) = (1/k) Σ dist(x, μᵢ)` over a permanent archive; hard-maze success 39/40 vs 3/40 for fitness-based. §10 item 24.
- **Negative results, all useful:** Music Transformer and the Jukebox paper report **no decoding temperature at all** (verified by grep) — do not cite them for one. Novelty search has **essentially never been applied to musical decision-making**. Game-audio middleware documentation (Wwise, FMOD, Unity, Unreal) is **unfetchable** — every claim about "avoid repeating last N", shuffle containers and the machine-gun effect is industry practice, not a citable source. And **no perceptual study validates stochastic over deterministic effect selection anywhere.**

### Inferred, derived or asserted here — **not** verified

- **The render-quantum figure.** 512 frames at 44.1 kHz = 11.6 ms is the *typical* tvOS buffer, not a measured one for this app. **E-G1 measures the actual hole rather than assuming this number.**
- **Every temperature, weight and threshold in §5.** Reasoned from the shape of the score distribution and from the transition engine's existing values. §9's tests pin them so a change is visible; they are not evidence. Two partial exceptions now: the **half-lives** have an anchor in Schellenberg et al.'s exposure counts, and the **workhorse/climactic split** has one in Vande Veire's transition matrix. Everything else in §5 remains hand-set.
- **The τ values specifically.** Holtzman's "below 0.9 severely increases repetition" is over a 50k-token vocabulary with unbounded logits; this softmax runs over ≤8 candidates with scores in 0…1, so the figures are **not commensurable** and Wedding's 0.06 is not thereby condemned. But the *mechanism* transfers and Wedding is the profile exposed to it. §5.3.
- **`envelopeReEntry`'s gates** (0.60 / 0.90 × median, 2-bar minimum dip, confidence cap 0.75). Designed against the picket-fence measurement, tested against synthetic envelopes, **never run on real material — E-G3.**
- **`GestureAffinity`'s axis rules.** Each has an argument; none has a citation. The `breakdownLength` inversion in particular is a strong claim ("trance does not need your help") that I believe and cannot prove.
- **The 16-bar entrainment floor.** Reasoned from expectation theory (§2); the specific number is **E-G4**.
- **`brake` executability.** The API surface is verified; that the *result sounds like a brake* is not. `AVAudioUnitTimePitch` at rate 0.5 with −1200 cents may sound like a artefact rather than a machine. Nobody has rendered it.
- **`gate` at 1/8 being acceptable at 16 ms granularity.** 7% edge error is arithmetic; that it reads as "soft" rather than "wrong" is a guess.
- **`dropOut`'s tension delta of +0.55**, and every other `deltaDuring`. These are ordinal intuitions dressed as cardinals. They only need to be *relatively* right for `arcFit` to work, which is the weaker and more defensible claim.

### Stated plainly: what this design cannot do

- **It cannot read the room.** There is no sensor and no proxy. Any claim otherwise would be a lie.
- **It cannot know whether a loop straddles a chord change.** No chord detection exists in the stack and per-region key runs at 73%. `melodicContent` is a genre-level prior standing in for a track-level fact.
- **It cannot detect a vocal** until either cues or `instrumentActivity` land, which is why the rhythmic family is gated behind that and not behind the DSP.
- **It cannot see mid-track structure on a limited master.** The picket fence is a property of mastering. `envelopeReEntry` will return nothing on a large fraction of the library and the design's honest answer is Class 1 self-releases, not a better detector.
- **It cannot tell "the track has no arrangement" from "the detector missed the arrangement"** — the MU spike could not either, and neither can we without labels we do not have.

---
