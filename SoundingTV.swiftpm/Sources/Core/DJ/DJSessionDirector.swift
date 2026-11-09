import Foundation
import AVFoundation
import Combine
import MusicUnderstanding

/// Owns the Decks session on behalf of PlayerService: mix-session lifecycle
/// (arm → live → hand back), deck arming/preload decisions, the phantom plan
/// cache, adaptive replanning, stage scheduling, mix-window state, and the
/// fallback policy when a blend cannot run.
///
/// PlayerService keeps the playback plumbing (AVPlayer, stream resolution,
/// queue, persistence) and forwards its public DJ API here unchanged. The
/// enable-policy tri-state (manual request / setting / collection policy)
/// also stays on PlayerService because session restore and persistence read
/// it; everything engine-facing moved here.
@MainActor
final class DJSessionDirector: ObservableObject {

    unowned let host: PlayerService

    init(host: PlayerService) {
        self.host = host
        observeAnalysisStates()
        observeSnapshotInputs()
        observeEnergy()
        observePerformanceLevel()
    }

    private func observePerformanceLevel() {
        Publishers.Merge(
            SettingsStore.shared.$djPerformanceLevel.removeDuplicates().dropFirst().map { _ in () },
            SettingsStore.shared.$djMoveStyle.map(\.blockedMidTrackMoves).removeDuplicates().dropFirst().map { _ in () }
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.cancelPerformance()
                self.schedulePerformanceIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func observeEnergy() {
        let energy = AutoMixEnergy.shared
        let settings = SettingsStore.shared
        Publishers.MergeMany(
            energy.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            settings.$djEnergyLevel.map { _ in () }.eraseToAnyPublisher(),
            settings.$djEnergyFollowsNight.map { _ in () }.eraseToAnyPublisher(),
            settings.$djMatchWorkout.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.energyTargetDidChange() }
        .store(in: &cancellables)
        AutoMixIntentStore.shared.$active
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.host.isAutoMixEnabled else { return }
                self.reconsiderCurrentPlanIfUseful()
            }
            .store(in: &cancellables)
    }

    private func energyTargetDidChange() {
        let target = AutoMixEnergy.shared.target
        guard target != lastEnergyTarget else { return }
        let previous = lastEnergyTarget
        lastEnergyTarget = target
        guard previous != nil, host.isAutoMixEnabled else { return }
        reconsiderCurrentPlanIfUseful()
    }

    // MARK: - Session state (moved from PlayerService)

    private var mixEngineTouched = false
    private var armedTrackId: String?
    private var armingTrackId: String?
    var incomingTrackId: String?
    private var armTask: Task<Void, Never>?
    private var armingDeck: MixEngine.Deck = .a
    private var pendingStartPosition: TimeInterval?
    private var avPlayerFallback: (trackId: String, reason: String)?
    private var engineRetry: (trackId: String, attempts: Int)?
    private var engineSkipStreak = 0
    private var handoverTrackId: String?
    private var midTrackHandoverTrackId: String?
    private var handoverTask: Task<Void, Never>?
    private var audibleHold: TimeInterval?
    private static let audibleHoldTolerance: TimeInterval = 0.01
    private static let audibleHoldMinimumLatency: TimeInterval = 0.1
    private var incomingTask: Task<Void, Never>?
    private var warmTasks: [String: Task<Void, Never>] = [:]
    private var warmFailures: [String: Date] = [:]
    private static let maxConcurrentWarmTasks = 2
    private static let warmRetryInterval: TimeInterval = 10 * 60
    private var mixTask: Task<Void, Never>?
    private var transitionActions: MixActionGroup?
    private var tempoReturn: MixScheduledAction?
    private var mixEngineObserver: AnyCancellable?
    private var mixEngineErrorObserver: AnyCancellable?
    var isCrossfading = false
    var deckEndHandled = false

    #if os(macOS)
    var tempoReference: @MainActor () -> DJPlayersTempoReference? = { DJPlayersController.shared.autoMixTempo }
    #endif
    private var lastNowPlayingSecond = -1
    private var lastMixEngineTransportUpdate = Date.distantPast
    private static let mixEngineTransportUpdateInterval: TimeInterval = 0.5

    private var cancellables = Set<AnyCancellable>()

    private var phantomPlanCache: [String: PhantomDJEngine.Plan] = [:]
    private var phantomPlanTasks: [String: Task<Void, Never>] = [:]
    private var phantomCutAnnounced = false
    private var deadlineLoopTrackId: String?
    private var recentTemplates: [TransitionTemplateID] = []
    private var performedMoves: [(kind: MixMove.Kind, at: Date)] = []
    private var jumpPlans: [String: PhantomDJEngine.Plan] = [:]
    private var jumpPlanTasks: [String: Task<Void, Never>] = [:]
    private var jumpDeckTrackId: String?
    private var jumpTask: Task<Void, Never>?
    private var isJumping = false
    private var activeMove: PhantomDJEngine.Plan?
    private var pinnedPlanTrackIds: Set<String> = []
    var forcedPlans: [String: PhantomDJEngine.Plan] = [:]
    private var lastEnergyTarget: Int?
    private var playedLog: [(id: String, artist: String)] = []
    private static let playedLogLimit = 50
    private static let jumpPreloadSeconds: TimeInterval = 45
    private static let jumpClearanceSeconds: TimeInterval = 60
    private var lastPlannerAnalysisStates: [String: AnalysisState] = [:]
    private var performanceTrackId: String?
    private static let performanceStartLead: TimeInterval = 4
    private static let transitionSchedulingLead: TimeInterval = 0.8

    // MARK: - Session snapshot

    /// The one read model consoles observe. Rebuilt on the throttled engine
    /// tick and on every discrete session/plan change; unchanged values are
    /// coalesced, so a paused session costs no republishes.
    @Published private(set) var snapshot: DJSessionSnapshot?

    private func observeSnapshotInputs() {
        host.$mixEngineState.dropFirst().sink { [weak self] _ in self?.publishSnapshot() }.store(in: &cancellables)
        host.$incomingDeck.dropFirst().sink { [weak self] _ in self?.publishSnapshot() }.store(in: &cancellables)
        host.$mixWindow.dropFirst().sink { [weak self] _ in self?.publishSnapshot() }.store(in: &cancellables)
        host.$phantomActivity.dropFirst().sink { [weak self] _ in self?.publishSnapshot() }.store(in: &cancellables)
        host.$liveDeck.dropFirst().sink { [weak self] _ in self?.publishSnapshot() }.store(in: &cancellables)
        host.$isAutoMixEnabled.dropFirst().sink { [weak self] _ in self?.publishSnapshot() }.store(in: &cancellables)
        host.$djProfile.dropFirst().sink { [weak self] _ in self?.publishSnapshot() }.store(in: &cancellables)
        host.$currentTrack.sink { [weak self] track in self?.notePlayed(track) }.store(in: &cancellables)
        let settings = SettingsStore.shared
        Publishers.Merge3(
            settings.$djBlend.dropFirst().removeDuplicates().map { _ in () },
            settings.$djKeepQueueOrder.dropFirst().removeDuplicates().map { _ in () },
            settings.$djMoveStyle.dropFirst().removeDuplicates().map { _ in () }
        )
        .sink { [weak self] in self?.profileDidChange() }
        .store(in: &cancellables)
    }

    private func publishSnapshot() {
        AutoMixLive.shared.publish(autoMixLiveState())
        guard host.djSessionEnabled else {
            if snapshot != nil { snapshot = nil }
            return
        }
        let engine = MixEngine.shared
        let activity = host.phantomActivity
        let activePlan: PhantomDJEngine.Plan?
        if case .mixing(let plan) = activity { activePlan = plan } else { activePlan = nil }
        let next = DJSessionSnapshot(
            mixEngineState: host.mixEngineState,
            isAutoMixEnabled: host.isAutoMixEnabled,
            liveDeck: host.liveDeck,
            decks: MixEngine.Deck.allCases.map {
                DJDeckSnapshot(
                    deck: $0,
                    isLive: $0 == host.liveDeck,
                    state: engine[$0],
                    beatGrid: engine.beatGrid(for: $0)
                )
            },
            crossfade: engine.crossfade,
            masterVolume: engine.masterVolume,
            mixWindow: host.mixWindow,
            activity: activity,
            activePlan: activePlan,
            upcomingPlan: adaptiveMixPlan,
            profile: host.djProfile
        )
        guard next != snapshot else { return }
        snapshot = next
    }

    // MARK: - Profile / plan cache lifecycle

    /// The profile drives the plan cache; a profile change invalidates every
    /// computed plan, exactly as the old djProfile didSet did.
    func profileDidChange() {
        for task in phantomPlanTasks.values { task.cancel() }
        phantomPlanTasks.removeAll()
        phantomPlanCache.removeAll()
        if host.djProfile != nil {
            refreshPhantomPlan()
        } else {
            host.phantomActivity = .idle
        }
    }

    // MARK: - Read models (PlayerService forwards its public API here)

    func plannedMixSeconds() -> TimeInterval? {
        if let plan = adaptiveMixPlan { return plan.transitionSeconds }
        if host.isPhantomEnabled, let track = host.currentTrack {
            return automaticCleanCutFallback(for: track)?.transitionSeconds
        }
        return nil
    }

    func plannedMixPointSeconds() -> TimeInterval? {
        if let plan = adaptiveMixPlan { return plan.mixPointSeconds }
        guard host.isPhantomEnabled, let track = host.currentTrack,
              let fallback = automaticCleanCutFallback(for: track) else {
            return nil
        }
        return fallback.mixPointSeconds
    }

    var adaptiveMixPlan: PhantomDJEngine.Plan? {
        guard let track = host.currentTrack, let plan = phantomPlanCache[track.id] else { return nil }
        guard let next = host.upcomingMixTrack else { return nil }
        guard plan.incomingTrackId == nil || plan.incomingTrackId == next.id else { return nil }
        return plan
    }

    var upcomingMovePlan: PhantomDJEngine.Plan? {
        if let activeMove, isCrossfading { return activeMove }
        if let track = host.currentTrack, let jump = eligibleJump(for: track) { return jump }
        return adaptiveMixPlan
    }

    var automaticMixDecision: DJAutomaticMixDecision {
        let profileName = host.djProfile?.displayName
        let plan = upcomingMovePlan
        let isFallback = plan?.templateId == DJTemplates.cutOnTheOne
        let templateName = plan?.move?.displayName
            ?? plan?.rationale?.templateName
            ?? plan?.templateId.map { DJTemplates.displayName(for: $0) }
        let headline = plan?.moveHeadline
            ?? plan?.rationale?.headline
            ?? plan.map { isFallback ? "Clean cut at \(DJFormat.time($0.mixPointSeconds))" : $0.reasoning }

        let phase: DJAutomaticMixDecision.Phase
        if !host.isAutoMixEnabled {
            phase = .off
        } else if case .unavailable = host.mixEngineState {
            phase = .unavailable
        } else if host.mixWindow != nil {
            phase = isFallback ? .cutting : .mixing
        } else if host.upcomingMixTrack == nil || (isAVPlayerHoldingCurrentTrack && !isStreamingBeforeHandover) {
            phase = .waiting
        } else if plan == nil {
            phase = host.isMixEngineLive ? .planning : .preparing
        } else if host.incomingDeck.isReady {
            phase = .armed
        } else {
            phase = .preparing
        }

        let unavailableReason: String?
        if case .unavailable(let reason) = host.mixEngineState { unavailableReason = reason }
        else { unavailableReason = nil }

        return DJAutomaticMixDecision(
            phase: phase,
            profileName: profileName,
            templateName: templateName,
            headline: unavailableReason
                ?? headline
                ?? (host.upcomingMixTrack == nil
                    ? "Nothing queued after this track"
                    : isAVPlayerHoldingCurrentTrack && !isStreamingBeforeHandover ? "Auto Mix starts with the next track" : "Listening for a clean transition point"),
            reasoning: unavailableReason ?? plan?.reasoning,
            incomingTrackId: plan?.incomingTrackId ?? host.upcomingMixTrack?.id,
            mixPointSeconds: plan?.mixPointSeconds,
            transitionSeconds: plan?.transitionSeconds,
            entrySeconds: plan?.entrySeconds,
            score: plan?.rationale?.score,
            isFallback: isFallback,
            canExtend: canExtendMix,
            energyTarget: host.isAutoMixEnabled ? AutoMixEnergy.shared.target : nil,
            selectionReason: plan?.selection?.why
        )
    }

    /// Compatibility projection for the tvOS readouts that still speak the
    /// old bars/techniques vocabulary. The parallel legacy planner is gone;
    /// this derives its answer from the single plan model.
    func legacyTransitionProjection(from: Track, to: Track) -> TransitionPlan? {
        guard host.currentTrack?.id == from.id, let plan = adaptiveMixPlan,
              plan.incomingTrackId == nil || plan.incomingTrackId == to.id else { return nil }
        return TransitionPlan(projecting: plan, fromTrackId: from.id, toTrackId: to.id)
    }

    var canStartMix: Bool {
        guard host.mixWindow == nil, !isCrossfading, host.upcomingMixTrack != nil else { return false }
        if host.isPhantomEnabled {
            return host.currentTrack.flatMap(phantomPlanOrFallback) != nil
        }
        return plannedMixSeconds() != nil
    }

    func startMix() {
        guard canStartMix, let next = host.upcomingMixTrack, let index = host.nextQueueIndex() else { return }

        if host.isPhantomEnabled, let track = host.currentTrack, let plan = phantomPlanOrFallback(for: track) {
            if host.isMixEngineLive, host.incomingDeck.isReady, incomingTrackId == next.id {
                host.phantomActivity = .mixing(plan)
                performLiveTransition(
                    to: next, at: index, over: plan.transitionSeconds,
                    announceAsMix: true, filterAccent: plan.accent, plan: plan
                )
            } else {
                host.phantomActivity = .cutting(reason: "Incoming deck wasn't ready — playing out, then cutting.")
                scheduleWindowThenCut(seconds: plan.transitionSeconds)
            }
            return
        }

        guard let seconds = plannedMixSeconds() else { return }
        if host.isMixEngineLive, host.incomingDeck.isReady, incomingTrackId == next.id {
            performLiveTransition(to: next, at: index, over: seconds, announceAsMix: true)
            return
        }

        scheduleWindowThenCut(seconds: seconds)
    }

    static let extendBars = 8.0

    var canChooseMove: Bool {
        host.isAutoMixEnabled && host.mixWindow == nil && !isCrossfading && host.currentTrack != nil
    }

    func chooseMove(_ plan: PhantomDJEngine.Plan?, forTrackId trackId: String) {
        guard canChooseMove, host.currentTrack?.id == trackId else { return }
        forcedPlans[trackId] = plan
        phantomPlanTasks[trackId]?.cancel()
        phantomPlanTasks[trackId] = nil
        phantomPlanCache[trackId] = nil
        pinnedPlanTrackIds.remove(trackId)
        phantomCutAnnounced = false
        refreshPhantomPlan()
        publishSnapshot()
    }

    var canExtendMix: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_FAKE_MOVE"] == "1" { return true }
        #endif
        guard host.isAutoMixEnabled, host.mixWindow == nil, !isCrossfading,
              let track = host.currentTrack, let plan = phantomPlanCache[track.id] else { return false }
        return extendedMixPoint(for: plan, duration: track.duration) != nil
    }

