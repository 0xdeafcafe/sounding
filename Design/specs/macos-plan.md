# macOS plan — Sounding for Mac

**Status:** spiked and partially built. The target compiles and links; the
console does not exist yet.
**Date:** 2026-08-03. Xcode 27.0 (27A5228h), macOS 27.0 host.
**Companions:** `ipad-plan.md` (the DJ surface this one must not contradict),
`dj-engine-spec.md` (the engine), `tension-gestures-spec.md` (machine-initiated
gestures), `mu-findings.md` (what `MusicUnderstanding` actually delivers).

---

## 0. The three answers, up front

The brief asked three questions before anything else. Two came back better
than expected and one came back worse.

### 0.1 Can the shared code compile for macOS? — **Yes. Verified.**

Not "yes with a shim layer" — yes, with **one new file and eight edits in two
existing files**, and the macOS target then compiles the *entire* shared core
including `PlayerService` and `MixEngine`.

```
SoundingTV macOS           OK      ← 43 source files, BUILD SUCCEEDED
SoundingTV iOS             OK
SoundingTV-Share           OK
SoundingTV-Widget          OK
SoundingTV                 FAILED  ← Views/Feed/FeedView.swift:66, not ours
SoundingTV-TopShelf        FAILED  ← same single root cause
```

Verified by `xcodebuild` against a copy of the project at
`/tmp/macspike/repo`, all six schemes, `-configuration Debug`.

The two failures are one error in `Views/Feed/FeedView.swift:66:54`
(`contextual closure type '(NavigationState.Tab) -> Void' expects 1 argument,
but 2 were used`) — a file this work never touched, in a directory that was
off-limits, containing zero references to anything changed here. It looks like
`NavigationState.Tab` is not `Equatable`, so `.onChange(of:) { _, tab in }`
resolves to the deprecated one-parameter overload. **Flagging it for whoever
owns the Feed work; it blocks tvOS today.**

The real blocker list, found by compiling rather than reading:

| Blocker | Where | Reality |
|---|---|---|
| `AVAudioSession` | `PlayerService` ×14, `MixEngine` ×1 | **Genuine.** `API_UNAVAILABLE(macos)` — the header ships in AVFAudio on macOS 27 and every member is explicitly unavailable. Verified by compiling: `error: 'AVAudioSession' is unavailable in macOS`, pointing at `AVAudioSession.h:31`. |
| `import UIKit` | `PlayerService`, `ArtworkImage`, `Tokens` | Genuine but shallow. |
| `UIColor` | `Design/Tokens.swift:260`, one line | Genuine — but macOS should not compile `Tokens.swift` anyway (§5.1). |
| `UIApplication.willResignActiveNotification` | `PlayerService` ×1 | Trivial. `NSApplication` posts the identical notification. |
| `AuthenticationService` | tvOS-only | Non-issue — never was in the iOS shared set, isn't in the macOS one. |
| `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` / `MPMediaItemArtwork` | `PlayerService` | **Not a blocker.** All present on macOS. `MPMediaItemArtwork` is polymorphic: the macOS SDK declares `initWithBoundsSize:requestHandler:` taking `NSImage` where iOS takes `UIImage`, so the *call site* needs no change. |
| `UIApplicationDelegate` | `DownloadManager` | **Not a blocker** — it appears only in a comment. |
| Focus APIs | — | Not in the shared set at all; they live in `Views/`, which is tvOS-only. |
| `NWListener`/`NWBrowser`/`NWConnection`, `CryptoKit`, `Security`, `sqlite3`, `CKSyncEngine` | auth + sync + storage | All present. `BonjourAuthClient.swift`, `PhoneSessionStore.swift` and `TokenTransferProtocol.swift` typecheck for macOS **with zero changes**. |

**So macOS is a third member of the existing shared core, not a new seam.**
What it needed was one more seam of the kind already established
(`SoundCloudCredentialSource`, `RemoteOutputTarget`) — see §2.

### 0.2 Does `MusicUnderstanding` exist in the macOS 27 SDK? — **Yes, and it runs. Verified twice.**

This is the answer that matters most and it is unambiguously good.

* **SDK, static:** `MacOSX.sdk/System/Library/Frameworks/MusicUnderstanding.framework`
  exists with a **native `arm64e-apple-macos.swiftinterface`**, module version
  13, declaring `-target arm64e-apple-macos27.0`. Every type is annotated
  `@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)`.
  Full parity: `MusicUnderstandingSession`, both initialisers, `analyze(for:)`,
  all six `AnalysisType`s, all six result types, all five error cases.
* **Runtime, executed:** a compiled probe on this machine analysed a synthetic
  128 BPM track and returned `bpm=128.0, beats=64`. Correct to the decimal.

Practical consequences, and they change the analysis story in the project's
favour:

1. `mu-findings.md`'s hard constraint still holds — `init(asset:)` takes
   **local `file://` only**. That is a framework property, not a platform one.
