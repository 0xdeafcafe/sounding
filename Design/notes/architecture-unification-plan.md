# Sounding architecture unification plan

Status: active migration, based on the repository audit of 2026-08-10.

## Implemented in this pass

- `AppRuntime` is the process composition root on iOS, tvOS, and macOS. It
  receives the concrete playback, sync, download, catalog, analysis, nearby,
  integration, account, and scheduler instances used by that process.
- `IntegrationSystem` is the only lifecycle driver for Companion, Watch,
  Spotlight, MIDI, and other optional platform integrations. Registration is
  idempotent by integration id.
- `PlaybackSourceResolver` is the single local/cache/network selection owner.
  `PlayerService` owns that resolver instance and uses it for ordinary
  playback, previews, manual decks, auto-mix preparation, and analysis audio.
  Its download, API, and cue dependencies are injected; the only audio
  renderers in production source are `PlayerService` and its `MixEngine`.
- Playback has a generation-token pipeline, so a late resolution or AVPlayer
  callback cannot overwrite a newer track selection or restart after Pause.
- `SynchronizationCoordinator` and `SynchronizationGateway` are the single
  mutation, pacing, coalescing, and transport-lane boundary for CloudKit and
  Companion state. Cue, settings, and setlist stores emit through narrow typed
  command ports instead of static callback hooks. Nearby cue and likes imports
  also enter through the coordinator rather than writing stores from transports.
- `WorkScheduler` now owns eligible autonomous cadence and admission, with
  priority, constraints, latest/FIFO delivery, stable ordering, cancellation
  scopes, jittered retry, periodic diagnostics, and metrics. Real-time audio
  and protocol deadlines remain local.
- Domain-wide likes, authentication, like-action, and traffic-safety
  notifications were replaced by observable typed state. The remaining custom
  session, pairing, auth-handoff, audio-route, and Mac presentation broadcasts
  were also removed. UI and integrations subscribe to typed state revisions and
  issue commands in one direction; only framework notifications enter adapters.
- One `RuntimeNetworkIntegration` publishes reachability, cost, and constrained
  status through `WorkScheduler.Environment`. Downloads subscribe to that state;
  they no longer create a second path monitor.
- Scroll-backed collections use lazy containers. Library, playlist, album,
  sidebar, feed, discovery, and search cache reads are explicitly bounded;
  network pagination advances from near-end demand rather than eager page
  crawls. Local search filters only the current data window and offers an
  explicit next-page action instead of hydrating an entire collection.
- The architecture checker is clean with zero upward dependencies and zero
  file cycles. It now rejects eager scroll children, UI-owned pagination walks,
  unbounded feature cache materialization, removed stringly domain broadcasts,
  duplicate reachability monitors, and alternate audio renderers.

## Outcome

Sounding should have one composition root per app process and one owner for each
system capability. Features ask those owners to do work through small interfaces;
they do not create transports, timers, caches, or alternate copies of the same
service.

This is intentionally not a proposal for one application-wide god object. The
composition root owns a graph of focused systems:

```text
AppRuntime
├── PlaybackSystem
├── SynchronizationSystem
│   ├── CloudKit adapter
│   ├── Companion adapter
│   ├── Watch adapter
│   └── Polyphony state adapter
├── DownloadSystem
├── CatalogSystem
├── AnalysisSystem
├── AccountSystem
├── NearbySystem
├── IntegrationSystem
└── WorkScheduler
```

Each system has one state owner. Platform APIs are adapters passed into the
system, rather than reasons for a feature to implement another owner.

## Audit baseline

The production-source static pass (including every app and extension target,
after the first scheduler migrations) found:

- 135 occurrences of `Task.sleep`, timers, dispatch delays, debounce, or
  throttle across 51 Swift files.
- 79 `shared` singleton declarations across 63 Swift files. A broad search
  found 1,146
  `.shared` references, including Apple framework singletons; the meaningful
  result is that service lookup is pervasive in app entry points and views.
- 33 files using global `NotificationCenter` traffic.
- 49 direct raw-network/session API sites spread across SoundCloud, artwork,
  downloads, sharing,
  Companion, WatchConnectivity, pairing, peer content, and Polyphony code.
- The repository layering checker reports 9 upward layer violations and 5 new
  file dependency cycles.
- Identical or near-identical platform services exist for likes-sync lifecycle,
  player lifecycle, now-playing artwork, and artwork caches.
- App startup independently installs credential sources, static callback hooks,
  lifecycle observers, audio-session behavior, sync loops, Companion servers,
  Watch servers, and activity polling.

The main current dependency cycles are:

- Downloads ↔ download-manifest sync ↔ peer content.
- Library cache ↔ likes peer sync ↔ likes sync engine.
- Player service ↔ DJ transition service.
- SoundCloud API ↔ SoundCloud gateway.
- Visual fixtures ↔ discovery home source.

## Ownership rules