    func extendMix() {
        guard canExtendMix, let track = host.currentTrack, let plan = phantomPlanCache[track.id],
              let point = extendedMixPoint(for: plan, duration: track.duration) else { return }
        let shifted = plan.shifted(mixPoint: point)
        phantomPlanCache[track.id] = shifted
        pinnedPlanTrackIds.insert(track.id)
        phantomCutAnnounced = false
        host.phantomActivity = .armed(shifted)
        publishSnapshot()
    }

    private func extendedMixPoint(for plan: PhantomDJEngine.Plan, duration: TimeInterval) -> TimeInterval? {
        let grid = plan.outgoingBeatGrid ?? outgoingBeatGrid()
        let bar = grid.map { $0.barDuration } ?? 0
        guard bar > 0 else { return nil }
        var target = plan.mixPointSeconds + Self.extendBars * bar
        if let grid, grid.isPhaseVerified { target = grid.nearestDownbeat(to: target) }
        let latest = duration - plan.transitionSeconds - 1
        guard target <= latest, target > host.currentTime + 1 else { return nil }
        if let outgoing = plan.outgoingFeatures,
           DJPlanValidator.reason(plan.shifted(mixPoint: target), outgoing: outgoing,
                                  incoming: DJPlanFeatureCache.shared.features(for: plan.incomingTrackId), profile: host.djProfile) != nil {
            return nil
        }
        return target
    }

    func completeMoveForSkip() -> Bool {
        guard isCrossfading, let actions = transitionActions else { return false }
        let engine = MixEngine.shared
        let outgoing = actions.outgoing
        let incoming = actions.incoming
        if isJumping {
            actions.cancelTimelineEvents()
            actions.cancel()
            actions.isFinished = true
            engine.cancelAllRamps()
            engine.crossfade(to: outgoing, over: 0)
            engine.pause(deck: incoming)
            engine.unload(deck: incoming)
            engine.resetProcessing(on: outgoing)
            transitionActions = nil
            isCrossfading = false
            isJumping = false
            activeMove = nil
            jumpDeckTrackId = nil
            incomingTrackId = nil
            host.incomingDeck = .idle
            host.mixWindow = nil
            return false
        }
        guard let finish = actions.finish else { return false }
        actions.cancelTimelineEvents()
        actions.isFinished = true
        if !engine[incoming].isPlaying { engine.play(deck: incoming) }
        engine.cancelAllRamps()
        engine.crossfade(to: incoming, over: 0)
        finish()
        return true
    }

