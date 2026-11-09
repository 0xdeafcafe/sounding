# Sign in a TV by sound

An Apple TV on its sign-in screen broadcasts a fresh 128-bit secret as sound. A nearby iPhone, iPad or Mac running Sounding hears it, proves it heard it, and the TV hands over its Link session so the existing credential transfer can run. It is an alternative to the QR code and to the numeric code; neither is removed.

Code: `SoundingTV.swiftpm/Sources/Auth/Shared/ChimeCodec.swift` (codec), `ChimeLinkCrypto.swift` (key derivation, key confirmation, code ledger, phone attempt budget), `ChimeListener.swift` (phone: microphone, handshake, flow model), `Apps/tvOS/Auth/ChimePlayer.swift` + `LinkServer.swift` (TV). Tests: `Tests/SoundingTVTests/Sources/ChimeCodecTests.swift` (codec and robustness) and `ChimeLinkCryptoTests.swift` (derivation, confirmation, identity binding, expiry, budgets).

## Two layers, one secret

| | Ultrasonic carrier | Audible pulse |
|---|---|---|
| When | Only on **Play Sound** (or `LinkServer.requestChime()`): under the pulse at +6 dB, for the pulse plus two frames (about 13 s), then silent | Only on **Play Sound**: the pulse with the veil. Nothing plays when the screen opens |
| Band | 4-FSK at 18.2 / 18.6 / 19.0 / 19.4 kHz | Replays only. The veil: 64 slots 55 Hz apart, 380 Hz–3.85 kHz, over a bass pulse cut off below 240 Hz |
| Symbol | 50 ms, 2 bits, continuous phase, 6 ms raised-cosine glides, constant envelope | 140 ms. Four groups each switch on one of four choices (2 + 2 + 2 + 2 = 8 bits). A choice is four slots spread across the band (one per quarter), and each slot sounds as three detuned sines with random phase, under a 25 ms taper. 16 of the 64 slots sound in every step. Eight seeded slot layouts rotate step by step. |
| Frame | 4-symbol preamble + 87 data symbols = **4.55 s**, looped seamlessly | 2-step preamble + 22 data steps = 3.36 s, then the pulse's release; **3.72 s** clip |
| Level | −26 dBFS peak, 0.45 s raised-cosine fade in and out | peak −2 dBFS, stereo; the veil sits 8–11 dB under the bass |

**On demand only (2026-11-09, round 7).** The owner: "lets not play the ultrasonic sound all the time". The TV now makes no sound until **Play Sound**: no opening beep or pulse, no pings, no carrier loop and no automatic replay. `ChimePlayer.playChime()` renders the coded pulse off the main thread, then plays it with the carrier for the pulse plus two carrier frames. A nearby phone or Mac can ask for the same sound with `chime_play_request` (below). The rest of this section describes the earlier always-on design; `ChimeReplay` and the ping synthesis stay in the codec for tests and the phone.

**Pulse alone (2026-11-09, round 6).** The owner listened to Omen's pulse with and without the veil and said: "so i only really want to hear the pulse alone". The opening handshake is now `ChimeSynth.Handshake.pulse`: the Omen bed with the veil off, so the code travels only on the ultrasonic carrier. The veil comes back only on replays (`ChimeSynth.Handshake.coded`, chosen by `ChimeReplay`):
- **Play Sound** always plays the coded pulse.
- **One automatic replay** plays it 18 s (`ChimeReplay.automaticDelay`) after the opening handshake, if no phone has scanned, offered, connected or signed in by then and the user hasn't pressed Play Sound. The first full attempt (beep, handshake, 1.4 s rest, two 3.4 s pings) takes about 12.4 s, so the replay comes after about 6 s of carrier alone. There is never a second automatic replay.
- While a replay plays, and for one carrier frame after it, the carrier rises 6 dB (`ChimeReplay.carrierBoostDB`) with a 0.45 s ramp each way. In the margin table that rescues the steep 15 kHz cut.
- Replays don't re-arm the pings, so the rule stays: two audible pings, then the carrier alone.

