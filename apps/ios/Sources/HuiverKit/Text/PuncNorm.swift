import Foundation

/// The text tidy-up Chatterbox does before tokenising.
///
/// A port of `punc_norm` in chatterbox/tts_turbo.py. It matters more than it
/// looks: the model was trained on text shaped this way, and a sentence handed
/// over without a final full stop tends to be read as though it runs on, then
/// trail off into a hallucinated continuation.
public enum PuncNorm {
    private static let replacements: [(String, String)] = [
        ("…", ", "),
        (":", ","),
        ("—", "-"),
        ("–", "-"),
        (" ,", ","),
        ("“", "\""),
        ("”", "\""),
        ("‘", "'"),
        ("’", "'"),
    ]

    private static let enders: Set<Character> = [".", "!", "?", "-", ","]

    public static func apply(_ text: String) -> String {
        if text.isEmpty { return "You need to add some text for me to talk." }

        var out = text
        if let first = out.first, first.isLowercase {
            out.replaceSubrange(out.startIndex...out.startIndex, with: first.uppercased())
        }
        out = out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for (from, to) in replacements {
            out = out.replacingOccurrences(of: from, with: to)
        }
        while out.hasSuffix(" ") { out.removeLast() }
        if let last = out.last, !enders.contains(last) { out.append(".") }
        return out
    }
}
