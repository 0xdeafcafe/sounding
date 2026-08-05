# SoundingCloud review worklist

This is the deduplicated implementation and QA list from the macOS review session.

Legend:

- `[ ]` outstanding
- `[~]` implemented or partly implemented, but still needs visual/behavioural verification
- `[x]` verified in the current build
- `Decision` records a deliberate constraint or a request that was later superseded

## P0 — responsiveness, hangs, and crashes

- [x] Stop Likes loading from synchronously encoding, encrypting, and atomically rewriting the whole download index once per track.
- [x] Batch collection download-policy updates and persist one snapshot instead of one snapshot per row.
- [x] Move encrypted download-index persistence off the main actor and coalesce stale snapshots.
- [x] Stop eagerly preloading Home, Feed, Artists, Likes, Library, and Playlists at application launch.
- [x] Move automatic downloaded-track decryption/intelligence resume work off the main actor.
- [x] Move account-vault read, decrypt, and JSON decoding off the main actor; latest steady-state sample shows no vault/index/crypto work on the main thread.
- [ ] Profile every major cold-start destination and enforce that disk IO, crypto, artwork decoding, API pagination, and audio analysis never run synchronously on the main actor.
- [ ] Add launch responsiveness regression coverage/signposts and a watchdog metric for main-thread stalls.
- [ ] Reproduce and fix the `CrBrowserMain` crash around the embedded sign-in browser.
- [ ] Reproduce the earlier general crash report and symbolicate any remaining crash logs.
- [ ] Confirm long lists remain responsive while artwork, waveform, analysis, downloads, and pagination are active.

## Window, headers, navigation, and layout

- [ ] Never show the same destination title twice: remove content-level `All Playlists`, `My Playlists`, and similar headings when the toolbar/header already names the page.
- [ ] Put every contextual filter/search field in the header/toolbar, aligned to the right; Global Search remains the one centered search surface.
- [~] Move the Likes/Library filter from the principal/center toolbar position to the trailing header actions.
- [~] Put the Artists filter at the top of the artist source-list column rather than floating over the detail page.
- [~] Make Command-K focus the current page’s search/filter; retain Command-F as a compatible shortcut.
- [ ] Apply the header-search rule consistently to playlist groups, playlist details, artist lists, Likes, Library, Sets, and other filtered destinations.
- [~] Keep root-level Back and Forward buttons with a remembered navigation stack.
- [ ] Ensure Back/Forward controls appear consistently in the header on all pushed artist, album, and playlist pages.
- [ ] When an artist is opened from Search, Activity, a table, or a context menu, select/highlight Artists in the main sidebar instead of leaving the old destination selected.
- [ ] Outside the Artists destination, open artist detail full-width by default.
- [~] Add a toolbar button on standalone artist detail to reveal/hide an optional followed-artists browser.
- [ ] Opening an artist from the optional browser must preserve correct Back/Forward history.
- [ ] Align floating side controls, disclosure controls, transport, and content edges to the page grid.
- [ ] Remove clipping at the top of Home and allow the title/content to scroll naturally without a redundant fixed header.
- [ ] Fix remaining broken panel dividers, black strips, mismatched backgrounds, and content clipping at narrow and wide window sizes.

## Global Search

- [~] Match Apple Music’s search information architecture: compact sticky header, centered hero field, trailing SoundCloud/Library scope switch, and content scrolling underneath.
- [~] Remove the large dead area and duplicate search header.
- [~] Add recent searches above Browse Categories.
- [~] Use five category tiles across on wide windows and adapt gracefully at smaller widths.
- [~] Add a rich suggestion panel with query suggestions, artists, tracks, and albums instead of text-only suggestions.
- [~] Keep the visual language SoundCloud-like: graphite glass, restrained orange focus/accent, artwork-led results; do not copy Apple’s rainbow treatment literally.
- [ ] Verify suggestion click behaviour: query fills/searches, artist routes through root Artists navigation, album opens detail, and track starts playback.
- [ ] Ensure the suggestion panel is keyboard navigable and handles Return, arrows, Escape, and accessibility focus.
- [ ] Ensure search header material responds cleanly while hovering/scrolling and never jumps between states.
- [ ] Confirm SoundCloud and Library scopes preserve independent query state and correct empty/results states.
- Decision: do not add global SoundCloud search to every contextual search field; contextual fields only filter their current view.

