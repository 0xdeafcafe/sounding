# Applying the listing in App Store Connect

Superseded for text fields: `tools/appstore/apply_metadata.py --apply` writes everything in `metadata.md` through the API, and `RELEASE-CHECKLIST.md` lists what's left. This page remains the manual walkthrough. Source of every value: `metadata.md` in this folder. Screenshots: `screenshots/<platform>/`. Do the steps in order. Paths are in the ASC web UI at <https://appstoreconnect.apple.com>. The API names in brackets are for a later scripted apply.

## 0. Before anything

1. Replace `sounding@alex.forbes.red` and `DEMO_ACCOUNT_PLACEHOLDER` in `metadata.md` (section 7, 9 and 10) with the real values.
2. Publish the privacy policy at `https://sounding.forbes.red/privacy` (draft text in `metadata.md`, section 7). `docs/` is the site root and has no privacy page. Add `docs/privacy.html` (or `docs/privacy/index.html`) and push; the Pages site picks it up through `docs/CNAME`.
3. Confirm `red.forbes.sounding` (and `red.forbes.sounding.watchkitapp`, `.Widget`, `.Share`, `.TopShelf`) exist at Certificates, Identifiers and Profiles, Identifiers. See `tools/testflight/README.md`, section 1.

## 1. Create the app record (once)

Apps, `+`, New App.

1. Platforms: tick iOS, tvOS and macOS. (iOS also covers iPad and the embedded Apple Watch app.)
2. Name: `Sounding`.
3. Primary language: English (U.K.).
4. Bundle ID: `red.forbes.sounding`.
5. SKU: `sounding` (any unique string; it is never shown).
6. User access: Full Access.

[`POST /v1/apps` needs the app to be created in the UI first; the API cannot create app records.]

## 2. App-level pages (shared by all three platforms)

My Apps, Sounding, App Store, sidebar General.

### 2.1 App Information

| Field | Value | API |
| --- | --- | --- |
| Name | `Sounding` | `appInfoLocalizations.name` |
| Subtitle | `Listen, mix, take it along` | `appInfoLocalizations.subtitle` |
| Privacy Policy URL | `https://sounding.forbes.red/privacy` | `appInfoLocalizations.privacyPolicyUrl` |
| Primary Category | Music | `appInfos.primaryCategory` = `MUSIC` |
| Secondary Category | Entertainment | `appInfos.secondaryCategory` = `ENTERTAINMENT` |
| Content Rights | The app shows third-party content: answer that it does, and that you have the rights to use it or are not required to (it is a client for a service the user signs in to) | `apps.contentRightsDeclaration` |

### 2.2 Age Rating

App Information, Age Rating, Edit. Enter the answers from `metadata.md`, section 5. [`ageRatingDeclarations`]

### 2.3 App Privacy

General, App Privacy.

1. Privacy Policy URL: same URL as above.
2. Get Started, then answer from `metadata.md`, section 6. Recommended: Data Not Collected. Cautious alternative: Identifiers (User ID), User Content (Other User Content), Usage Data (Product Interaction), all linked to the user, none used for tracking, purpose App Functionality.
3. Publish.

### 2.4 Pricing and Availability

Free (Tier 0), all territories unless the owner excludes any. [`appPriceSchedules`, `appAvailabilities`]

### 2.5 Encryption (per build, at upload)

Nothing to answer when a build is processed: every app Info.plist sets `ITSAppUsesNonExemptEncryption` to `false`. If ASC still asks, use the answers in `metadata.md`, section 8.

## 3. iOS version (iPhone, iPad, Apple Watch)

My Apps, Sounding, App Store, sidebar iOS App, 1.0 Prepare for Submission. [`appStoreVersions` where `platform` = `IOS`, then `appStoreVersionLocalizations`]

1. Screenshots, iPhone, 6.9-inch display: drag in `screenshots/iphone/iphone-1` to `iphone-6`, in numeric order. 1320 x 2868. [`appScreenshotSets.screenshotDisplayType` = `APP_IPHONE_67`]
2. Screenshots, iPad, 13-inch display: `screenshots/ipad/ipad-1` to `ipad-4`. 2064 x 2752. [`APP_IPAD_PRO_3GEN_129`; check the current display type list, which Apple renames when new sizes arrive]
3. Screenshots, Apple Watch, Ultra: `screenshots/watch/watch-1` to `watch-5`. 422 x 514. [`APP_WATCH_ULTRA`]
4. Smaller iPhone and iPad sizes: leave empty. ASC scales the 6.9-inch and 13-inch sets down.
5. Promotional Text: `metadata.md`, section 2. [`promotionalText`]
6. Description. [`description`]
7. Keywords. [`keywords`]
8. Support URL: `https://sounding.forbes.red`. [`supportUrl`]
9. Marketing URL: `https://sounding.forbes.red`. [`marketingUrl`]
10. What's New in This Version. [`whatsNew`]
11. Build: select the processed build (version 1.0, build 6 or later).
12. Copyright: `2026 Alexander Forbes-Reed`. [`appStoreVersions.copyright`]
13. App Review Information:
    - Sign-in required: on. User name and password: the demo SoundCloud account.
    - Contact: owner's name, phone, email.
    - Notes: the block in `metadata.md`, section 10.
