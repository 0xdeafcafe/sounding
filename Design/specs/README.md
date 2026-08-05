# Design specs — reference archive

Full text of the design/research documents produced by the agent run of **2026-08-03** (job `3fc7cb5a`), kept here so they survive the scratch directory they were written in.

> **None of this is implemented.** Every document is design or research. Where one says "no repo file was edited", that was true at the time of writing. Treat them as *arguments with numbers attached*, not as descriptions of the code.

## Why here and not `docs/`

`docs/` is the **published GitHub Pages root** — it holds `index.html`, `CNAME` (→ `sounding.forbes.red`) and `.well-known/apple-app-site-association`. Anything dropped in there is served publicly and would sit alongside the AASA. These are internal notes, so they live under `design/` with the other design material instead.

Related: the remote is `github.com/0xdeafcafe/sounding` and it serves Pages, so **assume this repo may be public**. See "What was deliberately left out" at the bottom.

## The documents

| File | What it is | Words | Status |
|---|---|---|---|
| **`dj-engine-spec.md`** | **The auto-DJ / transition engine.** Pure-core architecture, the template + scoring-term registries, the Wedding DJ / Junkie profiles, the transition catalog (T1–T11), and ~25k words of cited DJ-craft and academic research (Kim et al., Vande Veire, Bittner, Zehren, Ishizaki, Kell & Tzanetakis). **Read this first — the others assume it.** | 24.7k | design only; partially implemented since, see below |
| **`tension-gestures-spec.md`** | **In-track gestures and tension.** Mid-track moves applied to the *playing* track — filter builds, bass drops, drop-outs, loop rolls, brake. The "not predictable, not random" decision model: hard gates → seeded softmax → memory decay → rate control → arc. Composes with the transition engine and reuses its scoring machinery. | 25.8k | design only |
| **`mu-findings.md`** | **`MusicUnderstanding` spike — measured, not recalled.** Real runs of Apple's framework on macOS 27 / Xcode 27 beta. Answers: does it work on SoundCloud's remote audio (no — local `file://` only), what does it cost, is it accurate (BPM 10/11 exact, key 8/11), what do `structure`/`phrases` actually return (often generic 8-bar chunking), live vs offline loudness. **The hard constraints both DJ specs are designed around.** | 4.4k | measured findings |
| **`ios-design-spec.md`** | iPhone app design spec. Reference viewport 402 × 874 pt (iPhone 17 Pro), with formulas where a number depends on width. | 7.7k | design only |
| **`ios-ui-plan.md`** | Active follow-on implementation plan for the iPhone shell, mini player, Now Playing, browse screens, destinations, and visual acceptance matrix against the captured Apple Music iOS app. | evolving | queued after tvOS structure |
| **`tvos-ui-plan.md`** | **Active executable plan for the tvOS Library, artist/album/playlist destinations, Home, and Feed redesign.** Includes measured reference mappings, source ownership, fixture states, acceptance captures, simulator/LSP checks, and physical deployment commands. | evolving | active implementation plan |
| **`ipad-plan.md`** | iPad plan, with a CDJ-style console as the centrepiece. Companion to `dj-engine-spec.md`; "§n" unqualified means that document. | 16.0k | design only |
| **`macos-plan.md`** | macOS plan + the ecosystem-sync story. Leads with three verified feasibility answers: the shared core **does** compile for macOS (one new seam, two files touched); `MusicUnderstanding` **is** in the macOS 27 SDK and runs correctly; and **you cannot feed audio to a CDJ** — the realistic hardware subset is USB MIDI. Also records why iCloud-Keychain auth sync is rejected. Consumes `ipad-plan.md`'s console vocabulary and only documents the Mac deltas. | 6.5k | spiked; target builds, console not built |
| **`visual-audit.md`** | Read-only visual audit of the shipped tvOS and iOS UI. Every claim is a screenshot reference, a `file:line`, or a measured pixel value; inferences are marked `[inferred]`. Also grades `ios-design-spec.md`. | 8.3k | audit |
| **`watchos-plan.md`** | watchOS plan, with an honest verdict on whether to build it at all. | 8.0k | research + recommendation |
| **`watchos-haptics-findings.md`** | Can the Watch be a silent metronome tapping downbeats at ~120 BPM? Verdict: technically possible, not worth doing. | 3.0k | research |

## Reading order

1. `mu-findings.md` — what the platform can actually measure. Everything else is downstream of this.
2. `dj-engine-spec.md` — the engine, the profiles, the research base.
3. `tension-gestures-spec.md` — the mid-track layer on top.
4. `visual-audit.md` then `ios-design-spec.md` — the UI pair, audit first.
5. `ipad-plan.md`, `macos-plan.md`, `watchos-*` — platform expansion. Read `ipad-plan.md` before `macos-plan.md`: the Mac plan deliberately does not restate the console design, only where a pointer and a keyboard change it.

## `artifacts/`

Small, high-value evidence referenced inline by the documents:

- **`MusicUnderstanding.tvos.swiftinterface`** — the real tvOS 27 SDK interface dump. This is what `dj-engine-spec.md` §0.4 was verified against, and it is not otherwise easy to obtain.
- **`mu-spike/src/`** — the Swift programs that produced `mu-findings.md`, including `legacy_analyzer.swift` (the existing FFT path, for the head-to-head comparison).
- **`mu-spike/out/`** — the raw run logs behind every number in `mu-findings.md`, keyed by question (`q1_*` remote-audio, `q3_*` accuracy, `q4_*` structure, `cost/` timings).
- **`mu-spike/gen_audio.sh`**, **`range_server.py`**, **`parse_serato_db.py`** — the fixture generator, the byte-range HTTP server, and the Serato database reader.
- **`audit-crops/`** — the six cropped screenshots `visual-audit.md` cites directly.

## Known rot

These were written against a scratch directory and a moving codebase, so:

- Cross-references between the eight documents were rewritten to `design/specs/…`. **Any other absolute path in them still points at the original scratch dir and will not resolve** — notably the full screenshot set in `visual-audit.md` (only the six cited crops were kept) and the `mu-spike/` paths in `mu-findings.md` (now `design/specs/artifacts/mu-spike/`).
- `dj-engine-spec.md` §0 describes `MixEngine` as it was on 2026-08-03. **Some of what it proposes has since landed** — the low shelf has already moved 120 Hz → 200 Hz (`MixEngine.lowShelfHertz`), and `DJCore.swift` / `DJTemplates.swift` / `DJScoringTerms.swift` / `DJProfiles.swift` now exist. Read §0 as a snapshot, not as current state.
- `tension-gestures-spec.md` §2 still has four claims labelled `[R]` (recalled, unverified) — the Huron / Meyer / Farbood expectation-theory material. The literature pass commissioned to harden them returned only its *stochastic-selection and repetition* half, which is integrated and cited (§2.4, §5.3, §5.4, §10). §2.6 lists exactly what remains to upgrade or strike, in priority order.

## What was deliberately left out

Because this repo may be public:

- **`serato_db_dump.json`** — a 215-track dump of the owner's Serato library (absolute paths, titles, artists). The *aggregate* statistics the design actually relies on are already in `dj-engine-spec.md` §1.9, and `artifacts/mu-spike/parse_serato_db.py` regenerates the dump locally if it is ever needed.
- **Compiled binaries** from the spike's `out/` directory.
- **~90 MB of full-resolution screenshots** and **~170 MB of spike audio fixtures and a Python venv**. `gen_audio.sh` regenerates the fixtures.
- Home-directory paths in the retained logs were rewritten `/Users/afr` → `~`.
