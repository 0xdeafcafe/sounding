# rekordbox parity

Status: audit and first import route, 2026-11-09. Question from the owner: can Sounding replace rekordbox, with the same analysis and an import from it?

Short answer: for preparing tracks and putting them on a stick, mostly yes. Library management (My Tag, ratings, intelligent playlists, related tracks) is the gap. Sounding never opens `master.db` or the `.edb` files and won't add SQLCipher (owner decision, 2026-11-09). The import routes are rekordbox's own plain ANLZ analysis files and its collection XML.

Formats follow Deep Symmetry's public docs (dysentery "Track Analysis", crate-digger `rekordbox_anlz.ksy` / `rekordbox_pdb.ksy`) and pyrekordbox's structs, as in `dj-usb-format.md`.

## What the owner's library holds (read-only check, 2026-11-09)

`~/Library/Pioneer/rekordbox/share/PIONEER/USBANLZ/` holds 359 tracks: 359 `.DAT`, 359 `.EXT`, 359 `.2EX` and 347 `.3EX`. Every file parsed, with none unreadable and no codec issues.

| Data | Tracks | Notes |
|---|---|---|
| Beat grid (PQTZ) | 337 | All constant tempo. PQT2 (CDJ-3000 grid summary) in 329. |
| Phrases (PSSI) | 10 | 9 High mood, 1 Mid. Labels seen: Intro, Up, Down, Chorus, Bridge, Outro, Verse 1–3. |
| Vocal detection (PVDI, in `.2EX`) | 10 | Layout undocumented. Kept raw, not imported. |
| 3-band waveforms (PWV6/PWV7/PWVC) | 359 | |
| Hot cues, memory cues, loops (PCOB/PCO2) | 0 | The tags are there, but every list is empty. rekordbox 6/7 keeps cues in `master.db` and writes them into ANLZ only on USB export. |
| Key | – | Not in ANLZ. Only in `master.db` or the XML. |
| `.3EX` | 347 | MessagePack, not PMAI: an `embedding` map, likely the vectors behind Related Tracks. Never read. |

