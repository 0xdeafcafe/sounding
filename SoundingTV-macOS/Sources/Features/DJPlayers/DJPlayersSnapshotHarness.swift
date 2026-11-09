#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum DJPlayersSnapshotHarness {
    static func run() async {
        let env = ProcessInfo.processInfo.environment
        let stateName = env["SOUNDING_TV_MAC_DJ_PLAYERS_STATE"] ?? "disconnected"
        let surface = env["SOUNDING_TV_MAC_DJ_PLAYERS_SURFACE"] ?? "settings"
        let dark = env["SOUNDING_TV_MAC_DJ_PLAYERS_SCHEME"] == "dark"

        installFixture(named: stateName)

        let height = env["SOUNDING_TV_MAC_DJ_PLAYERS_HEIGHT"].flatMap(Double.init)
        let size: NSSize = surface == "panel" ? NSSize(width: 420, height: 460) : NSSize(width: 680, height: height ?? 560)
        let content: AnyView = surface == "panel"
            ? AnyView(DJPlayersDecksPanel(openSettings: {}))
            : AnyView(DJPlayersSettingsTab())
        let hosting = NSHostingView(rootView: content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key))
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = DJPlayersSnapshotWindow(contentRect: NSRect(x: 40, y: 40, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()

        try? await Task.sleep(for: .seconds(1.2))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.close()
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.close()
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        print("[DJ_PLAYERS_SNAPSHOT_B64]\(png.base64EncodedString())")
        fflush(stdout)
        exit(0)
    }

    private static let interfaces = [
        DJLinkInterface(
            bsdName: "en7", displayName: "USB 10/100/1000 LAN", index: 7,
            ip: DJLinkIPv4(169, 254, 41, 7), netmask: DJLinkIPv4(255, 255, 0, 0),
            broadcast: DJLinkIPv4(169, 254, 255, 255), mac: DJLinkMAC([0x3c, 0x18, 0xa0, 0x11, 0x22, 0x33])
        ),
        DJLinkInterface(
            bsdName: "en0", displayName: "Wi-Fi", index: 4,
            ip: DJLinkIPv4(192, 168, 1, 23), netmask: DJLinkIPv4(255, 255, 255, 0),
            broadcast: DJLinkIPv4(192, 168, 1, 255), mac: DJLinkMAC([0xa4, 0x83, 0xe7, 0x01, 0x02, 0x03])
        ),
    ]

    private static func player(
        _ number: Int,
        _ name: String,
        activity: DJPlayerActivity,
        bpm: Double?,
        pitch: Double = 1,
        master: Bool = false,
        onAir: Bool = false,
        trackId: UInt32? = nil,
        beat: Int? = nil,
        playhead: Int? = nil,
        length: Int? = nil
    ) -> DJPlayer {
        var status = DJPlayerStatus()
        status.activity = activity
        status.trackBPM = bpm
        status.pitch = pitch
        status.isMaster = master
        status.isOnAir = onAir
        status.track = trackId.map { DJPlayerTrackKey(sourcePlayer: number, slot: .usb, trackType: 0x01, rekordboxId: $0) }
        status.beatNumber = beat
        status.playheadMillis = playhead
        status.trackLengthSeconds = length
        return DJPlayer(
            number: number, name: name, ip: DJLinkIPv4(169, 254, 41, UInt8(10 + number)),
            mac: .zero, lastSeen: 0, reportsAsMixer: false, status: status
        )
    }

    private static func mixer(_ name: String, bpm: Double) -> DJPlayer {
        var status = DJPlayerStatus()
        status.activity = .playing
        status.trackBPM = bpm
        return DJPlayer(number: 33, name: name, ip: DJLinkIPv4(169, 254, 41, 50), mac: .zero, lastSeen: 0, reportsAsMixer: true, status: status)
    }

    private static func installFixture(named name: String) {
        let controller = DJPlayersController.shared
        let nxs2Rig = [
            player(1, "CDJ-2000NXS2", activity: .playing, bpm: 124, pitch: 1.0161, master: true, onAir: true, trackId: 1204, beat: 233),
            player(2, "CDJ-2000NXS2", activity: .cued, bpm: 126, pitch: 0.9842, trackId: 877, beat: 1),
            mixer("DJM-900NXS2", bpm: 126),
        ]
        let cdj3000Rig = [
            player(1, "CDJ-3000", activity: .playing, bpm: 130, master: true, onAir: true, trackId: 3311, playhead: 196_000, length: 412),
            player(2, "CDJ-3000", activity: .paused, bpm: 128, pitch: 1.0156, trackId: 3312, playhead: 31_500, length: 365),
            player(5, "CDJ-3000", activity: .empty, bpm: nil),
            mixer("DJM-A9", bpm: 130),
        ]
        let titles: [DJPlayerTrackKey: DJPlayersTrackInfo] = [
            DJPlayerTrackKey(sourcePlayer: 1, slot: .usb, trackType: 0x01, rekordboxId: 3311): DJPlayersTrackInfo(title: "Open Water", artist: "Low Sun"),
            DJPlayerTrackKey(sourcePlayer: 2, slot: .usb, trackType: 0x01, rekordboxId: 3312): DJPlayersTrackInfo(title: "After Hours", artist: "Glass District"),
        ]

        switch name {
        case "connected":
            controller.installFixture(state: .connected, interfaces: interfaces, players: nxs2Rig, ownNumber: 7, trackInfo: [:], recordingTitle: nil, recordedCount: 0)
        case "connected-3000":
            controller.installFixture(
                state: .connected, usesVirtualDeck: true, interfaces: interfaces, players: cdj3000Rig, ownNumber: 6, trackInfo: titles,
                recordingTitle: DJPlayersSetlistBuilder.title(for: Date(timeIntervalSince1970: 1_793_998_800)), recordedCount: 4
            )
        case "priming":
            controller.installFixture(state: .priming, interfaces: interfaces, players: [], ownNumber: nil, trackInfo: [:], recordingTitle: nil, recordedCount: 0)
        case "looking":
            controller.installFixture(state: .looking, interfaces: interfaces, players: [], ownNumber: nil, trackInfo: [:], recordingTitle: nil, recordedCount: 0)
        case "no-players":
            controller.installFixture(state: .noPlayers, interfaces: interfaces, players: [], ownNumber: 7, trackInfo: [:], recordingTitle: nil, recordedCount: 0)
        case "not-allowed":
            controller.installFixture(state: .notAllowed, interfaces: interfaces, players: [], ownNumber: nil, trackInfo: [:], recordingTitle: nil, recordedCount: 0)
        case "rekordbox":
            controller.installFixture(state: .rekordboxRunning, interfaces: interfaces, players: [], ownNumber: nil, trackInfo: [:], recordingTitle: nil, recordedCount: 0)
        case "ports":
            controller.installFixture(state: .portsInUse, interfaces: interfaces, players: [], ownNumber: nil, trackInfo: [:], recordingTitle: nil, recordedCount: 0)
        case "no-network":
            controller.installFixture(state: .noNetwork, interfaces: [], players: [], ownNumber: nil, trackInfo: [:], recordingTitle: nil, recordedCount: 0)
        case "number-taken":
            controller.installFixture(state: .numberTaken(3), interfaces: interfaces, players: [], ownNumber: nil, trackInfo: [:], recordingTitle: nil, recordedCount: 0)
        default:
            controller.installFixture(state: .disconnected, interfaces: interfaces, players: [], ownNumber: nil, trackInfo: [:], recordingTitle: nil, recordedCount: 0)
        }
    }
}

private final class DJPlayersSnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

@_cdecl("soundingtv_mac_dj_players_snapshot_bootstrap")
private func soundingtv_mac_dj_players_snapshot_bootstrap() {
    guard ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_DJ_PLAYERS_SNAPSHOT"] != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        Task { @MainActor in
            await DJPlayersSnapshotHarness.run()
        }
    }
}

@section("__DATA,__mod_init_func")
@used
private let soundingtv_mac_dj_players_snapshot_bootstrap_ptr: @convention(c) () -> Void = soundingtv_mac_dj_players_snapshot_bootstrap
#endif
