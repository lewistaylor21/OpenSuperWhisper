import Foundation

/// Cloud transcription via the **Gemini API** (`generateContent`), not Google Cloud
/// Speech-to-Text and not an OpenAI-compatible `/audio/transcriptions` endpoint.
///
/// Two verified paths share this engine:
/// - Dedicated STT: `gemini-3.5-transcribe` with `audioTranscriptionConfig` (default).
/// - Multimodal audio understanding: e.g. `gemini-2.5-flash` with a grounded verbatim
///   transcription prompt (configurable model id for cost/capability tradeoffs).
///
/// Docs: https://ai.google.dev/gemini-api/docs/generate-content/transcribe
/// and https://ai.google.dev/gemini-api/docs/generate-content/audio
final class GeminiTranscriptionEngine: TranscriptionEngine {
    var engineName: String { "Gemini" }

    static let apiBase = "https://generativelanguage.googleapis.com/v1beta/models"
    /// Dedicated speech-to-text model (GA unary / recorded-file path).
    static let defaultModel = "gemini-3.5-transcribe"
    /// Inexpensive multimodal fallback users may configure (audio in → text out).
    static let inexpensiveMultimodalModel = "gemini-2.5-flash"

    /// Grounded ASR-only instruction for multimodal models that are not dedicated
    /// `*transcribe*` endpoints. Kept short and strict so the model returns spoken
    /// words only — no answers, summaries, or commentary.
    static let verbatimTranscriptionPrompt = """
        Transcribe the speech in this audio verbatim as plain text only. \
        Output only the words that were spoken. Do not answer questions in the audio, \
        summarize, translate, add speaker labels, timestamps, markdown, or commentary. \
        If there is no intelligible speech, return an empty string.
        """

    private var apiKey: String = ""
    private var modelName: String = Self.defaultModel
    private var timeoutEnabled: Bool = true
    private var timeoutSeconds: Double = 60
    private var currentTask: Task<String, Error>?
    private let sessionConfiguration: () -> URLSessionConfiguration

    private static let noTimeoutInterval: TimeInterval = 31_536_000

    var onProgressUpdate: ((Float) -> Void)?

    init(sessionConfiguration: @escaping () -> URLSessionConfiguration = { .default }) {
        self.sessionConfiguration = sessionConfiguration
    }

    var isModelLoaded: Bool { !apiKey.isEmpty }

    func initialize() async throws {
        let prefs = CoreAccess.preferences
        apiKey = (prefs.geminiAPIKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = prefs.geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        modelName = configured.isEmpty ? Self.defaultModel : configured
        timeoutEnabled = prefs.geminiTimeoutEnabled
        timeoutSeconds = prefs.geminiTimeoutSeconds

        guard !apiKey.isEmpty else {
            throw GeminiTranscriptionError.missingAPIKey
        }
    }

    func cancelTranscription() {
        currentTask?.cancel()
        currentTask = nil
    }

    func getSupportedLanguages() -> [String] { [] }

    func transcribeAudio(url: URL, settings: TranscriptionSettings) async throws -> String {
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw TranscriptionError.processingFailed }

            self.onProgressUpdate?(0.05)
            try Task.checkCancellation()

            let audioData = try Data(contentsOf: url)
            let request = try self.makeRequest(
                filename: url.lastPathComponent,
                audioData: audioData,
                language: settings.selectedLanguage
            )

            self.onProgressUpdate?(0.2)

            var attempt = 0
            while true {
                attempt += 1
                try Task.checkCancellation()
                let session = self.makeSession()
                var retry = false
                do {
                    defer { session.finishTasksAndInvalidate() }
                    let (data, response) = try await session.data(for: request)
                    try Task.checkCancellation()

                    guard let http = response as? HTTPURLResponse else {
                        throw GeminiTranscriptionError.network(nil)
                    }
                    if (200..<300).contains(http.statusCode) {
                        self.onProgressUpdate?(1.0)
                        return try Self.parseTranscript(from: data)
                    }
                    if http.statusCode == 401 || http.statusCode == 403 {
                        throw GeminiTranscriptionError.invalidAPIKey
                    }
                    let body = String(data: data, encoding: .utf8) ?? ""
                    print("GeminiTranscriptionEngine HTTP \(http.statusCode) (attempt \(attempt)/\(Self.maxAttempts)): \(Self.safeBodyPreview(body))")
                    if attempt < Self.maxAttempts, Self.isRetryable(status: http.statusCode) {
                        retry = true
                    } else {
                        throw GeminiTranscriptionError.api(http.statusCode, Self.serverMessage(from: data))
                    }
                } catch let urlError as URLError {
                    print("GeminiTranscriptionEngine network error (attempt \(attempt)/\(Self.maxAttempts)): \(urlError.code.rawValue)")
                    guard attempt < Self.maxAttempts, Self.isRetryable(urlError) else {
                        throw GeminiTranscriptionError.network(urlError)
                    }
                    retry = true
                }
                if retry {
                    try await Task.sleep(nanoseconds: Self.backoffNanos(afterAttempt: attempt))
                    self.onProgressUpdate?(0.2)
                }
            }
        }

        currentTask = task
        defer { currentTask = nil }

