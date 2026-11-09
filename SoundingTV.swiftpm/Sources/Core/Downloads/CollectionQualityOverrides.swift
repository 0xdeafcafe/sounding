import Foundation
import SwiftUI
import Combine

enum QualitySizeEstimator {

    static func approximateBitrateKbps(for ceiling: QualityCeiling) -> Int? {
        switch ceiling {
        case .efficient: return 72
        case .standard:  return 128
        case .high:      return 256
        case .maximum:   return nil
        }
    }

    static func approximateMBPerHour(for ceiling: QualityCeiling) -> Double? {
        guard let kbps = approximateBitrateKbps(for: ceiling) else { return nil }
        return Double(kbps) * 0.45
    }

    static func summaryLine() -> String {
        QualityCeiling.allCases.map { tier in
            if let mb = approximateMBPerHour(for: tier) {
                return "\(tier.displayName) ~\(Int(mb.rounded())) MB/hr"
            }
            return "\(tier.displayName) varies, no cap"
        }.joined(separator: " · ")
    }

    static func estimatedBytes(durationSeconds: TimeInterval, ceiling: QualityCeiling) -> Int64 {
        let kbps = approximateBitrateKbps(for: ceiling) ?? approximateBitrateKbps(for: .high) ?? 256
        let bytesPerSecond = Double(kbps) * 1000 / 8
        return Int64((bytesPerSecond * max(0, durationSeconds)).rounded())
    }

    static func estimatedBytes(for playlist: Playlist, ceiling: QualityCeiling) -> Int64 {
        estimatedBytes(durationSeconds: playlist.duration, ceiling: ceiling)
    }
}

enum CollectionPolicyID {
    static let likedTracks = "likes"
}

@MainActor
protocol CollectionPolicyApplier {
    func applyCollectionPolicy(tracks: [Track], collectionId: String)
}

@MainActor
final class CollectionQualityOverrideStore: ObservableObject {
    static let shared = CollectionQualityOverrideStore()

    @Published private(set) var overrides: [String: QualityCeiling] = [:]
    @Published private(set) var policies: [String: CollectionPolicy] = [:]

    private static let legacyDefaultsKey = "collectionQualityOverrides.v1"
    private static let defaultsKey = "collectionPolicies.v2"
    private var settingsCancellable: AnyCancellable?

    private init() {
        load()
        let settings = SettingsStore.shared
        if settings.hasStoredValue(SettingKeys.CollectionPolicies.self) {
            policies = settings.collectionPolicies
            rebuildOverrides()
        } else if !policies.isEmpty {
            settings.setCollectionPolicies(policies)
        }
        settingsCancellable = settings.$collectionPolicies
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] policies in
                guard let self, policies != self.policies else { return }
                self.policies = policies
                self.rebuildOverrides()
                self.saveLocalCopy()
            }
    }

    func override(for collectionId: String) -> QualityCeiling? {
        policies[collectionId]?.qualityCeiling ?? overrides[collectionId]
    }

    func policy(for collectionId: String) -> CollectionPolicy {
        policies[collectionId] ?? .standard
    }

    func updatePolicy(for collectionId: String, _ change: (inout CollectionPolicy) -> Void) {
        var policy = self.policy(for: collectionId)
        change(&policy)
        if policy.djMode == .normal { policy.isDefaultDJSource = false }
        policy.maximumTransitionBars = min(32, max(4, policy.maximumTransitionBars))

        if policy.isDefaultDJSource {
            for id in Array(policies.keys) where id != collectionId {
                policies[id]?.isDefaultDJSource = false
            }
        }
        policies[collectionId] = policy
        rebuildOverrides()
        save()
    }

    func resetPolicy(for collectionId: String) {
        policies.removeValue(forKey: collectionId)
        rebuildOverrides()
        save()
    }

    var defaultDJCollectionId: String? {
        policies.first(where: { $0.value.isDefaultDJSource && $0.value.djMode != .normal })?.key
    }

    func effectiveCeiling(for collectionId: String?, default defaultCeiling: QualityCeiling) -> QualityCeiling {
        guard let collectionId, let override = override(for: collectionId) else { return defaultCeiling }
        return override
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: CollectionPolicy].self, from: data) {
            policies = decoded
            rebuildOverrides()
            return
        }

        guard let data = UserDefaults.standard.data(forKey: Self.legacyDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: QualityCeiling].self, from: data) else { return }
        policies = decoded.mapValues { ceiling in
            var policy = CollectionPolicy.standard
            policy.qualityCeiling = ceiling
            return policy
        }
        rebuildOverrides()
        save()
    }

    private func save() {
        saveLocalCopy()
        SettingsStore.shared.setCollectionPolicies(policies)
    }

    private func saveLocalCopy() {
        guard let data = try? JSONEncoder().encode(policies) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func rebuildOverrides() {
        overrides = policies.compactMapValues(\.qualityCeiling)
    }

    #if DEBUG
    #endif
}

struct CollectionPolicyEditor: View {
    let collectionId: String
    let collectionName: String
    let collectionKind: CollectionKind
    let tracks: [Track]
    let applier: any CollectionPolicyApplier

