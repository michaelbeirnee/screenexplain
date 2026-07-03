import Foundation

enum ClaudeClientError: LocalizedError {
    case badResponse(status: Int, body: String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .badResponse(let status, let body):
            return "Claude API error (\(status)): \(body)"
        case .missingAPIKey:
            return "No Anthropic API key configured."
        }
    }
}

enum ClaudeClient {
    private static let explainSystemPrompt = """
    You are helping someone understand a textbook page, diagram, or screen \
    they just captured while reading. Explain clearly and concisely what is \
    shown: the core concept, any formulas or terms, and how the pieces relate. \
    Assume an intelligent reader who wants the explanation, not a restatement \
    of what's visible. Write in plain prose paragraphs only — no markdown \
    syntax (no #, *, -, backticks). Keep it focused; a few short paragraphs \
    is usually enough.
    """

    private static let translateSystemPrompt = """
    You translate text captured from a screen. Read every piece of text \
    visible in the image and translate it, preserving reading order. Output \
    only the translated text — no commentary, no markdown, no restating the \
    original.
    """

    /// Streams an explanation of the given image, invoking onDelta with each
    /// text chunk as it arrives. Throws on network/API error.
    static func explainImage(pngData: Data, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        try await stream(
            pngData: pngData,
            userText: "Explain what's shown in this image.",
            systemPrompt: explainSystemPrompt,
            apiKey: apiKey,
            onDelta: onDelta
        )
    }

    /// Streams a translation of all text visible in the given image.
    static func translateImage(pngData: Data, targetLanguage: String, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        try await stream(
            pngData: pngData,
            userText: "Translate all text visible in this image into \(targetLanguage).",
            systemPrompt: translateSystemPrompt,
            apiKey: apiKey,
            onDelta: onDelta
        )
    }

    private static func stream(pngData: Data, userText: String, systemPrompt: String, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        let base64 = pngData.base64EncodedString()

        let body: [String: Any] = [
            "model": "claude-opus-4-8",
            "max_tokens": 1500,
            "stream": true,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/png",
                                "data": base64
                            ]
                        ],
                        [
                            "type": "text",
                            "text": userText
                        ]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeClientError.badResponse(status: -1, body: "no response")
        }

        guard http.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw ClaudeClientError.badResponse(status: http.statusCode, body: errorBody)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard let data = jsonString.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            if type == "content_block_delta",
               let delta = obj["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let text = delta["text"] as? String {
                onDelta(text)
            }
        }
    }
}
