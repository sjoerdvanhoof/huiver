import Foundation
import Testing

@testable import HuiverKit

/// The chunker decides where a chapter pauses, so it has to agree with
/// `packages/shared/src/chunk.ts`. These cases are the same ones that file's
/// tests use, at the same limit.
struct ChunkerTests {
    @Test("keeps short text in one piece")
    func short() {
        #expect(Chunker.chunk("Hello there.", max: 420) == ["Hello there."])
    }

    @Test("collapses whitespace inside a paragraph")
    func whitespace() {
        #expect(Chunker.chunk("one\n  two\n\tthree", max: 420) == ["one two three"])
    }

    @Test("joins paragraphs up to the limit, then breaks")
    func paragraphs() {
        let a = String(repeating: "a", count: 200)
        let b = String(repeating: "b", count: 200)
        let c = String(repeating: "c", count: 200)
        let chunks = Chunker.chunk("\(a)\n\n\(b)\n\n\(c)", max: 420)
        #expect(chunks.count == 2)
        #expect(chunks[0] == "\(a) \(b)")
        #expect(chunks[1] == c)
    }

    @Test("breaks a long paragraph on sentence boundaries")
    func sentences() {
        let sentence = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces) + "."
        let chunks = Chunker.chunk("\(sentence) \(sentence) \(sentence)", max: 260)
        #expect(chunks.count >= 2)
        // Nothing overshoots, and nothing is lost.
        for chunk in chunks { #expect(chunk.count <= 260) }
        #expect(chunks.joined(separator: " ").filter { !$0.isWhitespace }.count
            == "\(sentence) \(sentence) \(sentence)".filter { !$0.isWhitespace }.count)
    }

    /// A "word" with nothing to break on — a URL, say — is the one case that
    /// still gets cut mid-token, because there is no alternative.
    @Test("splits a word longer than the limit")
    func longWord() {
        let url = String(repeating: "x", count: 900)
        let ceiling = Chunker.ceiling(for: 260)
        let chunks = Chunker.chunk(url, max: 260)
        #expect(chunks.count == 3)
        for chunk in chunks { #expect(chunk.count <= ceiling) }
        #expect(chunks.joined() == url, "and nothing is lost")
    }

    @Test("keeps a closing quote with the sentence it ends")
    func closingQuotes() {
        // The quote goes with `"Stop!"`, not with what follows. Dialogue and
        // its attribution end up as separate pieces, which is what the web
        // chunker does too — worth pinning down, since it is the one place the
        // two could plausibly drift.
        let split = Chunker.sentences(in: "\"Stop!\" she said. Then nothing.")
        #expect(split == ["\"Stop!\"", "she said.", "Then nothing."])
    }

    @Test("leads with a single sentence for a fast first chunk")
    func sentenceLead() {
        let first = "The first sentence is long enough to lead."
        let text = "\(first) " + String(repeating: "more words here. ", count: 30)
        let chunks = Chunker.chunkWithSentenceLead(text, max: 260)
        #expect(chunks[0] == first)
        #expect(chunks.count > 2)
    }

    /// A lead below `minimumLead` is an audible stub — "Mr." or "1." alone,
    /// then a quarter-second of silence — so the fast start is skipped.
    @Test("refuses a stub as the fast first chunk")
    func noTinyLead() {
        let text = "1. Introduction to the whole business of the harbour. "
            + String(repeating: "more words here. ", count: 30)
        let chunks = Chunker.chunkWithSentenceLead(text, max: 260)
        #expect(chunks[0].count >= Chunker.minimumLead)
    }

    @Test("drops empty input")
    func empty() {
        #expect(Chunker.chunk("   \n\n  ", max: 420).isEmpty)
    }
}

/// v5: a full stop is only a sentence boundary when it is one.
///
/// v4 split at every terminator, which *invented* boundaries inside "3.14",
/// "U.S.A." and a literal "..." — and because sentences are rejoined with a
/// single space, the text itself was corrupted: "3. 14" is read as "three.
/// fourteen". The round-trip tests above never saw it, because they compare
/// with whitespace stripped; these compare exactly.
struct SentenceBoundaryTests {
    @Test("a literal ellipsis is one boundary, not three")
    func literalEllipsis() {
        #expect(Chunker.sentences(in: "Wait... then he left.") == ["Wait...", "then he left."])
    }

    @Test("interrobangs stay together")
    func interrobang() {
        #expect(Chunker.sentences(in: "What?! Surely not.") == ["What?!", "Surely not."])
        #expect(Chunker.sentences(in: "No!? Very well.") == ["No!?", "Very well."])
    }