## Sidebar

- [ ] Finalize sidebar icon size between the earlier oversized and later undersized versions; keep a consistent optical box, stroke weight, and baseline.
- [ ] Replace the Polyphony icon with a distinct, legible nearby-playback mark.
- [ ] Keep sidebar item text slightly smaller and white while preserving current icon size once finalized.
- [ ] Ensure labels never collide with icons or truncate unnecessarily at the normal sidebar width.
- [ ] Give All Playlists a distinct root icon.
- [ ] Make All Playlists a root item under the Playlists section.
- [ ] Group My Playlists and Liked Playlists into separate collapsible folders.
- [ ] Clicking either folder shows all playlists in that group; disclosure toggles collapse without unwanted navigation.
- [ ] Preserve playlist privacy indicators and folder state across launches.
- [ ] Replace the Profile sidebar/header label with `@username`, not the prettified full name.

## Playlist pages and playlist sidebar

- [ ] Remove duplicate `All Playlists` / `My Playlists` page headings when navigation/header title is present.
- [ ] Keep playlist search/filter controls in the header bar at all times.
- [ ] Separate owned and liked playlists in both sidebar grouping and All Playlists content.
- [ ] Separate public and private playlists on a profile/user page.
- [ ] Show public/private status at a glance for the current user’s playlists.
- [ ] Let the current user change playlist privacy with confirmation/error feedback and sync the change.
- [ ] Cache artist/profile playlist-tab responses for a useful TTL so tab switches do not refetch immediately.
- [ ] Add row/card context menus from playlist views.
- [ ] Fix playlist hero button sizing, glass treatment, alignment, and colour consistency.
- [ ] Use a distinct icon for smart playlists and keep the clean smart-playlist detail layout.
- [~] Confirm SoundCloud pagination can move beyond the first saved item/page for likes and playlists; table near-end loading and progressive playlist pagination are now wired, needs live large-library verification.

## Artists list and artist/user pages

- [ ] Finalize Artists as a native split view: vibrancy source list, stable divider, full detail canvas, and no stray opaque panel backgrounds.
- [ ] Restore the intended source-list width and prevent the artist detail from disappearing at wide/narrow sizes.
- [ ] Keep artist row text white and use restrained hover/selection colours rather than brown/gray blocks.
- [ ] Filter non-artist profiles (zero public tracks) from the Artists list while still allowing those users to be found elsewhere.
- [ ] Clicking an artist anywhere routes to artist detail and updates the selected main sidebar destination.
- [~] Add an artist Overview tab/page rather than dropping directly into a utility track table.
- [~] Build a content-derived hero using the best recent track/album artwork, with the avatar/graphite-orange fallback when no banner media exists.
- [~] Center avatar, display name, `@username`, follower/track counts, description, and actions in the artist hero.
- [~] Add Latest Release, Recent Tracks, and Albums/Featured Sets overview sections.
- [ ] Decide and persist user-controlled preferred/pinned profile content when SoundCloud itself provides no pinned-content field.
- [~] Collapse artist identity into the header after the hero scrolls away: avatar, display name, `@username`, and follower count.
- [ ] Verify the collapsed identity appears/disappears smoothly and does not collide with search, Back/Forward, or artist-browser buttons.
- [~] Hide the primary Follow action after following; expose Unfollow in the overflow menu with confirmation.
- [ ] Show loading/error feedback for follow/unfollow and keep local Activity in sync.
- [~] Remove the redundant `Songs / Uploaded by…` subheader inside the Tracks tab.
- [~] Make the whole tab segment/pill clickable, not only its text.
- [ ] Apply full-segment hitboxes to every segmented/tab control in the app.
- [~] Structure Activity into Today, Yesterday, This Week, and Earlier with upload/repost/like summary counts.
- [ ] Add richer activity types for follow/unfollow and other actions performed in the app.
- [ ] Load Following and Followers lists, support pagination, and let their entries navigate to user/artist pages.
- [ ] Hide Play/Shuffle controls for profiles with no playable public tracks.
- [ ] Keep profile tabs modern, glassy, aligned, and responsive without clipping at narrower widths.