The replay's veil follows the pulse (owner: "make it sound more like part of the pulse"; `ChimeVoiceSettings.followsPulse`). It starts 70 ms late so each 140 ms step is centred on a peak of Omen's 7.1 Hz throb, and each grain is gated 80% deep by the same throb, so the grit swells and ducks with the bass. Its level follows the pulse's swell, from 35% while the bass rises in to full at the top. Slots above 1.5 kHz roll off at 1.5 powers of frequency, so most of the energy sits between 380 Hz and 1.5 kHz. The veil passes the bed's own `tanh` drive (2.4 for Omen) and is then restored to its undriven RMS. The phone's decoder is unchanged and still listens for the veil, Eclipse, Ripple, Bell and the carrier.

**The sound (2026-11-09, round 5: one deep pulse).** The owner rejected note sequences outright: "instead of 10 or so unique dings, i want a sort of 1 sound for handshake, that is a large single sound, an omnious pulse, deep". The handshake is now one continuous pulse under one envelope, with no data notes. The code rides as grain over the pulse: no step has a pitch, and nothing moves as a line from step to step. All synthesis is original and nothing is sampled.
- **Beep:** a deep UI thump, 150 → 41 Hz with a 2 ms tick, 0.45 s.
- **Waiting:** 1.4 s after the handshake, one throbbing swell (E1 → A1 → E1, 7.1 Hz throb, slow phaser, 1.8 s, −21 dBFS peak). It plays **twice** (`ChimeSynth.audiblePings`), 3.4 s apart. After that the TV is silent to the ear and only the ultrasonic carrier keeps transmitting until the screen closes. A replayed handshake (**Play Sound**) doesn't re-arm the pings; a new session does.
- **Handshake (`ChimeSynth.Style.omen`, shipping):**
  - A driven three-partial saw drone on A1, through a resonant low-pass (`ChimeBass`) and a four-stage phaser at 0.45 Hz.
  - It slides up from E1 as it swells in, throbs at 7.1 Hz in time with the veil's steps while the filter opens to about 260 Hz, and sinks to D1 as it fades.
  - The bed passes an 8th-order low-pass at about 240 Hz, so it stays under the veil.
- **Success:** 2.4 s. One big throbbing swell whose filter opens to about 900 Hz, then settles.

The other pulse candidates are kept as styles: `.abyss` (one long sliding, wobbling sub) and `.grit` (a grainy, phased, distorted power-chord pulse). The older styles are kept for comparison: `.slide`, `.pulse` and `.click` (round 4), round 3's `.eclipse`, `.undertow` and `.descent`, and the older `.ripple`, `.bell` and `.bloom`. The phone listens for:
- the veil;
- the Eclipse layer, which Slide, Pulse and Click use;
- the Ripple layout;
- the older `.bell` dyad layout;
- the carrier.

So TVs on any earlier build still sign in by sound.

Both layers carry the same frame:
- a 128-bit secret from `SecRandomCopyBytes` plus a 4-bit check (the high nibble of CRC-8, poly 0x07, init 0x5A) = 132 bits;
- → 22 six-bit symbols → Reed–Solomon (29, 22) over GF(64) (corrects 3 symbol errors) → whitened;
- 174 bits are packed into the chime's 6-bit chords (29 exactly; the older 4-bit dyad layouts pad the last voice), into the veil's 8-bit steps (22 steps, the last 2 bits padding), or into three carrier symbols per RS symbol.

The phone decodes both layers at once and takes whichever lands first.

The carrier fades in when the screen is active, fades out on inactive/background, sign-in completion, or redemption, and cross-fades through silence when the code rotates. It never cuts abruptly. The TV session uses `.ambient` + `mixWithOthers` unless the app is already in `.playback`, so it never ducks or interrupts other audio.

### Band and level (measured)
`testCarrierBandMargin` runs every candidate band through modelled TV speakers. With the carrier at −29 dBFS RMS, a 28 dB room path and a −80 dBFS microphone floor:

