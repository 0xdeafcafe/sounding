import SwiftUI

enum SCAnalysisProvenance: Sendable, Equatable {
    case measured
    case stated
    case inferred
    case unavailable
}

enum SCAnalysisKind: Sendable {
    case bpm
    case key
    case genre

    fileprivate var systemImage: String {
        switch self {
        case .bpm:   return "metronome"
        case .key:   return "pianokeys"
        case .genre: return "tag"
        }
    }

    fileprivate var unavailableLabel: String {
        switch self {
        case .bpm:   return "Tempo not analysed"
        case .key:   return "Key not analysed"
        case .genre: return "Genre not analysed"
        }
    }
}

struct SCAnalysisBadge: View {
    let kind: SCAnalysisKind
    let value: String?
    let provenance: SCAnalysisProvenance
    var style: SCContentStyle = .tv

    var body: some View {
        HStack(spacing: style.spaceHair) {
            Image(systemName: kind.systemImage)
                .font(.system(size: iconPointSize, weight: .semibold))
                .symbolRenderingMode(.monochrome)

            Text(label)
                .font(style.fontCaptionEmphasis)
                .lineLimit(1)

            if provenance == .stated {
                Image(systemName: "pencil")
                    .font(.system(size: iconPointSize * 0.85, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, style.spaceSnug)
        .padding(.vertical, style.spaceHair * 1.5)
        .background {
            Capsule(style: .continuous)
                .fill(fill)
        }
        .overlay {
            if provenance == .inferred {
                Capsule(style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: style.iconStrokeWidth * 0.5, dash: [3, 3]))
                    .foregroundStyle(style.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var label: String {
        switch provenance {
        case .measured, .stated, .inferred:
            return presentedValue
        case .unavailable:
            return "—"
        }
    }

    private var accessibilityLabel: String {
        switch provenance {
        case .unavailable:
            return kind.unavailableLabel
        case .measured:
            return "\(kindName): \(presentedValue), measured"
        case .stated:
            return "\(kindName): \(presentedValue), entered by you"
        case .inferred:
            return "\(kindName): \(presentedValue), estimated"
        }
    }

    private var presentedValue: String {
        guard let value else { return "—" }
        return kind == .genre ? GenrePresentation.displayName(for: value) : value
    }

    private var kindName: String {
        switch kind {
        case .bpm: return "Tempo"
        case .key: return "Key"
        case .genre: return "Genre"
        }
    }

    private var iconPointSize: CGFloat {
        max(10, style.iconStrokeWidth * 4)
    }

    private var fill: Color {
        switch provenance {
        case .measured, .stated: return style.accent.opacity(0.22)
        case .inferred:          return style.bgOverlay
        case .unavailable:       return style.bgRaised
        }
    }

    private var foreground: Color {
        switch provenance {
        case .measured, .stated: return style.accent
        case .inferred:          return style.textSecondary
        case .unavailable:       return style.textTertiary
        }
    }
}

struct SCAnalysisText: View {
    let kind: SCAnalysisKind
    let value: String?
    let provenance: SCAnalysisProvenance

    var body: some View {
        Text(displayValue)
            .foregroundStyle(foreground)
            .accessibilityLabel(accessibilityLabel)
    }

    private var isEmpty: Bool {
        provenance == .unavailable || (value?.isEmpty ?? true)
    }

    private var displayValue: String {
        guard !isEmpty, let value else { return "—" }
        return kind == .genre ? GenrePresentation.displayName(for: value) : value
    }

    private static let tertiary = Color.primary.opacity(0.38)

    private var foreground: Color {
        if isEmpty { return Self.tertiary }
        switch provenance {
        case .measured, .stated: return .primary
        case .inferred: return .secondary
        case .unavailable: return Self.tertiary
        }
    }

    private var accessibilityLabel: String {
        switch provenance {
        case .unavailable:
            return kind.unavailableLabel
        case .measured:
            return "\(kindName): \(displayValue), measured"
        case .stated:
            return "\(kindName): \(displayValue), entered by you"
        case .inferred:
            return "\(kindName): \(displayValue), estimated"
        }
    }

    private var kindName: String {
        switch kind {
        case .bpm: return "Tempo"
        case .key: return "Key"
        case .genre: return "Genre"
        }
    }
}

struct SCAnalysisBadgeRow: View {
    var bpm: (value: String, provenance: SCAnalysisProvenance)?
    var key: (value: String, provenance: SCAnalysisProvenance)?
    var genre: (value: String, provenance: SCAnalysisProvenance)?
    var style: SCContentStyle = .tv

    var body: some View {
        HStack(spacing: style.spaceTight) {
            if let bpm {
                SCAnalysisBadge(kind: .bpm, value: bpm.value, provenance: bpm.provenance, style: style)
            }
            if let key {
                SCAnalysisBadge(kind: .key, value: key.value, provenance: key.provenance, style: style)
            }
            if let genre {
                SCAnalysisBadge(kind: .genre, value: genre.value, provenance: genre.provenance, style: style)
            }
        }
    }
}