## Library, Likes, and track tables

- [ ] Restore clear hover feedback for Likes and every other track table.
- [ ] Remove the redundant second Play button on the right side of Likes rows.
- [ ] Make the artwork-overlay Play button actually start playback and show its interactive state.
- [ ] Right-click anywhere on a row—not just text/artwork—to open the row context menu.
- [ ] Add appropriate context menus in table, playlist, and artist views.
- [ ] Keep table item text white with readable secondary text.
- [ ] Use subtle alternating row backgrounds without producing segmented/boxed cell backgrounds.
- [~] Remove per-cell interaction backgrounds that caused broken gray blocks.
- [ ] Fix table column sizing and prevent Title, Deck, Artist, BPM, Key, Genre, Time, and Added from clipping or wasting space.
- [ ] Fix title/artwork/table-leading alignment on artist and library tables.
- [ ] Add tooltips for Deck A/B, send-to-deck, analysis buttons, and other icon-only controls.
- [ ] Keep BPM/Key/Genre fields visible in the table; show actionable Analyse controls only when values are missing.
- [~] Show queued/analysing/completed/retry UI for analysis rather than silently doing nothing.
- [ ] Make Analyse update immediately to queued/loading, report failures, and refresh BPM/Key/Genre on completion.
- [ ] Remove odd analysis-cell colours and match row background/foreground states.
- [ ] Allow genre correction/editing and sync the correction across devices.
- [ ] Persist music intelligence on macOS and other platforms, including analysis status and corrected values.
- [ ] Add or verify sorting by every supported table column.
- [ ] Investigate list-scroll lag with Instruments: placeholder artwork generation, image decoding, row observation fan-out, waveform rendering, and pagination.
- [ ] Use stable row identity and lazy rendering; prefetch only a small artwork lookahead.
- [~] Verify large SoundCloud collections paginate to completion and do not stop at the first API page; implementation now continues pages with delay/deduplication, needs live verification.

## Playback and transport

- [~] Keep the iPhone Live Activity synchronized across track changes, seeks, and play/pause: transport state now publishes before artwork/waveform enrichment, stale enrichment is cancelled, concurrent updates are serialized, and optimistic widget controls rebase the timer. Builds pass; real-device background/lock-screen verification remains.
- [~] Keep an always-present macOS transport bar showing the latest persisted track and allowing playback from it.
- [~] Use the app logo in the empty transport state.
- [x] Remove the unnecessary “Choose something to play” instruction.
- [x] Allow Queue/Up Next to open even when the queue is empty.
- [~] Reduce the whole transport’s maximum width and keep it centered.
- [ ] Finalize transport height and glass treatment against the Apple Music reference while retaining SoundCloud identity.
- [ ] Keep transport height constant on waveform hover; only let the waveform use more of the existing height.
- [ ] Use real waveform variance, not a flat picket-fence placeholder.
- [ ] Prevent current-time/playhead labels from overlapping waveform bars or controls.
- [ ] Keep compact and expanded waveform controls aligned and readable.
- [ ] Fix broken bottom transport backgrounds, clipping, and overlap with scrolling content.
- [ ] Ensure previous/play/next buttons reflect availability and always execute correctly.
- [ ] Persist and restore the latest playable item/queue safely when signed in or signed out.
- [ ] Confirm signed-out public tracks can play when SoundCloud allows streaming.
- [ ] Add/share/timed-comments/queue/AirPlay/volume affordances consistently without crowding narrow layouts.
- [ ] Improve the menu-bar icon and now-playing menu; persist latest track rather than always showing Nothing Playing.