| Band | Flat speaker | 4th-order roll-off at 16 kHz (−15…−22 dB) | 8th-order at 15 kHz (−38…−54 dB) |
|---|---|---|---|
| 18.0–19.2 kHz | ≥32 dB margin | 22 dB | −13 dB |
| **18.2–19.4 kHz (shipping)** | ≥32 dB | **17 dB** | −13 dB |
| 18.6–19.8 kHz | ≥32 dB | 12 dB | −23 dB |

18.2 kHz is the lowest start that keeps the glides' splatter above 18 kHz. Speakers that brick-wall at 15 kHz kill any ultrasonic band, which is why the audible chime exists. An 8-tone carrier (3 bits per symbol) would shorten the loop to about 3 s, but 4 tones already meet the 6 s target with the measured margins, so the band and spacing are unchanged.

### Decoder
- Hann STFT with a 5 ms hop: 2048 points for the chime, 1024 for the carrier.
- Tone energy is the peak bin within ±3% (chime) or ±0.6% (carrier) of each note.
- Each slot subtracts 45% (eclipse and bell; 40% for ripple and descent, 50% for bloom) or 20% (carrier) of the previous slot's energy, which removes room tails.
- Each voice is ranked on its own, so the low and high notes of a dyad never compete.
- Detection is preamble-gated. It then searches start offsets and time scales (0.97–1.03 in 0.5% steps for the chime) and normalises each tone for the carrier, so speaker tilt doesn't matter. Tone energies are cached per time scale during a search.
- Chase decoding flips up to two of the three weakest notes.
- The veil (`ChimeLayer.veil`, `isSpread`) uses a 4096-point STFT. A choice's energy is the sum over its four slots (±10 Hz each), and each slot is compressed to the 0.4 power first, so one loud music partial can't take over a choice. Each slot pools ±20% of the step. The preamble is searched at every time scale (0.97–1.03), with energies cached per scale, so a 2% speed error still locks on.
- A decode is accepted with at most three changes, or five when the median confidence is high.
- It runs on a background queue at 44.1 or 48 kHz. An optimised build decodes a 5.6 s chime capture in about 30 ms on an M-series Mac.

### Test results (`ChimeCodecTests`; 48 trials per condition in the optimised harness, 24 in XCTest)

| Condition | Old (24-bit, 2.3 s chime) | New (128-bit, 4.0 s chime) |
|---|---|---|
| Clean | 100% | 100% |
| White noise, 0 dB SNR | 100% | 100% |
| Music at −6 dB | 100% | 100% |
| Music as loud as the whole chime, bass included | 83% | 94% |
| Speed and pitch +2% / −2% | 100% / 100% | 100% / 100% |
| RT60 0.8 s, reverb louder than the chime | 100% | 100% |
| RT60 0.5 s | 100% | 100% |
| −40 dB level at 6 dB SNR | 100% | 100% |
| +1.5% drift, echo, music, noise and −26 dB at once | 98% | 100% |
| Small speaker, 4th-order 5 kHz roll-off, 10 dB SNR | 100% | 100% |
| Tiny speaker, 8th-order 4 kHz roll-off, echo, 10 dB SNR | 98% | 96% |
| Every style (was every groove): −2% drift, echo, 6 dB SNR | 100% | 100% |
| Carrier clean | 100% | 100% |
| Carrier, 16 kHz roll-off, room noise and music | 100% | 100% |
| Carrier, 0.3% clock drift and echo | 100% | 100% |
| Carrier, 16 kHz roll-off, white noise at −45 dBFS | 100% | 100% |
| Carrier at −20 dB, white noise at −60 dBFS, echo | 91% | 100% |

