import Foundation
#if canImport(HomeKit)
import HomeKit
#endif

@MainActor
protocol HomeLightingBackend: LightWriting {
    var snapshot: HomeSnapshot { get }
    var onChange: (@MainActor () -> Void)? { get set }
    func requestAccess()
    func currentState(of lightID: String) -> LightState?
}

enum HomeLightingWriteError: Error {
    case unknownLight
}

#if canImport(HomeKit)

@MainActor
final class HomeKitLightingBackend: NSObject, HomeLightingBackend, HMHomeManagerDelegate {
    private(set) var snapshot: HomeSnapshot = .unrequested
    var onChange: (@MainActor () -> Void)?

    private var manager: HMHomeManager?
    private var services: [String: HMService] = [:]

    func requestAccess() {
        guard manager == nil else { return }
        snapshot.access = .waiting
        let manager = HMHomeManager()
        manager.delegate = self
        self.manager = manager
        onChange?()
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor [weak self] in self?.rebuild() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor [weak self] in self?.rebuild() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        Task { @MainActor [weak self] in self?.rebuild() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        Task { @MainActor [weak self] in self?.rebuild() }
    }

    private func rebuild() {
        guard let manager else { return }
        let status = manager.authorizationStatus
        if status.contains(.restricted) || (status.contains(.determined) && !status.contains(.authorized)) {
            services.removeAll()
            snapshot = HomeSnapshot(access: .denied, homes: [])
            onChange?()
            return
        }
        guard status.contains(.authorized) else {
            snapshot = HomeSnapshot(access: .waiting, homes: [])
            onChange?()
            return
        }

        var services: [String: HMService] = [:]
        let homes: [HomeInfo] = manager.homes.map { home in
            var byRoom: [String: [HomeLightInfo]] = [:]
            var roomNames: [String: String] = [:]
            for accessory in home.accessories {
                let room = accessory.room ?? home.roomForEntireHome()
                for service in accessory.services where service.serviceType == HMServiceTypeLightbulb {
                    let capabilities = Self.capabilities(of: service)
                    guard capabilities.contains(.power) || capabilities.contains(.brightness) else { continue }
                    let id = service.uniqueIdentifier.uuidString
                    services[id] = service
                    let roomID = room.uniqueIdentifier.uuidString
                    roomNames[roomID] = room.name
                    let name = accessory.services.filter { $0.serviceType == HMServiceTypeLightbulb }.count > 1
                        ? service.name
                        : accessory.name
                    byRoom[roomID, default: []].append(
                        HomeLightInfo(id: id, name: name, roomID: roomID, capabilities: capabilities)
                    )
                }
            }
            let rooms = byRoom.map { roomID, lights in
                HomeRoomInfo(
                    id: roomID,
                    name: roomNames[roomID] ?? "",
                    lights: lights.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return HomeInfo(
                id: home.uniqueIdentifier.uuidString,
                name: home.name,
                isPrimary: home.isPrimary,
                rooms: rooms
            )
        }
        self.services = services
        snapshot = HomeSnapshot(access: .ready, homes: homes)
        onChange?()
    }

    private static func capabilities(of service: HMService) -> LightCapabilities {
        var out: LightCapabilities = []
        let types = Set(service.characteristics.map(\.characteristicType))
        if types.contains(HMCharacteristicTypePowerState) { out.insert(.power) }
        if types.contains(HMCharacteristicTypeBrightness) { out.insert(.brightness) }
        if types.contains(HMCharacteristicTypeHue), types.contains(HMCharacteristicTypeSaturation) { out.insert(.color) }
        return out
    }

    func currentState(of lightID: String) -> LightState? {
        guard let service = services[lightID] else { return nil }
        func number(_ type: String) -> Double? {
            (service.characteristics.first { $0.characteristicType == type }?.value as? NSNumber)?.doubleValue
        }
        let isOn = (number(HMCharacteristicTypePowerState) ?? 1) > 0.5
        return LightState(
            isOn: isOn,
            color: LightColor(
                hue: number(HMCharacteristicTypeHue) ?? LightColor.warmGlow.hue,
                saturation: (number(HMCharacteristicTypeSaturation) ?? 0) / 100
            ),
            brightness: (number(HMCharacteristicTypeBrightness) ?? 100) / 100
        )
    }

    func write(_ changes: LightWriteChanges, to lightID: String) async throws {
        guard let service = services[lightID] else { throw HomeLightingWriteError.unknownLight }
        var writes: [(HMCharacteristic, NSNumber)] = []
        func add(_ type: String, _ value: NSNumber?) {
            guard let value, let characteristic = service.characteristics.first(where: { $0.characteristicType == type }) else { return }
            writes.append((characteristic, value))
        }
        add(HMCharacteristicTypePowerState, changes.isOn.map { NSNumber(value: $0) })
        add(HMCharacteristicTypeHue, changes.hue.map { NSNumber(value: Float($0)) })
        add(HMCharacteristicTypeSaturation, changes.saturation.map { NSNumber(value: Float(($0 * 100).rounded())) })
        add(HMCharacteristicTypeBrightness, changes.brightness.map { NSNumber(value: Int(($0 * 100).rounded())) })
        guard !writes.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = WriteGate(remaining: writes.count, continuation: continuation)
            for (characteristic, value) in writes {
                characteristic.writeValue(value) { @Sendable error in gate.finish(error) }
            }
        }
    }
}

private final class WriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var firstError: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    init(remaining: Int, continuation: CheckedContinuation<Void, Error>) {
        self.remaining = remaining
        self.continuation = continuation
    }

    func finish(_ error: Error?) {
        lock.lock()
        if let error, firstError == nil { firstError = error }
        remaining -= 1
        let done = remaining == 0
        let continuation = done ? self.continuation : nil
        if done { self.continuation = nil }
        let error = firstError
        lock.unlock()
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

#endif

#if DEBUG

@MainActor
final class FakeHomeLightingBackend: HomeLightingBackend {
    enum Story: String {
        case priming, waiting, denied, noHome, noLights, ready
    }

    private(set) var snapshot: HomeSnapshot
    var onChange: (@MainActor () -> Void)?
    private let story: Story
    private var states: [String: LightState] = [:]
    private(set) var writes: [(lightID: String, changes: LightWriteChanges)] = []

    init(story: Story) {
        self.story = story
        snapshot = story == .priming ? .unrequested : Self.snapshot(for: story)
    }

    func requestAccess() {
        guard snapshot.access == .notRequested else { return }
        snapshot = Self.snapshot(for: .ready)
        onChange?()
    }

    func currentState(of lightID: String) -> LightState? {
        states[lightID] ?? LightState(color: .warmGlow, brightness: 0.8)
    }

    func write(_ changes: LightWriteChanges, to lightID: String) async throws {
        writes.append((lightID, changes))
        var state = states[lightID] ?? LightState(color: .warmGlow, brightness: 0.8)
        if let isOn = changes.isOn { state.isOn = isOn }
        if let hue = changes.hue { state.color.hue = hue }
        if let saturation = changes.saturation { state.color.saturation = saturation }
        if let brightness = changes.brightness { state.brightness = brightness }
        states[lightID] = state
    }

    private static func snapshot(for story: Story) -> HomeSnapshot {
        switch story {
        case .priming: return .unrequested
        case .waiting: return HomeSnapshot(access: .waiting, homes: [])
        case .denied: return HomeSnapshot(access: .denied, homes: [])
        case .noHome: return HomeSnapshot(access: .ready, homes: [])
        case .noLights:
            return HomeSnapshot(access: .ready, homes: [
                HomeInfo(id: "home", name: "Home", isPrimary: true, rooms: [])
            ])
        case .ready:
            let all: LightCapabilities = [.power, .brightness, .color]
            return HomeSnapshot(access: .ready, homes: [
                HomeInfo(id: "home", name: "Home", isPrimary: true, rooms: [
                    HomeRoomInfo(id: "living", name: "Living Room", lights: [
                        HomeLightInfo(id: "living.floor", name: "Floor Lamp", roomID: "living", capabilities: all),
                        HomeLightInfo(id: "living.strip", name: "Light Strip", roomID: "living", capabilities: all),
                        HomeLightInfo(id: "living.shelf", name: "Shelf", roomID: "living", capabilities: [.power, .brightness]),
                    ]),
                    HomeRoomInfo(id: "kitchen", name: "Kitchen", lights: [
                        HomeLightInfo(id: "kitchen.pendant", name: "Pendant", roomID: "kitchen", capabilities: all),
                    ]),
                ]),
                HomeInfo(id: "studio", name: "Studio", isPrimary: false, rooms: [
                    HomeRoomInfo(id: "studio.main", name: "Studio", lights: [
                        HomeLightInfo(id: "studio.bar", name: "Light Bar", roomID: "studio.main", capabilities: all),
                    ]),
                ]),
            ])
        }
    }
}

#endif