## Downloads, access, and SoundCloud API behaviour

- [ ] Respect SoundCloud downloadability: stop/disable download only when the item has no downloadable/usable source.
- [ ] Preserve SoundCloud rate limits, Retry-After handling, backoff, and collection pagination.
- [~] Add rate-limit observability so the UI can distinguish cached, loading, throttled, and failed states. The shared API now exposes and publishes its persisted blocked/throttled-until state; destination-specific loading UI still needs wiring.
- [ ] Confirm all relevant endpoints from the official API guide are represented where the unofficial session can safely access them.
- [x] Research and document SoundCloud notification capabilities for iOS, iPadOS, tvOS, watchOS, and macOS; SoundCloud exposes no third-party push/webhook registration. See `docs/soundcloud-notifications.md`.
- [ ] Implement a rate-limited, cursor-backed notification poller for feed activity, follower deltas, bounded owned-track interactions, and direct-message inbox changes.
- [ ] Deliver deduplicated local notifications on macOS and an in-app notification inbox on every platform; establish a first-party APNs backend before promising timely alerts while mobile apps are suspended.
- [ ] Verify login can be completed through the embedded web flow and that the web area is visible when required.
- [~] Keep the SoundCloud signup/sign-in/2FA page unmodified: iOS and macOS now enter through `m.soundcloud.com/signin` (or `/signup`), allow SoundCloud's normal PKCE redirect/provider/OTP/TOTP/backup-code/CAPTCHA flow, inject no scripts or custom user-agent, and inspect cookies only after `/signin/callback`. Live verification is still required that SoundCloud supplies access, refresh, and client material in the completed WebKit session.
- [~] Never retry or disguise requests during a bot challenge/temporary block; the shared SoundCloud layer now persists a stop window for 403/429 responses and rejects subsequent requests until it expires. Notification polling still needs its cursor-backed implementation and live verification.
- [ ] Fix signed-in/signed-out state transitions without requiring an API client key.
- [~] Provide first-party SoundCloud account-management handoffs: iOS/iPadOS and macOS now link to SoundCloud's security/2FA/access, subscription, notification, privacy, communications, analytics, and advertising pages and revalidate when the app becomes active. Live navigation and account-change verification remain.
- Decision: keep SoundingCloud personal and unofficial. Do not require Artist Pro or app registration, embed a client secret, or borrow/impersonate Sonos, SoundCloud's CLI, or another client. Use the best-effort authenticated web/session approach described in `docs/soundcloud-integration.md`.
- Decision: do not generate or replay SoundCloud analytics; only SoundCloud's unmodified sign-in page may send its normal telemetry.
- Decision: do not block playback or table use based on Go/Go+/Free product badges.
- Decision: do not highlight Go/Go+/Free/Jayde access tiers on tracks.
- Decision: keep rate limiting and temporary lockouts; “do not block any” does not mean bypassing server safety limits.

## Social, sharing, and messaging

- [ ] Add Share Song from track rows, detail pages, context menus, and transport.
- [ ] Add Share Playlist and Share Profile with native share sheet and copy-link fallback.
- [~] Add messaging UI and service support using the existing authenticated SoundCloud web session where endpoints are available; compiled, needs live-account capability testing.
- [~] Provide conversation list, unread state, message thread, send state, retries, and safe external SoundCloud fallback where direct messaging is unavailable.
- [ ] Route the profile Message action into the new in-app composer/thread when supported instead of always launching SoundCloud in a browser.
- [ ] Review Bundle/Apple-style social presentation for clean navigation without copying branding.

## Persistence and sync