- No wrong codes in any trial, and no detections in 80 s of music-like audio.
- Random 29-symbol words pass RS + check in 0 of 2,000 tries.
- Renders: `chime-<style>.wav`, `chime-<style>-success.wav`, `chime-<style>-searching.wav` and `sounding-carrier.wav` (a fixed test secret), written to `CHIME_WAV_DIR` (set `TEST_RUNNER_CHIME_WAV_DIR` on `xcodebuild test`).
- The searching and success cues never decode as a code, and the phone's decoder hears the slide, ripple and older dyad chimes. `testWaitingPingsAtMostTwiceThenOnlyTheCarrierKeepsRunning` runs the TV's render loop and checks that exactly two pings sound and that the carrier alone still decodes afterwards.

### Sound redesign margins (2026-11-09; Mac harness, 32 trials per condition, the same channel models plus a phone mic at 4 m and one stereo channel only)

| Condition | Techno (old) | Bell | Bloom | **Ripple (shipping)** |
|---|---|---|---|---|
| 16 conditions overall | 98.6% | 99.2% | 97.1% | **99.4%** |
| Music as loud as the chime | 91% | 91% | 97% | 91% |
| Tiny speaker, 8th-order 4 kHz, echo, 10 dB SNR | 88% | 97% | 56% | **100%** |
| Phone mic at 4 m: 44.1 kHz, RT60 0.6, −30 dB, 8 dB SNR | 100% | 100% | 100% | 100% |
| Pre-FEC symbol error rate on decoded frames | 0.79% | 0.73% | 0.62% | **0.21%** |
| Lowest white-noise SNR still decoding ≥ 90% | −10 dB | −14 dB | −10 dB | −14 dB |
| Music 1× / 1.4× / 2× / 2.8× the chime | 93/81/68/12% | 100/93/81/31% | 75/68/37/6% | 81/68/68/12% |
| Wrong codes, false detections in 80 s of music | 0, 0 | 0, 0 | 0, 0 | 0, 0 |

### Round 3 margins (2026-11-09; Mac harness, 32 trials per condition, same channel models)

| Condition | Ripple | Undertow | Descent | **Eclipse (shipping)** |
|---|---|---|---|---|
| 16 conditions overall | 99.4% | 99.4% | 99.2% | **99.0%** |
| Music as loud as the chime (160 trials) | 92.5% | 91.9% | 83.8% | 85.6% |
| Tiny speaker, phone mic at 4 m, one channel only | 100% | 100% | 100% | 100% |
| Pre-FEC symbol error rate on decoded frames | 0.21% | 0.26% | 0.33% | 0.54% |
| White noise at −14 dB SNR | 93% | 68% | 62% | 81% |
| Music 1× / 1.4× / 2× / 2.8× the chime | 81/68/68/12% | 81/62/50/12% | 87/68/62/6% | 75/68/18/12% |
| Wrong codes, false detections in 80 s of music | 0, 0 | 0, 0 | 0, 0 | 0, 0 |

Eclipse gives up some margin against loud music for its lower, darker register; the carrier and **Play Sound** cover a missed first try. A lower four-voice candidate (0.15 s chords from A4) dropped to 28% with music as loud as the chime and was rejected.

### Round 4 margins (2026-11-09; Mac harness, 32 trials per condition, same channel models)

| Condition | Eclipse (r3) | **Slide (shipping)** | Pulse | Click |
|---|---|---|---|---|
| 16 conditions overall | 99.0% | **99.0%** | 98.8% | 99.0% |
| Music as loud as the chime (160 trials) | 85.6% | 80.6% | 78.8% | 84.4% |
| Tiny speaker, phone mic at 4 m, one channel only | 100% | 100% | 100% | 100% |
| Pre-FEC symbol error rate on decoded frames | 0.54% | 0.67% | 0.64% | 0.59% |
| White noise at −14 dB SNR | 81% | 12% | 12% | 31% |
| Wrong codes, false detections in 80 s of music | 0, 0 | 0, 0 | 0, 0 | 0, 0 |

The harness sets noise and music relative to the whole clip, and the bass bed is now a large share of it. Peak normalisation also leaves the data about 2–3 dB quieter, so the extreme rows fall. Room conditions all still decode 100%.

