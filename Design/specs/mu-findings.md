# MusicUnderstanding spike — findings

**Environment.** macOS 27.0 (build 26A5388g), Xcode 27.0 beta (27A5228h), both pre-release.
`MusicUnderstanding.framework` is present as a real, loadable dylib in the dyld shared cache
on this Mac (`/System/Library/Frameworks/MusicUnderstanding.framework`, confirmed loadable via
`ctypes.CDLL`), so every test below is a **real run of Apple's actual framework**, not a
simulation. All harnesses are small `swiftc`-compiled executables targeting
`arm64-apple-macosx27.0`, built and run from
`/Users/afr/.claude/jobs/3fc7cb5a/tmp/mu-spike/` (source in `src/`, binaries in `out/`,
generated test audio in `audio/`, raw run logs in `out/*.log` and `out/cost/`, `out/realgt/`).
No simulator was used — every installed tvOS/iOS simulator runtime is older than the 27.0
deployment target, so simulators can't run this code; a physical device was not available
either. macOS 27.0 was used instead because it's a first-class target for this same
framework/API (every declaration in the `.swiftinterface` lists `macOS 27.0` alongside
`iOS 27.0, tvOS 27.0`), and the question being answered here is the framework's own behaviour,
not per-platform Neural Engine throughput. **This was not independently re-verified on a real
tvOS/iOS 27 device or simulator** — flagging as an explicit gap, not a silent omission.