- [ ] Persist intelligence values, analysis work state, corrected genre, and relevant caches on macOS and all supported devices.
- [ ] Sync genre/privacy/follow/activity mutations and clearly show pending/failed state.
- [ ] Cache artist/profile tabs for a defined TTL and invalidate after mutations.
- [ ] Persist latest now-playing item, queue, transport state, playlist folder expansion, and navigation state where appropriate.
- [ ] Keep account-specific encrypted download indexes isolated and never expose decrypted material across accounts.

## Polyphony / “Foreplay”

- [~] Fix Bonjour service declarations and macOS entitlement for `_polyphony._tcp`.
- [~] Add TLS handshake rate limiting, per-peer/global temporary lockouts, and automatic room-code rotation.
- [~] Add Foreplay clock calibration using low-RTT ping/pong offset estimates.
- [~] Schedule transport commands slightly in the future, send frequent host updates, and apply gradual drift correction rather than coarse repeated seeks.
- [ ] Rebuild and test the latest Polyphony changes on at least two real devices over the same Wi-Fi network.
- [ ] Verify Local Network permission state against the actual bundle identity; do not report “no access” when System Settings grants it to the installed build.
- [ ] Replace raw `Network.NWError -65555 NoAuth` with accurate permission/entitlement/troubleshooting UI.
- [ ] Add a polished, centered, liquid-glass onboarding flow for Lead and Join.
- [ ] Make Start/Join/error/empty states visually centered, compact, and responsive.
- [ ] Measure end-to-end start skew, clock-offset error, steady drift, correction audibility, packet loss, reconnect time, and background/foreground transitions.
- [ ] Add authenticated session resume/reconnect and leader handoff behaviour.
- [ ] Threat-model peer discovery, pairing code, TLS identity, replay protection, rate limits, code rotation, and malicious LAN peers.
- [ ] Evaluate QUIC as a later transport behind the existing authenticated handshake; compare it with the current ordered TCP channel before replacing anything.
- Decision: do not use ultrasonic timing pulses; they require microphone permission/continuous capture and are less reliable than network clock calibration.
- Decision: do not ship unauthenticated raw UDP for control or timing.
- [ ] Add Polyphony diagnostics showing offset, RTT, drift, correction rate, peers, security state, and connection quality in a user-readable form.

## macOS polish and visual QA

- [ ] Verify glass/vibrancy on Artists, source lists, tabs, search headers, buttons, and transport under light/dark wallpapers and Reduce Transparency.
- [ ] Fix remaining broken segmented controls (`For You / Following`, profile tabs) and ensure full-pill hit targets.
- [ ] Keep button sizes, baselines, icon optical sizes, and subtitles aligned across artist/profile/playlist pages.
- [ ] Remove brown selection fills unless explicitly part of the SoundCloud accent palette; prefer graphite plus orange.
- [ ] Ensure every screen handles minimum window width, maximized width, split resizing, and sidebar collapse without clipped content.
- [ ] Verify hover, keyboard focus, context menu, double-click, VoiceOver label, and tooltip for every interactive row/control.
- [ ] Replace placeholder/broken artwork backgrounds with cached, stable fallbacks that do not cause scrolling jank.

## Build, run, and release verification

- [x] Rebuild after the latest artist, search, filter, vault, queue, and navigation edits.
- [ ] Relaunch the built macOS app and perform a cold-start sample on the real account.
- [x] Verify main thread is idle/event-waiting after launch and never performs vault crypto, full-index persistence, downloaded-audio materialization, or bulk analysis.
- [ ] Exercise Home, Search, Likes, Artists, artist detail, All/My/Liked Playlists, playlist detail, Decks, Profile, Queue, and Polyphony.
- [ ] Run focused tests for pagination, rate-limit handling, account switching, download index persistence, analysis persistence, follow/privacy mutation, navigation history, and Polyphony calibration/security.
- [ ] Keep the app running for hands-on review after the build passes.