14. Version Release: Manually release this version (recommended for a first release).

## 4. Apple TV version

Sidebar `+` next to the platforms if tvOS is not listed, then tvOS App, 1.0 Prepare for Submission. [`platform` = `TV_OS`]

1. Screenshots, Apple TV: `screenshots/tvos/tvos-1` to `tvos-4`. 1920 x 1080. [`APP_APPLE_TV`]
2. Promotional Text, Description, Keywords, What's New: `metadata.md`, section 3.
3. Support URL and Marketing URL: `https://sounding.forbes.red`.
4. Build, Copyright: as for iOS.
5. App Review Information: the Apple TV app has no sign-in form. In the notes say that the reviewer links it from the iPhone app (the Apple TV shows a code and the iPhone approves it), or from the QR code shown on the sign-in screen. Use the notes block from `metadata.md`, section 10.

## 5. Mac version

Sidebar macOS App, 1.0 Prepare for Submission. [`platform` = `MAC_OS`]

1. Screenshots, Mac: `screenshots/macos/macos-1` to `macos-5`. 2880 x 1800. [`APP_DESKTOP`]
2. Promotional Text, Description, Keywords, What's New: `metadata.md`, section 4.
3. Support URL, Marketing URL, Build, Copyright: as above.
4. App Review Information: the Mac app takes its sign-in from the iPhone or Apple TV over the local network (it has no sign-in form of its own). The reviewer needs an iPhone or Apple TV running the same build, or you attach a short screen recording. Say so in the notes.
5. App category on the build is already `public.app-category.music` in the Mac Info.plist.

## 6. TestFlight

My Apps, Sounding, TestFlight.

1. Test Information (left sidebar, under TestFlight):
   - Beta App Description: `metadata.md`, section 9. [`betaAppLocalizations.description`]
   - Feedback Email: the real address. [`betaAppLocalizations.feedbackEmail`]
   - Marketing URL: `https://sounding.forbes.red`; Privacy Policy URL: `https://sounding.forbes.red/privacy`.
   - Beta App Review Information: contact details and the demo account.
2. Each build, Test Details (per build): "What to Test" from `metadata.md`, section 9. [`betaBuildLocalizations.whatsNew`]
3. Internal Testing group: add team members. No review needed.
4. External Testing group: add testers, submit the first build for Beta App Review.

## 7. Submit

1. App Review: every platform page shows no red warnings.
2. Add for Review on the iOS version, then on tvOS and macOS. They can be submitted together on one submission. [`reviewSubmissions`]

## 8. Icon and screenshot notes

- The App Store icon (1024 x 1024, set on the build, not in ASC) is being redesigned. Nothing in the listing text or screenshots depends on it. Re-check the screenshots if the new icon appears in them (the Mac and iPhone screenshots do not show it; the Mac mini player shows the app icon at small size).
- All screenshots are taken from simulators (and the Mac Debug build with a clean home folder) in fixture mode. Names, artwork and counts are generated sample data. The Apple Watch clock cannot be overridden and reads the real time.
- Known weak spots, replace if you have better: iPad "ipad-4-library" is half empty; Mac "macos-2-decks" shows empty decks; tvOS has only four images (the TV simulator was unstable with the fixture hooks, so Now Playing, Decks and Settings were not captured). The iPad Now Playing screen was left out because its artwork is clipped at the top.

## 9. Review risks to know about before submitting

- Guideline 5.2 (intellectual property): the app is an unofficial client for SoundCloud, signs in on SoundCloud's own page and talks to its web API. SoundCloud's terms apply, and Apple may ask for evidence of permission. The listing avoids the name, logo and branding in every field and screenshot (the app's own sign-in button text does name the service; that is the app's UI).
- Guideline 1.2 (user-generated content): the app shows SoundCloud comments and messages, and has no in-app report or block controls. Be ready to point to SoundCloud's own reporting, or add the controls.
- Guideline 2.1 (completeness): the reviewer must be able to sign in, so the demo account must work from a clean install.
