# DJ mixing craft: what the Auto Mix planner must know

Status: research, 2026-11-07. Input to the planner work that follows `automix-overhaul.md` (§2.2 planning, §6 moves and rails).

Why: the owner, a DJ, listened to our renders and said the mixer blends "right in the middle of a lyrical peak of the song… and right into a lyrics peak of another, that isn't how mixing works at all". This document sets out how mixing is actually done, turns that into rules the planner can be tested against, and lists where our planner breaks them.

How to read the sources: most practical DJ guidance is published by DJ schools, software vendors and DJ blogs, which repeat each other. Where a rule is backed by measurement (MIR papers that analysed thousands of real mixes, or listening tests on automatic systems), that is called out, because it is stronger evidence than a blog's rule of thumb. Thresholds marked *starting value* are ours, chosen to be testable, and should be tuned by ear and on the real-music corpus.

---

## 1. Phrasing

**Phrase structure.** Dance music is in 4/4 and built from repeated blocks. Zehren et al., working from interviews with professional DJs, state that EDM sections are "two, or a multiple of two, repetitions of a phrase which is itself composed of two, or a multiple of two, bars", so "every period of four bars anticipates the potential start of a new music section" [Z20]. In practice DJs count 8-bar (32-beat) phrases and expect arrangement changes every 16 or 32 bars: an element enters or leaves, a crash or fill marks the line [DJTT09, SIREN]. At 128 BPM, 8 bars is 15 s, 16 bars 30 s, 32 bars 60 s. Drum and bass is often counted in 64-beat (16-bar) phrases [DD-DNB].

**Sections.** The standard club arrangement is intro (drums only or sparse, often 16–32 bars, 32–64 in techno), build/"up", drop or main section, breakdown/"down", second build and drop, outro (elements removed, ending on drums) [EXT, TECHNO-ARR]. rekordbox's phrase analysis names the same parts: for "High" mood (club) tracks Intro, Up, Down, Chorus, Outro; for "Mid" and "Low" mood (pop, hip-hop) tracks Intro, Verse 1–6, Chorus, Bridge, Outro [RB-PHRASE, DJL-ANLZ]. The split matters: pop is described as verse/chorus, club music as up/down/drop.

**Aligning phrases.** The basic rule in every source: start the incoming track at the start of a phrase in the outgoing track, so both tracks' 8/16/32-bar grids run in step and their sections change together [DJTT09, WIKI-PHR, VIBES-PHR]. DJ TechTools: "always start the new song at the beginning of a phrase in the outgoing track" [DJTT09]. Wikipedia adds the stronger form: line up the breaks of both tracks so they change section on the same bar [WIKI-PHR]. If the intro and outro lengths differ (16 against 8), DJs loop the shorter one or beat-jump so the phrase grids still meet [VIBES-PHR].

**Measured evidence.** Kim et al. aligned 1,557 real mixes from 1001Tracklists to their 13,728 source tracks [K20]:
- Transition lengths (cue-out to cue-in) form a histogram with "peaks at every phrase", every 32 beats.
- Cue points cluster: of all pairs of cue points that different DJs chose on the same track, 23.6% were identical, 40.4% within one bar, 73.6% within 8 bars, 86.2% within 16 bars. DJs agree on where a track can be mixed.
- The cue-out point, where the previous track starts to fade, shows peaks every 32 beats against annotated track boundaries.

**Where mixes start and land.** The default is the outgoing track's outro over the incoming track's intro: both are low-density, DJ-friendly sections made for this [VIBES-PHR, EXT]. Extended mixes carry "16 to 32 bars of clean drums at the beginning and end for beatmatching and phrasing", radio edits "cut straight into the vocal" with 0–4 bars of intro [SIREN-EDIT]. Secondary pairings: outgoing breakdown into incoming intro or build; outro into the incoming's first verse for a lift [VIBES-PHR, EDMGP-PHR]. The pairing to avoid: the new intro over the old track's drop or vocal hook [EDMGP-PHR].

DJ TechTools also warns the other way: "respect the chorus". Don't cut a track before its peak, and don't mix only intros into outros all night, since that keeps energy low [DJTT09].

**Blend length by genre** (practitioner consensus, not measured) [MG-MINIMAL, MG-MELODIC, MG-TECHHOUSE, CMUSE, DJL-TRANS]:

| Material | Typical overlap |
|---|---|
| Hip-hop, pop, radio edits | 1–8 bars, often a cut or echo out |
| Big room, EDM | 8–16 bars |
| House, tech house | 16–32 bars, up to 64 when the pair suits |
| Progressive, melodic techno, trance | 32–64 bars |
| Minimal, deep, ambient | 64 bars or more |

The Kim et al. histogram supports long blends being normal in club mixes: the peaks run out to 128 beats (32 bars) and beyond [K20].

## 2. Vocals

**Two vocals at once.** All sources treat overlapping lead vocals as the main thing that makes a mix sound wrong. "Two sets of vocals playing at once almost always sounds like a car crash" [NAJADE-2]. Mixed In Key: "If vocals overlap, dip one vocal with EQ or swap to an instrumental section", and "use a shorter overlap or another pairing if the arrangement clashes, even when the key labels look compatible" [MIK-5, MIK-KEY]. Mixgraph puts a number on the tolerance: "a 4-bar or 8-bar blend where both vocals are audible is manageable. A 32-bar blend with both vocals going is a mess", and two rap vocals layered for 16 bars is "almost always a trainwreck" [MG-VOX]. Every automatic system that has been listening-tested penalises vocal overlap: Spotify's transition planner adds a per-beat "vocalness" cost because "when vocals are present we risk overlapping vocals with the other track, or cutting over mid-sentence" [B17]; Vande Veire and De Bie measure vocal activity with a trained model and avoid vocal overlap in the crossfade [VV18-BLOG]; Mosaikbox separates stems and modifies the vocal stem if the vocals "intersect for more than two seconds" [MOSAIK]; DJustify's checker flags "vocals collide in the overlap" and shortens or cuts [DJUSTIFY].

**Never cut into or over a hook.** Two separate faults, and the owner named both:
1. *Leaving the outgoing in the middle of its vocal or hook.* "Let the outgoing vocal finish its phrase before completing the transition. Cutting a vocal mid-word sounds abrupt and unintentional" [MG-VOX]. DJustify's first checker gate is "cut mid-phrase", repaired by moving the cue to the phrase end [DJUSTIFY].
2. *Landing the incoming in the middle of its vocal or hook.* "Time the blend so the vocal enters after a breakdown or at the start of a phrase. Don't bring the vocal in mid-sentence" [MG-VOX]. DJustify gates "early cut in A or late entry in B" [DJUSTIFY]. Spotify's curators flagged "transitioning mid-vocals" as a fault class [B17].

**How DJs time a mix around vocals.**
- Mix during instrumental sections: the DJ-friendly intro and outro, breakdowns without vocals, drum sections [VIBES-PHR, DJCITY].
- Take turns: overlap the incoming's instrumental with the outgoing's vocal, or the reverse, so only one vocal is ever audible [MG-VOX].
- Let the hook finish, then hand over: in pop, "mix out of the chorus" so the crowd gets the payoff, and "time it so that the first verse of your new song starts right as the old chorus ends" [DJTT09].
- Mid swap: cut the incoming's mids during the blend and swap mids as well as bass, since vocals sit around 200 Hz–4 kHz [MG-VOX].

**When vocal over instrumental is fine.** Acapella layering is an accepted technique: an acapella over an instrumental (or the instrumental intro/outro of another track) in the same or compatible key, started at an obvious point such as a breakdown or drop [DDJT-ACA]. The condition is that the other track has no vocal at that moment: "you don't want to use your acapella at the same time there are vocals playing in the original song" [DJCITY]. Short vocal chops and one-word hooks layer more easily than sung lines; melodic vocals in compatible keys can overlap briefly; spoken word and rap rarely can [MG-VOX].

**Pop and vocal-heavy tracks** are handled differently because they have no long instrumental runway:
- Shorter overlaps (8 bars or less), or no overlap: the end-to-end, the fade-out timed so "the old track has faded just as the new one starts on the first beat of a phrase", or the stop/start, where the new track should "open on something recognisable or dramatic" [DDJT-5]. Digital DJ Tips notes "hip-hop, pop, rock and funk" often "have no long sections to beat mix over" [DDJT-5].
- Echo out on the last beat of a phrase, then bring the new track in on the "1" of the next phrase while the echo rings [DJL-FX, VIBES-TRANS].
- Loop the short intro of the incoming under the outgoing chorus, then release it as the chorus ends [DJTT09].
- Power-block style: cue points on hooks, mix every 20–30 s; this is a performance style for some rooms, not a default [MIK-5].

## 3. EQ and energy

**The bass swap.** Bring the incoming track in with its low EQ cut, then at a phrase line swap: lows down on the outgoing, up on the incoming. Digital DJ Tips' version is an 8-bar transition with the swap after 4 bars, because "two kick drums and two lots of low end at once sound worse, not better" [DDJT-5]. Other guides: swap "exactly at the phrase change" after 8–16 bars of blend [VIBES-EQ], "as soon as Track B's bass is present, make sure Track A's bass is completely gone" [DJS-EQ], "cut the outgoing bass and open the incoming one in the same motion" [MIXTAPE-EQ]. A drop can take an instant swap; rolling house grooves may take a gentler handoff [DDP-EQ]. Native Instruments teaches the same [NI-TRANS].