2. But **the Mac is the machine where that constraint stops hurting.** The
   Tier-B problem ("analysing library candidates you have not played") is
   caused by streams not being local and by mobile analysis budgets. A Mac has
   a disk, mains power, and — via read-only `~/Music` access — a large local
   corpus that is *already* `file://`. The Mac can be the **analysis producer
   for the whole ecosystem**, populating `AnalysisCache` and pushing rows out
   through `AnalysisSync` to devices that could never have computed them.
3. That reframes the sync story from "share what we happen to have" to "one
   machine does the work". See §6.2.

### 0.3 Is "a plugged in CDJ" real? — **No. Not in the sense meant.**

This is the negative, and it is worth stating bluntly because the rest of the
hardware plan follows from it.

**You cannot send audio to a CDJ.** Not "it's hard" — there is no supported
path and no reverse-engineered one either.

* CDJs speak **Pro DJ Link**: proprietary, undocumented, Ethernet/UDP on ports
  50000–50002 and 50004. Everything public is packet-capture reverse
  engineering (`dysentery`, `beat-link`, `crate-digger`, `prolink-connect`),
  and Deep Symmetry state theirs is "in no way a sanctioned implementation".
* `beat-link`'s own README: **"Does not handle audio streaming."**
  `crate-digger`: "does not access audio files themselves — only metadata and
  analysis files."
* The **one** place real audio crosses DJ Link is "Touch Audio" (UDP 50004,
  48 kHz S16LE PCM, CDJ-3000 → DJM mixer) for headphone touch-preview. Wrong
  direction, wrong endpoint.
* The capability does exist — **rekordbox Link Export** loads tracks to a
  player over LAN in real time — but it is rekordbox-proprietary, and Deep
  Symmetry list "posing as rekordbox" as an *unsolved* problem they expect to
  be expensive. Nobody has done it publicly.
* A CDJ otherwise plays from its own rekordbox-formatted SD/USB media. There
  is no slot for a SoundCloud stream.

And independently of the wire problem: **pushing SoundCloud audio into
third-party playback hardware is exactly what this project's entitlement rule
exists to prevent.** Even a working Link Export implementation would be off
the table.

**What CDJs *can* do, and it is a real subset:**

