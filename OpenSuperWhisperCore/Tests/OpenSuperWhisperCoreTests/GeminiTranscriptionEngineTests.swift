import XCTest
@testable import OpenSuperWhisperCore

/// Network-mocked coverage of Gemini `generateContent` audio transcription.
/// Distinguishes dedicated `gemini-3.5-transcribe` from multimodal Flash; never
/// hits Google Cloud Speech-to-Text or an OpenAI `/audio/transcriptions` URL.
final class GeminiTranscriptionEngineTests: CoreTestCase {

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

    private func engine(apiKey: String = "AIza-test",
                        model: String = GeminiTranscriptionEngine.defaultModel,
                        stubbed: Bool = true) async throws -> GeminiTranscriptionEngine {
        preferences.geminiAPIKey = apiKey
        preferences.geminiModel = model
        preferences.geminiTimeoutEnabled = true
        preferences.geminiTimeoutSeconds = 60
        let engine = stubbed
            ? GeminiTranscriptionEngine(sessionConfiguration: CloudStubServer.configuration)
            : GeminiTranscriptionEngine()
        try await engine.initialize()
        return engine
    }

    private func settings(language: String = "en") -> TranscriptionSettings {
        var s = Fixtures.pinnedSettings()
        s.selectedLanguage = language
        return s
    }

    // MARK: - Endpoint / body

