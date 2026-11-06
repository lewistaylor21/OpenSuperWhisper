import Foundation

/// MIME types for cloud STT uploads (xAI multipart file field, Gemini inlineData).
enum CloudAudioMIME {
    static func type(forFilename filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mp3"
        case "m4a": return "audio/m4a"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "opus": return "audio/opus"
        case "webm": return "audio/webm"
        case "aiff", "aif": return "audio/aiff"
        case "mp4": return "audio/mp4"
        case "mpeg", "mpga": return "audio/mpeg"
        default: return "audio/wav"
        }
    }
}

extension Data {
    mutating func appendMultipart(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }

    mutating func appendMultipartField(_ name: String, _ value: String, boundary: String) {
        appendMultipart("--\(boundary)\r\n")
        appendMultipart("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendMultipart("\(value)\r\n")
    }

    mutating func appendMultipartFile(_ name: String, filename: String, data: Data,
                                      mimeType: String, boundary: String) {
        appendMultipart("--\(boundary)\r\n")
        appendMultipart("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendMultipart("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        appendMultipart("\r\n")
    }
}
