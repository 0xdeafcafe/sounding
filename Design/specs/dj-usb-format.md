# DJ USB export format (phase 2 core)

Status: codec, removal-safe exporter and Mac export sheet, 2026-11-06. Hardware untested.

Sounding writes the **legacy rekordbox Device Library** that CDJ-2000NXS2, CDJ-3000 and XDJ players read from USB/SD: `export.pdb` plus ANLZ analysis files. OneLibrary (`exportLibrary.db`, CDJ-3000X, XDJ-AZ, OPUS-QUAD) is out of scope. Audio only ever comes from the user's own local files (bible §13, 2026-11-06 DJ gear row). The library takes file URLs and never fetches SoundCloud audio.

## Code

`SoundingTV.swiftpm/Sources/Core/DJMedia/`, compiled into the macOS target only. The test target compiles everything except `DJMediaSoundingAdapter.swift`.

| File | Role |
|---|---|
| `DJMediaBinary.swift` | Bounds-checked byte reader/writer, DeviceSQL strings (short ASCII, long ASCII `0x40`, UTF-16LE `0x90`, ISRC variant) |
| `PDBModel.swift`, `PDBReader.swift`, `PDBWriter.swift` | `export.pdb` / `exportExt.pdb` model, reader, writer, rekordbox default rows |
| `ANLZ.swift` | `.DAT`/`.EXT` reader and writer: PPTH, PVBR, PQTZ, PCOB/PCPT, PCO2/PCP2, PWAV, PWV2, PWV3, PWV4, PWV5, PSSI (masked or plain), and the `.2EX` tags PWV6, PWV7, PWVC; unknown tags kept raw |
| `DJExportTrack.swift` | `DJExportTrack` input protocol and value types (metadata, grid, cues, phrases, waveform, key, playlists) |
| `DJMediaMapping.swift` | ANLZ folder hash, colour palettes, FAT-safe paths, grid → beats, cues → cue lists, phrases → PSSI, waveform rendering |
| `DJExportPlanner.swift` | Pure planning: ids, `/Contents/<artist>/<album>/<file>`, ANLZ paths with collision numbering, PDB rows, ANLZ files |
| `DJMediaValidator.swift` | Structural, referential and player-facing checks |
| `DJMediaExporter.swift` | Stage, verify, copy, flush, journal, commit, post-check |
| `DJVolumeFileSystem.swift` | `DJExportFileSystem` (every stick I/O goes through it), the POSIX implementation, `DJVolumeInfo` (filesystem kind, read-only, free space) |
| `DJExportRecovery.swift` | `SOUNDING-EXPORT.json` journal, read-only inspection, repair, the `._*` / `.DS_Store` scrubber |
| `DJAudioAnalysis.swift` | Detail-rate (150/s) amplitude and 3-band envelopes from the local file |
| `DJMediaSoundingAdapter.swift` | `CuePoint`, `BeatGrid`, `CamelotKey`, `TrackSection`, `TrackFeatures`, `Waveform` → export types |

The UI adapts its own `TrackPrep` to `DJExportTrack` (or uses `DJExportTrackRecord`); the library doesn't depend on `TrackPrep`/`TrackLink`.

## Layout on the volume

```
PIONEER/rekordbox/export.pdb
PIONEER/USBANLZ/Pxxx/xxxxxxxx/ANLZ0000.DAT|EXT
PIONEER/Artwork/00001/a<n>.jpg, a<n>_m.jpg   (80 px, 240 px)
Contents/<artist>/<album>/<file>
```

The ANLZ folder is `P%03X/%08X` from rekordbox's path hash of the device path (UTF-16 units, ×0x5BC9 then ×0x93B5, mod 200003, P from bits 0,2,6,7,9,13,16). Players compute this themselves, so it must match; tracks that hash to the same folder get `ANLZ0001`, `ANLZ0002` in export order.

## Export safety