    @ObservedObject private var store = CollectionQualityOverrideStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @StateObject private var prompter = DownloadRequestPrompter()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        NavigationStack {
            policyForm
            .navigationTitle(collectionName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #endif
    }

    private var policyForm: some View {
        Form {
            Section {
                Toggle("Keep Downloaded", isOn: keepDownloadedBinding)
            } header: {
                Text("Downloads")
            } footer: {
                Text(downloadSummary)
            }

            Section {
                Picker("When Played", selection: binding(\.djMode)) {
                    ForEach(DJCollectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if policy.djMode != .normal {
                    Toggle("Default DJ Source", isOn: binding(\.isDefaultDJSource))
                    Picker("Style", selection: binding(\.djProfileId)) {
                        ForEach(DJProfile.all) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    }
                    Picker("Track Order", selection: binding(\.queueOrder)) {
                        ForEach(DJQueueOrderPolicy.allCases) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                    Picker("Long Mixes and Sets", selection: binding(\.setHandling)) {
                        ForEach(DJSetHandling.allCases) { handling in
                            Text(handling.displayName).tag(handling)
                        }
                    }
                    .help("Skip Sets leaves uploads of 20 minutes or more out of Auto Mix. They still play when you choose them.")
                    Toggle("Avoid Vocal Overlap", isOn: binding(\.avoidVocalOverlap))
                    Picker("Longest Transition", selection: binding(\.maximumTransitionBars)) {
                        ForEach([4, 8, 16, 32], id: \.self) { bars in
                            Text("\(bars) bars").tag(bars)
                        }
                    }
                }
            } header: {
                Text("Auto Mix")
            } footer: {
                Text(policy.djMode.explanation)
            }

            Section {
                Button("Reset Collection Settings", role: .destructive) {
                    store.resetPolicy(for: collectionId)
                    applier.applyCollectionPolicy(tracks: tracks, collectionId: collectionId)
                }
            }
        }
        .downloadRequestPrompts(prompter)
    }

    #if os(macOS)
    private var macOSBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(collectionName)
                .font(.title2.weight(.semibold))
                .lineLimit(1)

            policyForm
                .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
    #endif

    private var policy: CollectionPolicy { store.policy(for: collectionId) }

    private var keepDownloadedBinding: Binding<Bool> {
        Binding(
            get: { downloads.isCollectionDownloaded(collectionId) },
            set: { keep in
                if keep {
                    let descriptor = DownloadCollectionDescriptor.forCollectionID(collectionId, title: collectionName)
                    let known = tracks
                    prompter.request { confirmed in
                        await DownloadManager.shared.download(collection: descriptor, tracks: known, confirmed: confirmed)
                    }
                } else {
                    downloads.removeDownload(.collection(collectionId))
                }
            }
        )
    }

    private var downloadSummary: String {
        let seconds = tracks.reduce(0) { $0 + $1.duration }
        let bytes = QualitySizeEstimator.estimatedBytes(durationSeconds: seconds, ceiling: downloads.quality)
        return "Keeps this \(collectionKind.displayName.lowercased()) in sync, about \(DownloadsFormat.bytes(bytes))."
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<CollectionPolicy, Value>) -> Binding<Value> {
        Binding(
            get: { store.policy(for: collectionId)[keyPath: keyPath] },
            set: { value in
                store.updatePolicy(for: collectionId) { $0[keyPath: keyPath] = value }
                applier.applyCollectionPolicy(tracks: tracks, collectionId: collectionId)
            }
        )
    }
}

struct CacheUsage: Equatable, Sendable {
    var artworkBytes: Int64 = 0
    var analysisBytes: Int64 = 0
    var djSourceBytes: Int64 = 0
    var urlCacheBytes: Int64 = 0

    var totalBytes: Int64 { artworkBytes + analysisBytes + djSourceBytes + urlCacheBytes }

    static func cachesDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    static func measure() async -> CacheUsage {
        let caches = cachesDirectory()
        let artworkDirectory = caches.appendingPathComponent("Artwork", isDirectory: true)
        let djDirectory = caches.appendingPathComponent("MixEngine", isDirectory: true)
        let directoryBytes = await Task.detached(priority: .utility) {
            (
                DownloadStoragePolicy.onDiskBytes(in: [artworkDirectory]),
                DownloadStoragePolicy.onDiskBytes(in: [djDirectory])
            )
        }.value
        return CacheUsage(
            artworkBytes: directoryBytes.0,
            analysisBytes: await AnalysisCache.shared.usedBytes,
            djSourceBytes: directoryBytes.1,
            urlCacheBytes: Int64(URLCache.shared.currentDiskUsage)
        )
    }

    @MainActor
    static func clearArtwork() async {
        ArtworkCache.shared.purgeMemory()
        await SCArtworkStore.shared.removeAll()
    }

    @MainActor
    static func clearCaches() async {
        MixEngine.shared.clearCache()
        PlaybackSourceResolver.shared.clearResolutionCache()
        URLCache.shared.removeAllCachedResponses()
        await SCArtworkStore.shared.removeAll()
        await AnalysisCache.shared.removeAll(keepingUserCorrections: true)
    }
}