**Never two basslines together.** Stated by every EQ source above. Kim, Yang and Nam reverse-engineered per-band gain curves from 3,930 real transitions and found sub-band (per-band) models reconstruct real mixes better than a single crossfade, which confirms that DJs move bands separately rather than fading the whole signal [K21].

**Low, mid, high technique.**
- Low: swapped, as above.
- Mid: cut on the incoming during a blend of two melodic or vocal tracks, swapped later [MG-VOX].
- High: hi-hats and air can be brought in early to introduce the incoming groove; the incoming's highs are often the first thing heard [EDMGP-EQ].
- "Cut, don't boost": a DJ EQ at 12 o'clock is unity, and boosting pushes into the red [HDS-EQ, EDMGP-EQ].

**Filter use.** The filter fade: high-pass the incoming (removing its bass), open it as the outgoing is high-passed away; Native Instruments recommends it for "very busy" tracks [NI-TRANS]. A high-pass sweep up on the outgoing is also a build device.

**Gain staging and volume dips.** Set each channel's gain so both tracks meter the same before touching EQ, with peaks below red [DJTT-GAIN]. Matched gain is what keeps "perceived loudness consistent" through cuts and swaps [EDMGP-EQ]. The dip comes from turning one low EQ down before the other comes up, or from channels that weren't level-matched; the fix is matched meters and a simultaneous swap on the downbeat [EDMGP-EQ, MIXTAPE-EQ]. Spotify's planner adds a cost for transitions over quiet regions, since "transition regions with low loudness can often sound awkward and abrupt" [B17].

## 4. Harmonic mixing

**Camelot rules** [MIK-GUIDE, MIK-5]:
- Same key (8A to 8A).
- One step either way on the wheel, same letter (8A to 7A or 9A): adjacent keys share most notes.
- Same number, other letter (8A to 8B): relative major/minor; minor to major "lifts the mood; the reverse darkens it".
- Bigger jumps (3A to 9A) are curveballs, "used with extreme caution".

**Energy boost moves.** +2 on the wheel raises the key by two semitones; +7 raises it by one semitone [HM-BOOST, MIK-COMMUNITY]. Mixed In Key's own community answer calls +2 the energy boost and +7 "more of a modulation mix" [MIK-COMMUNITY]. "One or two energy boosts per set feel powerful; too many can lose their impact" [MIK-5].

**When key clashes matter.** Key labels matter when both tracks carry sustained harmonic content in the overlap: pads, chords, basslines, sung vocals. Mixed In Key lists "competing vocals, basslines and chord changes" as the things to listen for [MIK-KEY]. They matter much less when one side is percussive: drum intros and outros, DJ tools. Two pieces of evidence that key is secondary to timing and structure:
- Spotify's curators rated 48 automatic transitions and did not mark "key clash" as a problem for a single one; the faults they found were beats not aligning (15% "bad") and transitions mid-vocal [B17].
- In 24,202 tracks across real mixes, only 2.5% were transposed, and 94.3% of those by one semitone: DJs leave key lock on and don't fix keys by transposing [K20].

## 5. Tempo

**Ranges.** In real mixes, 86.1% of tracks were played within 5% of their native tempo, 94.5% within 10% [K20]. With key lock on, ±3–6% is regarded as transparent, artefacts creep in towards ±8% and are clearly audible past ±10%, worst on exposed vocals and cymbals [CROSSFADER, MG-PITCH, OKS-BPM]. rekordbox Automix only syncs tempo within ±8% (later builds expose a minimum threshold of ±6%), otherwise it mixes without sync [RB-FORUM, RB-NOTE]. Spotify's evaluation pairs were limited to 5 BPM apart [B17]; Digital DJ Tips' acapella guide uses "around five BPM either way" [DDJT-ACA].

**Halftime and double-time.** Tracks at exactly 2:1 share a downbeat grid (87 and 174, 70 and 140), so they can be blended; between unrelated tempos (124 house into 174 drum and bass) DJs echo out or go through a stepping-stone track [VIBES-HT, MG-HT].

**Ramps across a set.** About +1 BPM per transition moves a set without anyone noticing a change [VIBES-TRANS, SETFLOW]. Rules of thumb for the gap between two tracks: 1–5 BPM sync and mix; 6–15 BPM ramp gradually or loop; 16+ BPM use a breakdown, effect or cut [TUNETAPPER]. Big tempo moves are hidden in breakdowns [OKS-BPM].

## 6. Transition types

| Move | What it is | When it fits | When it doesn't |
|---|---|---|---|
| Long blend with bass swap | Phrase-aligned overlap, lows swapped on a phrase line | Both tracks have instrumental runway; house, techno, progressive [DDJT-5, VIBES-EQ] | Either side has vocals or a hook in the window; tempos far apart [DJL-TRANS] |
| Quick cut on the 1 | Switch on a downbeat, usually a phrase start | Peak time, "clear statements"; the incoming opens on something strong; pop and hip-hop [NI-TRANS, DDJT-5, DJL-TRANS] | Mid-phrase; incoming starts quietly |
| Echo out | Beat-synced echo on the last beat of the phrase, fader down, incoming on the next "1" [DJL-FX, VIBES-TRANS] | No runway, a vocal outro, a genre or tempo change [DDP-TRANS] | At peak energy it "risks deflating the room"; overuse; out-of-time echoes [VIBES-TRANS] |
| Reverb wash | Last snare or phrase into a long reverb | Into a breakdown or a calm incoming [VIBES-TRANS] | When energy must stay up |
| Filter fade | High-pass incoming opens as outgoing is filtered away | Busy tracks with many elements [NI-TRANS] | Already-sparse material (nothing to gain) |
| Loop roll | Loop of the outgoing halved 8→4→2→1 before a release | Builds into a drop, sparingly; "gimmicky if overused" [VIBES-TRANS] | Over a vocal; more than about once a set [NAJADE-FX] |
| Drop swap | Outgoing build, cut on the incoming's drop | Drop-based genres, peak time | Pop; tracks without a clear drop |
| Double drop | Drops of both tracks aligned and played together | Drum and bass, dubstep, hard techno; needs exact phrase alignment and drops that fit harmonically and rhythmically [DJS-DNB, BMG-DD, VV18] | Anything with vocals in either drop; general house |
| Spinback / brake | Deck pulled back or slowed on the final beat | A deliberate show moment in hip-hop, dancehall, open-format [DDP-TRANS, VIBES-TRANS, DJRP] | In a flowing club set; mid-phrase ("clumsy rather than cool") [DJL-TRANS]; repeatedly ("cliché") |

Frequency: one working guide suggests that in a 90-minute set "perhaps six echo-outs, two or three reverb washouts into breakdowns, and one loop roll" [NAJADE-FX]. The general warning across sources: once the room hears the technique rather than the music, it is overused [MG-TRANS].

## 7. Set structure

- **Energy arc.** A set is a journey: build gradually, peak, give the room space, lift again; plan 2–3 anchor tracks to build towards [PB-SET]. Shape it "like a wave, not a ramp": deliberate dips of two or three levels, then a higher peak [OKS-ENERGY]. Climb one level at a time, drop more freely [VIBES-ENERGY].
- **Warm-up vs peak time.** Warm-up starts low (about 2–4 of 10) and rises to 7–8; peaking early is "the cardinal sin" [SETFLOW-ENERGY, EDMGP-SET]. Peak time holds 8–10 with variety [SETFLOW-ENERGY]. In a 60-minute set the peak belongs in the last third [DJL-SET].
- **Not draining energy.** Mixing only outros into intros keeps energy flat [DJTT09]; an echo out at peak deflates [VIBES-TRANS]. Each track should get to its payoff before it leaves [DJTT09].
- **Track order.** Spotify sequences playlists as a shortest Hamiltonian path over tempo, key, loudness and timbre distances [B17]. DJ-MC learns preferences for songs and for transitions and found listeners rewarded good transitions beyond song choice alone [DJMC]. Vande Veire and De Bie pick the next song by key compatibility, a "theme" vector (energy and spectral content) and the most similar onset pattern, and plan transition types with a Markov chain: from relaxed, 70% rolling and 30% double drop; from rolling, 80% rolling and 20% relaxed [VV18, VV18-BLOG].

## 8. Automatic DJ systems

