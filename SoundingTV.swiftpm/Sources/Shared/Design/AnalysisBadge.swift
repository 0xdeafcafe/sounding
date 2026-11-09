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
        HStack(spacing: 4) {
            Label(label, systemImage: kind.systemImage)
                .labelStyle(.titleAndIcon)
                .font(labelFont)
                .italic(provenance == .inferred)
                .lineLimit(1)

            if provenance == .stated {
                Image(systemName: "pencil")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(provenance == .measured || provenance == .stated ? Color.primary : Color.secondary)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(.fill.tertiary, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var labelFont: Font {
        #if os(tvOS)
        .caption2.weight(.semibold)
        #else
        .caption.weight(.semibold)
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        12
        #else
        8
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
        4
        #else
        3
        #endif
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