1. Plan in memory; skip non-local or unsupported files (mp3, m4a/aac, flac, wav, aiff) and files over 4 GB.
2. Refuse read-only volumes and volumes without room (needed bytes plus the larger of 16 MB and 2%).
3. Stage generated files in the Mac's temp folder, then validate and re-read them.
4. Create `.metadata_never_index`, `.fseventsd/no_log` and `.Trashes` if missing, write the journal (`started`), then copy audio and generated files into `.sounding-incoming-<uuid>` on the volume, SHA-256 verifying each copy by re-reading it uncached and `F_FULLFSYNC`ing it.
5. `F_FULLFSYNC` every file and directory in the incoming tree, validate it as a player would see it, record the planned moves in the journal (`committing`).
6. Commit by rename, `PIONEER` last, `F_FULLFSYNC`ing the directory after each rename. Cancellation is no longer honoured from here.
7. Scrub `._*` and `.DS_Store` from `PIONEER` and `Contents`, sync every file and directory of the result up to the volume root, validate the final tree, write the journal (`completed`), remove the incoming folder, sync the root.
8. Any failure before step 5 deletes the incoming folder and records `rolledBack`. A failure after it runs the same recovery the next mount would.

Destinations: `.newFolder` (default; a fresh `Sounding Export <date>` folder on the volume, never touching an existing library), `.volumeRoot` (blank volumes only; refuses if `PIONEER`, `.PIONEER` or `Contents` exist), `.replaceExistingLibrary` (explicit opt-in; renames the old `PIONEER`/`.PIONEER` to `*.before-sounding-<stamp>`, adds new files to `Contents` without overwriting different ones, and refuses before touching anything if a different file is in the way). Players only read the volume root, so the UI offers `.volumeRoot` for blank sticks and explains the new-folder result otherwise.

## Removal safety

DJs pull sticks without ejecting. The rule: the stick is consistent at every moment, we hold nothing open and write nothing after an export finishes, and the one non-atomic stretch (the commit renames) is covered by a journal.

- **No automatic eject.** Success says "Done. You can unplug the stick." The sheet has a plain Eject button; it never runs by itself. Nothing touches a mounted stick in the background: no polling writes, no lazy cleanup. The watchdog during an export only stats the volume.
- **Plain POSIX I/O.** `open`/`read`/`write`/`rename`/`unlink`, never `copyfile` or Foundation's `moveItem`, so no extended attributes and no AppleDouble `._*` files. Every file is `F_FULLFSYNC`ed (falling back to `fsync` where unsupported), every directory too, before the next step.
- **Journal** `SOUNDING-EXPORT.json` at the volume root, written write-ahead (temp file, fsync, rename, fsync the root): `started` (before anything is copied), `committing` (with the exact files that will be added to `Contents` and the backup stamp), `completed`, `rolledBack`.
- **Self-heal.** Opening the export sheet on a volume runs a read-only inspection. It reports leftovers (an incoming folder, a stale journal temp file, an unfinished journal, a `PIONEER.before-sounding-*` backup with no library). Nothing is repaired until the user taps Repair, and repair follows the same flush-every-step rule. It rolls back to the old library, or rolls forward when the new library is fully in place and validates. A library that already exists is validated read-only and its problems listed in plain words.
- **Yank detection.** `NSWorkspace` unmount notifications for the exporting volume, a mount-point check and a 45 s heartbeat watchdog (no copy progress) end the export with "The stick was removed. Nothing on it was changed. Plug it back in to check it." Write errors EIO, ENXIO, ENODEV, ETIMEDOUT, ESTALE, EPIPE or a vanished volume map to the same state. A thread blocked inside the kernel on a dead device can't be interrupted; the UI abandons it. DiskArbitration callbacks aren't used: the workspace notifications cover the same events.
- **Filesystem awareness.** `statfs` classifies FAT, exFAT, HFS+, APFS, NTFS. Non-FAT/exFAT sticks get a note that DJ players can't read them; nothing is ever formatted or repaired. Files over 4 GB are left out with a message. Read-only volumes are refused. The FAT dirty bit isn't readable through public API, so we leave it alone.
- **Read paths are read-only.** The validator and `DJExportRecovery.inspect` use read-only opens and write nothing.
- **Mid-copy tear.** After a copy dies the incoming folder holds a truncated file; nothing outside the incoming folder, the journal and the three marker entries changes before the commit.

