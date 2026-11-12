# SoundCloud tiers in Sounding

Researched on 2026-11-08. Sounding follows SoundCloud's tier rules as SoundCloud's own apps do.

**Status of ads:** SoundCloud's ads can't be served without a deal with SoundCloud (full research: `/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/ads-research/REPORT.md`), and Sounding plays none.

## 1. What SoundCloud allows, per tier

| Tier | Ads | Offline downloads | Go+ catalogue | Audio quality | DJ-software access |
|---|---|---|---|---|---|
| Signed out | Ad-supported [^ads] | No | 30 s previews | AAC 96k / 160k | No |
| Free | Ad-supported | No | 30 s previews | AAC 96k / 160k | No |
| Go | Ad-free | Yes (mobile apps) | 30 s previews | Standard (160k) | No |
| Go+ (incl. Student) | Ad-free | Yes | Full | AAC up to 256k | Streaming in select DJ apps, home and private use only |
| DJ | Ad-free | Yes | Full | AAC up to 256k | Streaming in all supported DJ apps; offline in VirtualDJ and rekordbox only |
| Artist / Artist Pro (creator plans) | No listener perks; Artist Pro gets 50% off Go+ | No | Previews | Free tier | No |

[^ads]: SoundCloud doesn't document whether signed-out listeners hear ads. Embedded players can carry ads, and Go+ tracks are always previews when signed out.

Rules that apply on top of the table:

- **Downloads.**
  - Signing out deletes saved tracks.
  - Rights holders can turn offline off per track.
  - The account must sign in at least once every 30 days, or its offline content is removed.
  - When a plan is cancelled, the account goes back to the free, ad-supported experience.
- **Go+ catalogue.** Rights holders choose which tracks are Go+-only. Anyone not entitled hears a 30-second preview.
- **Ads.**
  - Formats are audio ads between songs (web, mobile, embeds), 15 s video pre-rolls on mobile, display banners and interstitials.
  - SoundCloud doesn't officially publish how often ads play, how long they are, or the skip rules. User reports say an ad every 2–3 tracks, 15–30 s each, and mostly unskippable.
  - Changing ad preferences doesn't change how many ads you get.

Sources:
- Choosing the Right Subscription (updated 2026-11-08): https://help.soundcloud.com/hc/en-us/articles/360051072534
- Get Started with SoundCloud Go (previews): https://help.soundcloud.com/hc/en-us/articles/360052599653
- Audio Streaming Formats: https://help.soundcloud.com/hc/en-us/articles/53385714099611
- High Quality Streaming: https://help.soundcloud.com/hc/en-us/articles/360051838074
- Offline listening: https://help.soundcloud.com/hc/en-us/articles/31354612612763
- Go / DJ terms (01-2026, 30-day sign-in rule): https://pages.soundcloud.com/geo/uk_us_ie/legal/go-terms-of-use/01-2026.std.html
- Cancelling Go: https://help.soundcloud.com/hc/en-us/articles/360051638314
- Start DJing with SoundCloud: https://help.soundcloud.com/hc/en-us/articles/31378025645595
- Serato: https://help.soundcloud.com/hc/en-us/articles/360051732133
- rekordbox: https://help.soundcloud.com/hc/en-us/articles/360051731553
- djay: https://www.algoriddim.com/streaming
- Plans page: https://soundcloud.com/company/plans/
- Artist / Artist Pro rename (Dec 2024): https://techcrunch.com/?p=2932941
- Advertising formats: https://soundcloud.com/company/advertise/ and https://www.siriusxmmedia.com/advertising-on-soundcloud
- Ads on SoundCloud: https://help.soundcloud.com/hc/en-us/articles/115003447287
- Ad settings: https://help.soundcloud.com/hc/en-us/articles/360004223094
- Embedding Go+ tracks: https://help.soundcloud.com/hc/en-us/articles/115003448167