`PPTH` in the local share folder is **anonymised**: `?/<file name>`, not the full path. So matching is by file name (checked against duration), not by path. Under `~/Music`, 350 of the 359 names match exactly one file (318 in `~/Music/SoundCloud`, the rest rekordbox's own sampler and demo files), 2 match more than one file and 7 match none. 358 of the names are distinct; one track was analysed twice.

So the ANLZ files alone bring grids and phrases. **Cues and keys need the collection XML** (File › Export Collection in xml format), and the import sheet says so in one line.

## Parity table

Key: **have**, **partial**, **missing**.

### Analysis

| rekordbox 7 | Sounding | Where |
|---|---|---|
| Beat grid, constant tempo | **have**. BeatTracker, the opt-in Beat This! grid, Set Downbeat, Lock, nudge, ×2 and ÷2 in Prep. | `Core/Analysis/BeatTracker*.swift`, `Core/Analysis/AI/BeatThisModel.swift`, `Core/DJ/TrackPrep.swift` (`PrepGrid`, `PrepGridEditor`) |
| Beat grid, dynamic tempo | **partial**. `PrepGrid` holds tempo segments and imports or exports them through XML and PQTZ. BeatTracker reports `tempoSegments`, but Prep doesn't edit them and analysis doesn't write a segmented grid yet. | `TrackPrep.swift`, `RekordboxBridge.swift` (`compact`), `BeatTracker.swift` |
| Key detection | **have**: a global chroma key (`AudioAnalyzer.computeKey`), key regions from Music Understanding, shown as Camelot. Accuracy against rekordbox is **unmeasured** (see below). | `Core/Playback/AudioAnalyzer.swift`, `Core/Analysis/AnalysisProducers.swift` |
| Phrase analysis (Intro, Up, Chorus, Down, Bridge, Outro, Verse 1–6; High, Mid and Low mood) | **partial**. TrackArrangement labels bars (intro, groove, build, breakdown, drop, vocal hook, outro) from envelopes, plus stems when AI is on. It has no mood classification, and no Verse or Chorus split for vocal songs. Imported rekordbox phrases keep their exact kind and mood. | `Core/DJ/TrackArrangement.swift`, `Core/DJMedia/RekordboxShareImport.swift` |
| Vocal detection | **partial**. BeatTracker's vocal curve, Open-Unmix vocal stems (opt-in) and TrackArrangement's per-bar vocal value. rekordbox's PVDI isn't decoded. | `BeatTracker.swift`, `AI/OpenUnmixModel.swift`, `TrackArrangement.swift` |
| Waveform: blue (PWAV, PWV2, PWV3) | **have**. Computed from the file on export, and drawn in Prep and Decks. | `DJMedia/DJAudioAnalysis.swift`, `DJMediaMapping.swift` |
| Waveform: RGB (PWV4, PWV5) | **partial**. Written, but its colour is synthesised from amplitude and the 3-band energy, not rekordbox's algorithm. | `DJMediaMapping.swift` (`DJWaveformSynth`) |
| Waveform: 3-band (PWV6, PWV7, CDJ-3000) | **partial**. Real low/mid/high envelopes go into `.2EX` on export. Decks can draw 3-band, but Prep's overview is still single-band, and PWVC is never emitted. | `DJAudioAnalysis.swift`, `ANLZ.swift`, `MacDJStackedWaveforms.swift` |
| Gain and loudness (auto gain) | **partial**. Integrated LUFS from Music Understanding and Auto Mix trims. Not written to the stick. | `AnalysisProducers.swift` |

### Cues and track tags

| rekordbox 7 | Sounding | Where |
|---|---|---|
| Hot cues A–H, colours, comments | **have** | `Core/DJ/CuePoints.swift`, `CueStore.swift` |
| Memory cues, comments, colours | **have**. Memory colours map to the 8 track colours on export. | same, `DJMediaMapping.swift` |
| Loops, hot loops, memory loops | **have** | same, `LoopMath.swift` |
| Active loop, quantised beat-jump cues | **missing** | |
| Track colour | **have** (`TrackPrep.colour`) | `TrackPrep.swift` |
| Track comment | **have** | `TrackPrep.swift` |
| Rating (stars) | **missing**. Not stored. The XML `Rating` attribute is ignored. | |
| My Tag | **missing**. No tags, and `exportExt.pdb` isn't written. | `dj-usb-format.md` › Omitted |

### Library

| rekordbox 7 | Sounding | Where |
|---|---|---|
| Playlists and folders | **have**. Imported from XML and from sticks, and exported to sticks. | `RekordboxBridge.swift` (`playlists`), `CueStore+Prep.swift` |
| Intelligent playlists | **partial**. Smart Crates are fixed (Needs a Grid Check, Not on the Stick, Duplicates). There are no user rules. | `Features/DJ/DJPrepSidebar.swift` |
| History | **have**. Mixes and Recent Sets on every device, Setlists recorded from DJ Players, Played Tonight. The stick's own history table isn't written (players write it). | `Core/DJ/MixHistory.swift`, `DJLibraryPanel.swift` |
| Related tracks | **partial**. The Fits filter (Camelot ±1 or relative, tempo within 6%) and Auto Mix's planner. No similarity browser. rekordbox's `.3EX` embeddings are not read. | `DJLibraryPanel.swift`, `AutoMixNet*.swift`, `Core/Analysis/TimbreEmbedding.swift` |
| Matching and relinking files | **have**. TrackMatcher (title, artist, duration, ISRC), file links with a size-and-edges hash. | `Core/DJ/TrackLink.swift` |

### USB export

| Element | Sounding | Where |
|---|---|---|
| `export.pdb` with tracks, artists, albums, keys, colours, playlists and artwork | **have**. Byte-checked against real exports. Hardware still untested. | `DJMedia/PDB*.swift`, `DJExportPlanner.swift` |
| `exportExt.pdb` (My Tag) | **missing** | |
| PQTZ grid, PCOB/PCO2 cues | **have** | `ANLZ.swift`, `DJMediaMapping.swift` |
| PQT2 | **missing**. Read and kept raw, but not written. NXS2 doesn't need it. | |
| PSSI phrases | **have** (this change). Imported rekordbox phrases go back out with their exact kind and mood. Otherwise our TrackArrangement sections are written, when a cached analysis exists. | `MacUSBExportModel.swift`, `RekordboxShareImport.swift` (`DJExportPhrases(prepPhrases:)`), `MacRekordboxShareImport.swift` (`MacUSBArrangementPhrases`) |
| PWV6/PWV7 3-band | **have**, from real bands only | `DJAudioAnalysis.swift` |
| PVBR | **partial**. A zero index, so VBR seeking is a guess. | `ANLZ.swift` |
| SoundCloud audio | Never, outside the Personal unlock | bible §9 |

### Import routes

| Route | State | Brings |
|---|---|---|
| Collection XML (File › Export Collection) | **have** | Tracks, grids, cues, loops, key, colour, comment and playlists. Not ratings or My Tag. `MacRekordboxLibrary.swift`, `MacRekordboxSheets.swift` |
| USB stick made by rekordbox | **have** | Grids, cues, loops and playlists. Phrases aren't brought in from sticks yet. `DJStickLibrary.swift`, `MacPrepStickModel.swift` |
| rekordbox's own analysis folder (ANLZ in `share/PIONEER/USBANLZ`) | **have** (this change) | Grids, phrases, and cues when they’re there. Merged with the XML for keys, colours, comments and cues. Scanner `DJMedia/RekordboxShare.swift`; matcher and key check `DJ/RekordboxBridge.swift`; glue `DJMedia/RekordboxShareImport.swift` (Mac only); UI `MacRekordboxShareImport.swift` |
| `master.db` (SQLCipher) | **never** | Owner decision, 2026-11-09 |

## Import from the rekordbox analysis folder (built)

Settings › Library › rekordbox › **Import Analysis…** opens "Import from rekordbox":

- **Choose the rekordbox folder.** The sandbox needs the user to pick it. The panel opens at `~/Library/Pioneer/rekordbox`, the bookmark is read-only, and choosing any parent of `USBANLZ` works.
- **Read-only.** Files are opened `O_RDONLY` through `DJStickIO`, read whole and never memory-mapped. Directories are only listed. `.3EX`, `master.db` and `.edb` are never opened. Nothing is written, moved or locked.
- **Matching.** It tries these in order:
  1. the XML `Location` (a full path), when a collection XML is chosen;
  2. the file name against linked files and Music Folder files, checked against duration (PWV3 at 150 per second, ±2 s);
  3. a title match on the XML's title and artist, or on "Artist - Title" from the file name, against likes and local tracks.

  Names that fit more than one file, and a second analysis of the same file, are counted as "More Than One Match" and left out.
- **Merge.** It goes through `RekordboxImport.importMerging`, the same as stick import: the rekordbox source wins over Sounding's analysis, but user and locked values win over rekordbox. Imported cues have the `imported` origin. Phrases land in `TrackPrep.phrases` with the `rekordbox` source, and each phrase keeps its `RekordboxPhraseCode` (mood and kind) so export can rebuild PSSI exactly. Kind mapping for Auto Mix: Intro → intro, Up → buildup, Down and Bridge → breakdown, Chorus → drop, Verse → bridge (groove), Outro → outro. When the XML is chosen, its key, colour and comment come along, and its cues are used when the ANLZ lists are empty.
- **Copy.** "For cue points, keys and playlists, export your collection from rekordbox with File › Export Collection in xml format." Playlists still come in through **Import…** (XML).
- **Snapshot scenes.** `SOUNDING_TV_PREP_SNAPSHOT=rbshare|rbshare-done|rbshare-folder`.
- **Tests.** `Tests/SoundingTVTests/Sources/RekordboxShareTests.swift`.

## Key accuracy

There's a helper, `RekordboxKeyAgreement` (exact, relative and ±1 on the wheel), and the import reports "Sounding's key matches rekordbox on N% of M" for tracks that have both an XML key and a cached Sounding key. **It can't be measured on the owner's library today.** rekordbox's keys are only in `master.db` and the XML, and no collection XML has been exported. Once he exports one and runs Import Analysis…, the done screen gives the rate.

## What's left, by value

1. Measure key agreement over the owner's library, once the collection XML exists.
2. Prep's overview in 3-band, from the bands export already computes; and emit PWVC.
3. Mood (High, Mid, Low) and Verse/Chorus phrases in TrackArrangement, so tracks rekordbox never analysed get CDJ-3000 phrase lighting that's as good.
4. Ratings and My Tag: a `TrackPrep` field, XML `Rating` import, and `exportExt.pdb`.
5. Phrases from rekordbox sticks (`DJStickAnalysis` ignores PSSI today).
6. Segmented (dynamic) grids from BeatTracker's `tempoSegments`, with an editor.
7. User-rule Smart Crates (intelligent playlists).
8. Decode PVDI (vocal positions) once someone documents it.
