import XCTest
@testable import OpenSuperWhisperCore

/// Network-mocked coverage of the xAI official STT path (`POST /v1/stt`).
/// No real credentials and no live api.x.ai calls.
final class XAIEngineTests: CoreTestCase {

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

    private func engine(apiKey: String = "xai-test-key",
                        model: String = XAIEngine.defaultModel,
                        format: Bool = true,
                        stubbed: Bool = true) async throws -> XAIEngine {
        preferences.xaiAPIKey = apiKey
        preferences.xaiModel = model
        preferences.xaiFormatEnabled = format
        preferences.xaiTimeoutEnabled = true
        preferences.xaiTimeoutSeconds = 60
        let engine = stubbed
            ? XAIEngine(sessionConfiguration: CloudStubServer.configuration)
            : XAIEngine()
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

    // MARK: - Request shape

    func testMultipartPutsOptionsBeforeFileAndUsesBearerAuth() async throws {
        let engine = try await engine(apiKey: "  sk-xai  ", model: "  grok-voice-transcribe-2.0  ")
        let request = engine.makeRequest(boundary: "BOUNDARY", filename: "clip.wav",
                                         audioData: Data("RIFFDATA".utf8), language: "en")

        XCTAssertEqual(request.url, XAIEngine.endpointURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-xai")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                       "multipart/form-data; boundary=BOUNDARY")

        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertEqual(body,
                       field("model", "grok-voice-transcribe-2.0")
                       + field("format", "true")
                       + field("language", "en")
                       + fileField + closing)
        // File must be last: option fields precede the file disposition.
        let fileIndex = try XCTUnwrap(body.range(of: "name=\"file\""))
        let modelIndex = try XCTUnwrap(body.range(of: "name=\"model\""))
        XCTAssertTrue(modelIndex.lowerBound < fileIndex.lowerBound)
        XCTAssertFalse(body.contains("response_format"), "must not use OpenAI transcription schema")
        XCTAssertFalse(body.contains("audio/transcriptions"))
    }

    func testAutoLanguageOmitsLanguageField() async throws {
        let engine = try await engine()
        let request = engine.makeRequest(boundary: "BOUNDARY", filename: "clip.wav",
                                         audioData: Data("RIFFDATA".utf8), language: "auto")
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertFalse(body.contains("name=\"language\""))
    }

    func testMissingAPIKeyFailsInitializeWithoutNetwork() async {
        preferences.xaiAPIKey = "   "
        let engine = XAIEngine(sessionConfiguration: CloudStubServer.configuration)
        do {
            try await engine.initialize()
            XCTFail("initialized without a key")
        } catch XAIError.missingAPIKey {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(CloudStubServer.requests.count, 0)
    }

    // MARK: - Parsing

    func testParsesOfficialTranscriptJSON() throws {
        let data = Data(#"{"text":"hello from grok","language":"en","duration":1.2,"words":[]}"#.utf8)
        XCTAssertEqual(try XAIEngine.parseTranscript(from: data), "hello from grok")
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try XAIEngine.parseTranscript(from: Data("not-json".utf8))) { error in
            guard case XAIError.malformedResponse = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertThrowsError(try XAIEngine.parseTranscript(from: Data(#"{"language":"en"}"#.utf8))) { error in
            guard case XAIError.malformedResponse = error else {
                return XCTFail("\(error)")
            }
        }
    }

    // MARK: - Live stubbed round-trips

    func testTranscribeSendsBuiltRequestAndReturnsText() async throws {
        CloudStubServer.reset(responses: [(200, #"{"text":"spoken words","language":"en","duration":0.5}"#)])
        let engine = try await engine(stubbed: true)

        let text = try await engine.transcribeAudio(url: try clipFile(), settings: settings(language: "fr"))

        XCTAssertEqual(text, "spoken words")
        let sent = try XCTUnwrap(CloudStubServer.requests.first)
        XCTAssertEqual(sent.url, "https://api.x.ai/v1/stt")
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer xai-test-key")
        let body = try XCTUnwrap(String(data: sent.body, encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"model\""))
        XCTAssertTrue(body.contains("grok-voice-transcribe-2.0"))
        XCTAssertTrue(body.contains("name=\"language\""))
        XCTAssertTrue(body.contains("\r\nfr\r\n"))
        let filePos = try XCTUnwrap(body.range(of: "name=\"file\""))
        let modelPos = try XCTUnwrap(body.range(of: "name=\"model\""))
        XCTAssertTrue(modelPos.lowerBound < filePos.lowerBound)
        // Key must never appear in the multipart body.
        XCTAssertFalse(body.contains("xai-test-key"))
    }

    func testUnauthorizedRejectsKeyWithoutRetry() async throws {
        CloudStubServer.reset(responses: [(401, #"{"error":"unauthorized"}"#)])
        let engine = try await engine(stubbed: true)
        do {
            _ = try await engine.transcribeAudio(url: try clipFile(), settings: settings())
            XCTFail("401 succeeded")
        } catch XAIError.invalidAPIKey {
        }
        XCTAssertEqual(CloudStubServer.requests.count, 1)
    }

    func testRateLimitIsRetried() async throws {
        CloudStubServer.reset(responses: [
            (429, #"{"error":"rate"}"#),
            (200, #"{"text":"ok","language":"en","duration":1}"#),
        ])
        let engine = try await engine(stubbed: true)
        let text = try await engine.transcribeAudio(url: try clipFile(), settings: settings())
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(CloudStubServer.requests.count, 2)
    }

    func testServerErrorSurfacesStatus() async throws {
        CloudStubServer.reset(responses: [(500, #"{"error":{"message":"boom"}}"#),
                                          (500, #"{"error":{"message":"boom"}}"#),
                                          (500, #"{"error":{"message":"boom"}}"#)])
        let engine = try await engine(stubbed: true)
        do {
            _ = try await engine.transcribeAudio(url: try clipFile(), settings: settings())
            XCTFail("500 succeeded")
        } catch XAIError.api(let code, let message) {
            XCTAssertEqual(code, 500)
            XCTAssertEqual(message, "boom")
        }
        XCTAssertEqual(CloudStubServer.requests.count, 3)
    }

    func testSelectingXAIDoesNotBuildWhisperOrRemote() async {
        preferences.selectedEngine = "xai"
        preferences.xaiAPIKey = "k"
        XCTAssertEqual(TranscriptionService.engineKind(forSelectedEngine: "xai"), .xai)
        let built = await TranscriptionService.buildEngine(.xai)
        XCTAssertTrue(built is XAIEngine)
        XCTAssertFalse(built is WhisperEngine)
        XCTAssertFalse(built is RemoteEngine)
        XCTAssertFalse(built is GeminiTranscriptionEngine)
    }
}
