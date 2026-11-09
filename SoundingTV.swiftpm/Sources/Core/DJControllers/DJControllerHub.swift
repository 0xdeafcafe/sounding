#if os(macOS) || os(iOS)
import Combine
import CoreMIDI
import Foundation

struct ConnectedController: Identifiable, Hashable, Sendable {
    var id: MIDIUniqueID
    var device: ControllerDeviceInfo
    var profileName: String?

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

    private var surface: (any DeckControlSurface)?
    private var access: () -> ControllerDeckAccess = { ControllerDeckAccess() }
    private var content: (MixEngine.Deck) -> ControllerDeckContent = { _ in .empty }

    private var routers: [MIDIUniqueID: ControllerInputRouter] = [:]
    private var connectedSources: [MIDIUniqueID: MIDIEndpointRef] = [:]

    private init() {}

    deinit {
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
    }

    func deckContent(_ deck: MixEngine.Deck) -> ControllerDeckContent { content(deck) }

    func isDeckLocked(_ deck: MixEngine.Deck) -> Bool {
        hasMappedController && !access().allows(content(deck))
    }

    func start() {
        guard !isRunning else { return }

        let status = MIDIClientCreateWithBlock("Sounding" as CFString, &client) { [weak self] notification in
            let messageID = notification.pointee.messageID
            guard messageID == .msgSetupChanged || messageID == .msgObjectAdded || messageID == .msgObjectRemoved else { return }
            Task { @MainActor [weak self] in
                self?.rescanSources()
            }
        }
        guard status == noErr else {
            lastError = "Couldn't open MIDI (error \(status))."
            return
        }

        let portStatus = MIDIInputPortCreateWithProtocol(client, "Sounding Input" as CFString, ._1_0, &inputPort) { [weak self] eventList, refCon in
            let sourceID = MIDIUniqueID(truncatingIfNeeded: Int(bitPattern: refCon))
            let messages = Self.parse(eventList)
            guard !messages.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.receive(messages, from: sourceID)
            }
        }
        guard portStatus == noErr else {
            lastError = "Couldn't open a MIDI input (error \(portStatus))."
            MIDIClientDispose(client)
            client = MIDIClientRef()
            return
        }

        isRunning = true
        lastError = nil
        rescanSources()
    }

    func stop() {
        guard isRunning else { return }
        MIDIPortDispose(inputPort)
        MIDIClientDispose(client)
        client = MIDIClientRef()
        inputPort = MIDIPortRef()
        controllers = []
        routers = [:]
        connectedSources = [:]
        isRunning = false
    }

    private func rescanSources() {
        guard isRunning else { return }

        var found: [ConnectedController] = []
        var seen: [MIDIUniqueID: MIDIEndpointRef] = [:]
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }

            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID)
            guard uniqueID != 0 else { continue }

            let device = ControllerDeviceInfo(
                name: Self.stringProperty(source, kMIDIPropertyDisplayName)
                    ?? Self.stringProperty(source, kMIDIPropertyName)
                    ?? "MIDI Device",
                manufacturer: Self.stringProperty(source, kMIDIPropertyManufacturer) ?? "",
                model: Self.stringProperty(source, kMIDIPropertyModel) ?? ""
            )
            if connectedSources[uniqueID] == nil {
                MIDIPortConnectSource(inputPort, source, UnsafeMutableRawPointer(bitPattern: Int(uniqueID)))
            }
            seen[uniqueID] = source
            found.append(ConnectedController(id: uniqueID, device: device, profileName: ControllerProfiles.profile(for: device)?.name))
        }

        for (id, source) in connectedSources where seen[id] == nil {
            MIDIPortDisconnectSource(inputPort, source)
        }
        connectedSources = seen
        controllers = found
        rebuildRouters()
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
