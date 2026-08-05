# SoundingCloud

The SoundCloud client I wished existed on my Apple TV, so I built it. For one Apple TV, one iPhone, and nobody else's App Store.

SoundCloud has never shipped a tvOS app. The third-party ones that exist throw away the two best things about the web player: the amplitude waveform, and the comments pinned to the second someone left them. This keeps both, and then goes quite some distance further - a real two-deck mixer running on AVAudioEngine, offline downloads, multi-room playback, and a sign-in flow that never touches a server of mine.

303 Swift files, roughly 111,000 lines, nine targets, one developer. No backend, no database of users, nothing of mine to breach.

## What's in it

**A waveform you can read from the sofa.** Full amplitude detail, scrubbable with the Siri Remote, with every timed comment pinned to its exact second. Focus a comment asking "what's this transition into??" and the app will go and search it for you, rather than making you unlock a phone.

**A DJ mixer, not a crossfade toggle.** Two decks on AVAudioEngine: crossfader, three-band EQ per channel, a filter, loop points, jog wheels, and an auto-mix that beat-matches the next track out of the queue on time. The iPhone app doubles as a control surface for it - a glass CDJ with a weighted jog wheel, so you can mix from across the room while the TV does the talking.

**Sign-in over your own network.** The TV shows a QR code carrying a session ID, a base64url shared secret and Bonjour service info. The phone signs in to SoundCloud, HMAC-SHA256 signs the token with that secret, and beams it over the LAN straight into Keychain. Five-minute window, no server in between. With both apps open the phone finds the TV on its own and the QR is just the fallback.

**Playback that follows you.** Start a track on the TV, pick the phone up on the way out and it carries on in your headphones at the same position. Come back and it lands on the big screen again. Same session, no restart, no scrubbing to catch up.

**The rest of it**, briefly: offline downloads with storage management that evicts the oldest first, Live Activities and Lock Screen transport on iOS, a Share extension that queues a link into the TV without opening the app, a Top Shelf that shows what you actually played, spatial and multichannel output, and Polyphony - one device leading, others playing in sync as speakers.

## Layout

```
SoundingTV.swiftpm/      Shared Swift package. Core/ is the engine room
                         (playback, DJ, sync, downloads, SoundCloud API),
                         Shared/ is design system + view models,
                         Apps/tvOS/ is the TV UI.
SoundingTV-tvOS/         tvOS app shell (Info.plist, entitlements, assets)
SoundingTV-iOS/          iPhone app: Companion control, DJ remote, Stream, Library
SoundingTV-macOS/        Mac app: Decks, Home, Library, Search
SoundingTV-watchOS/      Watch app and its haptics
SoundingTV-Widget/       Widgets, Live Activity, playback control intents
SoundingTV-TopShelf/     tvOS Top Shelf extension
SoundingTV-Share/        Share extension
SoundingTV-UITests/      Focus-walk UI tests
Tests/                   Unit tests
Design/specs/            Where the thinking lives. Start with feature-matrix.md
docs/                    The showcase site (GitHub Pages) and the AASA files
tools/                   Spikes, probes and scripts. Mostly disposable
```

## Building it

Xcode 27, Swift 6. Targets are tvOS 27, iOS 26.5, macOS 27 and watchOS 27.

```sh
open SoundingTV.xcodeproj
```

One rule worth knowing before you touch anything: **do not run `xcodegen`.** The `project.yml` in the root is a partial record - it declares the tvOS target properly and lags behind on the rest. The `.pbxproj` is hand-maintained and carries all nine targets. Regenerating would quietly delete six of them.

## The vocabulary

Cross-device code gets confusing fast, so these four words mean exactly one thing each and never overlap:

- **Link** - trust and credentials. Establishing that two devices belong to the same person, and moving the session between them.
- **Companion** - the control channel. Auth, state and settings flowing between a phone and a TV.
- **Polyphony** - one leader driving other devices as synchronised speakers.
- **Output** - where audio physically comes out.

"Handoff" means `NSUserActivity` and nothing else. There is no lyrics feature and there never will be.

## Legal

Independent, unofficial, and built by one person for their own living room. Not affiliated with, endorsed by, sponsored by or connected to SoundCloud in any way. "SoundCloud" is a trademark of its respective owner, used here only to describe the service this app talks to.

It isn't distributed anywhere. No App Store listing, no TestFlight link, no waitlist. The [showcase site](https://sounding.forbes.red) exists to show what it does, not to hand it to you.