### Round 5 margins (2026-11-09; ChimeLab `--pulse`, 16 trials per cell)
"Pulse data" is the veil alone, with the carrier switched off in the decoder. "Data or carrier" is what the phone gets.

| Channel | Carrier only | Omen: pulse data | Omen: data or carrier | Abyss: pulse data | Abyss: data or carrier | Grit: pulse data | Grit: data or carrier |
|---|---|---|---|---|---|---|---|
| Clean | 100% | 100% | 100% | 100% | 100% | 100% | 100% |
| TV, gentle roll-off above 16 kHz | 100% | 100% | 100% | 100% | 100% | 100% | 100% |
| TV, steep cut at 16 kHz | 100% | 100% | 100% | 100% | 100% | 100% | 100% |
| TV, steep cut at 15 kHz | 56% | 100% | 100% | 100% | 100% | 100% | 100% |
| TV, cut at 12 kHz | 0% | 100% | 100% | 100% | 100% | 100% | 100% |
| Tiny speaker, 4 kHz | 0% | 100% | 100% | 100% | 100% | 100% | 100% |
| Phone at 4 m, quiet room | 100% | 100% | 100% | 100% | 100% | 100% | 100% |
| Phone at 4 m, noisy room (8 dB SNR) | 100% | 100% | 100% | 100% | 100% | 100% | 100% |
| Phone at 4 m, TV rolls off at 16 kHz | 100% | 100% | 100% | 100% | 100% | 100% | 100% |
| Phone at 4 m, room noise at -60 dBFS | 100% | 100% | 100% | 100% | 100% | 100% | 100% |
| Music as loud as the chime | 100% | 81% | 100% | 56% | 100% | 75% | 100% |
| Clock drift 0.3%, echo | 100% | 100% | 100% | 100% | 100% | 100% | 100% |
| Music at 2x the chime | 100% | 44% | 100% | 38% | 100% | 44% | 100% |
| White noise at 0 dB SNR | 100% | 100% | 100% | 100% | 100% | 100% | 100% |
| Speed and pitch -2%, echo, 6 dB SNR | 0% | 100% | 100% | 100% | 100% | 100% | 100% |
| One stereo channel at 4 m, 44.1 kHz, drift | 100% | 100% | 100% | 100% | 100% | 100% | 100% |

- Wrong codes: 0 across every cell.
- False detections by the phone's full listening decoder: 0 in 80 s of music-like audio, and 0 across every beep, ping and success.
- Carrying the code in the throb or phaser alone was rejected: a 7 Hz throb carries about 14 bit/s, so the 174 coded bits would take about 12 s.
- Coherent DSSS or OFDM was not built: a 0.3% speed error at 4 kHz turns the phase over within 40 ms. The veil gets the same wideband, noise-like spectrum with energy detection instead.

### Round 6 margins: pulse alone, coded replay (2026-11-09; ChimeLab `--pulse-only`, 8 trials per cell)
"Code" is the veil on its own; "either" is what the phone gets with both layers. The default has no veil, so its only path is the carrier.

| Channel | Default: pulse alone | Replay: veil follows the pulse, carrier +6 dB | Replay: plain veil, carrier +6 dB | Replay: veil follows, carrier +0 dB |
|---|---|---|---|---|
| TV, steep cut at 15 kHz | carrier 50% | code 100%, carrier 100% | code 100%, carrier 100% | code 100%, carrier 50% |
| TV, cut at 12 kHz | 0% | code 100% | code 100% | code 100% |
| Tiny speaker, 4 kHz | 0% | code 100% | code 100% | code 100% |
| Phone at 4 m, noisy room (8 dB SNR) | carrier 100% | code 100%, carrier 100% | code 100%, carrier 100% | code 100%, carrier 100% |
| Phone at 4 m, room noise at −60 dBFS | carrier 100% | code 100%, carrier 100% | code 100%, carrier 100% | code 100%, carrier 100% |
| Music as loud as the chime | carrier 100% | code 75%, carrier 100% | code 75%, carrier 100% | code 75%, carrier 100% |
| Music at 2× the chime | carrier 100% | code 13%, carrier 100% | code 38%, carrier 100% | code 38%, carrier 100% |

