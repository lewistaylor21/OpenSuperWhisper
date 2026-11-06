import Foundation

/// Cloud transcription via xAI's official speech-to-text REST API
/// (`POST https://api.x.ai/v1/stt`, model `grok-voice-transcribe-2.0`).
///
/// This is intentionally **not** the OpenAI-compatible Remote engine: xAI's STT
/// schema is multipart to `/v1/stt` (option fields, then `file` last), not
/// `/v1/audio/transcriptions`. Streaming WebSocket (`wss://api.x.ai/v1/stt`) is
/// out of scope for the first push-to-talk recorded-file path.
final class XAIEngine: TranscriptionEngine {
    var engineName: String { "Grok (xAI)" }

    static let endpointURL = URL(string: "https://api.x.ai/v1/stt")!
    static let defaultModel = "grok-voice-transcribe-2.0"

    private var apiKey: String = ""
    private var modelName: String = Self.defaultModel
    private var formatEnabled: Bool = true
    private var timeoutEnabled: Bool = true
    private var timeoutSeconds: Double = 60
    private var currentTask: Task<String, Error>?
    private let sessionConfiguration: () -> URLSessionConfiguration

    private static let noTimeoutInterval: TimeInterval = 31_536_000

    var onProgressUpdate: ((Float) -> Void)?

    init(sessionConfiguration: @escaping () -> URLSessionConfiguration = { .default }) {
        self.sessionConfiguration = sessionConfiguration
    }

    /// "Loaded" means a non-empty API key is configured — nothing is downloaded locally.
    var isModelLoaded: Bool { !apiKey.isEmpty }

    func initialize() async throws {
        let prefs = CoreAccess.preferences
        apiKey = (prefs.xaiAPIKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = prefs.xaiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        modelName = configured.isEmpty ? Self.defaultModel : configured
        formatEnabled = prefs.xaiFormatEnabled
        timeoutEnabled = prefs.xaiTimeoutEnabled
        timeoutSeconds = prefs.xaiTimeoutSeconds

        guard !apiKey.isEmpty else {
            throw XAIError.missingAPIKey
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
            let boundary = "Boundary-\(UUID().uuidString)"
            let request = self.makeRequest(
                boundary: boundary,
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
                        throw XAIError.network(nil)
                    }
                    if (200..<300).contains(http.statusCode) {
                        self.onProgressUpdate?(1.0)
                        let text = try Self.parseTranscript(from: data)
                        return text
                    }
                    if http.statusCode == 401 || http.statusCode == 403 {
                        // Never log the key; only whether auth failed.
                        throw XAIError.invalidAPIKey
                    }
                    let body = String(data: data, encoding: .utf8) ?? ""
                    // Status + truncated body only — never echo Authorization.
                    print("XAIEngine HTTP \(http.statusCode) (attempt \(attempt)/\(Self.maxAttempts)): \(Self.safeBodyPreview(body))")
                    if attempt < Self.maxAttempts, Self.isRetryable(status: http.statusCode) {
                        retry = true
                    } else {
                        throw XAIError.api(http.statusCode, Self.serverMessage(from: data))
                    }
                } catch let urlError as URLError {
                    print("XAIEngine network error (attempt \(attempt)/\(Self.maxAttempts)): \(urlError.code.rawValue)")
                    guard attempt < Self.maxAttempts, Self.isRetryable(urlError) else {
                        throw XAIError.network(urlError)
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
        } catch let error as XAIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw XAIError.network(error)
        }
    }

    // MARK: - Request building (testable)

    func makeSession() -> URLSession {
        let interval = timeoutEnabled ? max(1, timeoutSeconds) : Self.noTimeoutInterval
        let config = sessionConfiguration()
        config.timeoutIntervalForRequest = interval
        config.timeoutIntervalForResource = interval
        return URLSession(configuration: config)
    }

    /// Builds the multipart body with option fields first and `file` last, matching
    /// https://docs.x.ai/developers/model-capabilities/audio/speech-to-text
    func makeRequest(
        boundary: String,
        filename: String,
        audioData: Data,
        language: String
    ) -> URLRequest {
        var request = URLRequest(url: Self.endpointURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var fields: [(String, String)] = [("model", modelName)]
        if formatEnabled {
            fields.append(("format", "true"))
        }
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

    // MARK: - Parsing / errors

    /// Official success body: `{ "text", "language", "duration", "words" }`.
    static func parseTranscript(from data: Data) throws -> String {
        guard !data.isEmpty else { throw XAIError.malformedResponse }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XAIError.malformedResponse
        }
        guard let text = json["text"] as? String else {
            throw XAIError.malformedResponse
        }
        return text
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

enum XAIError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case network(Error?)
    case api(Int, String?)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an xAI API key in Settings → Models → Grok (xAI). Speech usage is billed separately from a SuperGrok subscription."
        case .invalidAPIKey:
            return "xAI rejected the API key. Check it in Settings → Models → Grok (xAI)."
        case .network(let e):
            return "Couldn't reach xAI. \(e?.localizedDescription ?? "Check your connection.")"
        case .api(let code, let msg):
            return "xAI error \(code): \(msg ?? "request failed")."
        case .malformedResponse:
            return "xAI returned a response this app could not read."
        }
    }
}
