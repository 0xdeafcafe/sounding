# Sounding: App Store Connect metadata

Source of truth for the App Store listing. `tools/appstore/apply_metadata.py` reads the fenced blocks in this file and writes them to App Store Connect, so edit here first and re-run it.

Bundle `red.forbes.sounding`. iOS, tvOS and macOS share one App ID and one app record (`6767263473`). Team `6Z49PF6642`. Primary language: English (U.K.), `en-GB`. There is no `en-US` localisation: `en-GB` is shown in every storefront without one, and a second English copy would only drift.

Every field sits in its own fenced block, pasted verbatim. Each block's length was checked against the limit in its heading.

Fields ASC stores once per app (name, subtitle, categories, privacy policy URL, age rating) appear once. Fields ASC stores per platform version (promotional text, description, keywords, What's New, support and marketing URLs, copyright) appear once per platform: iOS (which also covers iPad and the Apple Watch app), Apple TV, Mac.

## Rules for every field

- SoundCloud is named only in plain, factual sentences ("works with your SoundCloud account", "needs SoundCloud Go"). Never in the name, subtitle, keywords or screenshot captions, and never as branding (SoundCloud API Terms §08). No SoundCloud logo, wordmark or orange anywhere in the listing.
- Every description ends with the independence line: not affiliated with SoundCloud.
- Only what ships. No lyrics. The plan requirement is stated up front, not hidden at the bottom.
- British English, no em-dashes, Alex's voice.
- What's New: ASC won't take it on a first version (the field is locked for 1.0). The script skips it there. The text stays here for the next version to start from.

## What ships, per plan

Checked against `SoundCloudEntitlements` in `SoundingTV.swiftpm/Sources/Core/SoundCloud/SubscriptionService.swift` and `Design/specs/soundcloud-tiers.md`.

| | Free, Artist, signed out | Go | Go+ and DJ |
| --- | --- | --- | --- |
| Browse library, stream, search | Yes (signed in) | Yes | Yes |
| Play SoundCloud tracks, Auto Mix, SharePlay, Play On | No | Yes | Yes |
| Go+ catalogue tracks | No | No (SoundCloud only gives a preview, and Sounding doesn't play previews) | Yes |
| Downloads | No | Yes | Yes |
| DJ decks, controllers and Prep with SoundCloud tracks | No | No | Yes |
| Your own music files, on the decks too | Yes | Yes | Yes |
| Ads in Sounding | None | None | None |

Promoted posts in the SoundCloud stream are shown, labelled "Promoted", as SoundCloud's own apps do.

## 1. App-level fields

### App name (max 30)

```
Sounding
```

### Subtitle (max 30)

```
Long sets, two decks, no ads
```

### Categories

| Field | Value | API |
| --- | --- | --- |
| Primary | Music | `MUSIC` |
| Secondary | Entertainment | `ENTERTAINMENT` |

### Privacy Policy URL

```
https://sounding.forbes.red/privacy/
```

### Price and availability

Free, no in-app purchases. Not set by the scripts: the owner sets it in ASC.

## 2. Shared per-version fields (all three platforms)

### Support URL

```
https://sounding.forbes.red/support/
```

### Marketing URL

```
https://sounding.forbes.red/
```

### Copyright

```
2026 Alexander Forbes-Reed
```

## 3. iOS version (iPhone, iPad and Apple Watch)

### Promotional text (max 170)

```
Long sets with the whole waveform, tracklist and every comment pinned to the second. Auto Mix brings the next one in on the phrase. Works with your SoundCloud account.
```

### Description (max 4000)

```
Sounding is a player for your SoundCloud on iPhone, iPad, Apple Watch, Apple TV and Mac. It's built around long sets, and there's a pair of DJ decks bolted on. I make it on my own, in Amsterdam.

Sign in with your SoundCloud account and it's all there: likes, playlists, the people you follow, that set you saved at 4am. Nothing to import.

BEFORE YOU DOWNLOAD
Playing SoundCloud tracks in Sounding needs SoundCloud Go, Go+ or DJ. Sounding shows no ads, and SoundCloud's ads can't run in an app that isn't SoundCloud's, so a paid plan is the honest way to do it. Go+ tracks need Go+ or DJ (on Go, SoundCloud only gives you a preview, and Sounding won't play previews). On a free account you can still browse, and play your own music.

LONG SETS, PROPERLY
Now Playing shows the whole waveform with every comment pinned to the second it was left. Anything six minutes or longer gets the Tape: the waveform scrolls edge to edge under a fixed playhead, with the tracklist marked along it. Sounding pieces the tracklist together from the uploader's notes, the comments and Shazam, and Identify fills in the gaps.

AUTO MIX, FOR WHEN YOU'D RATHER DANCE
Auto Mix beat-matches the next track and brings it in on the phrase. Pick a personality (Wedding DJ blends and cuts clean, Junkie loops, ramps the tempo and jumps through a long set) and let it follow the time of night, or your heart rate from Apple Watch. If it hasn't measured where the bars are, it cuts cleanly on the bar instead of faking it.

MIXES
Every Auto Mix transition is kept in Mixes, in your Library, so you can find the good one from last night and play it again.

TWO DECKS, IF YOU FANCY IT
Two decks, a crossfader, three-band EQ and a filter on each, loops and four hot cues a deck. Tempo and key are worked out on your device, so you can see what fits before you bring it in. On iPhone and iPad the decks drive your Apple TV, so you can mix from the sofa. Using the decks with SoundCloud tracks needs Go+ or DJ.

YOUR OWN MUSIC
Add a folder of your own audio files and it plays alongside everything else, on any plan.

APPLE TV
Your Apple TV signs in by ear: it plays a short chime, your iPhone hears it and signs it in. No typing a password with the Siri Remote. Tap Play On to move a set from your phone to the TV (or AirPlay, or Sonos) at the same second.

APPLE WATCH
Skip, pause and scrub with the Digital Crown, from your wrist (the phone's down the back of the sofa anyway). Match My Workout reads your heart rate to set how hard Auto Mix goes.

LISTEN TOGETHER
SharePlay plays the same set at the same moment for everyone on the call. Each of them streams it with their own SoundCloud account, so nobody's borrowing anyone's sign-in.

DOWNLOADS
With Go, Go+ or DJ, download tracks and playlists for when the signal goes.

PRIVACY
No Sounding servers, no Sounding account, no analytics and no ads. Your sign-in stays on your devices, and sync goes through your own iCloud. Promoted posts in your SoundCloud stream show up labelled Promoted, as they do in SoundCloud's own apps.

FAIR WARNING
It's one person making this, mostly in the evenings. Tell me what breaks: sounding@alex.forbes.red

Sounding is an independent app. It isn't affiliated with or endorsed by SoundCloud. You'll need a SoundCloud account.
```

### Keywords (max 100)

```
dj,decks,mixer,automix,mixes,sets,tracklist,bpm,key,waveform,offline,crossfader,shareplay,remote
```

### What's New (max 4000)

```
Hello. This is Sounding's first App Store release, after quite some months on TestFlight. If anything breaks, tell me at sounding@alex.forbes.red.
```

## 4. Apple TV version

### Promotional text (max 170)

```
Your sets on the big screen. It signs in by ear from your iPhone, takes a set from your phone mid-track, and Auto Mix keeps it going. Works with your SoundCloud account.
```

### Description (max 4000)

```
Sounding puts your SoundCloud on your Apple TV, built around long sets and loud rooms. I make it on my own, in Amsterdam.

Your likes, playlists, stream and the people you follow are all there, a Siri Remote swipe apart. Nothing to import.

BEFORE YOU DOWNLOAD
Playing SoundCloud tracks in Sounding needs SoundCloud Go, Go+ or DJ. Sounding shows no ads, and SoundCloud's ads can't run in an app that isn't SoundCloud's, so a paid plan is the honest way to do it. Go+ tracks need Go+ or DJ (on Go, SoundCloud only gives you a preview, and Sounding won't play previews).

SIGN IN BY EAR
There's no password to type with the Siri Remote. The TV plays a short techno pulse (plus a signal too high for you to hear), your iPhone picks it up, asks if that's your TV, and signs it in. If the room's loud, scan the code instead.

FROM YOUR PHONE TO THE TV, MID-TRACK
Tap Play On on your iPhone and pick the Apple TV. The set carries on from the same second, just louder. Your iPhone and Apple Watch are the remote.

LONG SETS
Now Playing shows the whole waveform, readable from across the room, with every comment pinned to the second it was left and the tracklist alongside. Sounding pieces the tracklist together from the uploader's notes, the comments and Shazam.

AUTO MIX
Auto Mix beat-matches the next track and brings it in on the phrase. Pick a personality (Wedding DJ blends and cuts clean, Junkie loops, ramps the tempo and jumps through a long set) and let it follow the time of night, or the heart rate of whoever's wearing the Apple Watch. If it hasn't measured where the bars are, it cuts cleanly on the bar instead of faking it.

DECKS FROM THE SOFA
Run two decks on the TV from your iPhone or iPad: crossfader, three-band EQ and a filter on each, loops and hot cues. Cue points you set on your Mac show up here too. Using the decks with SoundCloud tracks needs Go+ or DJ.

LISTEN TOGETHER
SharePlay plays the same set at the same moment for everyone on the call. Each of them streams it with their own SoundCloud account.

THE REST
A Top Shelf with what you actually played, downloads for when the connection drops (Go, Go+ or DJ), and HomeKit lights that follow the music if you want them to.

PRIVACY
No Sounding servers, no Sounding account, no analytics and no ads. Your sign-in stays on your devices, and sync goes through your own iCloud. Promoted posts in your SoundCloud stream show up labelled Promoted, as they do in SoundCloud's own apps.

Sounding is an independent app. It isn't affiliated with or endorsed by SoundCloud. You'll need a SoundCloud account, and an iPhone or iPad to sign the TV in.
```

### Keywords (max 100)

```
dj,decks,mixer,automix,sets,tracklist,waveform,big screen,top shelf,shareplay,party,remote,bpm
```

### What's New (max 4000)

```
Hello. This is Sounding's first App Store release on Apple TV, after quite some months on TestFlight. If anything breaks, tell me at sounding@alex.forbes.red.
```

## 5. Mac version

### Promotional text (max 170)

```
Two decks, Prep for beat grids and cue points, rekordbox in and out, and Auto Mix that reads your cues. Works with your SoundCloud account.
```

### Description (max 4000)

```
Sounding is a player for your SoundCloud on the Mac, built around long sets, with a proper DJ side. I make it on my own, in Amsterdam.

Sign in with your SoundCloud account (or let your iPhone sign the Mac in) and your likes, playlists and the people you follow are all there. Nothing to import.

BEFORE YOU DOWNLOAD
Playing SoundCloud tracks in Sounding needs SoundCloud Go, Go+ or DJ. Sounding shows no ads, and SoundCloud's ads can't run in an app that isn't SoundCloud's, so a paid plan is the honest way to do it. Go+ tracks need Go+ or DJ, and so do the decks and Prep with SoundCloud tracks. On a free account you can still browse, and play and mix your own music.

LONG SETS, PROPERLY
Now Playing shows the whole waveform with every comment pinned to the second it was left. Anything six minutes or longer gets the Tape along the bottom of the window, with the tracklist marked along it. Sounding pieces the tracklist together from the uploader's notes, the comments and Shazam.

TWO DECKS
Two decks and a crossfader, three-band EQ and a filter on each side, four hot cues a deck, loops you can halve and double, and an echo for the lazy exit. Sync and key lock are there for when your ears need a hand, and each deck takes an Audio Unit effect. Plug in a DDJ-400 and it's mapped already.

PREP IT ONCE
Prep is a window for every track you're getting ready: its beat grid, key and cue points. Sounding works the grid out itself and it's usually right. When it isn't, set the downbeat, nudge it, halve or double the tempo, then lock it. Hot cues A to H, in colour, plus memory cues and loops.

YOUR CUES, ON EVERYTHING
Cue points sync through your own iCloud, so they're on your iPhone, iPad and Apple TV too. Auto Mix reads them: a hot cue called Drop is somewhere it can bring a track in.

AUTO MIX
Auto Mix beat-matches the next track and brings it in on the phrase. Pick a personality (Wedding DJ blends and cuts clean, Junkie loops, ramps the tempo and jumps through a long set) and let it follow the time of night. Every transition is kept in Mixes, so you can play the good one again.

REKORDBOX AND CDJS
Import your rekordbox.xml and Sounding matches it to your library. Export makes a new XML file with your grids and cues (Sounding never touches your own rekordbox library). On the same network as CDJs, Sounding sees what each player's doing, writes the setlist for you, and can join as a virtual deck. Export to USB writes a stick a CDJ can read, from your own files.

YOUR OWN MUSIC
Add a folder of your own audio files. It plays, mixes and preps like everything else, on any plan.

AND THE REST
A mini player in the menu bar, Play On for your Apple TV, AirPlay and Sonos, SharePlay to listen together, and downloads with Go, Go+ or DJ.

PRIVACY
No Sounding servers, no Sounding account, no analytics and no ads. Your sign-in stays on your devices, and sync goes through your own iCloud. Promoted posts in your SoundCloud stream show up labelled Promoted, as they do in SoundCloud's own apps.

FAIR WARNING
The DJ side is the newest corner of Sounding. The CDJ and USB features have only met a fake CDJ I wrote, not a club rig. Tell me how it goes: sounding@alex.forbes.red

Sounding is an independent app. It isn't affiliated with or endorsed by SoundCloud or AlphaTheta. You'll need a SoundCloud account.
```

### Keywords (max 100)

```
dj,decks,mixer,prep,rekordbox,cdj,ddj-400,midi,automix,cue,beatgrid,bpm,key,tracklist,menu bar
```

### What's New (max 4000)

```
Hello. This is Sounding's first App Store release on the Mac, after quite some months on TestFlight. If anything breaks, tell me at sounding@alex.forbes.red.
```

## 6. Age rating answers

Applied through `ageRatingDeclarations`. Sounding plays third-party content and shows third-party comments and messages, so the content answers follow what a user can come across, not what Sounding itself ships.

| Question | Answer |
| --- | --- |
| Parental controls | No |
| Age assurance | No |
| Unrestricted web access | No (the only web view is SoundCloud's sign-in page) |
| User-generated content | Yes |
| Messaging and chat | Yes (SoundCloud messages) |
| Advertising | No |
| Health or wellness topics | No |
| Medical or treatment information | None |
| Profanity or crude humour | Infrequent or mild |
| Horror or fear themes | None |
| Alcohol, tobacco or drug references | Infrequent or mild |
| Mature or suggestive themes | Infrequent or mild |
| Sexual content or nudity | None |
| Graphic sexual content and nudity | None |
| Cartoon or fantasy violence | None |
| Realistic violence | None |
| Prolonged graphic or sadistic violence | None |
| Guns or other weapons | None |
| Simulated gambling | None |
| Gambling | No |
| Contests | None |
| Loot boxes | No |
| Social media | Yes |

Social media: Yes (follows, comments and messages on SoundCloud). Let ASC compute the rating. No override. ASC computed 12+ on 2026-11-08.

## 7. App Privacy

Findings from the code:

- No third-party SDKs at all: no Swift packages, CocoaPods or Carthage. `git grep` for Firebase, Crashlytics, Sentry, Mixpanel, Amplitude, AppsFlyer, Bugsnag, Datadog, PostHog and MetricKit finds nothing. No AdSupport or AppTrackingTransparency import, so no tracking and no ATT prompt.
- The only network hosts are SoundCloud's (`soundcloud.com`, `api-v2.soundcloud.com`, `api.soundcloud.com`, `secure.soundcloud.com`, and the `sndcdn.com` and `media-streaming.soundcloud.cloud` content hosts), plus the sample-art hosts used only by DEBUG fixtures. There is no Sounding backend.
- SoundCloud sign-in happens in SoundCloud's own web page. Tokens are stored in the Keychain on the user's devices and passed between the user's own devices over the local network, signed with a pairing secret.
- Sync uses `CKSyncEngine` against the user's private CloudKit database (`iCloud.red.forbes.sounding`): sessions, cue points, analysis results, download manifests, setlists, settings and the list of the user's devices. The developer cannot read a private database.
- ShazamKit (`SetlistIntelligenceStore`) is used on the Mac and Apple TV to identify tracks inside long mixes from audio signatures of the playing stream. It does not use the microphone and has no microphone permission. Matching is done by Apple.
- The camera is used on iPhone only, to scan the link code shown on an Apple TV. Nothing is stored or sent.
- Local network is used to find and talk to the user's own Apple TV, Mac and iPhone.
- Lyrics (opt-in): after the user turns on Lyrics from LRCLIB, the app sends the playing track's title, artist, album (when known) and length to `lrclib.net`, a free third-party lyrics database, with no account, token or device identifier. Nothing is sent until the user agrees. Details in `app-privacy.md`.

### Recommended answer

Data collection: **Data Not Collected** is accurate for the developer: nothing is sent to any server the developer or a partner controls. The app does send the user's activity to SoundCloud, the service they chose to sign in to, exactly as a web browser would. If the account owner prefers to declare that as well (the more cautious reading of Apple's definition), declare the following and nothing else.

| Data type | Linked to user | Used for tracking | Purposes |
| --- | --- | --- | --- |
| Identifiers: User ID (SoundCloud account ID) | Yes | No | App functionality |
| User content: Other user content (likes, playlists, comments the user posts) | Yes | No | App functionality |
| Usage data: Product interaction (plays and likes sent to SoundCloud) | Yes | No | App functionality |

Not collected in either reading: contact info (email is not read), health, financial, location, sensitive info, contacts, search history stored by the developer, browsing history, diagnostics, purchases, device ID, advertising data.

Tracking: No. The answer to "does this app or its third-party partners track users" is No.

### Privacy nutrition label on the product page

If "Data Not Collected" is chosen it reads "Data Not Collected". Otherwise it reads "Data Linked to You: Identifiers, User Content, Usage Data".

## 7. Privacy policy draft

Publish this at `https://sounding.forbes.red/privacy` (a page that `docs/` does not have yet; the site is served from `docs/` through `docs/CNAME`).

```
Sounding privacy policy

Sounding is an independent app made by Alexander Forbes-Reed. It is not affiliated with SoundCloud.

What Sounding collects
Nothing. Sounding has no servers, no accounts of its own, no analytics, no advertising and no third-party SDKs. I do not receive any data about you or your use of the app.

What Sounding does with your SoundCloud account
You sign in on SoundCloud's own page. Sounding keeps the resulting sign-in in the Keychain on your device and only sends it to SoundCloud, to fetch your library and play your music. When you like a track, comment or follow someone, that request goes straight to SoundCloud. SoundCloud's own privacy policy applies to that data.

What stays on your devices
Downloads, analysis results, cue points, setlists and settings are stored on the device. If you are signed in to iCloud they sync between your own devices through your private iCloud container. I cannot read that container.

Moving your sign-in between your devices
When you link an Apple TV, Mac or Apple Watch, your iPhone sends the sign-in to it directly over your local network, signed with a one-time secret. It does not pass through any server.

Camera and local network
The camera is used on iPhone only to scan the code on your Apple TV. Local network access is used to find your own devices. Neither is stored or shared.

Song identification
Sounding for Mac and Apple TV can identify tracks inside long mixes using Apple's ShazamKit. Apple's privacy policy applies to that.

Deleting your data
Sign out in Settings to remove the sign-in from your devices. Remove the app to remove everything stored on it. Delete the iCloud data for Sounding in Settings, Apple Account, iCloud, Manage Storage.

Contact
sounding@alex.forbes.red
```
The answers to click through are in `app-privacy.md`.

## 8. Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in the iOS, tvOS, watchOS and macOS app Info.plists, and every uploaded build shows `usesNonExemptEncryption = false` in ASC. Nothing else to file. The only encryption is HTTPS, Apple's own (Keychain, CloudKit) and CryptoKit for authenticating the local device link, all exempt. No French declaration is needed.

## 9. App Review information

### Notes (max 4000)

```
Sounding is an independent player for SoundCloud. It isn't affiliated with SoundCloud and doesn't use SoundCloud's logo or branding.

A SoundCloud account is required. Sign-in uses SoundCloud's own web sign-in page, shown in the app. Sounding never sees the password.

A paid SoundCloud plan is needed to play SoundCloud tracks. SoundCloud funds free listening with its own audio ads, and those ads can only be served by SoundCloud's apps. Sounding shows no ads and does not try to serve or fake them, so SoundCloud playback needs SoundCloud Go, Go+ or DJ, as checked from the signed-in account. On a free account the app explains this and links to SoundCloud's plans page. Sounding sells nothing itself and has no in-app purchases.

The demo account below has a paid plan, so playback works. Without a paid plan you can still browse, and test playback with local files:
- iPhone and iPad: Library, Files, Add Folder, and pick a folder of audio files (for example in On My iPhone).
- Mac: in the sidebar, On This Mac, Add Folder, and pick a folder of audio files.
Local files play, Auto Mix and load onto the decks on any plan.

Apple TV: the TV has no sign-in form. On the TV, choose Sign In. Then, on an iPhone or iPad signed in to Sounding, go to Settings, Devices, and add the Apple TV. Keep the phone near the TV while it plays a short chime, and the phone signs the TV in. If the microphone isn't available, choose Use QR Code Instead on the phone and scan the code on the TV. The TV's Sign in with iPhone button also offers any nearby iPhone through the system device picker. Both devices must be on the same Wi-Fi network.

Mac: sign in with SoundCloud's web page in the app, or let an iPhone on the same network sign the Mac in from Settings, Devices.

DJ features (two decks, Prep, rekordbox import and export, CDJ link and USB export) are on the Mac. On iPhone and iPad the decks control an Apple TV. Using the decks with SoundCloud tracks needs Go+ or DJ. Local files work on any plan.

The Apple Watch app is a remote for the iPhone. Heart rate (Match My Workout) and HomeKit lights are off until the user turns them on.

There are no Sounding servers and no Sounding accounts. Sync uses the user's private iCloud database.
```

### Contact

Copied from the TestFlight Beta App Review contact already set in ASC (the account holder). The owner should check it.

### Demo account

`demoAccountRequired` is on, and the name and password are empty. **Owner TODO:** a SoundCloud account with Go+ (so the decks and Go+ tracks can be reviewed), a few likes and playlists, and no two-factor prompt. The owner's own credentials can't be used.