No wrong codes. Following the pulse costs the veil about 2.6 dB in its band (7.9 dB over the pulse's own spectrum, against 10.5 dB for the plain veil), and it costs some margin under loud music, where the carrier still decodes 100%. In an earlier 8-trial tuning run on music as loud as the chime, the following veil decoded 38% and the plain veil 88%. Shallower gating (40%), a higher swell floor (0.7) and +2.6 dB of make-up each reached 50%; no high-slot roll-off and no drive stayed at 38%. Music at 2× stayed at 0% for every variant. None of them was worth the change, so the shipped values stay at 80% gating, a 0.35 floor, a 1.5 roll-off, drive on and no make-up. Drive costs nothing measurable.

## Protocol
The chime travels over the existing Link offer channel (the plain-TCP `SoundingTV-LinkOffer-<prefix>` Bonjour service the numeric-code path also uses). Protocol version 2.

1. **TV:** a fresh secret `S` (128 bits, `SecRandomCopyBytes`), registered in the code ledger with a generation number and a monotonic deadline.
2. **Phone** hears `S`, finds every Link offer, and sends `chime_hello { v: 2, N_p }` (a 32-byte nonce). Nothing derived from `S` leaves the phone yet.
3. **TV** sends `chime_hello_ack { v, N_t, sessionId, tvName, tvKind, tvDeviceId, confirm_tv }`.
   - The transcript `T` is length-prefixed: label ‖ version ‖ full session ID ‖ TV device ID ‖ TV name ‖ TV kind ‖ `N_p` ‖ `N_t`.
   - `K = HKDF<SHA256>(ikm: S, salt: SHA-256(T), info: "Sounding-Chime-v2 session")`.
   - `confirm_role = HMAC-SHA256(HKDF(K, "…confirm <role>"), role ‖ T)`, so the two roles use different keys and messages.
4. **Phone** rebuilds `T` from the ack, checks that the session ID starts with the advertised prefix, and verifies `confirm_tv` with CryptoKit's constant-time `isValidAuthenticationCode`. Only the TV that played `S` can produce it. The phone stops the microphone and shows the **authenticated** `tvName` and kind from `T`, never the Bonjour TXT name; the user taps **Sign In**.
5. **Phone** sends `chime_confirm { confirm_phone }`. The TV checks that the pending session's generation is still current and its deadline hasn't passed, verifies the tag in constant time, redeems the code and replies `chime_credentials { ChaChaPoly(HKDF(K, "transport"), LinkOffer, aad: SHA-256(T)) }`. The phone checks that the sealed offer's session ID and TV name match `T`.
6. **Phone** hands the session to the existing flow: the iOS `SoundCloudLoginView`, or `CompanionLinker` on Mac, then TLS-PSK token transfer and Companion pairing. **The SoundCloud credentials never touch the sound path.**

**Asking for the sound.** Before listening for a code it didn't hear, the phone can open the same Link offer and send `chime_play_request { v: 2 }`. The TV answers `chime_playing` and closes the connection, then plays the coded pulse and carrier as if **Play Sound** were pressed. It refuses (plain `error`) when no code is live, the sign-in screen isn't up, or the 12-a-minute hello budget is spent, and plays at most once every 10 s. The request carries nothing secret and gets nothing back: the code still arrives only as sound, so a LAN attacker can at worst make the TV play its chime, which is a nuisance the budget bounds. While a phone is offering the card it advertises `SoundingTV-Nearby-<salt>` with its name (`NearbyPresenceTXT`), and the TV's status line reads "<name> is nearby" (`NearbyPhonePresence`).

The wire types (`chime_*`, `ChimeLinkPayload`) live in `TokenTransferProtocol.swift`, which is still dependency-free. The crypto and codec are in their own files, and use only CryptoKit (`HKDF`, `HMAC`, `SHA256`, `ChaChaPoly`) and `SecRandomCopyBytes`.

## Code life
- **Expiry:** 120 s on `ContinuousClock`, so wall-clock changes can't extend it. It rotates and keeps looping while the screen is open, and the whole Link session still expires at 300 s.
- **Generations:** every rotation bumps the ledger's generation. A pending session records the generation and a deadline (the code's deadline, or 60 s after the hello, whichever is sooner). Redemption checks both, so a rotated or expired code can't be redeemed, even with the same secret.
- **Single use:** redeeming retires the code and stops the carrier at once. If no token arrives within 45 s, a new code starts.
- **TV budget:** 3 failed confirmations per code, then the code rotates. At most 12 hellos per minute across chime and numeric hellos.
- **Phone budget:** at most 6 offers tried per heard secret, 20 attempts per minute and 4 at once, so spoofed Bonjour adverts can't make the phone spray connections.

