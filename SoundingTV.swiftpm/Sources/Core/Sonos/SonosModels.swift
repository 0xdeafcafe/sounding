import Foundation

struct SonosPlayer: Identifiable, Hashable, Sendable {
    let id: String
    let roomName: String
    let host: String
    let port: Int
    let modelName: String?
    let isInvisible: Bool

    func withModelName(_ modelName: String?) -> SonosPlayer {
        SonosPlayer(id: id, roomName: roomName, host: host, port: port, modelName: modelName, isInvisible: isInvisible)
    }
}

struct SonosGroup: Identifiable, Hashable, Sendable {
    let id: String
    let coordinator: SonosPlayer
    let members: [SonosPlayer]
    var displayName: String
    var satellites: [SonosPlayer] = []

    static func displayName(coordinator: SonosPlayer, members: [SonosPlayer]) -> String {
        let others = members
            .filter { $0.id != coordinator.id }
            .map(\.roomName)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ([coordinator.roomName] + others).joined(separator: " + ")
    }
}

extension SonosGroup {
    init(id: String, coordinator: SonosPlayer, members: [SonosPlayer], satellites: [SonosPlayer] = []) {
        let ordered = [coordinator] + members
            .filter { $0.id != coordinator.id }
            .sorted { $0.roomName.localizedStandardCompare($1.roomName) == .orderedAscending }
        self.init(
            id: id,
            coordinator: coordinator,
            members: ordered,
            displayName: SonosGroup.displayName(coordinator: coordinator, members: members),
            satellites: satellites
        )
    }

    var allPlayers: [SonosPlayer] { members + satellites }
}

enum SonosTransportState: String, Sendable {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"
    case noMedia = "NO_MEDIA_PRESENT"
}

struct SonosNowPlaying: Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var artworkURL: URL?
    var trackURI: String?
    var position: TimeInterval?
    var duration: TimeInterval?
    var streamContent: String?
}

struct SonosSOAPError: Error, Equatable {
    let httpStatus: Int
    let upnpErrorCode: Int?
}

enum SonosResponseError: Error, Equatable {
    case malformed(String)
}
