import Foundation

enum AppMode: String, CaseIterable {
    case explain
    case translateScreen
    case translateAudio

    var displayName: String {
        switch self {
        case .explain: return "Explain"
        case .translateScreen: return "Translate Screen Text"
        case .translateAudio: return "Translate Audio (Live)"
        }
    }
}
