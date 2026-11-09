# Sounding 1.0: release checklist

State on 2026-11-08. Nothing has been submitted for review. All three 1.0 versions (iOS, tvOS, macOS) are in Prepare for Submission. Release type is After Approval on all three (consider Manual for a first release).

Re-apply the text at any time with `tools/appstore/apply_metadata.py --apply` (needs `ASC_KEY_ID` and `ASC_ISSUER_ID` and the `.p8` key). Without `--apply` it only checks lengths and banned words.

## Done (through the API)

- [x] App name `Sounding`, subtitle `Long sets, two decks, no ads`, privacy policy URL `https://sounding.forbes.red/privacy/` (en-GB, the app's primary locale).
- [x] Categories: Music, then Entertainment.
- [x] Age rating questionnaire answered (`metadata.md` §6). ASC computed 12+.
- [x] Version text for iOS, tvOS and macOS (en-GB): description, promotional text, keywords, support URL `https://sounding.forbes.red/support/`, marketing URL `https://sounding.forbes.red/`.
- [x] Copyright `2026 Alexander Forbes-Reed` on all three versions.
- [x] App Review notes on all three versions (`metadata.md` §9). Contact name, phone and email copied from the TestFlight Beta App Review contact already in ASC. "Sign-in required" is on.
- [x] Builds attached: tvOS 1.0 (776), macOS 1.0 (776). Both VALID, `usesNonExemptEncryption = false`.
- [x] Export compliance: nothing else to file (`metadata.md` §8).
- [ ] What's New: ASC locks this field on a first version, so it's left empty. The welcome text is in `metadata.md` for 1.0.1.

## Owner actions, in order

1. **iOS build.** The iOS 1.0 version still points at build 3 (May, expired, and it had an App Clip). Build 788 can't be attached because the version has an App Clip default experience and 788 has no App Clip. In ASC, iOS App, 1.0, scroll to App Clip and remove it (I don't delete things), then pick build 788 (or newer) under Build.
2. **Demo account.** Create a SoundCloud account on Go+ (so playback, Go+ tracks and the decks can all be reviewed), with a few likes and playlists, and no two-factor prompt at sign-in. Enter it under App Review Information, Sign-in information, on all three versions. Your own account can't be used.
3. **Review contact.** Check the copied name, phone and email on each version's App Review Information.
4. **App Privacy.** Click through `app-privacy.md` in General, App Privacy, then Publish. Decide the tracking answer for promoted-post pixels (recommendation in that file: No).
5. **Privacy policy line.** Add the promoted-posts sentence from `app-privacy.md` to `docs/privacy/index.html` (docs-only commit to `main`), so the policy matches the label.
6. **Privacy manifest.** No target has a `PrivacyInfo.xcprivacy`. Apple requires one declaring required-reason APIs (UserDefaults, file timestamps, disk space, system boot time) and flags missing ones at review. Add one to each app and extension target (engineering task, hand-edited pbxproj), then upload a new build and re-attach.
7. **Content rights.** App Information, Content Rights: Sounding shows third-party content (SoundCloud's). Answer it yourself, it's a legal statement.
8. **Price and availability.** Check it's Free in the territories you want. Not touched.
9. **CloudKit.** In the CloudKit Console, `iCloud.red.forbes.sounding`, deploy the Development schema to Production. Record types: `Cue`, `CueDismissal`, `AnalysisRow`, `SoundCloudSession`, `DownloadManifestEntry`, `SetlistSnapshot`, `CompanionDevice`, `SettingsEntry`, `SignInRequest` (`Design/cloudkit/SignInRequest.ckdb`), `AccountSignIn` (fields in `Design/cloudkit/AccountSignIn.ckdb`), `NearbyLinkRequest` and `NearbyLinkSnooze` (`Design/cloudkit/NearbyLinkRequest.ckdb`), `LibraryChunk` and `LinkOwnerKey` (`Design/cloudkit/LinkOwnerKey.ckdb`); the zones are created by the app at runtime. App Store builds use Production, so without this sync fails silently for everyone. Without `LinkOwnerKey` in Production, linking your own devices still works but asks for the code and **Allow**. The subscriptions (`signin-requests-v2`, `signin-requests-gone-v2`, `account-signins-v2`, `nearby-link-requests-v1`, `nearby-link-requests-gone-v1`) are saved by the apps and need no deploy, but they can only be saved once their record type exists in that environment; each app checks them against iCloud after every new build and once a day, and deletes the old `-v1` sign-in ones. A record type that no Debug build has saved yet isn't in Development either: import its `.ckdb` fragment into Development first (as in `Design/specs/library-db.md`), then deploy. Push Notifications must stay enabled on the `red.forbes.sounding` App ID: the Mac app now carries `com.apple.developer.aps-environment` too.
10. **Screenshots.** Uploaded by the appstore-shots agent. Check every platform shows no red warnings (iPhone 6.9", iPad 13", Apple Watch, Apple TV, Mac).
11. **Release type.** Consider "Manually release this version" so you choose the day.
12. **Read the listing once in ASC.** The copy is in `metadata.md`.
13. **Submit.** Add for Review on iOS, tvOS and macOS (one submission can carry all three), then Submit. That button is yours.

## Review risks

- **5.2.2 (third-party services).** An unofficial SoundCloud client. The listing names SoundCloud only factually and says it isn't affiliated. Apple may ask for permission from SoundCloud. Sounding uses SoundCloud's web endpoints, not a registered public-API app.
- **3.1.1 / 3.1.3 (payments).** Playback needs a paid SoundCloud plan, and the app links out to SoundCloud's plans page. It's a reader-style external subscription Sounding doesn't sell. If Apple objects to the link, the fallback is the message without the button.
- **1.2 (user-generated content).** Comments and messages show with no in-app report or block. Be ready to point to SoundCloud's reporting, or add the controls.
- **2.1 (completeness).** The reviewer needs a working demo account with a paid plan, and an iPhone or iPad to sign in the Apple TV. The notes explain both, and how to test with local files.
