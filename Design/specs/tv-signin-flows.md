# TV sign-in flows by account state

Status: **spec for owner review, 2026-11-12.** Nothing here is built. Once the owner answers §10, the decisions go into the bible (§11 lists the edits) and this file becomes the build brief.

Scope: what an Apple TV and an iPhone, iPad or Mac show for every combination of sign-in state, and the identity, protocol and security changes that make it work. Every phone-side surface is one shared implementation used by iPhone, iPad and Mac; only chrome differs (owner, 2026-11-12: "MUST be there for all devices").

Vocabulary is the bible's (§8): **Link** is trust and credentials, **Companion** is the control channel, **Output** is where audio plays, listening together is **SharePlay**, **Handoff** is only `NSUserActivity`. "Companion" never appears in the UI. `DeviceClass` is the only device identity. In this file "phone" means iPhone, iPad or Mac (the Remote side); copy uses `DeviceClass.current.displayName`.

Example names used throughout: the TV is **Living Room**; you are **Alex** on **Alex's iPhone**; the other account is **Sam**.

Related: `devices-and-auth.md` (trust, Link, Remote), `chime-signin.md`, bible §2 Apple TV sign-in screen, §9 Nearby Apple TV card.

---

## 1. What each device knows about the other's account today

| Channel | Direction | Carries | What the receiver can tell |
|---|---|---|---|
| Link offer TXT (`SoundingTV-LinkOffer-*`, plain Bonjour) | TV → LAN | Signed in: `as` salt, `ah` = 12-byte salted hash of the SoundCloud user id, `lp` = linked-device hashes. Signed out: no hint. | Signed out, or signed in to **my** account, or signed in to **another** account. Never which one. |
| Nearby presence (`SoundingTV-Nearby-*`) | phone → LAN | Same salted hash, the phone's name. Only while the phone is signed in, in the foreground and offering a card. | TV: "a phone on my account is nearby". A signed-out phone advertises nothing. |
| Numeric handshake owner proof (`LinkOwnerProof`) | both, over the offer socket | HMAC bound to the Apple ID link key **and** the TV's SoundCloud user id. | Same Apple ID and same SoundCloud account. Sent only when the hint already matches. |
| `token_transfer` (TLS-PSK Link) | phone → TV | The phone's token pair and `LinkPeerIdentity` (name, class, device id). | The TV validates the token but never compares its account with its own. |
| Companion `device_status` | TV → phone | `needsSignIn` only. Sent on connect and when `needsSignIn` flips. | Signed in or not. **No account.** An account change on the TV is never announced. |
| Companion announce (`queue_request` + `LinkPeerIdentity`) | phone → TV | Name, class, device id. | **No account.** |
| iCloud `session` record | any → same Apple ID | One token pair per Apple ID. **No account field.** | Nothing about whose account it is until `/me` is called. |
| iCloud `AccountSignIn`, `NearbyLinkRequest`, `ContinueSession` | any → same Apple ID | Account tag (hash), device name and kind. | Same account or not, for notifications, presence and Continue From. |

**Missing:** (1) a linked phone never learns the TV's account, and the TV never learns a controller's; (2) nothing says *who* the other account is, so "Living Room is signed in as Sam, you're Alex" can't be drawn; (3) nothing compares accounts before a token is accepted; (4) iCloud session sync is account-blind.

## 2. What happens today, and what's broken

| TV | Phone | Today |
|---|---|---|
| Signed out | Signed in | Flow 2 works: QR, the card's **Sign In** with the chime, the "<iPad> is nearby" line, sign-in requests, the device picker. Same Apple ID and no sign-out tombstone: the TV adopts the iCloud pair with no taps. |
| Signed in, same account | Signed in | Card **Link**. Same Apple ID with link keys: one tap. Otherwise six digits and **Allow**. A token is still sent (the TV discards it). |
| Signed in | Signed out | Nothing. The TV is "never a source over the LAN". Same Apple ID and never signed out: the phone silently adopts the iCloud pair. After an explicit sign-out: the welcome, nothing about the TV. Links survive, so a signed-out phone still controls a linked TV. |
| Signed in, other account | Signed in | No card (hint mismatch). Play On's Nearby section lists the TV anyway with **Link**. Nothing is shown about the account on either side. |

Broken or unsafe today (from reading the code; not reproduced on devices):

