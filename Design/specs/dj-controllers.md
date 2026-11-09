# DJ controllers

Decided 2026-11-08. This supersedes the controller parts of `macos-plan.md` §3.2 and the plugin-system idea floated the same day, which was dropped.

## Rules

- **Built in.** Controller support ships inside the app. There is no plugin system, no scripting and no Settings page for it. Unknown controllers do nothing.
- **Your own music only.** A controller drives a deck only while that deck is empty or holds one of the user's own files (`Track.localFile`, `TrackSource.local`). A deck holding a SoundCloud track ignores everything the controller sends it: play, cue, sync, jog, tempo, pads, loops, EQ, filter and the channel fader. The crossfader is ignored while either deck holds a SoundCloud track, because it would blend that track. On-screen controls, keyboard shortcuts and Auto Mix are unaffected; this only concerns hardware.
- **The line.** While a supported controller is connected and a deck holds a SoundCloud track, that deck shows one line under its header: "Controllers work with your own music." Nothing else changes and there is no alert.
- **Personal build.** In `SOUNDING_PERSONAL` builds with the hidden unlock entered (the same `PersonalCodeLock` as SoundCloud audio for Export to USB, `dj-gear.md` §9a), controllers also drive SoundCloud tracks. This is for the owner's future SoundCloud mixing on CDJs. Default, TestFlight and App Store builds compile none of it: the only reference is inside `#if SOUNDING_PERSONAL` in `MacDeckControlSurface.access`, and `tools/personal/check-no-personal-marker.sh` passes on the default build.

## Shape

| Piece | Where |
|---|---|
| `DeckControlSurface`: the one protocol the deck/mixer model exposes to hardware. `value(of:)`, `setValue(_:for:)`, `press(_:isDown:)`, `jog(_:ticks:)`, addressed by `DeckControlAddress` (`DeckGroup` deck A, deck B or mixer; `DeckControl`; index for hot cues 0–7). Continuous values are 0…1 knob positions; units (dB, Hz, ±16% tempo) belong to the surface. | `Core/DJControllers/DeckControlSurface.swift` |
| MIDI 1.0 messages, from bytes or Universal MIDI Packet words (64- and 128-bit packets are skipped whole). | `Core/DJControllers/ControllerMIDIMessage.swift` |
| Mapping tables: one `Entry` per control (`note`, `cc`, `cc14` MSB/LSB pairs, relative jog as `offset64` or `twosComplement`, `invert`). `problems` reports bad channels, targets and duplicates. The resolver keeps 14-bit state per pair. | `Core/DJControllers/ControllerMapping.swift` |
| Profiles: a name, port-name globs (`*`, `?`, case-insensitive, matched against the port name, model and manufacturer + model) and a mapping. Adding a controller means adding a profile to `ControllerProfiles.all`; no code changes elsewhere. | `Core/DJControllers/ControllerProfile.swift` |
| The gate: `ControllerDeckContent` (empty, own music, streaming) and `ControllerDeckAccess` (`allowsStreaming` is false unless the personal unlock says otherwise). | `Core/DJControllers/ControllerDeckAccess.swift` |
| `ControllerInputRouter`: resolve → gate → surface, per connected device. Returns performed, blocked or unmapped, which is what the tests assert. | `Core/DJControllers/ControllerInputRouter.swift` |
| `DJControllerHub`: CoreMIDI client and input port, source rescans on setup changes, one router per matched source (refCon carries the source's unique ID), raw message stream for the Hardware pane. macOS and iOS only; nothing on iOS attaches a surface yet. | `Core/DJControllers/DJControllerHub.swift` |
| Mac surface over `MixEngine` and `MacConsoleController`, including jog pitch-bend with decay and loop in/out. Attaches itself to the hub at launch. | `SoundingTV-macOS/Sources/Features/DJ/MacDeckControlSurface.swift` |

## Pioneer DJ DDJ-400

Channels 1 and 2 are decks A and B, channel 7 is the mixer, channels 8 and 10 are deck A and B performance pads in Hot Cue mode. Tempo, channel fader, trim and the three EQs are 14-bit CC pairs (MSB 0x00/0x13/0x04/0x07/0x0B/0x0F, LSB +0x20); the crossfader is 0x1F/0x3F and the filters 0x17/0x37 and 0x18/0x38 on the mixer channel. Jog turns are CC 0x21–0x23 offset by 64; jog touch is note 0x36. Play 0x0B, Cue 0x0C, Beat Sync 0x58, Loop In 0x10, Loop Out 0x11, Reloop/Exit 0x4D. Pads are notes 0–7. Beat Sync is new in this table and hasn't been tried on hardware.

## Tests

`Tests/DJControllers/run-tests.sh` compiles the Core files with a `MixEngine.Deck` stub and runs on the Mac, no simulator. It covers MIDI and UMP parsing, profile matching (unknown controllers and the IAC bus match nothing), table validation, every DDJ-400 control, a replay of `Fixtures/ddj400-session.midi.txt` against a recording surface, and the gate: with a SoundCloud track on deck A the same replay changes nothing on deck A or the crossfader while deck B still works; a local file on deck A plays; the unlocked access drives the SoundCloud deck. The fixture is built from the DDJ-400 MIDI message list, not captured from hardware; replace it with a capture when there's one.