    private func scheduleWindowThenCut(seconds: TimeInterval) {
        // "Mix Now" is an immediate command. If the second deck missed its
        // preload deadline, use a short safe cut instead of displaying a fake
        // mix window for the full planned blend and cutting much later.
        let cutSeconds = min(0.25, max(0.08, seconds))
        host.mixWindow = MixWindow(start: host.currentTime, seconds: cutSeconds, isLive: false)
        mixTask?.cancel()
        mixTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(cutSeconds))
            guard !Task.isCancelled, let self else { return }
            self.host.mixWindow = nil
            await self.host.playNext()
        }
    }

    // MARK: - Engine-owned playback

    var isAVPlayerHoldingCurrentTrack: Bool {
        guard let current = host.currentTrack?.id else { return false }
        return !host.isMixEngineLive && armingTrackId != current
    }

    private var isStreamingBeforeHandover: Bool {
        guard let current = host.currentTrack?.id else { return false }
        return handoverTrackId == current && !host.isMixEngineLive
    }

    func isStartingInEngine(_ trackId: String?) -> Bool {
        guard let trackId else { return false }
        return armingTrackId == trackId
    }

    func updatePendingStart(_ seconds: TimeInterval) {
        pendingStartPosition = seconds
    }

    func ownsTrackStart(_ track: Track, exclusiveElsewhere: Bool) -> Bool {
        DJTransitionPlanningPolicy.startsInMixEngine(
            sessionIsEnabled: host.djSessionEnabled || host.requiresMixEngineOutput,
            exclusiveElsewhere: exclusiveElsewhere,
            trackDuration: track.duration,
            isLoadedOnDeck: host.requiresMixEngineOutput || deckHolding(track) != nil,
            fellBackToAVPlayer: avPlayerFallback?.trackId == track.id
        )
    }

    func startsOnStreamFirst(_ track: Track) -> Bool {
        guard !host.requiresMixEngineOutput else { return false }
        return EngineHandoverPolicy.startRoute(
            isOnDeck: deckHolding(track) != nil,
            isCached: MixEngine.shared.hasCachedSource(
                cacheKey: host.mixCacheKey(for: track, collectionId: host.activeCollectionId)
            ),
            isAirPlay: PlatformAudioSession.isAirPlayRoute
        ) == .streamThenHandOver
    }

    func beginStreamingStart(_ track: Track) {
        handoverTask?.cancel()
        handoverTask = nil
        handoverTrackId = track.id
        midTrackHandoverTrackId = nil
    }

    private func startHandoverLoadIfNeeded() {
        guard let track = host.currentTrack, handoverTrackId == track.id,
              handoverTask == nil, !host.isMixEngineLive else { return }
        observeMixEngine()
        let deck = MixEngine.Deck.a
        handoverTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await self.host.resolveMixURL(for: track, collectionId: self.host.activeCollectionId)
                defer { TemporaryPlaintextFile(url: url).release() }
                try Task.checkCancellation()
                guard self.handoverTrackId == track.id else { return }
                let engine = MixEngine.shared
                try await engine.load(
                    url: url,
                    into: deck,
                    trackId: track.id,
                    cacheKey: self.host.mixCacheKey(for: track, collectionId: self.host.activeCollectionId)
                )
                Log.player.notice("[Handover] engine ready for \(track.id, privacy: .public)")
                if let localURL = engine.localFileURL(for: deck) {
                    self.scheduleMixAnalysis(track: track, transcoding: track.mixSource, localFileURL: localURL)
                }
                while !Task.isCancelled, self.handoverTrackId == track.id {
                    switch self.handoverStep(for: track, deck: deck) {
                    case .handOverNow:
                        if await self.handOver(track, on: deck) { return }
                        try await Task.sleep(for: .seconds(1))
                    case .wait:
                        try await Task.sleep(for: .milliseconds(500))
                    case .stayOnStream:
                        self.abandonHandover(track, unloading: deck)
                        return
                    }
                }
            } catch {
                guard self.handoverTrackId == track.id else { return }
                if !PlayerService.isCancellation(error) {
                    Log.player.error("[Handover] engine load failed for \(track.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                self.abandonHandover(track, unloading: nil)
            }
        }
    }

    private func handoverStep(for track: Track, deck: MixEngine.Deck) -> EngineHandoverPolicy.Step {
        let engine = MixEngine.shared
        let player = host.avPlayer
        let duration = engine[deck].duration > 0 ? engine[deck].duration : track.duration
        let position = player?.currentTime().seconds ?? host.currentTime
        let midTrack = midTrackHandoverTrackId == track.id
        return EngineHandoverPolicy.step(
            engineReady: engine[deck].status.isReady && engine[deck].trackId == track.id,
            streamPlaying: player?.timeControlStatus == .playing && host.playbackRequested,
            streamPaused: player != nil && !host.playbackRequested,
            position: position.isFinite ? position : host.currentTime,
            transitionAt: midTrack
                ? EngineHandoverPolicy.latestMidTrackTransition(duration: duration, barSeconds: nil)
                : EngineHandoverPolicy.latestTransition(duration: duration, barSeconds: nil),
            barSeconds: nil,
            leadBars: midTrack ? EngineHandoverPolicy.midTrackLeadBars : EngineHandoverPolicy.leadBars
        )
    }

    private func abandonHandover(_ track: Track, unloading deck: MixEngine.Deck?) {
        guard handoverTrackId == track.id else { return }
        handoverTrackId = nil
        midTrackHandoverTrackId = nil
        handoverTask = nil
        if let deck, !host.isMixEngineLive, MixEngine.shared[deck].trackId == track.id {
            MixEngine.shared.unload(deck: deck)
        }
        publishSnapshot()
    }

    private func handOver(_ track: Track, on deck: MixEngine.Deck) async -> Bool {
        let engine = MixEngine.shared
        guard let player = host.avPlayer, host.currentTrack?.id == track.id,
              engine[deck].status.isReady, engine[deck].trackId == track.id else { return false }
        let gain = host.streamLoudnessGain
        engine.cancelAllRamps()
        engine.masterVolume = 1
        engine.crossfade = deck == .a ? 0 : 1
        engine.resetProcessing(on: deck)

        guard host.playbackRequested else {
            engine.setGain(gain, on: deck)
            let at = player.currentTime().seconds
            engine.seek(deck: deck, to: at.isFinite ? at : host.currentTime)
            finishHandover(track, on: deck, playing: false)
            return true
        }

        engine.setGain(0, on: deck)
        let streamAt = player.currentTime().seconds
        guard streamAt.isFinite else { return false }
        engine.seek(deck: deck, to: streamAt + engine.outputLatencySeconds)
        engine.play(deck: deck)
        guard engine[deck].isPlaying else { return false }

        let stillValid: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.handoverTrackId == track.id && self.host.avPlayer === player
                && self.host.playbackRequested && player.timeControlStatus == .playing
        }
        var offset: TimeInterval?
        for _ in 0..<EngineHandoverPolicy.alignmentAttempts {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, stillValid() else {
                engine.pause(deck: deck)
                return false
            }
            let measured = player.currentTime().seconds - engine.audiblePosition(of: deck)
            offset = measured
            guard let correction = EngineHandoverPolicy.alignmentCorrection(offset: measured) else { break }
            engine.seek(deck: deck, to: engine.livePosition(of: deck) + correction)
        }
        guard let offset, EngineHandoverPolicy.isAligned(offset: offset) else {
            Log.player.notice("[Handover] alignment off by \(Int((offset ?? 0) * 1_000), privacy: .public) ms; retrying")
            engine.pause(deck: deck)
            return false
        }

        let fade = EngineHandoverPolicy.crossfadeSeconds
        let streamVolume = player.volume
        engine.setGain(gain, on: deck, over: fade)
        let clock = ContinuousClock()
        let began = clock.now
        while true {
            let progress = EngineHandoverPolicy.seconds(began.duration(to: clock.now)) / fade
            guard progress < 1 else { break }
            player.volume = streamVolume * Float(EngineHandoverPolicy.crossfadeGains(progress: progress).stream)
            try? await Task.sleep(for: .milliseconds(2))
        }
        player.volume = 0
        Log.player.notice("[Handover] \(track.id, privacy: .public) on the engine, offset \(String(format: "%.1f", offset * 1_000), privacy: .public) ms")
        finishHandover(track, on: deck, playing: true)
        return true
    }

    private func finishHandover(_ track: Track, on deck: MixEngine.Deck, playing: Bool) {
        let engine = MixEngine.shared
        handoverTrackId = nil
        midTrackHandoverTrackId = nil
        handoverTask = nil
        host.teardownAVPlayer(invalidatePipeline: false)
        host.liveDeck = deck
        armedTrackId = track.id
        armingTrackId = nil
        pendingStartPosition = nil
        deckEndHandled = false
        isCrossfading = false
        audibleHold = nil
        host.mixEngineState = .live
        host.clock.duration = engine[deck].duration > 0 ? engine[deck].duration : track.duration
        host.clock.currentTime = PlaybackTimelinePolicy.clampedPosition(
            engine.audiblePosition(of: deck),
            duration: host.clock.duration
        )
        lastMixEngineTransportUpdate = Date()
        host.publishMixEngineTransport(playing ? .playing : .paused, trackID: track.id)
        host.updateNowPlayingMetadata()
        prepareIncomingDeck()
        refreshPhantomPlan()
        refreshCacheWarming()
    }

    func noteTrackStart(_ track: Track) {
        if let fallback = avPlayerFallback, fallback.trackId != track.id { avPlayerFallback = nil }
    }

    func fallbackReason(for track: Track) -> String? {
        guard host.djSessionEnabled, let fallback = avPlayerFallback, fallback.trackId == track.id else { return nil }
        return fallback.reason
    }

    private func deckHolding(_ track: Track) -> MixEngine.Deck? {
        guard mixEngineTouched else { return nil }
        let engine = MixEngine.shared
        return MixEngine.Deck.allCases.first { engine[$0].trackId == track.id && engine[$0].status.isReady }
    }

    func resetForEngineStart(keeping track: Track) {
        cancelSessionWork()
        host.phantomActivity = .idle
        guard mixEngineTouched else { return }
        let engine = MixEngine.shared
        engine.cancelAllRamps()
        let kept = deckHolding(track)
        for deck in MixEngine.Deck.allCases {
            if engine[deck].isPlaying { engine.pause(deck: deck) }
            if deck != kept, engine[deck].status != .empty { engine.unload(deck: deck) }
        }
    }

    func startTrackInEngine(
        _ track: Track,
        at position: TimeInterval,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        observeMixEngine()
        let engine = MixEngine.shared
        let reused = deckHolding(track)
        let deck = reused ?? .a
        armingTrackId = track.id
        armingDeck = deck
        pendingStartPosition = position
        host.mixEngineState = .preparing(reused == nil ? 0 : 1)
        refreshPhantomPlan()

        armTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if reused == nil {
                    let url = try await self.host.resolveMixURL(for: track, collectionId: self.host.activeCollectionId)
                    defer { TemporaryPlaintextFile(url: url).release() }
                    try Task.checkCancellation()
                    guard self.armingTrackId == track.id, isCurrent() else { return }
                    try await engine.load(
                        url: url,
                        into: deck,
                        trackId: track.id,
                        cacheKey: self.host.mixCacheKey(for: track, collectionId: self.host.activeCollectionId)
                    )
                    if let localURL = engine.localFileURL(for: deck) {
                        self.scheduleMixAnalysis(track: track, transcoding: track.mixSource, localFileURL: localURL)
                    }
                }
                guard self.armingTrackId == track.id, isCurrent(),
                      self.host.djSessionEnabled || self.host.requiresMixEngineOutput else { return }
                try self.goLive(on: deck, track: track)
            } catch {
                guard self.armingTrackId == track.id, isCurrent() else { return }
                #if DEBUG
                if ProcessInfo.processInfo.environment["SOUNDING_TV_LOG_MIX_IMPORT"] == "1" {
                    print("[MixImport] start track=\(track.id) source=\(track.mixSource?.debugSummary ?? "none") error=\(String(reflecting: error))")
                }
                #endif
                self.fallBackToAVPlayer(track, error: error)
            }
        }
    }

    private func goLive(on deck: MixEngine.Deck, track: Track) throws {
        let engine = MixEngine.shared
        guard engine[deck].status.isReady, engine[deck].trackId == track.id else {
            throw engine.lastError ?? MixEngineError.deckEmpty
        }
        let duration = engine[deck].duration > 0 ? engine[deck].duration : track.duration
        let start = PlaybackTimelinePolicy.clampedPosition(pendingStartPosition ?? 0, duration: duration)

        engine.cancelAllRamps()
        engine.masterVolume = 1
        engine.crossfade = deck == .a ? 0 : 1
        engine.resetProcessing(on: deck)
        host.applyLoudnessNormalization(for: track, deck: deck)
        engine.seek(deck: deck, to: start)

        let shouldPlay = host.playbackRequested
        if shouldPlay {
            engine.play(deck: deck)
            guard engine[deck].isPlaying else {
                throw engine.lastError ?? MixEngineError.playbackStartFailed("the deck did not start")
            }
        }

        host.liveDeck = deck
        armedTrackId = track.id
        armingTrackId = nil
        armTask = nil
        pendingStartPosition = nil
        deckEndHandled = false
        isCrossfading = false
        audibleHold = shouldPlay ? start : nil

        host.mixEngineState = .live
        host.clock.duration = duration
        host.clock.currentTime = start
        lastMixEngineTransportUpdate = Date()
        host.publishMixEngineTransport(shouldPlay ? .buffering : .paused, trackID: track.id)
        host.updateNowPlayingMetadata()
        engineRetry = nil
        engineSkipStreak = 0
        prepareIncomingDeck()
        refreshPhantomPlan()
        refreshCacheWarming()
    }

    private func fallBackToAVPlayer(_ track: Track, error: Error) {
        let retries = engineRetry?.trackId == track.id ? engineRetry?.attempts ?? 0 : 0
        let action = EngineLoadFailurePolicy.action(
            requiresEngineOutput: host.requiresMixEngineOutput,
            retriesSoFar: retries,
            consecutiveSkips: engineSkipStreak,
            hasNextTrack: host.nextQueueIndex() != nil
        )
        switch action {
        case .fallBackToAVPlayer:
            handOverFailedTrackToAVPlayer(track, error: error)
        case .retry(let delay):
            engineRetry = (track.id, retries + 1)
            let position = pendingStartPosition ?? host.currentTime
            let intent: PlayerService.LoadTransportIntent = host.playbackRequested ? .play : .pause
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.host.currentTrack?.id == track.id, self.host.requiresMixEngineOutput else { return }
                await self.host.loadAndPlay(track: track, startPosition: position, transportIntent: intent)
            }
        case .skipToNext:
            engineRetry = nil
            engineSkipStreak += 1
            Task { @MainActor [weak self] in
                guard let self, self.host.currentTrack?.id == track.id else { return }
                await self.host.playNext()
            }
        case .stop:
            engineRetry = nil
            engineSkipStreak = 0
            host.mixEngineState = .unavailable(PlayerService.describeMixFailure(error))
            host.pause()
        }
    }

    private func handOverFailedTrackToAVPlayer(_ track: Track, error: Error) {
        avPlayerFallback = (track.id, PlayerService.describeMixFailure(error))
        let position = pendingStartPosition ?? host.currentTime
        let intent: PlayerService.LoadTransportIntent = host.playbackRequested ? .play : .pause
        endMixSession()
        Task { @MainActor [weak self] in
            await self?.host.loadAndPlay(track: track, startPosition: position, transportIntent: intent)
        }
    }

    // MARK: - Session arming

    func armMixSession() {
        guard host.djSessionEnabled else { return }
        startHandoverLoadIfNeeded()
        refreshCacheWarming()
        guard host.currentTrack != nil else {
            if armingTrackId == nil { host.mixEngineState = .off }
            return
        }
        if host.isMixEngineLive {
            refreshPhantomPlan()
            prepareIncomingDeck()
            return
        }
        guard !isStartingInEngine(host.currentTrack?.id) else { return }
        if case .unavailable = host.mixEngineState {} else { host.mixEngineState = .off }
        beginMidTrackHandoverIfNeeded()
        refreshPhantomPlan()
    }

    private func beginMidTrackHandoverIfNeeded() {
        guard let track = host.currentTrack, handoverTrackId == nil, armingTrackId == nil,
              host.avPlayer != nil, host.currentTrackBelongsInMixEngine,
              avPlayerFallback?.trackId != track.id else { return }
        guard EngineHandoverPolicy.midTrackHandover(
            position: host.currentTime,
            duration: track.duration
        ) else { return }
        handoverTrackId = track.id
        midTrackHandoverTrackId = track.id
        Log.player.notice("[Handover] Auto Mix turned on mid-track; moving \(track.id, privacy: .public) to the engine")
        startHandoverLoadIfNeeded()
    }

    func autoMixDidTurnOff() {
        cancelPerformance()
        guard !isCrossfading, host.mixWindow == nil else { return }
        mixTask?.cancel()
        mixTask = nil
        if host.isMixEngineLive { releaseDeadlineLoop(on: host.liveDeck) }
        pinnedPlanTrackIds.removeAll()
        phantomCutAnnounced = false
        host.phantomActivity = .idle
        AutoMixFeedbackStore.shared.dismiss()
    }

    func refreshMixSessionForQueue() {
        guard host.djSessionEnabled else { return }
        refreshCacheWarming()
        if host.isMixEngineLive {
            prepareIncomingDeck()
        } else {
            armMixSession()
        }
    }

    func prepareIncomingDeck() {
        guard host.djSessionEnabled, host.isMixEngineLive, !isCrossfading, jumpDeckTrackId == nil else { return }

        guard let next = host.upcomingMixTrack else {
            incomingTask?.cancel()
            incomingTask = nil
            if incomingTrackId != nil {
                MixEngine.shared.unload(deck: host.liveDeck.other)
                incomingTrackId = nil
            }
            host.incomingDeck = .idle
            return
        }
        if let currentId = host.currentTrack?.id,
           let cached = phantomPlanCache[currentId],
           cached.incomingTrackId != nil,
           cached.incomingTrackId != next.id {
            invalidatePhantomPlan(for: currentId)
        } else if let previous = incomingTrackId, previous != next.id,
                  let currentId = host.currentTrack?.id {
            invalidatePhantomPlan(for: currentId)
        }
        if incomingTrackId == next.id {
            if host.isAutoMixEnabled, MixEngine.shared[host.liveDeck.other].status.isReady {
                MixEngine.shared.resetProcessing(on: host.liveDeck.other, killLows: true)
                host.applyLoudnessNormalization(for: next, deck: host.liveDeck.other)
            }
            if let grid = adaptiveMixPlan?.incomingBeatGrid {
                MixEngine.shared.setBeatGrid(grid, for: host.liveDeck.other)
            }
            if let plan = adaptiveMixPlan, plan.incomingTrackId == next.id {
                repositionIncomingDeckIfIdle(with: plan)
            }
            return
        }

        incomingTask?.cancel()
        incomingTrackId = next.id
        host.incomingDeck = .loading(0)

        let deck = host.liveDeck.other
        incomingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await host.resolveMixURL(for: next, collectionId: host.activeCollectionId)
                defer { TemporaryPlaintextFile(url: url).release() }
                try Task.checkCancellation()
                guard self.incomingTrackId == next.id else { return }

                let engine = MixEngine.shared
                try await engine.load(
                    url: url,
                    into: deck,
                    trackId: next.id,
                    cacheKey: host.mixCacheKey(for: next, collectionId: host.activeCollectionId)
                )
                guard self.incomingTrackId == next.id else {
                    engine.unload(deck: deck)
                    return
                }
                if let localURL = engine.localFileURL(for: deck) {
                    scheduleMixAnalysis(track: next, transcoding: next.mixSource, localFileURL: localURL)
                }

                engine.resetProcessing(on: deck, killLows: true)
                self.host.applyLoudnessNormalization(for: next, deck: deck)
                engine.seek(deck: deck, to: self.entryPositionForIncomingDeck(next, on: deck))
                self.host.incomingDeck = .ready
                self.precomputePhantomPlanIfNeeded(for: next)
                self.reconsiderCurrentPlanIfUseful()
            } catch {
                if PlayerService.isCancellation(error) { return }
                guard self.incomingTrackId == next.id else { return }
                self.host.incomingDeck = .failed(PlayerService.describeMixFailure(error))
            }
        }
    }

    private func scheduleMixAnalysis(track: Track, transcoding: Transcoding?, localFileURL: URL) {
        AutomaticAnalysisScheduler.shared.schedule(
            track,
            trigger: .deckLoaded,
            localFileURL: localFileURL,
            transcoding: transcoding
        ) { [weak self] state in
            guard state == .complete else { return }
            self?.reconsiderCurrentPlanIfUseful()
        }
    }

    private func upcomingWarmWindow() -> [Track] {
        guard let next = host.upcomingMixTrack else { return [] }
        var out = [next]
        if let index = host.queue.firstIndex(of: next), index + 1 < host.queue.count {
            out.append(host.queue[index + 1])
        }
        return out
    }

    func refreshCacheWarming() {
        guard host.djSessionEnabled else {
            for task in warmTasks.values { task.cancel() }
            warmTasks.removeAll()
            return
        }
        let window = upcomingWarmWindow()
        let windowIds = Set(window.map(\.id))
        for (trackId, task) in warmTasks where !windowIds.contains(trackId) {
            task.cancel()
            warmTasks[trackId] = nil
        }
        let now = Date()
        warmFailures = warmFailures.filter { now.timeIntervalSince($0.value) < Self.warmRetryInterval }
        for track in window {
            guard warmTasks[track.id] == nil, warmFailures[track.id] == nil else { continue }
            guard warmTasks.count < Self.maxConcurrentWarmTasks else { break }
            let trackId = track.id
            warmTasks[trackId] = Task(priority: .utility) { @MainActor [weak self] in
                guard let self else { return }
                defer { self.warmTasks[trackId] = nil }
                guard let url = try? await self.host.resolveMixURL(
                    for: track, collectionId: self.host.activeCollectionId
                ) else {
                    if !Task.isCancelled { self.warmFailures[trackId] = Date() }
                    return
                }
                defer { TemporaryPlaintextFile(url: url).release() }
                guard !Task.isCancelled else { return }
                let cacheKey = self.host.mixCacheKey(for: track, collectionId: self.host.activeCollectionId)
                await MixEngine.shared.warmCache(remoteURL: url, cacheKey: cacheKey)
            }
        }
    }

    private func cachedPlanForIncoming(_ trackId: String) -> PhantomDJEngine.Plan? {
        guard let currentId = host.currentTrack?.id,
              let plan = phantomPlanCache[currentId],
              plan.incomingTrackId == trackId else { return nil }
        return plan
    }

    private func entryPositionForIncomingDeck(_ track: Track, on deck: MixEngine.Deck) -> TimeInterval {
        guard let plan = cachedPlanForIncoming(track.id) else { return 0 }
        let engine = MixEngine.shared
        let duration = engine[deck].duration > 0 ? engine[deck].duration : track.duration
        return PlaybackTimelinePolicy.transitionStartPosition(
            plan.entrySeconds,
            duration: duration,
            transitionSeconds: plan.transitionSeconds
        )
    }

    private func repositionIncomingDeckIfIdle(with plan: PhantomDJEngine.Plan) {
        guard host.isMixEngineLive, !isCrossfading, host.mixWindow == nil,
              host.incomingDeck.isReady else { return }
        let deck = host.liveDeck.other
        let engine = MixEngine.shared
        let duration = engine[deck].duration > 0 ? engine[deck].duration : (host.upcomingMixTrack?.duration ?? 0)
        guard duration > 0 else { return }
        let entry = PlaybackTimelinePolicy.transitionStartPosition(
            plan.entrySeconds,
            duration: duration,
            transitionSeconds: plan.transitionSeconds
        )
        guard abs(engine[deck].position - entry) > 0.05 else { return }
        engine.seek(deck: deck, to: entry)
    }

    // MARK: - Planning

    func refreshPhantomPlan() {
        phantomCutAnnounced = false
        guard DJTransitionPlanningPolicy.shouldPlan(
            isEnabled: host.isPhantomEnabled,
            sessionIsEnabled: host.djSessionEnabled,
            hasCurrentTrack: host.currentTrack != nil,
            hasUpcomingTrack: host.upcomingMixTrack != nil
        ), !isAVPlayerHoldingCurrentTrack, let track = host.currentTrack else {
            host.phantomActivity = .idle
            return
        }
        if let forced = forcedPlans[track.id], phantomPlanCache[track.id] != forced {
            installForcedPlan(forced, for: track.id)
        }
        if let cached = phantomPlanCache[track.id] {
            host.phantomActivity = .armed(cached)
            schedulePerformanceIfNeeded()
            return
        }
        host.phantomActivity = .idle
        precomputePhantomPlanIfNeeded(for: track, publishForCurrentTrack: true)
    }

    private func installForcedPlan(_ plan: PhantomDJEngine.Plan, for trackId: String) {
        phantomPlanTasks[trackId]?.cancel()
        phantomPlanTasks[trackId] = nil
        phantomPlanCache[trackId] = plan
        pinnedPlanTrackIds.insert(trackId)
        guard host.currentTrack?.id == trackId, host.isMixEngineLive else { return }
        MixEngine.shared.setBeatGrid(plan.outgoingBeatGrid, for: host.liveDeck)
        if plan.incomingTrackId == incomingTrackId {
            MixEngine.shared.setBeatGrid(plan.incomingBeatGrid, for: host.liveDeck.other)
            repositionIncomingDeckIfIdle(with: plan)
        }
    }

    nonisolated static func currentBeatGrid(for track: Track) async -> BeatGrid? {
        await features(for: track, legacyAnalysis: nil, userCues: []).beatGrid
    }

    nonisolated static func planningFeatures(for track: Track) async -> TrackFeatures {
        await features(for: track, legacyAnalysis: nil, userCues: [])
    }

    private func invalidatePhantomPlan(for trackId: String) {
        phantomPlanTasks[trackId]?.cancel()
        phantomPlanTasks[trackId] = nil
        phantomPlanCache[trackId] = nil
        if host.currentTrack?.id == trackId {
            host.phantomActivity = .idle
            refreshPhantomPlan()
        }
    }

    /// Analysis can improve after the first envelope-only decision. Keep
    /// reconsidering while the transition is still far enough away, then
    /// commit so the loaded deck and UI cannot churn at the last moment.
    private func reconsiderCurrentPlanIfUseful() {
        guard host.isAutoMixEnabled, let track = host.currentTrack,
              host.mixWindow == nil, !isCrossfading, !pinnedPlanTrackIds.contains(track.id) else { return }
        if let plan = adaptiveMixPlan,
           host.currentTime >= max(0, plan.mixPointSeconds - 45) {
            return
        }
        invalidatePhantomPlan(for: track.id)
    }

    private func observeAnalysisStates() {
        host.transitionService.$states
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] states in
                guard let self else { return }
                let relevantIds = Set([self.host.currentTrack?.id, self.host.upcomingMixTrack?.id].compactMap { $0 })
                let relevant = states.filter { relevantIds.contains($0.key) }
                guard relevant != self.lastPlannerAnalysisStates else { return }
                self.lastPlannerAnalysisStates = relevant
                let gainedMeasuredAnalysis = relevant.values.contains {
                    if case .analyzed(let analysis) = $0 { return !analysis.isEstimated }
                    return false
                }
                if gainedMeasuredAnalysis { self.reconsiderCurrentPlanIfUseful() }
            }
            .store(in: &cancellables)
    }

    private func planningProfile(for profile: DJProfile) -> DJProfile {
        let settings = SettingsStore.shared
        let reorder = DJFlowSelector.mayReorder(
            keepQueueOrder: settings.djKeepQueueOrder,
            explicitOrders: host.autoMixExplicitQueueOrders
        )
        return profile
            .applying(queueOrder: reorder ? .mayReorder : .preserve)
            .applying(blend: settings.djBlend)
    }

    private func precomputePhantomPlanIfNeeded(
        for track: Track,
        publishForCurrentTrack: Bool = false
    ) {
        guard let baseProfile = host.djProfile, phantomPlanCache[track.id] == nil else { return }
        guard phantomPlanTasks[track.id] == nil else { return }

        let trackId = track.id
        let profile = planningProfile(for: baseProfile)
        let candidates = candidateTracks(after: track, limit: min(DJFlowSelector.maxCandidates, profile.lookaheadCandidates))
        let history = currentSetHistory()
        let userTransitionSeconds: Double? = nil
        let earliestExit = earliestExit(for: track)

        phantomPlanTasks[trackId] = Task { @MainActor [weak self] in
            guard let self else { return }
            let legacyAnalyses: [String: TrackAnalysis] = Dictionary(uniqueKeysWithValues: ([track] + candidates).compactMap { candidate -> (String, TrackAnalysis)? in
                guard case .analyzed(let analysis) = self.host.transitionService.state(for: candidate.id) else { return nil }
                return (candidate.id, analysis)
            })
            let userCues = await self.host.cues.cues(forTracks: ([track] + candidates).map(\.id))
            let plan = await Self.computePhantomPlan(
                for: track,
                candidates: candidates,
                profile: profile,
                history: history,
                legacyAnalyses: legacyAnalyses,
                userCues: userCues,
                userTransitionSeconds: userTransitionSeconds,
                earliestExit: earliestExit
            )
            self.phantomPlanTasks[trackId] = nil
            guard !Task.isCancelled, self.host.djProfile == baseProfile,
                  self.phantomPlanCache[trackId] == nil, let plan else { return }
            if profile.mayReorderQueue == false,
               plan.incomingTrackId != nil,
               plan.incomingTrackId != self.host.upcomingMixTrack?.id {
                return
            }
            if profile.mayReorderQueue,
               let incomingTrackId = plan.incomingTrackId,
               incomingTrackId != self.host.upcomingMixTrack?.id {
                self.host.promoteToUpcoming(trackId: incomingTrackId)
            }
            let titled = plan.titled(plan.incomingTrackId.flatMap { id in self.host.queue.first { $0.id == id }?.title })
            self.phantomPlanCache[trackId] = titled
            self.precomputeJumpIfUseful(for: track, profile: baseProfile)
            if self.host.currentTrack?.id == trackId, self.host.isMixEngineLive {
                self.schedulePerformanceIfNeeded()
                MixEngine.shared.setBeatGrid(titled.outgoingBeatGrid, for: self.host.liveDeck)
                if titled.incomingTrackId == self.incomingTrackId {
                    MixEngine.shared.setBeatGrid(titled.incomingBeatGrid, for: self.host.liveDeck.other)
                    self.repositionIncomingDeckIfIdle(with: titled)
                }
            }
            if publishForCurrentTrack, self.host.currentTrack?.id == trackId,
               self.host.djSessionEnabled, self.host.upcomingMixTrack != nil {
                self.host.phantomActivity = .armed(titled)
            }
        }
    }

    nonisolated static let midTrackPlanningLead: TimeInterval = 8

    private func earliestExit(for track: Track) -> TimeInterval {
        guard host.currentTrack?.id == track.id else { return 0 }
        return Self.earliestExit(position: host.currentTime)
    }

    nonisolated static func earliestExit(position: TimeInterval) -> TimeInterval {
        guard position.isFinite, position > 1 else { return 0 }
        return position + midTrackPlanningLead
    }

    // MARK: - Mid-track performance

    private func schedulePerformanceIfNeeded() {
        guard host.isAutoMixEnabled, host.isMixEngineLive, !isCrossfading, host.mixWindow == nil,
              let track = host.currentTrack, let plan = phantomPlanCache[track.id] else { return }
        let engine = MixEngine.shared
        let deck = host.liveDeck
        let window = plan.mixPointSeconds...max(plan.mixPointSeconds, plan.mixEndSeconds)
        if performanceTrackId == track.id {
            engine.cancelPerformance(on: deck, overlapping: window)
            return
        }
        let level = SettingsStore.shared.djPerformanceLevel
        guard level != .off, let features = plan.outgoingFeatures else {
            cancelPerformance()
            return
        }
        let start = max(features.contentStart, engine.livePosition(of: deck) + Self.performanceStartLead)
        guard plan.mixPointSeconds > start else { return }
        let moves = MixEngine.planPerformance(
            for: features,
            level: level,
            playable: start...plan.mixPointSeconds,
            avoiding: [window],
            allowed: SettingsStore.shared.djMoveStyle.allowedMidTrackMoves
        )
        engine.schedulePerformance(moves, track: MixPerformanceTrack(features: features), on: deck)
        performanceTrackId = track.id
    }

    private func cancelPerformance() {
        guard performanceTrackId != nil else { return }
        performanceTrackId = nil
        guard mixEngineTouched else { return }
        for deck in MixEngine.Deck.allCases { MixEngine.shared.cancelPerformance(on: deck) }
    }

    private func candidateTracks(after track: Track, limit: Int) -> [Track] {
        guard let index = host.queue.firstIndex(of: track) else { return host.upcomingMixTrack.map { [$0] } ?? [] }
        let queuedEnd = host.currentIndex + host.playingNextCount
        if index >= host.currentIndex, index < queuedEnd { return [host.queue[index + 1]] }
        var out: [Track] = []
        var cursor = index + 1
        while out.count < max(1, limit), cursor < host.queue.count {
            out.append(host.queue[cursor])
            cursor += 1
        }
        if out.isEmpty, host.repeatMode == .all, !host.queue.isEmpty, host.queue[0].id != track.id {
            out.append(host.queue[0])
        }
        return out
    }

    private func notePlayed(_ track: Track?) {
        guard let track, playedLog.last?.id != track.id else { return }
        playedLog.append((track.id, track.user.username))
        if playedLog.count > Self.playedLogLimit {
            playedLog.removeFirst(playedLog.count - Self.playedLogLimit)
        }
    }

    private func currentSetHistory() -> SetHistory {
        let currentId = host.currentTrack?.id
        let played = playedLog.reversed().filter { $0.id != currentId }
        let queueHistory = (0..<host.currentIndex).reversed().map { (id: host.queue[$0].id, artist: host.queue[$0].user.username) }
        let recent = Self.recentPlays(log: played, queueHistory: queueHistory)
        let hourAgo = Date().addingTimeInterval(-3600)
        let target = AutoMixEnergy.shared.target
        lastEnergyTarget = target
        var history = SetHistory(
            recentTemplates: recentTemplates,
            recentArtists: Array(recent.map(\.artist).prefix(6)),
            recentTrackIds: Array(recent.map(\.id).prefix(DJFlowSelector.trackCooldown)),
            recentMoves: performedMoves.reversed().prefix(8).map(\.kind),
            loopsThisHour: performedMoves.filter { $0.kind == .loopRoll && $0.at > hourAgo }.count,
            energyTarget: target
        )
        history.learned = AutoMixFeedbackStore.shared.priors
        history.style = SettingsStore.shared.djMoveStyle
        history.transitionNet = AutoMixNetExperiment.model()
        history.setPriors = LearnedSetPriors.enabled()
        if host.isAutoMixEnabled, let active = AutoMixIntentStore.shared.current {
            history.intent = active.intent
            history.setMinute = Date().timeIntervalSince(active.startedAt) / 60
        }
        return history
    }

    nonisolated static func recentPlays(
        log: [(id: String, artist: String)],
        queueHistory: [(id: String, artist: String)]
    ) -> [(id: String, artist: String)] {
        var seen = Set<String>()
        var out: [(id: String, artist: String)] = []
        for entry in log + queueHistory where seen.insert(entry.id).inserted {
            out.append(entry)
        }
        return out
    }

    // MARK: - Jumps within a track or set

    private func precomputeJumpIfUseful(for track: Track, profile: DJProfile) {
        guard profile.allowsJumps, track.duration >= DJJumpPlanner.minimumTrackSeconds,
              jumpPlans[track.id] == nil, jumpPlanTasks[track.id] == nil,
              host.currentTrack?.id == track.id else { return }
        let trackId = track.id
        let position = host.currentTime
        let history = currentSetHistory()
        jumpPlanTasks[trackId] = Task { @MainActor [weak self] in
            guard let self else { return }
            let legacy: TrackAnalysis?
            if case .analyzed(let analysis) = self.host.transitionService.state(for: trackId) { legacy = analysis } else { legacy = nil }
            let cues = await self.host.cues.cues(forTracks: [trackId])[trackId] ?? []
            let features = await Self.features(for: track, legacyAnalysis: legacy, userCues: cues)
            let candidate = DJJumpPlanner.propose(track: features, from: position, profile: profile, history: history)
            self.jumpPlanTasks[trackId] = nil
            guard !Task.isCancelled, self.host.djProfile == profile, let candidate else { return }
            self.jumpPlans[trackId] = candidate.executablePlan(features)
            self.publishSnapshot()
        }
    }

    private func eligibleJump(for track: Track) -> PhantomDJEngine.Plan? {
        guard host.isAutoMixEnabled, host.djProfile?.allowsJumps == true,
              let jump = jumpPlans[track.id], host.currentTime < jump.mixPointSeconds + 1 else { return nil }
        if let next = phantomPlanCache[track.id], host.upcomingMixTrack != nil {
            let landing = jump.entrySeconds + jump.transitionSeconds
            guard landing + Self.jumpClearanceSeconds < next.mixPointSeconds,
                  jump.mixPointSeconds + jump.transitionSeconds + Self.jumpClearanceSeconds < next.mixPointSeconds else { return nil }
        }
        return jump
    }

    private func prepareJumpDeck(for track: Track, plan: PhantomDJEngine.Plan) {
        guard jumpDeckTrackId == nil, !isCrossfading else { return }
        incomingTask?.cancel()
        incomingTask = nil
        jumpTask?.cancel()
        incomingTrackId = nil
        jumpDeckTrackId = track.id
        host.incomingDeck = .loading(0)
        let deck = host.liveDeck.other
        jumpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await self.host.resolveMixURL(for: track, collectionId: self.host.activeCollectionId)
                defer { TemporaryPlaintextFile(url: url).release() }
                try Task.checkCancellation()
                guard self.jumpDeckTrackId == track.id else { return }
                let engine = MixEngine.shared
                try await engine.load(
                    url: url,
                    into: deck,
                    trackId: track.id,
                    cacheKey: self.host.mixCacheKey(for: track, collectionId: self.host.activeCollectionId)
                )
                guard self.jumpDeckTrackId == track.id else { return }
                engine.resetProcessing(on: deck, killLows: true)
                self.host.applyLoudnessNormalization(for: track, deck: deck)
                engine.setBeatGrid(plan.incomingBeatGrid, for: deck)
                engine.seek(deck: deck, to: plan.entrySeconds)
                self.host.incomingDeck = .ready
            } catch {
                guard self.jumpDeckTrackId == track.id else { return }
                self.cancelJump(for: track.id)
            }
        }
    }

    private func cancelJump(for trackId: String) {
        jumpTask?.cancel()
        jumpTask = nil
        jumpPlans[trackId] = nil
        if jumpDeckTrackId != nil {
            MixEngine.shared.unload(deck: host.liveDeck.other)
            jumpDeckTrackId = nil
            host.incomingDeck = .idle
        }
        prepareIncomingDeck()
    }

    private func updateJumpTick(track: Track, live: MixEngine.DeckState) -> Bool {
        guard let jump = eligibleJump(for: track) else {
            if jumpDeckTrackId == track.id, !isCrossfading { cancelJump(for: track.id) }
            return false
        }
        guard live.position >= jump.mixPointSeconds - Self.jumpPreloadSeconds else { return false }
        if jumpDeckTrackId != track.id {
            prepareJumpDeck(for: track, plan: jump)
            return true
        }
        guard host.incomingDeck.isReady, live.position >= jump.mixPointSeconds - Self.transitionSchedulingLead else { return true }
        isJumping = true
        host.phantomActivity = .mixing(jump)
        performLiveTransition(
            to: track, at: host.currentIndex, over: jump.transitionSeconds,
            announceAsMix: true, plan: jump, startAtPlannedBoundary: true
        )
        if !isCrossfading { isJumping = false }
        return true
    }

    nonisolated static func computePhantomPlan(
        for track: Track,
        candidates: [Track],
        profile: DJProfile,
        history: SetHistory,
        legacyAnalyses: [String: TrackAnalysis],
        userCues: [String: [CuePoint]],
        userTransitionSeconds: Double? = nil,
        earliestExit: TimeInterval = 0
    ) async -> PhantomDJEngine.Plan? {
        let outgoing = await features(
            for: track,
            legacyAnalysis: legacyAnalyses[track.id],
            userCues: userCues[track.id] ?? []
        )

        guard !candidates.isEmpty else {
            return envelopeOnlyPlan(outgoing, earliestExit: earliestExit)
        }
        var candidateFeatures: [TrackFeatures] = []
        for candidate in candidates {
            candidateFeatures.append(await features(
                for: candidate,
                legacyAnalysis: legacyAnalyses[candidate.id],
                userCues: userCues[candidate.id] ?? []
            ))
        }

        return decideFlowPlan(
            outgoing: outgoing,
            candidates: candidateFeatures,
            profile: profile,
            history: history,
            userTransitionSeconds: userTransitionSeconds,
            earliestExit: earliestExit
        )
    }

    nonisolated static func decideFlowPlan(
        outgoing: TrackFeatures,
        candidates: [TrackFeatures],
        profile: DJProfile,
        history: SetHistory,
        userTransitionSeconds: Double?,
        earliestExit: TimeInterval = 0
    ) -> PhantomDJEngine.Plan? {
        let choice = DJFlowSelector.choose(
            outgoing: outgoing,
            candidates: candidates,
            history: history,
            profile: profile,
            keepQueueOrder: !profile.mayReorderQueue
        )
        let chosen = choice.flatMap { choice in candidates.first { $0.trackId == choice.trackId } }
        let plan = decidePlan(
            outgoing: outgoing,
            candidates: chosen.map { [$0] } ?? candidates,
            profile: profile,
            history: history,
            userTransitionSeconds: userTransitionSeconds,
            earliestExit: earliestExit
        )
        return plan?.selected(choice)
    }

    nonisolated static func decidePlan(
        outgoing fullOutgoing: TrackFeatures,
        candidates fullCandidates: [TrackFeatures],
        profile: DJProfile,
        history: SetHistory,
        userTransitionSeconds: Double?,
        earliestExit: TimeInterval = 0
    ) -> PhantomDJEngine.Plan? {
        MixVocalMap.shared.record(fullOutgoing)
        let outgoing = fullOutgoing.planningView(
            earliestExit: earliestExit,
            playable: TrackTrimStore.effectiveRange(for: fullOutgoing.trackId, duration: fullOutgoing.duration)
        )
        let candidates = fullCandidates.map {
            $0.entryView(playable: TrackTrimStore.effectiveRange(for: $0.trackId, duration: $0.duration))
        }
        MixVocalMap.shared.recordContentEnd(outgoing.duration, for: outgoing.trackId)
        let decided = decideTrimmedPlan(
            outgoing: outgoing, candidates: candidates, profile: profile,
            history: history, userTransitionSeconds: userTransitionSeconds
        )
        guard var plan = decided else { return nil }
        plan.outgoingFeatures = outgoing
        DJPlanFeatureCache.shared.remember(outgoing)
        candidates.forEach(DJPlanFeatureCache.shared.remember)
        if let incoming = candidates.first(where: { $0.trackId == plan.incomingTrackId }) ?? candidates.first {
            plan.entryNote = incoming.intro?.note(entry: plan.entrySeconds)
                ?? (plan.templateId == DJTemplates.cutOnTheOne && plan.entrySeconds - incoming.contentStart >= DJIntro.minimumSkipSeconds
                    ? "Cutting in \(Int(plan.entrySeconds.rounded())) s in, on the first full phrase" : nil)
            plan.feedback = AutoMixTransitionFeatures(plan: plan, outgoing: outgoing, incoming: incoming)
        }
        return plan
    }

    private nonisolated static func decideTrimmedPlan(
        outgoing: TrackFeatures,
        candidates: [TrackFeatures],
        profile: DJProfile,
        history: SetHistory,
        userTransitionSeconds: Double?
    ) -> PhantomDJEngine.Plan? {
        let inputs = PhantomDJEngine.PlanningInputs(
            outgoing: outgoing,
            candidates: candidates,
            profile: profile,
            history: history,
            capabilities: .fullMixEngine,
            seedComponents: [profile.id.rawValue, outgoing.trackId, String(candidates.count)],
            userTransitionSeconds: userTransitionSeconds
        )
        let (decided, result, _) = PhantomDJEngine.validatedPlan(inputs) { chosen in
            var plan = chosen
            let incoming = candidates.first(where: { $0.trackId == plan.incomingTrackId }) ?? candidates.first
            if let incoming, !DJMoveSupport.vocalsMeasured(outgoing, incoming) {
                plan.incomingMidCutDecibels = DJMoveSupport.unmeasuredVocalMidCutDecibels
            }
            guard plan.templateId == DJTemplates.cutOnTheOne else { return plan }
            plan = pullCutBack(plan, outgoing: outgoing)
            if let phrase = DJPhraseCut.plan(
                outgoing: outgoing, incoming: incoming, incomingTrackId: plan.incomingTrackId, profile: profile, reason: plan.reasoning,
                near: DJPhraseCut.isEndOfTrack(plan, outgoing: outgoing) ? nil : plan.mixPointSeconds
            ) {
                return phrase.carryingExtras(from: plan)
            }
            if let incoming {
                let entry = DJIntro.cutEntry(incoming, from: plan.entrySeconds)
                if abs(entry - plan.entrySeconds) > 0.01 { plan = plan.entering(at: entry) }
            }
            return plan
        }
        if let decided { return decided }
        if let phrase = DJPhraseCut.plan(
            outgoing: outgoing, incoming: candidates.first, incomingTrackId: candidates.first?.trackId, profile: profile,
            reason: PhantomDJEngine.refusalReasoning(result, profile: profile)
        ) {
            return phrase
        }

        let cut = PhantomDJEngine.cleanCutFallbackPlan(
            outgoingDuration: outgoing.duration,
            incomingTrackId: candidates.first?.trackId,
            profile: profile,
            envelope: outgoing.envelope,
            reasoning: PhantomDJEngine.refusalReasoning(result, profile: profile),
        )
        return cut.map { plan in
            let pulled = pullCutBack(plan, outgoing: outgoing)
            guard let incoming = candidates.first, incoming.contentStart > pulled.entrySeconds + 0.01 else { return pulled }
            return pulled.entering(at: DJIntro.cutEntry(incoming, from: incoming.contentStart))
        }
    }

    nonisolated static let cutBodyDecibels: Float = 9

    nonisolated static func lastFullBarEnd(_ track: TrackFeatures) -> TimeInterval? {
        guard let profile = track.barProfile, track.barStarts.count == profile.level.count, profile.level.count >= 8 else { return nil }
        let levels = profile.level.filter { $0 > -89 }.sorted()
        guard levels.count >= 8 else { return nil }
        let body = levels[min(levels.count - 1, Int(Double(levels.count) * 0.75))]
        guard let last = profile.level.lastIndex(where: { $0 >= body - cutBodyDecibels }), last + 1 < track.barStarts.count else { return nil }
        return track.barStarts[last + 1]
    }

    nonisolated static func pullCutBack(_ cut: PhantomDJEngine.Plan, outgoing: TrackFeatures) -> PhantomDJEngine.Plan {
        guard let grid = outgoing.beatGrid else { return cut }
        let candidates = [outgoing.latestMixStart, lastFullBarEnd(outgoing) ?? outgoing.contentBounds.lastBodySeconds(outgoing)]
        guard let latest = candidates.compactMap({ $0 }).min(), cut.mixPointSeconds > latest + 0.05 else { return cut }
        var at = grid.nearestDownbeat(to: latest)
        if at > latest + 0.05 { at -= grid.barDuration }
        guard at >= max(outgoing.earliestExitSeconds, 0) else { return cut }
        if let payoff = DJMoveRails.energyPayoffEnd(outgoing), at < payoff - grid.beatPeriod, cut.mixPointSeconds >= payoff { at = payoff }
        return cut.shifted(mixPoint: at)
    }

    private nonisolated static func envelopeOnlyPlan(_ full: TrackFeatures, earliestExit: TimeInterval = 0) -> PhantomDJEngine.Plan? {
        let features = full.planningView(earliestExit: earliestExit)
        guard !features.envelope.isEmpty else {
            return PhantomDJEngine.fallbackPlan(outgoingDuration: features.duration)
        }
        return PhantomDJEngine.plan(outgoingDuration: features.duration, envelope: features.envelope)
            ?? PhantomDJEngine.fallbackPlan(outgoingDuration: features.duration)
    }

    private nonisolated static func features(
        for track: Track,
        legacyAnalysis: TrackAnalysis?,
        userCues: [CuePoint]
    ) async -> TrackFeatures {
        var envelope: [Float] = []
        if case .success(let waveform) = await WaveformService.shared.waveform(for: track), !waveform.isEmpty {
            let bucketCount = max(8, Int((track.duration / DJEngineConstants.bucketSeconds).rounded()))
            envelope = waveform.resampled(to: bucketCount)
        }

        var cachedAnalysis: CachedMusicUnderstanding?
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            cachedAnalysis = await cachedAnalysisFeatures(for: track)
        }
        let aiAudio = await cachedAIAudio(for: track)
        var trackedBeats: BeatTrackerResult?
        if (cachedAnalysis?.barSeconds.count ?? 0) < 2 {
            trackedBeats = await cachedBeatTracking(for: track)
        }
        let prep = await CueStore.shared.prep(forTrack: track.id)
        let tracklist = await SetlistIntelligenceStore.shared.tracklist(for: track.id)
        let boundaries = (tracklist?.entries ?? []).map(\.startSeconds).filter { $0 > 1 && $0 < track.duration - 1 }
        let manual = ManualTempoKeyOverride(await AnalysisCache.shared.userCorrection(for: track))
        let base = assembleFeatures(
            for: track,
            envelope: envelope,
            cachedAnalysis: cachedAnalysis,
            legacyAnalysis: legacyAnalysis,
            userCues: userCues,
            prep: prep,
            boundaries: boundaries,
            trackedBeats: trackedBeats,
            aiAudio: aiAudio,
            manual: manual
        )
        let timbre = await TimbreEmbeddingProducer.cached(for: track)
        let suggestions = await CueStore.shared.listeningSuggestions(forTrack: track.id, grid: base.beatGrid, duration: track.duration)
        guard !suggestions.isEmpty else {
            var features = base
            features.timbre = timbre
            return features
        }
        var features = assembleFeatures(
            for: track,
            envelope: envelope,
            cachedAnalysis: cachedAnalysis,
            legacyAnalysis: legacyAnalysis,
            userCues: userCues,
            prep: prep,
            suggestions: suggestions,
            boundaries: boundaries,
            trackedBeats: trackedBeats,
            aiAudio: aiAudio,
            manual: manual
        )
        features.timbre = timbre
        return features
    }

    private nonisolated static func cachedAIAudio(for track: Track) async -> AIAudioAnalysisResult? {
        guard AIAudioSettings.isSupported, AIAudioSettings.isEnabled else { return nil }
        let generation = AnalysisGeneration(engine: .aiAudio(), schemaVersion: 1)
        let candidates = [track.mixSource] + track.transcodings
            .sorted { $0.playbackRank > $1.playbackRank }
            .map { Optional($0) }
        var seen = Set<String>()
        for transcoding in candidates {
            guard let key = AnalysisCacheKey(track: track, transcoding: transcoding, generation: generation),
                  seen.insert(key.stableKey).inserted else { continue }
            if let result = await AnalysisCache.shared.peek(AIAudioAnalysisResult.self, for: key) { return result }
        }
        return nil
    }

    private nonisolated static func cachedBeatTracking(for track: Track) async -> BeatTrackerResult? {
        let generation = BeatTrackerProducer().generation
        let candidates = [track.mixSource] + track.transcodings
            .sorted { $0.playbackRank > $1.playbackRank }
            .map { Optional($0) }
        var seen = Set<String>()
        for transcoding in candidates {
            guard let key = AnalysisCacheKey(track: track, transcoding: transcoding, generation: generation),
                  seen.insert(key.stableKey).inserted else { continue }
            if let result = await AnalysisCache.shared.peek(BeatTrackerResult.self, for: key) { return result }
        }
        return nil
    }

    nonisolated static func assembleFeatures(
        for track: Track,
        envelope: [Float],
        cachedAnalysis: CachedMusicUnderstanding?,
        legacyAnalysis: TrackAnalysis?,
        userCues: [CuePoint],
        prep: TrackPrep? = nil,
        suggestions: [CueSuggestion] = [],
        boundaries: [TimeInterval] = [],
        trackedBeats inputTrackedBeats: BeatTrackerResult? = nil,
        aiAudio: AIAudioAnalysisResult? = nil,
        manual: ManualTempoKeyOverride? = nil
    ) -> TrackFeatures {
        let aiGrid = aiAudio?.plannerGrid(phaseFrom: inputTrackedBeats)
        let trackedBeats = aiGrid ?? inputTrackedBeats
        let arrangement = inputTrackedBeats.flatMap { TrackArrangement.cached(trackId: track.id, tracked: $0, ai: aiAudio) }
        var grid: BeatGrid?
        var keyRegions: [KeyRegion] = []
        var energyLevel: Int?
        var sections: [TrackSection] = []
        var provenance: FeatureProvenance = envelope.isEmpty ? .metadataOnly : .envelopeOnly

        var vocalRanges: [ClosedRange<TimeInterval>] = []
        var bassRanges: [ClosedRange<TimeInterval>] = []
        var phraseBoundaries: [TimeInterval] = []

        do {
            if let cached = cachedAnalysis {
                if let bpm = cached.features.bpm,
               cached.barSeconds.count >= 2,
               let measured = BeatGrid.fromMeasuredBars(
                   bpm: bpm, beats: cached.beatSeconds, bars: cached.barSeconds, confidence: 0.85
               ) {
                grid = measured
                provenance.insert([.measuredTempo, .measuredBeatGrid, .measuredDownbeats])
            } else if let bpm = cached.features.bpm, let tempoOnly = BeatGrid.tempoOnly(bpm) {
                grid = tempoOnly
                provenance.insert(.measuredTempo)
            }
            if !cached.keyRegions.isEmpty {
                keyRegions = cached.keyRegions
                provenance.insert(.measuredKey)
            } else if let key = cached.features.key {
                keyRegions = [KeyRegion(key: key, start: 0, end: track.duration)]
                provenance.insert(.measuredKey)
            }
            if let measuredVocalRanges = cached.vocalRanges {
                vocalRanges = measuredVocalRanges
                provenance.insert(.measuredVocals)
            }
            if let measuredBassRanges = cached.bassRanges {
                bassRanges = measuredBassRanges
                provenance.insert(.measuredBass)
            }
            if !cached.structureRanges.isEmpty {
                sections = arrangement?.sections(duration: track.duration) ?? classifyStructure(
                    cached.structureRanges,
                    duration: track.duration,
                    envelope: envelope
                )
                phraseBoundaries = cached.phraseBoundaries
                provenance.insert(.measuredStructure)
            }
            if let lufs = cached.integratedLUFS, lufs.isFinite {
                // Typical mastered music falls roughly between -24 and -6
                // LUFS. This is a stable whole-track energy prior, unlike the
                // legacy analyzer's first-minute snapshot.
                energyLevel = min(10, max(1, Int(((Double(lufs) + 24) / 2).rounded()) + 1))
            }
            }
        }

        if let aiGrid, let bpm = aiGrid.bpm,
           let measured = BeatGrid.fromMeasuredBars(
               bpm: bpm, beats: aiGrid.beats, bars: aiGrid.downbeats,
               confidence: aiGrid.confidence, phraseOffsetBars: aiGrid.phraseOffsetBars
           ) {
            grid = measured
            provenance.insert([.measuredTempo, .measuredBeatGrid, .measuredDownbeats])
            phraseBoundaries = aiGrid.phraseStarts
            if sections.isEmpty, aiGrid.phraseStarts.count >= 2 {
                let starts = aiGrid.phraseStarts + [track.duration]
                let ranges = zip(starts, starts.dropFirst()).compactMap { $1 > $0 ? $0...$1 : nil }
                sections = arrangement?.sections(duration: track.duration) ?? classifyStructure(ranges, duration: track.duration, envelope: envelope)
                provenance.insert(.measuredStructure)
            }
        }

        if let stems = aiAudio?.stems {
            vocalRanges = stems.vocals.compactMap(\.seconds)
            bassRanges = stems.bass.compactMap(\.seconds)
            provenance.insert([.measuredVocals, .measuredBass, .measuredStems])
        }

        if let tracked = trackedBeats, tracked.isParityReliable || tracked.isPhaseReliable {
            provenance.insert(.measuredBeatParity)
        }

        if let tracked = trackedBeats, !provenance.contains(.measuredVocals), tracked.vocalCurve != nil, let detected = tracked.vocalSeconds {
            vocalRanges = detected
            provenance.insert(.measuredVocals)
        }

        let beatOnlyGrid = trackedBeats.flatMap { DJBeatOnly.grid($0) }
        if let tracked = trackedBeats, !provenance.contains(.measuredBeatGrid),
           tracked.isPhaseReliable || beatOnlyGrid != nil || grid == nil, let trackedGrid = beatOnlyGrid ?? tracked.beatGrid() {
            grid = trackedGrid
            provenance.insert(.measuredTempo)
            if beatOnlyGrid != nil {
                provenance.insert([.measuredBeatGrid, .guessedBarPhase])
            } else if tracked.isPhaseReliable {
                provenance.insert([.measuredBeatGrid, .measuredDownbeats])
            }
            if phraseBoundaries.isEmpty { phraseBoundaries = tracked.phraseStarts }
            if sections.isEmpty, tracked.isPhaseReliable || beatOnlyGrid != nil, tracked.phraseStarts.count >= 2 {
                let starts = tracked.phraseStarts + [track.duration]
                let ranges = zip(starts, starts.dropFirst()).compactMap { $1 > $0 ? $0...$1 : nil }
                sections = arrangement?.sections(duration: track.duration) ?? classifyStructure(ranges, duration: track.duration, envelope: envelope)
                provenance.insert(.measuredStructure)
            }
        }

        if let analysis = legacyAnalysis, !analysis.isEstimated {
            if grid == nil,
               let bpm = analysis.bpm,
               let tempoOnly = BeatGrid.tempoOnly(bpm) {
                grid = tempoOnly
                provenance.insert(.measuredTempo)
            }
            if keyRegions.isEmpty, let key = analysis.key, let camelot = CamelotKey.parse(key) {
                keyRegions = [KeyRegion(key: camelot, start: 0, end: track.duration)]
                provenance.insert(.measuredKey)
            }
            if energyLevel == nil {
                energyLevel = min(10, max(1, Int((analysis.energy * 10).rounded())))
            }
            if sections.isEmpty, analysis.intro > 1, analysis.intro < track.duration * 0.5 {
                sections = [TrackSection(kind: .intro, start: 0, end: analysis.intro)]
            }
        }

        var manualTempoReplacedGrid = false
        if let manualBPM = manual?.bpm {
            let replaced = ManualTempoKeyOverride.grid(manualBPM, replacing: grid)
            if replaced != grid {
                grid = replaced
                manualTempoReplacedGrid = true
                provenance.remove([.measuredBeatGrid, .measuredDownbeats, .measuredBeatParity, .guessedBarPhase])
            }
            provenance.insert(.measuredTempo)
        }
        if let manualKey = manual?.key {
            keyRegions = [KeyRegion(key: manualKey, start: 0, end: track.duration)]
            provenance.insert(.measuredKey)
        }

        let preferredEntry = userCues.first { $0.kind == .mixIn }?.positionSeconds
        let preferredExit = userCues.first { $0.kind == .mixOut }?.positionSeconds

        let hints = PrepMixHints.derive(
            cues: userCues,
            suggestions: suggestions,
            prep: prep,
            measuredGrid: grid,
            phraseBoundaries: phraseBoundaries,
            duration: track.duration
        )
        if let trusted = hints.grid {
            grid = trusted
            provenance.insert([.measuredTempo, .measuredBeatGrid, .measuredDownbeats])
        }

        if let phrases = prep?.phrases?.value, phrases.count >= 2 {
            let ordered = phrases.sorted { $0.startMillis < $1.startMillis }
            sections = ordered.enumerated().compactMap { index, phrase in
                let start = CueTime.seconds(fromMillis: phrase.startMillis)
                let end = index + 1 < ordered.count ? CueTime.seconds(fromMillis: ordered[index + 1].startMillis) : track.duration
                return end > start ? TrackSection(kind: phrase.kind, start: start, end: end) : nil
            }
            provenance.insert(.measuredStructure)
        }
        if let energy = prep?.energy?.value, (1...10).contains(energy) {
            energyLevel = energy
        }
        let heat = suggestions
            .filter { $0.suggester.name == ListeningSuggester.identity.name }
            .map(\.positionSeconds)
            .sorted()

        let genre = GenreDetector.resolve(genreField: track.genre, tags: track.tags + [track.title])

        var features = TrackFeatures(
            trackId: track.id,
            title: track.title,
            artist: track.user.username,
            duration: track.duration,
            beatGrid: grid,
            swingRatio: nil,
            keyRegions: keyRegions,
            sections: sections,
            phraseBoundaries: phraseBoundaries,
            energyLevel: energyLevel,
            envelope: envelope,
            genre: genre,
            vocalRanges: vocalRanges,
            bassRanges: bassRanges,
            preferredEntrySeconds: preferredEntry,
            preferredExitSeconds: preferredExit,
            provenance: provenance,
            cueHints: hints.hints,
            extensionLoop: hints.extensionLoop,
            heat: heat,
            boundaries: boundaries,
            barProfile: manualTempoReplacedGrid && hints.grid == nil ? nil : trackedBeats?.bars,
            barStarts: manualTempoReplacedGrid && hints.grid == nil ? [] : (trackedBeats?.bars == nil ? [] : trackedBeats?.downbeats ?? [])
        )
        features.loopRanges = aiAudio?.stems?.drumsOnly.compactMap(\.seconds) ?? []
        features.arrangement = arrangement
        return features
    }

    nonisolated static func classifyStructure(
        _ ranges: [ClosedRange<TimeInterval>],
        duration: TimeInterval,
        envelope: [Float]
    ) -> [TrackSection] {
        let valid = ranges
            .filter { $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard !valid.isEmpty else { return [] }

        let median = DJPointFinder.envelopeMedian(envelope)
        func level(in range: ClosedRange<TimeInterval>) -> Double? {
            guard !envelope.isEmpty, duration > 0 else { return nil }
            let lower = max(0, min(envelope.count - 1, Int(range.lowerBound / duration * Double(envelope.count))))
            let upper = max(lower + 1, min(envelope.count, Int(range.upperBound / duration * Double(envelope.count))))
            guard lower < upper else { return nil }
            return envelope[lower..<upper].map(Double.init).reduce(0, +) / Double(upper - lower)
        }

        return valid.enumerated().map { index, range in
            let center = (range.lowerBound + range.upperBound) / 2
            let normalized = duration > 0 ? center / duration : 0
            let relative = median > 0 ? (level(in: range) ?? median) / median : 1
            let kind: SectionKind
            if index == 0 || normalized < 0.12 {
                kind = relative < 0.45 ? .ambientIntro : .intro
            } else if index == valid.count - 1 || normalized > 0.88 {
                kind = relative < 0.45 ? .ambientOutro : .outro
            } else if relative < 0.65 {
                kind = normalized > 0.70 ? .cooldown : .breakdown
            } else if relative > 1.18 {
                kind = .drop
            } else if index + 1 < valid.count,
                      let next = level(in: valid[index + 1]), median > 0, next / median > relative + 0.2 {
                kind = .buildup
            } else {
                kind = .bridge
            }
            return TrackSection(kind: kind, start: range.lowerBound, end: range.upperBound)
        }
    }

    struct CachedMusicUnderstanding: Sendable {
        let features: AnalysisFeatures
        let beatSeconds: [TimeInterval]
        let barSeconds: [TimeInterval]
        let structureRanges: [ClosedRange<TimeInterval>]
        let phraseBoundaries: [TimeInterval]
        let keyRegions: [KeyRegion]
        let vocalRanges: [ClosedRange<TimeInterval>]?
        let bassRanges: [ClosedRange<TimeInterval>]?
        let integratedLUFS: Float?
    }

    @available(iOS 27.0, macOS 27.0, tvOS 27.0, *)
    private nonisolated static func cachedAnalysisFeatures(for track: Track) async -> CachedMusicUnderstanding? {
        let generation = MusicUnderstandingProducer().generation
        let candidates = [track.mixSource] + track.transcodings
            .sorted { $0.playbackRank > $1.playbackRank }
            .map { Optional($0) }
        var seen = Set<String>()
        var found: MusicUnderstandingDistilledResult?
        for transcoding in candidates {
            guard let key = AnalysisCacheKey(track: track, transcoding: transcoding, generation: generation),
                  seen.insert(key.stableKey).inserted else { continue }
            if let result = await AnalysisCache.shared.peek(MusicUnderstandingDistilledResult.self, for: key) {
                found = result
                break
            }
        }
        guard let result = found else { return nil }
        return cachedMusicUnderstanding(result)
    }

    @available(iOS 27.0, macOS 27.0, tvOS 27.0, *)
    nonisolated static func cachedMusicUnderstanding(_ result: MusicUnderstandingDistilledResult) -> CachedMusicUnderstanding {
        func region(_ range: MusicUnderstandingDistilledResult.Range) -> ClosedRange<TimeInterval> {
            range.start...range.end
        }

        let structureRanges = result.structureRanges.map(region)
        let keyRegions: [KeyRegion] = result.keyRanges.compactMap { range in
            guard let mode = CamelotKey.CamelotMode(rawValue: range.mode) else { return nil }
            let key = CamelotKey(wheelPosition: range.wheelPosition, mode: mode)
            return KeyRegion(key: key, start: range.start, end: range.end)
        }

        return CachedMusicUnderstanding(
            features: MusicUnderstandingProducer.projectFeatures(result),
            beatSeconds: result.beatSeconds,
            barSeconds: result.barSeconds,
            structureRanges: structureRanges,
            phraseBoundaries: result.phraseStartSeconds,
            keyRegions: keyRegions,
            vocalRanges: result.vocalRanges?.map(region),
            bassRanges: result.bassRanges?.map(region),
            integratedLUFS: result.integratedLUFS
        )
    }

    static func loudnessAttenuation(for track: Track) async -> Double {
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            if let cached = await cachedAnalysisFeatures(for: track), let lufs = cached.integratedLUFS {
                return LoudnessNormalization.attenuation(measuredLUFS: lufs)
            }
        }
        if case .success(let waveform) = await WaveformService.shared.waveform(for: track), !waveform.isEmpty {
            return LoudnessNormalization.attenuation(waveformRMS: waveform.rmsLevel)
        }
        return 1
    }

    private func phantomPlanOrFallback(for track: Track) -> PhantomDJEngine.Plan? {
        if let cached = phantomPlanCache[track.id],
           cached.incomingTrackId == nil || cached.incomingTrackId == host.upcomingMixTrack?.id {
            return cached
        }
        return automaticCleanCutFallback(for: track)
    }

    private func automaticCleanCutFallback(for track: Track) -> PhantomDJEngine.Plan? {
        PhantomDJEngine.cleanCutFallbackPlan(
            outgoingDuration: track.duration,
            incomingTrackId: host.upcomingMixTrack?.id,
            profile: host.djProfile
        )
    }

    // MARK: - Transition execution

    private func updatePhantomTick(live: MixEngine.DeckState) {
        guard host.isAutoMixEnabled, host.isMixEngineLive, !isCrossfading, host.mixWindow == nil else { return }
        if let track = host.currentTrack, updateJumpTick(track: track, live: live) { return }
        guard let track = host.currentTrack, let plan = phantomPlanOrFallback(for: track) else { return }
        let overshootLimit = plan.mixPointSeconds + max(4, plan.transitionSeconds * 0.5)
        guard live.position <= overshootLimit || deadlineLoopTrackId == track.id else {
            invalidatePhantomPlan(for: track.id)
            return
        }
        guard live.position >= max(0, plan.mixPointSeconds - Self.transitionSchedulingLead) else { return }

        if host.incomingDeck.isReady, let next = host.upcomingMixTrack, incomingTrackId == next.id {
            Task { @MainActor [weak self] in self?.startPhantomMixIfStillDue() }
        } else if deadlineLoopTrackId != track.id, engageDeadlineLoop(track: track, plan: plan, live: live) {
            phantomCutAnnounced = true
            host.phantomActivity = .cutting(reason: "Next track isn't ready yet — looping the last phrase.")
        } else if !phantomCutAnnounced {
            phantomCutAnnounced = true
            let reason: String
            if case .failed(let message) = host.incomingDeck {
                reason = "Next track couldn't be prepared: \(message)"
            } else if host.upcomingMixTrack == nil {
                reason = "No next track queued — playing out."
            } else {
                reason = "Next track wasn't ready in time — playing out to a hard cut."
            }
            host.phantomActivity = .cutting(reason: reason)
        }
    }

    private func engageDeadlineLoop(track: Track, plan: PhantomDJEngine.Plan, live: MixEngine.DeckState) -> Bool {
        guard host.upcomingMixTrack != nil, live.loopLengthSeconds == nil else { return false }
        if case .failed = host.incomingDeck { return false }
        guard let downbeats = (plan.outgoingBeatGrid ?? outgoingBeatGrid())?.downbeats,
              let loop = MixDeadlineLoop.lastCleanPhrase(
                  downbeats: downbeats, duration: live.duration, playhead: live.position,
                  vocals: MixVocalMap.shared.vocals(for: track.id),
                  levels: MixVocalMap.shared.levels(for: track.id),
                  contentEnd: MixVocalMap.shared.contentEnd(for: track.id)
              ),
              loop.startSeconds <= live.position + loop.lengthSeconds else { return false }
        MixEngine.shared.setLoop(on: host.liveDeck, startSeconds: loop.startSeconds, lengthSeconds: loop.lengthSeconds)
        deadlineLoopTrackId = track.id
        if plan.mixPointSeconds >= loop.endSeconds || plan.mixPointSeconds < loop.startSeconds {
            phantomPlanCache[track.id] = plan.shifted(mixPoint: loop.startSeconds).validated(outgoing: nil, profile: host.djProfile)
            pinnedPlanTrackIds.insert(track.id)
        }
        return true
    }

    private func releaseDeadlineLoop(on deck: MixEngine.Deck) {
        guard deadlineLoopTrackId != nil else { return }
        deadlineLoopTrackId = nil
        MixEngine.shared.clearLoop(on: deck)
    }

    private func startPhantomMixIfStillDue() {
        guard host.isAutoMixEnabled, host.isPhantomEnabled, host.isMixEngineLive,
              !isCrossfading, host.mixWindow == nil else { return }
        guard let track = host.currentTrack, let plan = phantomPlanOrFallback(for: track) else { return }
        guard MixEngine.shared[host.liveDeck].position >= max(0, plan.mixPointSeconds - Self.transitionSchedulingLead) else { return }
        guard host.incomingDeck.isReady, let next = host.upcomingMixTrack, let index = host.nextQueueIndex(),
              incomingTrackId == next.id else { return }

        host.phantomActivity = .mixing(plan)
        performLiveTransition(
            to: next, at: index, over: plan.transitionSeconds,
            announceAsMix: true, filterAccent: plan.accent, plan: plan,
            startAtPlannedBoundary: true
        )
    }

    func performLiveTransition(
        to track: Track,
        at index: Int,
        over seconds: TimeInterval,
        announceAsMix: Bool,
        filterAccent: PhantomDJEngine.Accent? = nil,
        plan proposed: PhantomDJEngine.Plan? = nil,
        startAtPlannedBoundary: Bool = false
    ) {
        let engine = MixEngine.shared
        let outgoing = host.liveDeck
        let incoming = host.liveDeck.other
        let plan = proposed?.validated(outgoing: nil, profile: host.djProfile)
        let window = max(0.15, plan?.templateId != proposed?.templateId ? (plan?.transitionSeconds ?? seconds) : seconds)

        isCrossfading = true
        deckEndHandled = false
        engine.cancelPerformance(on: outgoing, overlapping: engine.livePosition(of: outgoing)...(engine.livePosition(of: outgoing) + window * 2))
        engine.cancelPerformance(on: incoming)
        performanceTrackId = nil
        let incomingDuration = engine[incoming].duration > 0 ? engine[incoming].duration : track.duration
        let entrySeconds = max(
            TrackTrimStore.effectiveRange(for: track.id, duration: incomingDuration).lowerBound,
            PlaybackTimelinePolicy.transitionStartPosition(
                plan?.entrySeconds ?? 0,
                duration: incomingDuration,
                transitionSeconds: window
            )
        )

        transitionActions?.cancel()
        tempoReturn?.cancel()
        tempoReturn = nil
        let actions = MixActionGroup()
        transitionActions = actions
        activeMove = plan?.move == nil ? nil : plan

        let request = MixTransitionPerformer.Request(
            outgoing: outgoing,
            incoming: incoming,
            window: window,
            entrySeconds: entrySeconds,
            plan: plan,
            filterAccent: filterAccent,
            announceAsMix: announceAsMix,
            startAtPlannedBoundary: startAtPlannedBoundary,
            outgoingGridFallback: outgoingBeatGrid(),
            rateBudgetPercent: max(host.djProfile?.maxAbsRatePercent ?? MixEngine.maxTempoMatchPercent, plan.map { abs($0.incomingRateRatio - 1) * 100 + 0.01 } ?? 0),
            legacyTempoMatch: plan == nil ? legacyTempoMatch(to: track) : nil,
            resetsIncoming: host.isAutoMixEnabled,
            startsPaused: !(host.isPlaying || engine[outgoing].isPlaying),
            riserLevel: host.djProfile?.id == .wedding ? 0 : SettingsStore.shared.djRiserLevel
        )
        let jumping = isJumping
        let outcome = MixTransitionPerformer(engine: engine).begin(request, actions: actions) { [weak self] in
            guard let self, self.transitionActions === actions else { return }
            if jumping {
                self.finishJump(outgoing: outgoing, incoming: incoming, track: track)
            } else {
                self.finishLiveTransition(outgoing: outgoing, incoming: incoming, track: track, index: index)
            }
        }

        switch outcome {
        case .failed(let reason):
            actions.cancel()
            transitionActions = nil
            isCrossfading = false
            activeMove = nil
            host.phantomActivity = .cutting(reason: "Incoming deck could not start: \(reason)")
        case .started(let leadSeconds, let windowSeconds):
            recordExecutedMix(plan, into: track, outgoing: outgoing, entrySeconds: entrySeconds, leadSeconds: leadSeconds, windowSeconds: windowSeconds, request: request)
            if announceAsMix {
                let sourceLead = leadSeconds * max(0.01, engine[outgoing].rate)
                host.mixWindow = MixWindow(start: engine.livePosition(of: outgoing) + sourceLead, seconds: windowSeconds, isLive: true)
            }
        }
    }

    private func outgoingBeatGrid() -> BeatGrid? {
        if let grid = MixEngine.shared.beatGrid(for: host.liveDeck) { return grid }
        if let grid = adaptiveMixPlan?.outgoingBeatGrid { return grid }
        guard let track = host.currentTrack else { return nil }
        guard case .analyzed(let analysis) = host.transitionService.state(for: track.id),
              !analysis.isEstimated, let bpm = analysis.bpm else { return nil }
        return BeatGrid.tempoOnly(bpm)
    }

    private func legacyTempoMatch(to track: Track) -> (sourceBPM: Double, targetBPM: Double)? {
        guard let from = host.currentTrack else { return nil }
        let dj = host.transitionService
        guard case .analyzed(let a) = dj.state(for: from.id),
              case .analyzed(let b) = dj.state(for: track.id),
              !a.isEstimated, !b.isEstimated,
              let sourceBPM = b.bpm, let targetBPM = a.bpm
        else { return nil }
        return (sourceBPM, targetBPM)
    }

    private func offerFeedback(for plan: PhantomDJEngine.Plan?, into track: Track) {
        guard host.isAutoMixEnabled, let plan, plan.incomingTrackId == track.id, var features = plan.feedback else { return }
        features.moveType = AutoMixTransitionFeatures.moveType(templateId: plan.templateId, move: plan.move?.kind)
        AutoMixFeedbackStore.shared.offer(
            features, incomingTitle: track.title,
            analysis: AutoMixAnalysisProvenance(outgoing: plan.outgoingFeatures, incoming: DJPlanFeatureCache.shared.features(for: plan.incomingTrackId))
        )
    }

    private func noteMovePerformed(_ plan: PhantomDJEngine.Plan?) {
        guard let plan else { return }
        if let used = plan.templateId {
            recentTemplates.insert(used, at: 0)
            if recentTemplates.count > 8 { recentTemplates.removeLast() }
        }
        if let move = plan.move {
            performedMoves.append((move.kind, Date()))
            if performedMoves.count > 32 { performedMoves.removeFirst() }
        }
    }

    private func finishJump(outgoing: MixEngine.Deck, incoming: MixEngine.Deck, track: Track) {
        let engine = MixEngine.shared
        noteMovePerformed(activeMove)
        jumpPlans[track.id] = nil
        tempoReturn?.cancel()
        tempoReturn = MixTransitionPerformer(engine: engine).finish(outgoing: outgoing, incoming: incoming)
        transitionActions?.cancel()
        transitionActions = nil
        host.liveDeck = incoming
        armedTrackId = track.id
        jumpDeckTrackId = nil
        incomingTrackId = nil
        isJumping = false
        activeMove = nil
        host.incomingDeck = .idle
        isCrossfading = false
        host.mixWindow = nil
        deckEndHandled = false
        let position = PlaybackTimelinePolicy.clampedPosition(engine.audiblePosition(of: incoming), duration: host.duration)
        host.clock.currentTime = position
        lastMixEngineTransportUpdate = Date()
        host.publishMixEngineTransport(engine[incoming].isPlaying ? .playing : .paused, trackID: track.id)
        host.updateNowPlayingProgress()
        prepareIncomingDeck()
        refreshPhantomPlan()
        if let profile = host.djProfile { precomputeJumpIfUseful(for: track, profile: profile) }
    }

    private func finishLiveTransition(
        outgoing: MixEngine.Deck,
        incoming: MixEngine.Deck,
        track: Track,
        index: Int
    ) {
        let engine = MixEngine.shared

        if deadlineLoopTrackId != nil {
            deadlineLoopTrackId = nil
            engine.forceClearLoop(on: outgoing)
        }
        if let outgoingId = host.currentTrack?.id {
            let performed = activeMove ?? phantomPlanCache[outgoingId]
            noteMovePerformed(performed)
            offerFeedback(for: performed, into: track)
            pinnedPlanTrackIds.remove(outgoingId)
            jumpPlans[outgoingId] = nil
        }
        activeMove = nil

        tempoReturn?.cancel()
        tempoReturn = MixTransitionPerformer(engine: engine).finish(outgoing: outgoing, incoming: incoming)
        #if os(macOS)
        if tempoReference() != nil {
            tempoReturn?.cancel()
            tempoReturn = nil
        }
        #endif

        transitionActions?.cancel()
        transitionActions = nil

        host.liveDeck = incoming
        armedTrackId = track.id
        incomingTrackId = nil
        host.incomingDeck = .idle
        isCrossfading = false
        host.mixWindow = nil
        deckEndHandled = false

        host.adoptIncomingTrack(track, at: index)
        host.clock.duration = engine[incoming].duration > 0 ? engine[incoming].duration : track.duration
        let incomingPosition = PlaybackTimelinePolicy.clampedPosition(
            engine.audiblePosition(of: incoming),
            duration: host.duration
        )
        host.clock.currentTime = incomingPosition
        lastMixEngineTransportUpdate = Date()
        host.publishMixEngineTransport(engine[incoming].isPlaying ? .playing : .paused, trackID: track.id)
        host.downloads.markPlayed(trackId: track.id)

        host.updateNowPlayingMetadata()
        host.transitionService.analyzeUpcoming(in: host.queue, from: host.currentIndex)
        prepareIncomingDeck()
        refreshPhantomPlan()
        refreshCacheWarming()
    }

    // MARK: - Transport during a mix

    func pauseMixDecks() {
        audibleHold = nil
        MixTransitionPerformer(engine: MixEngine.shared).pause(live: host.liveDeck, isCrossfading: isCrossfading)
    }

    func resumeMixDecks() {
        let engine = MixEngine.shared
        MixTransitionPerformer(engine: engine).resume(live: host.liveDeck, isCrossfading: isCrossfading)
        if engine[host.liveDeck].isPlaying {
            audibleHold = engine.livePosition(of: host.liveDeck)
        }
    }

    func seekMixDecks(to seconds: TimeInterval) -> TimeInterval {
        let engine = MixEngine.shared
        releaseDeadlineLoop(on: host.liveDeck)
        let outcome = MixTransitionPerformer(engine: engine).seek(
            live: host.liveDeck,
            to: seconds,
            transition: isCrossfading ? transitionActions : nil
        )
        if outcome == .aborted {
            transitionActions = nil
            isCrossfading = false
            if isJumping, let track = host.currentTrack {
                isJumping = false
                activeMove = nil
                jumpDeckTrackId = nil
                jumpPlans[track.id] = nil
                incomingTrackId = nil
                host.incomingDeck = .idle
                prepareIncomingDeck()
            }
            host.mixWindow = nil
            phantomCutAnnounced = false
            if let track = host.currentTrack, let plan = phantomPlanCache[track.id] {
                host.phantomActivity = .armed(plan)
            }
        }
        let landed = engine.livePosition(of: host.liveDeck)
        if engine[host.liveDeck].isPlaying, engine.outputLatencySeconds >= Self.audibleHoldMinimumLatency {
            audibleHold = landed
        } else {
            audibleHold = nil
        }
        lastMixEngineTransportUpdate = Date()
        return landed
    }

    // MARK: - Engine observation and adaptive tick

    private func observeMixEngine() {
        guard mixEngineObserver == nil else { return }
        mixEngineTouched = true
        mixEngineObserver = MixEngine.shared.$decks
            .throttle(for: .milliseconds(50), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] decks in
                self?.mixEngineDidTick(decks)
            }
        mixEngineErrorObserver = MixEngine.shared.$lastError
            .sink { [weak self] error in
                self?.mixEngineErrorDidChange(error)
            }
        MixEngine.shared.$crossfade
            .throttle(for: .milliseconds(50), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.publishSnapshot() }
            .store(in: &cancellables)
        MixEngine.shared.$masterVolume
            .throttle(for: .milliseconds(50), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.publishSnapshot() }
            .store(in: &cancellables)
        MixEngine.shared.$outputLatencySeconds
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] latency in self?.outputLatencyDidChange(latency) }
            .store(in: &cancellables)
    }

    private func outputLatencyDidChange(_ latency: TimeInterval) {
        guard host.isMixEngineLive, MixEngine.shared[host.liveDeck].isPlaying else { return }
        let heard = host.currentTime
        let audible = MixEngine.shared.audiblePosition(of: host.liveDeck)
        guard audible + Self.audibleHoldTolerance < heard else { return }
        audibleHold = max(audibleHold ?? 0, heard)
    }

    private func mixEngineErrorDidChange(_ error: MixEngineError?) {
        guard let error, host.djSessionEnabled, host.isMixEngineLive,
              case .graphBuildFailed = error, let track = host.currentTrack else { return }
        fallBackToAVPlayer(track, error: error)
    }

    private func mixEngineDidTick(_ deckStates: [MixEngine.DeckState]) {
        guard deckStates.count == MixEngine.Deck.allCases.count else { return }

        if case .preparing = host.mixEngineState {
            let arming = deckStates[armingDeck.rawValue]
            if arming.trackId == armingTrackId, case .loading(let fraction) = arming.status {
                let nextState = MixEngineState.preparing(fraction)
                if host.mixEngineState != nextState { host.mixEngineState = nextState }
            }
        }

        let other = deckStates[host.liveDeck.other.rawValue]
        if let wanted = incomingTrackId, other.trackId == wanted {
            switch other.status {
            case .loading(let fraction):
                let nextState = IncomingDeckState.loading(fraction)
                if host.incomingDeck != nextState { host.incomingDeck = nextState }
            case .ready:
                if host.incomingDeck != .ready { host.incomingDeck = .ready }
            case .failed(let message):
                let nextState = IncomingDeckState.failed(message)
                if host.incomingDeck != nextState { host.incomingDeck = nextState }
            case .empty:
                break
            }
        }

        publishSnapshot()

        guard host.isMixEngineLive else { return }

        let engine = MixEngine.shared
        let live = deckStates[host.liveDeck.rawValue]
        if live.duration > 0, host.duration != live.duration { host.clock.duration = live.duration }
        let running = live.isPlaying || isCrossfading
        let audible = PlaybackTimelinePolicy.clampedPosition(
            engine.audiblePosition(of: host.liveDeck),
            duration: host.duration
        )
        var released = false
        if let hold = audibleHold {
            if !running {
                audibleHold = nil
            } else if audible + Self.audibleHoldTolerance >= hold {
                audibleHold = nil
                released = true
            }
        }
        let now = Date()
        if audibleHold == nil,
           released || now.timeIntervalSince(lastMixEngineTransportUpdate) >= Self.mixEngineTransportUpdateInterval {
            lastMixEngineTransportUpdate = now
            host.clock.currentTime = audible
        }
        if let trackID = host.currentTrack?.id {
            let phase: PlayerService.MixTransportPhase
            if !running {
                phase = .paused
            } else if audibleHold != nil {
                phase = .buffering
            } else {
                phase = .playing
            }
            host.publishMixEngineTransport(phase, trackID: trackID)
        }
        host.persistSessionState()
        let whole = Int(host.currentTime)
        if whole != lastNowPlayingSecond || released {
            lastNowPlayingSecond = whole
            host.updateNowPlayingProgress()
        }

        if host.isPhantomEnabled {
            updatePhantomTick(live: live)
        } else if isAutoMixDue(live: live) {
            Task { @MainActor [weak self] in self?.startAutoMixIfStillDue() }
        }

        let trimEnd = TrackTrimStore.effectiveRange(for: host.currentTrack?.id ?? "", duration: live.duration).upperBound
        let pastTrimEnd = live.duration > 0 && trimEnd < live.duration - 0.05 && live.position >= trimEnd
        if !isCrossfading,
           !deckEndHandled,
           live.status == .ready,
           live.duration > 0,
           pastTrimEnd || (!live.isPlaying && live.position >= live.duration - 0.35) {
            deckEndHandled = true
            if pastTrimEnd, live.isPlaying { engine.pause(deck: host.liveDeck) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.host.handlePlaybackEnded()
            }
        }
    }

    private func isAutoMixDue(live: MixEngine.DeckState) -> Bool {
        guard host.djSessionEnabled, host.isAutoMixEnabled else { return false }
        guard !isCrossfading, host.mixWindow == nil else { return false }
        guard host.isMixEngineLive, host.incomingDeck.isReady else { return false }
        guard let next = host.upcomingMixTrack, incomingTrackId == next.id else { return false }
        guard let seconds = effectiveMixSeconds() else { return false }
        let total = live.duration > 0 ? live.duration : host.duration
        guard total > 0 else { return false }
        let end = TrackTrimStore.effectiveRange(for: host.currentTrack?.id ?? "", duration: total).upperBound
        return live.position >= max(0, end - seconds)
    }

    private func effectiveMixSeconds() -> TimeInterval? {
        if let seconds = plannedMixSeconds() { return seconds }
        guard host.autoMixSettingEnabled, host.upcomingMixTrack != nil else { return nil }
        return SettingsStore.shared.djTransitionLengthSeconds
    }

    private func startAutoMixIfStillDue() {
        guard host.isMixEngineLive, !isCrossfading, host.mixWindow == nil else { return }
        guard isAutoMixDue(live: MixEngine.shared[host.liveDeck]) else { return }
        guard let next = host.upcomingMixTrack, let index = host.nextQueueIndex() else { return }
        guard let seconds = effectiveMixSeconds() else { return }

        performLiveTransition(to: next, at: index, over: seconds, announceAsMix: true)
    }

    // MARK: - Session handoff

    func handBackToAVPlayer() {
        let ownsCurrent = host.isMixEngineLive || isStartingInEngine(host.currentTrack?.id)
        guard ownsCurrent, let track = host.currentTrack else {
            endMixSession()
            return
        }
        let resumeAt = host.isMixEngineLive ? host.currentTime : (pendingStartPosition ?? host.currentTime)
        let shouldResume = host.playbackRequested || host.isPlaying
        endMixSession()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.host.loadAndPlay(
                track: track,
                startPosition: resumeAt,
                transportIntent: shouldResume ? .play : .pause
            )
        }
    }

    private func cancelSessionWork() {
        cancelPerformance()
        armTask?.cancel();      armTask = nil
        handoverTask?.cancel(); handoverTask = nil
        handoverTrackId = nil
        midTrackHandoverTrackId = nil
        incomingTask?.cancel(); incomingTask = nil
        jumpTask?.cancel();     jumpTask = nil
        jumpDeckTrackId = nil
        isJumping = false
        activeMove = nil
        mixTask?.cancel();      mixTask = nil
        transitionActions?.cancel()
        transitionActions = nil
        tempoReturn?.cancel()
        tempoReturn = nil

        armingTrackId = nil
        armedTrackId = nil
        incomingTrackId = nil
        pendingStartPosition = nil
        audibleHold = nil
        host.incomingDeck = .idle
        isCrossfading = false
        deckEndHandled = false
        host.mixWindow = nil
        phantomCutAnnounced = false
        deadlineLoopTrackId = nil
    }

    func endMixSession() {
        cancelSessionWork()
        for task in warmTasks.values { task.cancel() }
        warmTasks.removeAll()
        host.liveDeck = .a

        for task in phantomPlanTasks.values { task.cancel() }
        phantomPlanTasks.removeAll()
        phantomPlanCache.removeAll()
        recentTemplates.removeAll()
        performedMoves.removeAll()
        for task in jumpPlanTasks.values { task.cancel() }
        jumpPlanTasks.removeAll()
        jumpPlans.removeAll()
        pinnedPlanTrackIds.removeAll()
        host.phantomActivity = .idle

        host.mixEngineState = .off
        if mixEngineTouched {
            MixEngine.shared.stop()
        }
    }
}

