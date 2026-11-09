# Set learning: what real DJ sets say about transitions

Status: second pass, 2026-11-09. 41 sets (3 local, 38 SoundCloud downloads), 1004 kept transitions, 985 of them anchored by a tracklist. Treat every number here as a direction, not a constant.

**This is a one-off training run, not a feature.** Nothing that reads, streams or analyses sets ships in the apps:
- the analysis code (`Core/DJ/SetLearning.swift`, `SetLearningPlot.swift`) is compiled only by `tools/SetLearning` (`run.sh`, `sources.txt`) and is in no app target;
- the headless Mac mode that reads downloaded sets (`SoundingTV-macOS/Sources/Debug/MacSetAnalysis.swift`) is wrapped in `#if DEBUG` and has no UI, setting or menu item;
- the apps carry only the trained output, `LearnedSetPriors.json` and its loader, which stays off by default so the Auto Mix bake-off can compare with and without it.

## Method

1. **Sources.**
   - *Local:* audio of 45 minutes or longer under `/Users/afr/Music`, opened read-only. Four files of 49 to 71 minutes (one is also a SoundCloud download, so only the download copy counts). Nothing under `~/Music` was written, moved or deleted.
   - *SoundCloud downloads:* the owner's own offline downloads, read offline by the Debug Mac app (see "SoundCloud sets"). 55 of 315 downloads are 30 minutes or longer; 40 were picked across genres and DJs (at most three per uploader), 38 analysed. No network request was made.
2. **Features.** `BeatTracker.extractFeatures` and `BeatTracker.analyze`, the same code the app uses, run over the whole set. The audio is then rolled up per bar: level, four band energies, chroma, a 16-step low pattern and a 16-step upper pattern, tempo from the beat intervals, and vocal coverage.
3. **Boundaries.** With a tracklist (two or more cues), each cue is anchored inside its window. The tracklists are Sounding's own Shazam setlists (`Application Support/Setlists`, read through `Tracklist`): for consecutive tracks A and B, the handover must lie between the last time A was heard and the first time B was heard, and B's estimated start (match time minus match offset) is where the blend probably began. The boundary is the strongest *track identity* change (bars b-28…b-4 against b+4…b+28) inside that window, with a prior 30 s after B's estimated start. No downloaded set had a timestamped tracklist in its description. Without a tracklist, peaks are picked from a novelty curve weighted by:
   - 0.50 *track identity*: the cosine distance between bars b-40…b-8 and b+8…b+40, using chroma plus the upper rhythm pattern. A breakdown inside one track has the same chroma and groove on both sides, so it scores low, while a track change scores high;
   - 0.25 local self-similarity;
   - 0.10 key change;
   - 0.10 low-band dip;
   - 0.05 beat-grid jumps.

   Peaks must be at least 48 bars apart, and the first and last 32 bars are ignored.
4. **Per-transition measurements.** These come from `SetLearning.measure`:
   - **Blend extent.** Each bar is projected onto the line from the outgoing core to the incoming core, using identity vectors and a window of ±40 bars around the boundary. The blend runs from where the projection leaves 0.15 to where it passes 0.85.
   - **Bass handover:**
     - *kill*: a low-band gap 6 dB or more under both neighbours, lasting under 8 bars (longer gaps are breakdowns, not kills);
     - *doubleThenSwap*: low 1.5 dB or more over both neighbours;
     - *step*: the largest bar-to-bar low change, if it exceeds 2 dB;
     - *crossfade*: none of the above.
   - **Double-bass bars and the swap position** within the incoming 8-bar phrase.
   - **Filters.** A monotone sweep of at least 4 bars and at least 9 dB, inside ±24 bars of the boundary. A falling low band with steady mids counts as HPF; a moving high band counts as LPF; both together count as "both".
   - **Loops.** Bar vectors repeat at lag 1, 2 or 4 above the outgoing track's own 90th-percentile similarity, for 8 or more bars.
   - **Energy step.** The mean level in the 8 bars after the blend minus the 8 bars before it.
   - **Vocal overlap**, from the tracker's vocal ranges.
   - **BPM.** BPM out and in, with a tempo ramp counted when 4 or more bars sit between 20 % and 80 % of the change.
   - **Key.** Krumhansl key out and in, as Camelot distance.
   - **Echo out**: a short blend with a level dip of 6 dB or more and a low drop of 10 dB or more.
   - **Cut**: a blend of 1 bar or less.
   - **Exit and entry sections**, from low, mid and level relative to each track's core.
