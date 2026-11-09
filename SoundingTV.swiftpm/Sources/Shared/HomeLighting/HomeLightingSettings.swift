import Combine
import Foundation

@MainActor
final class HomeLightingSettings: ObservableObject {
    static let shared = HomeLightingSettings()

    private struct Stored: Codable {
        var intensity: LightingIntensity
        var homeID: String?
        var roomIDs: Set<String>
        var lightIDs: Set<String>
        var hasRequestedAccess: Bool
    }

    private static let defaultsKey = "red.forbes.sounding.homeLighting.v1"

    @Published var intensity: LightingIntensity { didSet { save() } }
    @Published var homeID: String? { didSet { save() } }
    @Published var roomIDs: Set<String> { didSet { save() } }
    @Published var lightIDs: Set<String> { didSet { save() } }
    @Published var hasRequestedAccess: Bool { didSet { save() } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        intensity = stored?.intensity ?? .subtle
        homeID = stored?.homeID
        roomIDs = stored?.roomIDs ?? []
        lightIDs = stored?.lightIDs ?? []
        hasRequestedAccess = stored?.hasRequestedAccess ?? false
    }

    func selectedLights(in snapshot: HomeSnapshot) -> [HomeLightInfo] {
        guard let home = snapshot.home(id: homeID) else { return [] }
        return home.rooms.flatMap { room in
            roomIDs.contains(room.id) ? room.lights : room.lights.filter { lightIDs.contains($0.id) }
        }
    }

    func isRoomSelected(_ room: HomeRoomInfo) -> Bool {
        roomIDs.contains(room.id)
    }

    func isLightSelected(_ light: HomeLightInfo) -> Bool {
        roomIDs.contains(light.roomID) || lightIDs.contains(light.id)
    }

    func setRoom(_ room: HomeRoomInfo, selected: Bool) {
        if selected {
            roomIDs.insert(room.id)
            lightIDs.subtract(room.lights.map(\.id))
        } else {
            roomIDs.remove(room.id)
        }
    }

    func setLight(_ light: HomeLightInfo, selected: Bool) {
        if selected {
            lightIDs.insert(light.id)
        } else {
            lightIDs.remove(light.id)
        }
    }

    private func save() {
        let stored = Stored(
            intensity: intensity,
            homeID: homeID,
            roomIDs: roomIDs,
            lightIDs: lightIDs,
            hasRequestedAccess: hasRequestedAccess
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
