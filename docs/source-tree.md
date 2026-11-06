# Source tree

The source tree is organized by ownership first, then feature. Xcode file
references point at these physical locations; target membership is explicit
and does not depend on folder scanning.

```text
SoundingTV.swiftpm/Sources
├── Auth
│   └── Shared                 # pairing wire protocol, Bonjour client, session sync/store
├── Core
│   ├── Analysis               # waveform, loudness, genre, analysis cache/sync
│   ├── Artwork                # artwork fetch/decode store, variants (no UI)
│   ├── DJ                     # cues, decks, scoring, mix engine
│   ├── Downloads
│   ├── Library
│   ├── Models
│   ├── Networking             # peer content transport
│   ├── Playback               # player and system media-session bridges
│   ├── Settings
│   ├── SoundCloud             # API, subscriptions, track actions
│   ├── Support
│   ├── Sync                   # CloudKit engine
│   └── TopShelf
├── Shared
│   ├── AppIntents
│   ├── Debug                  # fixture data shared by every app target
│   ├── Design
│   ├── UI
│   │   ├── Comments
│   │   └── Components
│   └── ViewModels
└── Apps
    └── tvOS
        ├── App
        ├── Auth
        ├── Debug
        ├── Design
        ├── Features
        ├── Playback
        ├── TopShelf
        └── UI

SoundingTV-iOS/Sources
├── App
├── Auth
├── Features
│   ├── AppleTV
│   ├── Feed
│   ├── Home
│   ├── Intelligence
│   ├── Library
│   ├── Profile
│   ├── Search
│   └── Settings
├── Playback
└── Services

SoundingTV-macOS/Sources
├── App
├── Auth
├── Design
├── Features
│   ├── DJ
│   ├── Feed
│   ├── Home
│   ├── Library
│   ├── Playback
│   ├── Profile
│   └── Search
└── Services

SoundingTV-Share/Sources       # App, Models
SoundingTV-TopShelf/Sources
SoundingTV-UITests/Sources
```

Ownership rules:

- `Core` contains UI-independent product domains used by multiple apps.
- `Shared` contains cross-app presentation seams and intents.
- `Auth/Shared` is the single implementation of pairing and session transfer.
- `Apps/tvOS` and each platform root contain only platform-owned UI/services.
- Extensions own their entry points and extension-specific presentation.
- The retired App Clip has no target, source directory, entitlement, or project
  dependency. QR and Handoff links open the installed iOS companion app.

Layering rule: `Core` may reference only `Core`, `Shared` may reference `Core`
and `Shared`, and only a platform root may reference its own types. A file in
`Core` or `Shared` that reaches into `Apps/tvOS` or a platform root still
compiles for the owning platform and fails for every other one, so the break
surfaces on whichever target you were not building.

A file two targets both compile belongs in `Core` or `Shared`, not in the
platform root of whichever app happened to need it first.

Run `ruby tools/check-layering.rb` to verify both rules without a build. It
reports upward references and files compiled into a target that does not own
their directory. Run `ruby tools/organize-source-tree.rb --apply` as an
idempotent integrity check after changing project groups or source ownership.