## Numeric code
The numeric path (choosing a nearby Apple TV from the list in Devices, or "Use a Code Instead" on Mac) now needs a decision on the TV as well as on the phone:
- The phone sends its device name in `numeric_hello`; the name is mixed into the six-digit code's derivation, so a relay that rewrites it changes the code.
- The TV shows a native alert: **Allow "<device name>" to link to this Apple TV?** with "Only allow it if <device name> shows 123 456." and **Allow** / **Don't Allow**.
- The TV releases the sealed Link offer only after both the phone's "It Matches" and the TV's **Allow**. **Don't Allow**, the Menu button, a dropped connection or the 90 s timeout all discard the exchange. The phone shows "On <TV>, choose Allow to finish." while it waits.
- The shared secret is per connection and is cleared when the connection closes, so a second connection can't reuse an earlier exchange.

## Security reasoning

### Threat model
- **Assets.** The phone's SoundCloud credentials, and the TV's Link session secret, which lets a device push credentials and pair as a Companion. A secondary asset is the TV accepting someone else's account.
- **Attacker.** On the same Wi-Fi, not in the room: can browse and advertise Bonjour services, connect to any listener, and relay or rewrite traffic. Anyone in the room can hear the sound and see the screen, the same as the QR code.
- **Out of scope.** An attacker in the room with a microphone can hear the secret and race the user's phone, just as they could photograph the QR code. The TV shows nothing until a phone completes, and the user would see an unexpected sign-in.

### Why no PAKE
The secret is 128 bits, so a LAN attacker who records a transcript has nothing to brute-force offline. HKDF plus HMAC key confirmation is enough, and both use public CryptoKit APIs. CryptoKit in the 27.2 SDKs has no CPace, SPAKE2+, Elligator or hash-to-curve API (checked in the iOS and tvOS `CryptoKit.swiftinterface`), so the previous CPace variant needed hand-rolled field arithmetic, which is gone.

### Independent review (2026-11-06) and fixes
| # | Finding | Fix |
|---|---|---|
| 1 | **High.** Any LAN device could send `numeric_hello` then `numeric_confirm` and receive the Link secret with no code check or approval on the TV. | The TV now needs **Allow** on a native alert as well as the phone's confirmation; the shared secret is cleared per connection; hellos are rate-limited (`LinkServer.handleNumericHello`, `approveLink`, `releaseNumericCredentialsIfApproved`; alert in `QRCodeLoginView`). |
| 2 | **Medium.** The phone's confirmation screen showed the Bonjour `claimedName`, outside the authenticated transcript. | The TV's name, kind and device ID, both roles, the protocol version, both nonces and the full session ID are in `T` and covered by `confirm_tv`; the phone shows only the name from `T` and checks the sealed offer against it (`ChimeLinkHandshake`, `NearbyTVSignIn`). |
| 3 | **Medium.** Hand-rolled, non-constant-time field arithmetic and Elligator, and a non-conformant CPace variant. | Deleted. A 128-bit secret over sound, HKDF-SHA256 bound to `T`, and HMAC-SHA256 key confirmation with CryptoKit's constant-time compare (`ChimeLinkCrypto`). |
| 4 | **Medium.** Expired or rotated codes stayed redeemable, because pending sessions survived rotation. | `ChimeCodeLedger` binds each pending session to a generation and a monotonic deadline, invalidates on rotation, and checks both at redemption. |
| 5 | Phone-side budget. | `ChimeAttemptBudget`: 6 offers per heard secret, 20 attempts per minute, 4 concurrent. |