1. There is exactly one mutable owner for playback, synchronization, downloads,
   account/session state, catalog requests, analysis work, and nearby-device
   connectivity in each process.
2. Features receive narrow capabilities such as `PlaybackControlling`,
   `DownloadControlling`, and `SyncStatusProviding`. They do not call service
   singletons directly.
3. A transport owns connection mechanics and framing. It does not own domain
   state, retry cadence, or feature policy.
4. A cache owns persistence for one data class. Views never create network
   sessions or cache files.
5. Cross-system changes use typed events or explicit method calls. Static
   closure targets and stringly global notifications are transitional only.
6. Data-plane media transfer and control-plane synchronization remain separate.
   Large audio downloads must never queue ahead of play/pause or state updates.
7. Platform differences enter through adapters assembled by `AppRuntime`.
   Shared systems do not reach upward into iOS, tvOS, or macOS UI code.

## Unified scheduler

`WorkScheduler` is the single policy owner for non-real-time autonomous work.
It provides stable job keys, cancellation scopes, latest-value coalescing,
ordered FIFO delivery, debounce, periodic triggers, retry/backoff hooks, and
basic metrics.

Jobs that belong on it:

- Cloud and nearby state synchronization cadence.
- Likes and library metadata refresh.
- Subscription reverification.
- Download maintenance and traffic-safety resumption.
- Cloud device-offer refresh and Mac activity polling.
- Watch snapshot coalescing.
- Background analysis/setlist job admission and low-priority pacing.
- Reconnect attempts where the protocol does not require a precise deadline.

Jobs that explicitly do not belong on it:

- Audio render, deck, crossfade, or playback timeline clocks.
- Polyphony's 20 Hz transport-state broadcast and clock calibration.
- Socket handshake, request, and pairing deadlines.
- URLSession background-transfer execution.
- UI animation, toast dismissal, focus, and search-field presentation delays.

Those are domain clocks or protocol deadlines. Moving them through a general
actor would add jitter and make unrelated work capable of harming playback.

The scheduler accepts constraints from the runtime—foreground state, network
availability, power/charging policy—but does not discover them through global
singletons. A job remains owned by its subsystem; the scheduler only decides
when the admitted work may run.

## System boundaries

### PlaybackSystem

- Owns the one multi-track player, source resolution, current queue, loading,
  buffering, cached-file selection, streaming readiness, transitions, and
  playback state.
- Receives platform audio-session, remote-command, and now-playing adapters.
- Exposes read-only state and command capabilities to UI, Companion, Watch, and
  Polyphony.
- Never depends on a view or Shared UI lookup helper.

### SynchronizationSystem

- Owns domain mutations, deduplication, pacing, cursors, conflict handling, and
  delivery status.
- Contains Companion as a nearby transport adapter instead of treating it as a
  second synchronization system.
- Adapts CloudKit, Companion, and Watch state traffic to the same domain events.
- Uses separate lanes for reliable commands, latest snapshots, continuous
  controls, bulk sync, and cloud replication.
- Delegates timing to `WorkScheduler`; transports retain security and framing.

### DownloadSystem

- Owns download intent, persistent manifest, cache placement, background
  transfer tasks, retries, budget/quality policy, and local/peer availability.
- Provides a `PlayableSourceResolving` capability to PlaybackSystem.
- Keeps peer media bytes on a separate data plane while publishing availability
  changes through typed events.

### CatalogSystem

- Owns SoundCloud request admission, credentials presented to requests,
  pagination, artwork loading, metadata persistence, and request telemetry.
- Replaces direct `URLSession.shared` work in views and player code.
- Supplies repository-style interfaces to features and other systems.

### NearbySystem

- Shares discovery, connection lifecycle, trust, framing, reconnect policy, and
  diagnostics across Companion, linking, sharing, Polyphony, and peer content.
- Does not collapse their protocols or traffic classes into one socket.
- Exposes a control plane and a media data plane so large payloads cannot block
  interactive messages.

### PlatformServices

One platform bundle provides lifecycle events, audio session, now playing,
background transfers, WatchConnectivity when present, notifications, and secure
storage. iOS, tvOS, and macOS implement this bundle; systems depend only on its
small protocols.

## Migration sequence

### Phase 0 — characterization and telemetry

- Preserve existing behavior with gateway, player-source, queue-ordering,
  download-resume, and sync conflict tests.
- Add metrics for submitted/coalesced/dropped work, bytes by transport lane,
  reconnects, cache hit/miss, playback startup latency, and underruns.
- Make the layering checker part of CI and prevent new dependency cycles.

Exit: current behavior is measurable and each later phase can prove it did not
increase traffic or playback latency.

### Phase 1 — composition root

- Introduce `AppRuntime` and `PlatformServices` factories for all three apps.
- Initially wrap existing singleton instances to avoid a flag-day rewrite.
- Inject runtime capabilities into root views and feature/view-model factories.
- Move app startup/install sequences into the runtime.

Exit: app entry points construct one graph; no feature constructs an integration.

