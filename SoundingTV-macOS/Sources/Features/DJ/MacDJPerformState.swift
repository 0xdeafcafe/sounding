import SwiftUI

enum MacDJMode: String, CaseIterable, Identifiable {
    case perform
    case prep
    case plan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .perform: return "Perform"
        case .prep: return "Prep"
        case .plan: return "Plan"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .perform: return "1"
        case .prep: return "2"
        case .plan: return "3"
        }
    }
}

enum MacDJPanelTab: Hashable {
    case autoMix
    case library
}

enum MacDJPadMode: String, CaseIterable, Hashable {
    case hotCue = "Hot Cue"
    case loop = "Loop"
    case beatJump = "Beat Jump"
    case roll = "Roll"
}

struct MacDJCue: Equatable, Identifiable {
    var index: Int
    var label: String
    var seconds: Double
    var color: Color

    var letter: String { String(UnicodeScalar(UInt8(65 + min(7, max(0, index))))) }
    var id: Int { index }
}

struct MacDJPhraseBar: Equatable, Identifiable {
    var start: Double
    var end: Double
    var color: Color

    var id: Double { start }
}

struct MacDJDeckSection: Equatable, Identifiable {
    var name: String
    var color: Color
    var firstBar: Int
    var lastBar: Int
    var hasVocals: Bool
    var isCurrent: Bool
    var isPast: Bool

    var id: Int { firstBar }
}

enum MacDJDeckRole: Equatable {
    case onAir
    case mixingIn
    case idle
}

enum MacDJDeckAnalysis: Equatable {
    case ready
    case analysing(progress: Double, fallbackTitle: String?)
    case noGrid(tempoRange: String)
}

enum MacDJDeckProblem: Equatable {
    case fileMissing(title: String, otherDeck: MixEngine.Deck)
    case failed(title: String, message: String)
}

struct MacDJDeckState: Equatable {
    var deck: MixEngine.Deck
    var trackId: String?
    var title: String
    var artist: String
    var source: String?
    var artworkURL: URL?
    var isSoundCloud = false
    var isViewOnly = false
    var bpm: Double?
    var pitchPercent: Double = 0
    var key: String?
    var keyColor: Color = Color(red: 0.49, green: 0.86, blue: 1.0)
    var position: Double = 0
    var duration: Double = 0
    var isPlaying = false
    var role: MacDJDeckRole = .idle
    var isSynced = false
    var isMaster = false
    var cues: [MacDJCue] = []
    var phrases: [MacDJPhraseBar] = []
    var barReadout: String = "1.1"
    var jogAngle: Double = 0
    var loopBars: Double = 4
    var isLooping = false
    var tempo: Double = 0
    var statusTitle: String?
    var statusDetail: String?
    var padNote: String?
    var analysis: MacDJDeckAnalysis = .ready
    var problem: MacDJDeckProblem?
    var sections: [MacDJDeckSection] = []
    var samples: [Float] = []
    var barSeconds: Double?
    var viewOnlyNote: String?

    var isEmpty: Bool { trackId == nil && problem == nil }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    var remainingText: String {
        guard duration > 0 else { return "" }
        let total = Int(max(0, duration - position).rounded())
        return "\u{2212}\(total / 60):" + String(format: "%02d", total % 60)
    }

    var bpmText: String {
        guard let bpm, bpm > 0 else { return "\u{2014} \u{2014}" }
        return String(format: "%.1f", bpm * (1 + pitchPercent / 100))
    }

    var pitchText: String {
        String(format: "%+.1f%%", pitchPercent)
    }
}

struct MacDJStep: Equatable, Identifiable {
    var label: String
    var fromBar: Double
    var toBar: Double

    var id: String { "\(label)@\(fromBar)" }
}

struct MacDJLaneLoop: Equatable, Identifiable {
    var fromBar: Double
    var toBar: Double
    var label: String

    var id: Double { fromBar }
}

struct MacDJPhase: Equatable {
    var text: String
    var isKnown: Bool
    var beat: Int
}

struct MacDJMixState: Equatable {
    var leaving: MixEngine.Deck = .a
    var steps: [MacDJStep]
    var nowBar: Double
    var totalBars: Double
    var loops: [MacDJLaneLoop] = []
    var leavingLabel: String?
    var leavingLabelBar: Double?
    var enteringLabel: String?
    var enteringLabelBar: Double?
    var enteringNote: String
    var mixOutCue: (label: String, bar: Double, color: Color)?
    var mixOutMarkerBar: Double?
    var fadeOutFromBar: Double?
    var phase: MacDJPhase?
    var countdown: String?

