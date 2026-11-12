#if os(macOS) || os(iOS)
import Combine
import CoreMIDI
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ConnectedController: Identifiable, Hashable, Sendable {
    var id: MIDIUniqueID
    var device: ControllerDeviceInfo
    var profileName: String?
    var isNetwork = false
    var hasLights = false

    var name: String { device.name }
}

@MainActor
final class DJControllerHub: ObservableObject {
    static let shared = DJControllerHub()

    @Published private(set) var controllers: [ConnectedController] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    let rawMessages = PassthroughSubject<ControllerMIDIMessage, Never>()

    var hasMappedController: Bool { controllers.contains { $0.profileName != nil } }

    private nonisolated(unsafe) var client = MIDIClientRef()
    private nonisolated(unsafe) var inputPort = MIDIPortRef()
    private nonisolated(unsafe) var outputPort = MIDIPortRef()

    private var surface: (any DeckControlSurface)?
    private var access: () -> ControllerDeckAccess = { ControllerDeckAccess() }
    private var content: (MixEngine.Deck) -> ControllerDeckContent = { _ in .empty }

    private var routers: [MIDIUniqueID: ControllerInputRouter] = [:]
    private var connectedSources: [MIDIUniqueID: MIDIEndpointRef] = [:]
    private var feedbackLinks: [MIDIUniqueID: FeedbackLink] = [:]
    private var feedbackTask: Task<Void, Never>?
    private var networkWatch: AnyCancellable?
    private var terminateObserver: NSObjectProtocol?
    private let clockOrigin = Date()

    private struct FeedbackLink {
        var destination: MIDIEndpointRef
        var mapping: ControllerFeedbackMapping
        var throttle = ControllerFeedbackThrottle()
    }

    private init() {}

    deinit {
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func attach(
        surface: any DeckControlSurface,
        access: @escaping () -> ControllerDeckAccess,
        content: @escaping (MixEngine.Deck) -> ControllerDeckContent
    ) {
        self.surface = surface
        self.access = access
        self.content = content
        rebuildRouters()
        refreshFeedback()
    }

    func deckContent(_ deck: MixEngine.Deck) -> ControllerDeckContent { content(deck) }

    func isDeckLocked(_ deck: MixEngine.Deck) -> Bool {
        hasMappedController && !access().allows(content(deck))
    }

    func start() {
        guard !isRunning else { return }

        let status = MIDIClientCreateWithBlock("Sounding" as CFString, &client, Self.makeNotifyBlock())
        guard status == noErr else {
            lastError = "Couldn't open MIDI (error \(status))."
            return
        }

        let portStatus = MIDIInputPortCreateWithProtocol(client, "Sounding Input" as CFString, ._1_0, &inputPort, Self.makeReceiveBlock())
        guard portStatus == noErr else {
            lastError = "Couldn't open a MIDI input (error \(portStatus))."
            MIDIClientDispose(client)
            client = MIDIClientRef()
            return
        }

        if MIDIOutputPortCreate(client, "Sounding Output" as CFString, &outputPort) != noErr {
            outputPort = MIDIPortRef()
        }

        isRunning = true
        lastError = nil
        NetworkMIDI.shared.restore()
        networkWatch = NetworkMIDI.shared.$connectedNames
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.rescanSources() }
        if terminateObserver == nil {
            terminateObserver = NotificationCenter.default.addObserver(
                forName: Self.terminateNotification,
                object: nil,
                queue: .main,
                using: Self.makeTerminateObserver()
            )
        }
        rescanSources()
    }

    func stop() {
        guard isRunning else { return }
        blackoutAll()
        feedbackTask?.cancel()
        feedbackTask = nil
        networkWatch = nil
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        MIDIPortDispose(inputPort)
        MIDIClientDispose(client)
        client = MIDIClientRef()
        inputPort = MIDIPortRef()
        outputPort = MIDIPortRef()
        controllers = []
        routers = [:]
        connectedSources = [:]
        feedbackLinks = [:]
        isRunning = false
    }

    // MARK: Callbacks

    private nonisolated static func makeNotifyBlock() -> MIDINotifyBlock {
        { notification in
            let messageID = notification.pointee.messageID
            guard messageID == .msgSetupChanged || messageID == .msgObjectAdded || messageID == .msgObjectRemoved else { return }
            Task { @MainActor in
                DJControllerHub.shared.rescanSources()
            }
        }
    }