Status: implemented for all three primary apps. Remaining direct singleton
lookups are migration debt inside older features, not alternate process roots.

### Phase 2 — scheduler foundation

- Add `WorkScheduler` and put SynchronizationGateway policy on it.
- Migrate likes/library tickers, subscription checks, download maintenance,
  activity polling, Watch coalescing, and cloud-offer refresh.
- Add foreground/network constraints, jittered backoff, and job diagnostics.
- Leave real-time and protocol-deadline clocks local as listed above.

Exit: one diagnostic surface lists every autonomous job and its next run; no
eligible service or view owns an ad-hoc periodic loop.

Status: implemented for the audited autonomous jobs. UI animation/debounce,
media timing, and wire-protocol deadlines remain intentionally local.

### Phase 3 — synchronization integrations

- Move Companion client/server lifecycle under SynchronizationSystem.
- Adapt Watch state snapshots and Polyphony replicated state into typed domains.
- Keep pairing/linking as a NearbySystem bootstrap protocol and peer audio as a
  data-plane service.
- Replace `CueSyncTarget`, `SetlistSyncTarget`, `SettingsSyncTarget`, and
  `SessionSyncTarget` static hooks with injected event sources.

Exit: all replicated mutations pass through one observable gate and have one
owner, delivery policy, and byte budget.

Status: mutation and delivery gating implemented for CloudKit and Companion,
including nearby cue and likes persistence. Shared nearby protocol primitives
remain a follow-up extraction.

### Phase 4 — download/source/cache graph

- Break the Downloads/manifest/peer-content dependency cycle with capability
  protocols and one-way events.
- Make DownloadSystem the sole owner of local media placement and resumability.
- Make PlaybackSystem consume a source resolver instead of probing managers.
- Consolidate duplicate artwork caches behind CatalogSystem.

Exit: one source decision explains whether playback is local, progressive,
streaming, or awaiting download; views never make the choice.

Status: source decision and cache ownership implemented; player dependencies
are injected and guarded against alternate renderers. Background transfer and
peer-media execution remain separate data-plane adapters by design.

### Phase 5 — nearby transport primitives

- Extract common discovery, secure-connection, framing, timeout, reconnect, and
  metrics primitives.
- Migrate Companion, Watch bridge, link/bootstrap, share, Polyphony, and peer
  content adapters without merging their state machines.
- Enforce independent traffic lanes and payload budgets.

Exit: integrations share infrastructure without allowing bulk traffic to block
commands or playback.

### Phase 6 — remove service location and platform copies

- Replace direct `.shared` access in views with injected capabilities.
- Consolidate duplicate lifecycle and now-playing implementations into shared
  coordinators with platform adapters.
- Replace global notifications with typed streams where ownership crosses a
  system boundary.
- Remove transitional static install hooks and singleton wrappers.

Exit: new features cannot bypass the runtime graph, and the layering checker is
clean or has an explicit, shrinking migration allowlist.

Status: duplicated likes lifecycle coordinators, static synchronization hooks,
and custom domain broadcasts are removed. Critical playback and Companion paths
now use injected instances. Older feature views still contain direct lookups of
the same process-owned services; replacing those call sites with narrow runtime
capabilities remains migration debt, but they do not construct alternate owners.

## Guardrails and acceptance checks

- A play/pause/seek command never waits behind cloud, artwork, analysis, or
  media-transfer work.
- Replaceable state is latest-wins; discrete commands are FIFO and never
  coalesced.
- Identical snapshots are not serialized or transmitted twice.
- Disconnecting an integration cancels its pending work scope.
- Periodic jobs have one registration, survive foreground transitions without
  duplication, and use bounded jittered retry.
- Every network request is attributable to a system, feature intent, and lane.
- Every cache has one writer and a documented eviction owner.
- All app targets build after every phase; gateway and scheduler policy have
  deterministic unit tests.
- Playback startup, underrun, request count, and sync-byte metrics are compared
  with the Phase 0 baseline.
- A feature-owned cache query must state a limit, and a feature may not walk a
  pagination cursor in a loop. Lazy UI demand is what advances the cursor.
- Domain state reaches UI through observable projections; stringly global
  broadcasts for application state fail the architecture check.

## Implemented foundation

The first slice is deliberately narrow and complete:

1. One SynchronizationCoordinator receives lifecycle and mutation nudges.
2. One SynchronizationGateway gates CloudKit and Companion outbound traffic.
3. Companion state is event-driven and coalesced; commands remain FIFO.
4. Duplicate platform sync timers are removed.
5. WorkScheduler is the timing primitive beneath the gateway and now owns the
   low-risk sync, library, subscription, download-maintenance, device-offer,
   Watch snapshot, Companion heartbeat, and activity-polling cadences.

This foundation establishes the ownership rule and makes the most damaging
bypasses fail the architecture check. Remaining feature-level service-location
cleanup can proceed incrementally without reintroducing duplicate playback,
synchronization, scheduling, or reachability owners.
