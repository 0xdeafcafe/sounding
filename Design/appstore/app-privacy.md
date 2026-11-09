# App privacy notes

Running notes on the hosts Sounding talks to and what each one receives. The App Store answers live in `metadata.md` §6; the published policy is `docs/privacy/index.html`.

## LRCLIB (lyrics), added 2026-11-08

- **Host:** `https://lrclib.net`, a free, open lyrics database run by a third party. No API key or account.
- **Opt-in:** nothing is sent until the user agrees. The first time Lyrics opens on any device, the pane asks "Show Lyrics from LRCLIB?" with Show Lyrics and Not Now. The choice is the synced `lyricsSource` setting (unset, lrclib or off), shown as **Lyrics from LRCLIB** in Settings › Playback on iPhone, iPad, Mac and Apple TV. While it is unset or off the app makes no LRCLIB request at all, including prefetch (`LyricsConsentTests`).
- **What is sent:** the playing track's title, artist, album when known, and length in seconds, as query parameters of `GET /api/get`, `/api/v2/search`, `/api/search` and `GET /api/get/{id}`. The User-Agent is `Sounding/<version> (https://sounding.forbes.red)`. No SoundCloud token, account ID, device identifier or listening history.
- **When:** for the current track and the next one only, one request at a time, 200–500 ms apart, at most four lookups per track. A 429 or 503 stops all lyrics requests for `Retry-After` plus up to 30% jitter.
- **Stored:** results (including "no lyrics") are cached on the device in Caches/Lyrics, keyed by a hash of the track signature: found for 60 days, not found for 3 days. Nothing is synced except the on/off setting.
- **App Store answer:** unchanged. "Data Not Collected" still holds: LRCLIB is not a partner of the developer, the request is user-initiated, and nothing identifies the user. Under the cautious reading in `metadata.md` §6, it falls under the existing "Usage data: Product interaction" row (App functionality, not linked to tracking).

### Privacy policy change needed (not made; `docs/` is the owner's)

Add a section to `docs/privacy/index.html` and amend "The app only talks to SoundCloud and Apple" to "The app only talks to SoundCloud, Apple and, if you turn on lyrics, LRCLIB." Suggested section:

> **Lyrics.** Lyrics are off until you turn them on. If you do, Sounding sends the title, artist, album and length of the track you're playing to lrclib.net, a free lyrics database, to find its lyrics. Nothing else is sent: no account, no identifier and no listening history. Lyrics are kept on your device for a while so the same song isn't looked up twice. You can turn lyrics off in Settings › Playback.
# App Privacy answers

The App Privacy section (the nutrition label) can't be set through the public App Store Connect API. Click these through in ASC: Apps, Sounding, App Store, General, App Privacy. One set of answers covers iOS, iPadOS, watchOS, tvOS and macOS.

Checked against the code on 2026-11-08 (`rush/6a3b0b5d`, build 788).

## What the code does