## 2. Why Sounding can't serve SoundCloud's ads

- **How soundcloud.com does it.** It calls the undocumented `api-v2 /audio-ads?track_id=…`, a pre-roll before `policy == MONETIZE` tracks for accounts without `no_audio_ads`. Google Ad Manager and AdsWizz serve the ads, and the server sets the cadence and caps.
- **The terms rule it out.** The public API has no ad endpoint, and its Terms ban "any advertising… around User Content" (§06) and data "not intended for your use".
- **It would be spoofed traffic.** Requesting those ads from Sounding would pass Sounding's traffic off as soundcloud.com inventory. SoundCloud's `ads.txt` / `app-ads.txt` don't cover Sounding, so it would count as invalid traffic (MRC SIVT), with SoundCloud's Google account carrying the risk.
- **No route in.** There's no partner programme open to third-party players.
- **Faking it isn't an option.** Inventing ads isn't allowed either.

## 3. What Sounding allows

`SoundCloudEntitlements` in `Core/SoundCloud/SubscriptionService.swift` is the one place these rules live.

| Feature | Signed out | Free | Artist plans | Go | Go+ | DJ |
|---|---|---|---|---|---|---|
| Play SoundCloud tracks that aren't Go-restricted (incl. Auto Mix, Sonos, AirPlay, TV output, SharePlay) | No | Yes | Yes | Yes | Yes | Yes |
| SoundCloud's own 30 s previews (snipped transcodings), local output and AirPlay only | Yes | Yes | Yes | Yes (Go+ tracks) | Only when SoundCloud sends nothing else | Only when SoundCloud sends nothing else |
| `MONETIZE` tracks (`monetizedTracksOpen = true`) | No | Yes | Yes | Yes | Yes | Yes |
| Go+ catalogue tracks (`SUB_HIGH_TIER` or `SNIP`) | Preview | Preview | Preview | Preview | Yes | Yes |
| Download tracks that aren't Go-restricted | No | Yes | Yes | Yes | Yes | Yes |
| Download Go+ catalogue tracks | No | No | No | No | Yes | Yes |
| Manual DJ decks, controllers, Prep grid/cue editing with SoundCloud tracks (streaming) | No | No | No | No | Yes | Yes |
| Export to USB with SoundCloud audio | No | No | No | No | No | No |
| Any DJ gear, Personal build with the hidden unlock | Yes | Yes | Yes | Yes | Yes | Yes |
| Own files (local music, rekordbox-linked files) | Yes | Yes | Yes | Yes | Yes | Yes |
| See promoted feed items, labelled "Promoted" | Yes | Yes | Yes | Yes | Yes | Yes |

Behaviour:

- **The per-track gate.**
  - A track is Go-restricted when `monetization_model` is `SUB_HIGH_TIER`, its `policy` is `SNIP`, or it has only `snipped` transcodings; and, only if `monetizedTracksOpen` is turned off, when its `policy` is `MONETIZE`. `SoundCloudEntitlements.isGoRestricted(_:)` states it.
  - `.playback` and `.downloads` need only a signed-in account (`isOpenToEverySignedInAccount`), whatever the plan and whether or not it is confirmed. A Go-restricted track adds `.goPlusTrack` (or `.monetizedTrack`), which needs the plan as before. `SoundCloudEntitlements.trackDenial(for:feature:…)` and `canDownload(_:…)` are the pure per-track checks; `SubscriptionService.denial(for:feature:)` wraps them for the live account.
  - Signed out is unchanged: SoundCloud's previews only, and "Sign in to SoundCloud to play tracks." / "Sign in to SoundCloud to download."
