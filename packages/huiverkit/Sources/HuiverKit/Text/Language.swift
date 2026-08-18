import Foundation
import NaturalLanguage

/// What language a book is in, and whether the engine can actually read it.
///
/// This is per book rather than a global setting because a library is not
/// monolingual: one Dutch book among twenty English ones should not need a
/// setting changed before and after reading it.
///
/// The list is Chatterbox's own 23 languages, from `SUPPORTED_LANGUAGES` in
/// `chatterbox/mtl_tts.py`. Which of them the installed models can *speak* is a
/// separate question — see `ChatterboxEngine.languages`. Chatterbox Nano is
/// English-only: it uses GPT-2's English byte-pair vocabulary and its generator
/// takes no language argument. The multilingual checkpoint is a different and
/// much larger model.
public struct Language: Sendable, Hashable, Identifiable, Codable {
    public let code: String
    public let name: String

    public var id: String { code }

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    /// Every language Chatterbox has a model for, in name order.
    public static let all: [Language] = [
        ("ar", "Arabic"), ("zh", "Chinese"), ("da", "Danish"), ("nl", "Dutch"),
        ("en", "English"), ("fi", "Finnish"), ("fr", "French"), ("de", "German"),
        ("el", "Greek"), ("he", "Hebrew"), ("hi", "Hindi"), ("it", "Italian"),
        ("ja", "Japanese"), ("ko", "Korean"), ("ms", "Malay"), ("no", "Norwegian"),
        ("pl", "Polish"), ("pt", "Portuguese"), ("ru", "Russian"), ("es", "Spanish"),
        ("sw", "Swahili"), ("sv", "Swedish"), ("tr", "Turkish"),
    ].map { Language(code: $0.0, name: $0.1) }

    public static let english = Language(code: "en", name: "English")

    public static func named(_ code: String) -> Language {
        all.first { $0.code == code.lowercased() } ?? english
    }

    /// Guess a book's language from its text.
    ///
    /// Uses Apple's own recogniser rather than a word list: it is on-device,
    /// costs nothing, and is far better at telling Dutch from German than
    /// anything worth hand-writing. Only a guess the recogniser is reasonably
    /// sure of is accepted, and only for a language Chatterbox knows — a book it
    /// cannot place stays English rather than becoming something stranger.
    public static func detect(in text: String) -> Language {
        let sample = String(text.prefix(4000))
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(sample)

        let ranked = recogniser.languageHypotheses(withMaximum: 3)
        guard let best = ranked.max(by: { $0.value < $1.value }), best.value >= 0.55,
              let match = all.first(where: { $0.code == best.key.rawValue })
        else { return english }
        return match
    }
}
