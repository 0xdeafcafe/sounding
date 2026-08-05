import Foundation

enum MixEngineState: Equatable {
    case off
    case preparing(Double)
    case live
    case unavailable(String)
}
