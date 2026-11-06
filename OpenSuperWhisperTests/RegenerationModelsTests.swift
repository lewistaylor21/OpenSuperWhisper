import XCTest
@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// The regenerate menu offers only models that can transcribe the recording now (#275): a chat
/// model from a Remote server, a Remote server nobody configured, or an engine that is not
/// installed would each be a row that can only fail.
final class RegenerationModelsTests: XCTestCase {

    private func option(_ engine: String, _ id: String) -> DictationModelOption {
        DictationModelOption(engine: engine, identifier: id, displayName: id)
    }

    func testRemoteKeepsTranscriptionModelsAndDropsChatModels() {
        let models = RegenerationModels.usable(.init(
            remote: [option("remote", "whisper-large-v3-turbo"), option("remote", "gpt-oss-120b"),
                     option("remote", "llama-3.3-70b-versatile"), option("remote", "playai-tts")],
            remoteConfigured: true))

        XCTAssertEqual(models.map(\.option.identifier), ["whisper-large-v3-turbo"])
        XCTAssertEqual(models.map(\.family), [.remote])
    }

    func testUnconfiguredRemoteOffersNothingEvenWithACachedList() {
        let models = RegenerationModels.usable(.init(
            remote: [option("remote", "whisper-1")], remoteConfigured: false))

        XCTAssertTrue(models.isEmpty)
    }

    func testNothingInstalledOffersNothing() {
        XCTAssertTrue(RegenerationModels.usable(.init()).isEmpty)
    }

    func testEveryInstalledFamilyIsKeptAndGroupedInPickerOrder() {
        let models = RegenerationModels.usable(.init(
            parakeet: [option("fluidaudio", "v3")],
            whisper: [option("whisper", "/models/ggml-base.bin"), option("whisper", "/models/ggml-small.bin")],
            senseVoice: [option("sensevoice", "default")],
            appleSpeech: [option("apple", "default")],
            remote: [option("remote", "whisper-1")],
            groq: [option("groq", "whisper-large-v3-turbo")],
            xai: [option("xai", "grok-voice-transcribe-2.0")],
            gemini: [option("gemini", "gemini-3.5-transcribe")],
            remoteConfigured: true,
            groqConfigured: true,
            xaiConfigured: true,
            geminiConfigured: true))

        XCTAssertEqual(models.map(\.family),
                       [.parakeet, .whisper, .whisper, .senseVoice, .appleSpeech, .remote, .groq, .xai, .gemini])
        XCTAssertEqual(models.map(\.option.identifier),
                       ["v3", "/models/ggml-base.bin", "/models/ggml-small.bin", "default", "default",
                        "whisper-1", "whisper-large-v3-turbo", "grok-voice-transcribe-2.0", "gemini-3.5-transcribe"])
    }

    func testCloudFamiliesRequireConfiguredKeys() {
        let withoutKeys = RegenerationModels.usable(.init(
            groq: [option("groq", "whisper-large-v3-turbo")],
            xai: [option("xai", "grok-voice-transcribe-2.0")],
            gemini: [option("gemini", "gemini-3.5-transcribe")],
            groqConfigured: false,
            xaiConfigured: false,
            geminiConfigured: false))
        XCTAssertTrue(withoutKeys.isEmpty)

        let withKeys = RegenerationModels.usable(.init(
            groq: [option("groq", "whisper-large-v3-turbo")],
            xai: [option("xai", "grok-voice-transcribe-2.0")],
            gemini: [option("gemini", "gemini-3.5-transcribe")],
            groqConfigured: true,
            xaiConfigured: true,
            geminiConfigured: true))
        XCTAssertEqual(withKeys.map(\.family), [.groq, .xai, .gemini])
    }

    func testAppleSpeechNeedsItsAssetsForTheLanguage() {
        XCTAssertTrue(ModelCatalog.appleSpeechModels(forLanguage: "zz-no-such-language").isEmpty)
    }
}
