import XCTest
@testable import OpenSuperWhisperCore

/// Network-mocked coverage of first-party Groq STT
/// (`POST https://api.groq.com/openai/v1/audio/transcriptions`,
/// model `whisper-large-v3-turbo`). Not xAI `/v1/stt`, not Gemini.
final class GroqEngineTests: CoreTestCase {

    private var preferences: TestPreferences { CoreTestEnvironment.preferences }
    private var tempDirectories: [URL] = []

    override func tearDown() {
        tempDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        tempDirectories = []
        CloudStubServer.reset()
        super.tearDown()
    }

    private func clipFile(named name: String = "clip.wav", bytes: String = "RIFFDATA") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let url = directory.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private func engine(apiKey: String = "gsk-test",
                        model: String = GroqEngine.defaultModel,
                        stubbed: Bool = true) async throws -> GroqEngine {
        preferences.cloudGroqAPIKey = apiKey
        preferences.cloudGroqModel = model
        preferences.cloudGroqTimeoutEnabled = true
        preferences.cloudGroqTimeoutSeconds = 60
        let engine = stubbed
            ? GroqEngine(sessionConfiguration: CloudStubServer.configuration)
            : GroqEngine()
        try await engine.initialize()
        return engine
    }

    private func settings(language: String = "en") -> TranscriptionSettings {
        var s = Fixtures.pinnedSettings()
        s.selectedLanguage = language
        return s
    }

    private func field(_ name: String, _ value: String) -> String {
        "--BOUNDARY\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
    }

    private let fileField = "--BOUNDARY\r\n"
        + "Content-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\n"
        + "Content-Type: audio/wav\r\n\r\nRIFFDATA\r\n"
    private let closing = "--BOUNDARY--\r\n"

    func testPostsToOfficialGroqTranscriptionsURL() async throws {
        let engine = try await engine()
        let request = engine.makeRequest(boundary: "BOUNDARY", filename: "clip.wav",
                                         audioData: Data("RIFFDATA".utf8), language: "en")

        XCTAssertEqual(request.url, GroqEngine.transcriptionsURL)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gsk-test")
        XCTAssertFalse(request.url!.absoluteString.contains("api.x.ai"))
        XCTAssertFalse(request.url!.absoluteString.contains("generativelanguage.googleapis.com"))
        XCTAssertFalse(request.url!.absoluteString.contains("/v1/stt"))

        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertEqual(body,
                       field("model", "whisper-large-v3-turbo")
                       + field("response_format", "json")
                       + field("language", "en")
                       + fileField + closing)
        let filePos = try XCTUnwrap(body.range(of: "name=\"file\""))
        let modelPos = try XCTUnwrap(body.range(of: "name=\"model\""))
        XCTAssertTrue(modelPos.lowerBound < filePos.lowerBound)
    }

    func testMissingAPIKeyFailsWithoutNetwork() async {
        preferences.cloudGroqAPIKey = "  "
        let engine = GroqEngine(sessionConfiguration: CloudStubServer.configuration)
        do {
            try await engine.initialize()
            XCTFail("initialized without a key")
        } catch GroqError.missingAPIKey {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(CloudStubServer.requests.count, 0)
    }

    func testTranscribeParsesOpenAIStyleText() async throws {
        CloudStubServer.reset(responses: [(200, #"{"text":"hello groq"}"#)])
        let engine = try await engine(stubbed: true)
        let text = try await engine.transcribeAudio(url: try clipFile(), settings: settings())
        XCTAssertEqual(text, "hello groq")
        let sent = try XCTUnwrap(CloudStubServer.requests.first)
        XCTAssertEqual(sent.url, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer gsk-test")
        XCTAssertFalse(String(data: sent.body, encoding: .utf8)!.contains("gsk-test"))
    }

    func testUnauthorizedRejectsKey() async throws {
        CloudStubServer.reset(responses: [(401, #"{"error":{"message":"Invalid API Key"}}"#)])
        let engine = try await engine(stubbed: true)
        do {
            _ = try await engine.transcribeAudio(url: try clipFile(), settings: settings())
            XCTFail("401 succeeded")
        } catch GroqError.invalidAPIKey {
        }
        XCTAssertEqual(CloudStubServer.requests.count, 1)
    }

    func testRateLimitIsRetried() async throws {
        CloudStubServer.reset(responses: [
            (429, #"{"error":"rate"}"#),
            (200, #"{"text":"ok"}"#),
        ])
        let engine = try await engine(stubbed: true)
        XCTAssertEqual(try await engine.transcribeAudio(url: try clipFile(), settings: settings()), "ok")
        XCTAssertEqual(CloudStubServer.requests.count, 2)
    }

    func testSelectingGroqBypassesLocalXAIAndGemini() async {
        preferences.selectedEngine = "groq"
        preferences.cloudGroqAPIKey = "k"
        XCTAssertEqual(TranscriptionService.engineKind(forSelectedEngine: "groq"), .groq)
        let built = await TranscriptionService.buildEngine(.groq)
        XCTAssertTrue(built is GroqEngine)
        XCTAssertFalse(built is WhisperEngine)
        XCTAssertFalse(built is XAIEngine)
        XCTAssertFalse(built is GeminiTranscriptionEngine)
        XCTAssertFalse(built is RemoteEngine)
    }

    func testThreeCloudProvidersHaveDistinctEndpointsAndKeys() async throws {
        preferences.cloudGroqAPIKey = "gsk-only"
        preferences.xaiAPIKey = "xai-only"
        preferences.geminiAPIKey = "gemini-only"
        preferences.cloudGroqModel = GroqEngine.defaultModel
        preferences.xaiModel = XAIEngine.defaultModel
        preferences.geminiModel = GeminiTranscriptionEngine.defaultModel

        let groq = try await {
            let e = GroqEngine(sessionConfiguration: CloudStubServer.configuration)
            try await e.initialize()
            return e
        }()
        let xai = try await {
            let e = XAIEngine(sessionConfiguration: CloudStubServer.configuration)
            try await e.initialize()
            return e
        }()
        let gemini = try await {
            let e = GeminiTranscriptionEngine(sessionConfiguration: CloudStubServer.configuration)
            try await e.initialize()
            return e
        }()

        let groqReq = groq.makeRequest(boundary: "B", filename: "a.wav",
                                       audioData: Data([1]), language: "en")
        let xaiReq = xai.makeRequest(boundary: "B", filename: "a.wav",
                                     audioData: Data([1]), language: "en")
        let gemReq = try gemini.makeRequest(filename: "a.wav", audioData: Data([1]), language: "en")

        XCTAssertEqual(groqReq.url, GroqEngine.transcriptionsURL)
        XCTAssertEqual(xaiReq.url, XAIEngine.endpointURL)
        XCTAssertTrue(gemReq.url!.absoluteString.contains("generativelanguage.googleapis.com"))
        XCTAssertEqual(Set([groqReq.url!, xaiReq.url!, gemReq.url!]).count, 3)
        XCTAssertEqual(groqReq.value(forHTTPHeaderField: "Authorization"), "Bearer gsk-only")
        XCTAssertEqual(xaiReq.value(forHTTPHeaderField: "Authorization"), "Bearer xai-only")
        XCTAssertEqual(gemReq.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-only")
    }
}