| System | Cue points | Features | Notes |
|---|---|---|---|
| Spotify, research (Bittner et al. 2017) [B17] | Downbeats only; exit in the last 25%, entry in the first 20%; strongest candidates are drops, then section boundaries, then downbeats; penalty when the overlap doesn't end on a boundary in both tracks | Beat-synchronous timbre, chroma, loudness, per-beat vocal probability; drops from listeners' scrub (seek) data | 64% good, 28% OK, 8% bad from curators; faults were beat errors and mid-vocal transitions, never key |
| Spotify Mix (2025) [SP-MIX, TG-MIX] | Auto picks a style "based on the key, tempo, and other musical attributes"; user can move points on the waveform | Beat data, Camelot key, BPM | Presets Fade, Rise, Blend; EQ options centre bass, end bass swap, 3-band fade |
| Apple Music AutoMix (iOS 26) [AI-AUTOMIX, MO-AUTOMIX, TR-AUTOMIX, HTG-AUTOMIX] | Not documented; "time stretching and beat matching", trims silence, falls back to crossfade, off for albums | Not documented | Common complaints: starts too early, cuts the last 30 s, enters the next song 49 s in skipping the first verse, sometimes "straight to the first chorus". A cautionary example of what our owner described |
| rekordbox Automix [RB-FORUM, RB-NOTE] | From phrase analysis: mixes from the OUTRO phrase into the INTRO phrase; editing points means editing phrases | Phrase analysis (Intro/Up/Down/Chorus/Bridge/Verse/Outro, mood High/Mid/Low) [RB-PHRASE] | Fixed transition time; tempo sync only within ±6–8% |
| djay Automix AI [ALGO-AUTOMIX, ALGO-FORUM] | "Analyzes tracks and selects smooth transition points"; entry and exit regions shown on the waveform | Not documented; transitions include filter, echo, riser, Neural Mix | Users report good intros, poor exits that pass "several decent break points"; asked for "no vocals, just beats" exits |
| Serato DJ Pro [SERATO] | None | None | No auto-blend: Autoplay plays tracks back to back |
| DJ-MC (Liebman et al. 2015) [DJMC] | No cue points; sequence only | 340-dimensional song descriptors and transition descriptors | RL over song and transition preferences |
| Vande Veire & De Bie 2018 [VV18, VV18-BLOG] | Segments high/low energy; boundaries on downbeats, a whole number of phrases apart; cue 16 measures before a drop (double drop), 32 before a high-to-low boundary (rolling), 16 before it (relaxed); fade-in 16, fade-out 32 measures | Beats, downbeats, structure (Foote novelty plus rules), vocal activity, key, theme vector, onset pattern | 91% of songs fully correctly annotated; 18 DnB fans rated mixes highly |
| Zehren et al. 2020/2022 [Z20, Z22] | Rule 1 novelty (rhythm, loudness, timbre, harmony); Rule 2 on the downbeat at the start of a 4-bar period; Rule 3 the following section must "stand on its own" (salient, loud) | Drum transcription, HPSS loudness, CQT, chroma, 8-bar checkerboard novelty | 86% precision, 49% recall; about 96% of points judged usable |
| Kim et al. 2020 [K20] | Analysis of real mixes, not a system | Beat-synchronous chroma and MFCC, subsequence DTW | Phrase-quantised transition lengths, cue agreement, tempo and key statistics (above) |
| Mosaikbox 2024 [MOSAIK] | Rule-based | Stems (vocals, drums, bass, other), precise beat grid, harmonic compatibility | Vocal stem modified when vocals overlap > 2 s; transitions of 16 downbeats |
| DJustify 2026 [DJUSTIFY] | Cues restricted to "anchors": phrase ends, section boundaries, harmonic restarts, low-frequency onsets | Beats, downbeats, functional structure (All-In-One [KN23]), chords, per-frame singing-voice activity (CRNN on Jamendo) | Renders, then checks: cut mid-phrase, vocal collision, energy hole, early cut / late entry, entry stuck in intro; repairs up to 4 rounds. "Most of the margin comes from cue placement" |

What the successful systems share: candidates only on downbeats at phrase or section boundaries; a vocal activity curve per beat or frame; structure labels from a segmentation model, not from position in the file; costs for overlaps that don't end on a boundary in both tracks; and, in the newest work, a check of the rendered audio with repair. Vocal detection itself is a mature task: CNN singing-voice detectors reach about 90% frame accuracy on Jamendo [SG15, LCN18]; All-In-One predicts beats, downbeats, segment boundaries and functional labels (intro, verse, chorus, bridge, outro, and so on) in one model trained on the Harmonix set [KN23].

---

## 9. Rules for our planner

Priority: **H** hard rail (a plan that breaks it is not proposed; if nothing passes, step down the safety ladder), **S** strong preference (scored, heavily weighted, may be broken only when no plan satisfies it), **N** nice to have.

Definitions used below:
- *Phrase line*: a downbeat whose bar index, counted from the track's measured phrase anchor, is a multiple of 8. The phrase anchor is the nearest section boundary, not the first downbeat or the end of the file.
- *Vocal activity* `v(b)`: probability that a lead vocal (sung or rapped, not a one-shot chop) is present in beat `b`, 0–1. *Vocal beat*: `v(b) ≥ 0.5`. *Vocal phrase*: a run of vocal beats, merging gaps shorter than 1 bar.
- *Audible*: the deck's post-fader, post-EQ level in the 250 Hz–4 kHz band is within 12 dB of the louder deck in that band.
- *Overlap*: the span where both decks are audible.
- *Payoff*: the track's last chorus or drop section, or (with no labels) its last vocal phrase or last highest-energy phrase.
- *Runway*: the number of consecutive bars at the end (outgoing) or start (incoming) of a track with no vocal beats and no payoff section.

### Grid and phrase

1. **H.** Every audible event (deck start, fader, EQ, filter, FX on or off, cut) lands on a measured downbeat of the deck it affects. *Needs: downbeats.* (Existing rail, §6.3.)
2. **H.** The outgoing's blend start and the incoming's entry are both phrase lines of their own tracks. *Needs: downbeats, phrase anchor from section boundaries.*
3. **H.** Overlap lengths are 4, 8, 16, 32 or 64 bars; 4 bars only for short moves on pop or vocal material. *Needs: downbeats.* Supported by the 32-beat peaks in real mixes [K20].
4. **S.** Sections change together: the blend's handover (the bass swap, or the fader midpoint without one) and its end each fall within 1 bar of a section boundary in both tracks. Choose `(exit, entry, length)` jointly so `exit + length` lands on the outgoing's next boundary (or the end of its audible content) and `entry + length` on one of the incoming's. *Needs: structure segments with boundaries.* [B17, VV18, WIKI-PHR]

### Where to leave and where to land

5. **H.** Play the payoff: the outgoing's blend starts no earlier than the end of its payoff section, unless a user cue, Mix Now or an Adventurous move says otherwise. *Needs: structure labels or energy curve, vocal activity.* [DJTT09]
6. **H.** Don't skip the incoming's opening for Smooth and Club: its entry is its first downbeat or a phrase line inside its intro (labelled intro, or the leading runway). Later entries only for a user cue, a drop-in whose entry is the start of the build, or Adventurous. *Needs: structure labels, vocal activity.* This is the Apple AutoMix complaint ("49 seconds in… skipping over the first verse") [TR-AUTOMIX].
7. **S.** Prefer outgoing outro over incoming intro; then outgoing breakdown into incoming intro or build; then outro into the incoming's first verse. Score pairings by section kind, not by position in the file. *Needs: structure labels.*
8. **S.** Outro and intro are recognised by content: a span at the end (start) of the track with no vocal beats and falling (rising) density, measured from the music, not "the last 12% of the file". *Needs: structure segments, vocal activity, energy curve.*
9. **H.** Trailing silence and fade-outs: the exit is taken before the outgoing's audible end or its fade-out begins (radio edits fade). *Needs: loudness envelope.*

### Vocals

