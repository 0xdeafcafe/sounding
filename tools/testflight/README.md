# TestFlight distribution

Covers tvOS, iOS, iPadOS, watchOS, and macOS. The watch app ships **inside** the iOS app
(it is embedded via the "Embed Watch Content" phase), so uploading the iOS build
delivers the watch app too — there is no separate watchOS upload.

| Platform | Scheme | Bundle ID | Ships via |
|---|---|---|---|
| tvOS | `SoundingTV` | `red.forbes.sounding` | its own archive |
| iOS + iPadOS | `SoundingTV iOS` | `red.forbes.sounding` | its own archive |
| watchOS | `SoundingTV watchOS` | `red.forbes.sounding.watchkitapp` | embedded in the iOS archive |
| macOS | `SoundingTV macOS` | `red.forbes.sounding` | its own archive |

---

## 1. One-time: register identifiers

At <https://developer.apple.com/account/resources/identifiers>.

**App IDs**

`red.forbes.sounding` is shared by the tvOS, iOS and macOS apps, so it is a
single App ID and needs the **union** of their capabilities:

- App Groups → `group.red.forbes.sounding`
- iCloud → CloudKit, container `iCloud.red.forbes.sounding`
- Associated Domains
- Keychain Sharing

Then the extension/companion App IDs:

| Identifier | Capabilities |
|---|---|
| `red.forbes.sounding.watchkitapp` | Keychain Sharing |
| `red.forbes.sounding.Widget` | Keychain Sharing |
| `red.forbes.sounding.Share` | Keychain Sharing |
| `red.forbes.sounding.TopShelf` | App Groups |

**Also create**

- App Group `group.red.forbes.sounding`
- iCloud container `iCloud.red.forbes.sounding`

**ShazamKit** is not an entitlement — enable it under *App Services* on the
`red.forbes.sounding` App ID. A provisioning profile dump will not tell you
whether it is on.

**Associated domains** requires an `apple-app-site-association` file served from
`https://sounding.forbes.red/.well-known/apple-app-site-association`.

## 2. One-time: create the App Store Connect record

At <https://appstoreconnect.apple.com> → Apps → **+**.

Because tvOS, iOS, and macOS share `red.forbes.sounding`, create **one** app
record and add the **iOS**, **tvOS**, and **macOS** platforms. Adding iOS
automatically covers iPadOS and the embedded watchOS app.

You will need: a name, primary language, the bundle ID, and an SKU.

## 3. One-time: App Store Connect API key

Users and Access → **Integrations** → App Store Connect API → **+**.
Give it the **App Manager** role.

Download the `.p8` once (it cannot be re-downloaded) and put it at:

```
~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
```

Then export the identifiers — put these in your shell profile, not in the repo:

```sh
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

## 4. Ship a build

```sh
./tools/testflight/release.sh tvos     # tvOS only
./tools/testflight/release.sh ios      # iOS + iPadOS + watchOS
./tools/testflight/release.sh macos    # macOS only
./tools/testflight/release.sh all      # every platform
```

The build number defaults to the git commit count, which is monotonic on a
linear history. Override either value when you need to:

```sh
BUILD_NUMBER=42 VERSION=1.1 ./tools/testflight/release.sh all
```

To produce an `.ipa` without uploading (no API key needed):

```sh
SKIP_UPLOAD=1 ./tools/testflight/release.sh ios
```

To run the cheap App Store Connect acceptance test without shipping anything:

```sh
VALIDATE_ONLY=1 ./tools/testflight/release.sh all
```

That creates signed archives, exports each platform package, and runs
`altool --validate-app`, but does not upload a build.

Builds appear in App Store Connect 5–30 minutes after upload.

Every archive is built with `SOUNDING_EXPORT_METHOD=app-store-connect`, which the
macOS target's Personal Build Guard rejects if `SOUNDING_PERSONAL` is set. The
archive and the exported package are then scanned by
`tools/personal/check-no-personal-marker.sh`; any personal-build marker aborts the
upload. The personal Mac build is `tools/personal/build-personal.sh` and never goes
through this script.

## 5. One-time: TestFlight setup

In App Store Connect → your app → **TestFlight**:

- **Test Information** — fill in feedback email, and "What to Test". This is
  required once before external testing.
- **Internal Testing** — add up to 100 members of your team; no review needed,
  builds are available as soon as they finish processing.
- **External Testing** — up to 10,000 testers via a public link. The first build
  in a group needs Beta App Review (usually under 24h).

Export compliance is already declared in the Info.plists
(`ITSAppUsesNonExemptEncryption = false`), so builds will not stall asking about
encryption. See the note in the repo discussion — the app uses CryptoKit only
for authentication (HMAC/HKDF in device pairing) and HTTPS, which is exempt.
Confirm that is still true if you add cryptography.