### Denial of service
A LAN attacker can burn the hello budget, make the TV rotate its code with bad confirmations, or keep the numeric alert popping up (12 a minute at most, each needing **Allow**). The phone simply hears the new code, and the QR code still works.

## Phone experience
- **Entry points:**
  - iPhone and iPad: Settings › Devices › **Add Apple TV…**, which opens in listening mode;
  - "Sign In This Apple TV" on a device that is waiting nearby;
  - the **nearby Apple TV card** (bible §9): a signed-in iPhone, iPad or Mac that finds a signed-out TV's Link offer shows a card with **Sign In**. The tap turns the microphone on, sends `chime_play_request`, and runs the handshake below; a matching authenticated name confirms without a second tap.
- **Mac:** Settings › Devices › **Add Apple TV…**, with "Use a Code Instead" falling back to the numeric code.
- **States:** all are centred `ContentUnavailableView`s or progress views.
  - **Priming:** "Listen for Your Apple TV", **Continue**, then the system prompt.
  - **Microphone off:** **Open Settings** (System Settings › Privacy › Microphone on Mac).
  - **Listening…**
  - **Connecting…**
  - **Found:** the TV's authenticated name, "Sign in to Sounding on this Apple TV?", **Sign In** or **Not Now**.
  - **Signing in…**
  - **Couldn't Sign In:** **Try Again**.
  - Every state except Found also offers **Use QR Code Instead** ("Use a Code Instead" on Mac).
- **Microphone use:** permission is asked only when the user starts this flow, never at launch. The microphone runs only while the screen is open and stops when the app is backgrounded or a TV is found. Nothing is recorded or kept, and the secret is never logged (`ChimeCode` prints as "redacted").
- **Audio session:** on iOS, the listener uses `.playAndRecord`/`.measurement` with `mixWithOthers`, the built-in mic and 48 kHz preferred. It restores the previous category afterwards.
- **Fixtures:** `SOUNDING_TV_NEARBY_STORY=priming|denied|listening|checking|found|signingIn|failed` opens the sheet in that state. On tvOS, `SOUNDING_TV_UI_DESTINATION=signin` opens the sign-in screen.

## When the TV just needs sign-in again
- Losing the SoundCloud session no longer makes the Apple TV forget its linked devices; only Sign Out on the TV does.
- While the TV needs sign-in, it sends every connected device a signed `device_status`. The phone shows **Needs Sign-In** in Devices and Settings, and "<TV> is waiting to sign in" on Home.
- **Sign In This Apple TV** hands over credentials directly over the trusted Link (no sound). If the TV is only advertising its sign-in offer, it opens the listening flow instead.
- "Not Reachable" appears only when the TV can't be found at all.

## Left for on-device testing
- Real Apple TV speakers and soundbars: the carrier's margin, and whether any soundbar's codec strips 18 kHz. The chime is the fallback.
- iPad and iPhone microphones above 18 kHz in `.measurement` mode.
- Living-room distances, now that each chime note carries half the energy of a dyad.
- Whether the carrier is inaudible to younger listeners at normal TV volume.
- How the slide chime, the two pings and the success sound through real TV speakers and soundbars, how much of the sub survives small speakers, and whether soundbars with a sub boom.
- The numeric-code alert's focus and Menu-button behaviour on a real Siri Remote.