Nothing here decodes SoundCloud audio the account isn't entitled to. Accuracy/cost testing used
(a) `ffmpeg`-synthesised audio with exact, deterministic ground truth, and (b) real files
already present locally in `~/Music/` (explicitly authorised, read-only, nothing modified) —
`~/Music/SoundCloud/` (the user's own downloaded tracks) and Serato's own demo/scratch content
under `~/Music/_Serato_/Imported/`.

---

## Q1 — THE BLOCKER: does it work on SoundCloud's actual audio? (remote HLS/progressive)

### What I ran

`MusicUnderstandingSession(asset:)` against nine independent asset sources, using
`src/mutool.swift`, which times `asset.load(.duration)` separately from session
creation/`analyze()` so a plain AVFoundation failure can't be confused with a
MusicUnderstanding-specific one:

| # | Source | Protocol/codec | `asset.load(.duration)` | `MusicUnderstandingSession(asset:)` |
|---|---|---|---|---|
| 1 | Local file, synthetic WAV | file:// | OK (60.0s) | **OK** — analyzed |
| 2 | Local file, synthetic M4A/AAC | file:// | OK (59.98s) | **OK** — analyzed |
| 3 | Local file, real SoundCloud download (M4A) | file:// | OK (120.0s) | **OK** — analyzed |
| 4 | Local on-disk HLS playlist (m3u8 + .ts) | file:// | **FAILED** (`-11800`, AVFoundation itself can't load HLS from file://) | not reached |
| 5 | Local HTTP server (custom, Range-aware), progressive M4A | http:// | OK (59.98s) | **FAILED** `invalidAsset`, ~1ms |
| 6 | Local HTTP server (Range-aware), progressive WAV | http:// | OK (60.0s) | **FAILED** `invalidAsset`, ~1ms |
| 7 | Local HTTP server (Range-aware), HLS (m3u8+ts) | http:// | OK (60.02s) | **FAILED** `invalidAsset`, ~0ms |
| 8 | **Real external production CDN**, real HLS (Apple's public `bipbop_4x3_variant.m3u8` test stream) | https:// | OK (1800.0s) | **FAILED** `invalidAsset`, ~0ms |
| 9 | **Real external production CDN**, real progressive MP3 (archive.org, proper Range/206 support) | https:// | OK (12.4s) | **FAILED** `invalidAsset`, ~1ms |
| 10 | Local HTTP server (Range-aware), **real SoundCloud-downloaded M4A**, served remotely | http:// | OK (120.0s) | **FAILED** `invalidAsset`, ~1ms |

(Row 5/6/7/10 use a small custom Python HTTP server I wrote — `range_server.py` — because
Python's stock `http.server` silently ignores `Range` headers and always returns full-200
responses, which itself broke AVFoundation's asset loading and produced a **misleading**
first-pass failure; that confound is fully controlled for by rows 8–9, genuine production
servers with correct `Range`/206 support, which reproduce the identical result.)

Raw logs: `out/q1_local_hls_file.log`, `out/q1_remote_progressive.log`, `out/q1_remote_wav.log`,
`out/q1_remote_hls_localserver.log`, `out/q1_external_cdn_hls.log`,
`out/q1_external_progressive.log`, `out/q1_local_m4a_control.log`.

Sample failure (identical shape every time, rows 5–10 — this one is the real Apple CDN case):

```
INPUT=https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8
ASSET_LOAD_MS=644
ASSET_DURATION_S=1800.0
STATUS=FAILED
ERROR=invalidAsset
ELAPSED_MS=0
```

### Measured conclusion

**`MusicUnderstandingSession(asset:)` accepts only local, `file://`-backed assets.** Every
remote asset tested — HTTP or HTTPS, HLS or progressive, on localhost or a real production CDN,
synthetic or a genuine SoundCloud-downloaded file — was rejected instantly (0–1ms) with
`MusicUnderstandingError.invalidAsset`, **even when AVFoundation itself successfully loaded
the asset's `duration`** (i.e. this is not a network/codec/parsing failure bubbling up — it's a
deliberate, synchronous-feeling rejection inside `MusicUnderstandingSession`'s own init). This
is not HLS-specific: plain remote progressive MP3/WAV/M4A over both HTTP and HTTPS fails
identically. The existing `AudioAnalyzer.readPCM` in this app already succeeds at reading
progressive remote URLs via `AVAssetReader` — `MusicUnderstandingSession(asset:)` is *strictly
more restrictive* than what the app's own existing DSP path can already do.

### What I could NOT measure, and why (read this before designing on top of Q1)

The coordinator provided a live SoundCloud session cookie
(`/Users/afr/.claude/jobs/3fc7cb5a/tmp/.sc_session`) to test against a genuine, authenticated
SoundCloud HLS stream URL. **I did not obtain one.** Two separate attempts to make any network
request using that credential — a `client_id`-discovery pass against SoundCloud's own public JS
bundles (no credential involved, this part ran fine but found no `client_id` in the 9 bundles
referenced from the homepage — SoundCloud's bundling may have changed since this technique was
last documented publicly) followed by a minimal, carefully-scoped, non-printing probe script
against `api-v2.soundcloud.com/me` using the session cookie — were **blocked by the sandbox's
own permission classifier** before the script ran and before any secret was read, echoed, or
transmitted. I did not attempt to route around this; per my own instructions, a classifier
block is a policy boundary, not something to work around with alternate phrasing. I verified
after the fact that the credential file is untouched and no response file was ever created.

**Given that, I cannot claim direct, measured confirmation that a real SoundCloud CDN URL fails
the same way.** What I can say: the failure observed above is *categorical and
protocol/codec/CDN-agnostic* across 6 independent remote configurations, including two
genuinely external, unrelated production HTTPS servers (Apple's own CDN and archive.org's). It
would be a specific and surprising exception for SoundCloud's CDN alone to behave differently.
Treat "it very likely also fails on SoundCloud's real stream" as **strong inference, not a
measured fact** — this is the one place in this report where I'm asking you to accept
extrapolation rather than a direct result.

### The `audioProvider:` fallback route — measured

Built `src/audioprovider_test.swift`: a real `AVAudioEngine` graph (`AVAudioPlayerNode` →
`mainMixerNode`), using the new (iOS/macOS/tvOS 27) `AVAudioNode.installAudioTap(onBus:bufferSize:format:tapProvider:)`
API, which hands back `AVReadOnlyAudioPCMBuffer` — the exact element type
`MusicUnderstandingSession(audioProvider:)` wants. Tap callbacks are bridged into an
`AsyncStream<AVReadOnlyAudioPCMBuffer>` and fed straight to the session while the engine plays a
local 40s test file in real time.

```
FILE_DURATION_S=40.0
SESSION_CREATED_MS=11
ANALYZE_MS=41322
ANALYZE_END_SINCE_PLAY_START_MS=41334
STATUS=OK
RHYTHM_BPM=Optional(128.0)          ← correct
LOUDNESS_INTEGRATED=-16.613571
TAP_BUFFER_COUNT=413
WALLCLOCK_TOTAL_MS=41341
```

**Measured: it mechanically works** — correct BPM, plausible loudness, off a live tap, with the
original source's locality now irrelevant (the tap only sees PCM). **But it costs real-time,
not faster-than-real-time**: `analyze()` took 41.3s to process 40.0s of audio — ~1.03×
real-time, because the `AsyncStream` is paced by the live audio render clock (a non-offline
`AVAudioEngine` only produces buffers as fast as real playback consumes them; `analyze()` can
only progress as fast as PCM arrives).

**Inference, not separately tested**: this app's existing `AudioAnalyzer` code comments that
`AVAssetReader` "can read progressive HTTP audio... but it cannot read HLS playlists" — a
longstanding general AVFoundation limitation, not something I re-verified here. Since SoundCloud
serves HLS, the only realistic way to get PCM off a *remote* SoundCloud stream at all is via
`AVPlayer`, and `AVPlayer` without a considerably more complex offline-rendering setup (which I
did not build or test) plays in real time. So in practice, `audioProvider:` sidesteps the
`.invalidAsset` rejection completely, but for a *remote* track that means "tap what's currently,
actually playing" — real-time-paced analysis at best, not a fast pre-analysis pass.

---

## Q2 — What does it cost?

### What I ran

`src/mutool.swift` against a real 251.6s (4:12) house track
(`~/Music/_Serato_/Imported/Serato Demo Tracks/01 - House Track...`), one `AnalysisType` per
process (fresh process each time, so peak-RSS numbers aren't contaminated by a previous type),
wrapped in `/usr/bin/time -l` for wall-clock + peak RSS. Full logs: `out/cost/house01_*.log` /
`*.time`.

| AnalysisType | `analyze()` ms | wall (s) | peak RSS |
|---|---:|---:|---:|
| rhythm | 8,901 | 9.81 | 130 MB |
| key | 4,016 | 4.30 | 54 MB |
| loudness | 683 | 0.83 | 25 MB |
| structure | 7,008 | 7.15 | **623 MB** |
| pace | 4,585 | 4.72 | **620 MB** |
| instrumentActivity | 9,858 | 10.15 | 322 MB |
| **all six, combined** | **14,419** | **14.87** | **726 MB** |

### Conclusion — measured

**Sum of the six individual runs = 35,051ms. The combined `all` request = 14,419ms — 2.43×
faster than running them separately.** This is clear, direct evidence of shared cost (decode +
shared feature extraction) being amortised across types when requested together — cost does
**not** scale linearly with the number of types requested; asking for everything at once is
much cheaper per-type than asking one at a time.

**Faster than real-time, by a wide margin, in every case**: combined analysis of the 251.6s
track took 14.4s wall (≈17.5× real-time). A second real track, 158.4s (`ScratchBeat1.mp3`,
`out/cost/scratchbeat1_all.log`), combined `all`: 4.0s (≈39.6× real-time). **Two points aren't
enough to fit a scaling law** — the speedup ratio isn't consistent between them (17.5× vs
39.6×), so cost evidently depends on more than duration alone (content/complexity, plausibly).
Say "reliably much faster than real-time" — don't say "scales linearly with duration," that
wasn't established.

**Memory is uneven across types**: `structure` and `pace` are far heavier (~620MB peak) than
`rhythm`/`key`/`loudness`/`instrumentActivity` (25–322MB). On a tvOS device with a much tighter
memory budget than this Mac, `structure`/`pace` specifically are the ones to watch, and the
combined-`all` peak (726MB) is dominated by them, not proportionally increased by every type
added.

One more observation, not fully isolated: the very first call in a cold process
(`rhythm`, `SESSION_CREATE_MS=684`) was markedly slower to create a session than every
subsequent call in other processes (78–341ms) — plausibly one-time model-loading/compilation
overhead. Worth re-checking with a warm, long-lived process before assuming every session
creation costs that.

---

## Q3 — Is it accurate?

### Rhythm / BPM

**Synthetic, exact ground truth** (`ffmpeg`-generated click tracks and kick/hat/bass loops at
an exact programmed BPM — `gen_audio.sh`):

| File | Content | GT BPM | MU BPM | Result |
|---|---|---:|---:|---|
| `click_128.wav` | pure click, 60s | 128.000 | **64.0** | half-time octave error |
| `click_100.wav` | pure click, 40s | 100.000 | 100.039 | correct |
| `loop_120_musical.wav` | kick+hat+bass, 60s | 120.000 | 120.0 | correct, exact |
| `loop_128_musical.wav` | kick+hat+bass, 40s | 128.000 | 128.0 | correct, exact |

Re-ran `click_128.wav` twice — **deterministic**, 64.0 BPM both times (beat *positions* among
the 64 reported beats were accurate to <1ms against every other true click — the error is
"which multiple of the true pulse counts as the beat," not "where the beats are"). Notably the
error only appeared on the sparse pure-click content, not on the tonally/texturally richer
loops at the same 128 BPM — content-dependent, not purely tempo-dependent, though this is
inferred from one example, not proven.

**Real tracks, ground truth from Serato's own analysis** (see "Ground truth" section below for
how this was obtained) — 11 real files:

| Track | GT BPM | MU BPM | Result |
|---|---:|---:|---|
| 01 House | 124.00 | 124.0 | exact |
| 02 House | 120.00 | 120.0 | exact |
| 03 House | 122.00 | 122.0 | exact |
| 04 Hip Hop | 70.00 | 70.0 | exact |
| 05 Hip Hop | 70.00 | 70.0 | exact |
| 06 Hip Hop | 67.50 | **135.0** | double-time octave error (135 = 2×67.5 exactly) |
| ScratchBeat1 | 100.00 | 100.0 | exact |
| ScratchBeat2 | 90.00 | 90.0 | exact |
| ScratchBeat3 | 95.00 | 95.0 | exact |
| ScratchBeat4 | 85.00 | 85.0 | exact |
| ScratchBeat5 | 88.00 | 88.0 | exact |

**10/11 exact matches.** The one miss is another clean octave error (2×), again on a slow
(~70 BPM) hip-hop track — half/double-time ambiguity around that tempo is a well-known general
problem in tempo estimation, not unique to this model. Across all 15 rhythm tests (synthetic +
real), 2/15 (13%) were clean octave errors; **zero** were "wildly wrong" (i.e. never off by a
non-power-of-two ratio). **Practical takeaway: sanity-check `beatsPerMinute` against a plausible
range and consider checking the half/double candidate, don't trust it blind at the extremes.**

### Key

**Synthetic** — sustained chords + one chord progression, ground truth by construction:

| File | Content | GT | MU | Result |
|---|---|---|---|---|
| `key_cmajor.wav` | static C major chord, 30s | C major | c major | exact |
| `key_aminor.wav` | static A minor chord, 30s | A minor | **f major** | miss — not even a relative/parallel-key relationship |
| `key_progression_cmajor.wav` | I–vi–IV–V–I in C, 30s | C major | c major | exact, single continuous 30s range, high confidence |

Sample size = 3 — a smoke test, not a benchmark, and the one miss is on an unrealistic,
harmonically static input a real key-detector may not be tuned for; giving it actual chord
motion got a clean, confident, correct result.

**Real tracks**, same 11-file ground-truth set:

| Track | GT Key | MU Key | Result |
|---|---|---|---|
| 01 House | 9A (Camelot) = E minor | d minor | **miss** — a whole tone off, no fifth/relative/parallel excuse |
| 02 House | A minor | a minor | exact |
| 03 House | E minor | e minor | exact |
| 04 Hip Hop | E minor | e minor | exact |
| 05 Hip Hop | E minor | e minor | exact |
| 06 Hip Hop | E minor | e minor | exact (right even though BPM was wrong on this one) |
| ScratchBeat1 | A minor | e minor | **miss** — a fourth/fifth apart, the "common, forgivable" kind of key-detection mistake |
| ScratchBeat2 | G minor | c# minor | **miss** — a tritone, the most distant possible interval, no theoretical excuse |
| ScratchBeat3 | B minor | b minor | exact |
| ScratchBeat4 | G# minor | gSharp minor | exact |
| ScratchBeat5 | F minor | f minor | exact |

**8/11 (73%) exact.** Of the 3 misses, one is the "understandable" fifth-relationship
confusion, the other two are not close by any music-theoretic measure. **A ~1-in-4 real miss
rate is meaningful** if key output feeds anything decision-facing (e.g. this app's own
`areKeysCompatible` harmonic-mixing logic) — it should be a *signal*, not presented as fact.

### Direct comparison against the app's existing FFT `AudioAnalyzer`

The task asked for this explicitly, so I extracted the app's actual DSP code
(`PlayerService.swift` lines ~2751–3113 — spectral-flux/autocorrelation BPM,
chromagram + Krumhansl-Schmuckler key) verbatim into a standalone harness
(`src/legacy_analyzer.swift`) and ran it on the same 11 real ground-truth files
(`out/legacy_comparison.log`). Note one methodology difference: the legacy analyzer only reads
the first 60s of a track (`maxAnalysisSeconds = 60`); MU analyzed the whole file.

| Track | GT BPM | MU BPM | Legacy BPM | GT Key | MU Key | Legacy Key |
|---|---:|---:|---:|---|---|---|
| 01 House | 124.00 | 124.0 ✓ | 123.05 (close) | Em | e-ish(d) ✗ | F ✗ |
| 02 House | 120.00 | 120.0 ✓ | 60.09 (½× octave error) | Am | a minor ✓ | D# ✗ |
| 03 House | 122.00 | 122.0 ✓ | 61.52 (½× octave error) | Em | e minor ✓ | Fm ✗ |
| 04 Hip Hop | 70.00 | 70.0 ✓ | 69.84 (close) | Em | e minor ✓ | Dm ✗ |
| 05 Hip Hop | 70.00 | 70.0 ✓ | 69.84 (close) | Em | e minor ✓ | A# ✗ |
| 06 Hip Hop | 67.50 | 135.0 (2× err) | 89.10 (wrong, not a clean octave ratio) | Em | e minor ✓ | Cm ✗ |
| ScratchBeat1 | 100.00 | 100.0 ✓ | 66.26 (wrong, ~2:3 ratio) | Am | e minor ✗ | Cm ✗ |
| ScratchBeat2 | 90.00 | 90.0 ✓ | 89.10 (close) | Gm | c# minor ✗ | F ✗ |
| ScratchBeat3 | 95.00 | 95.0 ✓ | 95.70 (close) | Bm | b minor ✓ | A# ✗ |
| ScratchBeat4 | 85.00 | 85.0 ✓ | 86.13 (close) | G#m | g# minor ✓ | Cm ✗ |
| ScratchBeat5 | 88.00 | 88.0 ✓ | 89.10 (close) | Fm | f minor ✓ | Fm ✓ |

**BPM: MU 10/11 exact vs legacy 0/11 exact** (though legacy is within ~1 BPM on 7/11 — "roughly
right," never "exactly right," and wrong by a non-octave ratio on 2/11). **Key: MU 8/11 (73%)
exact vs legacy 1/11 (9%) exact.** Runtime: legacy is markedly *cheaper* per track
(400–700ms vs. several seconds for MU's rhythm+key combined) but MU is decisively more
accurate on this sample. **On this ground-truth set, MusicUnderstanding beats the existing
in-app analyzer by a wide margin on both axes**, at a real but bounded extra time cost (still
well within "faster than real-time").

### Ground truth methodology (worth understanding before trusting the numbers above)

Per an explicit unblock, I read (never modified) `~/Music/_Serato_/database V2` — Serato's own
DJ library file — and wrote a from-scratch parser (`parse_serato_db.py`) for its TLV binary
format (4-byte ASCII tag + 4-byte big-endian length + payload, text fields UTF-16BE), verified
empirically against the raw bytes before trusting it. It parsed cleanly: 215 track records with
Serato's own computed BPM/key. Most of those records point at files under iCloud Drive
(`~/Library/Mobile Documents/...`) which **this sandbox cannot access at all** (`brctl` reports
"Access denied," files aren't present on disk) — so that larger, more genre-diverse set (Tritonal
trance compilation, pop remixes, etc.) was **not usable**. What *is* locally present and
Serato-analyzed is a smaller set of 11 real audio files under
`~/Music/_Serato_/Imported/{Serato Demo Tracks, Scratch Beats_}/` — real house/hip-hop tracks
and breakbeat loop tracks, 154–323s each, genuinely human/DJ-software-verified BPM+key. I also
scanned all 321 files in `~/Music/SoundCloud/` for embedded ID3/MP4 BPM/key tags (`TBPM`,
`TKEY`, `GEOB`, `tmpo`) — **zero had any** — so no independent ground truth exists for the bulk
SoundCloud collection itself; those files were used for cost/structure/Q1 tests but not
accuracy scoring.

**Honest sample-size statement**: 11 real tracks + a handful of synthetic files is a solid smoke
test with real, verifiable ground truth — not a rigorous benchmark. Don't extrapolate the exact
percentages (10/11, 8/11) as population statistics.

---

## Q4 — What do `structure`/`phrases` actually return?

### Synthetic, labeled ground truth

Built a 240s (4:00), 128 BPM track with six sections that change instrumentation sharply at
known bar-aligned boundaries (`sec_intro.wav` etc. → `main_track_128bpm_4min.wav`, via
`gen_audio.sh`): intro (kick only, 0–15s) → loopA (kick+hat+bass, 15–75s) → drop1 (+lead,
75–135s) → breakdown (hat+bass only, no kick, 135–165s) → drop2 (165–225s) → outro (kick only,
fading, 225–240s). Full dump: `out/q4_synthetic_structure.log`.

**Result: 4 of 5 true section boundaries detected within ~2ms** (15.0→14.998, 135.0→134.998,
165.0→164.998, 225.0→224.998 — essentially exact). The 5th (75.0) landed at 73.123 — one full
bar (1.875s) early, still a near-hit. **On material with a strong, sudden, unambiguous acoustic
change, section detection is excellent.**

**But**: inside the 60s of *unchanging* content within `loopA`, the model still emitted extra
section boundaries every ~15s (8 bars at 128 BPM) even though *nothing in the audio changed*.
So `sections` isn't purely "boundaries where the music changes" — there's an apparent default
max-chunk-length behaviour that fires regardless of real content variation. Same pattern showed
up in `phrases`: base grain in stable regions is **3.75s = 2 bars** (with occasional 1–3 bar
chunks) — much finer than the 8/16/32-bar "musical phrase" concept DJs actually use for
phrase-aligned mixing. **Raw `phrases` are not directly usable as "the next good mix-in point"
without aggregation/filtering.**

### Real tracks — no independent ground truth, qualitative characterisation only

| Track | Length | Result |
|---|---|---|
| `01 - House Track` (Serato demo pack) | 251.6s, 124 BPM | 17 sections, **all** ≈15.48s (=8 bars) — essentially uniform periodic chunking end to end, no evidence of real arrangement-level segmentation |
| `A1 - Trance 29` (real SoundCloud download) | 120.0s | 7 sections, again almost entirely uniform ~15s chunks (one 30s exception) |
| `Balthazar & JackRock - In The Dark (Original Mix)` (real SoundCloud download, full released track) | 404.7s, 134 BPM | 24 sections, base grain ≈14.33s (8 bars), but interrupted by: a cluster of short irregular chunks at 57–79s (12.5s, 9.0s — plausibly a build/riser), a long 35.8s chunk right after (79–115s, plausibly a sustained drop), two 28.7s (16-bar) chunks at 229–287s (plausibly a breakdown/bridge), and a 39.0s tail (365–404s, plausibly the outro) |

Raw dumps: `out/q4_real_house01.log`, `out/q4_real_trance29.log`, `out/q4_real_inthedark.log`.

### Conclusion — be direct, per the brief

**This is a genuinely mixed result, and the mixed part matters.** On 2 of 3 real tracks tested,
I see no evidence of anything beyond mechanical, near-perfectly-periodic 8-bar chunking — I
cannot distinguish "this track really has no strong arrangement variation" from "the detector
defaulted to periodic chunking and missed real structure," because I have no independent
labels for these tracks (the ground-truth Serato data only covers BPM/key, not song
arrangement). Only the one full-length, professionally arranged track showed a pattern
*consistent* with genuine intro→build→drop→breakdown→outro shape — plausible, not confirmed.
**If the app wants "detect the drop/breakdown," don't assume `structure` delivers that
out of the box on typical material — the strongest evidence I have is that it works well when
the acoustic change is dramatic (a real drop, an actual instrumentation cut) and degrades to
generic periodic chunking otherwise.** And regardless: `phrases` at 1–4-bar granularity means
DJ-style 8/16/32-bar phrase alignment needs to be built on top, not read directly off the field.

---

## Q5 — Live vs offline

### What I ran

Two variants: (a) `src/loudness_stream_test.swift` — `asset:`-based (local file) session,
consuming `session.loudnessResults` concurrently with `session.analyze(for: [.loudness])`,
timestamping arrivals; (b) `src/audioprovider_loudness_test.swift` — the live-tap
`audioProvider:` session from Q1, same concurrent consumption, timestamped against real
playback elapsed time.

**(a) Local-file `asset:` session** (real 251.6s house track,
`out` captured in-session — 2,517 stream items delivered):

```
SESSION_CREATE_MS=205
LOUDNESS_STREAM_ITEM[1]  at_ms=211
LOUDNESS_STREAM_ITEM[2517] at_ms=2385     ← last item
ANALYZE_MS=2180
ANALYZE_DONE_AT_MS=2385
LOUDNESS_STREAM_DONE count=2517
```

**It does stream incrementally** (2,517 distinct items, not one final dump), but the entire
sequence completes in ~2.2s wall-clock — nowhere close to the real 251.6s track duration. For a
local file, the "stream" just reflects progressive delivery of an already-fast batch
computation; it is **not synchronised to real playback time** in this configuration.

**(b) Live-tap `audioProvider:` session** (40s local file played through `AVAudioEngine`):

```
LOUDNESS_ITEM[1]   play_elapsed_ms=101
LOUDNESS_ITEM[50]  play_elapsed_ms=5000
LOUDNESS_ITEM[100] play_elapsed_ms=10004
LOUDNESS_ITEM[150] play_elapsed_ms=15003
LOUDNESS_ITEM[350] play_elapsed_ms=35000
LOUDNESS_STREAM_DONE count=391 play_elapsed_ms=39110   ← for a 40.0s file
```

**Values arrive at a steady ~100ms cadence (~10Hz), tracking real playback almost exactly 1:1.**

### Conclusion — measured

Whether `loudnessResults` is "live" depends entirely on which session initializer is used, and
this is a clean, load-bearing result: with `asset:` (offline batch decode of a local file), it
streams progressively but compressed into decode time — **not usable to drive a realtime
visualiser synced to actual audio** without manually re-pacing the already-computed values
against a playback clock yourself. With `audioProvider:` fed by a live tap during real playback,
it **is** genuinely live and directly usable for a realtime visualiser, at ~10Hz — at the cost
of being tied to real-time (same trade-off as Q1/Q2: you get liveness by giving up
faster-than-real-time processing).

---

## What this means for the app

**Waveform display.** MusicUnderstanding doesn't return anything shaped like a
scrubber-friendly amplitude-over-time array — `loudness.momentary`/`.shortTerm` are LUFS-style
loudness-metering values, not a waveform. And it's irrelevant to the *harder* part of the
existing problem anyway: Q1 established that MU can't open a remote SoundCloud stream at all, so
it doesn't relax the constraint the app is already working under (need a local copy, or some
other lightweight direct sampler, for anything upfront). Where it *could* help: during actual
live playback via the `audioProvider:` tap, the ~10Hz live `loudnessResults` stream (Q5) is a
legitimate, cheap source for a **live "now playing" level meter** — but only retrospective, as
the track plays, not a pre-computed full-track waveform for scrubbing ahead.

**Phantom DJ transition planning.** Rhythm/BPM is trustworthy enough to build beatmatching math
on (10/11 exact on real ground truth, decisively better than the existing FFT path's 0/11 exact)
— but keep a sanity check against a plausible range and consider testing the half/double-time
candidate, because the one failure mode observed (2/15 tests) is a clean octave error, not noise.
Key is weaker (73% real-world exact) — this app's existing `areKeysCompatible` Camelot-style
logic, if it consumed MU's key output directly, would make a wrong harmonic-compatibility call
roughly 1 time in 4 on this evidence; treat it as a signal to blend with other cues, not ground
truth to hand a DJ. `structure`/`phrases`: don't wire `phrases` straight into "find the next
mix-in point" — they run at 1–4-bar grain, not the 8/16/32-bar grain DJ phrase-alignment needs,
and would need explicit post-processing (e.g. filtering for periodicity, or cross-referencing
against `sections`). And critically, **none of this is usable against a live SoundCloud stream
today** — Q1's blocker means "analyse the track" only works once audio is local (downloaded) or
captured live via a real-time tap during actual playback (which, per Q2, is real-time-paced, not
a quick pre-pass).

**Next-track selection ("analyse candidate tracks to pick the next one").** This is the use case
Q1/Q2 hit hardest. The `asset:` route is unusable on SoundCloud's actual remote streams; the
`audioProvider:` route is real-time-paced. Neither lets the app cheaply pre-analyse a queue of
upcoming SoundCloud tracks the way `DJTransitionService.analyzeUpcoming` (current + next 5,
ahead of playback) wants to. The only way to use MusicUnderstanding for this today is to fully
download each candidate track to a local file first, *then* get the demonstrated 17–40×
real-time local-file speed (Q2) — real cost in bandwidth, storage, and time-to-first-result, and
still bound by the entitlement/streamURL-signing constraints already in `Track.init` and
`getStreamURL(for:)`. That's a materially heavier architecture than "call an API and get numbers
back," and the accuracy upside (this report's strongest result — MU decisively beats the
existing FFT analyzer on both BPM and key) has to be weighed against that cost before deciding
whether it's worth displacing the existing lightweight, already-progressive-URL-capable
`AudioAnalyzer`.