10. **H.** No two lead vocals audible at once for more than 1 beat, in every move, play-out blends included. *Needs: vocal activity on both decks.* (Existing in `DJMoveRails` when both decks are measured; see gaps 1 and 2 for when they aren't.)
11. **H.** Let the outgoing vocal finish: no event that lowers the outgoing by more than 3 dB in the vocal band, cuts its mids, swaps dominance, or cuts or echoes it out, may occur while the outgoing is inside a vocal phrase. The cut or echo throw goes on the last beat of a vocal phrase or later, on a phrase line. *Needs: vocal activity, downbeats.* [MG-VOX, DJUSTIFY]
12. **H.** Land the incoming vocal cleanly: the incoming's first audible vocal beat is the first beat of one of its vocal phrases, and it starts only once the outgoing has had no vocal beats for at least 1 bar and is at least 12 dB down in the vocal band. *Needs: vocal activity on both decks.* [MG-VOX, DJTT09]
13. **H.** Unknown vocals are assumed present. If either deck has no vocal measurement, the overlap is capped at 8 bars for every move, the incoming's mids stay cut by at least 9 dB until the outgoing is out, and echo out or an 8-bar blend at the outgoing's audible end is preferred over a 32-bar blend. *Needs: nothing; this is the rule for missing evidence.* (Starting value 9 dB.)
14. **S.** Runway decides the move: the overlap may not exceed `min(outgoing runway, incoming runway)` rounded down to an allowed length (rule 3). With runway of 16 bars or more on both sides, blend. With less on either side, use rule 15. *Needs: vocal activity, structure.*
15. **S.** Vocal-heavy fallback (pop, radio edits, vocal house without instrumental intro or outro): echo out on the last beat of the outgoing's final chorus or vocal phrase, incoming on the next phrase line; or a 4–8-bar blend with the incoming's mids cut, timed so the incoming's first vocal starts as the outgoing's last vocal phrase ends. *Needs: vocal activity, downbeats, structure labels for chorus.* [DJTT09, DDJT-5]
16. **N.** Acapella-style layering (one deck's vocal over the other's instrumental for longer than 8 bars) only in Adventurous, only where the other deck has no vocal beats in the window, keys within one Camelot step, and stems are available. *Needs: stems, vocal activity, key.* [DDJT-ACA, DJCITY]
17. **H.** No loop, loop roll or deadline loop over a vocal phrase. *Needs: vocal activity.* (Existing for loop builds; missing for the deadline loop, §6.9.)

### Bass, EQ and level

18. **H.** One bassline at a time: the incoming's low band stays at kill (−24 dB or below) until the swap; the swap takes at most 1 beat and sits on a phrase line; the outgoing's lows are killed in the same beat. *Needs: downbeats; bass activity helps place it.* [DDJT-5, DJS-EQ]
19. **S.** The swap goes on the incoming's own section change where possible (its first bass entry or drop downbeat), otherwise at the midpoint phrase of the blend. *Needs: structure, bass activity.*
20. **S.** Mid swap when both decks carry melodic or vocal content in the overlap: one deck's mids at least 6 dB down at any moment, swapped on a phrase line. *Needs: harmonicity or vocal activity per section.* [MG-VOX]
21. **H.** Level continuity: short-term loudness through the move dips no more than 1.5 LU below the lower of the levels before and after, and swells no more than 3 LU above the higher, except where the move's shape is the dip (breakdown exit, builds), which have their own gates. *Needs: loudness normalisation.* (Existing gates, §6.8.)

### Key

22. **H.** A blend longer than 4 bars where both decks are harmonic in the overlap (pads, chords, bassline or vocals) needs a Camelot distance within the profile's limit after any varispeed. *Needs: key, per-section harmonicity.*
23. **S.** Percussive overlaps waive the key rail: if one deck is drums-only for the whole overlap (harmonic-to-percussive energy below a threshold), key distance is not scored. *Needs: harmonicity per section (HPSS ratio or chroma clarity).* [B17, MIK-KEY]
24. **N.** Energy-boost key moves (+2, or +7 for one semitone) at most twice an hour, on a short overlap or a cut into a drop. *Needs: key.* [MIK-5, HM-BOOST]

### Tempo

25. **H.** A beat-matched blend needs native tempos within the profile's limit (Smooth ±2%, Club ±4%, Adventurous ±8%), with key lock, and no rate change faster than 0.5% per bar. 2:1 bridges need a folded residual under 1%. *Needs: tempo map.* (Existing; consistent with [K20], [CROSSFADER].)
26. **S.** Across a set, drift the master tempo by about 1 BPM per transition at most when following the energy arc. *Needs: tempo.* [VIBES-TRANS, SETFLOW]

### Choosing the move

27. **S.** Choose the move from the material, in this order: both runways ≥ 16 bars, keys and tempos fit: long blend with bass swap. Busy tracks (high onset density in both): filter fade. Short runway or vocal at the boundary: rule 15. Tempo or genre jump beyond the blend limit: echo out or reverb wash into the incoming's first downbeat. Incoming opens on a drop or hook at bar 1 and the outgoing is at a phrase end: cut on the one. Labelled build and drop on the incoming, Club or Adventurous: drop-in. Double drop only for drop-based genres with no vocals in either drop. *Needs: structure, vocal activity, onset density, key, tempo.*
28. **H.** No spinback or brake in Smooth or Club. *Needs: nothing.* [DJL-TRANS, DJRP]
29. **S.** Effect budget per hour, starting values: echo outs ≤ 4, reverb washes ≤ 2, loop builds ≤ 1 (Club 0), risers ≤ 3; the same move twice in a row costs extra. *Needs: history.* [NAJADE-FX, MG-TRANS]
30. **S.** No echo out or reverb wash when the target energy is at or above the current energy and the set is at peak (energy ≥ 8). *Needs: energy curve, arc.* [VIBES-TRANS]

### Set

31. **S.** Energy steps up by at most one level per transition, down by up to three; the peak sits in the last third of a Follow the Night block. *Needs: per-section energy (not LUFS).* [VIBES-ENERGY, DJL-SET]
32. **N.** Use listening heat (seeks and replays, SoundCloud comment density) to find hooks and drops: heat peaks are payoff candidates the outgoing must reach (rule 5) and the incoming must not be entered in the middle of. *Needs: heat.* [B17]

### Missing evidence

33. **H.** Missing evidence steps the move down, never up: no measured downbeats on either deck: echo out or fade at the outgoing's audible end and start the incoming on its first downbeat (no overlap). No structure: play out to the last 16 bars of audible content and blend for at most 8 bars (rule 13). *Needs: provenance flags.*

---

## 10. Gaps against our current spec

Checked against `automix-overhaul.md` and the code it describes (`DJ/DJTemplates.swift`, `DJ/DJScoringTerms.swift`, `DJ/DJMoveTemplates.swift`, `DJ/DJSessionDirector.swift`, `DJ/DJProfiles.swift`). The first five are the likeliest causes of what the owner heard.

1. **The TV has no vocal measurement, and play-out blends ignore unmeasured vocals.** Vocal ranges come only from MusicUnderstanding instrument activity (`AnalysisProducers.swift`, `vocalRanges: instrumentRanges(.vocal)`), which doesn't run on tvOS (§1.3). The TV beat tracker (§5.5) stores flux bands, chroma and band energies, with no vocal feature. When either side is unmeasured, `SpectralClashTerm` returns `.unmeasured` and costs nothing, the overlap veto in `DJMoveRails` is skipped, and the 8-bar unmeasured cap applies only to plans with a move (`plan.move != nil`); §6.8 exempts play-out blends on purpose ("the play-out blends keep their phase B lengths"). So on the TV, with real music, the planner runs 32-bar blends with no knowledge of vocals at all. Breaks rules 10–13.

2. **Only two-deck overlap is checked.** With both decks measured, `DJMoveRails` vetoes more than a beat of vocal overlap, which is right. Nothing checks the single-deck faults the owner named: leaving the outgoing inside a vocal phrase or hook (rule 11), or landing the incoming inside one (rule 12). A blend can start mid-chorus on the outgoing and bring the incoming in on its own chorus, and pass, as long as the two vocals take turns within the overlap window; and the window is the fader overlap, so a vocal cut by the fader closing mid-word is never seen.

3. **Exits are counted back from the end of the file, and "outro" means position.** `exitCandidates` places play-out exits at `duration − {16, 24, 32, 40, 48, 64}` bars snapped to the nearest phrase start, and `outroFit` rewards 16–48 bars remaining whatever is there. On the TV path, `classifyStructure` labels any phrase in the last 12% of the file "outro" by position and loudness. For a 3:30 pop remix or a radio edit, 32 bars before the end at 124 BPM (62 s) is the final chorus: the planner starts a long blend over the hook. Breaks rules 5, 8 and 14.

4. **Entries can land mid-track, in a chorus.** `entryCandidates` admits every labelled section start up to `entryRegionCeiling` (Club 35%, Adventurous 55% of the incoming track) at confidence 0.85, above the track start at 0.6. On the TV those "sections" are each 8-bar phrase classified by loudness against the median; on Mac/iPhone, MusicUnderstanding's sections are mostly uniform 8-bar chunks (`mu-findings.md`). A loud phrase a minute in, which in vocal music is usually the chorus, is labelled `drop` or `bridge` and offered as an entry with a higher confidence than bar 1. This matches "right into a lyrics peak of another" and the Apple AutoMix complaints. To confirm with renders of real pairs, but the code permits it. Breaks rule 6.

5. **Structure labels have no vocal axis and come from loudness.** `SectionKind` (intro, buildup, drop, breakdown, bridge, cooldown, outro) can't tell an instrumental intro from a sung one, or a verse from a chorus; rekordbox's Mid/Low moods exist for exactly this (verse, chorus, bridge). `StructureTerm` gives outro→intro a cost of 0 even when both are full of vocals. Section kinds come from mean envelope relative to the median and position, which §2.1 itself says should be replaced ("not loudness against the median"). Breaks rules 7 and 8.

6. **Phrase alignment is only 8-bar, and the phrase anchor is weak.** `PhraseTerm` folds offsets modulo 32 beats (8 bars), so a blend that starts 8 bars into a 16-bar section scores as perfectly phrased. The tracker sets `phraseOffsetBars` only "when the evidence is clear" (§5.5), otherwise phrases count from the first downbeat, which may be 4 bars out from the arrangement. Breaks rules 2 and 4.

7. **No "sections change together" term.** Exit, entry and length are chosen and scored separately (phrase term, structure term, length from the profile's bar range). Nothing rewards the blend ending on a section boundary in both tracks, which Spotify's planner explicitly scores [B17] and Vande Veire and De Bie build into their cue offsets [VV18]. Breaks rule 4.

8. **Blend length is set by style, not by the music.** Club blends are 16–32 bars for every pair (§7: Blend caps the style's range). There is no runway limit (rule 14) and no genre or arrangement dependence: pop and vocal tracks get the same 32-bar blend as melodic techno. The Blend setting is a cap, but the planner should fit the length to the available instrumental runway under that cap.

9. **No vocal-aware fallback.** The ladder (§2.2) is blend → filter or echo → phrase-aligned cut, with no rule about where the echo or cut falls relative to a vocal phrase or chorus end, and no "first verse starts as the chorus ends" timing (rule 15).

10. **Club can leave before the payoff.** Club's `exitRegionFloor` is 0.45 and `minimumPlayFraction` 0.55; exits come from phrase lines and envelope candidates, with no check that the last chorus or drop has finished (rule 5).

11. **The key rail ignores what is in the overlap.** It applies to any blend over 4 bars, so a drums-only intro over an outro in a distant key becomes a cut or echo, while two vocal choruses in compatible keys pass (rules 22, 23). TV keys come from the legacy analyser as one key per track.

12. **The deadline loop doesn't check vocals** (known, §6.9). Breaks rule 17.

13. **Energy is LUFS-based** (known, §1.7, §7). Rules 30 and 31 need per-section energy.

14. **Imported rekordbox phrases are not used as structure.** We already read and write rekordbox PSSI phrase tags (`dj-usb-format.md`), and §2.2's cue hierarchy includes "imported rekordbox cues", but nothing feeds rekordbox's phrase labels (Intro/Verse/Chorus/Up/Down/Outro) into `TrackFeatures.sections`. For a DJ owner with a prepared library this is the best structure we can get, and it is how rekordbox's own Automix chooses points [RB-FORUM].

15. **The harness can't see these faults.** It measures vocal overlap seconds on one synthetic vocal pair (gate ≤ 0.5 s), but not vocal cuts, mid-phrase entries, skipped intros, payoff reached, or section alignment; fixtures have no verse/chorus structure, and there is no real-music corpus with labels (§3 "Not yet covered"). Every gate passes while the owner hears the fault.

**What analysis this needs, in order of value:**
- A vocal activity curve per beat on every platform, the TV included. Options, all to evaluate: a small singing-voice-detection CNN in Core ML (the Schlüter-style models are small and reach about 90% frame accuracy [SG15]); the vocal stem energy from a separation model run off the TV and synced like the tracker results; or Apple's SoundAnalysis built-in classifier, if its singing and speech classes prove usable and it is available on tvOS (not verified).
- Functional structure (intro, verse, chorus, build, drop, breakdown, outro) from content: an All-In-One-style model run on Mac/iPhone and synced [KN23], and imported rekordbox phrases where present.
- Per-section energy and harmonicity (HPSS ratio, chroma clarity) for rules 22, 23, 30 and 31.

---

## 11. Evaluation: how to judge a transition

The harness already gates timing, phase, loudness, bass clash and clicks well. What it lacks is the musical judgement the owner applies. Each metric below is computed per transition from the rendered mix, the solo stems and the tracks' labels (true labels on fixtures, the owner's labels on the real corpus).

**New per-transition metrics and starting gates:**

| Metric | Definition | Gate (Club) |
|---|---|---|
| Vocal overlap | Beats where both decks have vocal beats and both are audible (§9 definitions) | ≤ 1 beat (rule 10) |
| Outgoing vocal cut | Beats of outgoing vocal phrase remaining when the outgoing first drops ≥ 3 dB in the vocal band, is cut or echoed | 0 (rule 11) |
| Incoming mid-phrase entry | Whether the incoming's first audible vocal beat is not the first beat of a vocal phrase | false (rule 12) |
| Incoming vocal before outgoing clear | Bars between the outgoing's last vocal beat and the incoming's first audible vocal beat | ≥ 1 bar (rule 12) |
| Payoff reached | The blend starts after the end of the outgoing's payoff section | true (rule 5) |
| Opening skipped | Bars of the incoming skipped before the entry, beyond its labelled intro | 0 (rule 6) |
| Phrase position | Exit and entry bar index mod 8 against the labelled phrase grid | 0 (rule 2) |
| Section alignment | Bars between the blend's end (and its swap) and the nearest section boundary, each track | ≤ 1 bar (rule 4) |
| Overlap length | Bars, and whether it is an allowed length | in {4, 8, 16, 32, 64} (rule 3) |
| Runway use | Overlap bars minus the smaller runway | ≤ 0 (rule 14) |
| Mid clash | Bars where both decks' 250 Hz–4 kHz levels are within 6 dB and both are harmonic | ≤ 2 bars (rule 20) |
| Harmonic clash | Chroma-based dissonance across the overlap where both decks are harmonic | report, then gate once calibrated |
| Existing | Landing, phase, downbeat offset, dip, swell, true peak, bass clash, clicks, tempo after | as §3 and §6.8 |

**Per-set metrics:** move mix and effect counts per hour against rule 29; energy track error against the arc; tempo drift per transition (rule 26); repeated moves in a row.

**Fixtures.** Add synthetic tracks with verse/chorus structure and labelled vocal phrases: a radio edit (4-bar intro, vocal from bar 5, fade-out ending), a vocal house extended mix (32-bar instrumental intro and outro, vocal sections in the middle), a pop remix whose final chorus ends 24 bars before the file end, and a track whose loudest phrase is a sung chorus 60 s in. Each must produce a plan that passes the gates above, and the current planner should fail at least the last two, which proves the gates bite (as `deadline-control` does in §6.9).

**Real-music corpus.** The owner's own tracks, labelled once: sections (rekordbox phrase export where he has it, corrected by hand), vocal phrases, and the payoff. Report every metric above on 30+ real pairs spread across house, techno, melodic/progressive, pop remixes and one set. This is the gate that matters: synthetic fixtures already pass while the music fails.

**Listening.** Blind ratings by the owner on a 3-point scale (good, OK, bad) with a fault tag, as Spotify did with curators [B17]: beats, vocal clash, vocal cut, wrong section, energy drop, key clash, level. Ship target, starting value: no "vocal clash" or "vocal cut" tags, and at least 85% good or OK. DJustify's result is a useful prior: most of the quality comes from cue placement, not from the effect chosen [DJUSTIFY].

---

## 12. Mid-track moves: playing with a track between transitions

A DJ doesn't only touch a track at the mix. Between transitions they sometimes roll a loop into a drop, sweep a filter into a phrase, or throw an echo on the last beat. The tutors agree on one thing above all: do it rarely, on the phrase, and with a reason. The engine side is `MixPerformance.swift` (planner, move data, timelines) and `MixEngine+Performance.swift` (schedule and cancel).

**Techniques DJs actually use** (sources: [DJL-FX], [NAJADE-FX], [DDT-LOOPS], [DDT-FX3], [EDMGP-FX], [SETFLOW-FX], [DJTIPS-SPIN], [VIOLET], [GREENHITZ]):

| Technique | When | Length | Typical settings | How often | Genre |
|---|---|---|---|---|---|
| Loop roll | Last 1–2 bars before a drop or phrase change | 1 bar, halving to 1/2, 1/4, 1/8; release exactly on the one | Momentary (slip): the track keeps running underneath, so it lands where it would have been | 1–2 an hour, or one a set | House, techno, EDM |
| Loop or loop build | Last 1–2 bars of a phrase, or an intro held until its bass arrives | 1–2 bars | Must stay in sync; nothing may jump in level at the restart | Once or twice a set | Electronic |
| HPF build | Into a drop or phrase, starting and stopping on phrase boundaries | 4–16 bars | About 300–500 Hz, up to 1.5–2 kHz at the extreme; little resonance | Filters are used all set, but they are the easiest effect to overuse | Mostly electronic |
| LPF dip and release | Inside a groove, opening on the next phrase | A few bars | Close gradually, open on the one | As filters | House, techno |
| Echo throw or echo-out | On the last beat of a phrase; the new phrase starts on the one | Tail of 3–4 beats, gone before it smears the next phrase | Tempo-synced, 1 beat is the safe default (1/2, 3/4 for dub swing); wet 30–40%; feedback well below runaway | About 6 in 90 minutes (mostly at transitions) | House, techno |
| Spin-back or brake | Last beat of a phrase, then a cut | A fraction of a bar | Short = abrupt, long = slowing sweep | Once or twice a set at peaks | Hip hop, open format, DnB |
| Reverb wash | Into a breakdown, or the last snare | 1–4 bar tail | Long decay, high wet, return high-passed | 2–3 per 90 minutes | Thin or melodic material |
| Bass kill before the drop | A couple of beats to 4 bars before the drop | 2 beats–4 bars | Low EQ off, back on beat 1 | Routine EQ move | House, techno, EDM |

**Timing rules.**
- Every move starts and stops on the grid and lands on the one of a phrase. Mid-phrase moves sound like mistakes.
- Echo goes on the last beat of a phrase, while the track still has energy.
- A loop or roll releases exactly on beat 1 of the next phrase, with the track where it would have been.
- Build tools (roll, HPF build) belong in the last bar or few bars before an arrival (a drop or a clear rise in level).

**Don't.**
- Two effects at once. One move at a time.
- Effects that stay on: every move fully releases on its landing.
- Effects on vocals. Tutors allow careful echo on a vocal; we don't. No move overlaps a measured vocal, and with unmeasured vocals there are no moves at all.
- Unsynced echo, runaway feedback, 100% wet, or anything that pushes the master into clipping.
- Rolls on breaks that are already exciting, or looping the end of every record.
- A loop you can hear as a loop: clipped transients, level jumps at the restart.
- An effect "because it sounds cool". Mute it in your head: if the track still works without it, it's probably fine to leave it out. If listeners notice an effect, there's probably too much.

**What we build** (setting **Performance**: Off, Subtle (default), Lively):

| Move | Shape | Placement |
|---|---|---|
| Loop roll | 2 bars before a phrase: 1 bar, 1/2, 1/4 ×2, all looping the same downbeat; HPF rises to 220 Hz (Lively 420 Hz) and sweeps back open over the last beat; clears and returns to the phrase start on the one | Only into an arrival (drop or ≥ 2 dB level step), and only when the looped bar is loopable (`loop4` ≥ 0.8) or sparse (density ≤ 0.5) |
| Filter build | HPF sweeps 4 bars (Lively 8) to 320 Hz (Lively 650 Hz), resonance 0.08; sweeps back open over the last beat, fully open on the one | Into an arrival or a 16-bar boundary |
| Filter dip | LPF closes over 3 bars on a log-frequency curve to 1.1 kHz (Lively 500 Hz, never lower), resonance 0.06; holds 2 beats, then reopens over the last 2 beats so it is fully open on the one | Only in moderate, steady material: every bar within 3 dB of the others; never into a breakdown or a level drop |
| Echo throw | Send open for the last beat only (40%, Lively 55%), 1-beat delay, feedback 0.42 (Lively 0.5); the tail rings 2 bars into the next phrase | On full bars; preferred where the next phrase drops out (breakdown or level fall) |

Rails, all enforced by the planner:
- Never in the meaty part of a track: no bar under a move may be both within 2 dB of the track's median level and dense (density above 0.5). This is the owner's rule for mixes too.
- Never within 8 bars after a drop or energy jump (a rise of 4 dB or more across two bars). A build or roll may *land* on one.
- No moves on a track without a bar profile (level and density per bar).
- Start and landing are measured downbeats, and the landing is a phrase start. Echo starts exactly one beat before it.
- No vocal within a beat of the move, including the echo's tail, and no moves when vocals are unmeasured.
- Not in the first or last phrase of the playable range, never within a bar of a transition window (`avoiding`), never in the last 4 bars of the track.
- Subtle: on about half of track plays, at most one move. Lively: on about 90%, at most two, 32 bars apart and of different kinds. A track with no clean place gets nothing.
- A seek, an unload or a new schedule cancels pending moves; Skip and the transition planner cancel whatever overlaps their window (`cancelPerformance(on:overlapping:)`).

The UI reads the schedule as data: `MixPerformanceMove` has the kind, start, landing, end and length, and `upcomingPerformance(on:)` returns the next move and the bars until it starts ("Loop roll in 8 bars").

**Verification.** `tools/AutoMixMovesHarness/run.sh <wav dir> <out dir>` compiles the render core, timeline and planner with `swiftc` (Mac only, no simulator), analyses real tracks with the TV's own beat tracker, plans moves, renders each one wet and dry through the real `MixRenderCore`, and gates:
- discontinuities: the wet second difference inside the move stays within 1.1× the dry track's own ceiling;
- true peak: the wet true peak (4× oversampled) never exceeds the dry by more than 0.5 dB, or −0.3 dBTP;
- grid: start and landing on measured downbeats, every timeline event on a half-beat of its own bar, roll rungs restart within 8 samples of the looped downbeat (cross-correlation against the dry render), and the audio nulls against the dry render after the landing (≤ −40 dB), which proves the track is back where it would have been;
- vocals: no measured vocal under any move;
- spectral flux at the release: from 2 beats before the landing to a beat after, the wet render's peak flux (positive dB change per band, 40 log bands) stays within 1.25× the larger of the dry render's peak in the same window and the dry clip's 99th percentile, so no release is harder than the music's own onsets;
- placement: no meaty bars under the move, no jump in the 8 bars before it;
- synthetic invariants: Off plans nothing, vocals unmeasured plans nothing, moves stay inside vocal-free bars, respect the gap and avoided windows.

---


## 13. Where to bring the incoming in (2026-11-08)

Why: the owner asked for the same care at the start of a track as at the end: "so a mix doesn't go into a dull, silent few seconds of a track, or into a long intro". His library is mostly house, afro house, melodic house and techno, with DJ edits and remixes.

### What DJs do

1. **The default is the top of the DJ intro.** House and techno extended mixes open with drums and little melody so they can be mixed over. Setflow: "mix in at the top of the incoming track's intro, usually drums first with little melody", and when the intro is longer than the blend, start the blend *blend-length bars before the landing*: cue bar = intro bars − blend bars + 1 [SETFLOW-WHEN, SETFLOW-TOOL]. Siren: cue at the start of the 16-bar intro for a 16-bar club blend [EDMGP-PHR].
2. **A blend can't be longer than the intro it mixes into** unless the DJ loops the intro. Looping 4–16 beats of drums is "the old-fashioned and most trusted way" to stretch a short intro [DJTT-INTRO, SETFLOW-TOOL].
3. **Cue 1 goes on the first clean beat after any lead-in or ambient intro**, tied to the phrase, not to the look of the waveform. Long spoken intros, tempo changes and live drums don't fit the template [SFCD-CUES]. Traktor's "load marker" is the track's natural start, not always its first sample [DJTT-CUES]. Mixed In Key's auto cues are placed on the grid and "usually right on phrase" [DDJT-MIK7].
4. **The usual memory cue sits 16 bars before the first drop** (green), with another at the start of the outro (red). In awkward tracks DJs cut the intro into 16- or 32-bar blocks and cue the block before the percussive section [GRASP-RB]. rekordbox phrase analysis labels Intro/Up/Down/Chorus/Outro, but the labels are often wrong [PDJ-FORUM].
5. **Length by style.** Deep and hypnotic house and techno: 32 bars or more. Most house: 16. Melodic techno: 32–64, with mids and highs over 8–16 bars and the bass swapped on the next phrase line [SETFLOW-WHEN, SIREN, MIXGRAPH-MT, DJLEARN]. Melodic techno intros are often 32–64 bars of kick and percussion, with the bass from bar 33 [DJLEARN].
6. **Pairing.** Bring the incoming intro in over the outgoing outro or breakdown, never over the outgoing drop or vocal hook [EDMGP-PHR, DJINGTIPS-5]. Instrumental into vocal is clean. Keep vocal against vocal to 4–8 bars or less [MIXGRAPH-VOX]. Don't assume every extended mix has a 16-bar intro: some open on a 1-bar vocal pickup or a 4-bar drum tag [SIREN].
7. **Afro house** typically opens with 16–32 bars of kick and percussion, then bass, then motif and chant. Percussion goes in before bass. Looping a chant-heavy intro sounds wrong [ZIPDJ-AFRO; search summary only].
8. **Energy.** Ask whether the next track raises, holds or lowers the energy. Match the entry to the outgoing's current section, and use a longer blend or a breakdown when the energy drops [MIXGRAPH-MT].

No source sets a threshold for "beatless" or "too long". The thresholds below are ours, chosen to be testable, and get tuned on the corpus.

### Rules for the entry

- **E1 H.** Never enter in leading silence or below the content floor (§ `DJContentBounds`: a quarter of the body level). Leading silence, and up to min(60 s, 20 % of the track) of material cut off by 20 s or more of silence, counts as trimmed. The track's Start time also counts.
- **E2 H.** The entry is a downbeat on a phrase line of the incoming grid.
- **E3 S. Beat-only DJ intro: keep it.** From the content start, find the first run of 4 bars with onset density ≥ 0.15 and level within 15 dB of the body: that is the groove. If the groove starts at the first bar, enter at the content start and mix over the intro.
- **E4 S. Beatless, pad or ambient intro (4 bars or more before the groove): skip it.** Enter on the first phrase line at or after the groove. Offer a second entry 32 bars before the main section.
- **E5 S. Spoken or vocal intro over no beat:** the same as E4. The vocal rails (rules 11 and 12) still forbid landing inside a vocal phrase.
- **E6 S. Long quiet build.** The groove is there, but more than half of the bars before the main section sit 9 dB or more under the body, and the main section is more than 32 bars away: enter 32 bars before the main section, and offer 16. The main section is the first run of 4 bars at density ≥ 0.45 within 3 dB of the body.
- **E7 S. Very long intro.** More than 48 bars from the groove to the main section: enter 32 bars before the main section, and offer 16, so the blend doesn't drag.
- **E8 S. Energy match.** The entry's level (relative to its own body) should be within 6 dB of the outgoing's level at the exit. Each further dB costs 0.01 of score, up to 0.08.
- **E9 N.** User mix-in cues override all of the above.
- **E10 N.** When an intro is skipped, the Up Next line says so: "Skipping the 40 s ambient intro", "Skipping the 20 s spoken intro", "Skipping the 60 s build", "Skipping 30 s of a long intro", "Skipping 4 s of silence".

The same pass added one exit rule:

- **X1 H.** A blend never starts where the outgoing drops out within its first 8 bars: a bar 15 dB or more under the body, or 2 s of envelope under the floor. This is what happens when a blend starts 2 bars before the outgoing's build gap.

- **X2 H. Drops and hooks, not loudness.** A *dip* bar sits 6 dB or more under the body level, or has its 30–150 Hz band 6 dB or more under the loud bars' median (a bass-out breakdown). Four or more dip bars make a breakdown. The first 16 bars of the loud run after a breakdown are a *drop*. A bar that is at least a quarter covered by a measured vocal, outside a dip, is a *hook*. Drops and hooks are the peaks. Every other bar is *beat-led*, however loud: on a mastered house track, that is the groove a DJ loops and exits on. The rules for the outgoing:
  - a mix can't start within 8 bars before a peak, or inside one;
  - the mix window may cover at most 1 peak bar;
  - except in Adventurous, the exit comes after the last peak.

  Loop-mix windows must be all beat-led, not just low-density. They start after the last peak, and the latest loopable window wins, so the exit is the last beat-led phrase. A cut is only for pairs where a loop or blend is impossible: no verified grid on either side, or no beat-led window. The first version of this rule counted 2.5 dB of body loudness at median density as a peak. That made almost every bar of a club master a peak and turned every real pair into a cut. The tracker now stores per-bar band energies (`BarProfile.bands`: 30–150 Hz, 150 Hz–1 kHz, 1–5 kHz, 5–11 kHz) and chroma tonality. On voodoo and marionette the band balance is flat across every loud section, so loudness and arrangement (breakdown, then drop) are what separate a drop from groove.
- **X3 S. Cuts land at full energy.** A cut on the one can't exit after the last bar that is within 9 dB of the body. It enters on the first bar within 6 dB of the incoming's body: within 2 bars, otherwise on the first such phrase line within 32 bars. A pickup bar or a quiet kick intro is skipped, and the reason line says "Cutting in 31 s in, on the first full phrase".

### Implementation and gates

- `DJ/DJIntro.swift` classifies the intro as plain, silence, beatOnly, beatless, vocal, quietBuild or long, and implements the energy term.
- `TrackFeatures.entryView` sets `contentStart` to the earliest allowed entry, so the existing entry rails apply.
- `DJPointFinder.entryCandidates` adds the 16- and 32-bar alternatives.
- `Plan.entryNote` feeds `AutoMixLive.why`.

`AutoMixTimingTests` covers six synthetic intros:
- leading silence;
- a beatless pad;
- a spoken intro;
- a 64-bar quiet build;
- a 32-bar beat-only DJ intro, which must be kept;
- a 64-bar full-level intro.

Each entry must be a phrase line inside the groove, kept intros must not be skipped, and skipped intros must carry a note. The previous planner entered all four skip cases at 0 s, so the gate catches them. On the real pack (`/tmp/automix-moves-src`), darkknight's 30 s intro is a clean kick-only DJ intro. The waveform shows it, and the planner keeps it as beatOnly. jungle opens on a beat intro under a vocal from 16.5 s, and is kept. marionette and voodoo have no intro. The pack has no ambient intro.

Renders, with the app's own section labels and fresh tracker analyses that include the band data:
- voodoo into marionette: loop mix out of voodoo's beat-led groove at 161 s, after its drop at 129–159 s, into marionette's groove at 16.8 s;
- marionette into voodoo: loop mix at 268.7 s, after the drop at 235–262 s, into voodoo at 7.7 s;
- voodoo into darkknight: a cut, because darkknight's grid isn't verified.

Over all 12 ordered pairs in the pack: 4 loop mixes and 8 cuts. Every cut involves darkknight or jungle, whose beat grids aren't phase-verified, so the planner can't beatmatch them (rule 33). Two gates. `testGateNoExitBeforeADropOrAcrossAPeak`: never within 8 bars before either drop, never over more than 1 peak bar, never a cut. `testGateLoudBeatOnlyOutroIsAValidExit`: a 32-bar outro at full loudness with no vocals is beat-led, offers loop windows and carries a mix after the last drop.

## Sources

Academic and vendor research
- [B17] Bittner et al., "Automatic Playlist Sequencing and Transitions", ISMIR 2017 (Spotify): https://archives.ismir.net/ismir2017/paper/000086.pdf
- [K20] Kim, Choi, Sacks, Yang, Nam, "A Computational Analysis of Real-World DJ Mixes using Mix-To-Track Subsequence Alignment", ISMIR 2020: https://archives.ismir.net/ismir2020/paper/000352.pdf
- [K21] Kim, Yang, Nam, "Reverse-Engineering the Transition Regions of Real-World DJ Mixes using Sub-band Analysis with Convex Optimization", NIME 2021: https://nime.pubpub.org/pub/g7avj1a7 (code: https://github.com/mir-aidj/transition-analysis)
- [KN23] Kim, Nam, "All-In-One Metrical and Functional Structure Analysis with Neighborhood Attentions on Demixed Audio", WASPAA 2023: https://arxiv.org/pdf/2307.16425 (code: https://github.com/mir-aidj/all-in-one)
- [VV18] Vande Veire, De Bie, "From raw audio to a seamless mix: creating an automated DJ system for Drum and Bass", EURASIP JASMP 2018: https://asmp-eurasipjournals.springeropen.com/articles/10.1186/s13636-018-0134-8
- [VV18-BLOG] Vande Veire, "Developing an automatic DJ system": https://lenvdv.github.io/2018-03-20-autodj/
- [Z20] Zehren, Alunno, Bientinesi, "Automatic Detection of Cue Points for DJ Mixing", 2020: https://arxiv.org/pdf/2007.08411
- [Z22] Zehren, Alunno, Bientinesi, "Automatic Detection of Cue Points for the Emulation of DJ Mixing", Computer Music Journal 46(3), 2022: https://direct.mit.edu/comj/article/46/3/67/117159/Automatic-Detection-of-Cue-Points-for-the
- [DJMC] Liebman, Saar-Tsechansky, Stone, "DJ-MC: A Reinforcement-Learning Agent for Music Playlist Recommendation", AAMAS 2015: https://arxiv.org/pdf/1401.1880
- [MOSAIK] Sowula, Knees, "Mosaikbox: Improving Fully Automatic DJ Mixing Through Rule-Based Stem Modification and Precise Beat-Grid Estimation", ISMIR 2024: https://repositum.tuwien.at/bitstream/20.500.12708/212628/1/Sowula-2024-Mosaikbox%20Improving%20Fully%20Automatic%20DJ%20Mixing%20Through%20Rule-ba...-vor.pdf
- [DJUSTIFY] Hsu et al., "DJustify: Reason-and-Verify DJ Planning for Pop Transitions and Story-Driven Sets", arXiv 2026: https://arxiv.org/html/2610.33434
- [SG15] Schlüter, Grill, "Exploring Data Augmentation for Improved Singing Voice Detection with Neural Networks", ISMIR 2015: https://grrrr.org/pub/schlueter-2015-ismir.pdf
- [LCN18] Lee, Choi, Nam, "Revisiting Singing Voice Detection: a Quantitative Review and the Future Outlook", ISMIR 2018: https://arxiv.org/pdf/1806.01180

Products
- [RB-PHRASE] rekordbox Phrase Edit operation guide: https://cdn.rekordbox.com/files/20200312172204/rekordbox5.1.0_Phrase_Edit_operation_guide_EN.pdf
- [DJL-ANLZ] Deep Symmetry, rekordbox analysis files (PSSI mood and phrase kinds): https://djl-analysis.deepsymmetry.org/rekordbox-export-analysis/anlz.html
- [RB-FORUM] Pioneer DJ forum, "Rekordbox automix": https://forums.pioneerdj.com/hc/en-us/community/posts/360000015983-Rekordbox-automix and https://forums.pioneerdj.com/hc/en-us/community/posts/360042592471-how-can-i-manage-the-automix-function
- [RB-NOTE] "Changing the crossfade timing of Rekordbox's AutoMix": https://note.com/massuumaru/n/n1662265ec84e?hl=en
- [ALGO-AUTOMIX] Algoriddim, djay Automix overview: https://help.algoriddim.com/user-manual/djay-pro-windows/mixing-basics/automix
- [ALGO-FORUM] Algoriddim community, "Automix AI break point recognition for mix out points": https://community.algoriddim.com/t/automix-ai-break-point-recognition-for-mix-out-points/42723
- [SERATO] Serato, "Can Serato DJ auto-mix my songs?": https://support.serato.com/hc/en-us/articles/202304934-Can-Serato-DJ-auto-mix-my-songs
- [SP-MIX] Spotify Newsroom, Mix: https://newsroom.spotify.com/?p=35598
- [TG-MIX] Tom's Guide on Spotify Mix: https://www.tomsguide.com/entertainment/music-streaming/spotifys-new-mixing-feature-lets-you-dj-your-own-playlists-heres-how-it-works
- [AI-AUTOMIX] AppleInsider, Apple Music iOS 26 vs iOS 18: https://appleinsider.com/inside/apple-music/vs/apple-music-ios-26-vs-ios-18-automix-liquid-glass-and-lyrics-in-your-language
- [MO-AUTOMIX] MacObserver, AutoMix explained: https://www.macobserver.com/tips/automix-explained-ios-26/
- [TR-AUTOMIX] TechRadar, AutoMix's flaw: https://www.techradar.com/audio/apple-music/apple-music-fans-are-obsessed-with-automix-in-ios-26-but-one-big-flaw-could-be-its-downfall
- [HTG-AUTOMIX] How-To Geek, disabling AutoMix: https://www.howtogeek.com/i-disabled-apple-music-automix/

DJ education
- [DJTT09] DJ TechTools, "Phrasing the Perfect Mix": https://djtechtools.com/2009/01/26/phrasing-the-perfect-mix/
- [DJTT-GAIN] DJ TechTools, "Gain Staging for DJs": https://djtechtools.com/2015/10/11/gain-staging-for-djs-staying-out-of-the-red/
- [DDJT-5] Digital DJ Tips, "The Only Five DJ Transitions You'll Ever Need": https://www.digitaldjtips.com/the-only-five-dj-transitions-youll-ever-need/
- [DDJT-ACA] Digital DJ Tips, "How To DJ With Acapellas": https://www.digitaldjtips.com/how-to-dj-with-acapellas/
- [NI-TRANS] Native Instruments, "5 basic DJ transitions": https://blog.native-instruments.com/dj-transitions/
- [MIK-5] Mixed In Key, "5 Mixing Techniques Every DJ Should Know": https://mixedinkey.com/learn-5-mixing-techniques-every-dj-should-know/
- [MIK-KEY] Mixed In Key, "How to Mix in Key": https://mixedinkey.com/workflows/how-to-mix-in-key/
- [MIK-GUIDE] Mixed In Key, harmonic mixing guide: https://mixedinkey.com/harmonic-mixing-guide/
- [MIK-COMMUNITY] Mixed In Key community, energy boost mixing: http://community.mixedinkey.com/Topics/1621
- [HM-BOOST] harmonic-mixing.com, energy boost mixing: http://www.harmonic-mixing.com/energyboostmixing.aspx
- [PB-SET] Point Blank, "How to Create Engaging DJ Sets": https://www.pointblankmusicschool.com/blog/how-to-create-engaging-dj-sets-that-keep-the-crowd-dancing/
- [WIKI-PHR] Wikipedia, Phrasing (DJ): https://en.wikipedia.org/wiki/Phrasing_(DJ)
- [MG-VOX] Mixgraph, vocal mixing for DJs: https://www.mixgraph.io/learn/vocal-mixing-guide
- [MG-TRANS] Mixgraph, transition techniques: https://www.mixgraph.io/learn/dj-transition-techniques
- [MG-MINIMAL] https://www.mixgraph.io/mixing-guide/minimal-techno, [MG-MELODIC] https://www.mixgraph.io/mixing-guide/melodic-techno, [MG-TECHHOUSE] https://www.mixgraph.io/mixing-guide/tech-house
- [MG-PITCH] Mixgraph pitch and tempo: https://www.mixgraph.io/tools/pitch-tempo; [MG-HT] half/double time: https://www.mixgraph.io/tools/half-time-double-time
- [VIBES-PHR] VibesDJ, phrase mixing: https://vibesdj.io/learn/techniques/phrase-mixing
- [VIBES-EQ] VibesDJ, EQ swapping: https://vibesdj.io/learn/techniques/eq-swapping
- [VIBES-TRANS] VibesDJ, transitions guide: https://vibesdj.io/dj-tools/dj-transitions
- [VIBES-HT] VibesDJ, halftime and doubletime: https://vibesdj.io/dj-tools/bpm-halftime-doubletime
- [VIBES-ENERGY] VibesDJ, building a set by energy: https://vibesdj.io/learn/techniques/how-to-build-a-set-by-energy
- [SIREN] Sirenmix, phrasing guide: https://sirenmix.com/blog/dj-phrasing-guide
- [SIREN-EDIT] Sirenmix, remix vs edit vs radio edit: https://sirenmix.com/blog/remix-vs-edit-vs-bootleg-explained
- [EXT] Alima Beats, radio edit vs extended mix: https://alimabeats.com/radio-edit-vs-extended-mix/
- [TECHNO-ARR] Track Sensei, arranging a techno track: https://tracksensei.com/blog/how-to-arrange-a-techno-track
- [CMUSE] CMUSE, transition bar calculator: https://www.cmuse.org/dj-transition-bar-calculator
- [EDMGP-PHR] https://edm-ghost-production.com/dj-knowledge-base/dj-phrasing-when-to-mix, [EDMGP-EQ] https://edm-ghost-production.com/dj-knowledge-base/eq-mixing-and-bass-swaps, [EDMGP-SET] https://edm-ghost-production.com/dj-knowledge-base/structuring-a-dj-set
- [DJS-EQ] DJ.Studio, EQ mixing: https://dj.studio/blog/dj-eqmixing; [DJS-DNB] mixing drum and bass: https://dj.studio/blog/mix-drum-and-bass
- [DDP-EQ] Digital DJ Pool, EQ mixing: https://digitaldjpool.com/blog/dj-eq-mixing-for-beginners/; [DDP-TRANS] transitions: https://digitaldjpool.com/blog/dj-transitions-for-beginners/
- [MIXTAPE-EQ] The DJ Mixtape, EQ in a set: https://thedjmixtape.com/how-to-use-eq-in-a-dj-set/
- [HDS-EQ] Home DJ Studio, DJ EQing: https://homedjstudio.com/dj-eqing/
- [DJL-TRANS] DJLearn, transitions: https://djlearn.de/en/dj-transitions-and-mixing-techniques; [DJL-FX] effects: https://djlearn.de/en/dj-effects-guide; [DJL-SET] building a set: https://djlearn.de/en/how-to-build-a-dj-set
- [DJRP] DJ Record Pool, transition techniques: https://djrecordpool.com/dj-transition-techniques/
- [NAJADE-2] DJ NaJade, mixing two songs: https://djnajade.com/how-to-mix-two-songs-together/; [NAJADE-FX] effects: https://djnajade.com/how-to-use-dj-effects/
- [DJCITY] DJ City, DJing with acapellas: https://djcity.com.au/blog/how-to-dj-with-acapellas/
- [BMG-DD] Beatmatch Guru, double drops: https://beatmatchguru.com/how-to-double-drop-music-tracks-in-your-dj-sets/
- [DD-DNB] see [DJS-DNB]
- [CROSSFADER] We Are Crossfader, key lock: https://wearecrossfader.co.uk/blog/key-lock/
- [OKS-BPM] OpenKeyScan, key and BPM: https://www.openkeyscan.com/key-and-bpm-guide; [OKS-ENERGY] energy-level mixing: https://www.openkeyscan.com/energy-level-mixing
- [SETFLOW] Setflow, transitions: https://www.setflow.app/blog/dj-transitions-how-to-mix-between-songs; [SETFLOW-ENERGY] set energy: https://www.setflow.app/blog/dj-set-energy-flow
- [TUNETAPPER] TuneTapper, BPM transition helper: https://tunetapper.com/tools/bpm-transition
- [DDT-LOOPS] Digital DJ Tips, three ways to use loops: https://www.digitaldjtips.com/three-ways-to-use-loops-without-annoying-everyone/; [DDT-FX3] three essential effects: https://www.digitaldjtips.com/do-you-know-how-to-use-these-3-essential-dj-effects/
- [EDMGP-FX] EDM Ghost Production, effects basics: https://edm-ghost-production.com/dj-knowledge-base/dj-effects-basics
- [SETFLOW-FX] Setflow, echo-out and filter sweep: https://www.setflow.app/blog/dj-effects-transitions-echo-out-filter-sweep
- [DJTIPS-SPIN] DJing Tips, backspins and stops: https://www.djingtips.com/how-to-dj/backspins-stops-and-power-offs/
- [VIOLET] Violet Recording, loops when DJing: https://violetrecording.com/how-to-use-loops-when-djing/
- [GREENHITZ] GreenHitz, loop rolls: https://greenhitz.com/blog/loop-rolls-extend-short-intros-mixing; filter sweeps: https://greenhitz.com/blog/filter-sweeps-smooth-vocal-transitions

- [SETFLOW-WHEN] https://www.setflow.app/blog/when-to-start-a-dj-transition
- [SETFLOW-TOOL] https://www.setflow.app/tools/when-to-mix-in
- [EDMGP-PHR] https://edm-ghost-production.com/dj-knowledge-base/dj-phrasing-when-to-mix
- [SFCD-CUES] https://sfconservatoryofdance.org/blog/how-to-set-cue-points-for-mixing/
- [GRASP-RB] https://grasp.study/modules/337acb8c-c4f7-494c-ab99-36775c2f3f27/lessons/0eeb43ff-e589-453a-b8d6-c8378fc72340
- [PDJ-FORUM] https://forums.pioneerdj.com/hc/en-us/community/posts/360000117466-Phrase-Analysis-Limits-Edit-Options
- [DDJT-MIK7] https://www.digitaldjtips.com/mixed-key-7-brings-auto-cue-points-serato-traktor/
- [DJTT-CUES] https://djtechtools.com/2013/06/03/real-uses-of-real-cuepoints/
- [DJTT-INTRO] https://djtechtools.com/2017/09/11/mixing-songs-dont-dj-intro-4-common-techniques/
- [MIXGRAPH-MT] https://www.mixgraph.io/mixing-guide/melodic-techno
- [MIXGRAPH-VOX] https://www.mixgraph.io/learn/vocal-mixing-guide
- [DJINGTIPS-5] https://www.djingtips.com/5-ways-to-mix-in-the-next-track/
- [DJLEARN] https://djlearn.de/en/dj-transitions-and-mixing-techniques
- [ZIPDJ-AFRO] https://www.zipdj.com/blog/afro-house