5. **Per set.** The energy arc (median bar level per tenth of the set, relative to the set median), the BPM arc per tenth, and BPM drift from the first tenth to the last.
6. **Kept for statistics.** Transitions with confidence of at least 0.2 (or anchored by a tracklist) whose blend lies more than 60 s from either end of the set.
7. **Genre.** The uploader's SoundCloud genre, folded into families (techno, house, trance, disco, edm, hard / rave). Sets with no genre are placed by median BPM and marked "(by tempo)".
8. **Limits.** `BeatTracker.extractFeatures` stops at about 2.5 hours, so the 3 to 6 hour sets contribute their first 149 minutes. Two downloads (Pegassi 5HRS, Tjade ADE closing) crashed the analyser and are excluded.

Tooling: `tools/SetLearning/run.sh <build dir> analyse <audio> <out dir> [genre]` for local files, `tools/SetLearning/the one-off driver (removed) <Debug Sounding.app> <set-learning binary> <out dir> [limit] [max hours]` for downloads, then `aggregate <reports dir> <priors.json> <labels.json> <stats.md>`, then `effects <priors.json>`. One 60-minute set takes 20 to 60 s on the Mac.

## Calibration

The first detector picked in-track breakdowns as transitions. The track-identity term, a ±40 bar window and kills shorter than 8 bars fixed the obvious cases. Without a tracklist some boundaries still land late, on the incoming track's first breakdown (Café Del Mar 40:12).

The setlist windows fix most of that: the handover can no longer leave the stretch between the last sighting of A and the first sighting of B, which is usually 60 to 120 s wide. Envelope plots of the Essy and Chris Stussy sets show the boundary on the real low-band handover. Two weaknesses remain:
- a Shazam mis-identification inside a track creates a false cue. Its window is usually narrow and its identity change weak, so its confidence is low, but tracklist-anchored transitions are kept regardless of confidence;
- the bass-handover classifier still calls a long incoming breakdown a "kill" when the gap ends inside the blend.

No transition has been checked by ear.

**Visual spot-check (2026-11-09).** 20 boundaries, one from each of 20 different downloaded sets, judged from the band plots in `downloads-v1/reports/png/` (an estimate, not listening): 15 right, 4 shifted, 1 wrong. All four shifted windows run long, out into steady groove past the visible handover (sc-1225532056-05, sc-1893089691-07, sc-1941740879-25, sc-2321790599-03); the wrong one sits inside a gated techno loop with no unique change (sc-2032560920-10). Bass-swap markers: 18 plausible, 1 about 30 s late (sc-2321790599-03), 1 unreadable. Section labels: 13 plausible, 7 unreadable, none contradicted. So blend lengths in this survey lean long, and the 31-bar median is an upper estimate.

## Sets

41 sets: 3 local, 38 SoundCloud downloads. Every downloaded set is tracklist-anchored.

| family | sets | examples |
|---|---|---|
| techno (tagged or by tempo) | 22 | Essy (Wildeburg), TAFKAMP (De School), Parrish Smith (Dekmantel), Diffrent, Benwal (DGTL), Hoymans, Daria Kolosova, SaltySis, Pegassi (Essential Mix) |
| house | 9 | Chris Stussy (STRAF_WERK), Malugi (RA.981), Angel D'lite, Paige Tomlinson, Obskür b2b Luuk van Dijk, Locklead, Cuckoo's Nest, Café Del Mar |
| disco | 3 | Purple Disco Machine (Essential Mix), Palms Trax b2b DJ Tracksuit, Groovin' the Tropics |
| trance | 3 | Essy (Superstrings), L.zwo, Princess Elf Bar |
| hard / rave, edm | 5 | Geck-o ×2, Neon Cleptu, Bombs Away, WBBL |

Median BPM ranges from 113 (Vardae) to 176 (WBBL). Median spacing between transitions is 112 to 570 s per set; most club sets change track every 2.5 to 3.5 minutes. The full per-set table, with BPM drift and energy arcs, is in `stats.md`. Reports are kept outside the repo: per-set JSON in `/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/set-learning/combined`, envelope plots of the downloaded sets in `/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/set-learning/downloads-v1/reports/png`.

## Statistics (1004 kept transitions)

**Blend length (bars):**
- p10 10, p25 18, median 31, p75 42, p90 53.
- By bucket: 32 bars 50 %, 16 bars 23 %, 64 bars 13 %, 8 bars 10 %, 4 bars 4 %.

| family | n | median | p25–p75 |
|---|---|---|---|
| techno (tagged) | 165 | 38 | 21–44 |
| techno (by tempo) | 379 | 29 | 18–42 |
| trance | 64 | 40 | 24–45 |
| hard / rave | 68 | 38–40 | 22–43 |
| house | 171 | 31 | 19–41 |
| house (by tempo) | 43 | 23 | 8–34 |
| edm | 47 | 28 | 20–34 |
| disco | 67 | 26 | 12–44 |

