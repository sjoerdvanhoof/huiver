import Foundation

/// Serialized boundary around eSpeak NG's process-global C API. The native
/// bridge supplies the converter closure when the GPL core is linked; keeping
/// this actor in HuiverKit makes concurrency and failure behavior testable
/// without ever passing phonemes to Chatterbox.
public actor EspeakBackend {
    public typealias Converter = @Sendable (_ text: String, _ languageCode: String) throws -> String

    private let converter: Converter

    public init(converter: @escaping Converter) {
        self.converter = converter
    }

    public func phonemes(for text: String, languageCode: String) throws -> String {
        try converter(text, languageCode.lowercased())
    }

    public enum BackendError: LocalizedError {
        case unavailable
        public var errorDescription: String? {
            "eSpeak NG data or its native preprocessing core is unavailable."
        }
    }
}

