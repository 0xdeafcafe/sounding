import SwiftUI

enum SettingsIconFamily {
    case soundCloud, audio, devices, system
}

enum SettingsIcon: String, CaseIterable {
    case account, subscription, activity, scout, messages
    case playback, autoMix, alarms, analysis
    case devices, homeLighting, djPlayers
    case downloads, musicFolders, library, about

    var symbol: String {
        switch self {
        case .account: return "person.fill"
        case .subscription: return "star.fill"
        case .activity: return "bell.fill"
        case .scout: return "binoculars.fill"
        case .messages: return "message.fill"
        case .playback: return "play.fill"
        case .autoMix: return "slider.vertical.3"
        case .alarms: return "alarm.fill"
        case .analysis: return "waveform"
        case .devices: return "tv.and.mediabox.fill"
        case .homeLighting: return "lightbulb.fill"
        case .djPlayers: return "opticaldiscdrive.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .musicFolders: return "folder.fill"
        case .library: return "music.note.list"
        case .about: return "gearshape.fill"
        }
    }

    var family: SettingsIconFamily {
        switch self {
        case .account, .subscription, .activity, .scout, .messages: return .soundCloud
        case .playback, .autoMix, .alarms, .analysis: return .audio
        case .devices, .homeLighting, .djPlayers: return .devices
        case .downloads, .musicFolders, .library, .about: return .system
        }
    }

    var color: Color {
        switch self {
        case .account: return .blue
        case .subscription: return .indigo
        case .activity: return .red
        case .scout: return .teal
        case .messages: return .green
        case .playback: return .pink
        case .autoMix: return .purple
        case .alarms: return .indigo
        case .analysis: return .cyan
        case .devices: return .blue
        case .homeLighting: return .yellow
        case .djPlayers: return .indigo
        case .downloads: return .gray
        case .musicFolders: return .blue
        case .library: return .pink
        case .about: return .gray
        }
    }

    fileprivate var glyphScale: CGFloat {
        switch self {
        case .devices: return 0.84
        case .djPlayers, .scout, .messages: return 0.9
        default: return 1
        }
    }
}

struct SettingsIconTile: View {
    let icon: SettingsIcon

    #if os(macOS)
    private let baseSize: CGFloat = 20
    #else
    @ScaledMetric(relativeTo: .body) private var baseSize: CGFloat = 29
    #endif

    init(_ icon: SettingsIcon) {
        self.icon = icon
    }

    private var size: CGFloat { min(baseSize, 40) }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(icon.color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: icon.symbol)
                    .font(.system(size: size * 0.5 * icon.glyphScale, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

struct SettingsIconLabel: View {
    let title: String
    let icon: SettingsIcon

    init(_ title: String, icon: SettingsIcon) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsIconTile(icon)
        }
    }
}