    private static var terminateNotification: Notification.Name {
        #if os(macOS)
        NSApplication.willTerminateNotification
        #else
        UIApplication.willTerminateNotification
        #endif
    }

    private nonisolated static func makeTerminateObserver() -> @Sendable (Notification) -> Void {
        { _ in
            MainActor.assumeIsolated {
                DJControllerHub.shared.blackoutAll()
            }
        }
    }

    private nonisolated static func makeReceiveBlock() -> MIDIReceiveBlock {
        { eventList, refCon in
            let sourceID = MIDIUniqueID(truncatingIfNeeded: Int(bitPattern: refCon))
            let messages = parse(eventList)
            guard !messages.isEmpty else { return }
            Task { @MainActor in
                DJControllerHub.shared.receive(messages, from: sourceID)
            }
        }
    }

    // MARK: Devices

    private func rescanSources() {
        guard isRunning else { return }

        var found: [ConnectedController] = []
        var seen: [MIDIUniqueID: MIDIEndpointRef] = [:]
        var destinations: [MIDIUniqueID: MIDIEndpointRef] = [:]
        let allDestinations = Self.destinations()
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }

            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID)
            guard uniqueID != 0 else { continue }

            let isSession = NetworkMIDI.shared.isSessionEndpoint(source)
            let isNetwork = isSession || NetworkMIDI.isNetworkEndpoint(source)
            let name = Self.stringProperty(source, kMIDIPropertyDisplayName)
                ?? Self.stringProperty(source, kMIDIPropertyName)
                ?? "MIDI Device"
            var device = ControllerDeviceInfo(
                name: name,
                manufacturer: Self.stringProperty(source, kMIDIPropertyManufacturer) ?? "",
                model: Self.stringProperty(source, kMIDIPropertyModel) ?? ""
            )
            if isSession, !NetworkMIDI.shared.connectedNames.isEmpty {
                device.model = NetworkMIDI.shared.connectedNames.joined(separator: ", ")
            }
            if connectedSources[uniqueID] == nil {
                MIDIPortConnectSource(inputPort, source, UnsafeMutableRawPointer(bitPattern: Int(uniqueID)))
            }
            seen[uniqueID] = source
            let profile = ControllerProfiles.profile(for: device)
            let destination = Self.destination(pairedWith: source, name: name, among: allDestinations)
            if let destination { destinations[uniqueID] = destination }
            found.append(ConnectedController(
                id: uniqueID,
                device: device,
                profileName: profile?.name,
                isNetwork: isNetwork,
                hasLights: destination != nil && outputPort != 0 && profile?.feedback.isEmpty == false
            ))
        }

        for (id, source) in connectedSources where seen[id] == nil {
            MIDIPortDisconnectSource(inputPort, source)
        }
        connectedSources = seen
        if found != controllers { controllers = found }
        rebuildRouters()
        rebuildFeedback(destinations: destinations)
    }

    private func rebuildRouters() {
        guard let surface else {
            routers = [:]
            return
        }
        var rebuilt: [MIDIUniqueID: ControllerInputRouter] = [:]
        for controller in controllers {
            guard let profile = ControllerProfiles.profile(for: controller.device) else { continue }
            if let existing = routers[controller.id], existing.profile.id == profile.id {
                rebuilt[controller.id] = existing
            } else {
                rebuilt[controller.id] = ControllerInputRouter(profile: profile, surface: surface, access: { [weak self] in
                    self?.access() ?? ControllerDeckAccess()
                }, content: { [weak self] deck in
                    self?.content(deck) ?? .empty
                })
            }
        }
        routers = rebuilt
    }

    private func receive(_ messages: [ControllerMIDIMessage], from sourceID: MIDIUniqueID) {
        let router = routers[sourceID]
        for message in messages {
            rawMessages.send(message)
            router?.handle(message)
        }
    }

    // MARK: Feedback

    private func rebuildFeedback(destinations: [MIDIUniqueID: MIDIEndpointRef]) {
        var rebuilt: [MIDIUniqueID: FeedbackLink] = [:]
        for controller in controllers where controller.hasLights {
            guard let destination = destinations[controller.id],
                  let profile = ControllerProfiles.profile(for: controller.device) else { continue }
            if var existing = feedbackLinks[controller.id], existing.mapping == profile.feedback {
                if existing.destination != destination {
                    existing.destination = destination
                    existing.throttle.reset()
                }
                rebuilt[controller.id] = existing
            } else {
                rebuilt[controller.id] = FeedbackLink(destination: destination, mapping: profile.feedback)
            }
        }
        feedbackLinks = rebuilt
        refreshFeedback()
    }

    private func refreshFeedback() {
        let needed = surface != nil && !feedbackLinks.isEmpty && isRunning
        if needed, feedbackTask == nil {
            feedbackTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let interval = self.flushFeedback()
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
        } else if !needed {
            feedbackTask?.cancel()
            feedbackTask = nil
        }
    }

    private func flushFeedback() -> TimeInterval {
        guard let surface, !feedbackLinks.isEmpty else { return 0.25 }
        let decks = MixEngine.Deck.allCases
        let access = access()
        var states: [MixEngine.Deck: DeckFeedbackState] = [:]
        for deck in decks {
            var state = surface.currentFeedback(for: deck)
            state.isLocked = !access.allows(content(deck))
            states[deck] = state
        }
        let clock = Date().timeIntervalSince(clockOrigin)
        for id in Array(feedbackLinks.keys) {
            guard var link = feedbackLinks[id] else { continue }
            let desired = ControllerFeedbackRenderer.render(link.mapping, states: states, clock: clock)
            let messages = link.throttle.take(desired, now: clock)
            feedbackLinks[id] = link
            send(messages, to: link.destination)
        }
        let busy = states.values.contains { $0.isLoaded && !$0.isLocked }
        return busy ? 1.0 / 25 : 0.25
    }

    private func blackoutAll() {
        for link in feedbackLinks.values {
            send(ControllerFeedbackRenderer.blackout(link.mapping), to: link.destination)
        }
    }

    private func send(_ messages: [ControllerMIDIMessage], to destination: MIDIEndpointRef) {
        guard !messages.isEmpty, outputPort != 0, destination != 0 else { return }
        Self.send(messages.map(\.universalPacketWord), port: outputPort, destination: destination)
    }

    private nonisolated static func send(_ words: [UInt32], port: MIDIPortRef, destination: MIDIEndpointRef) {
        let chunks = stride(from: 0, to: words.count, by: 32).map { Array(words[$0..<min($0 + 32, words.count)]) }
        let builder = MIDIEventList.Builder(inProtocol: ._1_0, wordSize: words.count + chunks.count * 8 + 16)
        for chunk in chunks {
            _ = builder.append(timestamp: 0, words: chunk)
        }
        _ = builder.withUnsafePointer { MIDISendEventList(port, destination, $0) }
    }

    // MARK: Endpoints

    private static func destinations() -> [(endpoint: MIDIEndpointRef, name: String)] {
        var result: [(endpoint: MIDIEndpointRef, name: String)] = []
        for index in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(index)
            guard destination != 0 else { continue }
            let name = stringProperty(destination, kMIDIPropertyDisplayName) ?? stringProperty(destination, kMIDIPropertyName) ?? ""
            result.append((destination, name))
        }
        return result
    }

    private static func destination(
        pairedWith source: MIDIEndpointRef,
        name: String,
        among destinations: [(endpoint: MIDIEndpointRef, name: String)]
    ) -> MIDIEndpointRef? {
        var entity = MIDIEntityRef()
        if MIDIEndpointGetEntity(source, &entity) == noErr, entity != 0, MIDIEntityGetNumberOfDestinations(entity) > 0 {
            let destination = MIDIEntityGetDestination(entity, 0)
            if destination != 0 { return destination }
        }
        return destinations.first { $0.name == name }?.endpoint
    }

    private static func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr, let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    private nonisolated static func parse(_ eventList: UnsafePointer<MIDIEventList>) -> [ControllerMIDIMessage] {
        var result: [ControllerMIDIMessage] = []
        for packet in eventList.unsafeSequence() {
            result += ControllerMIDIMessage.parse(universalPacketWords: Array(MIDIEventPacket.WordCollection(packet)))
        }
        return result
    }
}
#endif