**Moves:** bass swap with no filter 35 %, HPF blend 24 %, LPF filter blend 15 %, loop blend 9 %, plain EQ blend 9 %, tempo blend 7 %. Drop-ins, cuts and echo outs are under 1 % (4 drop-ins, 2 echo outs).

**Bass handover:**
- kill 55 %, step 26 %, double then swap 16 %, crossfade 3 %;
- the swap sits in the middle of the blend (median fraction 0.5, p25 0.2, p75 0.8);
- 35 % of swaps land on bar 0 of the incoming 8-bar phrase, against 12.5 % by chance, and another 12 % on bar 7 (one bar early);
- 28 % of blends have 2 or more bars of measured double bass, an overestimate for the reason given in the first pass.

**Filters:** none 52 %, HPF 20 %, LPF 19 %, both 10 %.

**Loops:** 10 % of transitions show 8 or more bars of near-identical repeats on the outgoing track.

**Echo outs:** 2 of 1004. Either these DJs almost never echo out of a track, or the detector (a blend of 2 bars or less with a 6 dB level dip and a 10 dB low drop) is too strict for a tail that rings over the incoming track. It has not been validated on a known echo out.

**Phrasing:** 13 % of blends start on an outgoing 8-bar line and the two grids agree in 37 %. The bass swap, not the blend start, is what lands on the phrase.

**Sections:**
- outgoing exits from drop 74 %, outro 15 %, breakdown 11 %;
- incoming enters as drop 64 %, intro 18 %, breakdown 15 %, build 2 %.

**Energy step:** median -0.4 dB (p10 -6.7, p90 +5.3). Most transitions are level.

**Key (Camelot distance):** 0 20 %, 1 18 %, 2 20 %, 3 15 %, 4 13 %, 5 9 %, 6 or more 5 %. Over half are within 2 steps; still noisy on blended audio.

**Tempo:** ramps inside 7 % of transitions. Across a set, BPM mostly walks up slowly: Palms Trax 111 → 126, Essy (Superstrings) 132 → 141, Diffrent b2b Kyle Starkey 139 → 147, Pegassi 140 → 156 in the last tenth. Flat sets (BLYSS, Obskür, Café Del Mar) hold one tempo all night.

**Spacing:** median 172 s between transitions (p25 108, p75 261).

**Energy arcs:** nearly every set stays within ±2 dB of its median from start to end. The typical shape is a quieter first tenth (-1 to -3 dB), a flat body, and a dip or fade in the last tenth. Loudness does not build; tempo and density do.

### How real DJs mix, in plain English

- **Blends are long.** Half of all transitions run about 32 bars (about a minute at 128 BPM, 50 s at 150). Only one in seven is 8 bars or shorter.
- **Faster, harder music blends longer.** Techno, trance and hard sets sit around 38 to 40 bars. House sits around 31, disco and EDM around 26 to 28, and disco has the widest spread.
- **The bass goes over once, in the middle, on the incoming downbeat.** In most transitions one bass line is cut and the other comes in, usually halfway through the blend, and a third of the time exactly on the first bar of an incoming 8-bar phrase. Real double-bass overlaps are short.
- **Half the time there is no filter.** When there is one, high-pass on the outgoing track and low-pass sweeps are about equally common, and a tenth use both.
- **Loops are a minority tool, echo outs nearly absent.** About one transition in ten holds a loop on the outgoing track. Echo outs, cuts and drop-ins barely appear in these club and festival sets.
- **DJs leave from full energy and land in full energy.** Three quarters of exits leave from a drop, not an outro, and two thirds of entries arrive already at drop level. Level stays roughly flat across the change.
- **Tempo moves between tracks, slowly, and mostly upwards across a night.** Ramps inside a blend are rare.
- **Key is loosely respected.** More than half the transitions are within 2 Camelot steps, but a third are 3 to 5 steps apart.

## What this implies for Auto Mix

1. **Longer blends are normal.** The median is 31 bars and half of all blends fall in the 32-bar bucket. Our defaults that pick 8 to 16 bars for drop-to-drop are shorter than what these DJs do. Techno and trance run longer (about 38 to 40 bars) than house (31) and disco (26).
2. **Swap the bass on the incoming phrase line, in the middle of the blend.** This is the strongest pattern (35 % on bar 0, against 12.5 % by chance, over 1004 transitions), and it matches rule 33 and the runway rule in the bible. Keep it.
3. **Filters are common but not the default.** About half of all transitions use one (HPF and LPF equally). A plain bass swap is the single most common move.
4. **Exit from the drop.** Three quarters of exits leave from full-energy material, not an outro. Planner exits that insist on outros are stricter than practice.
5. **Key is a soft preference, not a rail.** 27 % of real transitions are 4 or more Camelot steps apart. This should not loosen our rails yet: the key detector is unvalidated on mixed audio.
6. **Hold the tempo inside a blend, walk it across the set.** 7 % of transitions ramp; most sets drift up a few BPM over the night.
7. **Echo outs and cuts are rare in this corpus.** Keep them as occasional moves, but do not read their low prior as proof until the echo detector is validated.

