import XCTest
@testable import OpenSuperWhisperCore

/// How the stored engine and model read back as the active option (#63). The menu, the Settings
/// lists and the settings file all go through this mapping, so a change here moves every one of
/// them. `activate` is left out: it reloads the engine.
final class ModelCatalogActiveOptionTests: CoreTestCase {

    private var prefs: TestPreferences { CoreTestEnvironment.preferences }

    func testWhisperNamesTheModelAfterItsFile() {
        prefs.selectedEngine = "whisper"
        prefs.selectedWhisperModelPath = "/models/ggml-large-v3-turbo.bin"
        XCTAssertEqual(ModelCatalog.activeOption(),
                       DictationModelOption(engine: "whisper", identifier: "/models/ggml-large-v3-turbo.bin",
                                            displayName: "ggml-large-v3-turbo"))
    }

    func testWhisperWithoutAModelHasNoOption() {
        prefs.selectedEngine = "whisper"
        prefs.selectedWhisperModelPath = nil
        XCTAssertNil(ModelCatalog.activeOption())
    }

    func testParakeetIsItsModelVersion() {
        prefs.selectedEngine = "fluidaudio"
        prefs.fluidAudioModelVersion = "v2"
        XCTAssertEqual(ModelCatalog.activeOption()?.identifier, "v2")
        XCTAssertEqual(ModelCatalog.activeOption()?.engine, "fluidaudio")
    }

    func testSingleModelEnginesUseADefaultIdentifier() {
        prefs.selectedEngine = "sensevoice"
        XCTAssertEqual(ModelCatalog.activeOption(),
                       DictationModelOption(engine: "sensevoice", identifier: "default", displayName: "SenseVoice"))
        prefs.selectedEngine = "apple"
        XCTAssertEqual(ModelCatalog.activeOption(),
                       DictationModelOption(engine: "apple", identifier: "default", displayName: "Apple Speech"))
    }

    func testARemoteModelIsTrimmed() {
        prefs.selectedEngine = "remote"
        prefs.remoteServerModel = "  whisper-1 \n"
        XCTAssertEqual(ModelCatalog.activeOption(),
                       DictationModelOption(engine: "remote", identifier: "whisper-1", displayName: "whisper-1"))

        prefs.selectedEngine = "xai"
        prefs.xaiModel = "grok-voice-transcribe-2.0"
        XCTAssertEqual(ModelCatalog.activeOption()?.engine, "xai")
        XCTAssertEqual(ModelCatalog.activeOption()?.identifier, "grok-voice-transcribe-2.0")

        prefs.selectedEngine = "gemini"
        prefs.geminiModel = "gemini-2.5-flash"
        XCTAssertEqual(ModelCatalog.activeOption()?.engine, "gemini")
        XCTAssertEqual(ModelCatalog.activeOption()?.identifier, "gemini-2.5-flash")

        prefs.selectedEngine = "groq"
        prefs.cloudGroqModel = "whisper-large-v3-turbo"
        XCTAssertEqual(ModelCatalog.activeOption()?.engine, "groq")
        XCTAssertEqual(ModelCatalog.activeOption()?.identifier, "whisper-large-v3-turbo")
    }

    func testARemoteServerWithoutAModelHasNoOption() {
        prefs.selectedEngine = "remote"
        prefs.remoteServerModel = "   "
        XCTAssertNil(ModelCatalog.activeOption())
    }

    func testAnUnknownEngineHasNoOption() {
        prefs.selectedEngine = "legacy-unknown-engine"
        XCTAssertNil(ModelCatalog.activeOption())
    }
}