    @Test("a decimal point is not a boundary")
    func decimals() {
        #expect(Chunker.sentences(in: "Pi is 3.14 or so. Roughly.")
            == ["Pi is 3.14 or so.", "Roughly."])
        #expect(Chunker.sentences(in: "It cost $3.99 at the shop. A bargain.")
            == ["It cost $3.99 at the shop.", "A bargain."])
    }

    @Test("abbreviations and initials are not boundaries")
    func abbreviations() {
        #expect(Chunker.sentences(in: "Mr. Sherlock Holmes was late. As usual.")
            == ["Mr. Sherlock Holmes was late.", "As usual."])
        #expect(Chunker.sentences(in: "The U.S.A. is far away. Very far.")
            == ["The U.S.A. is far away.", "Very far."])
        #expect(Chunker.sentences(in: "J. K. Rowling wrote it. Apparently.")
            == ["J. K. Rowling wrote it.", "Apparently."])
        #expect(Chunker.sentences(in: "Compare, e.g. the harbour. Or not.")
            == ["Compare, e.g. the harbour.", "Or not."])
    }

    /// The corruption v4 caused: rejoined chunks must equal the flattened
    /// original *exactly*, whitespace included.
    @Test("chunking never adds or moves whitespace")
    func exactRoundTrip() {
        let texts = [
            "Wait... then he left. " + String(repeating: "The tide was low that day. ", count: 20),
            "Pi is 3.14, or 3.14159 if pressed. " + String(repeating: "More on that later. ", count: 20),
            "Mr. Holmes said U.S.A. twice. " + String(repeating: "Nobody counted. ", count: 25),
            "What?! " + String(repeating: "The gulls went about their work. ", count: 15),
        ]
        for text in texts {
            let rejoined = Chunker.chunk(text).joined(separator: " ")
            #expect(rejoined == Chunker.flatten(text), "whitespace mutated for \(text.prefix(30))…")
        }
    }

    /// Fragments of a split sentence carry the flags `PuncNorm` shapes them by.
    @Test("split-sentence pieces are marked as mid-sentence")
    func midSentenceFlags() {
        let sentence = (1...14)
            .map { "clause number \($0) running on with a good many words in it" }
            .joined(separator: ", ") + "."
        let chunks = Chunker.chunks(sentence)
        #expect(chunks.count > 1)
        #expect(!chunks[0].beginsMidSentence, "the first piece starts the sentence")
        #expect(chunks[0].endsMidSentence, "and hands it on")
        for chunk in chunks.dropFirst() {
            #expect(chunk.beginsMidSentence, "later pieces continue the sentence")
        }
        #expect(!chunks.last!.endsMidSentence, "the last piece finishes it")
    }

    @Test("whole sentences carry no mid-sentence flags")
    func wholeSentenceFlags() {
        for chunk in Chunker.chunks("One thing. Another thing entirely, but short.") {
            #expect(!chunk.beginsMidSentence)
            #expect(!chunk.endsMidSentence)
        }
    }
}

/// The promise the chunker now makes: **no chunk ends in the middle of a
/// sentence.**
///
/// Every chunk is followed by a quarter-second of silence, so a boundary is an
/// audible pause. Putting one inside a sentence is the defect these pin down —
/// it was audible on long sentences, which v1 broke at an arbitrary word
/// boundary once they passed 260 characters.
struct ChunkBoundaryTests {
    /// Did this piece of text stop somewhere a reader would stop?
    func endsCleanly(_ chunk: String) -> Bool {
        guard let last = chunk.last else { return false }
        // Sentence-ending punctuation, optionally behind a closing quote or
        // bracket, is a clean stop. So is a clause mark, which is only ever
        // reached by a sentence too long for the model to say in one go.
        let closers = CharacterSet(charactersIn: "\"'”’)]»")
        var trimmed = chunk
        while let last = trimmed.unicodeScalars.last, closers.contains(last) {
            trimmed = String(trimmed.dropLast())
        }
        guard let final = trimmed.last else { return false }
        return ".!?…;:,—–".contains(final)
    }

    /// Prose with sentences well past the old 260-character limit, which is
    /// where the cutting happened.
    let longSentences = """
        The harbour had been quiet for so long that the townspeople had come to \
        regard the silence as a kind of weather, something that arrived in the \
        evening and lifted, occasionally, when a boat came in with news from the \
        far side of the water. Nobody remembered when it had started. The oldest \
        of them, who had a habit of remembering things that had not happened, \
        claimed it went back to the year the lighthouse failed, and that the two \
        were connected in a way he could explain at length if anyone would sit \
        still for it, which by then nobody would.
        """

    @Test("no chunk ends mid-sentence")
    func neverBreaksASentence() {
        let chunks = Chunker.chunk(longSentences)
        #expect(chunks.count > 1, "this text is long enough to be split")
        for chunk in chunks {
            #expect(endsCleanly(chunk), "chunk ended mid-sentence: …\(chunk.suffix(45))")
        }
    }