- **B1. Add a Device switches a TV's account silently.** `QRCodeLoginView(purpose: .companion)` calls `authService.authenticate` with whatever token arrives, so a phone on Sam's account that links through Settings › Add a Device signs Living Room out of Alex and into Sam with no prompt on either side.
- **B2. A different-account Link is made with false copy.** Play On's Nearby rows (`PlayOnNearbyLinking.makeRows`) don't filter by account. Linking runs against the TV's background `SameAccountLinkAdvertiser`, whose Allow alert (`RootView.SameAccountLinking`) always says "It's signed in to your SoundCloud account". The Link succeeds, the TV keeps its own session, and the phone never learns the accounts differ.
- **B3. The TV adopts an unsolicited auth handoff while signed in.** `CompanionServer.handleAuthHandoffSessionOffer` adopts any `companion_session_offer` from any linked peer, whether or not the TV needs signing in. The phone only sends one for Needs Sign-In, but the TV doesn't enforce it.
- **B4. iCloud session sync crosses accounts.** `SessionSyncPolicy.remoteWins` compares issue times only. A device on Alex adopts Sam's pair if Sam signed in later anywhere on the same Apple ID. And the TV pushes whatever it was signed in with (B1, or a guest's flow-2 sign-in) into the TV owner's iCloud.
- **B5. Cross-account rejections are silent, or blamed on the wrong thing.** `CompanionClient.rejection` is published but no view reads it. On connect the phone pushes likes and the library; a TV on another account answers `Library sync rejected`. `PlaybackConfirmationTracker.observeRejection` resolves **every** pending confirmation on any error frame, so a Play On move made just after connecting can report "Living Room couldn't play this" when the TV only refused the library.
- **B6. An account change on the TV is never announced.** `announceDeviceStatusIfChanged` only fires when `needsSignIn` flips.
- **B7. Presence leaks across accounts.** `DevicePresence`'s Companion source isn't account-checked, so a linked TV on Sam's account shows in Alex's bar ("Living Room is playing…"), against the bible's privacy rule.
- **B8. Not shared.** `PeerSignInPrompt` lives in the iOS target; the Mac has its own Needs Sign-In row in `MacDevicesSettingsTab`.

---

## 3. The model: one relation, resolved by one pure function

```
TVAccount     = signedOut | needsSignIn(last: PeerAccount?) | signedIn(PeerAccount) | signedInOther | signedInSame
                 (the last two come from an unlinked offer's hint, where the name isn't known)
PhoneAccount  = signedOut | signedIn(PeerAccount)
LinkState     = linked(connected | notReachable) | unlinked
Evidence      = ownerProven (same Apple ID, same account) | iCloudOffer(PeerAccount, deviceName)?

TVAccountRelation.resolve(tv:phone:link:evidence:) ->
  .sameAccount(linked, ownerProven)                 flow 1
  .tvSignedOut(linked)                              flow 2
  .tvNeedsSignIn(last: PeerAccount?, mine)          flow 2b
  .phoneSignedOut(tv: PeerAccount?, iCloudOffer?)   flow 3
  .differentAccounts(tv: PeerAccount?, mine)        flow 4
  .unknown                                          linked TV on an older build: today's behaviour
```

`PeerAccount` is `{ tag, name, username, avatarURL? }`: `tag` is `AccountSignIn.accountTag(userId:)` (8 bytes of SHA-256, never the raw id), `name` is `User.displayName`. Accounts compare by `tag` only. It lives in `Auth/Shared` and crosses the wire as opaque `Data` (§7).

Every surface in §6 reads this relation through `SoundingTV.swiftpm/Sources/Shared/ViewModels/TVAccountMatch.swift` (new, shared by iPhone, iPad and Mac; `PeerSignInPrompt` moves into it). The TV has its own small resolver for its side (`TVControllerAccount`).

## 4. State matrix

"Linked" means a Link exists between this phone and this TV. TV-side items marked (TV).

| # | TV | Phone | Linked | Flow | TV shows | Phone shows |
|---|---|---|---|---|---|---|
| 1 | Alex | Alex | yes | 1 | Normal. (TV) Remotes & Devices row has no account line. | Normal. Play On row has no account line. |
| 2 | Alex | Alex | no, same Apple ID | 1 | "Alex's iPhone is linked" capsule, 4 s. | Links with no taps; "Linked to Living Room" capsule, 2 s. |
| 3 | Alex | Alex | no, other Apple ID | 1 | Allow alert, "signed in to the same SoundCloud account". | Card **Link**, then the six digits. |
| 4 | signed out | Alex | either | 2 | Sign-in screen (QR, nearby line, **Play Sound**). | Card **Sign In** "as Alex", chime; or QR; or Sign In This Apple TV when linked. |
| 5 | needs sign-in, was Alex | Alex | yes | 2b | Sign-in screen. | Devices: "Living Room is waiting to sign in." **Sign In This Apple TV**. |
| 6 | needs sign-in, was Sam | Alex | yes | 2b | Sign-in screen. | "Living Room was signed in as Sam." **Sign In as Alex**. |
| 7 | signed out | signed out | either | — | Sign-in screen. | Welcome. Nothing about the TV. |
| 8 | Sam | signed out | no | 3 | Nothing. | Welcome. Same Apple ID with Sam's pair in iCloud: **Continue as Sam**. |
| 9 | Sam | signed out | yes | 3 | Nothing new. | Welcome with "Living Room is signed in as Sam" and, when iCloud has the pair, **Continue as Sam**. Control still works. |
| 10 | Sam | Alex | no | 4 | Nothing until linking; then the "different account" Allow alert. | No card. Play On Nearby: "Signed in to another account", **Link**. |
| 11 | Sam | Alex | yes | 4 | "Alex's iPhone is connected · Alex" capsule once per connection; Remotes & Devices row "Signed in as Alex". | Play On row "Signed in as Sam"; first use asks **Play on Living Room** or **Switch Living Room to Alex…**. |
| 12 | Sam → Alex | Alex | yes | 4c | Switch alert, then "Switching to Alex…". | "Waiting for Living Room…", then flow 1. |