    func testDedicatedTranscribeEndpointAndAuthHeader() async throws {
        let engine = try await engine(model: "gemini-3.5-transcribe")
        let request = try engine.makeRequest(filename: "clip.wav",
                                             audioData: Data("RIFFDATA".utf8),
                                             language: "en")

        XCTAssertEqual(request.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe:generateContent")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     "Gemini uses x-goog-api-key, not Bearer")
        XCTAssertFalse(request.url!.absoluteString.contains("speech.googleapis.com"))
        XCTAssertFalse(request.url!.absoluteString.contains("audio/transcriptions"))

        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as! [String: Any]
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1, "dedicated STT sends audio only, no chat prompt")
        let inline = try XCTUnwrap(parts.first?["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["mimeType"] as? String, "audio/wav")
        XCTAssertEqual(inline["data"] as? String, Data("RIFFDATA".utf8).base64EncodedString())

        let generation = try XCTUnwrap(json["generationConfig"] as? [String: Any])
        let audioConfig = try XCTUnwrap(generation["audioTranscriptionConfig"] as? [String: Any])
        XCTAssertEqual(audioConfig["mode"] as? String, "VERBATIM")
        XCTAssertEqual(audioConfig["languageCodes"] as? [String], ["en"])
    }

    func testMultimodalFlashUsesVerbatimPrompt() {
        XCTAssertFalse(GeminiTranscriptionEngine.usesDedicatedTranscriptionAPI("gemini-2.5-flash"))
        let body = GeminiTranscriptionEngine.requestBody(
            model: "gemini-2.5-flash",
            mimeType: "audio/wav",
            base64Audio: "QUJD",
            language: "auto"
        )
        let contents = body["contents"] as! [[String: Any]]
        let parts = contents.first!["parts"] as! [[String: Any]]
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["text"] as? String, GeminiTranscriptionEngine.verbatimTranscriptionPrompt)
        XCTAssertNotNil(parts[1]["inlineData"])
        XCTAssertNotNil(body["systemInstruction"])
        XCTAssertNil(body["generationConfig"], "Flash multimodal has no audioTranscriptionConfig")
    }

    func testRejectsPathTraversalModelIds() {
        XCTAssertNil(GeminiTranscriptionEngine.endpoint(model: "../evil"))
        XCTAssertNil(GeminiTranscriptionEngine.endpoint(model: "a/b"))
        XCTAssertNil(GeminiTranscriptionEngine.endpoint(model: "x:y"))
        XCTAssertEqual(GeminiTranscriptionEngine.endpoint(model: "gemini-3.5-transcribe")?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe:generateContent")
    }

    func testMissingAPIKeyFailsInitializeWithoutNetwork() async {
        preferences.geminiAPIKey = nil
        let engine = GeminiTranscriptionEngine(sessionConfiguration: CloudStubServer.configuration)
        do {
            try await engine.initialize()
            XCTFail("initialized without a key")
        } catch GeminiTranscriptionError.missingAPIKey {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(CloudStubServer.requests.count, 0)
    }

    // MARK: - Parsing

    func testParsesGenerateContentCandidates() throws {
        let data = Data(#"{"candidates":[{"content":{"parts":[{"text":"hello gemini"}]},"finishReason":"STOP"}]}"#.utf8)
        XCTAssertEqual(try GeminiTranscriptionEngine.parseTranscript(from: data), "hello gemini")
    }

    func testEmptySpeechReturnsEmptyString() throws {
        let data = Data(#"{"candidates":[{"content":{"parts":[{"text":""}]},"finishReason":"STOP"}]}"#.utf8)
        XCTAssertEqual(try GeminiTranscriptionEngine.parseTranscript(from: data), "")
    }

    func testBlockedPromptThrows() {
        let data = Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8)
        XCTAssertThrowsError(try GeminiTranscriptionEngine.parseTranscript(from: data)) { error in
            guard case GeminiTranscriptionError.blocked("SAFETY") = error else {
                return XCTFail("\(error)")
            }
        }
    }

    func testMissingCandidatesThrows() {
        XCTAssertThrowsError(try GeminiTranscriptionEngine.parseTranscript(from: Data(#"{}"#.utf8))) { error in
            guard case GeminiTranscriptionError.emptyTranscript = error else {
                return XCTFail("\(error)")
            }
        }
    }

    // MARK: - Stubbed round-trips

    func testTranscribePostsToGenerateContent() async throws {
        CloudStubServer.reset(responses: [(200,
            #"{"candidates":[{"content":{"parts":[{"text":"dictated"}]},"finishReason":"STOP"}]}"#)])
        let engine = try await engine(stubbed: true)

        let text = try await engine.transcribeAudio(url: try clipFile(), settings: settings(language: "en"))

        XCTAssertEqual(text, "dictated")
        let sent = try XCTUnwrap(CloudStubServer.requests.first)
        XCTAssertTrue(sent.url.contains(":generateContent"))
        XCTAssertTrue(sent.url.contains("gemini-3.5-transcribe"))
        XCTAssertEqual(sent.headers["x-goog-api-key"], "AIza-test")
        XCTAssertNil(sent.headers["Authorization"])
        let body = try XCTUnwrap(String(data: sent.body, encoding: .utf8))
        XCTAssertFalse(body.contains("AIza-test"), "API key must not appear in JSON body")
        XCTAssertTrue(body.contains("audioTranscriptionConfig"))
        XCTAssertTrue(body.contains("VERBATIM"))
    }

    func testUnauthorizedRejectsKey() async throws {
        CloudStubServer.reset(responses: [(403, #"{"error":{"message":"API key not valid"}}"#)])
        let engine = try await engine(stubbed: true)
        do {
            _ = try await engine.transcribeAudio(url: try clipFile(), settings: settings())
            XCTFail("403 succeeded")
        } catch GeminiTranscriptionError.invalidAPIKey {
        }
        XCTAssertEqual(CloudStubServer.requests.count, 1)
    }

    func testClientErrorIsNotRetried() async throws {
        CloudStubServer.reset(responses: [(400, #"{"error":{"message":"bad audio"}}"#)])
        let engine = try await engine(stubbed: true)
        do {
            _ = try await engine.transcribeAudio(url: try clipFile(), settings: settings())
            XCTFail("400 succeeded")
        } catch GeminiTranscriptionError.api(let code, let message) {
            XCTAssertEqual(code, 400)
            XCTAssertEqual(message, "bad audio")
        }
        XCTAssertEqual(CloudStubServer.requests.count, 1)
    }

    func testSelectingGeminiBypassesLocalAndXAI() async {
        preferences.selectedEngine = "gemini"
        preferences.geminiAPIKey = "k"
        XCTAssertEqual(TranscriptionService.engineKind(forSelectedEngine: "gemini"), .gemini)
        let built = await TranscriptionService.buildEngine(.gemini)
        XCTAssertTrue(built is GeminiTranscriptionEngine)
        XCTAssertFalse(built is WhisperEngine)
        XCTAssertFalse(built is RemoteEngine)
        XCTAssertFalse(built is XAIEngine)
    }

    func testProvidersDoNotShareKeysOrEndpoints() async throws {
        preferences.xaiAPIKey = "xai-only"
        preferences.geminiAPIKey = "gemini-only"
        preferences.xaiModel = XAIEngine.defaultModel
        preferences.geminiModel = GeminiTranscriptionEngine.defaultModel

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

        let xaiReq = xai.makeRequest(boundary: "B", filename: "a.wav",
                                     audioData: Data([1]), language: "en")
        let gemReq = try gemini.makeRequest(filename: "a.wav", audioData: Data([1]), language: "en")

        XCTAssertEqual(xaiReq.url, XAIEngine.endpointURL)
        XCTAssertTrue(gemReq.url!.absoluteString.contains("generativelanguage.googleapis.com"))
        XCTAssertNotEqual(xaiReq.url, gemReq.url)
        XCTAssertEqual(xaiReq.value(forHTTPHeaderField: "Authorization"), "Bearer xai-only")
        XCTAssertEqual(gemReq.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-only")
        XCTAssertNil(xaiReq.value(forHTTPHeaderField: "x-goog-api-key"))
        XCTAssertNil(gemReq.value(forHTTPHeaderField: "Authorization"))
    }
}
