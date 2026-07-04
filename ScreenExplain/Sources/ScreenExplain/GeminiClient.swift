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
    You may be given one or two separate audio tracks, each preceded by a \
    text label identifying its source. If a track is labeled as the user's \
    microphone, label every line transcribed from it "You:" — never number \
    it as a speaker. If a track is labeled as system/call audio, distinguish \
    voices within it by ear and label them "Speaker 1:", "Speaker 2:", etc. \
    You'll be given the tail of the previous segment's transcript so you can \
    reuse the same speaker numbers for voices you recognize — only introduce \
    a new speaker number for a voice that genuinely hasn't appeared before. \
    If both tracks are present, interleave the lines into one chronological \
    transcript as best you can judge from context; if you can't tell the \
    order, list the microphone track's lines first. Output only the \
    translated, labeled lines with no other commentary, timestamps, or \
    markdown. If a track is silent or has no discernible speech, say nothing \
    about it.
    """

    static func explainImage(pngData: Data, model: GeminiModel, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        try await stream(
            parts: [
                ["inline_data": ["mime_type": "image/png", "data": pngData.base64EncodedString()]],
                ["text": "Explain what's shown in this image."]
            ],
            systemPrompt: explainSystemPrompt,
            model: model,
            apiKey: apiKey,
            onDelta: onDelta
        )
    }

    static func translateImage(pngData: Data, targetLanguage: String, model: GeminiModel, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        try await stream(
            parts: [
                ["inline_data": ["mime_type": "image/png", "data": pngData.base64EncodedString()]],
                ["text": "Translate all text visible in this image into \(targetLanguage)."]
            ],
            systemPrompt: translateImageSystemPrompt,
            model: model,
            apiKey: apiKey,
            onDelta: onDelta
        )
    }

    /// Either audio track may be omitted, but at least one must be present.
    /// Passing both lets the model tell "you talking" apart from "audio
    /// playing from the call" by source rather than guessing from voice alone.
    static func translateAudio(micAudio: Data?, systemAudio: Data?, targetLanguage: String, previousContext: String?, model: GeminiModel, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        var parts: [[String: Any]] = []

        if let micAudio {
            parts.append(["inline_data": ["mime_type": "audio/wav", "data": micAudio.base64EncodedString()]])
            parts.append(["text": "The audio track above is from the user's own microphone."])
        }
        if let systemAudio {
            parts.append(["inline_data": ["mime_type": "audio/wav", "data": systemAudio.base64EncodedString()]])
            parts.append(["text": "The audio track above is system/call audio (e.g. other participants on a Zoom call)."])
        }

        var promptText = "Translate the speech in the audio above into \(targetLanguage)."
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
        parts.append(["text": promptText])

        try await stream(
            parts: parts,
            systemPrompt: translateAudioSystemPrompt,
            model: model,
            apiKey: apiKey,
            onDelta: onDelta
        )
    }

    /// On a 429 (rate limit), automatically retries once with the model's
    /// fallback (a cheaper, higher-quota model) before giving up — the
    /// request hasn't streamed any partial output yet at that point, since
    /// the status code is checked before reading any response lines.
    private static func stream(parts: [[String: Any]], systemPrompt: String, model: GeminiModel, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        do {
            try await performRequest(parts: parts, systemPrompt: systemPrompt, model: model, apiKey: apiKey, onDelta: onDelta)
        } catch let error as GeminiClientError {
            if case .badResponse(let status, _) = error, status == 429, let fallback = model.rateLimitFallback {
                try await stream(parts: parts, systemPrompt: systemPrompt, model: fallback, apiKey: apiKey, onDelta: onDelta)
            } else {
                throw error
            }
        }
    }

    private static func performRequest(parts: [[String: Any]], systemPrompt: String, model: GeminiModel, apiKey: String, onDelta: @escaping (String) -> Void) async throws {
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "systemInstruction": ["parts": [["text": systemPrompt]]]
        ]

        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):streamGenerateContent")!
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
