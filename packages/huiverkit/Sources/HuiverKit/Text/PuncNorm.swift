import Foundation

/// The text tidy-up Chatterbox does before tokenising.
///
/// A port of `punc_norm` in chatterbox/tts_turbo.py. It matters more than it
/// looks: the model was trained on text shaped this way, and a sentence handed
/// over without a final full stop tends to be read as though it runs on, then
/// trail off into a hallucinated continuation.
///
/// The two `midSentence` flags are this app's addition, for chunks that are
/// fragments of a sentence too long to say in one go. Upstream never sees
/// those — it normalises whole utterances — so the base rules mis-shape them:
/// capitalising the first word of a fragment cues sentence-opening prosody in
/// the middle of a sentence, and a terminal full stop makes the model wrap the
/// fragment up as finished. A continuation keeps its lowercase opening, and a
/// fragment that carries on ends on a comma — a pause, not an ending.
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

    public static func apply(
        _ text: String,
        beginsMidSentence: Bool = false,
        endsMidSentence: Bool = false
    ) -> String {
        if text.isEmpty { return "You need to add some text for me to talk." }

        var out = text
        if !beginsMidSentence, let first = out.first, first.isLowercase {
            out.replaceSubrange(out.startIndex...out.startIndex, with: first.uppercased())
        }
        out = out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for (from, to) in replacements {
            out = out.replacingOccurrences(of: from, with: to)
        }
        while out.hasSuffix(" ") { out.removeLast() }
        if endsMidSentence {
            // A clause fragment can end on a semicolon, the one clause mark the
            // replacements leave alone; the model reads "…;." or "…;," as
            // noise, so it becomes the comma it prosodically is.
            if out.hasSuffix(";") {
                out.removeLast()
                out.append(",")
            }
            if let last = out.last, !enders.contains(last) { out.append(",") }
        } else if let last = out.last, !enders.contains(last) {
            out.append(".")
        }
        return out
    }
}