enum EngineLoadFailurePolicy {
    enum Action: Equatable {
        case fallBackToAVPlayer
        case retry(after: TimeInterval)
        case skipToNext
        case stop
    }

    static let retriesPerTrack = 1
    static let retryDelay: TimeInterval = 1
    static let maxConsecutiveSkips = 3

    static func action(requiresEngineOutput: Bool, retriesSoFar: Int, consecutiveSkips: Int, hasNextTrack: Bool) -> Action {
        guard requiresEngineOutput else { return .fallBackToAVPlayer }
        if retriesSoFar < retriesPerTrack { return .retry(after: retryDelay) }
        if hasNextTrack, consecutiveSkips < maxConsecutiveSkips { return .skipToNext }
        return .stop
    }
}

enum EngineHandoverPolicy {
    enum StartRoute: Equatable { case engine, streamThenHandOver }
    enum Step: Equatable { case handOverNow, wait, stayOnStream }

    static let leadBars: Double = 16
    static let longestBlendBars: Double = 32
    static let defaultBarSeconds: TimeInterval = 2
    static let crossfadeSeconds: TimeInterval = 0.03
    static let alignmentAttempts = 4
    static let correctionThreshold: TimeInterval = 0.001
    static let alignedTolerance: TimeInterval = 0.004