| Capability | Verdict | Notes |
|---|---|---|
| Feed a CDJ audio | **NO** | Above. Not a roadmap item. |
| CDJ as a **USB HID control surface** (CDJ plays nothing; the Mac renders) | **Narrowly yes** | Publicly documented for **CDJ-850 / 900 / 2000 only** (VID `0x08e4`, usage page `0xffa0`), via Mixxx's reverse-engineered mapping. 16-bit signed jog, 16-bit tempo fader, a discrete `jog_touch` bit. **CDJ-2000NXS2 and CDJ-3000 HID is vendor-blessed only** (Serato, Traktor, djay Pro) — undocumented, and those arrived as Pioneer firmware updates under OEM partnerships. |
| Read-only **Pro DJ Link telemetry** (what's playing, BPM, phase, tempo master) | **Yes, with caveats** | Port from `prolink-connect` (MIT — the only clean licence here; `beat-link` is EPL-2.0, `crate-digger` unspecified). Caveats to design in from day one: consumes a device slot; breaks if rekordbox is running; can **crash an XDJ-RX/RX2**; Opus Quad never appears. |
| Official SDK / partner programme | **Does not exist** | AlphaTheta's only developer page covers rekordbox XML playlist import. Nothing else. |

**What actually works, uncomplicated: DDJ-class USB MIDI controllers.**
DDJ-FLX4 and DDJ-400 are confirmed USB audio + MIDI class-compliant, no
driver, on macOS. That is a completely different and far easier proposition,
and it is what this plan builds. **This is the honest answer to the ask: a
"plugged in CDJ" becomes a plugged-in DDJ.**

*Currently attached to this machine:* nothing relevant. `ioreg`/
`system_profiler` show only an Apple Studio Display (8 output channels), two
Apple USB hubs, and the internal keyboard/trackpad. No MIDI sources
(`MIDIGetNumberOfSources() == 0`). Read-only inspection; nothing reconfigured.

---

## 1. What was built

New, and safe to review in isolation:

```
SoundingTV-macOS/
  Info.plist
  SoundingTV-macOS.entitlements
  Sources/
    SoundingMacApp.swift              app shell, seam installation, menu commands
    MacRootView.swift                 window: Status / Hardware / Console panes
    MacAudioSessionCoordinator.swift  CoreAudio half of the audio seam
    MacArtworkCache.swift             NSImage ArtworkCache for Now Playing
    MIDIControllerHub.swift           CoreMIDI discovery + UMP parsing
SoundingTV.swiftpm/Sources/Services/
    AudioSessionCoordinator.swift     the seam itself (shared, all platforms)
tools/
    add-macos-target.rb               target creation, tested against a copy
```

Modified (both editable, both surgical):

* `Services/PlayerService.swift` — eight regions, all in the audio-session
  block. `AudioOutputRoute.outputPortType: AVAudioSession.Port?` became
  `outputKind: AudioOutputKind`; nothing outside the file read it.
* `Services/MixEngine.swift` — the single `AVAudioSession` block in `start()`,
  three lines, replaced by one seam call.

**`project.pbxproj` was not touched.** The target creation is
`tools/add-macos-target.rb`, tested against `cp -R`'d copies. See §2.5.

---

## 2. The audio-session seam

### 2.1 Why a seam and not `#if os(macOS)`

`RemoteOutputTarget`'s header already makes the argument: an inert
implementation you can read and reason about beats code the compiler deleted.
`AudioSessionCoordinating` follows it exactly, and the asymmetry it hides is
real rather than incidental:

* On iOS/tvOS the session is a **negotiation** with a system that can take the
  speaker away — phone calls, route yanks, another app's session priority.
* On macOS there is **no negotiation**. An app that wants to make sound makes
  sound. There are no interruptions. Route changes are a CoreAudio
  default-device property, not a session notification.

So the macOS conformance is mostly *correct no-ops* plus one real device
watcher. The no-ops are behaviour, not stubs.

### 2.2 Shape

```swift
enum AudioOutputKind { case builtIn, headphones, bluetooth, airPlay, hdmi, usb, unknown }

@MainActor protocol AudioSessionCoordinating: AnyObject {
    func activatePlayback()
    var outputName: String? { get }
    var outputKind: AudioOutputKind { get }
    var maximumOutputChannels: Int { get }
    var supportsMultichannel: Bool { get }
    func refreshRoute()
}

extension AudioSessionCoordinating {
    var isAirPlayRoute: Bool          { outputKind == .airPlay }
    var supportsSeparateCueBus: Bool  { maximumOutputChannels >= 4 }
}

extension Notification.Name {
    static let audioOutputRouteDidChange = …
}

@MainActor enum PlatformAudioSession {
    static var coordinator: (any AudioSessionCoordinating)? = /* platform default */
}
```

Three decisions worth defending:

1. **`PlatformAudioSession.coordinator` defaults to the right thing** rather
   than requiring installation, unlike the other two seams. Those genuinely
   have no sensible default (only the app knows who holds the token; "somewhere
   else to play" is legitimately nothing). This one does — and forgetting to
   install it would silently drop the `.longFormAudio` route-sharing policy,
   an AirPlay 2 regression nobody would trace back to a missing line in an app
   entry point. macOS overrides the nil default in `SoundingMacApp.init`,
   because its coordinator also starts a CoreAudio property listener, which is
   a side effect rather than a construction.
2. **`activatePlayback()` is one method both callers use.** `MixEngine.start()`
   previously re-set the category itself, with an eight-line comment explaining
   that it must pass `policy:` or it would downgrade what `PlayerService`
   established. That correctness now holds by construction instead of by two
   comments agreeing with each other.
3. **The route-change notification carries the original as its `object`.**
   `PlayerService` needs `AVAudioSessionRouteChangeReasonKey` to distinguish a
   device *disappearing* (pause) from a route *upgrade* (do nothing). Dropping
   the reason would make plugging headphones back in stop the music.

### 2.3 What is deliberately still `#if`

Two things, both with the reason in the code:

* **Interruptions.** There is no macOS behaviour to abstract over. A seam whose
  macOS half is "this never happens" is worse than an honest `#if`.
* **`willResignActiveNotification`.** Same notification, same semantics,
  different framework prefix. A name swap, not a seam.

### 2.4 Follow-up that would tidy this

`ArtworkVariant` and `URL.soundCloudArtworkVariant(_:)` are ~20 lines of pure
string manipulation currently trapped inside the UIKit-shaped
`Views/Components/ArtworkImage.swift`, so `MacArtworkCache.swift` duplicates
them. **Moving them to a shared `Services/ArtworkVariant.swift` removes the
duplication.** Not done here because `Views/` was off-limits. The candidate
lists (`["t500x500", "large"]`, `["original", "t500x500", "large"]`) are the
wire contract with SoundCloud's CDN — the two copies must track each other
until this is fixed.

### 2.5 The target script

`tools/add-macos-target.rb`, idempotent, safe to re-run.

Two things it does that a hand-written version got wrong first:

**Group resolution is by resolved absolute directory, not `find_subpath`.**
This project's group tree does not mirror its directory tree — *two* different
groups report `hierarchy_path == "/Sources"` (one is
`SoundingTV-AppClip/Sources`, the other `SoundingTV.swiftpm/Sources`). So
`find_subpath("SoundingTV.swiftpm/Sources/Services", true)` does not find the
existing group; it silently creates a new chain off the root and every file
lands at the repo root. That produced "Build input files cannot be found" for
33 files at once on the first run. Matching on `real_path` is unambiguous.
Reference paths are still basenames and no group's `source_tree` is touched.

**Shared membership is derived from the iOS target, not listed.** The first
version hard-coded 33 filenames and broke within the hour when another agent
added `Models/FeedActivity.swift` — surfacing as `cannot find type
'FeedActivity' in scope`, which points nowhere near the list. The rule is now
stated once, positively: *macOS compiles whatever iOS compiles from
`SoundingTV.swiftpm/Sources`, minus an explicit exclusion list with a reason
per entry.* Current exclusions:

| Excluded | Reason |
|---|---|
| `Views/Components/ArtworkImage.swift` | UIKit view + UIImage cache; macOS has `MacArtworkCache.swift` |
| `Views/Components/AnalysisLookup.swift` | SwiftUI helper for the iOS surface |
| `Design/Tokens.swift` | `UIColor` — and macOS must not silently fork the design tokens (§5.1) |

The script **also adds `AudioSessionCoordinator.swift` to the `SoundingTV` and
`SoundingTV iOS` targets**, because `PlayerService` and `MixEngine` now call
through it — the two changes are not independently applicable.

---

## 3. Hardware

### 3.1 Scope, stated once

**In:** USB MIDI controllers. **Out:** CDJs as audio sinks. **Later, maybe:**
read-only Pro DJ Link telemetry; CDJ-850/900/2000 HID.

The UI says this out loud. `MacRootView`'s Hardware pane carries the CDJ
sentence permanently, in the same spirit as `ipad-plan.md` §2's rule about the
headphone-cue situation: *"Say which of these you are in, in the UI,
permanently."* A user who owns CDJs should learn this from the app in ten
seconds, not from a support thread.

### 3.2 `MIDIControllerHub` — built

Now `DJControllerHub` in `Core/DJControllers`, behind `DeckControlSurface`, and limited to the user's own music. `Design/specs/dj-controllers.md` is current; the notes below are history.

`MIDIClientCreateWithBlock` + `MIDIInputPortCreateWithProtocol(._1_0)`. The
modern pairing: the deprecated `MIDIInputPortCreate` read-proc gives
`MIDIPacketList` rather than UMP.

Verified on this machine (unsandboxed CLI probe, macOS 27):

```
MIDIClientCreateWithBlock status=0        ← noErr, no prompt
MIDIInputPortCreateWithProtocol status=0
MIDI sources visible = 0                   ← no hardware attached
```

**There is no MIDI privacy prompt on macOS.** `NSMIDIUsageDescription` does
not exist in Apple's property-list index, CoreMIDI exposes no authorization
API, and the sandbox device-access family is exactly `{audio-input, camera,
microphone, usb, print, bluetooth, smartcard}`. The likely source of the
contrary intuition is **Bluetooth** MIDI, which does need
`NSBluetoothAlwaysUsageDescription`. This app is USB-only and asks for neither.

The entitlements still declare `com.apple.security.device.usb` — the probe was
unsandboxed, the key is documented as covering "USB device access APIs"
generally, and it costs nothing.

Threading: the notify block and the receive block both run on CoreMIDI's own
high-priority thread. Both hop to `@MainActor` before touching state. Doing
real work on the MIDI thread is how you drop events under a jog wheel sending
thousands of messages a second. `MIDIClientRef`/`MIDIPortRef` are held
`nonisolated(unsafe)` so `deinit` can dispose them without crossing an actor
boundary — the pattern `BonjourAuthServer`/`BonjourAuthClient` already use.

### 3.3 `ControlEvent` — why the console never sees raw MIDI

```swift
enum ControlEvent { case absolute(ControlID, Double)
                    case relative(ControlID, Double)
                    case button(ControlID, isDown: Bool, velocity: Double)
                    case touch(ControlID, isTouching: Bool) }
```

Two reasons. Vendors disagree about everything, so a mapping layer is
unavoidable. And a keyboard, a trackpad and a controller should all drive the
same console verb — which they can only do if the verb is in the console's
vocabulary, not the hardware's. `ControlID.Surface` deliberately reuses
`ipad-plan.md`'s region names (`jog`, `tempo`, `lineFader`, `crossfader`,
`trim`, `eqHigh/Mid/Low`, `filter`, `hotCue`, …).

`.touch` is a separate case because it is load-bearing: on a DDJ-400 platter
touch is a **Note** message (`0x90/0x91`, note `0x36`) independent of rotation,
and touch is what decides *scrub vs pitch-bend* — precisely the distinction the
iPad console draws between platter face and outer ring.

### 3.4 Mapping — editor first, bundled mappings second

`MappingLibrary` is deliberately empty. Hand-writing mappings for hardware
nobody here owns is the wrong first move; the **mapping editor** driven by
`rawMessages` is what makes *any* controller work, including ones that do not
exist yet. Bundled mappings are a convenience on top, not a prerequisite.

Concrete jog facts to build against, from the DDJ-400 mapping — 7-bit relative
CC centred on 64, a **different CC per behaviour** rather than one CC plus a
modifier:

| Behaviour | Status | CC |
|---|---|---|
| Platter rotate, vinyl ON (scratch) | `0xB0/0xB1` | `0x22` |
| Platter rotate, vinyl OFF (bend) | `0xB0/0xB1` | `0x23` |
| Jog side rotate (bend) | `0xB0/0xB1` | `0x21` |
| Platter rotate + SHIFT (search) | `0xB0/0xB1` | `0x29` |
| Platter touch on/off | `0x90/0x91` (Note) | `0x36` |

Mixxx assumes **720 ticks/revolution** with alpha-beta filtering
(`alpha = 1/8`, `beta = alpha/32`). Note the ceiling: this is **7-bit, not
14-bit**. Fine for bend; adequate for scratch only because of the filter.

**Licence discipline:** Mixxx is **GPL**. Use its XML as *documentation of the
hardware* and reimplement the behaviour. Do not copy its JavaScript. Traktor
TSI is a proprietary undocumented binary with only thin community RE — not a
standard, not worth adopting. **Define our own JSON mapping format**, and
optionally write a one-way Mixxx-XML importer to bootstrap device coverage.

### 3.5 Entitlements

| Key | Why |
|---|---|
| `app-sandbox` | On. |
| `device.usb` | CoreMIDI belt-and-braces (§3.2). |
| `network.client` | api-v2, streams, CloudKit. |
| `network.server` + `device.bonjour` (`_soundingtv._tcp`) | Bonjour needs both inside the sandbox; service type must match the other two apps exactly. |
| `assets.music.read-only` | `~/Music` is **scanned and analysed, never modified, moved, renamed or re-tagged.** |
| `associated-domains` | `applinks:sounding.forbes.red`, same as iOS. |
| `keychain-access-groups` | Same two groups as iOS, so `PhoneSessionStore`'s item is *the same item* (§4). |
| `icloud-container-identifiers` + `icloud-services` | `CKSyncEngine` private DB for analysis + cues. |

`device.audio-input` is present (with `NSMicrophoneUsageDescription`) only so
"Add Apple TV" can hear the TV's sign-in chime; see `chime-signin.md`.
Deliberately absent: anything DriverKit. **DriverKit is not needed**: `IOHIDManager` reaches a CDJ's
HID interface without it. DriverKit entitlements are Apple-granted per team and
would only matter for a custom audio-class driver, which this is not.

### 3.6 Multi-channel output — the cue bus

`AVAudioEngine` has **no first-class arbitrary channel-routing API**. The
route is `kAudioOutputUnitProperty_ChannelMap` on the engine's underlying AUHAL
output unit, plus `kAudioOutputUnitProperty_CurrentDevice` to pick the
interface. The map is an array of `SInt32` with **one element per destination
channel**, each holding a source index or `-1`.

`MacAudioSessionCoordinator` already reports
`maximumOutputChannels` off the real device via
`kAudioDevicePropertyStreamConfiguration` (this machine: 8 on the Studio
Display, 2 on built-in speakers). `supportsSeparateCueBus` is that `>= 4`.
**Master → 1/2, cue → 3/4** is therefore mechanically available on a Mac —
which makes the Mac the first platform in this project where a real headphone
cue is possible at all.

One constraint carries over from `dj-engine-spec.md` and must not be
forgotten: `MixEngine` deliberately never calls
`setPreferredOutputNumberOfChannels`, because negotiating discrete multichannel
with only front L/R populated suppresses the receiver's own upmix. A cue bus
means deliberately opting into a wider device — **for the interface case only**,
never as a global setting.

---

## 4. Auth sync — what it can and cannot mean

### 4.1 The constraint, restated

Per-device OAuth is **blocked**: it needs a `client_id` with a custom-scheme
`redirect_uri` this project does not have. Devices cannot hold independent,
independently-refreshable tokens. **"Sync auth" therefore means sharing one
token.** There is no version of this where the Mac gets its own.

Given that, the question is only *how the one token reaches the Mac*, and the
answer changes the blast radius.

### 4.2 Option A — extend the existing Bonjour handoff. **Recommended.**

`BonjourAuthClient.swift`, `PhoneSessionStore.swift` and
`TokenTransferProtocol.swift` **compile for macOS unchanged** (verified). The
Mac becomes a third participant in the mechanism that already exists: HMAC-
SHA256-signed `TokenTransferMessage` over `_soundingtv._tcp`, 5-minute session
timeout, shared secret out-of-band.

Properties:

* **No new trust surface.** The wire protocol, the signing, the timeout and the
  threat model are the ones already reviewed. Nothing weakens.
* **The token only ever crosses the local network**, to a device the user
  physically operated within a 5-minute window.
* **Revocation is comprehensible**: "sign out on the Mac" deletes one keychain
  item on one machine.
* Costs a pairing gesture per device. That is a feature — it is the moment the
  user consents.

Direction: today tvOS is the pairing *host* and the phone is the client. For
the Mac, **the Mac should be a client too** — a Mac has a keyboard and a
browser, so it can equally well run the `WKWebView` login itself and *become a
source*. Both directions reuse the same code. Ship "sign in on the Mac
directly" first; it is simpler than pairing and needs no second device.

### 4.3 Option B — iCloud Keychain via `kSecAttrSynchronizable`. **Not recommended.**

`PhoneSessionStore` currently writes with
`kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock` and **no**
`kSecAttrSynchronizable`. Adding `kSecAttrSynchronizable: true` would make the
token appear on every device signed into the same iCloud account,
automatically.

Why not:

1. **It puts the token on devices the user never paired**, including future
   ones and ones that are lost/stolen but still in the iCloud account. The
   Bonjour path requires a deliberate act per device; this requires none.
2. **It widens the blast radius of an iCloud compromise** from "Apple data" to
   "SoundCloud session". A single token shared by N devices, replicated by a
   service outside this project's control, is a materially different risk than
   the same token hand-carried to N devices.
3. **Revocation becomes fuzzy.** Deleting a synchronizable item propagates,
   but propagation is best-effort and eventually-consistent. "I signed out"
   stops meaning "it is gone".
4. **It does not solve the actual problem.** With one shared token, a 401
   invalidates the session *everywhere*, sync or no sync. iCloud Keychain makes
   distribution automatic; it does not make the session more robust.
5. `kSecAttrAccessibleAfterFirstUnlock` is compatible with synchronizable, so
   nothing stops this technically. That is precisely why it needs a decision
   rather than a default.

**Verdict: do not weaken the existing auth model to make sync convenient.**
Keep `kSecAttrSynchronizable` off. If it is ever turned on, it must be an
explicit, off-by-default user setting with the consequence stated plainly, not
a silent behaviour.

### 4.4 Non-negotiable

Never log a token, cookie, secret, nonce or signature. The existing code is
careful about this (`CueStore`'s and `AnalysisSync`'s log headers both note
what their logs may and may not carry); the Mac must stay careful. Nothing in
`MacRootView` or `MacSettingsView` prints or displays a token — the Status pane
shows "Session found" / "Not signed in" and the username, nothing more.

---

## 5. The Mac as an instrument

### 5.1 Design tokens — do not fork silently

`ipad-plan.md` §1.6 sets the rule and it applies with more force here: the tvOS
and iOS token sets **already disagree** (`Spacing.md` 16 vs 14, `CornerRadius`
vs `Radius`, different `scAccent`). A third silent fork is how a Mac control
ends up 2 pt off its iPad twin for a year.

So: **`Design/Tokens.swift` is excluded from the macOS target**, and the macOS
UI uses system semantic colours and spacing until a deliberate `MacTokens.swift`
exists. That file, when written, should be derived from the *iPad* console's
values, not tvOS's — the Mac and iPad consoles are the same instrument at
different input resolutions.

### 5.2 What a Mac changes about the console

`ipad-plan.md` designs the surface; this section only records the deltas. A
Mac has a pointer, a keyboard, a large non-touch screen, and no haptics at all.

| Dimension | iPad | Mac |
|---|---|---|
| Simultaneity | Ten fingers; `TouchRouter` exists to arbitrate | **One pointer.** The whole `TouchRouter`/`ControlBinding` multitouch architecture is *unnecessary* — and cannot substitute for hands. Simultaneous moves come from **hardware** or from **automation**, not from the mouse. |
| Fine mode | Second finger within 120 pt | **⌥ + drag / ⌥ + scroll** (the Logic/Ableton convention `ipad-plan.md` §1.5 already names) |
| Detents | "Resistive value mapping" at 0.25× finger speed, because no haptics | Same technique, same detent positions. A Mac has no haptics either (Force Touch trackpads aside, and a DJ is not on a trackpad). **Keep the visual detent verbatim.** |
| Scrub / zoom | One finger vs two in a waveform lane | Scroll = scrub; ⌘-scroll or pinch = zoom; ⌥-scroll = fine |
| Jog | 340 pt platter, palm-brake at `majorRadius > 18 pt` | **There is no good mouse jog.** Do not draw a big platter and pretend. Draw a *small* one as a readout, and put jog on the keyboard (nudge) and on hardware (real platter). |
| Screen | 1376 × 1032 fixed, no scroll, landscape-only | Resizable. **The no-scroll rule still holds** — it exists because scrolling competes with dragging, which is just as true with a mouse. Use `ipad-plan.md`'s width ladder (≥1180 / 900–1179 / <900) against window width, and set a `minWidth` that keeps the two-deck layout legal. |
| Second screen | v3, needs scene manifest work | **Free on macOS.** A second `WindowGroup` (library/browser on one display, decks on the other) is ordinary AppKit/SwiftUI. This is a genuine Mac advantage worth taking early. |
| Menu bar | Argued *against* `keyboardShortcut` | **Inverts.** See below. |

### 5.3 The keyboard, and the one place the iPad plan's reasoning flips

`ipad-plan.md` §1.5 says: use one big `onKeyPress` on the console root, **not**
`keyboardShortcut` on forty hidden buttons — because on iOS `keyboardShortcut`
publishes into a menu system that barely exists, steals keys from text fields,
and gives no key-up.

Two of those three still bite on macOS. But the first inverts completely: the
Mac menu bar is real, discoverable, and searchable from Help. A DJ app that
hides its entire key map from it is worse for it.

**The split that resolves it:**

* **Menu bar (`keyboardShortcut`):** transport and navigation. Play/Pause,
  Next/Previous, Open Console, Settings. Things that are fine on key-*up*, fine
  with a menu round-trip, and that a new user should be able to *find*.
* **`onKeyPress` on the console root:** every performance key. Hot cues, cue
  (momentary — `Q`/`P` must be press-and-hold), nudge, tempo, crossfader snap,
  loop. These need key-down latency and key-*up* reporting, and neither is
  available through `keyboardShortcut`.

The full key map in `ipad-plan.md` §1.5 (`Q`/`P` cue, `W`/`O` play, `1`–`4` /
`7`–`0` hot cues, `Z`/`C`/`X` crossfader, `[` `]` `;` `'` nudge, `-` `=` `,`
`.` tempo, `9` `0` loop, `K` key-lock, `Space`, `Tab`, `⇧` = fine) transfers
**verbatim**. Do not invent a second map.

### 5.4 Deck count, waveforms, cues — all inherited unchanged

Two decks (`Deck.a`/`Deck.b`, bus-pinned). Three waveform surfaces (overview /
mirrored detail-beatgrid / phase meter), tiled rendering at 2048 px with ±3
tiles resident, 20 Hz playhead sampling extrapolated to display rate. Eight hot
cue pads per deck backed by the **real** `CueStore` actor (not
`ipad-plan.md`'s stale `CuePointStore` name). Tempo stored as a **rate ratio**,
BPM derived for display only. `TEMPO` not `SYNC` in v1. Master limiter at
−1.0 dBTP in v1.

All of that is `ipad-plan.md`'s work and none of it changes on a Mac.

### 5.5 A Mac-only capability worth designing for

Because a Mac can run analysis on a large local corpus (§0.2), the Mac console
can offer something no other platform can: **planning against a fully-analysed
library**. `DJProfile.lookaheadCandidates` is 1 for Wedding and 24 for Junkie
precisely because candidate analysis is expensive on mobile. On a Mac with a
warm `AnalysisCache`, that ceiling is a policy choice rather than a physical
limit. Do not change the profile constants — but do note that a Mac is where a
"deep look-ahead" profile would actually be honest.

---

## 6. Ecosystem sync

### 6.1 Nothing new needs designing

`AnalysisSync.swift` is already the decision half only, with two protocols
underneath it:

```swift
protocol AnalysisSyncTransport: Sendable {
    var transportId: String { get }
    func isReady() async -> Bool
    func offer(_ records: [AnalysisSyncRecord]) async throws
    func fetch(since cursor: AnalysisSyncCursor?) async throws -> (records: [AnalysisSyncRecord], cursor: AnalysisSyncCursor?)
}
protocol AnalysisSyncStore: Sendable { … }
```

and its header already names the two intended transports — Bonjour over the
existing `_soundingtv._tcp` channel, and CloudKit over `CKSyncEngine` against
the **private** database. `CueStore` is shaped to ride the identical mechanism
(`CueSyncRecord`, `CueSyncPolicy.remoteWins`, `syncRecords(changedSince:)`,
`adopt(_:)`, soft deletes so deletions survive a round trip).

**The Mac's job is to implement a transport, not to design a sync system.**
Extend, do not reinvent.

Both compile for macOS today (they are in the verified 43-file target). Both
are pure Foundation + SQLite.

### 6.2 What the Mac uniquely contributes

* **Analysis.** Per §0.2, the Mac is the only device that can analyse a large
  local corpus. It should be the ecosystem's analysis producer, pushing rows
  the TV and phone could never have computed.
  **Caveat: `AnalysisCache` has no producer yet** — that work is in flight
  elsewhere. Nothing here should be designed around data that does not exist.
  `AnalysisProducers.swift` exists; whether it is wired is not this plan's
  claim to make.
* **Cue points.** Already fully sync-shaped, already backed to
  `Application Support/CuePoints/cues.sqlite3`, deliberately *not*
  backup-excluded. Nothing to add.
* **Downloads.** `DownloadManager` compiles for macOS. Note that its background
  `URLSession` hookup comment names `UIApplicationDelegate`; the macOS
  equivalent is `NSApplicationDelegate`'s
  `application(_:handleEventsForBackgroundURLSession:)`, and neither app has an
  app delegate today. Unchanged problem, one more platform.
* **Entitlement.** Unchanged and non-negotiable on every transport: an
  unentitled track has empty `transcodings` and nil `streamURL` by
  construction. Nothing may unlock previews, bypass the check or strip ads —
  **including for content moved between the user's own devices.** Analysis rows
  and cue points are *metadata about* tracks and carry no audio; that is why
  they may sync at all.

### 6.3 Direction of travel

The Mac should also be a `RemoteOutputTarget` **client** — able to drive the
TV, and to accept playback handed to it. `RemoteQueueClient` lives in
`SoundingTV-iOS/Sources/` and is not in the macOS target yet;
`PlayerService.remoteOutput` stays nil on macOS today, which is a working
no-op rather than a half-connection. Adding it is target membership plus
whatever `RemoteQueueClient` assumes about `PhonePlaybackCoordinator`. Not
attempted here.

---

## 7. Order of work

| # | Item | Size | Notes |
|---|---|---|---|
| 1 | Apply `tools/add-macos-target.rb` to the real project | S | Needs a quiet tree. Verified against copies. |
| 2 | Fix `Views/Feed/FeedView.swift:66` | XS | **Blocks tvOS today**, unrelated to this work. |
| 3 | Move `ArtworkVariant` + `soundCloudArtworkVariant` to a shared file | XS | Removes the `MacArtworkCache` duplication (§2.4). |
| 4 | `MacTokens.swift`, derived from the iPad console values | S | Before any console UI, not after. |
| 5 | Library browsing + local playback UI | M | The Mac is a music app before it is a DJ app. |
| 6 | Mapping editor driven by `MIDIControllerHub.rawMessages` | M | Makes *any* controller work; precedes bundled mappings. |
| 7 | Cue bus via AUHAL channel map | M | §3.6. The first real headphone cue in this project. |
| 8 | The console, per `ipad-plan.md` + §5 deltas | **L** | ~3,000 lines on the iPad estimate; the Mac shares most of it. |
| 9 | `AnalysisSyncTransport` over Bonjour | M | Extend, don't reinvent (§6.1). |
| 10 | Second-window support (library on one display, decks on the other) | S–M | Cheap on macOS, v3 on iPad. |
| — | Read-only Pro DJ Link telemetry | L | Only if a real user asks. Port from `prolink-connect` (MIT). |
| — | CDJ HID (850/900/2000 only) | L | Low ROI. Genuinely narrow. |
| — | **Feeding audio to a CDJ** | — | **Not on the roadmap. Not possible.** |

---

## 8. Verification log

Everything marked *verified* above was produced by one of these.

| Claim | Method | Result |
|---|---|---|
| `AVAudioSession` unavailable on macOS | `swiftc -typecheck -target arm64-apple-macos27.0` on a probe | `error: 'AVAudioSession' is unavailable in macOS`, note at `AVAudioSession.h:32` |
| MediaPlayer / AVAudioEngine / AVAudioUnitTimePitch / AVAudioUnitEQ / `allowedAudioSpatializationFormats` / NWListener / NWBrowser / NWConnection / `CKSyncEngine` all available on macOS | same probe | compiles clean |
| `MusicUnderstanding` in the macOS 27 SDK | `MacOSX.sdk/…/MusicUnderstanding.framework` + `arm64e-apple-macos.swiftinterface` read in full | present, full API parity, `macOS 27.0` availability |
| `MusicUnderstanding` **runs** on macOS | compiled probe against a synthetic 128 BPM WAV | `bpm=128.0 beats=64` |
| CoreMIDI needs no entitlement or prompt | compiled probe | `MIDIClientCreateWithBlock status=0`, `MIDIInputPortCreateWithProtocol status=0`, no prompt |
| CoreAudio device/channel reads | compiled probe | `MacBook Pro Speakers`, 2 channels; Studio Display reports 8 |
| Auth stack compiles for macOS unchanged | `swiftc -typecheck` over `BonjourAuthClient` + `PhoneSessionStore` + `TokenTransferProtocol` | zero errors |
| macOS target builds | `xcodebuild … -scheme 'SoundingTV macOS' -destination 'platform=macOS,arch=arm64'` against a project copy | **BUILD SUCCEEDED**, 43 files |
| Existing targets not broken | all six schemes against the same copy | 4 OK; 2 fail on one pre-existing `FeedView.swift` error |
| No DJ hardware attached | `ioreg -p IOUSB`, `ioreg -c IOHIDDevice`, `system_profiler SPAudioDataType` | Studio Display, 2 Apple hubs, internal keyboard/trackpad. Read-only. |
| CDJ / Pro DJ Link / DDJ findings | web research, sourced in §0.3 | see the source list in the research notes |
