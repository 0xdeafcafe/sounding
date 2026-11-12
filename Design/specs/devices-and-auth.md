# Devices, roles and auth

What a device is in Sounding, what each one can do for the others, how they come to trust each other, and how SoundCloud credentials move, refresh and die. It also specifies the **Remote**: an iPhone, iPad or Mac controlling a linked Apple TV.

Vocabulary is the bible's (§8): **Link** is trust plus credentials, **Companion** is the control channel (plus auth, state and settings riding on it), **Output** is where audio plays, **Handoff** is only `NSUserActivity`. "Companion" never appears in the UI. This spec adds **Remote** (see §5).

Related: `Design/specs/chime-signin.md` (sign-in by sound, Needs Sign-In), `Design/specs/soundcloud-pkce-signin.md` (why the web flow stays).

---

## 1. What exists today (code map)

| Concern | Where | Notes |
|---|---|---|
| Device identity | `Core/Models/DeviceClass.swift` | `tv, phone, pad, mac, watch`, resolved at launch. The one identity enum. `OutputDevice` (`Core/Playback/RemoteOutputTarget.swift`) wraps a `DeviceClass` plus a name and id; it is not a second enum. |
| Device ids | `LinkPeerIdentity.localDeviceId` (Link) and `DownloadManifestDeviceIdentity.deviceId()` (CloudKit manifests, `CompanionRegistry`) | Two independent random UUIDs per install (gap G9). |
| Wire protocol | `Auth/Shared/TokenTransferProtocol.swift` | Dependency-free. Message types, payloads, HMAC canonical signing, `LinkTLS` (TLS 1.3 PSK from the Link secret), framing, `CompanionChannel`. |
| Link, TV side | `Apps/tvOS/Auth/LinkServer.swift`, `QRCodeLoginView.swift`, `ChimePlayer.swift` | Generates a one-time `SessionCredentials` (id + 32-byte secret), advertises `SoundingTV-Link-<prefix>` (TLS-PSK) and `SoundingTV-LinkOffer-<prefix>` (plain TCP, for the numeric code and chime). Accepts one `token_transfer`, validates or refreshes it, then calls `CompanionServer.pair`. |
| Link, phone/Mac side | `Auth/Shared/LinkClient.swift` (`LinkClient`, `CompanionLinker`, `LinkOfferBrowser`, `LinkConfirmationHandshake`), `ChimeListener.swift`, iOS `PhoneDevicesView.swift`, `SoundCloudLoginView.swift`, Mac `MacDevicesSettingsTab.swift` | Gets the session id + secret (QR, numeric code, chime), then pushes a SoundCloud token pair over TLS-PSK. |
| Link store, TV | `Apps/tvOS/Playback/LinkedDeviceStore.swift` | Keychain JSON list of up to **8** `LinkedDevice` (session id, secret, name, class, device id). |
| Link store, phone/Mac | `Auth/Shared/LinkedCompanionStore.swift` (`LinkedCompanionLedger`) | A list of up to **8** Links (`linked_tvs`), most recently used first, plus an outbox of unsent `link_revoke` / `session_revoke` messages (`pending_link_messages`, 14-day lifetime). Shared access group `6Z49PF6642.red.forbes.sounding.shared`, `AfterFirstUnlockThisDeviceOnly`. The old single `paired_tv` record (shared or legacy group) migrates into the list on first read. |
| Companion, TV | `Apps/tvOS/Playback/CompanionServer.swift` | One TLS-PSK listener per linked session, `SoundingTV-Companion-<prefix>`. Applies queue, transport, DJ, cue and likes commands; broadcasts signed `queue_state`, `playback_state`, `dj_state`, `device_status`. Up to 8 clients. Handles `link_revoke` and `session_revoke`; a forgotten device that wasn't connected gets a removal notice listener (`RevokedLinkStore` in `LinkedDeviceStore.swift`) until it acknowledges or 14 days pass. |
| Companion, phone/Mac | `Shared/Networking/CompanionClient.swift`, `LinkCourier.swift`, `CompanionFailure.swift` | Holds every Link, keeps one **active** connection (the TV being controlled), sees which other TVs are advertised, probes them for status, and delivers queued revokes with one-shot `LinkCourier` connections. `OutputRouter` (same file) moves playback between this device and any linked TV. Connection errors map to `CompanionFailure` copy, never raw `NWError` text. |
| Remote (new) | `Shared/Networking/RemotePlaybackIntents.swift`, `Shared/UI/Remote/RemoteControlView.swift`, Mac `MacRemoteWindow.swift` | Optimistic intents and reconciliation; the Remote screen. |
| Session store | `Auth/Shared/DeviceSessionStore.swift`, `SoundCloudCredentialSource.swift`, `SessionRenewal.swift` | Per-device SoundCloud token pair in the keychain, local sign-out tombstone, renewal through ordered sources. |
| iCloud session | `Auth/Shared/SessionSync.swift`, `Core/Sync/CloudSyncEngineController.swift`, `CloudSyncMapping.swift` | The token pair as one CloudKit private-database record (`session` zone, `encryptedValues`), last writer wins with digests and a sign-out tombstone. |
| Device registry | `Core/Sync/CompanionRegistry.swift` | Same-account devices seen recently (class, name, conditions). Used for Workshop jobs, not trust. |
| Watch | `Core/WatchLink/WatchLinkProtocol.swift`, iOS `PhoneWatchLinkServer.swift`, watch `WatchLinkClient.swift`, `WatchCredentialSource.swift` | WatchConnectivity to the paired iPhone only: snapshots (Now Playing with the Output's name, every Output by name and id, and the app volume; Up Next with its source), transport, volume, output by id, and a session request that copies the phone's token pair. |
| Handoff | `HandoffActivityType` in the protocol file, iOS/tvOS app activity handlers | `NSUserActivity` only. |
| Multipeer | none | Not used. |

---

## 2. What a device is

A **device** is one install of Sounding on one piece of Apple hardware. It has:
- a **class** (`DeviceClass`), fixed at launch;
- a **name** (the system device name, e.g. "Living Room");
- an **install id** (random UUID in `UserDefaults`; today two of them, G9);
- **zero or one SoundCloud session** (its own token pair, `DeviceSessionStore`);
- **zero or more Links**, each a shared secret with exactly one other device (a TV keeps up to 8, an iPhone, iPad or Mac up to 8).

Devices on the same Apple ID also share an **iCloud scope** (CloudKit private database). That scope is a credential *source*, not a trust relationship between two named devices.

A device's SoundCloud session always belongs to the device that holds it. When credentials move, the receiver gets either a copy of the giver's pair (Link sign-in, watch, iCloud) or a brand-new pair minted for it (auth handoff, §4.4).

---

## 3. Roles

| Role | Meaning |
|---|---|
| **Signed-in player** | Holds a usable SoundCloud session and can stream on its own. |
| **Output** | Where audio plays. Accepts `queue_load` and transport over Companion from a Remote. |
| **Remote** | Shows and controls another device's playback over Companion, optimistically. Its own Output can stay local. |
| **Credential source** | Can give another device a SoundCloud session: Link sign-in, auth handoff, watch session, or by writing the iCloud record. |
| **Credential receiver** | Can take a session from a source. |
| **Workshop worker** | Runs background jobs (`DeviceClass.supports`). |

### Role matrix

✓ = today, ◐ = partial or limited, ✗ = not possible or not built, → = proposed.

| Role | iPhone | iPad | Mac | Apple TV | Watch |
|---|---|---|---|---|---|
| Signed-in player | ✓ web sign-in | ✓ web sign-in | ✓ web sign-in | ✓ via Link, iCloud or auth handoff only (no keyboard sign-in) | ◐ copies the iPhone's pair |
| Output for others | ✗ | ✗ | ✗ → could accept (same player) | ✓ | ✗ |
| Remote | ✓ any linked TV, one at a time | ✓ same | ✓ same | ✗ | ◐ controls the iPhone, which may be driving a TV |
| Credential source | ✓ Link, handoff, watch, iCloud | ✓ same | ✓ Link, handoff, iCloud | ◐ iCloud only | ✗ |
| Credential receiver | ✓ iCloud | ✓ iCloud | ✓ iCloud | ✓ Link, handoff, iCloud | ✓ from iPhone |
| Workshop worker | ✓ | ✓ | ✓ | ◐ no deep analysis | ✗ |

Rules that follow from the matrix:
- An Apple TV is always a **receiver** and an **Output**, never a Remote and never a source over the LAN.
- A Remote must be a **signed-in player** to start a Link (it has to give the TV something). Once linked, controlling the TV needs no session on the Remote: commands carry track ids, the TV resolves them with its own session. Liking from the Remote uses the Remote's own session (§5.6).
- The Watch reaches a TV only through its iPhone.

---

## 4. Trust and credentials

### 4.1 Trust anchors

```
 same Apple ID ──────────── iCloud (CloudKit private DB) ───── session record (token pair)
                                                         └──── CompanionRegistry (who exists)

 physical presence ─┬─ QR code on the TV screen   ─┐
                    ├─ 6-digit numeric comparison  ─┼─► Link secret (32 bytes, per pair)
                    └─ chime / ultrasonic code     ─┘        │
                                                             ├─► TLS 1.3 PSK for token transfer
                                                             └─► TLS 1.3 PSK for Companion (forever, until forgotten)

 paired Watch ────────────── WatchConnectivity ────────────── copy of the iPhone's token pair
```

### 4.2 Establishing a Link (all three bootstraps converge)

```
 iPhone / iPad / Mac                                    Apple TV (sign-in screen or Add Device)
 ───────────────────                                    ───────────────────────────────────────
                                                        LinkServer.start()
                                                          SessionCredentials(id, secret)
                                                          advertise Link-<id8>     (TLS-PSK)
                                                          advertise LinkOffer-<id8> (TCP, TXT: name, class, commitment)
                                                          show QR(session, secret) · play chime(K)

 (a) QR: camera reads session + secret ───────────────────────────────────────────────┐
 (b) Numeric: X25519 over LinkOffer, both show 6 digits, user confirms,               │
     TV seals LinkOffer(id, secret) with the transport key ───────────────────────────┤
 (c) Chime: hear K, CPace over LinkOffer, confirm MACs, user taps Sign In,            │
     TV seals LinkOffer(id, secret) ──────────────────────────────────────────────────┤
                                                                                      ▼
 SoundCloudLoginView / CompanionLinker
   take this device's token pair (refresh first if near expiry)
   TLS-PSK(id, secret) ──► token_transfer { token, refresh, clientId, expiry, HMAC }
                           + LinkPeerIdentity { name, class, deviceId, HMAC }
                                                        validate token with SoundCloud
                                                          or refresh it (TV keeps the new pair)
                       ◄── ack (+ echo of the refreshed pair)
 LinkedCompanionStore.save(id, secret, class, name)     CompanionServer.pair(id, secret, identity)
                                                        AuthenticationService.authenticate(…)
```

After this the pair shares a long-lived secret. Every later Companion connection is TLS-PSK with that secret, and every command and state frame is also HMAC-signed with it, with freshness windows and replay guards.

**Linking a signed-in TV sends no token** (2026-11-12, `tv-signin-flows.md` §7 P3). Once the TLS-PSK connection is up, a phone whose offer carried an account hint sends `link_establish { LinkPeerIdentity, account }`; the TV pairs and answers `link_established { needsCredentials, account }`. The phone sends `token_transfer` only when `needsCredentials` is true. A signed-out TV (no hint) still gets `token_transfer` at once. An older TV answers `Unsupported message`: the phone falls back to `token_transfer` for a same-account hint and stops with "Update Sounding on <TV> to link it from here." for another account. A signed-in TV that still receives `token_transfer` (an older phone) pairs without adopting it. Add a Device on a signed-in TV is control-only; the only way to change a signed-in TV's account from another device is the switch in §4.3.

### 4.3 Credential flow and refresh

| Path | Giver → receiver | What moves | When |
|---|---|---|---|
| Link sign-in | Remote → TV | a copy of the Remote's pair (TV may refresh it and echo the new pair back) | first link, Add Device |
| Auth handoff | Remote → TV | a **new** pair minted by a silent web re-auth (`SilentWebReauthorizer`) or an interactive sign-in on the Remote | the TV's renewal failed (`SoundCloudSessionRenewal` source `.linkedPeer`), or the user taps **Sign In This Apple TV** (Needs Sign-In) |
| iCloud | any → any, same Apple ID | the latest pair, encrypted CloudKit field; one record per account (`session-<tag>`) beside the legacy record | after any sign-in or refresh; adopted by devices with no session and no sign-out, or a stale pair **of the same account**. A device that signed out gets **Continue as <name>** instead. A TV's guest session (handoff or switch) is written only when iCloud already holds that account. |
| Watch | iPhone → Watch | a copy of the iPhone's pair | watch launch without a session |
| Account switch | Remote → TV | a copy of the Remote's pair in `account_switch_credentials`, bound to the request nonce | only after **Switch** on the phone and **Switch** on the TV (`account_switch_request` → `account_switch_answer(accepted)`, 60 s to answer, 30 s for the pair). The TV validates the pair before signing the old account out (Links kept); any failure leaves it as it was. Offered only to TVs whose `account_status` lists `account_switch`. |

Refresh is per device: each device refreshes its own pair (`DeviceSessionRefresher`, coalesced by `TokenRefreshCoordinator`). Because copies share one refresh token, one device's refresh can invalidate another's copy; the iCloud record and the renewal sources exist to heal that. Renewal order on the TV: refresh → iCloud record → ask a connected Remote (auth handoff).

### 4.4 When a TV is open but signed out

Per `chime-signin.md`, losing the SoundCloud session no longer forgets the TV's Links; only Sign Out on the TV does. While it needs sign-in the TV keeps its Companion listeners and sends each connected Remote a signed `device_status { needsSignIn }`.

| What the Remote sees | Status in Devices | Remote screen |
|---|---|---|
| Connected, `needsSignIn = false` | Connected | the remote |
| Connected, `needsSignIn = true` | **Needs Sign-In** | "Living Room Needs Sign-In", **Sign In This Apple TV** (auth handoff over the Link) |
| Not linked, but the TV advertises a LinkOffer | (Home prompt) | — |
| Linked, another TV is being controlled, this one is on the network | **Available** | (opening its Remote makes it the active TV) |
| Linked, not found or TLS fails | **Not Reachable**, with a plain reason in the detail footer (`CompanionFailure`) | "Living Room Isn't Reachable", the same reason, **Try Again** |

### 4.4a The phone comes to the TV (sign-in requests)

A signed-out Apple TV asks for sign-in so nobody has to go and find the app. Both routes end in the existing Link flow; QR, chime and numeric code stay as fallbacks. There is no Sounding server.

**Route A, same iCloud account, zero clicks (CloudKit).**
- While the sign-in screen is visible (purpose `.signIn`, TV not authenticated), `SignInRequestPublisher` saves one `SignInRequest` record to the private database of `iCloud.red.forbes.sounding` (default zone, record name `signin-<rendezvous>`): `tvName`, `tvKind`, `rendezvous` (16 random bytes, hex), `tvTag` (SHA-256 of "Sounding-SignInRequest-TV-v1|" + the TV's Link device id, 12 bytes hex, the same for every request from that TV), `createdAt`, `expiresAt` (10 minutes, clamped on read). One record per screen session, saved once the Link listener is advertising; deleted on success or when the screen goes away. Saving a new one deletes any earlier request the TV still has outstanding. The start screen asks at most once every 10 minutes (`signInRequest.lastPublished.v1`); opening Sign In from the TV's own menus always asks. If the Production schema doesn't have `tvTag` yet, the TV saves the request without it.
- **No secrets.** The record only says "come find me". The same `rendezvous` is advertised in the `SoundingTV-LinkOffer-<prefix>` TXT record (`rv`), so the phone can tell which Bonjour offer is that TV. Trust still comes from the chime (or the numeric code with **Allow** on the TV) over the local network.
- The iPhone, iPad and Mac save one `CKQuerySubscription` (`signin-requests-v3`, fires on creation) whose alert is "<TV name> wants to sign in" (`SIGN_IN_REQUEST_TITLE` with the `tvName` field, `Localizable.strings`, shared by the iOS and Mac apps), a body line and the default sound. **CloudKit refuses a subscription with more than five desired keys** ("notification additional fields limit exceeded"), so every alert asks for five at most (`OutsideAlertSubscription`, tested). Sign-in requests ask for `tvName`, `tvKind`, `rendezvous`, `tvTag` and `createdAt` (the expiry is `createdAt` + 10 minutes), so the app needs no fetch. `tvTag` is the APNs collapse id, so a TV only ever has one "wants to sign in" on each device; `-v2` collapsed per request and stacked one per retry. Its category `SIGN_IN_REQUEST` has two actions, **Link** (opens the app into the flow below) and **Not Now**. Subscriptions are account-wide, so any one device saving them is enough; `OutsideAlerts.ensureSubscriptions` lists the account's subscriptions in iCloud after every new build and once a day (`outsideAlertSubscriptions.v2` holds the build and time of the last complete check), saves whichever are missing and, only once they all saved, deletes the retired ones (`OutsideAlertSubscription.retiredIDs`). A local "saved" flag is never trusted on its own: it survived a Debug build (Development environment) being replaced by TestFlight (Production), so Production never got the subscriptions. Push registration runs at every activation, whatever the permission, so CloudKit always has the device token and the silent withdrawals arrive.
- **Withdrawn when it's over.** A second subscription, `signin-requests-gone-v2`, fires silently (`content-available`) when the TV deletes its request: on success, when the sign-in screen goes away, or in the next launch's leftover sweep. The iPhone (background mode `remote-notification`) and a running Mac remove the delivered "wants to sign in" for that record. A silent push doesn't reach an iPhone app the user has swiped away, so the app also sweeps when it launches or becomes active, when a Link completes, and when the SoundCloud account changes (`OutsideAlerts.tidyDelivered`, rules in `OutsideAlertSweep`, tested): it removes alerts that have expired, alerts for a TV that has just signed in or linked, alerts whose record is gone or no longer shows (other account, already linked), and all but the newest alert per TV. It reads the records in one batch and keeps an alert when iCloud can't be reached.
- Tapping it opens **Sign In Apple TV** in listening mode: "Connecting to Living Room…", the matching offer is tried first, and **Use a Code Instead** appears once that offer is on the network. In the foreground, the banner shows only if `SignInRequestFilter` admits it: not expired, not already shown (per rendezvous), and not a TV that is linked, connected and signed in. Expired notifications are removed when the app becomes active.
- Permission is primed in Devices: **Turn On Sign-In Requests…** opens a centred "Sign In Apple TVs from Here" screen with **Continue** / **Not Now** before the system prompt, only when the status is undetermined. The same screen opens once, 5 s after the first Link this iPhone or iPad completes, if the status is still undetermined. Nothing asks at launch. Denied means in-app only.
- iCloud unavailable on either side, or no notification permission: route A does nothing, silently.
- **Time Sensitive.** `CKSubscription.NotificationInfo` has no interruption level, so the subscription sets `shouldSendMutableContent` and the Notification Service Extension (`SoundingTV-NotificationService`, `red.forbes.sounding.NotificationService`) marks sign-in requests `.timeSensitive`, titles them "<TV name> wants to sign in" from the record fields and threads them per TV (`sign-in-requests-<tvTag>`); a request that has already expired arrives `.passive`. The iPhone app carries `com.apple.developer.usernotifications.time-sensitive`. The subscription's saved flag moved to `signInRequestSubscription.v2`, so existing installs re-save it with mutable content.
- **Leftovers.** The TV keeps the record names it saved (`SignInRequestLedger`, `signInRequest.outstanding.v1` in its own defaults, newest 20) until a delete succeeds or CloudKit says the record is gone. On launch it deletes whatever is still listed, so a TV killed on the sign-in screen doesn't leave its request in iCloud. Phones ignore expired requests either way.

**Route B, any nearby iPhone or iPad, one click on the TV (DeviceDiscoveryUI).**
- The TV sign-in screen has **Sign in with Another Device** next to Get a New Code and Play Sound: SwiftUI `DevicePicker` (the system wrapper around `DDDevicePickerViewController`) for the application service `SoundingSignIn`. It hides itself when `devicePickerSupports` says no.
- The iPhone starts an `NWListener(using: .applicationService)` for `SoundingSignIn` at launch. The system asks the iPhone's owner to allow the connection and launches Sounding. The TV then sends one length-prefixed `DevicePickerSignIn.Invitation` (session id, Link secret, created-at, name, kind) over that system-encrypted, user-approved channel: the same thing the QR code shows, delivered only to the device picked on the TV and allowed on the phone. The phone shows the TV's name, "Sign in to Sounding on this Apple TV?", **Sign In** / **Not Now**, then runs the normal TLS-PSK token transfer.
- Info.plist: tvOS `NSApplicationServices › Browses` (identifier, usage description, platforms iOS and iPadOS); iOS `NSApplicationServices › Advertises` (identifier). No entitlement.

**Route C, any signed-in phone that sees the TV, one tap on the phone (nearby card).** The phone shows the nearby Apple TV card (bible §9); **Sign In** asks the TV for its sound over the Link offer (`chime_play_request`) and signs in by the chime (`chime-signin.md`).

**Live Activity.** Any of these routes starts "Signing in <TV>" (`TVSignInActivityAttributes`, its own type next to Now Playing): Connecting… → Waiting for SoundCloud… (token sent, TV checking it) → Signed in (tick) or Couldn't sign in. It follows `LinkClient.transfers` for that session and ends 4 s after done or failed; Not Now ends it at once.

**TV backdrop.** Two more reactions: a notification going out (rings lighting inner to outer, then two arcs leaving the jack; pill "Notification sent to your iPhone") and an iPhone connecting through the picker (the incoming arc plus the connecting pulse; pill "iPhone connecting…").

**Fixtures.** iPhone: `SOUNDING_TV_SIGNIN_INVITE=nearby|picked` opens the sheet from a fake request; `SOUNDING_TV_TV_SIGNIN_ACTIVITY=connecting|waitingForSoundCloud|done|failed` shows the Live Activity; `SOUNDING_TV_SIGNIN_NOTIFY_STORY=priming` opens the priming screen. TV: `SOUNDING_TV_DEVICE_PICKER=1` forces the button on; `SOUNDING_TV_SIGNIN_STORY=notified|picker` loops the new backdrop states. Tests: `SignInRequestTests.swift` (expiry, filtering, de-duplication, rendezvous mapping, picker wire).

**Before release.** Deploy the `SignInRequest` (including `tvTag`) and `AccountSignIn` record types (fields above and in §4.4a2) to the production CloudKit schema; enable Push Notifications and Time Sensitive Notifications on the iOS App ID (`aps-environment` and the time-sensitive entitlement are in the entitlements), and register `red.forbes.sounding.NotificationService` (no capabilities).

### 4.4b2 A signed-in Apple TV asks to be linked (outside the app)

The TV can only see an iPhone while Sounding is open on it (the phone's `SoundingTV-Nearby-<salt>` presence is foreground-only), so "<iPhone> is nearby" on the TV never helped a phone in a pocket. The TV now asks through iCloud instead.

- **When.** `NearbyLinkRequestPublisher` (tvOS, fed by `SameAccountLinking` in `RootView`) asks when the app is open, signed in, advertising its same-account Link offer, no Allow prompt is up, and either it sees an unlinked iPhone of the account or it has no iPhone, iPad or Mac linked. `NearbyLinkRequestPolicy` (shared, tested) decides: at most one request per TV per account every 12 hours; after a phone's **Not Now**, nothing for 12 hours and until the TV has been closed or asleep for 30 minutes since.
- **Record.** `NearbyLinkRequest`, private database, default zone, record name `nearbylink-<16 random bytes hex>`: `tvName`, `tvKind`, `tvTag` (SHA-256 of the TV's Link device id, 12 bytes hex), `accountTag` (as `AccountSignIn`), `linkedDevices` (comma-separated hashed device ids of what the TV has linked), `createdAt`, `expiresAt` (10 minutes). No secrets. Leftovers are tracked in `nearbyLinkRequest.outstanding.v1` and swept at launch like sign-in requests.
- **Withdrawn** when the TV links a device, goes to the background, signs out, or the 10 minutes run out. `nearby-link-requests-gone-v1` (silent) removes the delivered notification on every device; expired, other-account and already-linked ones are also tidied when the app becomes active.
- **Alert.** `nearby-link-requests-v2` (fires on creation): `LINK_REQUEST_TITLE` "%@ is nearby" with `tvName`, `LINK_REQUEST_BODY` "Link it to control playback and share settings.", category `LINK_REQUEST` (**Link**, foreground; **Not Now**), `tvTag` as the collapse id. Desired keys: `tvName`, `tvKind`, `tvTag`, `accountTag`, `expiresAt` (`-v1` asked for all seven fields, so CloudKit never saved it and the alert never fired). The app reads the full record by the notification's record ID from the private database before it presents or links (`OutsideAlerts.linkRequest(for:)`); if it's gone or unreadable, nothing happens. **Not Now** needs only the notification's `tvTag`, name and kind. The Notification Service Extension sets interruption level `.active`, thread `link-requests`, and attaches a 240 pt picture of the device symbol on brand orange (also on sign-in requests). No new entitlement: the extension and its App ID already exist.
- **Link** opens the app; `DevicePairingFlow.link(_:)` waits up to 15 s for that TV's same-account offer and runs the card's **Link** (the one-tap or six-digit flow), else opens Add Apple TV. **Not Now** writes the card's per-TV dismissal (`NearbyCardDismissals`) and saves `NearbyLinkSnooze` (record name `nearbylink-snooze-<tvTag>`: `tvTag`, `snoozedAt`), deleting the request so other devices clear it.
- **Foreground.** With Sounding open the banner is suppressed; the nearby card is the only prompt. On the Mac, only when the app isn't active.
- **Limits.** Same iCloud account only. A visible push can't be filtered before it shows (no filtering entitlement), so a device on another SoundCloud account, or one already linked to that TV, can still see it while Sounding isn't running; it is removed the next time the app is active.
- **Schema.** `Design/cloudkit/NearbyLinkRequest.ckdb`; deploy with the rest (release checklist item 9).

### 4.4a2 Your account is being used (New Sign-In)

When the SoundCloud account signs in on a device it hasn't been on before, the account's other devices on the same iCloud account show **New Sign-In**, "Your SoundCloud account is now signed in on Living Room.", with **Show Devices**. Tapping it, or the action, opens Devices (a sheet on iPhone and iPad, Settings › Devices on the Mac), where the device can be forgotten.

- **Record.** `AccountSignIn` in the private database of `iCloud.red.forbes.sounding`, default zone, record name `account-signin-<accountTag>-<subject>`: `subject`, `announcer`, `accountTag`, `deviceName`, `deviceKind`, `collapse`, `createdAt`. No secrets and no raw ids: `accountTag` is the first 8 bytes of SHA-256("Sounding-AccountSignIn-Account-v1|" + SoundCloud user id); `subject` and `announcer` are hashed device ids (`d…`) or a hashed Link session id (`l…`). Schema in `Design/cloudkit/AccountSignIn.ckdb`.
- **Who writes it.** Each device writes one for itself the first time it holds a session for an account (interactive sign-in, a Link received, an iCloud session adopted). The iPhone, iPad or Mac that completes a Link writes one for the device it linked, keyed by that Link, so a TV on someone else's iCloud account is still announced. One record per device and account: the save uses `ifServerRecordUnchanged`, the subscription fires only on creation, and `accountSignIn.announced.v1` remembers what was sent, so token refreshes, relaunches and re-sign-ins on the same device never notify. A failed save is retried at the next launch for 24 hours (`accountSignIn.pending.v1`).
- **Upgrades are quiet.** On the first launch with this code, a device that has run before (it already has a sync device id) records its current account as announced without writing anything, so updating every device doesn't notify about all of them.
- **Fan-out.** `CKQuerySubscription` `account-signins-v3` (fires on creation; `-v2` asked for seven fields and was refused): title `ACCOUNT_SIGN_IN_TITLE` "New Sign-In", body `ACCOUNT_SIGN_IN_BODY` with `deviceName`, category `ACCOUNT_SIGN_IN` (action **Show Devices**), `collapse` as the APNs collapse id so the TV's own record and the linking phone's record for the same TV show as one notification. Desired keys: `deviceName`, `deviceKind`, `collapse`, `accountTag`, `createdAt`. The extension makes it Time Sensitive and threads it as `account-sign-ins`. In the foreground the app reads the full record (`subject` and `announcer` aren't in the push) before deciding whether to show it; **Show Devices** needs no record.
- **Not on the device that signed in, not on another account.** CloudKit doesn't push a change back to the device that made it. In the foreground, `AccountSignIn.verdict` hides it on the device it's about (or that wrote it), on a device signed out of SoundCloud, and on a device signed in to a different SoundCloud account; delivered ones in those cases are removed when the app becomes active. A visible push can't be filtered before it shows while the app isn't running, so a signed-out device on the same iCloud account can still see it.
- **Apple TV** writes records but never shows these notifications.
- **Mac.** `com.apple.developer.aps-environment`, `NSApplication.registerForRemoteNotifications()` once notifications are allowed, the same subscriptions and categories (`MacOutsideAlerts.swift`), and the iOS `Localizable.strings` is in the Mac target for the alert keys.

### 4.4b Same account, automatic

When a signed-in Apple TV and a signed-in iPhone or iPad are on the same SoundCloud account and the same network, they find each other and offer to link. **Auto-link** (owner, 2026-11-12, Q1: "link auto if already linked and not unlinked"; replaces decision 1a): when this phone was linked to the TV before and never explicitly unlinked it (`KnownLinkLedger`; Forget on either side records an explicit unlink; a `link_revoke` with reason `signedOut` or `replaced` doesn't), the owner proof below runs with no card and no tap, at most once per TV per launch, 15 s budget, then `link_establish`. The phone shows "Linked to <TV>" for 2 s. Owner tags are only sent for such known Links, so a first link, or one after an explicit unlink, always shows the six digits and **Allow**, even on the same Apple ID.

**What the TV advertises.** While the app is active, signed in, and no sign-in or Add a Device screen is up, `SameAccountLinkAdvertiser` (in `LinkServer.swift`) runs a chime-less `LinkServer` and advertises the usual `SoundingTV-LinkOffer-<prefix>`. Its TXT adds three keys (`LinkAccountHint`, `TokenTransferProtocol.swift`):
- `as`: 8 random bytes, new for every advertisement;
- `ah`: the first 12 bytes of SHA-256("Sounding-LinkAccount-v1" ‖ salt ‖ SoundCloud user id);
- `lp`: for each device already linked to this TV (up to 8), the first 4 bytes of SHA-256("Sounding-LinkedPeer-v1" ‖ salt ‖ device id).

The raw user id never leaves the device, and the salt changes every time the offer restarts, so the advert can't be tracked between networks. A phone with the same user id recomputes `ah` with the advertised salt (constant-time compare), and skips the offer if its own device id is in `lp`. Tokens are never hashed or advertised.

A signed-in TV's Add a Device screen (`QRCodeLoginView`) carries the same hint, so a phone never offers to sign in a TV that's already signed in.

**One-tap linking.** Each Apple ID has one link key: 32 random bytes in the iCloud private database, default zone, record type `LinkOwnerKey`, record name `linkOwnerKey`, fields `currentKey` (encrypted bytes), `currentCreatedAtMillis` (Int64), `previousKey` (encrypted bytes) and `previousRetiresAtMillis` (Int64); schema in `Design/cloudkit/LinkOwnerKey.ckdb`. `LinkOwnerKeyCloud` (iPhone, iPad, Mac, Apple TV) fetches it when the app comes forward (at most every 6 hours, or every 5 minutes while there's none), creates it if missing, and rotates it after 30 days; the old key keeps working for 7 more days, and no key is used after 45 days. A conflicting write re-reads and adopts the other device's key. A record that can't be read is never overwritten. Each device caches the key ring in its own keychain (`LinkOwnerKeyStore`, this device only) and clears it when iCloud signs out or changes account. The key is never sent, logged or put in a Bonjour record.

The numeric handshake carries the proof (`LinkOwnerProof`, `LinkOwnerKey.swift`; wire fields are plain strings in `TokenTransferProtocol.swift`):
1. `numeric_hello` adds `ownerKeyTags`: for each usable key (at most 2), the first 8 bytes of HMAC-SHA256(key, "Sounding-LinkOwnerTag-v1" ‖ session prefix ‖ phone public key). Tags change with every ephemeral key, so they can't be used to track the owner. They're only sent to a TV whose account hint matches.
2. A TV that's signed in and holds a key with a matching tag answers `numeric_hello_ack` with `ownerKeyTag` and `ownerProof` = HMAC-SHA256(key, "Sounding-LinkOwnerProof-v1" ‖ "responder" ‖ session prefix ‖ phone public key ‖ TV public key ‖ commit nonce ‖ phone name ‖ phone class ‖ the TV's SoundCloud user id), and holds its **Allow** prompt back.
3. The phone recomputes the proof with its own user id. If it verifies, it skips the code ("Linking Living Room…") and sends `numeric_confirm` with its own proof (role "initiator", same transcript). If not, it shows the code as before.
4. The TV releases the sealed Link credentials without asking only when the initiator proof verifies; a missing or wrong proof brings back **Allow "iPhone" to link to this Apple TV?** with the code.

Proofs bind both ephemeral keys, the commit nonce, the session and the phone's claimed identity, so they can't be replayed or relayed, and they match only when both sides have the same SoundCloud user id. Older builds ignore the new fields and get the two-tap flow. Without the record in Production, or with iCloud off on either device, it's the two-tap flow too.

**On the phone.** The nearby Apple TV card (bible §9) offers it: the TV's name, "It's signed in to your SoundCloud account. Link it to control it from this iPhone.", **Link Apple TV** and **Not Now**. Devices keeps a row at the top, "Living Room is signed in to your account. Link it?", with **Link** (swipe for **Not Now**). The Home banner is gone (owner: "looks lost on the page, not a clear CTA"). **Link** runs one-tap linking when it can; otherwise it opens the numeric code: both screens show six digits, the TV shows **Allow "iPhone" to link to this Apple TV?** ("It's signed in to your SoundCloud account. Only allow it if it shows 123 456."), and the phone then runs the normal TLS-PSK token transfer. `SameAccountLinkOffer` is the state machine: hidden → suggested → linking (150 s) → hidden on success, or failed with a plain message and **Try Again**; **Not Now** keeps that TV quiet for the rest of the session in Devices; on the card it's saved per TV (`NearbyCardDismissals`) until the TV has been away and back after 12 hours. A TV already in `LinkedCompanionStore` (same kind and name) is never suggested. Same-account offers are never shown as "waiting to sign in".

**On the Mac.** The Mac runs the same `SameAccountLinkModel` (one per app, `MacTVLinking`) on a `LinkOfferBrowser` that browses while the app is active. Settings › Devices shows the same line at the top of the grouped Form with **Not Now** and **Link**; a failure shows "Couldn't Link Living Room", the message, **Not Now** and **Try Again**. The main window shows the nearby Apple TV card as a sheet (it replaced the bar under the toolbar), and the same card signs in a signed-out TV by its sound. **Link** opens a sheet in the window it came from with the same six digits; after **It Matches** and **Allow** on the TV it runs the normal token transfer and closes. The Mac advertises its own `SoundingTV-Nearby-<salt4>` presence with its computer name, so the TV's hint names the Mac. `SameAccountLinkPrompt` (`LinkClient.swift`) maps the offer phase to the row's copy; tests in `MacSameAccountOfferTests.swift`. `SOUNDING_TV_MAC_SAME_ACCOUNT=suggested|failed` (DEBUG) forces the row and bar for screenshots.

**On the TV.** While the phone has an unlinked same-account TV in view and is in the foreground, it advertises `SoundingTV-Nearby-<salt4>` (TXT `as`, `ah`, `lp` = its own device id, `name`; it accepts no connections). `SameAccountPhoneBrowser` on the TV matches it and shows a non-blocking glass capsule at the top: "iPhone is nearby. To link it, open Sounding › Devices on it." After a link it shows "<name> is linked" for 4 s. The match is `SameAccountPhoneBrowser.nearbyName(in:accountId:linkedDeviceIds:)`, a pure function over the browsed adverts: only `SoundingTV-Nearby-*` services with a TXT record, the same account hash, and a device id this TV is not already linked to; first by service name, "An iPhone" when the name is blank. The browser re-matches whenever `CompanionServer.devices` changes, restarts itself 2 s after a failure, and the TV's own advert re-publishes its `lp` list when the linked devices change (only while idle, never mid-link). Dismissing the Allow alert any other way counts as **Don't Allow**.

**The TV keeps its own session.** The Link is made with `link_establish` and carries no token (§4.2): both devices are already signed in, and sharing one refresh token would let one device's refresh invalidate the other's copy. Add a Device on a signed-in TV no longer adopts a token either. The numeric hello carries `accountDigest` (the phone's `ah` with the TV's salt), so the TV's **Allow** alert says whether the phone is on the same or a different SoundCloud account; without it (an older phone) it uses the different-account copy.

**Debug.** `SOUNDING_TV_LINK_ACCOUNT=<id>` (DEBUG only, both apps) forces the account id, so two fixture simulators can play "same account". Tests: `Tests/SoundingTVTests/Sources/SameAccountLinkTests.swift` (hashing, TXT round trip, candidate filtering, the offer state machine, timeouts and retries, service-name collisions).

### 4.4c Why linking failed on real devices (2026-11-07 findings)

| # | Symptom | Cause | Fix |
|---|---|---|---|
| F1 | Add Apple TV on the phone sat waiting while the TV was signed in | A signed-in TV advertised no Link offer at all: `LinkServer.start()` only ran from `QRCodeLoginView` (sign-in screen, or Settings › Add a Device). `CompanionServer` only advertises `SoundingTV-Companion-<prefix>` for existing Links. | §4.4b: the signed-in TV advertises a chime-less offer with the account hint. |
| F2 | Add Apple TV showed only "Listening…" even when a TV was on the network | The sheet opens in listening mode, which acted only on a heard chime and never listed the offers `LinkOfferBrowser` had found; the numeric path was hidden behind Use QR Code Instead. | Listening lists every nearby TV with its status ("Link with a code", "Signed in · Link with a code"). |
| F3 | Names were "Nearby Apple TV", the iCloud request's matching offer was never found, Use a Code Instead never appeared | `LinkOfferBrowser` browsed with `.bonjour`, which never returns TXT records, so `name`, `kind`, `pkc` and `rv` were always missing. | `.bonjourWithTXTRecord`. |
| F4 | "Connecting…" then failure after the chime or a code | `LinkClient` picked the TLS service by `hasPrefix("SoundingTV-Link") && contains(prefix)`, which also matches the plain-TCP `SoundingTV-LinkOffer-<prefix>`. Bonjour results are unordered, so about half the time the phone tried TLS-PSK against the offer listener: no handshake, 15 s timeout, "Couldn't securely verify", and the TV's single offer slot was held by the dead connection. | Exact name match (`BonjourConstants.linkServiceName`), plus up to 2 retries (1 s, 2 s) on a failed TLS connection. |
| F5 | The TV played the chime and the phone did nothing | The audible chime plays once when the screen appears; if the phone wasn't listening yet only the 18 kHz carrier remains, which many TV speakers and soundbars cut. The phone gave no sign that it heard anything. | A live microphone level meter; after 20 s with no code, the phone says what to do and offers the code path. (Audio session was already right: `.playAndRecord` / `.measurement`, built-in mic.) |
| F6 | Raw `NWError` text in failures | `LinkClient` and `LinkConfirmationHandshake` put `localizedDescription` into the state. | `LinkFailureCopy` maps local-network denial, TLS and unreachable errors to plain next steps; every step has a timeout with a message (`LinkStep`). |
| F7 | Simulators: the phone suggested Link, the TV never showed "iPhone is nearby" | Not reproduced since (no simulator). Code faults found on the TV path: the browser's linked-device list was a snapshot taken only when the account key changed, while the TV's own advert kept an older `lp` list, so the two sides could disagree about "already linked"; a failed browser was never restarted (no state handler); the matching was untestable inside the results handler. | Pure `nearbyName(in:accountId:linkedDeviceIds:)` with tests; re-match and re-advertise on `CompanionServer.devices`; restart after failure; log advert count and TXT-less adverts. |
| F8 | After a relaunch the TV showed only the blurred backdrop: no tab bar, no content | Not confirmed. The screenshot is a tvOS modal blur with nothing in it, and the hint is hidden whenever `linkApproval` is set. The Allow alert's binding ignored dismissal (`set: { _ in }`), so a system dismissal left SwiftUI presenting while the alert was gone. | Dismissal now declines while an approval is pending (`set: false` → `declineLink()`; Allow clears the approval first, so it never declines). Re-run the simulator pair to confirm. |

**Capturing logs on device.** With the iPhone and Apple TV attached to the Mac (or paired in Xcode › Devices), run on the Mac:

```
log stream --level debug --predicate 'subsystem == "red.forbes.sounding" AND category == "link"'
```

What to look for: TV `[SameAccountLink] advertising for N linked devices` and `[LinkServer] offer advertised (signedIn=true)`; phone `[LinkOfferBrowser] found SoundingTV-LinkOffer-… TXT=true signedIn=true` and `[SameAccountLink] suggestion: Living Room`; `[ChimeListener] listening at 48000 Hz, category=AVAudioSessionCategoryPlayAndRecord mode=AVAudioSessionModeMeasurement input=MicrophoneBuiltIn`; `[NearbyTVSignIn] heard a code; N offers` (or `no code after 20 s`); `[LinkClient] found SoundingTV-Link-… opening TLS-PSK` then `Connected to Apple TV (TLS-PSK verified)`; any `[LinkOfferBrowser] waiting: … -65570` means Local Network is off for Sounding.

### 4.5 Revocation

| Action | Effect today | Gap |
|---|---|---|
| Action | Effect |
|---|---|
| **Forget This Apple TV** (iPhone/iPad/Mac) | Queues a signed `link_revoke` (with the secret it needs) in the outbox, then deletes the Link. The outbox delivers it over a one-shot TLS-PSK connection as soon as the TV is advertised; the TV deletes its record, acknowledges, and the message is settled. Unsent messages expire after 14 days. |
| **Forget Device / Forget All Devices** (TV) | Sends `link_revoke` to any connected client of that Link, then closes it. If none was connected, or the send failed, the TV keeps a removal notice: it keeps advertising that Link's Companion service, and whoever connects with the old secret is sent `link_revoke` until they acknowledge (14-day lifetime). The phone removes the TV and shows nothing stale. |
| A newer Link from the same device, or a 9th Link | The replaced or evicted Link gets the same removal notice. |
| **Sign Out** on the TV | `CompanionServer.unpair()`: every Link is revoked as above, queue and Top Shelf cleared. |
| **Sign Out** on iPhone/iPad/Mac | Local tombstone, clears local data. Links stay. The dialog names the devices that stay signed in (linked TVs and same-account devices from `CompanionRegistry`). |
| **Sign Out of All Devices** (iPhone/iPad Account, Mac Account) | Native confirmation naming the linked TVs. Queues a signed `session_revoke` for every linked TV (carrying the SoundCloud account id and the refresh-token lineage digest), deletes the iCloud session record, then signs this device out. A TV signs out only if the account id or lineage matches its own session, so one person can't sign a shared TV out of a different account. The TV keeps its Links and shows its sign-in screen; Remotes show Needs Sign-In. |
| SoundCloud revokes the token | Each device fails refresh on its own and walks its renewal sources. |

Both messages are `TokenTransferMessage`s with a `LinkRevokePayload` (`issuedAtMillis`, nonce, HMAC over `[sessionId, type, accountId, lineageDigest, issuedAt, nonce]` with the Link secret, 120 s freshness, per-session replay guard). The receiver answers with a plain `ack` on the same TLS-PSK connection.

---

## 5. The Remote

### 5.1 What it is
A Remote is an iPhone, iPad or Mac showing and controlling a **linked, signed-in Apple TV** over Companion. It is not an Output change: you can control the TV while this device plays something else.

With several linked TVs, one is **active** at a time: the one whose Remote was opened last, or the Output. Devices lists every TV; opening a TV's Remote, choosing it in Play On or tapping **Play on Bedroom** makes it active (the Mac Remote window has a TV picker when more than one is linked). If Output was a different TV, Output returns to this device and that TV keeps playing on its own. Moving Output from one TV to another sends the first TV's queue and position to the second.

There are two ways in, and they share one engine:
- **Output is the TV.** The mini player, Now Playing, the Mac toolbar capsule, the transport buttons and the Playback menu all *become* the TV's remote, like Apple Music with AirPlay.
- **Devices › Living Room › Remote** (iPhone/iPad), and **Playback › Remote ⌥⌘R** or **Play On › Remote** in the toolbar (Mac). This opens the Remote screen for the TV regardless of Output.

### 5.2 What it does

| Feature | How |
|---|---|
| Now playing (artwork, title, artist, live progress) | `playback_state`, interpolated from its anchor (no per-frame redraws; the screen ticks twice a second only while playing). The artwork URL comes from `playback_state` (falling back to the matching `queue_state` track); the hero shows any copy of that cover already cached (the mini player's thumbnail included) while the large one loads, and falls back to the thumbnail if the large one fails. |
| Play/pause, previous, next | `transport_*`, optimistic (§5.3). Previous restarts after 3 s, like the TV. |
| Scrub | system `Slider`; commits a `transport_seek` on release; optimistic. |
| Up Next with play-next | `queue_state`, which also carries the queue's source (`sourceTitle`, `sourceKind`; display-only) so Up Next says "Playing from <playlist>". `queue_load` carries the same source to the TV. Tap a row to jump; **Play Next** (context menu, swipe, VoiceOver action) moves it behind the current track; **Remove from Up Next**. |
| Like | the Remote's own SoundCloud session (`NowPlayingLikeModel`), so it shows the account's state and the TV picks it up through likes sync. |
| Start something on the TV | **Play on Living Room** in track menus on iPhone, iPad and Mac (when the TV is linked, advertised and isn't already the Output): makes it the active TV, loads the queue on it, waits for it to confirm, pauses here and makes the TV the Output. |
| Volume | The TV's system volume stays with the Siri Remote (tvOS apps can't set it). Sounding's own app volume (`PlayerService.volume`, 0–1, applied to the player and the mix engine's main mixer, remembered per device) travels as `transport_volume` (a signed continuous control with a sequence gate) and comes back in `playback_state.volume` (display-only, unsigned, like the title). The Watch's Output screen sets it on whichever device is the Output. The Remote still says "Change the volume with the Siri Remote." and the phone's own slider stays hidden while Output is the TV. |
| Mac shortcuts | Space, ⌘← ⌘→, ⌥⌘← ⌥⌘→ (15 s), ⇧⌘S, ⇧⌘R, ⌘L act on the TV when Output is the TV, or when the Remote window is key and the TV is reachable. ⌥⌘R opens the Remote. |
| Media keys, Control Center | Routed to the TV while Output is the TV. |

### 5.3 Instant feel: intents and reconciliation
`RemotePlaybackIntents` holds what the user just asked for until the TV agrees.

```
 tap ──► note intent (anchored at the presented position, now) ──► UI shows the intent at once
     └─► send signed command
 playback_state (rev r) ──► settle:
     transport  : rev > baseline and isPlaying matches          → done
                  rev > baseline and 1 s grace passed           → TV wins
     skip       : track changed (or, for restart, position ≈ 0)  → done
     seek       : |observed − (target + rate·elapsed)| ≤ 2 s     → done
     any        : 3 s deadline, or the link drops               → TV wins
```

- Stale frames already in flight (newer revision, old state) don't flicker the UI back inside the grace window.
- A skip shows the next track from Up Next (title, artwork, duration, position 0) before the TV confirms; Up Next follows the presented track.
- The intents live in `CompanionClient`, so every surface (Remote screen, mini player, Now Playing, Mac toolbar) is optimistic for free.
- Tests: `Tests/SoundingTVTests/Sources/RemotePlaybackIntentsTests.swift` (17 cases).

### 5.4 States
All centred, `ContentUnavailableView` or `ProgressView`:

| Phase | Shown |
|---|---|
| Not linked | "No Apple TV", **Add Apple TV…** |
| Connecting, nothing known | "Connecting to Living Room…" |
| Reconnecting with a snapshot | the remote, controls disabled, footer "Reconnecting…" |
| Unreachable | "Living Room Isn't Reachable", **Try Again**; the client also retries on its own (5 s doubling to 30 s) |
| Needs Sign-In | "Living Room Needs Sign-In", **Sign In This Apple TV** |
| Connected, idle | "Nothing Playing" |
| Playing or paused | the remote |

When Output is the TV and it becomes unreachable, iPhone/iPad Now Playing covers itself with the same unreachable view, plus **Play on This iPhone** and **Close**. A brief drop (watchdog reconnect) doesn't show it; only a failed reconnect does.

### 5.5 Accessibility
Every control has a label; the artwork is decorative; the title and artist read as one element; the scrubber is the system slider with a spoken value ("30 minutes, 39 seconds of …"); queue rows read as one element with Play Next and Remove actions; transport stays at most xxxLarge so it can't overflow at AX5; Mac has full keyboard access.

### 5.6 Role combinations and who owns the queue

The queue always lives on the device that is playing. A Remote never holds a second copy it can drift from: it shows the Output's `queue_state` and sends edits, which the Output applies and re-broadcasts.

| Mode | This device's Output | Audio plays on | Queue owner | What this device's transport, Now Playing, Up Next, media keys and Control Center drive |
|---|---|---|---|---|
| Local | This Mac / iPhone / iPad | this device | this device | this device |
| **Remote alongside** (Remote screen or Mac Remote window while Output is local) | this device | this device **and** the TV, independently | each device owns its own queue | the app's transport and system Now Playing drive this device; the Remote screen/window drives the TV |
| **Output = Living Room** ("TV is the speaker") | Living Room | the TV | the TV | the TV, everywhere: toolbar, capsule, Now Playing, Up Next, Playback menu, menu bar extra, media keys, Control Center |

Moving between modes moves the queue:
- **To the TV** (Play On › Living Room, or Play on Living Room from a track): the queue is sent as `queue_load` (up to 300 ids around the current track) with the position; once the TV confirms, this device pauses and stops owning a queue.
- **Back here** (Play On › This Mac): the TV's queue ids are resolved through the API, loaded here at the TV's position, and the TV is paused.
- **Play Next / Play Last** while Output is the TV insert into the TV's queue (optimistically shown here).

### 5.7 The Mac's two forms
1. **Integrated (Output = Living Room).** The toolbar transport, the now-playing capsule, Now Playing, Up Next, the Playback menu shortcuts and the menu bar extra all control the TV. Browsing, search and library actions keep working; Play and Play Next send to the TV. The system Now Playing (Control Center, media keys, the menu bar Now Playing widget) is routed to the TV through `PlayerService.routeSystemNowPlaying`, which `OutputRouter` sets whenever the Output is remote. Decks stay local: the TV's mix engine is controlled from the iPhone's Decks screen, not the Mac's.
2. **"Mac is the remote, TV is the speaker".** This is form 1: it's just Output = Living Room done properly on the Mac, chosen from **Play On** in the toolbar or **Play on Living Room** on any track.

### 5.8 Fixtures
`SOUNDING_TV_REMOTE_FIXTURE=playing|paused|nothing|needsSignIn|connecting|reconnecting|unreachable|unlinked` makes `CompanionClient` a fake linked "Living Room" that echoes commands after 350 ms (DEBUG only, touches no keychain). `SOUNDING_TV_REMOTE_FIXTURE_TVS=2` adds an advertised "Bedroom". `SOUNDING_TV_REMOTE_OPEN=1` with `SOUNDING_TV_PHONE_SETTINGS=devices` opens the Remote on iPhone; `SOUNDING_TV_REMOTE_OUTPUT=1` makes the TV the Output. `SOUNDING_TV_TV_STORY_DETAIL=1` opens the active TV's detail and `SOUNDING_TV_TV_STORY_FORGET=1` its Forget dialog; `SOUNDING_TV_OPEN_SIGN_OUT=here|everywhere` opens a sign-out dialog (iOS Account, Mac Account). Screenshots: `Screenshots/Remote/`, `Screenshots/DevicesAuth/`.


### 5.9 Sonos as an Output (2026-11-07)
Owner decision: Sonos rooms and groups are Outputs. It relies on Sonos's unofficial local control (UPnP/SOAP on port 1400), which the owner accepted.

- **Model.** A Sonos group is an Output, but the queue, the engine and Now Playing stay on the sending device (iPhone, iPad, Mac or Apple TV). Sonos only pulls a live stream of what that device renders. `OutputRouter.current` stays `.thisDevice`; `SonosOutputController` (`Core/Playback/`) owns which group is playing, the stream server and the Sonos volume. Picking a linked Apple TV or This iPhone stops the Sonos stream first; picking a Sonos group while the TV is the Output moves playback back here first. `DeviceClass` is unchanged: Sonos isn't a Sounding device.
- **Discovery.** Bonjour `_sonos._tcp` (in every app's `NSBonjourServices`), then `ZoneGroupTopology#GetZoneGroupState` on port 1400 from any player. Bonded satellites (subs, surrounds) are hidden. Each group is one row: "Soundbar", "Den", "Soundbar + Den" (coordinator first). No SSDP, so no multicast entitlement.
- **Control** (`Core/Sonos/`, pure Foundation, `SonosClient`): RenderingControl and GroupRenderingControl volume and mute, AVTransport play, pause, stop and now playing, join (`x-rincon:<coordinator>`) and leave (`BecomeCoordinatorOfStandaloneGroup`). Transport and group volume go to the group coordinator. ••• on a row adds or removes rooms (a context menu on Apple TV).
- **Stream.** The sending device runs a Network.framework HTTP server (`Core/Sonos/Streaming/`) on an unguessable path. All playback goes through the mix engine while Sonos is the Output (`PlayerService.requiresMixEngineOutput`), so normal playback, Auto Mix and Decks mixes are one signal. A tap on the engine's mix (built in a nonisolated static func, never inline in the `@MainActor` engine) writes into a lock-free ring buffer; an encoder queue turns it into **AAC-LC 256 kbps in ADTS**, served as internet radio (`x-rincon-mp3radio://`) with DIDL-Lite metadata (title, artist, artwork URL) and ICY `StreamTitle` updates on track change. Local output is muted while the tap keeps full level. While paused the server keeps sending encoded silence so Sonos holds the stream. The encoder is paced by the wall clock (`SonosStreamPacer`), not by the tap: at most 0.25 s ahead, silence once 0.3 s behind, oldest audio dropped beyond a 0.75 s backlog, so a slow or bursty mix never starves or floods Sonos (2026-11-09).
- **Latency.** Sonos buffers a few seconds. Every 2 s the controller compares the frames produced with Sonos's `GetPositionInfo` elapsed time (or the wall clock since Play when radio reports none), median-smooths it (`SonosLatencyEstimator`, 0.2–10 s) and sets `MixEngine.additionalOutputLatency`, so `audiblePosition`, Now Playing, the Auto Mix live view and Home Lighting follow what Sonos plays.
- **Staying alive.** iOS keeps the app running through the existing audio background mode while the engine renders; the Mac holds a `ProcessInfo` activity that stops idle sleep. The Connect sheet footer says "Keep this iPhone on the same Wi-Fi while it plays on Sonos."
- **Connect sheet** (iPhone and iPad from the mini player's Play On… and Now Playing's Output button; Mac toolbar Play On popover; Apple TV's Output panel keeps its rows and gains Sonos rows): the current Output at the top with its name, a quality badge ("Sonos · AAC 256 kbps"), what's playing and a volume slider (Sonos volume when Sonos plays; hidden while a TV is the Output, as before); then every other Output; then Sonos groups with •••; then **Bluetooth & AirPlay** (the system route picker; on the Mac, Sound settings).
- **Safety.** Agents may only run read-only discovery and status queries against real speakers. Control and stream tests use a fake Sonos (a recorded-SOAP transport and a plain HTTP client).
- **Fixtures.** `SOUNDING_TV_SONOS_FIXTURE=1` lists Soundbar + Den, Kitchen and Bedroom without touching the network; `=active` also makes Soundbar + Den the Output. `SOUNDING_TV_MAC_OPEN_CONNECT=1` opens the Mac popover.
- **Needs real-device testing:** start-up time and real buffering latency on the owner's Sonos; whether radio-mode `GetPositionInfo` reports elapsed time; group volume through `SnapshotGroupVolume`; an iPhone locked and paused for minutes (iOS may suspend the app once the engine stops rendering); long sets through the engine; Apple TV as the sender.

---

## 6. Threat model

| Threat | Mitigation | Residual |
|---|---|---|
| Someone on the Wi-Fi but not in the room links to the TV | QR needs line of sight; numeric code needs a human comparison; chime is a PAKE (one online 2⁻²⁴ guess per hello, rate-limited). | The numeric path hands the TV's session secret to any LAN client that gets a "match" from an inattentive user. |
| Someone on the Wi-Fi reads or injects Companion traffic | TLS 1.3 PSK per Link; every frame HMAC-signed; freshness windows (120 s) and nonce replay guards; continuous controls use sequence gates. | `playback_state` signs ids and timing but not title, artist or artwork URL (TLS covers them in transit). |
| A Remote's token is copied to the TV and then the Remote signs out | Plain Sign Out keeps the TV signed in and says so. **Sign Out of All Devices** sends `session_revoke`, checked against the TV's own account. | A TV that's offline for more than 14 days keeps its copy. |
| A guest's phone links to a household TV | Linking a signed-in TV sends no token (`link_establish`), so the TV keeps its account. A guest's sign-in on the TV stays off the owner's iCloud. Forget Device on the TV removes the Link. | A guest who links can control playback, labelled "Signed in as <guest>" on the TV. |
| A linked device switches the TV's account | Confirmed on the phone and on the TV's own alert (presence in the room); the pair is sent only after the TV accepts, bound to a single-use nonce; the TV validates it before signing the old account out. | Someone at the TV's remote who is also linked can switch it, as Sign Out on the TV allows today. |
| Sync moves a device to another account | `SessionSyncPolicy.remoteWins` never crosses known, different account tags; a signed-out device only offers **Continue as**. | Records from older builds carry no tag and keep the old ordering. |
| A forgotten Remote keeps control | Forgetting on either side sends a signed `link_revoke`; the other side drops the secret. | While the peer stays offline, the forgetter's outbox (phone) or removal notice (TV) holds the secret for up to 14 days so it can deliver the revoke. |
| Stolen phone | Link secrets are `ThisDeviceOnly`, after-first-unlock. | A stolen unlocked phone can control the TV until forgotten on the TV, or until **Sign Out of All Devices** from another device signs the TV out (it doesn't revoke the stolen phone's Link). |
| Shared keychain group leaks to extensions | Share and Widget extensions can read the Link record. | They only use it to queue tracks on the TV (`ShareDestination`), which is intended. |
| Sound leaks the chime code through a wall | CPace makes the code useless without the live handshake; 120 s expiry, single use. | — |

---

## 7. Gaps and inconsistencies found

| # | Gap | Status |
|---|---|---|
| G1 | iPhones, iPads and Macs held **one** Link (`paired_tv`); linking a second TV silently replaced the first, while a TV holds 8. | **Fixed**: `LinkedCompanionLedger` keeps up to 8 Links, most recently used first, and migrates the old record. Devices (iPhone, iPad, Mac) lists every TV with its status; `CompanionClient` keeps one active TV and probes the rest; Remote, Output and Play On select the TV they act on (`CompanionClient.select`, `OutputRouter.focus`). Tests: `LinkLifecycleTests.swift`. |
| G2 | Forgetting was one-sided; the other side showed Not Reachable forever. | **Fixed**: signed `link_revoke` both ways, a phone-side outbox and a TV-side removal notice for offline peers (§4.5). |
| G3 | No sign-out-everywhere for a TV holding a copy of your pair. | **Fixed**: **Sign Out of All Devices** (iPhone/iPad Account, Mac Account) sends `session_revoke` to every linked TV and deletes the iCloud session record; plain Sign Out names the devices that stay signed in (§4.5). Other same-account phones and Macs signed in on their own keep their sessions and may write a new iCloud record. |
| G4 | `CloudPairingOfferMonitor`, `MacCloudPairingOfferMonitor` and the Watch's "authorise waiting TV" read the TV's offer from a keychain item that was `ThisDeviceOnly` and not synchronisable, so another device could never see it. | **Fixed by removal.** Publishing a TV's one-time Link secret through iCloud would add a new trust anchor (anyone on the Apple ID could link) while the pairing crypto is being reworked, and same-account TVs already sign in from the iCloud session record. The TV no longer writes the offer (and deletes any old one at launch); the iPhone, Mac and Watch monitors, the "Continue" offer buttons and the Watch's "Sign In Living Room" row are gone. Nearby TVs are still found by `LinkOfferBrowser` (Bonjour). |
| G5 | Mac with Output = Apple TV still played new tracks on the Mac; the toolbar transport, Playback menu, menu bar extra and scrubber controlled the Mac player; the capsule, Now Playing and Up Next showed the Mac's own state; media keys and Control Center drove the paused Mac player. | **Fixed**: play actions route through `MacPlayback`/`OutputRouter`; toolbar, menu, menu bar extra and timeline follow Output; `MacNowPlayingModel` follows the TV's track; Up Next shows the TV's queue; system Now Playing is routed to the TV (iPhone and iPad too). Playlist, album, station and artist plays and shuffles, Play Next/Last (menus, accessibility actions, bulk) and the Now Playing window transport also go through `MacPlayback` with a `PlaybackQueueSource`; Up Next shows "Playing from <source>" for whichever device plays, and the Now Playing volume slider sets the TV's volume. Decks and Prep previews stay local. |
| G6 | The phone's volume slider changed the phone's volume while audio played on the TV. | **Fixed**: hidden while Output is remote; the Remote says to use the Siri Remote. |
| G7 | Remote play/pause and skips waited a round trip; the scrubber only. | **Fixed**: intents (§5.3). |
| G8 | `CompanionClient.fail` put raw `NWError` text into the state, which the device detail footer showed. | **Fixed**: `State.failed(CompanionFailure)`; `CompanionFailure.classify` maps `NWError` (DNS, policy denied, POSIX, TLS) to six plain messages, shown in the detail footer, the Mac row and the Remote's unreachable view. |
| G9 | Two install ids (`LinkPeerIdentity.localDeviceId`, `DownloadManifestDeviceIdentity.deviceId()`). | Open. Merge into one `DeviceIdentity.installId`. |
| G11 | `OutputDevice.deviceClassesThatAcceptOutput == [.tv]`; a Mac could be an Output (same player, same `CompanionServer` shape). | Open, low priority. |
| G12 | `DeviceClass.hasBattery` was `true` for every Mac. | **Removed** with Polyphony (2026-11-08); Mac device conditions still report real charge and power state through `MacPowerSource`. |
| G13 | Phones sent a `session_request` the TV always declined. | **Fixed**: removed from `CompanionClient`; the TV still declines requests from older builds. |
| G14 | A Link can only be created by sending a token; there is no "control only" link for a guest who shouldn't sign the TV in. | Closed 2026-11-12: `link_establish` makes a Link with no token for a signed-in TV. |

---

## 8. Needs real-device testing
- Two Apple TVs linked to one iPhone: switching the Remote between them, Play On › Bedroom while Output is Living Room, and the Available / Not Reachable statuses as TVs sleep.
- Forget on the iPhone while the TV is asleep, then wake it: the TV should drop the Link within seconds of the iPhone seeing it. Forget on the TV while the iPhone is in another room: the iPhone should remove the TV the next time it opens Devices or the Remote.
- **Sign Out of All Devices** with the TV awake and asleep, with the TV on the same and on a different SoundCloud account (it must not sign out a different account).
- Upgrading a build with one stored Link: it must appear in the new list without re-linking.
- A MacBook and a Mac mini: Workshop conditions.
- Remote latency on the owner's Apple TV over real Wi-Fi: intent → TV → confirming frame, and whether the 1 s grace / 3 s deadline feel right.
- Reconnection after the TV sleeps and wakes, and after the iPad sleeps (the client disconnects in the background and reconnects on foreground).
- **Play on Living Room** with a long queue (window of 300 tracks) and with a track the TV's session can't stream.
- Needs Sign-In → **Sign In This Apple TV** from the Remote screen on the iPad.
- Mac: Space and arrows while the Remote window is key but Output is the Mac.
- The iPad's sidebar layout of the Remote screen and Now Playing columns with Output = TV.
- Media keys, Control Center and the lock screen driving the TV while Output = TV. On iPhone and iPad, iOS may stop treating Sounding as the Now Playing app once its own audio is paused; on the Mac it should hold.