## Learned priors

`Core/DJ/LearnedSetPriors.json` (bundled in the tvOS, iOS and macOS apps) holds the distributions above. `LearnedSetPriors.adjustment` adds a bounded term to each candidate's score in `DJCore`, next to the transition-net term:

`0.012 × (log lift of the move group + log lift of the blend bucket + 0.5 × exit lift + 0.5 × entry lift)`, clamped to ±0.03.

Lifts are against uniform, with 12 pseudo-counts. With 1004 transitions the pseudo-counts no longer matter much.

It is **off by default**:
- turn it on with `defaults write red.forbes.sounding AutoMixLearnedSetPriors -bool YES`;
- `AutoMixLearnedSetPriorsPath` can point at a different JSON.

There is no UI toggle.

### How it shifts the planner (drop → drop, from `set-learning effects`)

| move (group) | 4 bars | 8 bars | 16 bars | 32 bars | 64 bars |
|---|---|---|---|---|---|
| longBlend (blend) | +0.019 | +0.030 | +0.030 | +0.030 | +0.030 |
| loopMix (loop) | -0.007 | +0.004 | +0.014 | +0.023 | +0.007 |
| tempoBlend (tempo) | -0.010 | +0.001 | +0.011 | +0.020 | +0.004 |
| cut, drop-in, echo out | -0.025 | -0.015 | -0.005 | +0.005 | -0.011 |

| exit → entry (32-bar blend) | adjustment |
|---|---|
| every pair except breakdown → breakdown | +0.030 (at the cap) |
| breakdown → breakdown | +0.029 |

In ranking terms:
- a long blend now sits at the +0.03 cap from 8 bars up, so blend length among long blends no longer separates candidates;
- a blend gains 0.04 to 0.055 on a cut, drop-in or echo out at 4 to 8 bars, and about 0.025 on a loop at 4 bars;
- section pairs are all at or next to the cap, so the section term has stopped discriminating.

That is the same size as the transition-net term and smaller than any `DJMoveRails` veto or penalty. It only reorders near-ties, and never overrides a rail.

Risk: the cap now saturates for most blends, so the term mainly penalises short special moves. Cuts and echo outs score lower partly because the detector found almost none. Leave it off until the bake-off shows it helps; if it stays, lower `weight` or raise the cap so lengths and sections separate again.

## Labelled transitions

`tools/AutoMixNetLab/set-learning-good.json` contains 1004 transitions labelled good (rating 4), in the lab's `Dataset` format (`samples[]` of `id`, `fault`, `good`, `rating`, `estimated`, `measured`; both observations come from the measured audio). They are positives only. Pair them with the synthetic faults before training, and consider dropping tracklist-anchored samples with confidence under 0.1, which may sit on a Shazam mis-identification.

## SoundCloud sets

Streaming was stopped in the first pass because two processes sharing one rotating refresh token can sign the owner out. The owner then approved streaming only while his Sounding is fully quit, and asked to read his downloads first. The downloads gave 55 usable sets, so **nothing was streamed**.

How the downloads were read:
- `SOUNDING_TV_SET_ANALYSIS=<dir>` in the Debug Mac app (DEBUG only) exits from `SoundingMacApp.init` before any runtime, credential, Companion, Sonos or CloudKit start-up, and never touches the network. It refuses to run if another Sounding is running.
- `SOUNDING_TV_SET_ANALYSIS_STEP=list` reads the cached account ID from defaults, opens the encrypted download index with `AccountDataVault`, and writes a candidate list with Shazam-setlist cues. `decrypt:<track id>` decrypts one file with `DownloadVault.key(createIfMissing: false)` and `DownloadVault.decryptFile` into the app's temporary directory.
- a one-off driver (removed after the run; no Python in tooling) checks that no Sounding is running before each set, runs the analyser on the decrypted file, and deletes it as soon as the measurement ends. Only per-set JSON and envelope plots are kept.
- The downloads folder, index and keys are never written. No key or token is printed.

Without the sandboxed app's keychain access the files cannot be decrypted, which is why this lives in the Debug Mac app and not in the command-line tool. The streaming mode was not built.

## Next

- Check 20 anchored boundaries by ear and record the miss rate. (A visual check of 20 is done, above; listening is still open.)
- Validate the loop and echo detectors on synthetic renders, where the truth is known. The echo-out share (0.2 %) is the least trustworthy number here.
- Lift the 2.5-hour feature cap so long sets count in full.
- Run the Auto Mix bake-off with and without `LearnedSetPriors`, and retune `weight` and the cap if it stays.

