# Brief: new website for Sounding (sounding.forbes.red)

Repo root: `/Users/afr/Source/github.com/0xdeafcafe/sounding-tv/.claude/worktrees/6a3b0b5d`. The live site is static, served from `docs/` (GitHub Pages; `docs/CNAME` = sounding.forbes.red).

## What Sounding is
An independent SoundCloud client for iPhone, iPad, Apple Watch, Apple TV and Mac. It is **not affiliated with SoundCloud**, and every page must say so in the footer. It is about to ship via TestFlight and then the App Store, so the old badge "Not on the App Store" goes.

Features, accurate as of now:
- **Now Playing.** A calm, always-dark screen: big artwork, a blurred backdrop drawn from the artwork, a clean waveform, and timed SoundCloud comments that follow the playhead. Modes for Up Next, Comments and Tracklist.
- **Tracklists for DJ mixes.** The current track is highlighted as the mix plays. Identify (ShazamKit) names a track. Saved tracklists live in Library → Setlists.
- **Decks.** Two decks, crossfader, EQ, filter, hot cues, loops and jog wheels. Auto Mix beat-matches the next track. On iPhone, the decks also act as a remote for the Apple TV.
- **Output.** Move playback between iPhone, Mac and Apple TV, and control the TV from your phone or Mac. Several devices can be linked to one Apple TV.
- **Music analysis.** On-device tempo, key and genre, shown on track rows.
- **Downloads** that work like Apple Music: playlists stay in sync, Optimise Storage, encrypted on disk.
- **Apple Watch** controls. **Polyphony**: play in time across nearby devices.
- **Privacy.** No servers, no accounts of its own, no analytics. Sync goes through the user's own iCloud.

## Brand
- **The icon:** a photographed copper 3.5 mm audio jack on black felt. See `Branding/Sounding-iOS-AppIcon-Master.png`, `Branding/Sounding-tvOS-AppTile-Master.png` and `Branding/Sounding-TopShelf-Master.png`.
- **The app's welcome art:** procedural copper line art. Echoing outline contours of a jack, cables, sound rings and wave lines, over flat colour masses in copper, brass, verdigris, rose copper and cream. Headline: "Plug in. Turn it up." See `Design/appstore/screenshots/iphone/iphone-4-welcome.png` and `Shared/Design/SoundingLineArt.swift` for the motif.
- **Tone:** calm, confident, British English ("optimise", "colour"), short sentences, no hype words.

## Assets you may use
- **App screenshots:** `Design/appstore/screenshots/{iphone,ipad,macos,tvos,watch}/`.
- **Now Playing prototype screenshots:** `Design/prototypes/now-playing/shots/`. These show the newest design, so prefer them for Now Playing.
- **App Store listing copy:** `Design/appstore/metadata.md`.

## Hard requirements
- Static HTML, CSS and vanilla JS only. No build step, no frameworks, no CDN or external network requests. Use system fonts (`-apple-system`, SF Pro). Copy any images you use into the site folder.
- Fast and accessible: semantic HTML, keyboard support, `prefers-reduced-motion`, and `prefers-color-scheme` (light and dark). Respectable Lighthouse numbers. Images must be compressed: convert PNG screenshots to downscaled WebP or JPEG, under ~250 KB each.
- Motion should be subtle and smooth; animate only transform and opacity. A tasteful version of the line-art "draw-on" for the hero is welcome.
- Pages:
  - Home: a hero, then features by area, platforms, privacy, a TestFlight / "Coming to the App Store" call to action, and a FAQ.
  - Privacy: keep the existing `docs/privacy/index.html` content verbatim, restyled to the new look.
  - Support: contact `sounding@alex.forbes.red`, and how to send TestFlight feedback.
- **Must NOT break or remove:**
  - `docs/auth/index.html`, an OAuth redirect page the app depends on. Leave it byte-identical.
  - `docs/CNAME`.
  - The existing `docs/*.md` files.
- Never use SoundCloud's logo, wordmark or orange cloud. "SoundCloud" appears only in descriptive text.
