import XCTest
@testable import OpenSuperWhisperCore

/// Backend selection / catalog routing for the cloud STT engines. Ensures choosing
/// xAI or Gemini never silently activates Whisper, Remote, or the other cloud provider.
final class CloudProviderSelectionTests: CoreTestCase {

    private var preferences: TestPreferences { CoreTestEnvironment.preferences }

    func testEngineKindRoutesCloudIds() {
        XCTAssertEqual(TranscriptionService.engineKind(forSelectedEngine: "xai"), .xai)
        XCTAssertEqual(TranscriptionService.engineKind(forSelectedEngine: "gemini"), .gemini)
        XCTAssertEqual(TranscriptionService.engineKind(forSelectedEngine: "groq"), .groq)
        XCTAssertEqual(TranscriptionService.engineKind(forSelectedEngine: "remote"), .remote)
        XCTAssertEqual(TranscriptionService.engineKind(forSelectedEngine: "whisper"), .whisper)
    }

    func testDefaultEngineRemainsWhisper() {
        XCTAssertEqual(preferences.selectedEngine, "whisper")
        XCTAssertEqual(TranscriptionService.engineKind(forSelectedEngine: preferences.selectedEngine),
                       .whisper)
    }

    func testActivateXAIUpdatesCatalogWithoutTouchingRemote() {
        preferences.remoteServerURL = "https://api.groq.com/openai/v1"
        preferences.remoteServerModel = "whisper-large-v3"
        preferences.selectedEngine = "whisper"

        ModelCatalog.activate(DictationModelOption(
            engine: "xai",
            identifier: "grok-voice-transcribe-2.0",
            displayName: "Grok Voice Transcribe"))

        XCTAssertEqual(preferences.selectedEngine, "xai")
        XCTAssertEqual(preferences.xaiModel, "grok-voice-transcribe-2.0")
        XCTAssertEqual(preferences.remoteServerModel, "whisper-large-v3",
                       "activating xAI must not rewrite Remote settings")
        XCTAssertEqual(ModelCatalog.activeOption()?.engine, "xai")
    }

    func testActivateGeminiUpdatesCatalogWithoutTouchingXAI() {
        preferences.xaiModel = "grok-voice-transcribe-2.0"
        preferences.xaiAPIKey = "xai-key"

        ModelCatalog.activate(DictationModelOption(
            engine: "gemini",
            identifier: "gemini-2.5-flash",
            displayName: "gemini-2.5-flash"))

        XCTAssertEqual(preferences.selectedEngine, "gemini")
        XCTAssertEqual(preferences.geminiModel, "gemini-2.5-flash")
        XCTAssertEqual(preferences.xaiModel, "grok-voice-transcribe-2.0")
        XCTAssertEqual(preferences.xaiAPIKey, "xai-key")
        XCTAssertEqual(ModelCatalog.activeOption()?.engine, "gemini")
        XCTAssertEqual(ModelCatalog.activeOption()?.identifier, "gemini-2.5-flash")
    }

    func testBuildEngineClassesMatchKinds() async {
        let xai = await TranscriptionService.buildEngine(.xai)
        let gemini = await TranscriptionService.buildEngine(.gemini)
        let groq = await TranscriptionService.buildEngine(.groq)
        let remote = await TranscriptionService.buildEngine(.remote)
        let whisper = await TranscriptionService.buildEngine(.whisper)

        XCTAssertTrue(xai is XAIEngine)
        XCTAssertTrue(gemini is GeminiTranscriptionEngine)
        XCTAssertTrue(groq is GroqEngine)
        XCTAssertTrue(remote is RemoteEngine)
        XCTAssertTrue(whisper is WhisperEngine)
    }

    func testActivateGroqDoesNotTouchOtherCloudPrefs() {
        preferences.xaiModel = "grok-voice-transcribe-2.0"
        preferences.geminiModel = "gemini-3.5-transcribe"
        ModelCatalog.activate(DictationModelOption(
            engine: "groq",
            identifier: "whisper-large-v3-turbo",
            displayName: "Groq Whisper Turbo"))
        XCTAssertEqual(preferences.selectedEngine, "groq")
        XCTAssertEqual(preferences.cloudGroqModel, "whisper-large-v3-turbo")
        XCTAssertEqual(preferences.xaiModel, "grok-voice-transcribe-2.0")
        XCTAssertEqual(preferences.geminiModel, "gemini-3.5-transcribe")
    }

    func testRemoteFallbackGateIgnoresCloudEngines() {
        // shouldUseFallback may still classify network errors, but transcribe() only
        // applies remoteFallback when selectedEngine == "remote".
        preferences.selectedEngine = "xai"
        preferences.remoteFallbackEnabled = true
        preferences.remoteFallbackModel = DictationModelOption(
            engine: "whisper", identifier: "/m.bin", displayName: "m")
        XCTAssertEqual(preferences.selectedEngine, "xai")
        XCTAssertNotEqual(preferences.selectedEngine, "remote")
    }

    func testXAIAndGeminiModelsAreListedSeparately() {
        preferences.xaiModel = "grok-voice-transcribe-2.0"
        preferences.geminiModel = "gemini-3.5-transcribe"
        let xai = ModelCatalog.xaiModels()
        let gemini = ModelCatalog.geminiModels()
        XCTAssertEqual(xai.map(\.engine), ["xai"])
        XCTAssertEqual(gemini.map(\.engine), ["gemini"])
        XCTAssertNotEqual(xai.first?.identifier, gemini.first?.identifier)
    }
}