- **Previews.** Owner decision, 2026-11-08.
  - `Track` keeps snipped transcodings apart as `previewTranscodings`; `transcodings` stays full-track only, so downloads, mix sources and deck loads never see a preview. A preview-only track gets its `streamURL` and `duration` from the preview.
  - `SoundCloudEntitlements.playbackGrant(for:…)` returns `.full`, `.preview` or `.denied`. When full playback is denied and the track has a preview, the grant is `.preview`; with no preview it's the denial ("This track needs SoundCloud Go+." or, signed out, "Sign in to SoundCloud to play tracks."). An entitled account gets `.preview` only when SoundCloud sent nothing but the preview.
  - `PlaybackSourceResolver` streams the best preview transcoding exactly as supplied, with no extension or looping, and never cuts a full track itself. Decoded audio (decks, Prep, analysis, Auto Mix decks, export) refuses a preview with `.previewOnly`.
  - Previews always play on the AVPlayer path, never in the mix engine. `PlayerService.upcomingMixTrack` (`SoundCloudEntitlements.blendableNext`) is nil into or out of a preview, so Auto Mix hard-stops and the next track starts. Previews are refused while Sonos needs the engine output or a SharePlay session is active.
  - The scrubber uses the preview's length. Rows show "Preview · 0:30" in place of the duration (Mac table: a "Preview" label by the title), and Now Playing shows "Preview · 0:30" under the artist.
  - When a preview ends, once per launch, the entitlement alert says "Full track needs SoundCloud Go+.", titled "Preview Ended", with **Subscribe in SoundCloud**; Apple TV shows OK only. "Full track needs SoundCloud Go or Go+." is used only for a `MONETIZE` preview while `monetizedTracksOpen` is off.
  - Tests: `SoundCloudTierTests` and `TrackGateTests` (free × normal = full + download; free × Go+ = preview, no download; Go, Go+ and DJ as before; signed out as before; downloads pick the entitled quality).