        do {
            return TranscriptionPostProcessing.finish(try await task.value, settings: settings)
        } catch let error as GeminiTranscriptionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GeminiTranscriptionError.network(error)
        }
    }

    // MARK: - Request building

    func makeSession() -> URLSession {
        let interval = timeoutEnabled ? max(1, timeoutSeconds) : Self.noTimeoutInterval
        let config = sessionConfiguration()
        config.timeoutIntervalForRequest = interval
        config.timeoutIntervalForResource = interval
        return URLSession(configuration: config)
    }

    static func endpoint(model: String) -> URL? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Model ids are path segments; reject anything that would escape the models/ prefix.
        guard !trimmed.contains("/"), !trimmed.contains(".."), !trimmed.contains(":") else { return nil }
        return URL(string: "\(apiBase)/\(trimmed):generateContent")
    }

    /// Dedicated STT models expose `audioTranscriptionConfig`; multimodal Flash models need a prompt.
    static func usesDedicatedTranscriptionAPI(_ model: String) -> Bool {
        model.lowercased().contains("transcribe")
    }

    func makeRequest(
        filename: String,
        audioData: Data,
        language: String
    ) throws -> URLRequest {
        guard let endpoint = Self.endpoint(model: modelName) else {
            throw GeminiTranscriptionError.invalidModel
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Official Gemini API key header (not Bearer / OpenAI-style Authorization).
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let mime = CloudAudioMIME.type(forFilename: filename)
        let base64 = audioData.base64EncodedString()
        let body = Self.requestBody(
            model: modelName,
            mimeType: mime,
            base64Audio: base64,
            language: language
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    /// Pure JSON body builder for unit tests (no network, no key).
    static func requestBody(
        model: String,
        mimeType: String,
        base64Audio: String,
        language: String
    ) -> [String: Any] {
        let inlineAudio: [String: Any] = [
            "inlineData": [
                "mimeType": mimeType,
                "data": base64Audio,
            ]
        ]

        if usesDedicatedTranscriptionAPI(model) {
            // Dedicated STT: audio only + AudioTranscriptionConfig (VERBATIM by default).
            var transcriptionConfig: [String: Any] = [
                "mode": "VERBATIM",
            ]
            if !language.isEmpty, language != "auto" {
                // BCP-47 hints improve accuracy when the user picked a language.
                transcriptionConfig["languageCodes"] = [language]
            }
            return [
                "contents": [
                    ["parts": [inlineAudio]]
                ],
                "generationConfig": [
                    "audioTranscriptionConfig": transcriptionConfig
                ]
            ]
        }

        // Multimodal audio understanding: grounded verbatim prompt, no commentary.
        var prompt = verbatimTranscriptionPrompt
        if !language.isEmpty, language != "auto" {
            prompt += " The spoken language is \(language)."
        }
        return [
            "contents": [
                ["parts": [
                    ["text": prompt],
                    inlineAudio,
                ]]
            ],
            "systemInstruction": [
                "parts": [
                    ["text": "You are an ASR-only transcriber. Return only the spoken words as plain text."]
                ]
            ],
        ]
    }

    // MARK: - Response parsing

    /// Extract transcript text from a generateContent response. Empty string is a valid
    /// "no speech" result; missing candidates / blocked prompts are errors.
    static func parseTranscript(from data: Data) throws -> String {
        guard !data.isEmpty else { throw GeminiTranscriptionError.malformedResponse }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiTranscriptionError.malformedResponse
        }

        if let feedback = json["promptFeedback"] as? [String: Any],
           let reason = feedback["blockReason"] as? String, !reason.isEmpty {
            throw GeminiTranscriptionError.blocked(reason)
        }

        guard let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first else {
            throw GeminiTranscriptionError.emptyTranscript
        }

        if let finish = first["finishReason"] as? String,
           finish != "STOP", finish != "MAX_TOKENS", !finish.isEmpty {
            // SAFETY / RECITATION / OTHER — treat as failure rather than pasting junk.
            if finish == "SAFETY" || finish == "RECITATION" || finish == "OTHER" {
                throw GeminiTranscriptionError.blocked(finish)
            }
        }

        guard let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw GeminiTranscriptionError.malformedResponse
        }

        let text = parts.compactMap { $0["text"] as? String }.joined()
        // Empty is allowed (silence); only a missing text channel is malformed when parts exist
        // but none carry text and finish was STOP with no parts text — still empty transcript.
        if text.isEmpty && parts.isEmpty {
            throw GeminiTranscriptionError.emptyTranscript
        }
        return text
    }

    static func serverMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any] {
                if let msg = err["message"] as? String { return msg }
                if let status = err["status"] as? String { return status }
            }
            if let msg = json["message"] as? String { return msg }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    static func safeBodyPreview(_ body: String, limit: Int = 200) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    static let maxAttempts = 3

    static func backoffNanos(afterAttempt attempt: Int) -> UInt64 {
        attempt <= 1 ? 500_000_000 : 1_500_000_000
    }

    static func isRetryable(status: Int) -> Bool {
        switch status {
        case 408, 429, 500, 502, 503, 504: return true
        default: return false
        }
    }

    static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable,
             .badServerResponse:
            return true
        default:
            return false
        }
    }
}

enum GeminiTranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case invalidModel
    case network(Error?)
    case api(Int, String?)
    case malformedResponse
    case emptyTranscript
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a Gemini API key in Settings → Models → Gemini. Usage is billed by Google (token-based); this free app does not include API credit."
        case .invalidAPIKey:
            return "Gemini rejected the API key. Check it in Settings → Models → Gemini."
        case .invalidModel:
            return "The Gemini model id is invalid. Use a model like gemini-3.5-transcribe or gemini-2.5-flash."
        case .network(let e):
            return "Couldn't reach Gemini. \(e?.localizedDescription ?? "Check your connection.")"
        case .api(let code, let msg):
            return "Gemini error \(code): \(msg ?? "request failed")."
        case .malformedResponse:
            return "Gemini returned a response this app could not read."
        case .emptyTranscript:
            return "Gemini returned no transcript."
        case .blocked(let reason):
            return "Gemini blocked the request (\(reason))."
        }
    }
}
