# Sounding

Read **`Design/DESIGN-BIBLE.md`** before any UI, UX, copy, motion or website work. It's the source of truth for design and process, and it overrides older specs in `Design/specs/`. When a user decision changes a rule, update the bible in the same change.

Hard rules (details in the bible):
- **Code style:** no code comments, except an occasional `// MARK:`.
- **Project file:** never run xcodegen. `SoundingTV.xcodeproj/project.pbxproj` is hand-maintained.
- **Lyrics come from LRCLIB only** (owner decision 2026-11-08, reversing the old no-lyrics rule). `TokenTransferProtocol.swift` stays dependency-free. `DeviceClass` is the one device-identity enum.
- **Native Apple idioms:**
  - system controls and grouped Forms;
  - no custom cards, no system blue (the app tint is brand orange everywhere, owner 2026-11-09), no implementation prose;
  - empty, loading and error states centred, using `ContentUnavailableView`.
- **Every device, one implementation** (owner 2026-11-12: "these things MUST be there for all devices, not be device specific"):
  - apps: iPhone and iPad (iOS 26.5+), Mac (macOS 27), Apple TV (tvOS 27), Apple Watch (watchOS 27, shipped inside the iOS app), CarPlay, plus the widget, Share and Top Shelf extensions;
  - code lives in `SoundingTV.swiftpm/Sources/{Core,Shared,Auth}` and is used by every app; `SoundingTV-iOS`, `SoundingTV-macOS`, `SoundingTV-watchOS` and `Sources/Apps/tvOS` hold only idiom (chrome, focus, sidebars, input);
  - caching, performance fixes, networking, playback and data features go in shared code and are wired up on every app in the same change; never fix or add something on one device only;
  - the owner's iPad runs iPadOS 26, so an iOS 27-only API needs a working iOS 26 path; never let a `#available` gate quietly turn a feature off;
  - vocabulary: Link is trust and credentials, Companion is the control channel, listening together is SharePlay, Output is where audio plays, Handoff means only `NSUserActivity`.
- **Building:** a merge builds every platform. The iOS scheme also compiles the watch, widget and Share targets, so it's the one that catches wire-protocol breaks. TestFlight builds come from `tools/testflight/release.sh all`. History was squashed on 2026-11-09, so pass a `BUILD_NUMBER` above the latest App Store Connect build.
- **Testing:**
  - use real auth and the real account for all testing (no fixtures or fake logins); keep traffic low and stop at the first 429;
  - shared simulators only;
  - kill the Mac app by PID, never `pkill -x Sounding`.
- **Website:** `docs/` is the public GitHub Pages site. Never modify `docs/auth/` or `docs/CNAME`. Publish with a docs-only commit to `main`.
