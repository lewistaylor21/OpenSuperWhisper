import SwiftUI
import OpenSuperWhisperCore

/// Settings panels for the first-party cloud STT engines (xAI Grok, Gemini).
/// Kept separate from Remote (OpenAI-compatible servers): different endpoints, auth,
/// and billing. Selecting one never silently sends audio to the other.

// MARK: - Grok (xAI)

struct XAISettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var revealKey = false

    var body: some View {
        SPaneStack(spacing: 26) {
            SettingsGroup("Grok Voice Transcribe") {
                SettingNotice("Audio is uploaded to xAI (api.x.ai). Speech-to-text usage is billed by xAI separately — a SuperGrok subscription is not API credit. This free app does not include cloud minutes.")
                SettingRow("API key", hint: "Personal xAI API key. Stored in your Keychain, never in settings backups.") {
                    HStack(spacing: 12) {
                        apiKeyField
                        Link("Get a key", destination: URL(string: "https://console.x.ai/")!)
                            .scaledFont(size: 12)
                    }
                }
                SettingRow("Model", hint: "Official model id. Default is grok-voice-transcribe-2.0.") {
                    TextField("grok-voice-transcribe-2.0", text: $viewModel.xaiModel)
                        .textFieldStyle(.plain)
                        .scaledFont(size: 13, design: .monospaced)
                        .foregroundColor(STheme.textBright)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.inputBg))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
                        .frame(maxWidth: 320)
                }
                SettingRow("Written formatting",
                           hint: "Asks xAI for inverse text normalization (numbers, currency) when a language is set.") {
                    SSwitch(isOn: $viewModel.xaiFormatEnabled)
                }
                SettingRow("Use Grok") {
                    Button("Use for dictation") {
                        let model = viewModel.xaiModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        viewModel.selectXAI(model.isEmpty ? "grok-voice-transcribe-2.0" : model)
                    }
                    .buttonStyle(.sPrimary)
                    .disabled(viewModel.xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            SettingsGroup("Reliability") {
                timeoutRow(
                    enabled: $viewModel.xaiTimeoutEnabled,
                    seconds: $viewModel.xaiTimeoutSeconds
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var apiKeyField: some View {
        Group {
            if revealKey {
                TextField("xai-…", text: $viewModel.xaiAPIKey)
            } else {
                SecureField("xai-…", text: $viewModel.xaiAPIKey)
            }
        }
        .textFieldStyle(.plain)
        .scaledFont(size: 13, design: .monospaced)
        .foregroundColor(STheme.textBright)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.inputBg))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
        .frame(maxWidth: 280)
        Button(revealKey ? "Hide" : "Show") { revealKey.toggle() }
            .buttonStyle(.sSecondary)
    }
}

// MARK: - Gemini

struct GeminiSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var revealKey = false

    var body: some View {
        SPaneStack(spacing: 26) {
            SettingsGroup("Gemini") {
                SettingNotice("Audio is uploaded to Google's Gemini API (generativelanguage.googleapis.com) via generateContent — not Google Cloud Speech-to-Text. Billing is token-based (input and output); this app does not promise a fixed per-minute price.")
                SettingRow("API key", hint: "Google AI Studio key. Stored in your Keychain, separate from xAI and Remote keys.") {
                    HStack(spacing: 12) {
                        apiKeyField
                        Link("Get a key", destination: URL(string: "https://aistudio.google.com/apikey")!)
                            .scaledFont(size: 12)
                    }
                }
                SettingRow("Model",
                           hint: "Default gemini-3.5-transcribe (dedicated STT). You can set gemini-2.5-flash for multimodal audio understanding.") {
                    TextField("gemini-3.5-transcribe", text: $viewModel.geminiModel)
                        .textFieldStyle(.plain)
                        .scaledFont(size: 13, design: .monospaced)
                        .foregroundColor(STheme.textBright)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.inputBg))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
                        .frame(maxWidth: 320)
                }
                SettingRow("Use Gemini") {
                    Button("Use for dictation") {
                        let model = viewModel.geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        viewModel.selectGemini(model.isEmpty ? "gemini-3.5-transcribe" : model)
                    }
                    .buttonStyle(.sPrimary)
                    .disabled(viewModel.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            SettingsGroup("Reliability") {
                timeoutRow(
                    enabled: $viewModel.geminiTimeoutEnabled,
                    seconds: $viewModel.geminiTimeoutSeconds
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var apiKeyField: some View {
        Group {
            if revealKey {
                TextField("AIza…", text: $viewModel.geminiAPIKey)
            } else {
                SecureField("AIza…", text: $viewModel.geminiAPIKey)
            }
        }
        .textFieldStyle(.plain)
        .scaledFont(size: 13, design: .monospaced)
        .foregroundColor(STheme.textBright)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.inputBg))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
        .frame(maxWidth: 280)
        Button(revealKey ? "Hide" : "Show") { revealKey.toggle() }
            .buttonStyle(.sSecondary)
    }
}

// MARK: - Shared timeout control

@ViewBuilder
private func timeoutRow(enabled: Binding<Bool>, seconds: Binding<Double>) -> some View {
    SettingRow("Request timeout",
               hint: enabled.wrappedValue
               ? "Raise it for slow cloud responses."
               : "No timeout: requests wait as long as it takes.") {
        HStack(spacing: 8) {
            if enabled.wrappedValue {
                TextField("", value: seconds, format: .number)
                    .textFieldStyle(.plain)
                    .scaledFont(size: 13, design: .monospaced)
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(STheme.textBright)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(width: 64)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.inputBg))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(STheme.border, lineWidth: 1))
                Text("s").scaledFont(size: 13).foregroundColor(STheme.hint)
            }
            SSwitch(isOn: enabled)
        }
    }
}