Not covered: a stick that lies about `F_FULLFSYNC` (cheap controllers), and a pull during a single rename on FAT, which the journal repairs on the next inspection but which can't be made atomic.

## What's documented and what's a guess

**Follows documentation or real exports (and is tested byte-for-byte):** file header, table directory, page header, row-count packing (13 + 11 bits), row directory groups and presence/transaction masks, index page layout, all row layouts we write, row allocation sizes, DeviceSQL strings, default colour, column and menu rows (match a rekordbox export page-for-page), ANLZ envelope and every tag we write, PSSI XOR mask, ANLZ path hash (matches three real exports).

**Guesses, flagged for hardware:**
- Page fill: we pack pages to the brim (rekordbox leaves slack); empty candidates point past EOF as rekordbox does.
- Track constants (`0x000C0700`, `0xAE49`, `0x03DD`, `0x29`, string slots 2/3 = `"2"`, u32 `0x14` = path hash) copied from rekordbox 6/7 exports, meaning unknown.
- PCOB `memory_count` (we write the entry count, `-1` when empty), PCPT order fields as a prev/next list, PCOB carries only hot cues A–C.
- PCP2: the seven bytes after the colour id (`01 00…`), 20-byte trailer, hot cue colour = nearest rekordbox palette code + its display RGB (the LED RGB table differs slightly).
- PVBR: 400 zero index entries plus MP3 frame-rounded sample count; VBR MP3 seek index not generated.
- PWV4 colour preview bytes and PWV5/PWAV whiteness are synthesised from amplitude and 3-band energy to resemble rekordbox's, not rekordbox's algorithm.
- PSSI is written masked (rekordbox 6+ style), mood inferred from phrase kinds, phrase beats snapped to our grid.
- Key names use classic notation (`Am`, `F#m`, `Db`); the player may key-match on the key id or the name.
- Memory cue colours map to the 8 track colours; album rows carry the artist id.

**Omitted:**
- `exportExt.pdb`: it only holds My Tag categories and tag links. Sounding has no tags, and rekordbox 5 exports without it play on NXS2 and CDJ-3000.
- PWVC is read and written by the codec but never emitted: the layout is documented (14-byte header with one u16, three u16 values, tag length 20) but nobody knows what it means.
- PQT2, `DEVSETTING.DAT`/`MYSETTING*.DAT`, history tables (players write those).

The reader also understands hidden `.PIONEER` exports from recent rekordbox.

## Tests (`Tests/SoundingTVTests/Sources/DJMediaTests.swift`)

`DJUSBExportRoundTripTests.swift` exports three tracks and three playlists (one in a folder) to a temp stick and reads them back with `DJStickLoader`: titles, artists, playlists and their order, grid, hot cues, hot and memory loops, memory cues, waveform tags and the `.2EX` file. It runs on the Mac without a simulator: `tools/DJUSBExportHarness/run.sh`.

Round trips (write → read → compare for PDB, ANLZ and a 700-track library spanning page chains), goldens (index page, default pages, track/artist rows and cue entries byte-for-byte against documented layouts and real exports; real `.DAT`/`.EXT` rewrite byte-identical), validator cases, fuzzing (truncation, flips, poisoned u32s) of both readers and the validator, export to temp volumes (new folder, blank root, explicit replace, cancellation, artwork), `.2EX` tag layouts, and removal safety: a fault-injecting file system kills the stick after every Nth operation (about 90 points per destination, including every step of the commit and torn writes) and asserts the old library is byte-identical or a valid new one after recovery, plus recovery from leftovers and half-done replaces, the scrubber, space and heartbeat checks, and read-only inspection. Read fixtures are MIT-licensed exports from pyrekordbox and rekordbox-pdb-rs (`Tests/SoundingTVTests/Fixtures/DJMedia/`, licences alongside). Kaitai structs and rekordcrate were not used.

