import Foundation
import Testing

@testable import HuiverKit

/// Every expected id here came out of the Python tokenizer that Chatterbox
/// itself uses (see the generator in apps/ios/README.md). A mismatch means the
/// phone would speak different words from the desktop app, which is exactly the
/// sort of bug that is invisible until you listen to a whole chapter.
struct TokenizerTests {
    /// The tokenizer files are installed alongside the models, which are not in
    /// the repo. Skipping is right: the check is worth having when they are
    /// there and is not worth a 1 MB fixture when they are not.
    static var tokenizer: BPETokenizer? {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HuiverKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // huiverkit
        // Where `bun run ios:models` installs them, and an older local layout.
        for models in [
            package.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("apps/ios/Models"),
            package.appendingPathComponent("Models"),
        ] {
            if let tokenizer = try? BPETokenizer(directory: models) { return tokenizer }
        }
        return nil
    }

    static let cases: [(String, [Int])] = [
        ("The quiet harbour town woke slowly.", [464, 5897, 39720, 3240, 19092, 6364, 13]),
        (
            "She judged it a fair morning for the crossing, and said so.",
            [3347, 19589, 340, 257, 3148, 3329, 329, 262, 12538, 11, 290, 531, 523, 13]
        ),
        (
            "Mr. Sherlock Holmes, who was usually very late in the mornings,",
            [5246, 13, 25730, 17628, 11, 508, 373, 3221, 845, 2739, 287, 262, 31143, 11]
        ),
        (
            "A church bell rang - past the bridge - at 7,45.",
            [32, 4928, 8966, 28077, 532, 1613, 262, 7696, 532, 379, 767, 11, 2231, 13]
        ),
        ("Don't you think it's odd?", [3987, 470, 345, 892, 340, 338, 5629, 30]),
        // A style tag: one id, not five, and the text around it still splits
        // normally.
        ("[laugh] Well, quite.", [50275, 3894, 11, 2407, 13]),
        // Non-ASCII goes through the byte alphabet rather than an unknown token.
        ("Café naïve résumé 42 tokens.", [34, 1878, 2634, 41492, 40560, 16345, 2634, 5433, 16326, 13]),
    ]

    @Test("matches the Python tokenizer")
    func matchesPython() throws {
        guard let tokenizer = Self.tokenizer else {
            withKnownIssue("Models/ not installed; run scripts/install-models.sh") {
                Issue.record("skipped")
            }
            return
        }
        for (text, expected) in Self.cases {
            #expect(tokenizer.encode(text) == expected, "encoding \(text.debugDescription)")
        }
    }

    /// The chunker budgets in characters — `hardMaxChars` is 500, sized on the
    /// assumption that English runs about four characters per BPE token. The
    /// prefill model refuses anything over 320 text tokens, so the assumption
    /// has to hold with room to spare, and this checks it against the real
    /// tokenizer over deliberately awkward prose. (Text that still breaches it
    /// — non-Latin scripts, base64 — is re-split by the engine at synthesis
    /// time rather than trusted to this margin.)
    @Test("a full-size English chunk fits the prefill ceiling")
    func chunkFitsPrefill() throws {
        guard let tokenizer = Self.tokenizer else {
            withKnownIssue("Models/ not installed; run scripts/install-models.sh") {
                Issue.record("skipped")
            }
            return
        }
        let awkward = [
            // Quoted, dashed, numbered dialogue tokenizes worse than plain prose.
            String(repeating: #""Hm?!" — 12,5% of £3.99, per Dr. Quixote's 'zyzzyva' — "no". "#, count: 12),
            // Ordinary literary prose at full chunk size.
            String(repeating: "The harbourmaster, who had by then given up pretending to keep the register, said so. ", count: 8),
            // Rare vocabulary, which BPE breaks into many pieces.
            String(repeating: "Sesquipedalian obfuscation notwithstanding, borborygmus quixotically overwhelmed perspicacity. ", count: 7),
        ]
        for text in awkward {
            for chunk in Chunker.chunk(text) {
                let tokens = tokenizer.encode(PuncNorm.apply(chunk))
                #expect(
                    tokens.count <= 320,
                    "a \(chunk.count)-character chunk is \(tokens.count) tokens, over the prefill's 320"
                )
            }
        }
    }

    /// GPT-2's byte alphabet has to cover all 256 values and collide with none
    /// of them, or some byte sequences would encode to the same token.
    @Test("byte alphabet is a bijection")
    func byteAlphabet() {
        let map = BPETokenizer.byteEncoder()
        #expect(map.count == 256)
        #expect(Set(map.values).count == 256)
        #expect(map[UInt8(ascii: "A")] == "A")
        #expect(map[32] == "Ġ")  // space, lifted out of the control range
    }
}

struct PuncNormTests {
    @Test("matches chatterbox's punc_norm")
    func normalises() {
        #expect(PuncNorm.apply("she judged it") == "She judged it.")
        #expect(PuncNorm.apply("a  b   c") == "A b c.")
        // An ellipsis becomes a comma, which already counts as an ending, so no
        // full stop is added on top of it.
        #expect(PuncNorm.apply("wait…") == "Wait,")
        #expect(PuncNorm.apply("time: now") == "Time, now.")
        #expect(PuncNorm.apply("dash — here") == "Dash - here.")
        #expect(PuncNorm.apply("“quoted”") == "\"quoted\".")
        // Already ends in punctuation, so nothing is added.
        #expect(PuncNorm.apply("Done!") == "Done!")
        #expect(PuncNorm.apply("") == "You need to add some text for me to talk.")
    }

    /// Fragments of a sentence too long to say in one go must not be shaped
    /// as whole sentences: no capital cueing sentence-opening prosody, and a
    /// comma rather than a full stop when the sentence carries on.
    @Test("mid-sentence fragments keep their shape")
    func midSentenceFragments() {
        #expect(
            PuncNorm.apply("like untamed beasts in a cage", beginsMidSentence: true)
                == "like untamed beasts in a cage."
        )
        #expect(
            PuncNorm.apply("All day the wind had screamed", endsMidSentence: true)
                == "All day the wind had screamed,"
        )
        #expect(
            PuncNorm.apply("and to recognise those forces", beginsMidSentence: true, endsMidSentence: true)
                == "and to recognise those forces,"
        )
        // The one clause mark the replacements leave alone becomes the comma
        // it prosodically is, rather than picking up a stray full stop.
        #expect(
            PuncNorm.apply("the register was kept;", endsMidSentence: true)
                == "The register was kept,"
        )
        // A fragment already ending on an ender is left alone.
        #expect(
            PuncNorm.apply("it screamed,", beginsMidSentence: true, endsMidSentence: true)
                == "it screamed,"
        )
    }
}