    static func == (lhs: MacDJMixState, rhs: MacDJMixState) -> Bool {
        lhs.leaving == rhs.leaving && lhs.steps == rhs.steps && lhs.nowBar == rhs.nowBar
            && lhs.totalBars == rhs.totalBars && lhs.loops == rhs.loops
            && lhs.leavingLabel == rhs.leavingLabel && lhs.enteringLabel == rhs.enteringLabel
            && lhs.enteringNote == rhs.enteringNote && lhs.mixOutCue?.label == rhs.mixOutCue?.label
            && lhs.mixOutCue?.bar == rhs.mixOutCue?.bar && lhs.phase == rhs.phase
            && lhs.fadeOutFromBar == rhs.fadeOutFromBar && lhs.countdown == rhs.countdown
    }

    func mode(of step: MacDJStep) -> StepMode {
        if nowBar >= step.toBar { return .done }
        if nowBar >= step.fromBar { return .now }
        return .next
    }

    enum StepMode {
        case done
        case now
        case next
    }

    var currentStep: MacDJStep? { steps.first { mode(of: $0) == .now } }
}

struct MacDJTarget: Equatable {
    var value: Double
    var label: String?
}

struct MacDJOwnership: Equatable, Identifiable {
    var control: MixControl
    var valueText: String

    var id: String { control.id }
    var title: String { "\(control.name) is yours" }
}

struct MacDJPlanRow: Equatable {
    var deck: MixEngine.Deck
    var title: String
    var section: String?
    var detail: String?
}

struct MacDJWhy: Equatable, Identifiable {
    var title: String
    var detail: String?

    var id: String { title }
}

struct MacDJNext: Equatable {
    var title: String
    var detail: String
    var artworkURL: URL?
    var identity: String
}

struct MacDJPanelState: Equatable {
    var isAutoMixOn: Bool
    var playsBothDecksNote: String?
    var stageChip: String?
    var timeLeft: String?
    var headline: String
    var subline: String?
    var from: MacDJPlanRow?
    var enter: MacDJPlanRow?
    var move: String?
    var why: [MacDJWhy] = []
    var next: MacDJNext?
    var footer: String
    var canExtend = false
}

struct MacDJPerformState: Equatable {
    var decks: [MacDJDeckState]
    var mix: MacDJMixState?
    var panel: MacDJPanelState?
    var values: [MixControl: Double] = [:]
    var targets: [MixControl: MacDJTarget] = [:]
    var owned: [MacDJOwnership] = []
    var mixerLabel: String?
    var isAutoMixDriving = false
    var levels: [MixEngine.Deck: Double] = [:]
    var masterLevel: Double = 0
    var zoomBars: Double = 22
    var banner: MacDJBanner?

    func deck(_ deck: MixEngine.Deck) -> MacDJDeckState {
        decks.first { $0.deck == deck } ?? MacDJDeckState(deck: deck, title: "", artist: "")
    }

    func value(_ control: MixControl) -> Double { values[control] ?? MacDJPerformState.defaultValue(control) }

    func ownership(_ control: MixControl) -> MacDJOwnership? { owned.first { $0.control == control } }

    static func defaultValue(_ control: MixControl) -> Double {
        switch control.kind {
        case .volume: return 1
        case .crossfader: return 0.5
        case .echo: return 0
        default: return 0.5
        }
    }
}

struct MacDJPerformLayout: Equatable {
    var showsMixer = true
    var showsJog = true
    var showsLoopControls = true
    var showsTempoFader = true
    var showsPads = true
    var showsEffects = true
    var showsOverview = true
    var showsStepTracker = true
    var showsPhaseMeter = true
    var showsControlTargets = true

    static let full = MacDJPerformLayout()

    static let calm = MacDJPerformLayout(
        showsMixer: true,
        showsJog: false,
        showsLoopControls: false,
        showsTempoFader: false,
        showsPads: false,
        showsEffects: false,
        showsOverview: true,
        showsStepTracker: true,
        showsPhaseMeter: false,
        showsControlTargets: true
    )
}

struct MacDJBanner: Equatable {
    var title: String
    var detail: String
    var action: String
}