    static func startRoute(isOnDeck: Bool, isCached: Bool, isAirPlay: Bool) -> StartRoute {
        isOnDeck || isCached || isAirPlay ? .engine : .streamThenHandOver
    }

    static func latestTransition(duration: TimeInterval, barSeconds: TimeInterval?) -> TimeInterval {
        max(0, duration - longestBlendBars * bar(barSeconds))
    }

    static let shortestMidTrackBlendBars: Double = 8
    static let midTrackLeadBars: Double = 4

    static func latestMidTrackTransition(duration: TimeInterval, barSeconds: TimeInterval?) -> TimeInterval {
        max(0, duration - shortestMidTrackBlendBars * bar(barSeconds))
    }

    static func midTrackHandover(position: TimeInterval, duration: TimeInterval, barSeconds: TimeInterval? = nil) -> Bool {
        guard position.isFinite, duration.isFinite, duration > 0 else { return false }
        return latestMidTrackTransition(duration: duration, barSeconds: barSeconds) - position >= midTrackLeadBars * bar(barSeconds)
    }

    static func step(
        engineReady: Bool,
        streamPlaying: Bool,
        streamPaused: Bool,
        position: TimeInterval,
        transitionAt: TimeInterval,
        barSeconds: TimeInterval?,
        leadBars: Double = EngineHandoverPolicy.leadBars
    ) -> Step {
        guard transitionAt - position >= leadBars * bar(barSeconds) else { return .stayOnStream }
        guard engineReady else { return .wait }
        return streamPlaying || streamPaused ? .handOverNow : .wait
    }

    static func alignmentCorrection(offset: TimeInterval) -> TimeInterval? {
        guard offset.isFinite, abs(offset) > correctionThreshold else { return nil }
        return offset
    }

    static func isAligned(offset: TimeInterval) -> Bool {
        offset.isFinite && abs(offset) <= alignedTolerance
    }

    static func crossfadeGains(progress: Double) -> (stream: Double, engine: Double) {
        let p = min(1, max(0, progress))
        return (1 - p, p)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func bar(_ seconds: TimeInterval?) -> TimeInterval {
        guard let seconds, seconds.isFinite, seconds > 0 else { return defaultBarSeconds }
        return seconds
    }
}
