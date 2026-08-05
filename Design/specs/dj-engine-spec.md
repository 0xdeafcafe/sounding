# SoundingCloud Auto-DJ - Architecture Spec

**Status:** design only, no code written. Nothing in the repo was edited.
**Author:** design agent, job 3fc7cb5a.
**Core thesis:** the choice of *next track* and the choice of *transition* are one decision. The engine does not pick a track then find a transition. It enumerates `(candidate, template, exitPoint, entryPoint)` tuples, scores each, and takes the best-scoring tuple. The track is a by-product of the transition, not the other way round.

---

## 0. What actually exists today (verified by reading the code)

Everything in this section was read, not recalled. File paths are absolute.

### 0.1 `MixEngine` - `/Users/afr/Source/github.com/0xdeafcafe/sounding-tv/SoundingTV.swiftpm/Sources/Services/MixEngine.swift`

The graph, per deck (`buildGraph()`, ~line 480):

```
player(AVAudioPlayerNode) → timePitch(AVAudioUnitTimePitch) → eq(AVAudioUnitEQ, 3 band)
    → filter(AVAudioUnitEQ, 1 band) → mixer(AVAudioMixerNode) → mainMixerNode → output
```

Two decks, `Deck.a`/`Deck.b`, bus-pinned into the main mixer (deck N owns bus N - deliberate, so `handleConfigurationChange` re-wiring doesn't leak buses).

| Capability | State today | Detail |
|---|---|---|
| **Time/pitch unit** | **Present** - the brief's open question is answered: `AVAudioUnitTimePitch` is already in every deck chain | `setRate(_:on:over:)`, `setPitch(_:on:over:)`, `matchTempo(on:sourceBPM:targetBPM:over:)`. `rateRange = 0.5...2.0`, `pitchCentsRange = -2400...2400`. `matchTempo` hard-refuses ratios outside `0.84...1.16` (±16%). |
| **Filter** | **Confirmed: resonant low-pass only.** `configureFilter` sets `bands[0].filterType = .resonantLowPass`, `bandwidth = 2.0`, starts at 20 kHz and `bypass = true` | `filterCutoffRange = 30...20_000`; cutoff ≥ `filterOpenHertz` (19 kHz) hard-bypasses the band so "open" is bit-transparent. `setFilterResonance` maps 0…1 onto `bandwidth = 2.0 - v*1.9` octaves. **There is no high-pass band.** |
| **EQ** | 3-band, fixed frequencies | low = `.lowShelf` @ 120 Hz, mid = `.parametric` @ 1 kHz BW 1.2 oct, high = `.highShelf` @ 6 kHz. `eqGainRange = -60...12` dB. |
| **`swapBass`** | Exactly two `setEQ` calls | `setEQ(.low, on: outgoing, toDecibels: -60, over: d)` + `setEQ(.low, on: incoming, toDecibels: 0, over: d)`. Both ramp linearly in dB over the same window. Nothing else. |
| **Crossfade** | Equal-power, always | `applyMixerGains()` unconditionally applies `a = cos(x·π/2)`, `b = sin(x·π/2)` to the two deck mixers' `outputVolume`, multiplied by `masterVolume` and per-deck `gain`. `FadeCurve` (`.linear`/`.smooth`/`.logarithmic`) only shapes how the *fader position* travels, not the gain law. |
| **Ramps** | 60 Hz `Task`-driven, keyed | `ramp(_ key: RampKey, duration:apply:)` sleeps 16 ms. `RampKey` covers `.crossfade`, `.masterVolume`, `.gain(Deck)`, `.eq(Deck,Band)`, `.filterCutoff(Deck)`, `.filterResonance(Deck)`, `.rate(Deck)`, `.pitch(Deck)`. Any new automated parameter needs a new `RampKey` case. |
| **Loops** | **Present and real** | `setLoop(on:startSeconds:lengthSeconds:)` reads the region into an `AVAudioPCMBuffer` and calls `scheduleBuffer(_:at:options:[.loops])`, so the wrap happens on the render thread with no Swift in the path. `clearLoop(on:)` resumes from the true playhead. `LoopMath.resolve`/`.wrap` are pure and self-tested. |
| **Metering** | Per-deck, pre-fader | Tap on `filter` output (post-EQ/filter, pre-crossfader), RMS + peak via vDSP into a lock-guarded box, drained by a 20 Hz tick with VU ballistics. |
| **Playhead** | `playheadPosition(for:)`, guarded | Guards `nodeTime.isSampleTimeValid \|\| nodeTime.isHostTimeValid` **and** `playerTime.sampleRate > 0` before `playerTime(forNodeTime:)`. This is the documented Obj-C-exception crash class. Loop-aware via `LoopMath.wrap`. |
| **Scheduling** | `at: nil` everywhere | `schedule(deck:fromFrame:)` calls `scheduleSegment(..., at: nil, ...)`; `play(deck:)` calls `player.play()`. **Nothing in the engine can currently start a deck at a chosen sample instant.** This is the single biggest gap for real beatmatching - see §8.3. |
| **Source** | Materialised, not streamed | `SourceImporter.materialise` downloads → (if HLS) parses playlist, resolves variants, concatenates segments → `AVAssetReader` decode → canonical 44.1 kHz stereo float32 `.caf` on disk. Cache is LRU-bounded at `maxCacheBytes = 400_000_000` / `maxCacheFiles = 6`. Refuses AES-encrypted playlists, byte-range playlists, and Opus. |
| **Delay/reverb** | **Absent** | No `AVAudioUnitDelay` anywhere in the graph. |
| **Master limiting** | **Absent** | `mainMixerNode` is deliberately never explicitly connected to `outputNode` (so it tracks the hardware format across route changes). Nothing protects the bus from summing two loud decks. |

### 0.2 `PhantomDJEngine` - `.../Services/PhantomDJEngine.swift`

Pure, synchronous, AVFoundation-free, self-tested (`PhantomPlanSelfTest`, `SOUNDING_TV_MIXTEST=1`).

`plan(outgoingDuration:envelope:) -> Plan?`:
- `envelope` is the whole-track peak amplitude array (from `WaveformService`, resampled to ~1 bucket/second).
- `quietThreshold = max(0.05, median(envelope) * 0.55)` - relative to the track's own median, not absolute.
- Search window: `floorSeconds = max(0.55·D, D − 90)`, ceiling = `count − 1 − 2s`.
- Walks **backward** from the ceiling while `envelope[i] ≤ quietThreshold`, requiring ≥ 4 consecutive calm buckets.
- Found → `mixPoint = calmStart`, `transitionSeconds = clamp(calmLength·0.9, 6, 28)`; classifies `.fadeToSilence` if the floor amplitude ≤ 0.4·threshold else `.breakdown`.
- Not found → `.hardStop`, mix point 4 s from the end, `transitionSeconds = 3`.
- `Accent`: `.outgoingFilterClose` for breakdowns ≥10 s, `.incomingFilterOpen` for fades ≥8 s, else nil. Both ride the one low-pass.
- `Plan` = `{mixPointSeconds, transitionSeconds, outroShape, accent, reasoning: String}`.
- `fallbackPlan` = last 12% capped at 16 s, `outroShape == .unknown`, reasoning explicitly says "No waveform".

**This is a good bone structure and the design below extends it rather than replacing it.** The extension is straightforward. `plan` returns *one* exit point. The new engine needs a *ranked list* of exit points, and a second axis (entry points in the incoming track), and a template choice per pair.

### 0.3 `PlayerService` DJ section - `.../Services/PlayerService.swift`

- **The invariant** (line ~1420, "The rules"): `AVPlayer` and `AVAudioEngine` are never both rendering. `takeOverFromAVPlayer` calls `teardownAVPlayer()` before the first deck starts, and `endMixSession` stops the engine before `loadAndPlay` builds a player item.
- **Preload or don't mix**: `prepareIncomingDeck()` materialises the *next queue item* onto the free deck the moment the session goes live. If it isn't `.ready` at the mix point, no mix is attempted - hard cut, with the real reason string.
- `performLiveTransition(to:at:over:announceAsMix:filterAccent:)` is the **single** execution path for every transition. It does, in order: `seek(incoming, to: 0)` → `play(incoming)` → `applyBeatMatch` → pin incoming lows to −60 dB → `crossfade(to:incoming, over:window)` → `swapBass(from:to:over:window)` → optional filter accent. A `mixTask` polls at 33 ms and calls `finishLiveTransition`.
- **`engine.seek(deck: incoming, to: 0)` is hard-coded.** The incoming deck always starts at zero. There is no entry-point concept today.
- `applyBeatMatch` only acts when *both* tracks have `!isEstimated` analyses with real BPMs, and otherwise falls back to `setRate(1, on: incoming)`.
- `finishLiveTransition` returns the incoming deck's rate to 1.0 over 8 s so beat-matching doesn't compound across a set.
- `AudioAnalyzer` (same file, ~line 2751): `AVAssetReader` decode of the **first 60 s only** at 22.05 kHz mono → spectral-flux onset envelope + autocorrelation BPM (60–180 range), chromagram + Krumhansl-Schmuckler key over 24 templates, RMS energy, intro estimate. `outro` is just `duration − 16`, i.e. a placeholder. **`AVAssetReader` cannot read HLS**, so HLS-only tracks fall through to `DJTransitionService.synthesizeAnalysis`, which hashes `track.id` into a fake BPM/key and flags `isEstimated: true`.
- `DJTransitionService.computeTransition` is a 7-branch if/else over `(Δbpm, Δenergy, keysCompatible)` producing `[TransitionStep]` in **bars**, with a hand-assigned `confidence`. `areKeysCompatible` accepts intervals {0, 5, 7} any mode, and {3, 9} with opposite modes.
- `TransitionTechnique` already enumerates `phraseAlign, beatMatch, bassSwap, lowpassSweep, highpassSweep, loopOut, echoOut, quickCut` - **four of which (`highpassSweep`, `loopOut`, `echoOut`, `phraseAlign`) the engine cannot actually execute.** They are rendered as UI chips describing a mix that isn't happening. This is the largest honesty gap in the current code and §3 closes it.
- `isPhantomEnabled: Bool` is `@Published` on `PlayerService`. `Phantom` appears in exactly **three** files: `PhantomDJEngine.swift`, `PlayerService.swift`, `SoundingTVApp.swift`. **Nothing in any view references it.** Migration cost for renaming is therefore small - see §5.4.

### 0.4 `MusicUnderstanding` (tvOS 27) - verified against the real interface

`/Users/afr/.claude/jobs/3fc7cb5a/tmp/sdk/MusicUnderstanding.tvos.swiftinterface`, module version 13, `-target arm64-apple-tvos27.0`.

```swift
public actor MusicUnderstandingSession {
    public convenience init<Provider>(audioProvider: Provider) async
        where Provider: AsyncSequence, Provider.Element == AVReadOnlyAudioPCMBuffer, Provider.Failure == Never
    public convenience init(asset: any AVAsset & Sendable) async throws
    public func analyze(for analysisTypes: Set<AnalysisType>) async throws -> SessionResult
    public func analyze() async throws -> SessionResult
    public func cancel() async
    nonisolated public var loudnessResults: some Sendable & AsyncSequence<LoudnessResult, any Error> { get }
}
```

`AnalysisType`: `.rhythm`, `.structure`, `.key`, `.loudness`, `.pace`, `.instrumentActivity`.

| Result | Shape | What it buys us |
|---|---|---|
| `RhythmResult` | `beats: [CMTime]`, `bars: [CMTime]`, `beatsPerMinute: Float?` | A real **beat grid and bar grid**, not a scalar BPM. This is the single most valuable field in the whole framework - phase alignment, phrase alignment, bar-aligned loops and drift correction all need the grid, not the average. |
| `StructureResult` | `sections: [CMTimeRange]`, `segments: [CMTimeRange]`, `phrases: [CMTimeRange]` | Exit/entry candidate generation. `phrases` is exactly the 8/16/32-bar grammar we would otherwise have to infer. |
| `KeyResult` | `ranges: [RangedValue<KeySignature>]`, `KeySignature = (tonic: Tonic, mode: .major/.minor)` | Harmonic mixing - and it's **time-ranged**, so a track that modulates gives per-region keys. We can ask "what key is playing *at the exit point*", which is strictly better than one key per track. |
| `LoudnessResult` | `integrated: TimedValue<Float>`, `momentary: [...]`, `shortTerm: [...]`, `peak: TimedValue<Float>` | **Gain staging** (§7.4) and a far better energy curve than the RMS scalar we have. `integrated` is presumably LUFS-shaped; `peak` gives true headroom. |
| `InstrumentActivityResult` | `ranges: [Instrument: [CMTimeRange]]`, `activity: [Instrument: [TimedValue<Float>]]`, instruments `.vocal`, `.drum`, `.bass`, `.other` | **Vocal clash detection** - the classic auto-DJ disaster is two vocals over each other, and this makes it a direct lookup. Also lets us find "drums only" regions (ideal exit) and "no bass yet" regions (ideal entry). |
| `PaceResult` | `ranges: [RangedValue<Double>]` | Perceived pace over time - a plausible energy-arc proxy independent of loudness. Semantics unverified. |
| `MusicUnderstandingError` | `.sessionInProgress`, `.emptyAnalysisSet`, `.invalidAsset`, `.hasProtectedContent`, `.internalError` | `.hasProtectedContent` matters: it's the likely failure for anything DRM'd, and `.invalidAsset` is the likely failure for a remote HLS URL. |

**The HLS question, and why it matters less than the brief assumes.**

The spike is measuring whether `MusicUnderstandingSession(asset:)` works on a remote SoundCloud HLS URL. Assume it comes back negative. That does **not** block this design, because of a fact about our own architecture:

> Any track that DJ mode can play has, by construction, already been materialised by `SourceImporter` into a local canonical 44.1 kHz stereo `.caf`. That file is an ordinary `AVURLAsset`. MU can analyse it.

So there are two analysis tiers, and the spike only determines the cost of the *second* one:

- **Tier A (guaranteed to work):** the live deck's track and the incoming deck's track. Both are already local `.caf`s. Full `analyze()` is available for these regardless of the spike outcome. This is enough to plan *the transition currently being executed* with full fidelity.
- **Tier B (spike-dependent):** candidates we have *not* loaded onto a deck. If MU accepts remote HLS, candidate analysis is a network-bound background task. If it does not, candidate analysis requires a partial materialise first (§4.5), which is more expensive but still bounded.

There is a second door too. `init(audioProvider:)` takes an `AsyncSequence<AVReadOnlyAudioPCMBuffer>`. If a partial materialise is needed we can feed MU the decoded buffers directly out of the existing `SourceImporter` transcode pass without a second decode. That is a real saving and it is why §4.5 recommends fusing analysis into the import pipeline rather than bolting it on afterwards.

### 0.5 DSP that is available but unused (verified against the tvOS 27.0 SDK headers)

| Unit | Verified range | Use |
|---|---|---|
| `AVAudioUnitEQFilterType.resonantHighPass` (=4) | Same `AVAudioUnitEQ` node | **A high-pass costs one extra band on the existing `filter` node, not a new node.** `AVAudioUnitEQ(numberOfBands: 2)` with `bands[0] = .resonantLowPass`, `bands[1] = .resonantHighPass`. This is the cheapest high-value change in the whole spec. |
| `AVAudioUnitDelay` | `delayTime 0…2 s`, `feedback −100…100`, `lowPassCutoff 10…sr/2`, `wetDryMix 0…100` | Echo-out. Needs a new node per deck. |
| `AVAudioUnitVarispeed` | `rate 0.25…4.0` | Turntable-style rate+pitch. Alternative: couple `timePitch.rate` and `timePitch.pitch` (§8.2). |
| `kAudioUnitSubType_PeakLimiter` (`'lmtr'`) | Present in `AUComponent.h` | Master-bus safety net via `AVAudioUnitEffect(audioComponentDescription:)`. |
| `AVAudioEngine.enableManualRenderingMode(.offline, …)` | - | **Deterministic offline testing of whole transitions.** See §9.5 - this is how the whole engine gets tested without a device or a real track. |

---

## 1. DJ craft - research

*(Filled in below from three research passes. Claims are labelled **[V]** verified from a fetched source with a URL, or **[R]** recalled/derived and flagged as such. Arithmetic marked **[A]** is my own and checkable.)*

### 1.1 Beatmatching is two problems, not one

Every shipping DJ product separates **tempo lock** from **phase lock**, and so must we.

- Traktor: *BeatSync* maintains tempo **and** phase; *TempoSync* locks tempo only, "meaning there can be offsets in the beat synchronization". A separate **Phase meter** exists purely to display the residual. **[V]** (NI manual, via snippet - native-instruments.com 403s direct fetch)
- Mixxx: *Sync Lock* links tempo. *Quantize* on top of it "ensures beats are perfectly lined up as well". Mixxx names the audible symptom of residual drift as a **"double bass kick"**. **[V]** https://manual.mixxx.org/2.4/en/chapters/djing_with_mixxx
- Mixxx 2.4 added **variable-BPM beatgrids** with Soft Leader/Follower roles. Traktor's documented default is the opposite: "a single Grid Marker with a constant tempo for the entire track" - which is exactly the model that drifts on live or hand-played material. **[V]/[V-snippet]**

**"On the one" hides two separate requirements** - and this is the finding that most changes our design:

- **Beat parity (mod 4).** In 4/4 house the kick is on all four beats, so a **one-beat** offset produces **no flam at all**. What breaks is the backbeat: the incoming clap on 2 & 4 lands on the outgoing 1 & 3 and the groove inverts. **No phase metric catches this.** **[V]** https://vibesdj.io/learn/techniques/beat-matching
- **Phrase parity (mod 32).** Bar 1 of the incoming 8-bar phrase on bar 1 of the outgoing.

So the downbeat error budget is **modular, not metric**. Being right to 2 ms but wrong mod 4 beats is a total failure.

### 1.2 The phase-error budget - a band, not a number

No source gives a single flam threshold; it is transient-dependent. The evidence:

| Figure | Value | Source |
|---|---|---|
| Mixxx design doc: "beats within a **±25 ms** threshold will still sound good" | ±25 ms | **[V]** https://github.com/mixxxdj/mixxx/wiki/Downbeats-And-Phrase-Detection |
| Same doc: "a tempo change of **±0.03%** can be stretched without noticeable difference" | ±0.03% | **[V]** same |
| Echo threshold, castanet (sharp attack) vs organ pipe | **7.5 ms** / 75 ms | **[V-snippet]** ResearchGate, attack-transient/echo-threshold study |
| Live-sound audible flam band | 20–150 ms | **[V-snippet]** ProSoundWeb |
| MIR beat-tracking F-measure tolerance | ±70 ms | **[V]** https://arxiv.org/pdf/2605.12287 - *a research metric, ~3× too loose for DJ use* |

**Our budget: ≤10 ms hard target, ≤25 ms tolerable, >30 ms abort.** A closed hi-hat or clicky kick is in the castanet class.

**Below the flam threshold the problem changes character, not magnitude [A].** Two correlated signals offset by Δt comb-filter, with first null at 1/(2Δt):

| Δt | first null | consequence |
|---|---|---|
| 5 ms | 100 Hz | bass fundamental notched |
| **10 ms** | **50 Hz** | a sustained 50 Hz sub is a 20 ms period → 10 ms is **180°, total cancellation** |
| 20 ms | 25 Hz | sub gone, next null 75 Hz |

This is a stronger argument for bass exclusivity than "it sounds muddy": **an inaudible 10 ms phase error deletes the sub entirely.**

### 1.3 Drift arithmetic - [A], derived here, no DJ source states it

Over elapsed time `T`, drift ≈ `T · Δf/f`. In milliseconds: **`drift_ms = 1000 · Δbpm · T / bpm`**.

At **128 BPM with a 0.1 BPM error**:
- 0.366 ms slip per beat → **0.781 ms/s**
- 10 ms after **27 beats ≈ 6.8 bars**
- 25 ms (Mixxx threshold) after **68 beats ≈ 17 bars**
- **46.8 ms over 32 bars** - well past flam
- a full beat (468.75 ms) after 320 bars = exactly 10:00

**Drift is worse at slow tempos**, because 0.1 BPM is a bigger *fraction* of 90 than of 174:

| Tempo | drift over 32 bars |
|---|---|
| 90 BPM | **94.7 ms** |
| 128 BPM | **46.8 ms** |
| 174 BPM | **25.4 ms** |

→ **Never budget tempo error in absolute BPM. Budget the ratio.**

Required precision to hold ≤10 ms over a 120 s blend: `Δf/f ≤ 8.3×10⁻⁵` = **±0.011 BPM at 128**. BPM stored to one decimal (±0.05) drifts 10 ms in **25.6 s (~14 bars)** - insufficient. **Architecture consequence: do not represent tempo as a rounded BPM at all.** Store `(anchorSample, periodSamples)` as `Double`, or keep MU's `beats: [CMTime]` array, and derive a display BPM only for the UI. For comparison, a CDJ's ±6% range resolves to ~0.026 BPM at 128 - which is why humans nudge continuously. Software has no such excuse.

### 1.4 Groove and swing - why identical BPM still sounds wrong

Roger Linn, in his own words: "I merely delay the second 16th note within each 8th note." **[V]** https://www.attackmagazine.com/features/interview/roger-linn-swing-groove-magic-mpc-timing/ and https://brettworks.com/2013/07/23/roger-linn-on-drum-machine-groove-and-j-dillas-off-beat-sound/

- **50%** = straight; **54%** = "loosens up the feel without it sounding like swing"; **62%** = "looser"; **66%** = perfect triplet swing. "Between 50% and around 70% are lots of wonderful little settings."
- MPC3000 offered fixed steps **50, 54, 58, 62, 66, 71%**. Hip-hop canon is 54–58%. **[V-snippet]**

**Converted to milliseconds [A]** - displacement of the offbeat 16th = `(s−50)/100 × eighthNote_ms`:

| Swing % | @128 BPM | @90 BPM |
|---|---|---|
| 54 | **9.4 ms** | 13.3 ms |
| 58 | **18.8 ms** | 26.7 ms |
| 62 | **28.1 ms** | 40.0 ms |
| 66 | **37.5 ms** | 53.3 ms |

> **A 58%-shuffled house track against a straight track has its offbeat hats 18.8 ms from the other's - right at the flam threshold - with BPMs identical to eight decimal places and downbeats perfectly locked.** Nothing in a beatgrid catches this.

This is the single most important finding for an engine that reasons only about BPM and downbeats: **BPM equality is necessary and nowhere near sufficient.**

**Can we detect it?** Not from beat timestamps. **[V]** https://www.audiolabs-erlangen.de/resources/MIR/2017-JNMR-SwingRatio/ (Dittmar/Pfleiderer/Müller, ISMIR 2015 + JNMR 2017): onset-based swing estimation fails because "small errors in the onset detection propagate considerably into swing ratio estimates"; their fix is a mid-level **log-lag autocorrelation** representation, later a **swingogram** with dynamic-programming tracking. Measured jazz swing ratios span **1.13–3.50**, clustering 1.74–3.07.

Three independent reasons beat-IOI alternation cannot work **[A]**: (a) swing lives *between* beats, so beat IOIs are swing-invariant by construction; (b) onset-timing error propagates directly into the ratio; (c) swing varies within a track.

**Is it in reach for us? Partially - and honestly, mostly not.** `MusicUnderstanding.RhythmResult` gives `beats` and `bars` only; there are no sub-beat onsets, so **swing cannot be read off MU's output**. `PaceResult` is a per-range `Double` of unverified semantics and should not be assumed to encode swing. What *is* cheaply reachable is our own beat-synchronous onset histogram (§2.4): fold an onset-strength envelope modulo the beat period into ~64 phase bins over 32+ bars; the centroid of the second-quarter lobe gives swing as a fraction of the beat. That is the LLACF insight done cheaply, and it needs decoded PCM we already have for any deck-loaded track. **Recommendation: ship without swing in v1, add the histogram in v3, and never claim swing-awareness in the reasoning string until it is measured.**

J Dilla feel is explicitly *not* a swing percentage - Linn: Dilla "avoided quantization entirely… finger-drum his beats live and pretty much leave them raw". **[V]** A scalar cannot represent it; don't try.

### 1.5 Phrasing - the rule of 32

**[V]** https://www.djkit.com/blogs/news/djing-rule-of-32 and https://djtechtools.com/2014/11/16/how-to-dj-101-why-you-must-understand-phrasing/

- 4 beats = 1 bar; **8 bars = 32 beats = one phrase**. "Music changes *naturally* at the end of these 32-beat phrases." Count "8, 16, 24, 32 → change happens." Mix *on* or *just before* the change.
- Failure symptoms named explicitly: "Melodies clash," "Drops hit at the wrong time," and the key line - **"your mix will sound forced - even if the BPMs are matched perfectly."**
- Cues marking a boundary: "a new instrument, a drum fill, or crash."
- Applies to "house, techno, trance, drum & bass, and EDM"; "hip-hop, open-format, or older disco can be less rigid."
- Typical overlap "one to two phrases", **16 bars common for house and techno**. **[V]** https://vibesdj.io/learn/techniques/phrase-mixing
- Afro house blends "can run for 32, 64, or even 128 bars." **[V-snippet]**

**Phrase durations [A]** - the tidy coincidence at 128 BPM is worth using in test fixtures:

| Tempo | 1 bar | 8 bars | 16 bars | 32 bars |
|---|---|---|---|---|
| 90 | 2.667 s | 21.3 s | 42.7 s | 85.3 s |
| 128 | 1.875 s | **15.0 s** | **30.0 s** | **60.0 s** |
| 140 | 1.714 s | 13.7 s | 27.4 s | 54.9 s |
| 174 | 1.379 s | 11.0 s | 22.1 s | 44.1 s |

**What goes wrong at each offset [A]** - this taxonomy drives the `phraseFit` term:

| Offset | Result | Severity |
|---|---|---|
| **1 beat** | Kicks coincide; incoming clap on 2&4 hits outgoing 1&3 → **groove inverts** | Fatal, *invisible to any flam metric* |
| 2 beats | Snares land on kicks | Fatal |
| **1 bar** | Beat- and backbeat-aligned; a drop/fill/crash arrives 1.875 s early | Survivable, structurally wrong |
| 8 bars | Incoming breakdown lands on outgoing drop | Energy arc inverts |

### 1.6 Gain staging - the +6 dB problem

**[V-snippet]** Sweetwater: uncorrelated equal signals sum **+3.01 dB**; 100% correlated sum **+6.02 dB**; music sits between "because the signals are often harmonically or rhythmically related."

**The DJ-specific case [A]:** two beatmatched 4/4 tracks are *deliberately engineered to be correlated in the low band* - both kicks fire on the same sample, both subs in the same octave. **The +3 dB uncorrelated assumption is exactly wrong where it matters most. Budget +6 dB below 250 Hz, +3 dB above.**

| Law | Gain each at midpoint | Correlated sum | Uncorrelated sum |
|---|---|---|---|
| Equal-gain (0.5/0.5) | −6.02 dB | **0 dB** | −3 dB dip |
| **Equal-power (0.707/0.707)** ← what `MixEngine` does | −3.01 dB | **+3 dB bump** | 0 dB |
| Both faders full (real DJ practice) | 0 dB | **+6 dB** | +3 dB |

> **The EQ bass swap is what stops the correlated +6 dB from happening**, because the most-correlated, highest-energy band is never doubled. That is the real engineering justification for bass exclusivity - stronger than "it sounds muddy."

Practitioner guidance: channel meter "around the yellow. **NOT THE RED**" **[V]** https://audiomunk.com/gain-staging-for-djs/; channel peaks **−6 to −3 dB**, master max **−1 dB true peak**, explicitly justified by "a transition where both tracks are playing at full force" **[V]** https://dj.studio/blog/mixing-db-levels. Streaming reference: **−14 LUFS-I**, true peak below **−1 dBTP** **[V]** https://www.masteringthemix.com/pages/how-loud-should-you-master. Club-targeted masters commonly **−7 to −9 LUFS** **[V-snippet]**.

The folk rule is numerically correct: "yellow not red" ≈ −6 dB nominal with peaks to −3 dB ≈ **6 dB headroom**, which is exactly the +6 dB correlated worst case.

### 1.7 The EQ swap in detail

**Real mixer band frequencies [V]** https://forum.djtechtools.com/showthread.php?t=45205 (quoting manuals), corroborated by Pioneer product copy **[V-snippet]**:

| Mixer | Low | Mid | High | Range |
|---|---|---|---|---|
| **Pioneer DJM-800/900/900NXS2** | **70 Hz** | 1 kHz | **13 kHz** | **−26 → +6 dB**, or **Isolator mode with −∞ kill** |
| Pioneer DJM-600 | 100 Hz | 1 kHz | 10 kHz | −26 → +6 dB |
| Allen & Heath Xone:92 | low shelf **250 Hz** | 350 Hz / 2 kHz bells | high shelf 2.5 kHz | - |
| Allen & Heath Xone:42 | 420 Hz and down | 1.2 kHz | 2.7 kHz and up | - |

**Caveat [A]:** these are *nominal band frequencies*, not textbook crossover points. The DJM low control is a shelf whose transition region sits well above 70 Hz, which is why cutting LOW removes the whole bassline. Note the enormous manufacturer spread (70 Hz vs 420 Hz) - **there is no single correct crossover; it is a house-sound decision.** For software, **200–250 Hz low/mid and 2–4 kHz mid/high** is the defensible middle, and 250 Hz matches the Xone:92 corner.

**Our `MixEngine` low shelf is at 120 Hz** - noticeably lower than any of these. At 120 Hz a `-60 dB` low-shelf cut leaves a substantial amount of 120–250 Hz bass-guitar/kick-body energy in the mix, which is precisely the "mud" region. **Recommendation: move the low shelf to 200 Hz** (§3.1). This is a one-line change with a disproportionate audible effect and it should be in v1.

**−26 dB vs −∞ [A]:** −26 dB is 5% amplitude; against an opposing full-level bassline the resulting comb null is only ~0.9 dB deep, so −26 dB is in practice safe. But **software has no reason to compromise: use true −∞.** Our `eqGainRange.lowerBound` is −60 dB (0.1%), which is effectively −∞ for this purpose.

**Timing - the answer to the brief's question. [V]** vibesdj EQ-swapping / bass-shift:

> "The incoming track always enters with its low EQ fully cut, and the bass swap happens as **one decisive move, one or two beats, not a slow crossfade**."

> "Phrase timing matters just as much as knob position. **An accurate bass swap at the wrong phrase point still sounds wrong.**" … "at the end of a 32 beat phrase, you quickly switch basslines."

```
t0                incoming.low = −∞, channel fader begins to rise
t0 … t1           fader rises; mids/highs blend; low band exclusive to A
t1  ◄── PHRASE BOUNDARY (end of a 32-beat phrase)
t1 … t1+1~2 beats THE SWAP: A.low → −∞, B.low → 0 dB, near-simultaneous, fast
t1+2 … t2         faders complete the handover; A's mids/highs fade out
```

> **The bass swap happens *during* the fader move, snapped to a phrase boundary - not at the fader's midpoint.** The fader is slow (16–32 bars); the swap is fast (1–2 beats). **Two different time constants in one transition.**

**This is a bug in the current code.** `performLiveTransition` calls `engine.swapBass(from:to:over: window)` with the *same* `window` as the crossfade - a 20-second linear dB ramp on the low band. That is not a bass swap; it is a slow bass dissolve, and for most of its length *both* basslines are audible at partial level, which is the exact failure mode the technique exists to prevent. Fixing this is the highest value-per-line change in the whole spec (§3.1).

The taught debugging order is also worth encoding as the reasoning-string order: **"first check phrase alignment, then check gain, then check whether both tracks were too busy to overlap comfortably."** **[V-snippet]**

### 1.8 Beat/downbeat detection accuracy - how much to trust the features

- Beat F-measure tolerance is **±70 ms**; a tracker can score perfectly and still be unusable for DJ purposes. Failure taxonomy: octave errors, continuity errors, complete failure. Models "tend to generate **confident-but-wrong** activations." **[V]** https://arxiv.org/pdf/2605.12287
- The standard DBN's default 55 BPM floor "prevents it from inferring the correct tempo for **21% of slow music tracks**, forcing double-tempo predictions." Errors of **3× and 4×** are also observed. **[V-snippet]** arXiv 2401.00209
- Octave-error correction alone improved algorithms by **45%/65.5%** on ISMIR04/MIREX06. **[V-snippet]**
- "**The tempogram… is useless to find the phase of these pulses.**" Mixxx multiplies DFT and ACF tempograms pairwise, because "the DFT adds harmonics… the ACF adds sub-harmonics", so only peaks present in both survive - a cheap octave-error killer worth stealing. **[V]** Mixxx wiki

Real-world failure modes **[V]** https://www.thomann.de/blog/en/learn/how-to-edit-beatgrids-manually-and-why-you-should-do-it/:
- **Shuffle**: "the software gets confused by the double hits of the bass drum… displays an incorrect tempo, for example, **97 BPM instead of 130 BPM**." Note **[A]**: 130 × 0.75 = 97.5 - a **3:4 metrical error, not an octave error**. Correction logic that only tries ×2 and ÷2 misses it.
- Soft-attack drums; pickup beats misread as downbeats ("the entire grid does not sit correctly"); live/acoustic material; and **deliberate laid-back placement**, where the grid is correct and the audio is intentionally off it - quantising to the grid actively destroys the groove.
- "If the song varies slightly in BPM, this grid will 'drift out'." **[V]** https://www.digitaldjtips.com/advanced-beatgridding-flexible-dynamic-elastic-how-to-do-it/

**The asymmetry that governs our confidence weighting [A]:** software is *better* than a human at tempo, *comparable* at beat phase, and **much worse at downbeat and phrase**, because those depend on musical structure rather than signal periodicity. → **Trust automatic tempo; verify automatic downbeat; treat phrase boundaries as the least reliable of the three.** This directly sets the confidence attenuations in §5.3.

### 1.9 Grounding: the owner's actual library (read-only scan)

Strictly read-only inspection of `~/Music`, as authorised. **This is empirical, not recalled.**

- `~/Music/SoundCloud/` - **321 files**: 268 `.m4a`, 42 `.mp3`, 9 `.wav`. Overwhelmingly edits, bootlegs, refixes and unreleased material ("(mozart - unreleased)", "(Semisecco Edit)", "FREE DL", "[Ingo Remix]"). **This is exactly the material with no reliable published metadata** - which is the case the engine must actually serve.
- `~/Music/_Serato_/database V2` - **215 analysed tracks**: 215 with BPM (**13 of them 0.0, a 6% analysis-failure rate**), 210 with key, 186 with genre.
- **BPM distribution is strongly bimodal**: a 125–129 cluster (**42 tracks**) and a large 70–100 mass (**82 tracks**, peaking at 80–84). Median **95.2**. → The half/double-time problem is not hypothetical for this user; it is half the library. A naive `|Δbpm|` is wrong on this collection roughly half the time.
- **Keys are overwhelmingly minor**: Am 34, Em 24, Cm 15, Fm 14, G#m 14, Gm 11, Dm 11, F#m 10 - vs C 17, A 8, F 8. Camelot A-side dominance; the harmonic term will mostly be comparing minor to minor, where relative-major moves (`+3` semitones, mode flip) are the interesting escape hatch.
- **Genre strings are messy and multi-valued**, exactly as the genre agent will have found: `"Trance, Progressive House"` (25), `"Hip Hop/Rap"` (9), `"Rap / Hip-Hop"` (1), `"Rock / Indie"`, `"Disco/Nu Disco/Re-Edits"`. Comma- and slash-separated, inconsistent, and **29 of 215 have no genre at all**. `"Pop"` (61) and `"Electronic"` (32) dominate and are nearly useless as labels.

**Negative finding, and it kills one idea in the brief:** the coordinator suggested mining the owner's real Serato cue points as empirical evidence for mix-point selection. **That data is not present on this machine.** `_Serato_/Subcrates/` contains only Serato's own demo crates; and of 40 `.mp3` files sampled from `~/Music/SoundCloud/`, **zero** contain a `Serato Markers` GEOB frame. rekordbox's `master.db` is SQLCipher-encrypted (rekordbox 6+) and not readable without the key. So: **no cue-point corpus exists to learn from, and the design must not depend on one.** This is also a data point for §7 - the training-data problem is not abstract; the most obvious local source of ground truth is empty.

---

### 1.10 The transition archetypes

**Bass swap.** Digital DJ Tips, verbatim **[V]** https://www.digitaldjtips.com/the-ultimate-guide-to-mixing-house-music/: "mix in the incoming track with its bass EQ down, then on a suitable 'one beat', turn the bass off on the outgoing track while simultaneously turning it on for the incoming track." Why: "the 'kick drum' contains the most volume, and a good trick is to have only one kick drum playing loud at once." Incoming prep is **LOW and MID fully down, HIGH ~11–12 o'clock** **[V-low]**. Sound on Sound on the physics **[V]** https://www.soundonsound.com/techniques/mixing-bass: layered basses "can cancel gruesomely at certain frequencies if there are polarity or phase mismatches" → "tonal carnage"; and their low frequencies "present the primary headroom bottleneck." Conflict zones cited as 20–100 Hz (fundamentals), 40–80 Hz (weight), 100–200 Hz (warmth). Historical: **Ron Hardy** at the Music Box is the canonical aggressive EQ-swapper - Marshall Jefferson: "Hardy would mess with every fuckin' thing," explicitly contrasted with Frankie Knuckles who touched bass only occasionally **[V]** https://magazine.waxpoetics.com/article/ron-hardy-house-of-revolution/

**Filter direction convention** - consistent across every source. **[V]** https://www.digitaldjtips.com/rock-the-dancefloor/adding-eq-filters-and-effects/: "Turn the filter knob to the left, and you progressively introduce a low pass filter… Turn it to the right, and you're getting a high pass filter." Centre = bypass with a detent. Traktor matches **[V]** https://blog.native-instruments.com/traktor-effects/. **High-pass thins the *outgoing*** - it strips kick and bass first, leaving hats, clearing low-end space without touching volume: the exit/handover move. **Low-pass sweep brings a track in "underwater" and opens it**: the build/reveal move. Durations: 2–4 bars for a flavour move **[V]** https://learningtodj.com/blog/practical-guide-to-dj-filters/; 8–16 bars for a full build/reveal **[V]** https://unison.audio/filter-sweeps/; Traktor's own tutorial moves the filter "over… the last four bars of a musical phrase" **[V]**. Resonance guidance: Q ~0.7 wide vs 1.5 narrow; resonance 1.0 up to 2.5 "for added energy"; watch the 2–4 kHz "resonance concern range" **[V]** unison.audio. Practitioner rule: "Keep filter resonance low: a little movement helps, squealing does not" **[V-low]**.

**Loop vs loop-roll - a distinction our `setLoop` currently blurs.** A **loop** freezes the playhead: track time stops. A **loop roll / beat roll** keeps the timeline advancing silently underneath, so releasing snaps you to where you'd have been - "the track keeps playing silently underneath the whole time" **[V-low]** https://edm-ghost-production.com/dj-knowledge-base/dj-looping-techniques; on CDJs this is **SLIP MODE**, and in Serato the roll button is momentary **[S]**. The halving build **4 → 2 → 1 → ½ → ¼ beats** is given identically by two independent sources **[V-low]**. Starting loop for a transition: 4 or 8 beats; practical range 4–16; 16–32 beats to extend a whole phrase. rekordbox auto beat loop offers 1/32…32 beats **[S]**; CDJ-3000 BEAT LOOP defaults to 4 with halve/double buttons **[S]**; Serato Loop Roll spans 1/32–32 **[S]**. **Nobody could source who originated it** - treat any attribution as unverified.

**Echo-out.** Digital DJ Tips' definition, verbatim **[V]** https://www.digitaldjtips.com/stop-using-echo-out/: "**kill the track, echo it, then drop something new over the top.**" Their critique is itself evidence of ubiquity: "It works, but it's also a dead end… the moment you trigger that echo, you've lost control of it." Step order **[V-low]**: engage echo on the **last beat of a phrase** → pull the channel fader on that beat → the tail "continues 'in time' through the next downbeat" → start the new track on the following downbeat. The repeats are already in the FX buffer before the fader drops, which is what prevents a hard cut. Divisions taught: **1/8, 1/4, 1/2, 3/4, 1 beat** **[V]** https://www.digitaldjtips.com/how-to-use-echo-when-djing/; the author's own practice is "**1/2 beat or 1 beat**", wet/dry **30–40%** **[V]**. DJM-A9 Beat FX DELAY spans 1/16–16 beats **[V]** (manualslib). Traktor Delay T3 starting points **50–60% feedback, 30–40% wet** **[S]**. Serato's Delay exposes an **HPF cutoff on the repeats** **[V]** - that detail matters: high-passing the tail is how you stop it muddying the incoming bass. The pro version of the move is Pioneer's **FX Frequency** buttons: deselect lows before Echo and you get "a much cleaner output" **[V]** https://djtechtools.com/2016/04/04/3-techniques-pioneer-djm-900nxs2s-eq-effects/. Pioneer's own taxonomy: **DELAY = one repeat; ECHO = several decaying repeats; SPIRAL = delay+reverb hybrid** **[V]**.

**Double drop.** Execution **[V]** https://www.homemusicmaker.com/what-is-a-double-drop: select tracks whose basslines *complement* rather than compete; map each track's breakdown/build/drop; **count backwards in bars** ("if track A drops at bar 32 and track B drops at bar 16, count back 16 bars on track A"); release simultaneously; manage bass by cutting one deck's lows or *alternating bass emphasis every few bars*; resolve by filtering one out. Preconditions, all verified: matched BPM, non-clashing keys (Andy C: keys "can't clash" **[V]** Skiddle), complementary frequency content, both drops needing a free "slot", and deep familiarity - Andy C calls it "**muscle memory**". **Correction to the brief: every source ties the double drop primarily to drum & bass. Dubstep/hardcore/trance could not be verified as canonical double-drop genres.** Andy C is the originator ("he 'coined the double drop'" **[V]** Dancing Astronaut), typically across three turntables **[V]** Wikipedia, and rejects sync on principle: "syncing tracks just doesn't get me off." His description of success is the best statement of the goal in the whole dossier: "two tunes locked in perfect sync and they're working together, bouncing off each other. **They're almost creating a new song.**"

**Harmonic mixing.** The Camelot wheel *is* the circle of fifths: **+1 on the wheel = +7 semitones**. The full 24-key table was cross-checked against 8B = C major / 8A = A minor / 9A = E minor / 5A = C minor. ⚠️ **Source conflict:** Mixed In Key's own wiki states "8A = C Minor", contradicting every other source *including MIK's own advanced page* - **go with 8A = A minor.** Safe moves **[V]** https://mixedinkey.com/harmonic-mixing-guide/: same code; **±1 same letter**; **letter switch at the same number** (relative major/minor). The prohibition, verbatim **[V]**: "8A will go with 8B, because that's one step. But **8A is a key clash with 9B**, because you need to make two steps." Advanced moves, all self-consistent under +1 wheel = +7 semitones: **Energy Boost +2 wheel = +2 semitones**; **+7 wheel = +1 semitone**; the "**Armin van Buuren**" −5 wheel = +1 semitone; **Energy Drop −2**; **+4 wheel = +4 semitones** (major third, "dissonant-then-effective, works best with simple melodies"); **diagonal** with MIK's specific asymmetry (B→A: +1; A→B: −1); **parallel-key mood shift** (8B → 5A). Cadence guidance: energy boosts "every 20–30 minutes, but not ALL the time."

**Energy arcs.** Mixed In Key's 1–10 scale is the most concrete published model **[V]** https://mixedinkey.com/harmonic-mixing-guide/sorting-playlists-by-energy-level/. Level 5 = "**This is where people start dancing**"; 6 = "you can play it the entire night, and people won't get bored"; 8 = "festival anthems… hands-in-the-air"; 9 = "people run out of breath in 1–2 minutes". Computed from "hi-hat patterns, white noise… and other elements" - brightness/aggression, **independent of BPM**. **The one-step rule, verbatim:** "**one step at a time**… We don't recommend skipping from Energy Level 5 > 7… **It'll sound like a different DJ got on the decks.**" Real set traces they published: Armin van Buuren, Ultra 2017 - `7,8,8,8,7,7,7,8,8,8,7,7,8,7,7`, avg **7.5**, "always going up or down 1 step"; Martin Garrix avg **7.0**, "not jumping 6 > 8"; Skrillex avg **7.26** with a *deliberate* crash to Level 4 mid-set then back to 6. **Dips are engineered, not accidents.** Warm-up etiquette **[V]** https://www.digitaldjtips.com/5-essential-tips-for-playing-a-great-warm-up-set/: "**If you build up your set so your last few tunes are the loudest, biggest club bangers in your box, how is the next DJ going to follow on from you?**" A practitioner curve **[V]**: hour one "very low and almost not growing up"; near the end "similar energy as the headliner will play, **but not higher**"; hard rule "**Never play tracks with higher BPM than the headliner**"; plus "drop it down up to 90–95% of total volume."

**Tempo/pitch hardware and practice.** CDJ-3000 **[V]** manualslib: tempo ranges "**±6 (0.02%) ±10 (0.05%) ±16 (0.05%) WIDE**", WIDE extending to ±100%. Technics SL-1200GAE: **±8%**, ±16% with ×2; platter strobe marks at ±6.4% and ±3.3%. **1 semitone = +5.9463% up / −5.66% down** **[V]** omnicalculator. So **±6% ≈ just over one semitone; ±10% < two; ±16% ≈ 2.6.** 128 → 174 BPM is **+35.9% ≈ 5.3 semitones** - which is why the pitch fader cannot bridge house to D&B. **Key-lock artefact thresholds are genuinely contested** - sources give 5%, 8%, and 10–20%, none from a controlled study. Do not state a hard threshold. **2:1 tempo ratios are free**: a 174 BPM D&B track and an 87 BPM hip-hop loop share the same downbeat grid exactly, no stretch, no shift. "Drumstep" exists precisely as this pivot.

**Named DJs worth citing.** Jeff Mills - three decks plus a live TR-909, but his own framing is that he reads "the temperature in the room… where the people are positioned" **[V]** DJ Mag. Carl Cox - three-turntable pioneer; origin was a 15,000-person rave and a spare standby deck; his framing is "**like remixing other people's music, live**" **[V]** DJ Mag. ⚠️ "three decks and a bag of tricks" **could not be verified** in any source. DJ EZ - rapid chopped UK garage mixing, "flicking between the faders"; on Cleptomaniacs' "All I Do" he "punches in a vocal sample in **triplet time** before dropping the track in perfectly on cue" **[V]** https://ra.co/reviews/13702. Objekt - a 5-hour Berghain set with "frequent pace changes and no 'Berghain techno' to be heard" **[V]** Crack. Daft Punk *Alive 2007* - Ableton Live on custom machines with BCR2000 controllers, performing **live mashups of their own catalogue**, the reference point for *stem-level* rather than track-level transition **[V]** Wikipedia. Richie Hawtin *DE9: Closer to the Edit* - 100+ tracks sliced into **300+ loops from a single note to 4 bars**, reassembled into a 53-minute mix with 31 ID points **[V]**. **Two corrections to the brief:** Eric Prydz's "long builds / own unreleased edits" is snippet-only, and **"trancegate" is not an Above & Beyond signature** - no source connects the term to them; the trance gate is a general production technique popularised by Tiësto **[V]** MusicRadar.

### 1.11 The academic layer - this is where the defaults come from

**Kim, Choi, Sacks, Yang & Nam, ISMIR 2020** - https://arxiv.org/pdf/2008.10267. **The best empirical source in the dossier.** 1,557 real mixes, 13,728 tracks, **24,202 track plays, 20,765 transitions, 1,570 hours**, mean tempo 127 BPM, 12.9 transitions per mix. Verbatim findings:

- **"86.1% of the tempo are adjusted less than 5%, 94.5% are less than 10%, and 98.6% are less than 20%."** Double-exponential, centred on zero.
- **"Only 2.5% among the total 24,202 tracked instances involve transposition and, among those transposed tracks, 94.3% of them are only one semitone transposed… DJs generally do not perform key transposition much and leave the 'master tempo' function turned on in most cases."**
- **Transition-length histogram "has peaks at every phrase"**, marked every **32 beats**.
- **Inter-DJ cue-point agreement: 23.6% exact, 40.4% within 4 beats, 73.6% within 8 measures, 86.2% within 16 measures.** Human annotator disagreement on mix boundaries itself has σ ≈ **9 s**.
- Cue types: cue-in 52%, cue-out 30%, cue-mid 18%.
- Failure mode to note: chroma-DTW **fails on techno/ambient material "which only contain drum and ambient sounds"**.

**Vande Veire & De Bie, EURASIP JASMP 2018:13** - the closest prior art, D&B-specific. Source read directly at https://github.com/aida-ugent/dnb-autodj. **Crucially, there is no global cost function** - it is a 5-stage greedy filter cascade: key filter → style filter (top 6) → cue point selection → vocal-clash rejection → ODF-matching DTW pick. Constants, from code:

```python
TYPE_DOUBLE_DROP='double drop'; TYPE_ROLLING='rolling'; TYPE_CHILL='relaxed'
LENGTH_ROLLING_IN=16; LENGTH_ROLLING_OUT=16          # downbeats == bars
LENGTH_DOUBLE_DROP_IN=16; LENGTH_DOUBLE_DROP_OUT=32
LENGTH_CHILL_IN=16; LENGTH_CHILL_OUT=16
MAX_SONGS_IN_SAME_KEY=6;  min_playable_length=32     # bars
LOW_CUTOFF=70; MID_CENTER=1000; HIGH_CUTOFF=13000; Q=0.707; NUM_STEPS=20
```

**At 175 BPM, 16 bars ≈ 22 s and 32 bars ≈ 44 s.** These are long crossfades by consumer-app standards. Transition type is picked by a Markov FSM (`chill→[0, 0.7, 0.3]`, `rolling/ddrop→[0.2, 0.8, 0.0]`), **not by content** - double drops are forbidden after a rolling or another double drop. Their crossfade profile is a bass swap expressed as data, with a **duplicated time point** so the low and high shelves cross **instantaneously at the crossover point** while volume is already at parity. Gain law is `np.sqrt(...)` - **equal-power** - plus an explicit `loudness_balance = np.sqrt(1.0/(master_vol**2 + slave_vol**2))` across the overlap. Their harmonic rule set is exactly same / relative / ±7 semitones, plus ±1 semitone candidates admitted *because they will be pitch-shifted into place*. Segment labels are a bare **RMS-vs-song-mean threshold** ("high"/"low"); a low→high transition *is* the drop. Accuracy: beat **98.2–99.4%**, downbeat **95.3–98.1% per song**, structure **94.3–95.3%**, end-to-end **90.9% fully correct**. Vocal-clash SVM: F1 **61.7%**, "prevents 69.3% of true clashes at the cost of discarding 16.5% of clash-free crossfades." Runtime **2.3 s per minute of audio** for annotation on a 2015 dual-core i7. User study n=18: style-aware selection beat style-agnostic **17/18, p = 7.25e-5** - but **rhythmic (ODF) matching was not statistically significant (10/15, p = 0.151)**.

**Bittner et al., ISMIR 2017 (Spotify)** - https://archives.ismir.net/ismir2017/paper/000086.pdf. Sequencing = shortest Hamiltonian path over a weighted feature space (acoustic CNN vectors → ℝ⁸, key/mode → ℝ³ arranged so circle-of-fifths neighbours and relative major/minor are equidistant, tempo on a **log₂** scale with an optional octave-wrapping unit vector). Transitions = `argmin` over six standardised cost matrices: timbre, chroma, **loudness (rewards regions loud in both)**, **vocalness (penalises both having vocals)**, **drop-coincidence**, **section-boundary-coincidence**. Structural significance explicitly ranked **drops > section boundaries > downbeats**. Candidate pruning: track 1's fade-out end must be **in the last 25%**, track 2's fade-in start **in the first 20%**. Rendering ramps tempo per beat: `d_out = ((N−n)/N)·d₁ + (n/N)·d₂`. Results: **Good 64.13% / OK 28.26% / Bad 7.61%**, mean 2.56/3. **Failure attribution: "beats do not align" 15.22%; key clash 0%.** A/B test: **+1.4 pp daily return rate**; and **~95% of Spotify users never enable the existing fixed crossfade.** Their own conclusion is a direct argument against learning: *"the experiments above prove how just a few interpretable features are suitable for this problem to a remarkable extent."* ⚠️ Their drop detection is **crowdsourced playhead-scrubbing telemetry**, not acoustic - an option we do not have.

**Zehren, Alunno & Bientinesi, CMJ 46(3) 2022** - four cue-point rules, verbatim: **Beat Gridding** ("a switch point is always located on a strong beat"), **Period Alignment** ("always occurs on the downbeat at the start of a period", period = 4 bars), **Novelty**, **Salience** ("located in the initial portion of a track that precedes the first point of salience", because "DJs tend to look for switch points only in the intro"). Constants: 8-bar checkerboard kernel; peak = local max in a 4-bar window with amplitude **> 0.3 × feature max**; salience threshold **0.4 × max harmonic energy** averaged over the 4 following bars. Results **precision 86% / recall 49%**, **95.8% of candidates usable**, mean **8.9 candidates per track** (min 1, max 33) - versus **Mixed In Key at 65% precision** on the same task. Their own caveat is directly usable: "one could argue that in order to create a sense of anticipation, a DJ wants to switch **4 or 8 bars before** the next track exhibits any element of novelty. **We agree.**"

**Ishizaki et al., ISMIR 2009** - the perceptual tempo ceiling, **n = 96 subjects**. Discomfort histogram **peaks at ×1.10 and ×0.90**. Within 0.90 < f < 1.10, discomfort was reported by **15.42% (SOLA) / 11.31% (SoundTouch)**. Their system splits the required change **between both tracks** rather than forcing one onto the other, with a **fixed 5-second ramp**. **±10% is the perceptual ceiling, independently confirmed by the 94.5%-under-10% behavioural figure above.**

**Kell & Tzanetakis, ISMIR 2013** - 114 BBC Essential Mix sets vs albums vs random EDM. Timbre dominates. Tempo distance between successive excerpts: DJ sets **median 0.12 BPM** (Marsyas: **0**) vs albums 10–11. Loudness: DJ sets 0.76 ± 0.71 dB vs random EDM 3.18 ± 3.07. And the finding that should temper our harmonic term: **"we can thus suggest that DJs do not use key as a primary concern when selecting and ordering their tracks."** No statistically significant key effect at all. Ordering heuristics vs the DJ's true order (lower = closer, random ≈ 192–204): Rank **186.27**, NN 187.64, **Median 171.85**, **Equal-Step 172.75** → *"transitions of roughly equal size are probably a better choice"* than similarity ranking, which causes playlist drift.

**The neural evidence - DJtransGAN, ICASSP 2022** (arXiv 2110.06525). The only purpose-built deep DJ-transition model, properly evaluated. Generator = a differentiable mixing console emitting 24 effect parameters (a two-clipped-ReLU fader and a differentiable 4-band EQ implemented as a fade curve *along the frequency axis*). Discriminator trained on 284 crawled mixes → 7,064 sections; generator inputs synthetic, constrained to **ΔBPM ≤ 5 and Δkey ≤ 2 semitones**. Transition length **hard-coded to 8 bars**, cue points fixed by convention, and track 2 **pre-stretched and pre-shifted before the model runs**. Listening test: 136 qualified (46 DJs). **GAN ≈3.2, linear crossfade ≈3.1, hand-written rules ≈3.0 - no statistically significant difference between any of the three. All three beat naive summation (≈1.9) and all three lose clearly to a human (≈3.9).** Experienced DJs complained the GAN "makes transition too fast." They explicitly avoided supervision because labelling "is time-consuming."

**Data availability, as of 2026.** **Raveform** (TISMIR 9(1), 20 Apr 2026, https://transactions.ismir.net/articles/10.5334/tismir.288) - **4,902 mixes, 56,873 tracks, 53,780 transitions, 6,522 hours, 1,423 tracks with full human structure annotations** using an EDM-specific vocabulary: **Intro, Buildup, Breakdown, Drop, Cooldown, Bridge, Outro, Ambient-Intro, Ambient-Outro**. Annotations only, CC BY 4.0, audio referenced by YouTube ID. **EDM-CUE / CUE-DETR** (ISMIR 2024) - **21,461 manually placed cue points across 4,710 tracks from four professional DJs' rekordbox libraries**, 35× larger than the previous set; a fine-tuned DETR over Mel spectrograms reaches **best F1 0.46** (vs Mixed In Key 0.22, rule-based Automix 0.13). **Even with 21k expert labels and a modern detector the task caps out at F1 0.46 - because cue placement is genuinely multi-modal**, which Kim et al.'s 23.6% exact inter-DJ agreement independently confirms. **No public dataset of real EQ/fader automation curves exists.** The only exact version (UnmixDB) is synthetic, uses constant time-scaling and linear crossfades, and is **CC BY-NC-ND** - noncommercial, no derivatives.

**Feature accuracy, for setting confidence weights.** *Beat This!* (ISMIR 2024, MIT, ~20 M params; a **2 M-param** variant loses only 0.3 F1): GTZAN **beat F1 89.1 / downbeat 78.3**; on **HJDB (hardcore/jungle/D&B) beat 98.2 / downbeat 96.6**; on classical, downbeat collapses to 61–66. Its own caveat: without a DBN, **continuity metrics regress** (GTZAN downbeat AMLt 79.1 vs 88.1 with one) - and for a DJ grid, continuity matters more than F1. *All-In-One* (WASPAA 2023, MIT) is **300 K parameters** - 1.2 MB at fp32 - and beats a 9.3 M-param transformer: Harmonix beat **.958**, downbeat **.915**, segment boundary **.660**, label **.738**. Its heavy dependency is Demucs demixing, and the published ablation prices dropping it at only **−0.017 downbeat / −0.046 segment boundary**. **Key detection is the weak feature: the best MIREX 2020 submission scored 40% on GiantStepsKey (EDM)** under a scheme that already gives partial credit for fifth and relative errors, versus 76–83% on classical. Commercial tools agree with each other only **~39%** of the time three-way; community benchmarks put Mixed In Key at 76–95% and built-in detectors at 40–74%. **Genre priors are decisive:** general downbeat trackers scored **29–51%** on hardcore/jungle/D&B (commercial DJ software: 38.5% and 7.4%) while a style-specific model scored **74.7%** (Hockman et al., ISMIR 2012); and Vande Veire simply constrained tempo search to 160–190 BPM and got 98–99%.

---

## 2. Architecture: pure core, impure shell

### 2.1 The boundary

The single most important structural decision. **Everything that decides is pure; everything that acts is not.**

```
╔═══════════════════ PURE CORE ═══════════════════╗   ╔══════ IMPURE SHELL ══════╗
║  no AVFoundation · no I/O · no network          ║   ║  AVFoundation, network,   ║
║  no singletons · no Date() · no global RNG      ║   ║  MusicUnderstanding,      ║
║                                                 ║   ║  disk cache, MixEngine    ║
║  TrackFeatures        (value)                   ║   ║                           ║
║  DJProfile            (value)                   ║   ║  FeatureProvider          ║
║  TransitionRegistry   (value)                   ║   ║  CandidateProvider        ║
║  ScoringRegistry      (value)                   ║   ║  TransitionExecutor       ║
║  ExitPoint / EntryPoint (value)                 ║   ║  DJDirector (@MainActor)  ║
║  TransitionPlan       (value)                   ║   ║                           ║
║  PlanRationale        (value)                   ║   ║                           ║
║                                                 ║   ║                           ║
║  DJPlanner.rank(...) -> [ScoredPlan]   ← pure   ║   ║  executes a TransitionPlan║
╚═════════════════════════════════════════════════╝   ╚═══════════════════════════╝
                         ▲                                        │
                         └──── features in, plans out ────────────┘
```

`PhantomDJEngine` is **already on the right side of this line** - the file header says so explicitly ("everything below is synchronous, has no dependency on AVFoundation/MixEngine/PlayerService"). The work is to widen it, not to relocate it.

### 2.2 Core types

```swift
// ───────── Pure value inputs ─────────

/// Everything the planner knows about one track. Every optional field is
/// genuinely optional: `nil` means "not measured", never "assume a default".
/// `provenance` is what stops the planner claiming a move it can't justify.
struct TrackFeatures: Equatable, Sendable, Codable {
    let trackId: String
    let duration: TimeInterval

    // Rhythm
    let beatGrid: BeatGrid?              // §2.3 - supersedes a scalar BPM
    let swingRatio: Double?              // 0.5 = straight; nil = not measured (§1.4)

    // Harmony - time-ranged, so we can ask "what key at 5:12?"
    let keyRegions: [KeyRegion]

    // Structure
    let sections: [Section]              // Raveform vocabulary, §2.3
    let phraseBoundaries: [TimeInterval] // bar-grid phrase starts

    // Energy / level
    let loudness: LoudnessCurve?         // integrated + shortTerm, LUFS-shaped
    let envelope: [Float]                // the existing WaveformService peak array
    let paceCurve: [RangedValue<Double>]?

    // Content
    let instrumentActivity: [Instrument: [TimeInterval2]]  // .vocal/.drum/.bass/.other
    let genre: GenreEstimate?            // supplied by the genre subsystem

    let provenance: FeatureProvenance
}

/// Which tier each field came from. The planner reads this, not a bool.
struct FeatureProvenance: OptionSet, Sendable, Codable {
    static let measuredTempo      = FeatureProvenance(rawValue: 1 << 0)
    static let measuredBeatGrid   = FeatureProvenance(rawValue: 1 << 1)
    static let measuredDownbeats  = FeatureProvenance(rawValue: 1 << 2)
    static let measuredKey        = FeatureProvenance(rawValue: 1 << 3)
    static let measuredStructure  = FeatureProvenance(rawValue: 1 << 4)
    static let measuredLoudness   = FeatureProvenance(rawValue: 1 << 5)
    static let measuredVocals     = FeatureProvenance(rawValue: 1 << 6)
    static let envelopeOnly       = FeatureProvenance(rawValue: 1 << 7)
    static let metadataOnly       = FeatureProvenance(rawValue: 1 << 8)
}
```

### 2.3 `BeatGrid` - why a scalar BPM is the wrong representation

§1.3 showed a one-decimal BPM drifts 10 ms in 14 bars. The grid is therefore the primitive and BPM is a derived display value:

```swift
struct BeatGrid: Equatable, Sendable, Codable {
    /// Seconds of the first tracked beat.
    let anchor: TimeInterval
    /// Seconds per beat, as a Double. NEVER round this.
    let beatPeriod: Double
    /// Which of beats 0..3 is the downbeat. The mod-4 parity of §1.5.
    let downbeatOffset: Int
    /// Bars per phrase - 8 for house/techno, sometimes 4. From MU `phrases`.
    let barsPerPhrase: Int
    /// 0…1. Below `profile.minGridConfidence` the planner refuses phase lock.
    let confidence: Double
    /// Non-nil when MU gave us real beat times: use these, not the model.
    let beats: [TimeInterval]?

    var bpm: Double { 60.0 / beatPeriod }              // display only
    var barDuration: Double { beatPeriod * 4 }
    var phraseDuration: Double { barDuration * Double(barsPerPhrase) }
}
```

**Section vocabulary - adopt Raveform's, not a binary H/L.** Vande Veire's "high/low" is a bare RMS-vs-mean threshold; Raveform (2026, same author group, real annotations *inside mixed audio*) gives a strictly better-resolved set, and it maps cleanly onto both MU's `sections`/`segments` and rekordbox's own labels:

```swift
enum SectionKind: String, Codable, Sendable, CaseIterable {
    case ambientIntro, intro, buildup, drop, breakdown, bridge, cooldown, outro, ambientOutro
}
```

### 2.4 Registration, not switch statements

Two independently registerable unit types. Neither the planner nor any existing template needs editing to add either.

```swift
// ───────── Templates ─────────

struct TransitionTemplateID: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    let rawValue: String
}

/// A template is a *pure candidate generator*. Given the two tracks and a
/// profile, it proposes zero or more concrete transitions. It does not score
/// them and it does not execute them.
protocol TransitionTemplate: Sendable {
    var id: TransitionTemplateID { get }
    var displayName: String { get }

    /// The DSP this template needs. The registry filters on this against the
    /// executor's declared capabilities, so a template that needs a high-pass
    /// simply does not appear until the high-pass ships.
    var requiredCapabilities: ExecutorCapabilities { get }

    /// Cheap gate, evaluated before any point enumeration. Returning a
    /// `.rejected(reason:)` feeds straight into the rejection breakdown.
    func admits(outgoing: TrackFeatures, incoming: TrackFeatures,
                profile: DJProfile) -> TemplateAdmission

    /// Pure. Deterministic given the same inputs and the same `rng`.
    func propose(outgoing: TrackFeatures, incoming: TrackFeatures,
                 exits: [ExitPoint], entries: [EntryPoint],
                 profile: DJProfile, rng: inout SeededGenerator) -> [TransitionPlan]
}

// ───────── Scoring terms ─────────

struct ScoringTermID: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    let rawValue: String
}

/// Everything a term is allowed to see. Pure value type - note there is no
/// engine, no clock and no I/O in here.
struct ScoringContext: Sendable {
    let outgoing: TrackFeatures
    let incoming: TrackFeatures
    let plan: TransitionPlan
    let profile: DJProfile
    let history: SetHistory        // recent tracks, templates, energy trace
}

/// A term's verdict. `cost` in 0…1 (0 = perfect). `veto` is reserved for
/// physical impossibility, never for taste - see §5.6.
struct TermResult: Sendable, Equatable {
    let cost: Double
    let confidence: Double         // 0…1. Attenuates weight, never cost. §5.3
    let veto: Bool
    /// One clause, lower-case, no trailing stop, e.g.
    /// "128.0 → 127.4 BPM (−0.5%)" or "8A → 9A, one step round the wheel".
    let explanation: String?
}

protocol ScoringTerm: Sendable {
    var id: ScoringTermID { get }
    func evaluate(_ ctx: ScoringContext) -> TermResult      // pure
}

// ───────── Registries ─────────

struct TransitionRegistry: Sendable {
    private(set) var templates: [TransitionTemplateID: any TransitionTemplate] = [:]
    mutating func register(_ t: any TransitionTemplate) { templates[t.id] = t }
    func admissible(for profile: DJProfile,
                    capabilities: ExecutorCapabilities) -> [any TransitionTemplate] {
        profile.admissibleTemplates.compactMap { templates[$0] }
              .filter { capabilities.contains($0.requiredCapabilities) }
    }
}

struct ScoringRegistry: Sendable {
    private(set) var terms: [ScoringTermID: any ScoringTerm] = [:]
    mutating func register(_ t: any ScoringTerm) { terms[t.id] = t }
}
```

**Note what `requiredCapabilities` buys us.** It is the mechanism that makes §3's "what MixEngine can execute today" a *runtime fact* rather than a comment. `TransitionExecutor` declares what it can do; a template that needs `.highPassFilter` or `.delayPerDeck` is silently absent from the admissible set until that capability ships. This directly fixes the current honesty gap where `TransitionTechnique.echoOut` is rendered as a UI chip for a move the engine cannot make.

### 2.5 The planner - one pure function

```swift
enum DJPlanner {
    /// Pure. No I/O, no clock, no global state. Same inputs → same output.
    static func rank(
        outgoing: TrackFeatures,
        candidates: [TrackFeatures],
        profile: DJProfile,
        templates: TransitionRegistry,
        scoring: ScoringRegistry,
        capabilities: ExecutorCapabilities,
        history: SetHistory,
        rng: inout SeededGenerator
    ) -> [ScoredPlan]
}

struct ScoredPlan: Sendable, Equatable {
    let plan: TransitionPlan
    let score: Double                        // 0…1, higher is better
    let rationale: PlanRationale
    var fires: Bool { score >= plan.profileMinimumScore }
}
```

### 2.6 Explainability as an output, not a log line

`PlanRationale` is a value type built from the `TermResult`s, and `Plan.reasoning` (the field already on `PhantomDJEngine.Plan`) is a *rendering* of it. This is the concrete differentiator: tvOS 27 ships Apple's own AutoMix as a black box, and a mix that can state why is the defensible difference.

```swift
struct PlanRationale: Sendable, Equatable {
    let templateName: String
    let headline: String                       // one sentence
    let contributions: [Contribution]          // sorted by |weight × (1 − cost)|
    let concerns: [Contribution]               // the costly ones
    let provenanceCaveats: [String]            // "tempo is estimated, not measured"

    struct Contribution: Sendable, Equatable {
        let termId: ScoringTermID
        let explanation: String
        let weightedCost: Double
    }

    /// Renders to the existing `reasoning: String`, in the order DJ instructors
    /// teach for debugging a bad swap: phrase → gain → content (§1.7).
    var reasoning: String
}
```

Worked output for a good pairing:

> **Loop-roll out** at 5:12 into *Track B* at its 16-bar intro - 128.0 → 127.4 BPM (−0.5%, key-locked), 8A → 9A one step round the wheel, tech house → tech house. Both on phrase boundaries. No vocal overlap. Held 4 bars back because B's intro is only 8 bars.

And for a rejection - the debuggable breakdown, free:

> **No mix.** *Euro dance → hard groove*: genre distance 0.80, tempo Δ14.0 BPM (no valid 2:1 or 3:2 relation), no compatible outro found in the last 25%. Best available plan scored 0.31 against a Wedding threshold of 0.62. Playing out to a clean cut.

### 2.7 Determinism

`rank` takes `inout SeededGenerator`. Variety (so the engine does not make identical choices every set) comes from the seed, not from `SystemRandomNumberGenerator`. The `DJDirector` in the shell derives the seed from something stable and reproducible - e.g. `SHA256(sessionId + outgoingTrackId + transitionIndex)` - so **any plan can be reproduced exactly from the log.** No `Date()`, no `.random()`, and per `CLAUDE.md`, **no `= .shared` default arguments anywhere in the core** (they warn today and are a Swift 6 error). The core does not reference `.shared` at all; the shell injects.

---

## 3. The transition catalog

### 3.0 Executor capabilities - the gap made explicit

```swift
struct ExecutorCapabilities: OptionSet, Sendable {
    static let crossfade         = ExecutorCapabilities(rawValue: 1 << 0)  // ✅ today
    static let threeBandEQ       = ExecutorCapabilities(rawValue: 1 << 1)  // ✅ today
    static let lowPassFilter     = ExecutorCapabilities(rawValue: 1 << 2)  // ✅ today
    static let timeStretch       = ExecutorCapabilities(rawValue: 1 << 3)  // ✅ today
    static let pitchShift        = ExecutorCapabilities(rawValue: 1 << 4)  // ✅ today
    static let loopBuffer        = ExecutorCapabilities(rawValue: 1 << 5)  // ✅ today
    static let entryCue          = ExecutorCapabilities(rawValue: 1 << 6)  // ❌ 1-line
    static let snappedBassSwap   = ExecutorCapabilities(rawValue: 1 << 7)  // ❌ S
    static let highPassFilter    = ExecutorCapabilities(rawValue: 1 << 8)  // ❌ S
    static let sampleAccurateCue = ExecutorCapabilities(rawValue: 1 << 9)  // ❌ M
    static let loopResize        = ExecutorCapabilities(rawValue: 1 << 10) // ❌ M
    static let delayPerDeck      = ExecutorCapabilities(rawValue: 1 << 11) // ❌ M
    static let masterLimiter     = ExecutorCapabilities(rawValue: 1 << 12) // ❌ S
    static let reversePlayback   = ExecutorCapabilities(rawValue: 1 << 13) // ❌ L, out of scope
}
```

Sizes: **1-line** = one call site; **S** ≈ under a day; **M** ≈ 2–4 days; **L** = a week+.

### 3.1 The three changes that cost almost nothing and matter most

Before any new template, three defects in the existing execution path. All three are in v1.

**(a) The bass swap is not a swap.** `performLiveTransition` calls `swapBass(from:to:over: window)` with the *same* `window` as the crossfade - a 20-second linear dB ramp on the low band, during most of which **both basslines are audible at partial level**. That is precisely the failure the technique exists to prevent (§1.7, §1.6). Every source says the swap is **one to two beats**, snapped to a phrase boundary, *inside* a slow fader move; and the Ghent reference implementation encodes it as a **duplicated time point** so the shelves cross instantaneously. Fix: give `swapBass` its own duration and its own trigger time, decoupled from the fader.

```swift
// New capability: .snappedBassSwap
func swapBass(from outgoing: Deck, to incoming: Deck,
              atHostTime t: AVAudioTime,        // snapped to a downbeat
              over duration: TimeInterval)      // 1–2 beats, NOT the fade window
```

**(b) The low shelf is at 120 Hz.** Every reference sits higher: DJM nominal 70 Hz but with a shelf transition well above it, Xone:92 low shelf **250 Hz**, Xone:42 "420 Hz and down", Ghent's implementation 70 Hz at Q = 0.707. At 120 Hz a −60 dB cut leaves the 120–250 Hz kick-body and bass-guitar region fully present - the mud band. **Move `eq.bands[0].frequency` to 200 Hz.** One line; disproportionate audible effect.

**(c) The incoming deck always starts at zero.** `engine.seek(deck: incoming, to: 0)` is hard-coded in `performLiveTransition`. Every template below needs an entry cue. Threading an `entrySeconds` through is a one-line change and opens the entire entry-point axis of the search.

### 3.2 The templates

Each entry gives: sound · preconditions · parameters · execution gap.

---

**T1 · `bassSwapBlend`** - the workhorse.
*Sound:* both tracks running, incoming enters with lows killed, mids/highs interleave over 16 bars, lows swap in 1–2 beats on a phrase boundary, outgoing fades out.
*Preconditions:* ≥16 bars of outgoing runway from the exit point; `|Δbpm|` within profile after rate correction; both grids `confidence ≥ 0.6`; no ≥2-bar vocal overlap.
*Parameters:* `fadeBars ∈ {8,16,32}` (default 16), `swapBeats ∈ {1,2}`, `swapAtBar` (phrase boundary inside the fade), `incomingLowCut = −60 dB`, `incomingHighTrim = −3 dB` until the swap.
*Capabilities:* `crossfade, threeBandEQ, timeStretch, entryCue, snappedBassSwap`.
*Gap:* **executable after §3.1(a) and (c) only.** This is the v1 template.

---

**T2 · `filterFadeOut`** - Phantom's existing `.outgoingFilterClose`, upgraded.
*Sound:* outgoing recedes into the mix as its low-pass closes over the blend rather than merely getting quieter.
*Preconditions:* outgoing exit region is a `.breakdown` or `.cooldown`; blend ≥ 10 s (below that a sweep is inaudible noodling - Phantom already enforces this).
*Parameters:* `cutoffFrom = 20 kHz`, `cutoffTo = 320 Hz` (existing `accentClosedFilterHz`), `curve = .logarithmic`, `resonance ≤ 0.3` ("a little movement helps, squealing does not").
*Capabilities:* `crossfade, lowPassFilter`.
*Gap:* **none - ships today.**

---

**T3 · `filterBloomIn`** - Phantom's existing `.incomingFilterOpen`.
*Sound:* incoming arrives muffled and blooms open as it takes over.
*Preconditions:* outgoing `.fadeToSilence`/`.ambientOutro`; blend ≥ 8 s.
*Parameters:* as T2, reversed; 8–16 bar sweep per unison.audio's build/reveal guidance.
*Capabilities:* `crossfade, lowPassFilter`. *Gap:* **none.**

---

**T4 · `highPassThinOut`** - the correct exit filter, and currently impossible.
*Sound:* the outgoing track is progressively stripped of kick and bass, leaving hats and percussion floating over the incoming track's full body. This is the *handover* filter; T2's low-pass is the *recede* filter. `TransitionTechnique.highpassSweep` already exists as a UI chip for a move the engine cannot make.
*Preconditions:* incoming has a full-bodied entry (a `.drop` or a `.intro` with bass present); tempo locked.
*Parameters:* `cutoffFrom = 30 Hz` → `cutoffTo ∈ 300…800 Hz` over 4–8 bars, `resonance ≤ 0.2`. Pairs with, and partly replaces, the bass swap: high-passing the outgoing *is* a bass kill with a smoother handover.
*Capabilities:* `+ highPassFilter`.
*Gap:* **S.** `AVAudioUnitEQFilterType.resonantHighPass` is verified present in the tvOS 27 SDK. Change `AVAudioUnitEQ(numberOfBands: 1)` → `2`, add `bands[1].filterType = .resonantHighPass` starting bypassed at 30 Hz, add a `RampKey.filterHighPassCutoff(Deck)` case and a `setHighPassCutoff` mirroring `setFilterCutoff`. **No new node, no graph change, no reconnection.** Perhaps 40 lines.

---

**T5 · `echoOut`** - the standard clean ending in house and techno.
*Sound:* on the last beat of a phrase, a beat-synced delay is thrown on the outgoing deck; its source is killed; the tail rings through the next downbeat while the incoming track starts underneath.
*Preconditions:* an identified phrase boundary in the outgoing track. **Notably: no tempo match required** - once the echo is thrown the outgoing track is gone. This makes T5 the correct template for large `Δbpm`, and it is what the current `computeTransition` already *claims* to do in its `.echoOut` branches.
*Parameters:* `division ∈ {1/4, 1/2, 3/4 dotted, 1}` beat (default **1/2**), `feedback ∈ 50…60%`, `wetDryMix ∈ 30…40%`, `lowPassCutoff` on the repeats - better, **high-pass the tail** so it does not muddy the incoming bass, which is exactly what Pioneer's FX Frequency buttons and Serato's Delay HPF do. Tail 2–4 bars.
*Capabilities:* `+ delayPerDeck`.
*Gap:* **M.** Add `AVAudioUnitDelay` per deck. **Placement is load-bearing:** the delay must sit *after* the point where the source is killed but *before* the crossfader, otherwise pulling the fader kills the tail too. Correct chain: `player → timePitch → eq → filter → delay → mixer`, and the "kill" is `player.pause()` or an EQ/gain collapse - **not** a `mixer.outputVolume` move. Verified params: `delayTime 0…2 s`, `feedback −100…100`, `wetDryMix 0…100`. New `RampKey` cases for `.delayWet(Deck)` and `.delayFeedback(Deck)`. One subtlety: `delayTime` must be recomputed when `timePitch.rate ≠ 1`, since the beat division is in *source* beats but the delay is in *wall-clock* seconds - `delayTime = beatPeriod × division / rate`.

---

**T6 · `loopRollOut`** - the user's explicit ask, and where our existing `setLoop` half-helps.
*Sound:* the outgoing track's last 8 bars are looped; the loop halves 8 → 4 → 2 → 1 bar (and in Junkie, on to ½ and ¼ beat) as a build, then hands over.
*Preconditions:* an accurate bar grid; a rhythmically self-sufficient region (a loop across a chord change collapses); ≥8 bars of outgoing material after the exit point.
*Parameters:* `startBars ∈ {4, 8, 16}` (Junkie: up to **32**, the owner's "20 bar loop" rounds to 16 or 32), `halvings ∈ 0…4`, `halveOnBar`. Wedding caps at 8 bars and 1 halving; Junkie allows 32 bars and 4.
*Capabilities:* `+ loopResize, sampleAccurateCue`.
*Gap:* **M, and the gap is subtler than it looks.** `setLoop` exists and its `.loops` buffer approach is right - the wrap happens on the render thread with no Swift in the path. But **halving requires re-arming**, and `setLoop` does `player.stop()` + `scheduleBuffer`, which its own comments concede is the audible-gap path. A halving on a bar line must be *sample-accurate*, so the new `resizeLoop(on:toLengthSeconds:atHostTime:)` has to pre-build the halved buffer and schedule it at a computed `AVAudioTime` rather than stopping first. Also: the code's `setLoop` is a **loop**, not a **roll** - the playhead freezes. That is correct for a loop-out (we never return to the timeline) but wrong if we ever want a momentary roll; note the distinction (§1.10) and do not conflate them in the API.

---

**T7 · `doubleDrop`** - Junkie only.
*Sound:* two drops land on the same downbeat.
*Preconditions, all hard:* both tracks have a `.drop` section with `measuredStructure` provenance; `|Δbpm|` after rate correction ≤ 0.5% (this template has the tightest tolerance of any, because a mistimed double drop is a trainwreck); key compatible at ≤1 Camelot step; **complementary bass** - reject if both tracks' `instrumentActivity[.bass]` is dense in the same octave at the drop; no vocal overlap at all. Vande Veire forbids a double drop immediately after another double drop or a rolling transition; we adopt the same cooldown.
*Parameters:* `leadInBars = 16`, `outBars = 32` (Ghent's values), `bassPolicy ∈ {killOutgoing, alternateEveryNBars}`.
*Capabilities:* `+ sampleAccurateCue, masterLimiter`.
*Gap:* **M–L.** Needs drop detection (MU `sections` + `loudness`), sample-accurate phase lock, and it is the template most likely to clip - two drops summing correlated is the +6 dB case exactly.

---

**T8 · `cutOnTheOne`** - the honest fallback, done properly.
*Sound:* a hard cut on a downbeat, ~50 ms equal-power fade to avoid a click.
*Preconditions:* none. This is what the engine does when nothing scores above threshold, and it should *sound deliberate* rather than like a failure.
*Parameters:* `fadeMs ∈ 20…80`.
*Capabilities:* `crossfade` (+`sampleAccurateCue` to land it on the beat rather than "whenever the 33 ms poll noticed").
*Gap:* **executable today in degraded form**; sounds materially better with `sampleAccurateCue`.

---

**T9 · `tempoRampBlend`** - the user's "move around bpm slowly".
*Sound:* over 16–32 bars the two decks converge on a shared tempo rather than one snapping to the other.
*Preconditions:* both tempos `measuredTempo`; combined required change within profile limits; **the phase pre-compensation of §8.4 applied** - without it this template is actively worse than a snap.
*Parameters:* `rampBars ∈ {8,16,32}`, `split ∈ 0…1` (0 = incoming does all the moving; **0.5 = both move half**, which is Ishizaki's approach and halves the perceived discomfort on each deck).
*Capabilities:* `timeStretch, entryCue, sampleAccurateCue`. *Gap:* **S–M** - the ramp exists (`setRate(_:over:)`); the phase maths does not.

---

**T10 · `halfTimeBlend`** - free, and half the owner's library needs it.
*Sound:* a 174 BPM track and an 87 BPM track playing together, every other D&B kick coinciding with a hip-hop kick. **No stretch, no shift, exact grid alignment.**
*Preconditions:* `tempoRelation` resolves to a 2:1 or 1:2 factor within 1%; both grids measured. Genre gate: the incoming section must have a sparse enough kick pattern that the doubled grid does not become a wall.
*Parameters:* as T1, plus `factor ∈ {0.5, 2.0}`.
*Capabilities:* same as T1. *Gap:* **none beyond T1** - the whole trick is in the *scoring* (§5.2), not the DSP. **This is the highest ratio of musical payoff to engineering cost in the catalog**, given the owner's bimodal 80/125 BPM library.

---

**T11 · `backspin` / rewind.** *Out of scope, documented so it is not re-proposed.* `AVAudioPlayerNode` cannot play backwards; it would need a reversed PCM buffer per deck (~50 MB for a 6-minute track at canonical format) or a reversed decode pass. Also culturally specific - rewinds appear where an MC is present (jungle, garage, grime, dancehall) and "techno, trance, and deep house rarely use rewinds because their structurally continuous, mix-focused sets conflict with the disruption." **L**, low value for this app.

### 3.3 Summary

| ID | Template | Wedding | Junkie | Ships in | New DSP |
|---|---|---|---|---|---|
| T1 | `bassSwapBlend` | ✅ | ✅ | **v1** | entryCue (1 line) + snappedBassSwap (S) |
| T2 | `filterFadeOut` | ✅ | ✅ | **v1** | none |
| T3 | `filterBloomIn` | ✅ | ✅ | **v1** | none |
| T8 | `cutOnTheOne` | ✅ | ✅ | **v1** | none (better with sample-accurate cue) |
| T10 | `halfTimeBlend` | ✅ | ✅ | **v1** | none (scoring only) |
| T4 | `highPassThinOut` | ✅ | ✅ | v2 | high-pass band (S) |
| T5 | `echoOut` | ✅ | ✅ | v2 | `AVAudioUnitDelay` per deck (M) |
| T9 | `tempoRampBlend` | ✗ | ✅ | v2 | phase pre-compensation (S–M) |
| T6 | `loopRollOut` | limited (≤8 bars, 1 halving) | ✅ (≤32 bars, 4 halvings) | v3 | sample-accurate loop resize (M) |
| T7 | `doubleDrop` | ✗ | ✅ | v3 | drop detection + phase lock + limiter (M–L) |
| T11 | `backspin` | ✗ | ✗ | - | reverse playback (L) |

---

## 4. Features, and how to afford them

### 4.1 Three tiers, and what dies at each one

The planner never sees "a track". It sees `TrackFeatures` with a `provenance` set. Everything degrades by dropping capability, never by substituting a guess. That rule already exists in this codebase and it is the right one: `DJTransitionService.synthesizeAnalysis` hashes a fake BPM out of a track id purely so the console has stable numbers to render, and `isEstimated` exists so nothing can present it as measurement.

| Tier | Source | Cost | What we get | What we lose |
|---|---|---|---|---|
| **0 · Metadata** | SoundCloud JSON + `WaveformService` envelope | ~0, already fetched | duration, genre string, envelope, Phantom's exit shape | everything rhythmic and harmonic |
| **1 · Tail analysis** | partial materialise (first 90 s + last 90 s) then MU or `AudioAnalyzer` | ~40% of a full download, one decode | tempo, key at the tail, outro loudness, exit points | phrase grid across the whole track, structure labels |
| **2 · Full analysis** | the deck's own local `.caf`, MU `analyze()` | free for anything on a deck | beats, bars, phrases, sections, per-region key, per-instrument activity, integrated loudness | nothing |

Tier 2 is free for the two tracks on the decks, which is the important bit. `SourceImporter` has already produced a local canonical `.caf` for both, and that is an ordinary `AVURLAsset`. Whatever the HLS spike comes back with, **the transition currently being played can always be planned at full fidelity**. The spike only prices Tier 1.

### 4.2 What each template falls back to

| If missing | Effect |
|---|---|
| `measuredBeatGrid` | no phase lock, no bar-snapped bass swap, no loops. T1 degrades to a plain equal-power blend with a time-based swap. T6, T7, T9, T10 are struck from the admissible set entirely. |
| `measuredDownbeats` (grid present, parity unknown) | phase lock allowed only mod 1 beat, never mod 4. `phraseFit` returns `confidence 0.3`. T7 struck. |
| `measuredKey` | `harmonicFit` returns cost 0.5 with confidence 0.0, so it contributes nothing rather than penalising. Never a veto. |
| `measuredStructure` | exit points fall back to Phantom's envelope walk, which is what ships today. Entry points fall back to `intro = AudioAnalyzer.computeIntro`. |
| `measuredVocals` | `vocalClash` returns confidence 0.0. Given Vande Veire's detector runs at F1 0.62 and discards 16.5% of clean crossfades, an absent detector is not much worse than a mediocre one. |
| `measuredLoudness` | gain staging falls back to the envelope peak. Master headroom policy (§5.7) applies regardless, because it must. |
| Everything (Tier 0 only) | Phantom's current behaviour exactly: envelope walk, shape classification, filter accent, honest reasoning string. **This is the floor, and it already ships.** |

### 4.3 Exit and entry points

Phantom currently returns one exit point. It needs to return a ranked list, and it needs a mirror on the incoming side. That is the whole shape of the extension.

```swift
struct ExitPoint: Equatable, Sendable {
    let seconds: TimeInterval
    let kind: SectionKind            // what we are leaving
    let barsRemaining: Int?          // runway after this point
    let onPhraseBoundary: Bool
    let confidence: Double
}

struct EntryPoint: Equatable, Sendable {
    let seconds: TimeInterval
    let kind: SectionKind            // what we are landing in
    let barsUntilNextSection: Int?   // how long before the drop arrives
    let onPhraseBoundary: Bool
    let hasBassFromHere: Bool        // decides whether a bass swap has anywhere to go
    let confidence: Double
}
```

Generation rules, straight out of the literature:

- **Exit candidates** come from Zehren's four rules. On a strong beat (Rule 1), on the downbeat starting a 4-bar period (Rule 2), at a novelty peak (Rule 3), and Spotify's pruning: the fade-out end must sit **in the last 25%** of the track. Take the top 8. Zehren's own system produces a mean of **8.9 candidates per track** and 95.8% of them are usable, so 8 is not an arbitrary cap.
- **Entry candidates** are Spotify's mirror: the fade-in start must sit **in the first 20%**, plus Zehren's Salience rule ("switch points are located in the initial portion of a track that precedes the first point of salience"). Take the top 6.
- Zehren's own caveat is worth encoding as a parameter rather than ignoring: "a DJ wants to switch **4 or 8 bars before** the next track exhibits any element of novelty. We agree." So `EntryPoint.barsUntilNextSection` is a first-class field and templates use it to hold back.
- Junkie gets one extra rule Wedding does not: **any phrase boundary is an exit candidate**, including mid-track. That single line is most of what makes Junkie feel like a different DJ.

### 4.4 The search, and why it is cheap

```
plan(outgoing, pool, profile):
    O       = features(outgoing)                    // Tier 2, free
    exits   = exitCandidates(O, profile)            // <= 8
    cands   = prefilter(pool, profile)              // <= 24, metadata only
    best    = nil
    for c in cands, ordered by cheapScore(c):       // cheap = Tier 0 arithmetic
        I       = features(c)                       // cached, or Tier 0
        entries = entryCandidates(I, profile)       // <= 6
        for t in registry.admissible(profile, capabilities):
            guard case .admitted = t.admits(O, I, profile) else { continue }
            for plan in t.propose(O, I, exits, entries, profile, &rng):
                let s = score(O, I, plan, profile, history)
                if s > best { best = (s, plan) }
    return best where best.score >= profile.minimumScoreToFire
```

Worst case with Junkie's numbers: 24 candidates x 6 templates x roughly 12 surviving point pairs is about 1,700 scorings. Each scoring is 10 pure arithmetic terms over pre-computed arrays. Call it 30 microseconds each and the whole search is **under 60 ms on the main actor**, which is two frames on tvOS. Run it on a background task anyway and it disappears.

**All the cost is in feature extraction, none of it is in the search.** That is the thing to get right.

### 4.5 Making feature extraction affordable

Five levers, in order of how much they buy:

1. **Cache by track id, on disk, forever.** `DJTransitionService` already has exactly this (`CachePayload`, JSON at `cacheURL`, with a hand-written `init(from:)` that defaults old entries to `isEstimated: true`). Widen the payload to `TrackFeatures` and the plumbing is done. Serato and rekordbox both treat analysis as permanent per track. So should we.
2. **Cheap prefilter before anything expensive.** Duration outside 90 s to 15 min, titles matching `/\b(mix|set|podcast|live at|dj set)\b/`, or a genre distance already over the profile's ceiling, all get cut on metadata alone. On the owner's library that immediately removes the 13 zero-BPM tracks and anything hour-long.
3. **Budget the expensive work.** At most **3 new Tier-1 analyses per track played**, background priority, ordered by the cheap prefilter score. The pool warms up over a session: the first two or three transitions run on Tier 0, and by track six there is a real candidate set. That is an honest, shippable property, and the reasoning string can say so.
4. **Partial materialise for Tier 1.** `SourceImporter.assembleHLS` already parses the playlist and enumerates segments. Fetching the first N and last M rather than all of them costs roughly 40% of the bytes for a 6 minute track at 6 to 10 second segments, and the tail is exactly the part an exit point needs. Caveat: MU's `structure` on a discontiguous asset would be nonsense, so Tier 1 must request only `.rhythm`, `.key`, `.loudness` and mark `measuredStructure` absent.
5. **Fuse analysis into the import.** `SourceImporter.transcode` already decodes to PCM. `MusicUnderstandingSession(audioProvider:)` takes an `AsyncSequence<AVReadOnlyAudioPCMBuffer>`. Feeding MU from that pass rather than re-opening the finished `.caf` saves a whole decode per track. Worth doing once the shape is settled, not before.

Hard budget: analysis must never compete with the deck cache. `SourceImporter` is capped at 400 MB and 6 files. Tier 1 gets its own directory with its own cap (**150 MB, 20 files**), and its scratch files are deleted the moment features are extracted, because the features are 2 KB of JSON and the audio is 60 MB.

### 4.6 The commitment problem, which is the real constraint

There are two decks. `MixEngine.load` downloads and decodes an entire track before the deck is playable, and `PlayerService`'s own comment puts that at "tens of seconds". So the engine cannot audition candidates. It gets exactly one guess.

The scheduling that falls out of that:

- **Commit** to a winning `(track, template, exit, entry)` at `max(plannedMixPoint - 90 s, endOfPreviousTransition)`.
- **Re-rank without re-committing.** If a better candidate appears after commit (a Tier-1 analysis lands), log it and use it next time. Swapping the loaded deck would cost another full download and is exactly the kind of thing that turns into a hard cut at the mix point.
- **Upgrade the template freely.** The track is fixed at commit; the transition is not. If the incoming track's full analysis lands while it sits on the deck (which it will, since it is now a local `.caf`), re-run `propose` and `score` against the *same* pair. A plan that committed as T1 at Tier 0 can be promoted to T6 with a real bar grid before it fires. This is the cheapest quality win in the design.
- **Never fake it.** If the deck is not `.ready` at the mix point, fall through to `cutOnTheOne` with a real reason string. `updatePhantomTick` already does exactly this, and the `.cutting(reason:)` case already exists.

### 4.7 Retrieval: two stages, and no vector index

The owner asked whether the analysis cache should become a vector DB so the library can be queried for "music that mixes well". Short answer: **no, and the reason is that mixability is not a distance.**

Use the standard recall/rank split.

**Stage 1, recall. Thousands down to tens.** Indexed scalar predicates in SQLite, which the cache already is. Exact, fast, explainable, no embeddings and no new dependency.

**Stage 2, rank. Tens down to one.** The registry scoring function from §5, producing the plan and the reasoning string.

#### Why not ANN as the retrieval mechanism

Five reasons, and the first is the one that actually kills it.

**Mixability is directional and structural, not symmetric.** What we are asking is "does A's *outro* work against B's *intro*, given a transition template". Nearest-neighbour in a shared embedding space computes `d(A, B) = d(B, A)` over whole-track summaries. It cannot express that A mixes beautifully into B and terribly the other way round, which is the normal case: A has a 32-bar breakdown to exit through and B has a clean 16-bar intro to land in. Reverse them and there is nowhere to go. The thing we care about is a property of the *pair plus the template plus two time points*, and an embedding of a track has thrown all of that away before the query runs.

**Hard constraints are predicates, not distances.** "Has at least 16 bars of usable outro" is true or false. Embed it and it becomes a nudge, which means the index will confidently return tracks that physically cannot support the transition, and stage 2 then has to reject them anyway. All the cost, none of the recall.

**BPM breaks naively, and on this library it breaks half the time.** 174 and 87 are the same tempo. In any plain vector they are maximally far apart. The owner's Serato database is bimodal: 42 tracks in the 125 to 129 band and 82 in the 70 to 100 mass. An index that cannot see the 2:1 relation gets the single most valuable pairing in the collection exactly backwards.

**It destroys the differentiator.** tvOS 27 already ships AutoMix as a black box. "These vectors were close" is not a reason string. `PlanRationale` is the whole point and an ANN recall stage would put an unexplainable step in front of it.

**No dependencies allowed, and there is no turnkey on-device ANN.** A real vector index means hand-rolling HNSW or IVF, at personal-library scale (321 files, 215 analysed) where a SQLite index with a compound key wins on latency anyway. It would be a lot of code to be slower and less correct.

#### What stage 1 needs indexed

Treating the cache as given (SQLite, keyed by track id plus engine identity plus schema version plus audio fingerprint, LRU byte budget), the recall query needs these columns materialised and indexed. Everything here is derived once at analysis time and never recomputed.

| Column | Type | Index | Notes |
|---|---|---|---|
| `track_id` | TEXT | PK | existing |
| `bpm` | REAL | ✅ | the display value. Never used for rate maths |
| `bpm_octave_norm` | REAL | ✅ | **the important one.** BPM folded into a canonical octave: `while v < 88 { v *= 2 }; while v >= 176 { v /= 2 }`. 174 and 87 both land on 174.0. One indexed range scan then covers the 1:1 and 2:1 bands together |
| `beat_period_us` | INTEGER | | microseconds per beat, the real tempo primitive (§2.3) |
| `grid_confidence` | REAL | ✅ | recall filters on `>= profile.minGridConfidence` |
| `camelot` | INTEGER | ✅ | 1…24, encoded `number * 2 + (isMinor ? 0 : 1)`. Compatible set is a small precomputed `IN (...)` list, not a distance |
| `key_confidence` | REAL | | |
| `genre_id` | INTEGER | ✅ | canonical id from the genre subsystem |
| `genre_family_id` | INTEGER | ✅ | coarser bucket, so the recall predicate is a family match rather than a distance |
| `genre_confidence` | REAL | | |
| `energy_level` | INTEGER | ✅ | 1…10, the MIK-style scale. Recall window is `energy ± profile.energyStepLimit` |
| `duration_s` | REAL | ✅ | prefilter cut for 90 s to 15 min |
| `outro_bars` | INTEGER | ✅ | **the structural predicate.** Usable bars after the best exit point. `>= template.minOutroBars` is the cheapest true/false in the whole system |
| `intro_bars` | INTEGER | ✅ | mirror, for the entry side |
| `has_vocal_intro` | INTEGER | ✅ | 0/1. Cuts the worst clash case before scoring |
| `provenance` | INTEGER | ✅ | the `FeatureProvenance` bitfield. Recall can demand `measuredBeatGrid` |
| `features_blob` | BLOB | | the full `TrackFeatures` JSON, fetched only for the shortlist |

The recall query, in one statement:

```sql
SELECT track_id, features_blob FROM track_features
WHERE  duration_s BETWEEN 90 AND 900
  AND  grid_confidence >= :minGrid
  AND  provenance & :requiredProvenance = :requiredProvenance
  AND  bpm_octave_norm BETWEEN :bpmLo AND :bpmHi     -- covers 1:1 and 2:1 in one range
  AND  camelot IN (:c0, :c1, :c2, :c3, :c4)          -- precomputed compatible set
  AND  genre_family_id IN (:g0, :g1, :g2)
  AND  energy_level BETWEEN :eLo AND :eHi
  AND  outro_bars >= :minOutro
  AND  intro_bars >= :minIntro
  AND  track_id NOT IN (:recentlyPlayed)
ORDER BY abs(bpm_octave_norm - :targetBpm) ASC
LIMIT  :lookaheadCandidates;                          -- Wedding 1, Junkie 24
```

One index scan, one sort, no joins. On a 10,000 track library that is well under a millisecond. On 215 it is noise.

`bpm_octave_norm` is the piece worth being deliberate about. Folding tempo into a canonical octave at write time means the 174-against-87 pairing falls out of an ordinary `BETWEEN` rather than needing three range queries unioned together, and it means the index is doing the work rather than the scorer. The 3:2 and 4:3 relations from §5.2's table are *not* covered by the fold and are rarer, so they get a second, cheaper query issued only when the first returns fewer than 8 rows.

Two loosening rules, so recall never returns nothing:

1. If fewer than 4 rows come back, drop the `camelot` and `genre_family_id` predicates and re-run. Both are soft in the scorer anyway, so gating recall on them is the wrong place to be strict.
2. If still fewer than 4, drop to `duration_s` and `provenance` only, and let stage 2 sort it out. A shortlist of bad options that the scorer rejects with a reason string is better than an empty result and a silent hard cut.

#### Where an embedding does earn a place

Timbre. "Sounds like" is the one thing BPM, key and genre genuinely cannot capture, and it is measurably the thing that matters most: Kell & Tzanetakis analysed 114 BBC Essential Mix sets and found **timbre is the dominant factor** in what DJs actually put next to each other, while key showed no statistically significant effect at all. Vande Veire's user study is the corroboration: style-aware selection beat style-agnostic **17 out of 18, p = 7.25e-5**, and his "style" descriptor is spectral contrast over the high-energy segments reduced to three dimensions by PCA.

So build a small timbre vector, and use it as **one scoring term in stage 2**, never as retrieval.

```swift
/// 16 floats. Small enough to sit in the cache row, large enough to separate
/// "rolling tech house" from "hard groove" when both are 128 BPM in A minor.
struct TimbreProfile: Equatable, Sendable, Codable {
    let v: [Float]   // count == 16, L2-normalised

    // Construction, from MU's InstrumentActivityResult over the *transition
    // region only*, not the whole track. A track's intro and its drop have
    // different timbre and we only care about the part that will be audible.
    //   [0..3]   mean activity of .drum, .bass, .vocal, .other
    //   [4..7]   standard deviation of each, over 1-second frames
    //   [8..11]  first-difference mean of each (how much it moves)
    //   [12]     bass-to-drum ratio
    //   [13]     vocal presence fraction (bars with vocal / total bars)
    //   [14]     LoudnessResult short-term crest factor (peak minus shortTerm)
    //   [15]     pace, from PaceResult, normalised
}

func timbreTerm(_ ctx: ScoringContext) -> TermResult {
    guard let a = ctx.outgoing.timbreAtExit, let b = ctx.incoming.timbreAtEntry else {
        return TermResult(cost: 0.4, confidence: 0, veto: false, explanation: nil)
    }
    // Cosine distance, but the target is NOT zero. Identical timbre is boring
    // and, worse, maximally masking. Vande Veire's negative beta encodes the
    // same intuition: the next track should move in the direction the set is
    // already moving, not sit on top of the current one.
    let d = 1 - cosine(a.v, b.v)                    // 0 = identical, 1 = orthogonal
    let target = ctx.profile.timbreTargetDistance   // Wedding 0.18, Junkie 0.32
    let cost = min(1, abs(d - target) / 0.35)
    ...
}
```

Note what that is and is not. It is 16 floats per track, computed at analysis time, stored inline in the cache row, compared with a dot product. It is **not** an index, not an ANN, not a dependency, and it never decides which tracks are considered. Weight 0.35 under Wedding and 0.50 under Junkie, sitting alongside `genre` rather than replacing it, because genre carries the phrase-grammar and template-affinity information (§5.4) that a timbre vector has no way to express.

**Is it worth it yet? Not in v1.** It needs `InstrumentActivityResult`, which is Tier 2, which is v3. Until then `genre` plus `energy` covers most of what it would buy. Ship it with the rest of the MU work, and only after E4 confirms MU returns sensible instrument activity on bootleg and refix material rather than on clean commercial masters.

#### And the query the owner actually asked for

"Show me music that mixes well with this" is stage 1 plus stage 2 with `lookaheadCandidates` raised and the result rendered as a list instead of consumed by the transport. Same code path, different presentation, and every row comes with its reason string already written. That is a genuinely nice feature and it falls out for free, which is a decent sign the architecture is the right shape.


---

## 5. The scoring model

### 5.1 The shape

```
score = 1 - Σᵢ (wᵢ · cᵢ · κᵢ) / Σᵢ (wᵢ · κᵢ)
```

where `cᵢ` is term *i*'s cost in 0…1, `wᵢ` is the profile's weight, and `κᵢ` is the term's own confidence in 0…1. Two properties worth spelling out, because both are load-bearing:

**Confidence attenuates the weight, never the cost.** A term that does not know anything returns `κ = 0` and drops out of both numerator and denominator. It does not quietly score 0.5 and drag everything toward the middle. This is the difference between "we could not measure the key" and "the key is mediocre", and conflating them is how a scorer ends up preferring tracks it knows nothing about.

**A veto is physical impossibility, never taste.** `veto` is for "this template needs 16 bars of runway and there are 4". It is not for "the genres are far apart". More on that in §5.6.

### 5.2 Tempo, done properly

Absolute BPM difference is wrong on the owner's library roughly half the time. The 80 BPM cluster (82 tracks) and the 125 cluster (42 tracks) both exist, and a naive `|Δbpm|` between an 87 and a 174 says 87 when the answer is 0.

```swift
/// Every metrical relation worth considering, with the base cost of using it.
/// 1:1 is free. 2:1 is nearly free (the grids coincide exactly, no stretch).
/// 3:2 and 4:3 are real moves that cost something.
static let tempoRelations: [(factor: Double, baseCost: Double, label: String)] = [
    (1.0,     0.00, "same tempo"),
    (2.0,     0.06, "double time"),
    (0.5,     0.06, "half time"),
    (1.5,     0.30, "3:2"),
    (2.0/3.0, 0.30, "2:3"),
    (4.0/3.0, 0.42, "4:3"),
    (0.75,    0.42, "3:4"),
]

func tempoTerm(_ ctx: ScoringContext) -> TermResult {
    guard let a = ctx.outgoing.beatGrid, let b = ctx.incoming.beatGrid else {
        return TermResult(cost: 0.5, confidence: 0, veto: false, explanation: nil)
    }
    // Best relation = smallest residual after the factor is applied.
    let best = Self.tempoRelations
        .map { r -> (r: (factor: Double, baseCost: Double, label: String), residual: Double) in
            (r, abs(a.bpm - b.bpm * r.factor) / a.bpm)          // relative, never absolute
        }
        .min { $0.residual < $1.residual }!

    let p = ctx.profile
    // Residual we are allowed to correct with the time-stretch unit.
    let correctable = min(best.residual, p.maxAbsRatePercent / 100)
    let leftover    = best.residual - correctable

    // Leftover drift is what actually flams. §1.3: drift_ms = 1000·Δf/f·T.
    let overlapSeconds = ctx.plan.overlapSeconds
    let driftMs = leftover * 1000 * overlapSeconds
    if driftMs > p.maxDriftMs {
        return TermResult(cost: 1, confidence: 1, veto: false,
                          explanation: "would drift \(Int(driftMs)) ms over the blend")
    }

    // Stretch cost rises steeply past 5%, per Kim et al. (86.1% of real
    // adjustments are under 5%) and Ishizaki (discomfort peaks at ±10%).
    let stretchCost = pow(correctable / 0.10, 1.8)
    let cost = min(1, best.r.baseCost + stretchCost + driftMs / p.maxDriftMs * 0.25)
    ...
}
```

Three things to notice.

The residual is **relative, not absolute**. §1.3 showed 0.1 BPM drifts 94.7 ms over 32 bars at 90 BPM and only 25.4 ms at 174. A cost function in absolute BPM systematically over-trusts slow music.

The stretch cost uses **exponent 1.8**, which puts 5% at cost 0.30 and 10% at cost 1.0. That is fitted to the two independent numbers we have: 86.1% of real DJ transitions adjust under 5%, and listener discomfort in a 96-person study peaks at exactly ±10%. Not invented.

**2:1 is nearly free and this matters.** A 174 D&B track and an 87 hip-hop track share a downbeat grid exactly, no stretch, no shift, no artefacts. Given the shape of the owner's library this is the single highest-value line in the scoring model, and it costs nothing to implement because the DSP is identical to a normal blend.

### 5.3 The full term set

Costs are 0…1, 0 = perfect. Weights are per-profile; §6 gives the numbers.

| Term | Cost from | Confidence from | Notes |
|---|---|---|---|
| `tempo` | §5.2 | grid confidence of both tracks | never vetoes on tempo alone; a big gap just makes `echoOut` win instead |
| `phrase` | offset of the exit and entry from their nearest phrase boundary, in beats, folded **mod 4 and mod 32** | `measuredDownbeats` present, and downbeat parity known | §1.5: a 1-beat error inverts the backbeat with zero flam, so the mod-4 residual is weighted **3x** the mod-32 one |
| `structure` | lookup on `(exit.kind, entry.kind)` | `measuredStructure` | `.outro → .intro` = 0.0; `.drop → .drop` = 0.0 for T7, 0.9 for anything else; `.drop → .ambientIntro` = 0.8 (energy dumped on the floor) |
| `harmonic` | Camelot distance at the **exit region's** key vs the **entry region's** key | `measuredKey`, further scaled by **0.45** (see below) | MIK's rules: 0 steps = 0.0, ±1 same letter = 0.12, letter switch same number = 0.15, +2 energy boost = 0.25, +7 or −5 = 0.30, +4 = 0.45, anything else = 0.85 |
| `energy` | signed step on a 1–10 scale derived from `LoudnessResult.integrated` plus the envelope, against the profile's target arc | `measuredLoudness` | MIK's one-step rule: ±1 step = 0.0, ±2 = 0.45, ±3 or more = 0.9. Armin's Ultra 2017 trace never moves more than 1 |
| `spectralClash` | vocal overlap in bars, plus bass-density overlap at the swap | `measuredVocals` | ≥2 overlapping vocal bars = cost 0.9; exactly 1 bar is tolerated at 0.2 (Vande Veire's own threshold) |
| `genre` | `genreDistance(a, b)`, attenuated (§5.5) | `min(confA, confB)` | cost, never veto |
| `groove` | `\|swingA − swingB\| × eighthNoteMs / 10 ms` | `swingRatio` measured on both | usually confidence 0 in v1 and v2. Honest, and it drops out cleanly |
| `novelty` | repeat of the same template within the profile's cooldown; same artist within the last N tracks | 1.0 always (it is bookkeeping, not measurement) | stops the engine echo-ing out of three tracks in a row |
| `feasibility` | template's own risk: runway shortfall, deck-readiness margin, missing capability | 1.0 always | the only term allowed to veto |

**Why harmonic gets scaled by 0.45.** This is the one place I am arguing against DJ folklore, and the evidence is one-sided:

- Kell & Tzanetakis measured 114 BBC Essential Mix sets and found **no statistically significant key effect at all**. Their words: "DJs do not use key as a primary concern when selecting and ordering their tracks."
- Spotify's professional curators attributed **0%** of bad transitions to key clash. Beat misalignment got 15.22%.
- Best MIREX 2020 key detection on EDM scored **40%**, under a scheme that already gives partial credit for fifth and relative errors. On the owner's library that means we would be wrong more often than right.
- Three commercial tools agree with each other only about **39%** of the time.
- Real DJs transpose on **2.5%** of plays.

So harmonic mixing stays in, because when it is right it is genuinely lovely, but it is a tiebreak rather than a gate. Vande Veire used a key *filter* as stage one of five and his own users complained about bad harmonic mixing. Not repeating that.

### 5.4 Where genre goes, and why it is a cost

Weight sits between tempo and structure: high enough to keep a set coherent, low enough that one bad label cannot wreck a good pairing.

**Cost, not veto.** Three reasons. The owner's own library says genre labels are `"Trance, Progressive House"`, `"Rap / Hip-Hop"`, `"Rock / Indie"` and `"Other"`, with 29 of 215 tracks carrying no genre at all, so a veto would silently refuse to play a lot of perfectly good music on the strength of a string somebody typed into a web form. A silent refusal is also the worst possible failure mode: the user hears a hard cut and has no idea a genre label caused it, whereas a *cost* still shows up in the reasoning string. And genre is the term most likely to be wrong, so it is the term least entitled to a veto.

The one exception is a profile-level ceiling, which is a policy, not a term: if `genreDistance > profile.genreCeiling` the pair is dropped in the **prefilter**, before scoring, and the reasoning string says which. Wedding sets that at 0.55; Junkie at 0.85. That is a deliberate, explainable refusal rather than a silent one.

**Confidence attenuation.** Same mechanism as every other term, and it matters more here because the genre subsystem is normalising free text:

```swift
func genreTerm(_ ctx: ScoringContext) -> TermResult {
    guard let a = ctx.outgoing.genre, let b = ctx.incoming.genre else {
        return TermResult(cost: 0.4, confidence: 0, veto: false,
                          explanation: nil)                      // drops out entirely
    }
    let d = genreDistance(a.genre, b.genre)
    // Joint confidence, squared so two mediocre labels are worth much less
    // than one good one. Two 0.6s give 0.36, not 0.6.
    let kappa = (a.confidence * b.confidence)
    return TermResult(
        cost: d,
        confidence: kappa,
        veto: false,
        explanation: kappa > 0.4
            ? "\(a.genre.displayName) → \(b.genre.displayName)"
            : "\(a.genre.displayName) → \(b.genre.displayName) (low confidence)"
    )
}
```

Squaring the joint confidence is deliberate. A track tagged `"Other"` at confidence 0.3 mixed with one tagged `"Techno"` at 0.9 gives `κ = 0.27`, so genre contributes about a quarter of its nominal weight. That is the right amount of opinion to have about a label nobody stands behind.

**Genre changes what tempo cost means.** This is the interesting interaction and it needs a real mechanism, not a hand-wave. `Genre` carries a nominal tempo range, and the tempo term normalises the residual against **the width of the pair's shared tempo band** rather than a global constant:

```swift
// Tech house sits roughly 122-128 (6 BPM wide). Techno 130-145 (15 wide).
// A 6 BPM gap inside tech house is the whole genre; the same gap inside
// techno is nothing. Normalising against the band width gets this right
// without a special case.
let band = max(4.0, min(a.genre.tempoSpan, b.genre.tempoSpan))
let tempoCost = baseCost * (6.0 / band)
```

And when the pair crosses genres *upward* (tech house at 126 into techno at 132), the direction agrees with the set's energy arc, so `energy` already rewards it. No extra term needed. Two mechanisms already in the model produce the behaviour the brief asked for, which is a good sign the model is the right shape.

**Genre gates templates too, not just tracks.** This is the piece that stops the engine applying house grammar to trance:

```swift
extension Genre {
    /// Phrase unit in bars. Trance and big-room are strict 32; tech house
    /// and minimal are comfortable at 8 or 16; hip-hop is 4.
    var phraseBars: Int { ... }
    /// Templates this genre's grammar actually supports.
    var templateAffinity: [TransitionTemplateID: Double] { ... }
}
```

Concretely: **trance** has 64 to 96 bar breakdowns and 32 to 64 bar intros (myloops' blueprint), so `filterBloomIn` and long `bassSwapBlend` at 32 bars score well and `cutOnTheOne` scores badly. **Tech house** rolls with minimal breakdowns, so 16-bar `bassSwapBlend` and `highPassThinOut` win and a 32-bar filter build has nothing to build into. **Hard groove** is relentless and percussive: `loopRollOut` and short blends. **Drum and bass** is where `doubleDrop` lives, per every source we could verify, and where `halfTimeBlend` pays off against the 87 BPM half of the library. **Euro dance** has vocal hooks over almost the whole track, so `spectralClash` will dominate and the engine should favour `echoOut` and `filterFadeOut` between the hooks.

The affinity multiplies the template's proposed plans' scores by 0.7 to 1.15. It never removes a template (that is `admissibleTemplates`' job); it just tilts.

### 5.5 The reason string, composed not written

`PlanRationale.reasoning` renders in the order DJ instructors teach for debugging a bad swap: **phrase, then gain, then content**. Terms sort by `weight × cost` and the top three concerns plus the top two contributions get a clause each. Provenance caveats always come last and are never omitted.

```
Bass swap into "Pegassi" at 5:12, 16 bars.
127.4 → 128.0 BPM (+0.5%, key-locked). 8A → 9A, one step round the wheel.
Tech house → tech house. Both on phrase boundaries. No vocal overlap.
Lows swap on the downbeat at 5:42.
Key is estimated, not measured.
```

That last line is not optional. `TrackAnalysis.isEstimated` already exists for exactly this reason and the discipline should survive the rewrite.

### 5.6 Vetoes, in full

Only `feasibility` may veto, and only for these:

1. Runway shortfall: the template needs *n* bars after the exit point and fewer exist.
2. `minimumPlayFraction`: the outgoing track has not played enough of itself (Wedding 0.85, Junkie 0.35; Vande Veire enforces a hard 32-bar floor).
3. Missing capability, which cannot actually happen because the registry filters on it first, but is asserted anyway.
4. Both decks would need to be the same deck (guards against a re-entrant plan during a crossfade).

Everything else is cost. A pair with a 40 BPM gap, clashing keys and opposite genres does not get vetoed; it scores 0.18, loses to `cutOnTheOne` at 0.55, and the reason string explains itself.

### 5.7 Gain staging is not a scoring term, it is a rule

Two decks at the equal-power midpoint sit at 0.707 each. Uncorrelated that sums to 0 dB; **correlated it sums to +3.01 dB**, and two beatmatched 4/4 tracks are deliberately correlated in exactly the band carrying most of the energy. `MixEngine` has nothing between `mainMixerNode` and the hardware. So:

1. **Trim each deck to a common loudness** using `LoudnessResult.integrated`, targeting −6 dBFS nominal per deck via `DeckState.gain`. Falls back to the envelope's 95th-percentile peak when MU is absent.
2. **Pull `masterVolume` to 0.707 for the duration of any overlap**, restoring over 2 s afterwards. Three dB of insurance, free, one ramp.
3. **Move the low shelf to 200 Hz and make the outgoing cut a true kill** (−60 dB is 0.1%, effectively −∞). Low-band exclusivity converts the +6 dB correlated worst case into 0 dB and is worth more than any limiter.
4. **Add a `kAudioUnitSubType_PeakLimiter` on the main bus at −1.0 dBTP** as a backstop, not a plan. Verified present in the tvOS 27 SDK, reachable via `AVAudioUnitEffect(audioComponentDescription:)`.

Rule 3 is the one that actually matters. The other three are belt and braces.

---

## 6. Two DJs, one engine

The coordinator's steer was that Wedding and Junkie should be two policy profiles over one scoring model rather than two engines. Agreed, and not just on tidiness grounds. They differ in *what they are allowed to consider*, not in how they judge it, and every one of the differences is expressible as a number. A profile that needed its own branching logic would be evidence the model was the wrong shape.

`DJProfile` is a value. Adding a third (Warm-up? Closing? Radio?) is a new constant, not a new code path.

```swift
struct DJProfile: Sendable, Equatable, Codable {
    let id: DJProfileID                    // "wedding" | "junkie"
    let displayName: String                // "Wedding DJ" | "Junkie"

    // ── Where a mix may begin in the outgoing track ──
    let exitRegionFloor: Double            // fraction of the track before which no exit is allowed
    let allowMidTrackExit: Bool
    let minimumPlayFraction: Double        // how much of a track must play before it may be left

    // ── Templates ──
    let admissibleTemplates: Set<TransitionTemplateID>
    let repeatTemplateCooldown: Int        // transitions before the same template may repeat

    // ── Tempo ──
    let maxAbsRatePercent: Double          // time-stretch budget
    let allowVarispeed: Bool               // turntable-style rate+pitch (shifts the key)
    let requireMeasuredBPMForRate: Bool
    let maxDriftMs: Double                 // §1.2 budget
    let minGridConfidence: Double          // below this, no phase lock

    // ── Harmony & genre ──
    let maxCamelotSteps: Int
    let allowEnergyBoost: Bool             // MIK's +2 move
    let genreCeiling: Double               // prefilter cut

    // ── Queue ──
    let mayReorderQueue: Bool
    let lookaheadCandidates: Int
    let analysisBudgetPerTrack: Int

    // ── Loops ──
    let maxLoopBars: Int
    let maxLoopHalvings: Int

    // ── Risk & shape ──
    let weights: [ScoringTermID: Double]
    let minimumScoreToFire: Double
    let transitionBarsRange: ClosedRange<Int>
    let energyStepLimit: Int               // MIK's one-step rule
}
```

### 6.1 The two values

| Field | **Wedding DJ** | **Junkie** | Why |
|---|---|---|---|
| `exitRegionFloor` | **0.72** | **0.25** | Wedding mixes out of the outro. Junkie will leave a track at any phrase boundary past a quarter in |
| `allowMidTrackExit` | `false` | `true` | the single line that most changes the character |
| `minimumPlayFraction` | **0.85** | **0.35** | Vande Veire enforces a hard 32-bar floor; Junkie's 0.35 is well above that |
| `admissibleTemplates` | T1, T2, T3, T4, T5, T8, T10 | all of the above **+ T6, T7, T9** | Junkie gets loop rolls, double drops and tempo ramps |
| `repeatTemplateCooldown` | **2** | **3** | Junkie repeats itself less, because it has more to choose from |
| `maxAbsRatePercent` | **2.0** | **6.0** | Kim et al: 86.1% of real transitions are under 5%. Junkie's 6 is the 94th percentile; Wedding stays where nobody could notice |
| `allowVarispeed` | `false` | `true` | §8.2. Varispeed shifts the key, so it is only for a profile that can afford to re-derive it |
| `requireMeasuredBPMForRate` | `true` | `true` | non-negotiable in both. `applyBeatMatch` already enforces this and it stays |
| `maxDriftMs` | **10** | **25** | §1.2. Wedding targets the sharp-transient threshold; Junkie accepts the Mixxx figure |
| `minGridConfidence` | **0.75** | **0.55** | Junkie will gamble on a shakier grid |
| `maxCamelotSteps` | **1** | **2** | Wedding is MIK's safe set exactly. Junkie may take a 2-step if other terms carry it |
| `allowEnergyBoost` | `false` | `true` | the +2 move, "every 20-30 minutes, but not ALL the time" |
| `genreCeiling` | **0.55** | **0.85** | prefilter cut, not a veto |
| `mayReorderQueue` | **`false`** | **`true`** | Wedding respects the user's order absolutely. This is the point of it |
| `lookaheadCandidates` | **1** | **24** | Wedding scores exactly one pair: the next track, as queued |
| `analysisBudgetPerTrack` | **1** | **3** | Wedding only needs the next track analysed |
| `maxLoopBars` | **8** | **32** | the owner's "20 bar loop" rounds to 16 or 32 |
| `maxLoopHalvings` | **1** | **4** | 32 → 16 → 8 → 4 → 2 |
| `timbreTargetDistance` | **0.18** | **0.32** | v3, once `InstrumentActivityResult` lands (§4.7) |
| `minimumScoreToFire` | **0.62** | **0.45** | Wedding would rather cut cleanly than take a risk. Junkie would rather try |
| `transitionBarsRange` | **8…32** | **4…64** | Junkie can slam in 4 bars or ride 64 |
| `energyStepLimit` | **1** | **2** | MIK's one-step rule, relaxed by one for Junkie |

Weights:

| Term | Wedding | Junkie |
|---|---|---|
| `feasibility` | 1.00 | 1.00 |
| `phrase` | 0.95 | 0.85 |
| `tempo` | 0.90 | 0.70 |
| `spectralClash` | 0.85 | 0.60 |
| `structure` | 0.70 | 0.90 |
| `genre` | 0.65 | 0.40 |
| `energy` | 0.55 | 0.75 |
| `harmonic` | 0.35 | 0.50 |
| `novelty` | 0.20 | 0.55 |
| `groove` | 0.30 | 0.45 |

The shape of the difference is the interesting bit. **Wedding weights the things that stop it sounding wrong** (phrase, tempo, vocal clash, genre coherence). **Junkie weights the things that make it sound like a choice** (structure, energy arc, novelty). Neither is "stricter"; they are optimising different objectives with the same machinery.

### 6.2 The same pair, scored twice

Outgoing: **"Amphetamine"**, 126.0 BPM measured, 8A, tech house, currently 4:10 into a 6:30 track (64%), with a breakdown starting at 5:02.
Incoming: **"BANGING NOISE"**, 132.4 BPM measured, 10A, hard groove, 16-bar intro, no vocals in the first minute.

Genre distance tech house → hard groove: **0.42**, confidence 0.7 and 0.6 so `κ = 0.42`.

| Term | Cost | Wedding contribution | Junkie contribution |
|---|---|---|---|
| `tempo` | 132.4/126.0 = +5.08%. Wedding can correct 2.0%, leaving 3.08% residual → over a 30 s blend that is 924 ms of drift, far past 10 ms → **cost 1.00**. Junkie corrects 5.08% fully, `(0.0508/0.10)^1.8` → **cost 0.29** | 0.90 x 1.00 = **0.900** | 0.70 x 0.29 = **0.203** |
| `phrase` | both on boundaries, downbeats known → **0.05** | 0.95 x 0.05 = 0.048 | 0.85 x 0.05 = 0.043 |
| `structure` | `.breakdown → .intro` → **0.10** | 0.70 x 0.10 = 0.070 | 0.90 x 0.10 = 0.090 |
| `harmonic` | 8A → 10A is +2, the energy boost. Wedding caps at 1 step → **0.85**. Junkie allows it → **0.25** | 0.35 x 0.85 x 0.45κ = 0.134 | 0.50 x 0.25 x 0.45κ = 0.056 |
| `energy` | tech house 6 → hard groove 8, a 2-step rise. Wedding's limit is 1 → **0.45**. Junkie's is 2 → **0.10** | 0.55 x 0.45 = 0.248 | 0.75 x 0.10 = 0.075 |
| `genre` | 0.42, κ = 0.42 | 0.65 x 0.42 x 0.42 = 0.115 | 0.40 x 0.42 x 0.42 = 0.071 |
| `spectralClash` | no vocal overlap → **0.00** | 0 | 0 |
| `novelty` | last transition was a `filterFadeOut`, this is `bassSwapBlend` → **0.00** | 0 | 0 |

**Wedding: 0.44.** Below its 0.62 threshold, so it does not fire. It plays "Amphetamine" out and cuts. The reason string:

> No mix. 126.0 → 132.4 BPM needs +5.1% and Wedding allows +2.0%, which would drift 924 ms over 16 bars. 8A → 10A is two steps round the wheel. Energy jumps two levels. Scored 0.44 against a 0.62 threshold. Playing out to a clean cut at 6:28.

**Junkie: 0.83.** Well over its 0.45 threshold, so it fires:

> Bass swap into "BANGING NOISE" at 5:02, 16 bars. 126.0 → 132.4 BPM (+5.1%, key-locked). 8A → 10A, an energy boost. Tech house → hard groove, lifting the room. Breakdown into a 16-bar intro, both on phrase boundaries. No vocals to clash. Lows swap on the downbeat at 5:32.

Same engine, same terms, same arithmetic. Two DJs.

Worth noticing that Wedding did not refuse because of a rule saying "no genre jumps". It refused because a 5.1% stretch it is not allowed to make leaves 924 ms of drift, and the other costs stacked on top. The refusal is a *number*, and the string says which number. That is the whole argument for the scoring approach in one example.

### 6.3 What to do about "Phantom"

`Phantom` appears in three files and **zero views**. Nothing user-facing depends on it. So the naming question is cheap either way, and the recommendation is: **keep it as the internal umbrella, put the owner's names on the profiles, and change the one thing that has to change anyway.**

| Name | Recommendation | Cost |
|---|---|---|
| `PhantomDJEngine` | **Keep.** It is a decent internal codename for the DJ who is not there, and it is already the pure planner, which is exactly where the new pure planner goes. Grow it into `PhantomDJEngine.Planner` / `.Templates` / `.Terms` rather than renaming it | zero |
| `PhantomDJEngine.Plan` | **Keep the name, widen the type.** Add `entrySeconds`, `templateId`, `profileId`, `rationale: PlanRationale`. `reasoning: String` stays, computed from the rationale, so nothing downstream breaks | small; `PhantomPlanSelfTest` needs its constructor calls updated |
| `PhantomActivity` | **Keep.** `.idle/.armed/.mixing/.cutting` is the right shape and the "never imply a mix that isn't happening" discipline is worth preserving verbatim | zero |
| **`isPhantomEnabled: Bool`** | **Must change regardless of naming.** Off / Wedding / Junkie is not a boolean. Becomes `djProfile: DJProfile?` with `nil` = off. Keep `var isPhantomEnabled: Bool { djProfile != nil }` as a computed shim for one release so the six existing call sites inside `PlayerService` do not all move at once | ~10 lines in `PlayerService`, 1 in `SoundingTVApp` |
| **UI** | The owner's names live here and only here: "Auto DJ: Off / Wedding DJ / Junkie". `Phantom` never appears on screen | new, in `DJModeView` |

So: Phantom is the umbrella, Wedding and Junkie are profiles under it, and nothing gets renamed for the sake of it. If the owner later wants `AutoDJPlanner` instead, it is a three-file rename with no view churn, and that is worth doing as its own commit rather than smuggled into this work.

---

## 7. Rules, a database, or a neural net

The brief asked me to argue this properly rather than just agree with the prior. Having read the literature, the prior is right, but not for the reason usually given, and there is one place where learning genuinely earns its keep.

### 7.1 The neural net loses on its own evidence

This is not a hunch. There is exactly one purpose-built deep DJ-transition model with a proper listening test, and it ties a linear crossfade.

DJtransGAN (ICASSP 2022) put 136 qualified listeners, 46 of them self-identified DJs, on a 5-point scale across four systems. **GAN roughly 3.2, linear crossfade roughly 3.1, hand-written rules roughly 3.0, and no statistically significant difference between any of them.** All three beat naive summation at 1.9. All three lost clearly to a human at 3.9. The experienced DJs' complaint was that the GAN "makes transition too fast", which is a complaint about a *hard-coded* 8-bar length, not about anything the network learned.

And look at what had to be true before the model could run at all: transition length hard-coded to 8 bars, cue points fixed by convention, and **track 2 pre-stretched and pre-pitched before the model sees it**. Every decision that actually matters was made outside the network. The network chose fader and EQ curves, which is the one part of a transition where a decent default is nearly as good as a great one.

Spotify, with more data and more listeners than anyone else in this space, wrote their conclusion down: *"the experiments above prove how just a few interpretable features are suitable for this problem to a remarkable extent."* They shipped six interpretable cost matrices and an argmin, and A/B tested it to **+1.4 percentage points on daily return rate**.

### 7.2 The training data is not there, and I checked locally

The brief's framing was "no training data". It is worse than that in the specific way that matters, and better than that in a way worth knowing.

What you *can* now get, legally and at scale: **Raveform** (TISMIR, April 2026) gives 4,902 mixes, 53,780 transitions, 6,522 hours and 1,423 tracks with full human structure annotations under CC BY 4.0. **EDM-CUE** gives 21,461 expert cue points across 4,710 tracks from four professional DJs' rekordbox libraries. That is real supervision for *where* and *when*.

What you cannot get, at all: **any public dataset of real EQ and fader automation curves.** The only exact version is UnmixDB, which is synthetic, uses constant time-scaling and linear crossfades, and ships CC BY-NC-ND, so it is noncommercial and no-derivatives. The paper that used it says so itself: results "do not always surpass the state of the art, due to the dataset's constant time-scaling".

So the supervision exists for the part that is already well-formalised into rules, and does not exist for the part a network would actually have to learn. That is close to the worst possible arrangement for a learned approach.

And then there is the ceiling. CUE-DETR fine-tuned a DETR object detector on those 21,461 expert labels and reached **best F1 0.46**. Not because the model is weak, but because the task is genuinely multi-modal: Kim et al. measured inter-DJ agreement on cue points at **23.6% exact, 40.4% within 4 beats, 73.6% within 8 measures**. Two professionals given the same track disagree three quarters of the time on the exact bar. A model trained to predict "the" cue point is being asked to predict a distribution and scored as though it were a point.

Locally, the picture is bleaker still. I scanned the owner's library read-only: **zero of 40 sampled `.mp3` files carry a Serato `Markers` GEOB frame**, the Serato subcrates contain only Serato's own demo content, and rekordbox's `master.db` is SQLCipher-encrypted. The most obvious source of personal ground truth is empty. Any plan that starts "learn from the user's own cue points" has nothing to start from.

### 7.3 A database of known-good pairs does not survive contact with SoundCloud

Pattern-matching a curated database of known-good transitions is the middle option, and it fails on a different axis: **coverage**.

The owner's `~/Music/SoundCloud/` is 321 files of edits, refixes, bootlegs and unreleased material. Titles like `227kg - Pegassi (mozart - unreleased)`, `All the things she said - t.A.T.u (Semisecco Edit)`, `BICEP - Glue (Rialians On Earth Remix + ACOR HT Rework)`. None of these have a stable identity in any external database. 1001Tracklists would know the original; it has never heard of the refix. A pair database would hit on the 5% of a SoundCloud library that is commercially released and miss on everything that makes the library interesting.

It also has the wrong generalisation shape. Knowing that A mixed well into B tells you nothing about C, unless you go back through features, at which point you have rebuilt the scoring model with extra steps and worse explainability.

Where a database *does* earn its place is as **priors, not lookups**. Raveform's 53,780 transitions can calibrate the numbers this spec currently sets by hand: the distribution of transition lengths, the exit-position histogram within a track, how often each structural pair occurs. That is offline work producing a table of constants, not a runtime dependency. Worth doing at v3 to replace guessed weights with measured ones.

### 7.4 What we build

**A registry of pure rules and a weighted, explainable score.** Because:

- The domain is formalised to an unusual degree. Camelot adjacency is arithmetic on the circle of fifths. Phrase structure is powers of two. The bass swap is one rule with one exception. This is not a domain crying out for a function approximator.
- Every failure is inspectable. When a mix sounds wrong, `PlanRationale` says which term won and which lost. A network says nothing.
- **Apple ships AutoMix in tvOS 27 as a black box.** A mix that can state why is the defensible difference, and that only exists if the decision is made by things with names.
- The whole search is 1,700 arithmetic evaluations. It runs in under 60 ms on an Apple TV with no model to load, no Core ML compilation, no thermal budget.

### 7.5 Where learning would earn its place

Two places, and both are small.

**Weight calibration from the user's own behaviour.** This is where a learned component genuinely beats hand-tuned numbers, because the target is a personal preference and no amount of reading DJ blogs recovers it. The signal is already there: skip within the first 30 seconds of a new track is a negative, playing a transition through and continuing is a positive, hitting "Mix Now" early is a negative on the current plan's timing. Fit a logistic regression over the ten term costs, with the hand-set weights as a strong prior, and update slowly. Ten parameters, hundreds of observations needed, not millions. It stays explainable, because the output is still a weight vector you can print. Gate it behind a "your DJ has learned X" line in Settings and a reset button.

The honest caveat: skips confound the transition with the track. Someone skipping because they dislike the song teaches the scorer nothing about the mix. Mitigate by only counting skips that land within 8 bars of the transition point, and by weighting a skip *during* a blend far more than one after it.

**Beat and downbeat tracking, if it becomes the bottleneck.** This is the one place a network is clearly the right tool, and both independent evaluations name it as the top failure cause. Spotify's curators blamed **15.22%** of bad transitions on misaligned beats and **0%** on key clash. Vande Veire built a custom tracker because madmom's 2.2% inter-beat-interval jitter and >0.25 BPM error on 30.3% of tracks broke beatmatching outright.

The good news is that it is small. All-In-One (WASPAA 2023, MIT) is **300 K parameters**, about 1.2 MB at fp32, and beats a 9.3 M-parameter transformer on every metric: Harmonix beat F1 .958, downbeat .915, segment boundary .660. Beat This!'s reduced variant is 2 M parameters and loses 0.3 F1. The heavy dependency is Demucs demixing, and the published ablation prices dropping it at **−0.017 downbeat, −0.046 segment boundary**, which is a fine trade against shipping a 50 to 150 MB separation network on tvOS.

But **do not build this until `MusicUnderstanding` has been measured**. MU gives `beats`, `bars` and `phrases` from Apple, on-device, already installed, with no model to ship. If MU's grid is good, a Core ML port is wasted work. If it is not, All-In-One is the fallback and it is 1.2 MB. Either way that is a v4 decision informed by data, not a v1 commitment.

**Everything else stays rules.** Not because learning is bad, but because on this evidence it does not win, and it costs the one property that differentiates us from what Apple already ships for free.

---

## 8. Tempo and pitch

The user asked to "move around bpm slowly, change pitch tempo". Here is what that actually costs.

### 8.1 The unit is already there

`AVAudioUnitTimePitch` is in every deck chain today, between the player and the EQ. `setRate`, `setPitch` and `matchTempo` all exist. Verified ranges from the tvOS 27 SDK: `rate` 1/32 to 32, `pitch` −2400 to +2400 cents, `overlap` 3.0 to 32.0. `MixEngine` clamps to `rateRange 0.5...2.0` and `pitchCentsRange ±2400`.

`matchTempo` currently refuses ratios outside `0.84...1.16`, which is ±16%. That is the CDJ's widest non-WIDE range and it is far too loose given that **86.1% of real DJ transitions adjust under 5%** and listener discomfort in a 96-person study peaks at exactly **±10%**. Move the limit onto the profile: Wedding 2%, Junkie 6%.

`AVAudioUnitVarispeed` (rate 0.25 to 4.0) is *not* in the graph.

### 8.2 Key-locked versus turntable, and the number that decides it

Two different moves that people call the same thing.

**Key-locked (tempo only).** `timePitch.rate = r`, pitch untouched. The phase vocoder stretches time and holds pitch. Harmonic mixing stays valid because the key does not move. Artefacts are granular smearing, worst on percussive transients and reverb tails. **The threshold is genuinely contested**: sources give 5%, 8%, and 10 to 20%, and none of them come from a controlled study. Do not put a hard number in the code comment. What we can say with evidence is that real DJs stay under 5% 86% of the time and listeners start reporting discomfort around ±10%.

**Turntable (rate and pitch together).** Natural, no artefacts at all, because it is a resampling rather than a reconstruction. And it moves the key:

```
cents = 1200 · log₂(r)
```

| Rate | Cents | In musical terms |
|---|---|---|
| +2% | +34.3 | a third of a semitone, sour |
| **+3%** | **+51.2** | **a quarter-tone. Out of tune with everything** |
| +4% | +67.9 | two thirds of a semitone |
| **+5.946%** | **+100.0** | **exactly one semitone** |
| +6% | +100.9 | a semitone, near enough |
| +8% | +133.2 | a semitone and a third |
| −6% | −107.1 | roughly a semitone down |

Which produces the counterintuitive result worth putting in the code comment: **with varispeed, small pitch changes are more harmonically damaging than large ones.** At +5.946% you land exactly a semitone up, which is a real key, seven steps round the Camelot wheel, and mixable with something. At +3% you land 51 cents up, which is not a key at all and clashes with everything including itself.

So the varispeed policy is: **snap to semitone multiples or do not use it.** If the required ratio is within 15 cents of a semitone boundary, snap and re-derive the Camelot code. Otherwise use key-locked.

Kim et al. found DJs transpose on **2.5% of plays**, and 94.3% of those by exactly one semitone. Which is the same policy, arrived at by 24,202 real decisions.

**Implementation, and it needs no graph change.** For turntable behaviour, set `timePitch.rate = r` **and** `timePitch.pitch = 1200·log2(r)` on the same node. Quality is worse than a true resampler (the vocoder stretches, then shifts back), but it is one node, zero reconnection, and no risk to `handleConfigurationChange`. If it sounds bad in the ±6% range, add an `AVAudioUnitVarispeed` in v3 with a bypass switch. **Experiment: render both at +6% offline through `enableManualRenderingMode` and listen.** Cheap, deterministic, settles it.

### 8.3 Phase alignment, and the biggest gap in the engine

`MixEngine.schedule(deck:fromFrame:)` calls `scheduleSegment(..., at: nil, ...)` and `play(deck:)` calls `player.play()`. Both mean "as soon as possible". So the incoming deck starts *whenever the main actor gets round to it*, which is a `Task` hop plus a render quantum. At 44.1 kHz with a typical 512-frame quantum that is 11.6 ms of jitter before you count the actor hop, and §1.2 says the budget is 10 ms.

**The engine currently cannot beatmatch, and no amount of scoring fixes that.**

The fix is `AVAudioTime`. Both `scheduleSegment(at:)` and `player.play(at:)` take one:

```swift
/// Starts `deck` at `sourceSeconds` such that its first beat lands exactly on
/// `reference`'s next downbeat. Sample-accurate: the scheduling happens on the
/// render thread's timeline, not the main actor's.
func cue(deck: Deck, to sourceSeconds: TimeInterval,
         alignedTo reference: Deck, grid: BeatGrid, phraseAligned: Bool) {
    guard let refTime = nodes[reference.rawValue].player.lastRenderTime,
          refTime.isSampleTimeValid || refTime.isHostTimeValid,       // the §0.1 guard
          let refPlayer = nodes[reference.rawValue].player.playerTime(forNodeTime: refTime),
          refPlayer.sampleRate > 0 else { return }                    // fail closed, never crash
    let framesUntilDownbeat = ...        // from grid + the reference's playhead
    let start = AVAudioTime(sampleTime: refTime.sampleTime + framesUntilDownbeat,
                            atRate: refTime.sampleRate)
    schedule(deck: deck, fromFrame: frame(for: sourceSeconds), at: start)
    nodes[deck.rawValue].player.play(at: start)
}
```

Two things to be careful about.

**The guard must be the same one.** `playheadPosition(for:)` already has the full `isSampleTimeValid || isHostTimeValid` plus `sampleRate > 0` guard, and its comment explains why: without it, `playerTime(forNodeTime:)` raises an **Objective-C** exception (`com.apple.coreaudio.avfaudio`, "required condition is false"), which is not catchable in Swift and kills the app. That is the documented DJ-mode crash. Any new code touching `lastRenderTime` copies that guard verbatim or it will reintroduce the crash, because the window it hits is precisely "just after a player node starts", which is exactly when a cue happens.

**Verify the claim, do not assume it.** I have not measured whether `play(at:)` on `AVAudioPlayerNode` is genuinely sample-accurate relative to another player node in the same engine. §9.5 names the experiment.

### 8.4 Ramping the tempo, and the arithmetic nobody mentions

This is the subtlest thing in the spec and it is exactly what "move around bpm slowly" runs into.

`setRate(_:on:over:)` already ramps linearly at 60 Hz. Ramp a deck from rate `r₀` to `r₁` over `T` seconds and the source frames consumed are:

```
∫₀ᵀ r(t) dt = T · (r₀ + r₁) / 2
```

whereas a deck held at `r₁` the whole time consumes `T · r₁`. So the ramped deck ends up **behind by `T · (r₁ − r₀) / 2` seconds of source material**.

Put real numbers on it. Ramp the incoming deck from 1.0 to 0.98 over 16 bars at 128 BPM, which is 30 seconds:

```
offset = 30 · 0.02 / 2 = 0.30 s = 0.64 of a beat at 128 BPM
```

**Nearly two thirds of a beat.** Against a 10 ms budget. A tempo ramp implemented naively is not slightly off, it is catastrophically off, and it will sound worse than snapping the rate instantly. This is almost certainly why "gradual BPM ramps" get proposed often and shipped rarely.

Two fixes, and the second is nicer:

1. **Pre-compensate.** Seek the deck forward by `T·(r₁ − r₀)/2` before starting the ramp. Correct, but it means a seek, and `MixEngine.seek` does `player.stop()` and reschedules, which is audible.
2. **Align at the midpoint.** Compute the phase alignment for the *mean* rate `r̄ = (r₀ + r₁)/2` and cue the deck so it is in phase at `T/2` rather than at `t = 0`. The deck then runs `+offset/2` early for the first half and `−offset/2` late for the second, symmetrically. With the numbers above that is ±0.15 s, still too much for 16 bars, which tells you the real answer:
3. **Split the ramp across both decks and keep it short.** Ishizaki's system splits the required change between the two tracks and inserts a **fixed 5-second ramp**. Splitting halves each deck's offset; a 5 s ramp instead of 30 s cuts it by six. Combined: ramping both decks by ±1% over 5 s gives `5 · 0.01 / 2 = 25 ms` per deck, and with midpoint alignment that is ±12.5 ms. Borderline, and it is why `tempoRampBlend` is Junkie-only with `maxDriftMs = 25`.

**Recommendation:** `tempoRampBlend` uses `split = 0.5`, ramps over **8 bars maximum**, aligns at the midpoint, and re-checks phase at the end of the ramp. If the residual exceeds `profile.maxDriftMs`, the template scores itself down rather than firing and hoping. Wedding does not get this template at all.

### 8.5 Coming home

`finishLiveTransition` already returns the incoming deck's rate to 1.0 over 8 seconds, with a good comment about why (a beat-matched deck is running at the *old* track's tempo, and leaving it there compounds across a set). Keep that exactly. Add the mirror for pitch when varispeed has been used, and re-derive the Camelot code for the now-live track from its true rate so the *next* transition's harmonic term is not computed against a key that is no longer playing.

### 8.6 Groove, and being honest about it

§1.4 showed that a 58% shuffled house track against a straight one has its offbeat hats 18.8 ms apart at 128 BPM, with the BPMs identical and the downbeats locked. Nothing in a beatgrid catches it, and `MusicUnderstanding` does not expose sub-beat onsets, so **swing cannot be read from MU's output**. `PaceResult` is a per-range `Double` of unverified semantics and should not be assumed to encode it.

So `groove` ships with `confidence 0` and drops cleanly out of the score. In v3, if it is worth it, compute a beat-synchronous onset histogram from the decoded PCM we already have: fold an onset-strength envelope modulo the beat period into 64 phase bins over 32+ bars, and take the centroid of the second-quarter lobe. That is the log-lag-autocorrelation insight done cheaply, and it sidesteps the discrete-onset error propagation that the ISMIR 2015 work says kills onset-based swing estimation.

Until it is measured, **the reasoning string must never claim the groove matches.** Same discipline as `isEstimated`.

---

## 9. Staging

Ranked so v1 is genuinely good and depends on none of the risky pieces. Nothing in v1 needs the `MusicUnderstanding` spike to come back positive.

### 9.1 v1 - fix what is broken, add the profiles

No new DSP nodes. No MU dependency. Ships on Tier 0 features, which is what Phantom already runs on.

1. **The bass swap becomes a swap.** Decouple its duration and trigger from the crossfade window: 1 to 2 beats, at a phrase boundary, inside the fader move. Right now it is a 20-second dB ramp during which both basslines are audible, which is the exact failure the technique prevents. **Highest value per line in the whole document.**
2. **Low shelf 120 Hz → 200 Hz.** One line. Every reference mixer sits higher and the 120 to 250 Hz band is where the mud lives.
3. **`entrySeconds` threaded through `performLiveTransition`**, replacing the hard-coded `seek(deck: incoming, to: 0)`. One line, and it opens the entire entry-point axis.
4. **Master headroom.** `masterVolume` to 0.707 for the duration of any overlap, restored over 2 s. Plus per-deck trim from the envelope's 95th percentile.
5. **The pure core.** `TrackFeatures`, `DJProfile`, `TransitionTemplate`, `ScoringTerm`, the two registries, `DJPlanner.rank`. Templates T1, T2, T3, T8, T10 registered. Terms: `tempo`, `phrase`, `structure`, `energy`, `genre`, `novelty`, `feasibility`.
6. **Wedding and Junkie as values**, with `isPhantomEnabled` becoming `djProfile: DJProfile?` plus a computed shim.
7. **`PlanRationale`** and the composed reasoning string.
8. **`halfTimeBlend` scoring** (the `tempoRelations` table). Pure scoring change, no DSP, and given the owner's bimodal 80/125 library it is the biggest musical win available for free.

Risk to the invariants: **none.** No change to the `AVPlayer`/`AVAudioEngine` handover, no new `lastRenderTime` access.

### 9.2 v2 - real DSP, still no MU dependency

9. **High-pass band** on the existing filter node (`AVAudioUnitEQ(numberOfBands: 2)`), plus `RampKey.filterHighPassCutoff`. Registers T4. Verified available in the tvOS 27 SDK.
10. **`AVAudioUnitDelay` per deck**, placed after `filter` and before `mixer` so the tail survives the fader. Registers T5, which is the correct template for large tempo gaps and is what `computeTransition` already claims to do.
11. **Sample-accurate cue** (§8.3). `scheduleSegment(at:)` and `play(at:)`. **This is the one with real crash risk** and it is gated behind experiment E1 below.
12. **Peak limiter** on the main bus at −1.0 dBTP.
13. **Tier 1 analysis**: partial materialise plus `AudioAnalyzer`, feature cache widened from `TrackAnalysis` to `TrackFeatures`, budgeted at 3 per track.
14. **Junkie's queue reordering**, now that there is a candidate pool worth ranking.

### 9.3 v3 - needs the MU spike

15. **`MusicUnderstanding` at Tier 2** for both deck-loaded tracks. This works regardless of the spike, because both are local `.caf` files. Registers real `beats`, `bars`, `phrases`, per-region `key`, `instrumentActivity` and `LoudnessResult`.
16. **`spectralClash` term** with real vocal ranges. Note the modest expectations: Vande Veire's own detector runs at F1 0.62 and discards 16.5% of clean crossfades.
17. **LUFS-matched gain staging** from `LoudnessResult.integrated`.
18. **T6 `loopRollOut`** with sample-accurate loop resize.
19. **T9 `tempoRampBlend`** with the §8.4 phase maths.
20. **Structure labels** from MU `sections`, mapped onto the Raveform vocabulary.

**If the spike comes back negative for remote HLS**, everything above still ships. Only Tier 1 gets more expensive, meaning candidate analysis needs a partial download rather than a URL. The engine degrades to "the two tracks on the decks are fully understood, the candidate pool is not", which is a perfectly reasonable auto-DJ.

### 9.4 v4 - stretch

21. **T7 `doubleDrop`**, Junkie only, needing drop detection plus tight phase lock plus the limiter.
22. **Weight calibration** from skip/replay (§7.5), ten parameters, hand-set weights as prior.
23. **Raveform-derived priors** replacing hand-set constants with measured distributions.
24. **Groove detection** via the beat-synchronous onset histogram.
25. **rekordbox / Serato import.** Worth flagging here because it changes the calculus above: if the app could read a DJ's already-analysed library (beatgrids, cue points, keys, all curated by hand), it sidesteps the entire "can we analyse streamed audio" question for every track the user owns. Serato stores this in `GEOB` ID3 frames plus `database V2`; rekordbox 6+ uses a SQLCipher-encrypted `master.db` with a published key, and also exports a plain XML. **Caveat from the local scan: on this machine the Serato database has 215 analysed tracks with BPM and key but the SoundCloud files carry no cue markers at all.** So import would deliver tempo and key, not cue points. Still a good feature, just not the shortcut it looks like.

### 9.5 Testing, and the trick that makes it cheap

`AVAudioEngine.enableManualRenderingMode(.offline, format:maximumFrameCount:)` renders the whole graph deterministically with no device, no audio session and no real time. That turns "does the transition sound right" into an assertion over PCM.

The project already has the rig: `#if DEBUG`, `XSelfTest.run()` returning `MixImportSelfTest.Report`, registered in `SoundingTVApp.swift`, run under `SOUNDING_TV_MIXTEST=1`. `PhantomPlanSelfTest` and `MixLoopSelfTest` are the pattern to follow.

**Pure-core tests** (no audio at all, the `PhantomPlanSelfTest` shape):

- Each `ScoringTerm` in isolation, with hand-built `TrackFeatures`. Ten small tests.
- **Confidence attenuation**: a term returning `κ = 0` must not move the score at all. This is the property most likely to break silently.
- **Profile differentiation**: the §6.2 pair must score 0.44 under Wedding and 0.83 under Junkie. Nail the actual numbers, not just the inequality, so a weight change surfaces as a failed assertion rather than a shrug.
- **Template preconditions**: every template rejects when its runway is short, and the rejection carries a reason.
- **Determinism**: same inputs, same seed, byte-identical `TransitionPlan`. Run it twice in the test.
- **Tempo relations**: 174 against 87 resolves to factor 2.0 with residual 0; 128 against 140 resolves to factor 1.0; 130 against 97.5 resolves to 0.75 (the shuffle-beatgrid failure case).
- **Registry**: a template needing an absent capability never appears in `admissible`.

**Offline-render tests** (new, and this is the valuable bit):

- **E1, the one that must pass before shipping sample-accurate cue**: render two decks each carrying a synthetic impulse train at exactly 128 BPM, cue deck B against deck A with `play(at:)`, then cross-correlate the two channels and assert the offset is **under 1 ms**. If `play(at:)` is not sample-accurate relative to another player node, this is where we find out, cheaply, before writing anything that depends on it.
- **Drift**: render a 60-second blend at 128.0 versus 128.1 BPM and assert the measured offset matches the §1.3 prediction of 46.8 ms within 2 ms. Validates the arithmetic against reality.
- **Headroom**: render the worst case (two identical correlated tracks at full level through the crossfade midpoint) and assert the main bus peak stays under −1.0 dBFS.
- **Bass exclusivity**: render a bass swap and assert that summed energy below 200 Hz never exceeds either deck's solo energy by more than 1 dB.

`ffmpeg`-generated tones served from a local HTTP server that mimics SoundCloud's JSON second hop, pointed at with `SOUNDING_TV_STREAM_HOST`, is already documented in `CLAUDE.md` as the thing that finally reproduced the DJ crash locally. Same rig, extended.

### 9.6 Risks to the documented invariants

**The `AVPlayer` / `AVAudioEngine` rule.** Nothing in this spec touches the handover. `takeOverFromAVPlayer` and `endMixSession` stay exactly as they are. One thing to watch: Junkie's queue reordering must never mutate `queue` while `isCrossfading`, because `finishLiveTransition` re-derives `currentIndex` from `queue.firstIndex(of: track)` and a concurrent reorder would land the cursor somewhere else. Guard reordering behind `!isCrossfading && mixWindow == nil`, same as every other tick-driven check in that file.

**The `playheadPosition` crash class.** This is the real one. §8.3 adds new `lastRenderTime` access, and the crash window is "just after a player node starts", which is exactly when a cue happens. Mitigations: copy the existing guard verbatim rather than writing a new one; put the guard in one `private func renderClock(for:) -> AVAudioTime?` helper so there is a single place to get it right; fail closed by falling back to `play()` with no alignment; and make E1 assert that a cue attempted 5 ms after `engine.start()` returns nil rather than crashing.

**`@Published` re-entrancy.** `MixEngine.decks` is `@Published` and emits in `willSet`; `PlayerService` subscribes. The planner must never be invoked from inside `mixEngineDidTick`. Run it from a `Task { @MainActor in ... }` hop, the way `startPhantomMixIfStillDue` already does.

**Cache pressure.** Tier 1 gets its own directory and its own cap (150 MB, 20 files), separate from `SourceImporter`'s 400 MB / 6 files. tvOS evicts Caches aggressively and the deck cache must win.

### 9.7 What the migration actually costs

`PhantomDJEngine.swift` is a monolithic `enum` with the rules baked into one 90-line `plan` function, plus a 100-line self-test. It is not a clean slate and should not be treated as one.

**Carries over unchanged:** the envelope walk, `quietThreshold = max(0.05, median · 0.55)`, the `floorSeconds = max(0.55·D, D − 90)` search window, the 4-consecutive-bucket calm requirement, `OutroShape` classification, `fallbackPlan`, `PhantomActivity`, and the entire "never claim a move you are not making" discipline. That is the majority of the file and it is good work.

**Gets restructured:** `plan(outgoingDuration:envelope:)` becomes `exitCandidates(...) -> [ExitPoint]`, ranked. The existing single-plan behaviour is `exitCandidates(...).first` composed with a T1 or T2 template, so the current self-test assertions can be kept as an integration test proving v1 did not regress Phantom's behaviour. `Accent` folds into templates T2 and T3 and the enum goes away, which is a small deletion at three call sites.

**Rough cost.** v1 is a new file of roughly 600 to 800 lines (core types, registries, five templates, seven terms) plus about 150 lines of changes across `MixEngine.swift` and `PlayerService.swift`, plus 200 lines of self-test. `PhantomDJEngine.swift` shrinks rather than grows, because the rules move out into registered templates. Two to three days of focused work, and about half of it is the tests.

**Do not regenerate the project from `project.yml`.** New files go in via Xcode or the `xcodeproj` gem, registered from the main session, with the group-relative path form documented in `CLAUDE.md`. `project.pbxproj` is a serialisation bottleneck and agents should not touch it.

---

## 10. Open questions, and the experiment that settles each

| # | Question | Experiment | Blocks |
|---|---|---|---|
| **E1** | Is `AVAudioPlayerNode.play(at:)` sample-accurate relative to another player node in the same engine? | Offline render, two impulse trains at 128 BPM, cross-correlate, assert offset < 1 ms | T6, T7, T9, and all of §8.3 |
| **E2** | Does `MusicUnderstandingSession(asset:)` accept a remote SoundCloud HLS URL? | The spike already running | Tier 1 cost only. Nothing in v1 |
| **E3** | How long does MU's `analyze()` take on a 6-minute track on an Apple TV 4K? | Time it on the local `.caf` a deck has already produced | The analysis budget in §4.5 |
| **E4** | Does MU return usable `bars` and `phrases` on SoundCloud's material specifically (bootlegs, refixes, live edits)? | Run it over 20 files from `~/Music/SoundCloud/` and hand-check the grid against Serato's BPM for the 215 tracks that have one | Whether `phrase` deserves weight 0.95 |
| **E5** | Does `timePitch.rate` + coupled `pitch` sound acceptable at ±6%, or do we need `AVAudioUnitVarispeed`? | Offline render both at +6%, listen | §8.2, a v3 decision |
| **E6** | Does a downstream time effect break `playerTime(forNodeTime:)` when `rate ≠ 1`? | Assert `playheadPosition` tracks true source position within 20 ms at rate 0.94 and 1.06 | Everything involving beat-matched playhead maths |
| **E7** | Does the delay's tail actually survive `player.pause()` in the proposed node position? | Offline render an echo-out, assert non-zero energy 2 bars after the source stops | T5 |
| **E8** | What is MU's key agreement with Serato on the 210 tracks that have a key? | Compare directly. Anything under ~50% and the harmonic weight of 0.35 is generous | The harmonic weight |

### Things I could not verify, stated plainly

- **Pioneer DJM channel EQ dB range.** The commonly cited −26 dB to +6 dB with an isolator mode reaching −∞ appears in a DJ TechTools forum post quoting the manual and in Pioneer product copy, but every route to an official spec PDF returned 403 or 404. The 70 Hz / 1 kHz / 13 kHz band frequencies *are* corroborated across two sources.
- **The flam threshold as a single number.** It does not exist. It ranges from 7.5 ms for a castanet-class transient to 75 ms for a soft one. The ±25 ms figure used throughout comes from the Mixxx design document, which is the only one from an actual DJ-software design process.
- **Key-lock artefact thresholds.** Sources give 5%, 8% and 10 to 20%. None from a controlled study. Do not put a number in a comment as though it were fact.
- **Who originated the loop roll.** Nobody could source it.
- **Dubstep, hardcore and trance as canonical double-drop genres.** Every source ties the double drop to drum and bass. The brief's wider list is not supported.
- **"Trancegate" as an Above & Beyond signature.** Actively contradicted. The trance gate is a general production technique popularised by Tiësto.
- **"Three decks and a bag of tricks"** as a Carl Cox phrase. Unverified.
- **Real cue points from the owner's library.** Not present on this machine. Zero of 40 sampled files carry Serato markers, the subcrates hold only demo content, and rekordbox's DB is encrypted.

### Signing off

The engine already has more than it looks like. Two decks with EQ, a filter, a time-pitch unit and a real loop primitive, plus a pure planner that already walks a waveform to find a breakdown. What it is missing is not capability, it is *precision*: a bass swap that snaps instead of dissolving, a cue that lands on a sample instead of a run loop, and a scoring model that can say out loud why it picked what it picked.

Get those three right and the exotic templates are mostly bookkeeping.