    /// The specific regression: v1 broke this into two pieces at a word
    /// boundary, so the sentence was read with a pause in the middle.
    @Test("a sentence longer than the old limit is kept whole")
    func keepsLongSentencesIntact() {
        let sentence = """
            It was the kind of morning that made the whole business seem \
            reasonable, the light coming off the water in flat sheets and the \
            gulls going about their work with an air of purpose that nobody in \
            the town had managed in years, least of all the harbourmaster, who \
            had by then given up pretending to keep the register.
            """
        #expect(sentence.count > 260, "longer than v1 would tolerate")
        #expect(sentence.count <= Chunker.hardMaxChars, "but within what the model can say")
        #expect(Chunker.chunk(sentence) == [sentence])
    }

    /// The sentence from "The Five Orange Pips" that v3 cut at a comma,
    /// stranding "like untamed beasts in a cage" as a chunk of its own with a
    /// quarter-second of silence in front of it.
    @Test("a long literary sentence is read in one breath")
    func keepsAConanDoyleSentenceWhole() {
        let paragraph = """
            All day the wind had screamed and the rain had beaten against the \
            windows, so that even here in the heart of great, hand-made London we \
            were forced to raise our minds for the instant from the routine of \
            life and to recognise the presence of those great elemental forces \
            which shriek at mankind through the bars of his civilisation, like \
            untamed beasts in a cage.
            """
        #expect(paragraph.count > Chunker.defaultMaxChars, "longer than the packing target")
        #expect(Chunker.chunk(paragraph) == [paragraph], "and still said in one piece")
    }

    /// A sentence too long for the model to say at all still has to break, but
    /// at its own punctuation rather than between two arbitrary words.
    @Test("an enormous sentence breaks at its own punctuation")
    func splitsMonstrousSentencesAtClauses() {
        let sentence = (1...14)
            .map { "clause number \($0) running on with a good many words in it" }
            .joined(separator: ", ") + "."
        #expect(sentence.count > Chunker.hardMaxChars)

        let chunks = Chunker.chunk(sentence)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(endsCleanly(chunk), "broke mid-clause: …\(chunk.suffix(45))")
        }
        #expect(
            chunks.joined(separator: " ").filter { !$0.isWhitespace }
                == sentence.filter { !$0.isWhitespace },
            "and nothing is lost"
        )
    }

    /// The reason the ceiling is what it is.
    ///
    /// Generation stops after `SamplingOptions.maxTokens` and silently drops
    /// the rest of the sentence, so the ceiling has to sit below that even for
    /// a narrator who reads slowly. This is the only limit that loses words —
    /// the mel decoder's 768-token window costs a five-millisecond ramp, which
    /// is why chunks are allowed to exceed it.
    @Test("no chunk can outrun the generation budget")
    func staysWithinTheGenerationBudget() {
        // What the KV cache has left for speech once the voice conditioning
        // (376) and the text and its BOS are in it. A 500-character chunk is
        // roughly 125 BPE tokens of English.
        let budget = min(SamplingOptions().maxTokens, 1697 - 376 - 125 - 1)
        let seconds = Double(budget) / 25
        let slowestCharactersPerSecond = 12.0
        let safeCharacters = Int(seconds * slowestCharactersPerSecond)

        #expect(
            Chunker.hardMaxChars <= safeCharacters,
            """
            a \(Chunker.hardMaxChars)-character chunk can outrun a \(budget)-token \
            budget (\(safeCharacters) characters at \(slowestCharactersPerSecond)/s), \
            and the overrun is dropped without a word about it
            """
        )
    }

    /// The ceiling is the model's, not a preference.
    @Test("no chunk can overrun the model's speech budget")
    func staysWithinTheSpeechBudget() {
        let texts = [
            longSentences,
            String(repeating: "Short. ", count: 200),
            (1...20).map { "clause \($0) with several words" }.joined(separator: ", ") + ".",
            String(repeating: "x", count: 2000),
        ]
        for text in texts {
            for chunk in Chunker.chunk(text) {
                #expect(
                    chunk.count <= Chunker.hardMaxChars,
                    "a \(chunk.count)-character chunk risks being cut off mid-word"
                )
            }
        }
    }

    @Test("a paragraph that fits is one chunk")
    func paragraphsStayWhole() {
        let paragraph = "One sentence here. And a second one, slightly longer than the first."
        let chunks = Chunker.chunk("\(paragraph)\n\n\(String(repeating: "z", count: 390))")
        #expect(chunks.first == paragraph, "the paragraph was not carved up")
    }

    @Test("nothing is lost or duplicated")
    func preservesEveryWord() {
        let chunks = Chunker.chunk(longSentences)
        let rejoined = chunks.joined(separator: " ").filter { !$0.isWhitespace }
        let original = longSentences.filter { !$0.isWhitespace }
        #expect(rejoined == original)
    }

    /// The fast-start split has to obey the same rule: its lead is a whole
    /// sentence, not the first 200 characters.
    @Test("the fast first chunk is still a whole sentence")
    func sentenceLeadEndsCleanly() {
        let chunks = Chunker.chunkWithSentenceLead(longSentences)
        for chunk in chunks {
            #expect(endsCleanly(chunk), "lead split mid-sentence: …\(chunk.suffix(45))")
        }
    }
}