| Area | What leaves the device, and to whom | Counts as collected? |
| --- | --- | --- |
| Sounding servers | None exist. No backend, no Sounding account. | - |
| Analytics, crash SDKs | None. No third-party SDKs, Swift packages, CocoaPods or Carthage. No MetricKit upload. Crash reports only through Apple's own opt-in. | No |
| Advertising identifier | Not read. No AdSupport, no AppTrackingTransparency, no ATT prompt. | No |
| SoundCloud library, playback, likes, comments, follows, messages, search | Sent to SoundCloud, the service the user signs in to, to run the feature. | Cautious reading: yes, App Functionality (see below) |
| Promoted posts (`PromotedTracking`, `Core/Models/PromotedContent.swift`) | When a promoted post in the stream is 50% visible for a second, played or opened, Sounding requests the impression, play or click URLs SoundCloud put on that post. Cookie-less, ephemeral, foreground only, at most once per post per event, never in fixtures. The URLs are SoundCloud's own and are issued for the signed-in account, so SoundCloud can tie them to it. | Yes: Advertising Data |
| SoundCloud sign-in | Keychain on the device, and encrypted in the user's private iCloud database for their other devices. Sent only to SoundCloud. | No |
| CloudKit sync (`iCloud.red.forbes.sounding`, private database) | Cues, cue dismissals, analysis rows, the SoundCloud session (encrypted), download manifests, setlists, settings, the list of the user's devices, sign-in requests. The developer can't read a private database. | No (Apple: data only in the user's own iCloud, not accessible to the developer, isn't collected) |
| Heart rate (Match My Workout, HealthKit) | Off until turned on. Read on the Watch and iPhone. When the Apple TV is the Output, the iPhone sends it an energy level (not the heart rate) over the local network, not stored. A workout started on the Watch is saved to Health. | No |
| HomeKit (Home Lighting) | Off until turned on. Sets the lights the user picks. Nothing about the home is kept or sent. | No |
| Microphone | iPhone, iPad and Mac listen for the Apple TV's sign-in chime while that screen is open. Nothing recorded or sent. | No |
| Camera | iPhone and iPad, only to scan the Apple TV's code. | No |
| Local network | Finds and talks to the user's own Apple TV, Mac, iPhone and Sonos speakers. | No |
| ShazamKit | Fingerprints of the playing track's own audio (not the microphone) are matched by Apple. | No (Apple's service, covered by Apple's policy) |
| SharePlay | What's playing and the position go to the people in the call through Apple's GroupActivities. No audio. | No |

The promoted-post pixels are what rule out "Data Not Collected". Everything else could honestly sit under it.

## Answers to enter

**Do you or your third-party partners collect data from this app?** Yes.

Tick these data types, and nothing else:

| Category | Data type | Linked to the user | Used for tracking | Purposes |
| --- | --- | --- | --- | --- |
| Usage Data | Advertising Data | Yes | No | Third-Party Advertising |
| Usage Data | Product Interaction | Yes | No | App Functionality |
| Identifiers | User ID | Yes | No | App Functionality |
| User Content | Other User Content | Yes | No | App Functionality |
| Search History | Search History | Yes | No | App Functionality |

Notes for each, if ASC asks:

- **Advertising Data:** SoundCloud's impression, play and click URLs on promoted posts, fired as SoundCloud's own apps fire them. Linked, because SoundCloud issues them for the signed-in account.
- **Product Interaction:** plays, likes, reposts and follows sent to SoundCloud.
- **User ID:** the SoundCloud account ID used in every SoundCloud request.
- **Other User Content:** comments, messages and playlists the user writes to SoundCloud.
- **Search History:** searches go to SoundCloud's search.

Not collected (leave unticked): Contact Info (the email address is never read), Health and Fitness, Financial Info, Location, Sensitive Info, Contacts, Emails or Text Messages (SoundCloud messages are covered by Other User Content), Photos or Videos, Audio Data, Gameplay Content, Customer Support, Browsing History, Purchases, Device ID, Crash Data, Performance Data, Other Diagnostic Data, Environment Scanning, Hands, Head, Body.

**Tracking:** No, for every type. Sounding doesn't combine anything with data from other companies' apps or websites, and has no data broker. The promoted-post URLs measure SoundCloud's own promoted posts on SoundCloud's own platform.

## Owner decision

The tracking answer is the one judgement call. Apple counts third-party ad measurement as tracking when it links your app's data with another company's data. SoundCloud is a separate company, and its ad URLs may carry measurement for its advertisers.

- **Recommended:** answer No (above). The pixels report on SoundCloud's own posts, inside SoundCloud's own feed, to SoundCloud, with no device identifier and no cookies.
- **If Apple pushes back,** or you'd rather not argue it: answering Yes for Advertising Data means an ATT prompt is required before the pixels fire. Turning the pixels off (`PromotedTracking.record`) puts Sounding back to "Advertising Data: not collected", and the rest stays the same.

## Privacy policy

`https://sounding.forbes.red/privacy/` is live and matches the table above, with one gap: it says "Sounding doesn't collect anything" and doesn't mention the promoted-post URLs. Add a line under "Your SoundCloud account" before submitting, for example: "Promoted posts in your SoundCloud stream are labelled Promoted. When one is shown, played or opened, Sounding tells SoundCloud, as SoundCloud's own apps do." That's a docs-only commit to `main`.
