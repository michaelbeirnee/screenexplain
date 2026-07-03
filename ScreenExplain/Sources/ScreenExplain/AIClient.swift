import Foundation

enum AIClientError: LocalizedError {
    case audioNotSupported(provider: AIProvider)

    var errorDescription: String? {
        switch self {
        case .audioNotSupported(let provider):
            return "\(provider.displayName) doesn't support live audio translation. Switch the provider to Gemini in the menu."
        }
    }
}

/// Dispatches to the selected provider's client so callers don't need to
/// branch on AIProvider themselves.
enum AIClient {
    static func explainImage(pngData: Data, provider: AIProvider, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        switch provider {
        case .claude:
            try await ClaudeClient.explainImage(pngData: pngData, apiKey: apiKey, onDelta: onDelta)
        case .gemini:
            try await GeminiClient.explainImage(pngData: pngData, apiKey: apiKey, onDelta: onDelta)
        }
    }

    static func translateImage(pngData: Data, provider: AIProvider, targetLanguage: String, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        switch provider {
        case .claude:
            try await ClaudeClient.translateImage(pngData: pngData, targetLanguage: targetLanguage, apiKey: apiKey, onDelta: onDelta)
        case .gemini:
            try await GeminiClient.translateImage(pngData: pngData, targetLanguage: targetLanguage, apiKey: apiKey, onDelta: onDelta)
        }
    }

    static func translateAudio(wavData: Data, provider: AIProvider, targetLanguage: String, previousContext: String?, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        switch provider {
        case .claude:
            throw AIClientError.audioNotSupported(provider: .claude)
        case .gemini:
            try await GeminiClient.translateAudio(wavData: wavData, targetLanguage: targetLanguage, previousContext: previousContext, apiKey: apiKey, onDelta: onDelta)
        }
    }
}