## `.2EX` three-band waveforms

`ANLZ0000.2EX` sits next to `.DAT` and `.EXT` and holds `PPTH`, `PWV6`, `PWV7`. It's written only when the track's waveform carries real bands (`DJAudioAnalysis` output), never from synthesised ones, and can be switched off with `DJExportOptions.writeThreeBandWaveform`. Layouts from the Deep Symmetry analysis docs and pyrekordbox's `structs.py`:

| Tag | Header | Fields | Entries |
|---|---|---|---|
| PWV6 | 0x14 | `len_entry_bytes` = 3 at 0x0C, `len_entries` at 0x10 | 1,200 columns of three bytes: mid, high, low |
| PWV7 | 0x18 | `len_entry_bytes` = 3, `len_entries` (150 per second), `0x00960000` at 0x14 | three bytes per half-frame: mid, high, low |
| PWVC | 0x0E | one u16 at 0x0C | three u16 at 0x0E; tag length 0x14 |

Deep Symmetry's page says PWV7 is in `.EXT`; pyrekordbox and real exports have it in `.2EX`, and the documented PWV7 entry size is 3 (pyrekordbox's prose says 6, its struct says 3). Heights are the normalised band envelopes scaled linearly to 0 to 255; the players' non-linear display scaling is theirs. The validator reads `.2EX` when present and checks tag presence, the PWV6 length and the PWV7 count.

## Needs a real player

On CDJ-2000NXS2, CDJ-3000 and an XDJ (XDJ-1000MK2 or XDJ-RX3), with a FAT32 and an exFAT stick:
1. Stick mounts, browses by Playlist, Artist, Album, Genre, Key, BPM; folders nest; UTF-16 titles and artists render.
2. Tracks load and play for mp3, m4a, wav, aiff, flac (flac not on older XDJs).
3. Beat grid lines up (first beat, bar markers, BPM display); quantise and sync behave.
4. Hot cues A–H load with the right colours, pad LEDs and comments; hot loops; auto-load on.
5. Memory cues and loops: positions, colours, comments; legacy PCOB on players without PCO2.
6. Waveforms: overview, detail, colour; CDJ-3000 three-band waveform with and without `.2EX`.
7. CDJ-3000 phrase display and lighting with our masked PSSI.
8. Seeking and cue jumps in VBR MP3s (PVBR guess).
9. Artwork appears; key display; track colour and rating; History recording works on our stick.
10. Two tracks in one ANLZ folder (`ANLZ0001`) both get their own analysis.
11. rekordbox opens the stick in Export mode without repairing it.

## Mac UI

`Features/DJ/MacUSBExportModel.swift` and `MacUSBExportSheet.swift`. Entry points: Prep toolbar "Export to USB…", Prep menu "Export to USB…" (⇧⌘E), Settings › Library › DJ Players, "Export to USB…" on any playlist context menu, and "Export Setlist to USB…" on a mix with a setlist. A grouped Form with Playlists (a switch per source: the playlist or setlist it was opened from, Selected in Prep, All Tracks, each imported rekordbox playlist; each ticked source becomes a playlist on the stick; candidates are linked files plus Music Folder tracks; "No File on This Mac (N)" lists the rest with Find Local File…, and the finished state names them), Destination (volume, free space, format, mode: New Folder by default, Blank Stick (Root) only on sticks with no library, Replace Library only on sticks with one, behind a confirmation that names the backup folder; Allow Access… for volumes the sandbox can't write to) and Preview (track count and size, what's left out and why, validator problems in plain words). Progress shows the five stages with Cancel; finish and failure are centred `ContentUnavailableView`s. Snapshot scenes: `SOUNDING_TV_PREP_SNAPSHOT=usb-setup|usb-replace|usb-access|usb-progress|usb-done|usb-error|usb-pulled|usb-unfinished|usb-novolume|usb-noeligible|usb-selection|usb-full|usb-run|usb-playlists`. The harness now captures the real window with `screencapture -l` (the old view cache missed the inspector).
