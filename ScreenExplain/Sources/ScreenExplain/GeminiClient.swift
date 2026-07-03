import Foundation

enum GeminiClientError: LocalizedError {
    case badResponse(status: Int, body: String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .badResponse(let status, let body):
            return "Gemini API error (\(status)): \(body)"
        case .missingAPIKey:
            return "No Gemini API key configured."
        }
    }
}

enum GeminiClient {
    private static let model = "gemini-flash-latest"

    private static let explainSystemPrompt = """
    You are helping someone understand a textbook page, diagram, or screen \
    they just captured while reading. Explain clearly and concisely what is \
    shown: the core concept, any formulas or terms, and how the pieces relate. \
    Assume an intelligent reader who wants the explanation, not a restatement \
    of what's visible. Write in plain prose paragraphs only — no markdown \
    syntax (no #, *, -, backticks). Keep it focused; a few short paragraphs \
    is usually enough.
    """

    private static let translateImageSystemPrompt = """
    You translate text captured from a screen. Read every piece of text \
    visible in the image and translate it, preserving reading order. Output \
    only the translated text — no commentary, no markdown, no restating the \
    original.
    """

    private static let translateAudioSystemPrompt = """
    You translate spoken audio captured live from a screen or call. \
    Transcribe the speech and translate it. This audio is one short segment \
    of an ongoing recording, so multiple speakers may appear across segments. \
    Distinguish speakers by voice and label every line with a tag like \
    "Speaker 1:", "Speaker 2:", etc. You'll be given the tail of the previous \
    segment's transcript so you can reuse the same speaker numbers for voices \
    you recognize — only introduce a new speaker number for a voice that \
    genuinely hasn't appeared before. Output only the translated, \
    speaker-labeled lines with no other commentary, timestamps, or markdown. \
    If the audio is silent or has no discernible speech, output nothing.
    """

    static func explainImage(pngData: Data, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        try await stream(
            parts: [
                ["inline_data": ["mime_type": "image/png", "data": pngData.base64EncodedString()]],
                ["text": "Explain what's shown in this image."]
            ],
            systemPrompt: explainSystemPrompt,
            apiKey: apiKey,
            onDelta: onDelta
        )
    }

    static func translateImage(pngData: Data, targetLanguage: String, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        try await stream(
            parts: [
                ["inline_data": ["mime_type": "image/png", "data": pngData.base64EncodedString()]],
                ["text": "Translate all text visible in this image into \(targetLanguage)."]
            ],
            systemPrompt: translateImageSystemPrompt,
            apiKey: apiKey,
            onDelta: onDelta
        )
    }

    static func translateAudio(wavData: Data, targetLanguage: String, previousContext: String?, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        var promptText = "Translate the speech in this audio into \(targetLanguage)."
        if let previousContext, !previousContext.isEmpty {
            promptText = """
            Tail of the previous segment's transcript, for speaker-numbering \
            continuity only — do not repeat it in your output:
            \"\"\"
            \(previousContext)
            \"\"\"

            \(promptText)
            """
        }

        try await stream(
            parts: [
                ["inline_data": ["mime_type": "audio/wav", "data": wavData.base64EncodedString()]],
                ["text": promptText]
            ],
            systemPrompt: translateAudioSystemPrompt,
            apiKey: apiKey,
            onDelta: onDelta
        )
    }

    private static func stream(parts: [[String: Any]], systemPrompt: String, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "systemInstruction": ["parts": [["text": systemPrompt]]]
        ]

        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent")!
        components.queryItems = [
            URLQueryItem(name: "alt", value: "sse"),
            URLQueryItem(name: "key", value: apiKey)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GeminiClientError.badResponse(status: -1, body: "no response")
        }

        guard http.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw GeminiClientError.badResponse(status: http.statusCode, body: errorBody)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard let data = jsonString.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = obj["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let contentParts = content["parts"] as? [[String: Any]] else { continue }

            for part in contentParts {
                if let text = part["text"] as? String {
                    onDelta(text)
                }
            }
        }
    }
}