---

## 5. The flows

### Flow 1. Same account

Goal: no QR, no chime, no code. Zero taps when both devices prove the same Apple ID; one tap otherwise.

**1a. Already linked.** Nothing to do. Continue From, the other-devices bar and Output already carry the state.

**1b. Not linked, same Apple ID (auto-link).** Recommended in Q1.
- *When:* the phone is in the foreground, signed in, holds a link key, sees a TV offer whose hint matches its account and doesn't list it in `lp`, and isn't showing another pairing sheet. The TV isn't on Don't Ask or Not Now (`NearbyCardDismissals`). At most one attempt per TV per app launch.
- *What runs:* the numeric handshake with owner tags, no UI. When both proofs verify, the phone sends `link_establish` (§7 P3): a Link with **no token** (the TV already holds Alex's session). If either proof fails, nothing is shown and the card (1c) takes over.
- *Phone:* a glass capsule at the top, like the volume capsule: `appletv.fill` + "Linked to Living Room", 2 s, VoiceOver announcement. Mac: no capsule; the TV simply appears in Play On and Devices.
- *TV:* the existing bottom capsule "Alex's iPhone is linked", 4 s.
- *Timeout:* 15 s for the whole exchange, then silent fallback to 1c.

**1c. Not linked, one tap.** Today's card, unchanged except no token is sent:
- Card: `appletv.fill`, "Living Room", "Apple TV · Signed in as Alex", "Link it to control playback from this iPhone.", **Link**, **Not Now**.
- **Link** with owner proof: "Linking Living Room…" then done. Without: both screens show six digits; TV alert (§6 TV) with the "same account" message; phone **It Matches** / **It Doesn't Match**; then `link_establish`.
- Errors: the existing `SameAccountLinkOffer` copy ("Couldn't Link Living Room", "Living Room didn't finish linking. Try again from Devices.", 150 s).

```
 iPhone (1b, auto)                       Apple TV
 ┌────────────────────────────────┐      ┌─────────────────────────────────────────┐
 │ ( tv  Linked to Living Room )  │      │  Home                                   │
 │                                │      │                                         │
 │  Home                          │      │                                         │
 │  ...                           │      │     ( phone  Alex's iPhone is linked )  │
 └────────────────────────────────┘      └─────────────────────────────────────────┘
```

### Flow 2. TV signed out, phone signed in

Today's flow stays. Three changes: the phone names the account it will use, the TV says whose account it signed in to, and a linked TV that was on another account asks before signing in as you.

**TV sign-in screen** (bible §2 Apple TV; unchanged layout). One status line under the plate:

| State | Line |
|---|---|
| Waiting | "Scan with your iPhone camera, or open Sounding on your iPhone nearby." |
| A phone is offering | "Alex's iPad is nearby: open Sounding on it to sign in." |
| Phone connected | replaced by the centred **Connecting to Alex's iPad…** progress (`ContentUnavailableView` layout, orange tint) |
| Token received | "Signing you in…" |
| Last minute of a code | caption "New code in 42s" |
| Done | title "You're signed in", subtitle **"Signed in as Alex."** (new; was "Enjoy your music."), then Home after 1.5 s |
| Fault | the plate is replaced in place; **Try Again** |

Controls: **Play Sound** (glass capsule), **Sign in with iPhone** where the picker exists, **Try Again** only after a failure, **Use Without SoundCloud** as quiet text. Focus enters on **Play Sound**. No focus ring; focused chrome inverts to near-white with a black label.

```
 Apple TV, flow 2
 ┌──────────────────────────────────────────────────────────────────┐
 │                       Plug in. Turn it up.                       │
 │            Your SoundCloud on Apple TV, iPhone and Mac.          │
 │                          ┌────────────┐                          │
 │                          │ ▓▒ ░▓ ▒░▓▒ │                          │
 │                          │ ░▓  ))) ▓░ │                          │
 │                          │ ▒░▓▒ ░▓ ▒▓ │                          │
 │                          └────────────┘                          │
 │   [ipad] Alex's iPad is nearby: open Sounding on it to sign in.  │
 │                         New code in 42s                          │
 │               ( Play Sound )   ( Sign in with iPhone )           │
 │                      Use Without SoundCloud                      │
 └──────────────────────────────────────────────────────────────────┘
```

**Phone card** (shared `NearbyDeviceCard`): title "Living Room", subtitle "Apple TV · Not signed in", message **"Sign it in to Sounding as Alex."** (was "…with your SoundCloud account."), **Sign In**, **Not Now**. Phases and errors as today: "Listening for Living Room… Keep this iPhone near it." → "Connecting…" → "Signing in…" → "Signed in." Errors: "Couldn't hear Living Room. Turn its volume up and try again, or use the code instead." (20 s), "Couldn't reach Living Room. Make sure it's showing its sign-in screen, then try again.", microphone denied; each with **Try Again**, **Use QR Code Instead** (Mac: **Use a Code Instead**), **Not Now**.

```
 iPhone, flow 2 card
 ┌────────────────────────────────┐
 │            [ appletv ]         │
 │           Living Room          │
 │    Apple TV · Not signed in    │
 │  Sign it in to Sounding as     │
 │  Alex.                         │
 │ ┌────────────────────────────┐ │
 │ │          Sign In           │ │  prominent, brand orange
 │ └────────────────────────────┘ │
 │            Not Now             │
 └────────────────────────────────┘
```

**2b. Linked TV that needs signing in.** Devices row (iPhone, iPad, Mac), status **Needs Sign-In**:
- Last account unknown or Alex: "Living Room is waiting to sign in." footer "It'll use the SoundCloud account on this iPhone." **Sign In This Apple TV** (today).
- Last account Sam (new, from `account_status.last`): "Living Room was signed in as Sam." footer "Sign it in as Alex, or sign Sam in on Living Room." **Sign In as Alex**. The tap is the confirmation; the TV doesn't ask again, because it has no session to lose.
- Remote screen and Home prompt use the same copy. Timeout 20 s: "Living Room didn't answer. Keep it on and try again."

### Flow 3. Phone signed out, TV signed in

**Decision (Q2): the TV never gives its SoundCloud token to a phone over the network.** A Link holder could otherwise pull the household account, and every copy of a refresh token can invalidate the others. Instead:

**3a. Same Apple ID, Sam's pair in iCloud** (per-account records, §7 P8). The signed-out welcome (shared `SoundingWelcome`, iPhone, iPad, Mac) and Settings › Account (signed out) show the offer above the usual buttons:

```
 iPhone, flow 3 welcome
 ┌────────────────────────────────┐
 │       (line-art hero)          │
 │     Plug in. Turn it up.       │
 │                                │
 │   (avatar) Sam                 │
 │   Signed in on Living Room     │
 │ ┌────────────────────────────┐ │
 │ │      Continue as Sam       │ │  prominent
 │ └────────────────────────────┘ │
 │ ┌────────────────────────────┐ │
 │ │  Sign In with SoundCloud   │ │  bordered
 │ └────────────────────────────┘ │
 │     Use Without SoundCloud     │
 └────────────────────────────────┘
```

- "Signed in on <writer device name>" comes from the record's `writerName`; avatar from `PeerAccount.avatarURL` (cached art only, no request on appear).
- **Continue as Sam:** adopts the pair (validated, not refreshed, per the renewal rules), clears this device's sign-out tombstone, and announces **New Sign-In** only under the existing rule (first time this device holds Sam's account). Then the normal follow-up page with "✓ Signed in as Sam".
- Errors (centred, under the buttons): pair refused (`invalid_grant`) → "Sam's sign-in has expired. Sign in with SoundCloud instead." and the offer disappears; network → "Couldn't reach SoundCloud. Try again." Validation timeout 15 s.
- A fresh install that has never signed out keeps adopting with no taps (today's behaviour).

**3b. Linked TV, phone signed out.** Links survive Sign Out, so control keeps working: Play On lists Living Room, the Remote works, Control Living Room works. The welcome adds one quiet line under the headline, "Living Room is signed in as Sam." (from `account_status`), with **Continue as Sam** only when 3a's iCloud offer exists. Likes and Play on Living Room from a track need a session, as today.

**3c. Anything else** (other Apple ID, not linked): nothing. The phone signs in normally, then lands in flow 1 or 4.

**TV:** shows nothing for flow 3. It never prompts a signed-out phone.

### Flow 4. Different accounts

Rule: **controlling a TV on another account is allowed and always labelled; changing its account is a separate, explicit choice confirmed on both devices.**

**4a. Linked, TV on Sam, phone on Alex.** The phone learns "Sam" from `account_status` (§7 P2).

*First use* (choosing Living Room in Play On, **Control Living Room**, **Play on Living Room** from a track, or opening its Remote), once per (Link, TV account, my account): a native `confirmationDialog` (action sheet on iPhone, popover on iPad, alert sheet on the Mac):

```
 iPhone, flow 4 choice
 ┌────────────────────────────────┐
 │ Living Room is signed in as    │
 │ Sam                            │
 │ You're signed in as Alex.      │
 │ Living Room plays from Sam's   │
 │ SoundCloud, so tracks only     │
 │ Alex can play won't play there.│
 ├────────────────────────────────┤
 │      Play on Living Room       │  (or "Control Living Room")
 ├────────────────────────────────┤
 │  Switch Living Room to Alex…   │
 ├────────────────────────────────┤
 │             Cancel             │
 └────────────────────────────────┘
```

- **Play on / Control Living Room** remembers the choice (`CrossAccountChoice`, device-local) until either account changes, then does what was asked.
- **Switch Living Room to Alex…** runs 4c.
- **Cancel** does nothing.

*Ever after:*
- **Play On** (Connect sheet, Mac popover, toolbar menu, the Watch's Output via the iPhone): Living Room's row gets a secondary line **"Signed in as Sam"**.
- **Devices** (iPhone, iPad, Mac): the row's secondary line is "Signed in as Sam". The detail page gets an **Account** section: `LabeledContent("Signed In As", "Sam")`, **Switch Living Room to Alex…**, footer "You're signed in as Alex. Your likes and library stay with Alex."
- **Now Playing bar:** unchanged ("Playing on Living Room", "Connecting to Living Room…"). The account isn't repeated in the bar.
- **Other-devices bar** (`DevicePresence`): Living Room is left out unless it's the Output (fixes B7).
- **Like** on the phone still likes as Alex (the Remote's own session) and the heart shows Alex's state.

*Failures never silent* (fixes B5):
- Play On move refused because the TV's account can't play the track (`error.code = track_unavailable`): alert "Couldn't Play on Living Room", "It's signed in as Sam, who can't play this.", **Switch Living Room to Alex…**, **OK**. Other move failures keep today's copy ("Living Room didn't respond, so playback stayed on this iPhone.").
- A transport or queue command refused while Living Room is the Output: the mini player subtitle (iPhone, iPad) and the Mac capsule say "Living Room couldn't do that." for 4 s. Bar actions keep the bible's "Couldn't Switch Device".
- Library, likes and cue sync refusals stay quiet (they're expected across accounts) and never resolve a pending Play On.

*TV side:*
- When a controller on another account connects, the bottom glass capsule (non-focusable, like the nearby hint) says **"Alex's iPhone is connected · Alex"** for 4 s, once per connection.
- Settings › Remotes & Devices: that device's row adds a secondary line "Signed in as Alex". Same-account devices show no line.

**4b. Not linked, TV on Sam (hint doesn't match).**
- No nearby card and no outside notification (Q4).
- Play On's Nearby section and Add Apple TV list it with status **"Signed in to another account"** (was "Signed in").
- **Link** first asks: "Living Room is signed in to another SoundCloud account" / "Link it to control it from this iPhone. You can switch it to your account afterwards." **Link**, **Cancel**.
- Then the six digits. The TV's alert reads: **"Allow “Alex's iPhone” to control this Apple TV?"**, "It's signed in to a different SoundCloud account. Only allow it if Alex's iPhone shows this code.", the code, **Allow**, **Don't Allow** (fixes B2; the TV knows from the phone's account digest in `numeric_hello`, §7 P9).
- The Link is made with `link_establish`: **no token is sent**. Once connected, `account_status` names Sam and the 4a choice appears at once, because the user came from Play On.

**4c. Switch the TV to my account.**

1. Phone, confirmation alert: **"Switch Living Room to Alex?"**, "Sam will be signed out on Living Room. Sam's downloads and recent plays on it are removed.", **Switch**, **Cancel**.
2. Phone sends `account_switch_request` (Alex's `PeerAccount`, no token). The phone shows, inline where the user tapped (Devices row, Play On row, the dialog's origin): `ProgressView` + "Waiting for Living Room…", footer "Choose Switch on Living Room."
3. TV alert (tvOS native, focus defaults to the cancel action):

```
 Apple TV, flow 4c
 ┌──────────────────────────────────────────────────────────┐
 │              Switch to Alex's SoundCloud?                │
 │   Alex's iPhone wants to sign this Apple TV in as Alex.  │
 │              Sam will be signed out here.                │
 │                                                          │
 │                    (    Switch     )                     │
 │                    (   Keep Sam    )                     │
 └──────────────────────────────────────────────────────────┘
```

4. **Switch** → TV answers `account_switch_answer(accepted)`. Only now does the phone send its pair (`account_switch_credentials`). The TV shows the centred link-progress view, **"Switching to Alex…"**, validates the pair, then, only if it's valid, signs Sam out locally (account-scoped data wiped as on Sign Out; **Links kept**), adopts Alex, writes `AccountSignIn` and announces `account_status` to every connected controller. Home shows the capsule "Signed in as Alex", 4 s.
5. Phone: the row says "Living Room is signed in as Alex." and the relation becomes flow 1.

| Outcome | Phone copy (inline, never an alert) | TV |
|---|---|---|
| **Keep Sam** | "Living Room kept Sam's account." | alert closes |
| No answer in 60 s | "Living Room didn't answer. Its account hasn't changed." **Try Again** | alert withdrawn |
| TV can't reach SoundCloud | "Living Room couldn't reach SoundCloud. Its account hasn't changed." **Try Again** | stays on Sam |
| Pair refused | "Your sign-in on this iPhone needs renewing. Try again in a moment." | stays on Sam |
| Link drops mid-way (30 s) | "Living Room isn't reachable. Its account hasn't changed." | stays on Sam unless validation already finished |
| TV on an older build | **Switch Living Room to Alex…** isn't offered | — |

Other linked devices on Sam's account become "different account" controllers of Living Room and see 4a on their next use.

---

## 6. Surfaces at a glance

| Surface | Shared code | Flow 1 | Flow 2 | Flow 3 | Flow 4 |
|---|---|---|---|---|---|
| TV sign-in screen | `QRCodeLoginView` (tvOS) | — | as today + "Signed in as Alex." on done | — | — |
| TV Allow alert | `RootView` / `QRCodeLoginView` | "It's signed in to the same SoundCloud account. Only allow it if <device> shows this code." | — | — | "Allow … to control this Apple TV?" + "different account" copy |
| TV capsule | `SameAccountLinking` | "<device> is linked" | — | — | "<device> is connected · Alex"; "Signed in as Alex" after a switch |
| TV switch alert, progress | new `TVAccountSwitchPrompt` | — | — | — | 4c |
| TV Remotes & Devices | `SettingsView` | no line | — | — | "Signed in as Alex" per other-account device |
| Nearby card (iPhone, iPad, Mac) | `NearbyDeviceCard` | 1c; never in 1b | "Sign it in to Sounding as Alex." | — | never |
| Linked capsule (iPhone, iPad) | new `LinkedCapsule` beside the volume capsule | "Linked to Living Room" | — | — | — |
| Devices list and detail | new shared `LinkedDeviceAccountSection` (replaces the iOS and Mac rows; `PeerSignInPrompt` moves to Shared) | — | 2b copy | "Signed in as Sam" | account section, Switch |
| Play On rows and Nearby | `OutputRouter.entries`, `PlayOnNearbyLinking` | — | "Ready to sign in" | "Signed in as Sam" | "Signed in as Sam" / "Signed in to another account" |
| Cross-account choice | new `CrossAccountChoiceDialog` modifier | — | — | — | 4a |
| Now Playing bar, Mac capsule | existing | — | — | — | failure caption only |
| Other-devices bar | `DevicePresence` | as today | — | — | other-account TV hidden unless Output |
| Welcome, Account (signed out) | `SoundingWelcome`, `OnboardingFeaturePage` | — | — | Continue as Sam | — |
| Watch, CarPlay | via the iPhone | — | — | — | Output names only; failures show on the iPhone |

---

## 7. Data and protocol changes

`TokenTransferProtocol.swift` stays dependency-free: new payloads carry identity as opaque `Data` (base64 in JSON), decoded by `PeerAccount` in `Auth/Shared/PeerAccount.swift`, which the watch, Share and widget targets never need to decode. Build the iOS scheme to catch breaks.

| # | Change | Channel | Direction | When |
|---|---|---|---|---|
| P1 | `PeerAccount { tag, name, username, avatarURL? }`, JSON, at most 512 bytes. Never the raw user id, never a token. | — | — | — |
| P2 | New `account_status { state: signedIn\|signedOut\|needsSignIn, account: Data?, last: Data?, capabilities: [String], issuedAtMillis, signature }`, HMAC over `[sessionId, "account_status", state, base64(account), base64(last), capabilities joined, issuedAt]`, 120 s freshness. Capabilities: `link_establish`, `account_switch`. | Companion (TLS-PSK) | TV → phone, and phone → TV | on connect, and whenever the account or sign-in state changes (fixes B6). `device_status` stays for older peers. A phone sends its own only after the TV has sent one (so older TVs never see an unknown message). |
| P3 | `link_establish { LinkPeerIdentity, account: Data? }` → `link_established { needsCredentials: Bool, account: Data? }`. The phone sends `token_transfer` **only** if `needsCredentials` (the TV is signed out). Older TVs answer `Unsupported message`; the phone then falls back to `token_transfer` only if the offer had no account hint (or, for a QR scan with no offer seen, as today). | Link (TLS-PSK) | phone ↔ TV | every new Link (QR, code, chime, picker, auto-link) |
| P4 | `account_switch_request { account: Data, nonce }`, `account_switch_answer { nonce, accepted\|declined }`, `account_switch_credentials { nonce, TokenPayload }`. 60 s to answer, 30 s for credentials, nonce single use. | Companion | phone → TV → phone → TV | 4c only |
| P5 | The TV accepts `companion_session_offer` only while it needs sign-in and a matching `companion_session_request` or Needs Sign-In is outstanding; otherwise `error` with code `not_expected` (fixes B3). | Companion | TV | always |
| P6 | `error` gains an optional `code` (`track_unavailable`, `queue_unavailable`, `sync_refused`, `not_expected`). `PlaybackConfirmationTracker.observeRejection` resolves only the waiter whose command the error answers; `sync_refused` resolves none (fixes B5). | Companion | TV → phone | — |
| P7 | Bonjour TXT unchanged: names and accounts never go on the network in the clear. | — | — | — |
| P8 | iCloud session records become one per account: record name `session-<accountTag>`, adding `accountTag`, `accountName`, `writerName`, `writerKind` (encrypted fields). `SessionSyncPolicy.remoteWins` never moves a signed-in device to another account; a device with no session and no tombstone adopts the newest record; with a tombstone it only offers **Continue as** (3a). The legacy single record is read once and rewritten under its account's tag. (Fixes B4.) | iCloud | any | after sign-in or refresh |
| P9 | `numeric_hello` adds `accountDigest` (the phone's `ah` computed with the TV's advertised salt). The TV picks the Allow copy from it. Absent (older phone) means the "different account" copy. | Link offer (plain, sealed after the exchange) | phone → TV | numeric and chime hellos |
| P10 | The TV writes its session to iCloud only when it came from iCloud, from an owner-proven Link (same Apple ID), or from a switch confirmed with an owner-proven peer. A guest's sign-in stays on the TV. | iCloud | TV | — |

Pure helpers that drive the UI, all in shared code and unit-tested: `TVAccountRelation.resolve`, `AutoLinkPolicy.shouldAttempt`, `CrossAccountChoice` (remember and forget), `AccountSwitchHandshake` (state machine), `LinkEstablishPolicy.sendsCredentials`, `TVAccountCopy` (every string in §5 keyed by relation and surface), `SessionSyncPolicy` (account-aware), `TVControllerAccount` (TV side).

## 8. Security

1. **No token reaches a TV without a person choosing it.** Tokens move only for flow 2 (card **Sign In**, scanning the QR, the picker's approval, **Sign In This Apple TV** / **Sign In as Alex**) and 4c after **Switch** on both devices. A signed-in TV never receives a token from linking (`link_establish`), and nothing is sent before the TV's own **Switch**.
2. **Across accounts, only an explicit choice switches anything.** Add a Device, the background same-account advertiser, auth handoff and iCloud sync can no longer change a signed-in device's account (B1, B3, B4).
3. **Switching needs presence at the TV.** The TV's own alert is the physical-presence check: a Link holder in another room, or whose phone was stolen, can't sign the household out of its account.
4. **The validated pair replaces the old one atomically.** The TV keeps Sam until Alex's pair has been validated; any failure leaves it on Sam.
5. **Identity leaves only over authenticated channels.** Names and avatars travel only inside TLS-PSK Companion frames between linked devices, or in encrypted iCloud fields on the same Apple ID. The LAN sees salted hashes, as today. An unlinked TV on another account is "another account", never a name.
6. **The TV is never a credential source over the LAN** (flow 3). Same-Apple-ID iCloud is the only way a TV's account reaches a phone, and only by the phone's **Continue as**.
7. **Guest sessions stay off the owner's iCloud** (P10).
8. **Auto-link needs two proofs** (Apple ID link key and the same SoundCloud account, bound to the handshake) and sends no token. Revocation, Forget and Sign Out of All Devices are unchanged.
9. Residual: a person who can both reach the TV's remote and is linked can switch its account; that matches Sign Out on the TV today.

## 9. Test plan

Unit tests (XCTest target `SoundingTVTests`, wrapped in `XCTestCase` classes, no network, no fixtures of accounts beyond fake `PeerAccount` values):

| Suite | Covers |
|---|---|
| `TVAccountRelationTests` | All 12 matrix rows plus `.unknown` for older builds; hint-only offers (same, other, none); needs sign-in with and without `last`; tag comparison ignores names. |
| `TVAccountCopyTests` | Exact strings for every relation × surface in §5, including device names with apostrophes and long names. |
| `AutoLinkPolicyTests` | Attempts only with a link key, matching hint, not in `lp`, not dismissed or ignored, foreground, no other pairing sheet, once per launch. |
| `CrossAccountChoiceTests` | Remembered per (Link, TV tag, my tag); forgotten when either tag changes or the Link is forgotten. |
| `AccountSwitchHandshakeTests` | idle → confirming → waiting (60 s) → sending → validating → done; declined, timed out, link dropped, validation unavailable, pair refused; credentials never produced before `accepted`; nonce reuse rejected. |
| `LinkEstablishTests` | Credentials requested only for signed-out TVs; fallback for older TVs; P9 digest picks the Allow copy. |
| `PeerAccountWireTests` | Round trip, size cap, signature over every field, freshness, tampered `account` fails, older payloads still verify. |
| `SessionSyncAccountTests` | Extends `remoteWins`: same account newer wins; other account never wins for a signed-in device; empty device adopts newest; tombstone blocks; legacy record migration; P10 write rules. |
| `CompanionRejectionTests` | `observeRejection` resolves only the matching waiter; `sync_refused` resolves none; copy for `track_unavailable`. |
| `DevicePresenceTests` (extend) | A Companion entry on another account is dropped unless it's the Output. |
| `SameAccountLinkTests` (extend) | Nearby rows now carry "Signed in to another account"; same-account candidates unchanged. |

On real devices (main session only, owner's account; a second SoundCloud account must be signed in by the owner himself on one device, agents never type credentials; stop at the first 429): matrix rows 2, 3, 4, 6, 8, 10, 11 and 12 on the Living Room TV with the iPad and the Mac; B1 to B6 confirmed fixed; VoiceOver on the choice dialog and the capsules; TV focus never trapped by the switch alert.

## 10. Open questions for the owner

| # | Question | Recommendation |
|---|---|---|
| Q1 | Same account and same Apple ID: link with **no taps** (capsule "Linked to Living Room"), or keep the one-tap card? Zero taps reverses the recorded rule "nothing pairs silently". | **No taps.** Two independent proofs that it's your device, and no token moves. The card stays for every other case. |
| Q2 | Phone signed out, TV signed in: should the TV be able to sign the phone in over the network (with **Allow** on the TV)? | **No.** Same Apple ID gets **Continue as Sam** from iCloud; everyone else signs in with SoundCloud. A TV handing out the household token is the bigger risk. |
| Q3 | Switching a TV's account: confirm on the phone **and** the TV? | **Both.** It signs someone out, and the TV's alert proves you're in the room. |
| Q4 | Should a TV on another account ever get the proactive nearby card or the "is nearby" notification? | **No.** It's usually someone else's TV (a friend's flat). It shows in Play On's Nearby section, Add Apple TV and Devices. |
| Q5 | A linked TV on another account in the other-devices bar? | **No**, only as an Output with "Signed in as Sam". Matches the bible's privacy rule. |
| Q6 | Settings › Add a Device on a signed-in TV: control-only from now on (never adopts the phone's account)? | **Yes.** Switching goes through 4c only. |
| Q7 | iCloud session records per SoundCloud account, and guest sign-ins never written to the TV owner's iCloud? | **Yes.** Fixes devices flipping accounts. |
| Q8 | After a switch, what happens to the old account's data on the TV? | **The same as Sign Out on the TV, but Links are kept**: downloads, Top Shelf, recents and account settings for Sam are removed. |
| Q9 | Show the account on the TV's success screen ("Signed in as Alex.") and in the flow-2 card ("Sign it in to Sounding as Alex.")? | **Yes.** It's the cheapest way to make the account visible before and after. |
| Q10 | Put the TV's account in the Now Playing bar while it's the Output on another account? | **No.** The bar stays calm; the Output picker row, the first-use choice and every failure name it. |

## 11. Bible edits once approved

- §2 All platforms: a new **TV accounts** bullet (the relation, the first-use choice, "Signed in as Sam" in Play On and Devices, failures never silent) and a change to **Link a nearby Apple TV from Play On** (another-account status and its confirmation).
- §2 Apple TV: the done subtitle "Signed in as Alex.", the two Allow alert texts, the switch alert and "Switching to Alex…", the "connected · Alex" capsule, Remotes & Devices lines.
- §8 Words: "Signed in as <name>", "Signed in to another account", "Switch <TV> to <name>…"; Link may now exist without a sign-in.
- §9 Nearby Apple TV card: auto-link (Q1), the "as Alex" message, no card for another account (Q4); SoundCloud sign-in renewal: per-account iCloud records (Q7).
- `devices-and-auth.md`: §4.2 (`link_establish`), §4.3 (switch path), §4.4b (auto-link), §6 threat model rows for switching and guests, G14 closed.
- §13 decision log: one row per answered question.
