import Foundation

enum AIProvider: String, CaseIterable {
    case claude
    case gemini

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }

    /// Keychain account name. The claude value matches the account used
    /// before multi-provider support existed, so existing saved keys keep working.
    var keychainAccount: String {
        switch self {
        case .claude: return "anthropic_api_key"
        case .gemini: return "gemini_api_key"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .claude: return "sk-ant-..."
        case .gemini: return "AIza..."
        }
    }
}

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
