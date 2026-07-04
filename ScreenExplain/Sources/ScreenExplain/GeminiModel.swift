import Foundation

/// Google's "-latest" aliases roll forward to whatever model they currently
/// point at, so these stay valid without needing updates as models change.
enum GeminiModel: String, CaseIterable {
    case flashLite = "gemini-flash-lite-latest"
    case flash = "gemini-flash-latest"
    case pro = "gemini-pro-latest"

    var displayName: String {
        switch self {
        case .flashLite: return "Flash Lite (fastest, cheapest)"
        case .flash: return "Flash (balanced, default)"
        case .pro: return "Pro (most capable, slower)"
        }
    }

    /// When this model is rate-limited, which model to retry with — cheaper,
    /// higher-quota models are tried after pricier ones, ending at Flash Lite.
    var rateLimitFallback: GeminiModel? {
        switch self {
        case .pro: return .flash
        case .flash: return .flashLite
        case .flashLite: return nil
        }
    }
}