- **Go+ tracks on Free, Artist and Go.** Tracks marked `SUB_HIGH_TIER` or `SNIP` need Go+, which also covers stale caches and downloads made before a downgrade.
- **Download source.** Downloads take the best full transcoding the account is entitled to: progressive first, then HLS, never opus, under the quality ceiling. On Free, Artist and Go, `hq` transcodings are skipped whenever a standard one exists (`DownloadSourceSelection.allowsHighQuality(for:)`). SoundCloud resolves the stream URL with the user's own session, so the URL is the one their plan may fetch. Files stay encrypted in the app container and are never exported.
- **Unconfirmed plan.** A paid plan keeps its Go+ extras for 10 days while it can't be confirmed (offline). After that the account counts as Free: non-restricted tracks keep playing and downloading, Go+ tracks and DJ streaming stop.
- **Removing downloads.** On a confirmed plan, downloads the plan no longer covers (Go+ tracks after a drop to Go or Free) are removed; on a confirmed unpaid plan that happens 7 days after the lapse. Every download is removed after 30 days without a confirmed sign-in (SoundCloud's 30-day rule), on any plan (`DownloadManager.entitlementSweep`). Go+ downloads stop playing straight away when the plan lapses; Settings warns only while Go+ downloads are due to go.
- **DJ gear.**
  - One pure check, `SoundCloudEntitlements.djGearDenial(feature, isSoundCloudTrack, tier, …, personalUnlocked)`, covers it. On the Mac it's wrapped by `MacDeckControlSurface.djDenial`, which adds the Personal unlock (`dj-gear.md` §9a).
  - Every DJ surface uses it: deck loads (`MacMixLoader`), the controller gate (`ControllerDeckAccess.allowsStreaming`), Prep's track list, and the USB export's SoundCloud fetch.
  - Prep hides SoundCloud tracks without a linked file when the plan doesn't allow them.
  - Auto Mix is ordinary playback, so Free accounts Auto Mix every track they may play.
- **SharePlay.** Each participant resolves audio through their own account.
- **Apple TV.** The Apple TV checks its own session.
- **Copy.**
  - "This track needs SoundCloud Go+."
  - "Full track needs SoundCloud Go+." (when a preview ends)
  - "DJ decks need SoundCloud Go+ for SoundCloud tracks."
  - "Export to USB works with your own music."
  - "Sign in to SoundCloud to play tracks." / "Sign in to SoundCloud to download."
  - "Couldn't confirm your SoundCloud plan." (Go+ tracks and DJ gear only)
  - Plan footers: "SoundCloud Free. Go+ tracks play as previews." / "A SoundCloud artist plan. Go+ tracks play as previews."
  - "Playback needs SoundCloud Go or Go+." and "Downloads need SoundCloud Go or Go+." remain in code only for `monetizedTracksOpen = false`.

  On iPhone, iPad and Mac the alert offers **Subscribe in SoundCloud** (https://soundcloud.com/go) only for Go-restricted tracks and DJ gear. Apple TV shows **OK** only.

## 4. Promoted feed items

- **Decoding.** `/stream` items of type `track-promoted` / `playlist-promoted`, or any item carrying `promoted {ad_urn, tracking}`, decode into `FeedActivity.promoted` (`Core/Models/PromotedContent.swift`). `StreamItem` keeps `type` and `promoted` too.
  - Tracking keys are classified by name: impression, play (played), click (clicked). This covers both a nested `tracking` object and top-level `tracking_*_urls`.
  - Only https URLs are kept.
- **Display.** iPhone, iPad, Mac and Apple TV show "Promoted", or "Promoted by …" when a promoter is given, in place of the repost line.
- **Tracking.** `PromotedTracking` fires SoundCloud's own URLs, as SoundCloud's apps do:
  - **Impression:** once the item is at least 50% visible for 1 s (`onScrollVisibilityChange`), once per item.
  - **Play:** when the user plays a promoted track.
  - **Click:** when the user opens a promoted playlist.
  - Each event fires at most once per item.
- **Never fires:**
  - in the background;
  - in fixtures, UI tests or XCTest;
  - in snapshot harnesses;
  - with the mock service;
  - while the SoundCloud traffic stop is active;
  - beyond 30 URLs a minute.

  Requests are ephemeral and cookie-less.
- **Tests.** `PromotedFeedTests` records URLs with a stub transport and never touches the network.

## 5. Open points

- The DJ plan's product id isn't documented. Sounding accepts `consumer-dj` and `consumer-dj-tier`. Any other id shows as an unrecognised plan in Settings, with the raw id, so it can be added.
- The Go+ Student product id isn't documented either. If it isn't `consumer-high-tier`, it shows as unrecognised in the same way.
- **Reading the plan** (`SubscriptionService.verifyNow`). The plan comes from api-v2 `/me`: any key naming a subscription (`consumer_subscription(s)`, `creator_subscription(s)` or a new spelling), as a product object, a `product_id`, a bare id or a `collection` list. When that body carries no readable plan, Sounding asks the documented `api.soundcloud.com/me` once (its `subscriptions` list), and stops asking for that account for the rest of the launch if it has nothing either. Only exact product ids count. Go, Go+ and DJ ids are read from any of these; Free and Artist only from SoundCloud's own consumer and creator keys, and an empty `consumer_subscriptions` list. `plan` names ("Free", "Pro Unlimited") never decide anything, and the documented `subscriptions` list never makes an account Free or Artist, since that would start the 7-day removal of Go+ downloads. Anything else stays unknown: the last confirmed plan holds through its grace period, and the outcome is logged once per launch, with `/me`'s key names when no plan key was present.
- The exact `promoted.tracking` key names weren't captured live. They're inferred from the web bundle, and the classifier matches by substring.
- The ads research advises against firing promoted pixels, for the same invalid-traffic reason as audio ads. The owner chose to fire them faithfully, only on genuine events.
- The public API Terms also forbid offline storage and Go+-only content without a separate agreement. Sounding uses SoundCloud's web endpoints rather than a registered public-API app, so this is an owner-level risk, not a code question.
