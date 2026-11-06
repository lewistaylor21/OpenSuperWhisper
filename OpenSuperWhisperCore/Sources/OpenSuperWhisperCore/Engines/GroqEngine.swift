import Foundation

/// First-party **Groq** cloud STT (groq.com) — OpenAI-compatible
/// `POST https://api.groq.com/openai/v1/audio/transcriptions` with
/// `whisper-large-v3-turbo` by default.
///
/// Distinct from:
/// - xAI Grok (`/v1/stt`, `grok-voice-transcribe-2.0`)
/// - Gemini (`generateContent` / `gemini-3.5-transcribe`)
/// - the generic Remote engine (any user-typed OpenAI-compatible server)
///
/// Docs verified: https://console.groq.com/docs/speech-to-text
/// Model: https://console.groq.com/docs/model/whisper-large-v3-turbo
/// Published rate: $0.04/audio-hour; minimum billable length 10 seconds per request.
final class GroqEngine: TranscriptionEngine {
    var engineName: String { "Groq" }

    static let apiBase = "https://api.groq.com/openai/v1"
    static let defaultModel = "whisper-large-v3-turbo"
    /// Official transcriptions URL (not translations — turbo does not support translation).
    static let transcriptionsURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

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
        apiKey = (prefs.cloudGroqAPIKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = prefs.cloudGroqModel.trimmingCharacters(in: .whitespacesAndNewlines)
        modelName = configured.isEmpty ? Self.defaultModel : configured
        timeoutEnabled = prefs.cloudGroqTimeoutEnabled
        timeoutSeconds = prefs.cloudGroqTimeoutSeconds

        guard !apiKey.isEmpty else {
            throw GroqError.missingAPIKey
        }
    }

    func cancelTranscription() {
        currentTask?.cancel()
        currentTask = nil
    }

    func getSupportedLanguages() -> [String] { [] }

    func transcribeAudio(url: URL, settings: TranscriptionSettings) async throws -> String {
        // whisper-large-v3-turbo: transcription only (no /translations). Ignore translateToEnglish.
        let language = settings.translateToEnglish ? "" : settings.selectedLanguage

        let task = Task<String, Error> { [weak self] in
            guard let self else { throw TranscriptionError.processingFailed }

            self.onProgressUpdate?(0.05)
            try Task.checkCancellation()

            let audioData = try Data(contentsOf: url)
            let boundary = "Boundary-\(UUID().uuidString)"
            let request = self.makeRequest(
                boundary: boundary,
                filename: url.lastPathComponent,
                audioData: audioData,
                language: language
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
                        throw GroqError.network(nil)
                    }
                    if (200..<300).contains(http.statusCode) {
                        self.onProgressUpdate?(1.0)
                        return Self.extractText(from: data)
                    }
                    if http.statusCode == 401 || http.statusCode == 403 {
                        throw GroqError.invalidAPIKey
                    }
                    let body = String(data: data, encoding: .utf8) ?? ""
                    print("GroqEngine HTTP \(http.statusCode) (attempt \(attempt)/\(Self.maxAttempts)): \(Self.safeBodyPreview(body))")
                    if attempt < Self.maxAttempts, Self.isRetryable(status: http.statusCode) {
                        retry = true
                    } else {
                        throw GroqError.api(http.statusCode, Self.serverMessage(from: data))
                    }
                } catch let urlError as URLError {
                    print("GroqEngine network error (attempt \(attempt)/\(Self.maxAttempts)): \(urlError.code.rawValue)")
                    guard attempt < Self.maxAttempts, Self.isRetryable(urlError) else {
                        throw GroqError.network(urlError)
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
        } catch let error as GroqError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GroqError.network(error)
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

    /// OpenAI-compatible multipart to Groq's fixed transcriptions URL.
    /// Not xAI `/v1/stt` and not Gemini `generateContent`.
    func makeRequest(
        boundary: String,
        filename: String,
        audioData: Data,
        language: String
    ) -> URLRequest {
        var request = URLRequest(url: Self.transcriptionsURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var fields: [(String, String)] = [
            ("model", modelName),
            ("response_format", "json"),
        ]
        if !language.isEmpty, language != "auto" {
            fields.append(("language", language))
        }

        var body = Data()
        for (name, value) in fields {
            body.appendMultipartField(name, value, boundary: boundary)
        }
        body.appendMultipartFile("file", filename: filename, data: audioData,
                                 mimeType: CloudAudioMIME.type(forFilename: filename),
                                 boundary: boundary)
        body.appendMultipart("--\(boundary)--\r\n")

        request.httpBody = body
        return request
    }

    // MARK: - Parsing / retry

    static func extractText(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = json["text"] as? String { return text }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func serverMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
            if let err = json["error"] as? String { return err }
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

enum GroqError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case network(Error?)
    case api(Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a Groq API key in Settings → Models → Groq. Usage is billed by Groq ($0.04/audio-hour for whisper-large-v3-turbo; requests under 10 seconds are billed as 10 seconds)."
        case .invalidAPIKey:
            return "Groq rejected the API key. Check it in Settings → Models → Groq."
        case .network(let e):
            return "Couldn't reach Groq. \(e?.localizedDescription ?? "Check your connection.")"
        case .api(let code, let msg):
            return "Groq error \(code): \(msg ?? "request failed")."
        }
    }
}
