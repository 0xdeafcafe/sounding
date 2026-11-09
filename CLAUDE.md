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
- **Testing:**
  - use real auth and the real account for all testing (no fixtures or fake logins); keep traffic low and stop at the first 429;
  - shared simulators only;
  - kill the Mac app by PID, never `pkill -x Sounding`.
- **Website:** `docs/` is the public GitHub Pages site. Never modify `docs/auth/` or `docs/CNAME`. Publish with a docs-only commit to `main`.
