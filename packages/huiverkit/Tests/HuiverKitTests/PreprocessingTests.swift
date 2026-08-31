import CryptoKit
import Foundation
import Testing

@testable import HuiverKit

struct PreprocessingTests {
    private func context(
        language: String = "en", locale: String = "en-US",
        overrides: [PronunciationOverride] = []
    ) -> ProcessingContext {
        .init(
            language: .named(language), locale: LocaleProfile(locale),
            contentId: "book", overrides: overrides
        )
    }

    @Test("English normalization keeps display text and expands safe speech forms")
    func englishNormalization() async {
        let source = "Dr. Smith paid £12.50 at 14:30, a 25% discount on his 3rd FBI badge."
        let result = await EnglishProcessor().process(
            chunk: .init(text: source, beginsMidSentence: false, endsMidSentence: false),
            context: context(locale: "en-GB")
        )
        #expect(result.displayText == source)
        #expect(result.spokenText.contains("Doctor Smith"))
        #expect(result.spokenText.contains("pounds"))
        #expect(result.spokenText.contains("percent"))
        #expect(result.spokenText.contains("third"))
        #expect(result.spokenText.contains("F B I"))
        #expect(!result.fingerprint.isEmpty)
    }

    @Test("Dutch normalization uses Dutch spell-out and letter names")
    func dutchNormalization() async {
        let override = PronunciationOverride(
            languageCode: "nl", bookContentId: "book", matchText: "SQL",
            mode: .spellLetters, matchCase: .sensitive
        )
        let result = await DutchProcessor().process(
            chunk: .init(text: "Dhr. Vos noemt SQL en 25%.", beginsMidSentence: false, endsMidSentence: false),
            context: context(language: "nl", locale: "nl-NL", overrides: [override])
        )
        #expect(result.spokenText.contains("de heer Vos"))
        #expect(result.spokenText.contains("es kuu el"))
        #expect(result.spokenText.contains("procent"))
    }

    @Test("Dotted acronyms are spelled as letters, spaced initials are not")
    func dottedAcronyms() async {
        let source = "The U.S. and the U.N. asked J. K. Rowling about the U.S.A. in the UK."
        let result = await EnglishProcessor().process(
            chunk: .init(text: source, beginsMidSentence: false, endsMidSentence: false),
            context: context()
        )
        #expect(result.spokenText.contains("The U S and the U N"))
        #expect(result.spokenText.contains("J. K. Rowling"))
        #expect(result.spokenText.contains("the U S A in the U K."))
    }

    @Test("Dotted acronyms use Dutch letter names in Dutch books")
    func dutchDottedAcronyms() async {
        let result = await DutchProcessor().process(
            chunk: .init(text: "De V.S. en de V.N. overleggen, d.w.z. morgen.", beginsMidSentence: false, endsMidSentence: false),
            context: context(language: "nl", locale: "nl-NL")
        )
        #expect(result.spokenText.contains("De vee es en de vee en"))
        #expect(result.spokenText.contains("dat wil zeggen"))
    }

    @Test("Latin abbreviations get spoken English expansions")
    func latinAbbreviations() async {
        let result = await EnglishProcessor().process(
            chunk: .init(text: "Fruit, e.g. apples, i.e. not meat, etc.", beginsMidSentence: false, endsMidSentence: false),
            context: context()
        )
        #expect(result.spokenText.contains("for example, apples"))
        #expect(result.spokenText.contains("that is, not meat"))
        #expect(result.spokenText.contains("et cetera"))

        // A comma already in the source is consumed, never doubled.
        let commas = await EnglishProcessor().process(
            chunk: .init(text: "Fruit, e.g., apples.", beginsMidSentence: false, endsMidSentence: false),
            context: context()
        )
        #expect(commas.spokenText.contains("for example, apples"))
        #expect(!commas.spokenText.contains(",,"))
    }

    @Test("Ordinals above twenty are spelled out correctly")
    func largeOrdinals() async {
        let result = await EnglishProcessor().process(
            chunk: .init(
                text: "Her 21st birthday, his 32nd, their 30th, the 100th anniversary.",
                beginsMidSentence: false, endsMidSentence: false
            ),
            context: context()
        )
        #expect(result.spokenText.contains("twenty-first"))
        #expect(result.spokenText.contains("thirty-second"))
        #expect(result.spokenText.contains("thirtieth"))
        #expect(result.spokenText.contains("one hundredth"))
    }

    @Test("Numeric dates with a four-digit year are spoken in locale order")
    func dates() async {
        let us = await EnglishProcessor().process(
            chunk: .init(
                text: "Born on 12/03/1999; the deadline is 2026-08-30.",
                beginsMidSentence: false, endsMidSentence: false
            ),
            context: context(locale: "en-US")
        )
        #expect(us.spokenText.contains("December third, nineteen ninety-nine"))
        #expect(us.spokenText.contains("August thirtieth, twenty twenty-six"))

        let gb = await EnglishProcessor().process(
            chunk: .init(text: "Born on 12/03/1999.", beginsMidSentence: false, endsMidSentence: false),
            context: context(locale: "en-GB")
        )
        #expect(gb.spokenText.contains("the twelfth of March, nineteen ninety-nine"))

        let nl = await DutchProcessor().process(
            chunk: .init(text: "Geboren op 12-03-1999.", beginsMidSentence: false, endsMidSentence: false),
            context: context(language: "nl", locale: "nl-NL")
        )
        #expect(nl.spokenText.contains("twaalf maart negentienhonderd negenennegentig"))
    }

    @Test("Money with grouped thousands and cents reads as money")
    func money() async {
        let result = await EnglishProcessor().process(
            chunk: .init(
                text: "He wired €1,250.50, kept $1 and found £0.75.",
                beginsMidSentence: false, endsMidSentence: false
            ),
            context: context()
        )
        #expect(result.spokenText.contains("one thousand two hundred fifty euros and fifty cents"))
        #expect(result.spokenText.contains("one dollar"))
        #expect(result.spokenText.contains("seventy-five pence"))
    }

    @Test("A user correction beats the built-in dotted acronym rule")
    func overrideBeatsDottedRule() async {
        let override = PronunciationOverride(
            languageCode: "en", bookContentId: "book", matchText: "U.S.",
            replacement: "United States", matchCase: .sensitive
        )
        let result = await EnglishProcessor().process(
            chunk: .init(text: "Life in the U.S. today.", beginsMidSentence: false, endsMidSentence: false),
            context: context(overrides: [override])
        )
        #expect(result.spokenText == "Life in the United States today.")
    }

    @Test("Book correction wins over global and cannot be recursively normalized")
    func overridePrecedence() async {
        let global = PronunciationOverride(
            languageCode: "en", matchText: "Sjoerd", replacement: "global",
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let book = PronunciationOverride(
            languageCode: "en", bookContentId: "book", matchText: "Sjoerd",
            replacement: "Dr. Twelve", updatedAt: Date(timeIntervalSince1970: 1)
        )
        let result = await EnglishProcessor().process(
            chunk: .init(text: "Sjoerd's book.", beginsMidSentence: false, endsMidSentence: false),
            context: context(overrides: [global, book])
        )
        #expect(result.spokenText == "Dr. Twelve's book.")
    }

    @Test("Ambiguous and technical terms are surfaced with a stable ten-item cap")
    func candidateRanking() async {
        let terms = ["SQL", "1/2/2026", "Widget9000", "Sjoerd", "HyperLongFiction", "ABC", "XYZ", "QRS", "TUV", "LMN", "PQR", "RST"]
        let text = terms.map { "We discussed \($0) twice: \($0)." }.joined(separator: " ")
            + String(repeating: " The stranger Zyxwverian arrived.", count: 8)
        let book = Book(
            id: "local", title: "Challenge", added: Date(), language: "en",
            localeIdentifier: "en-GB", chapters: [Chapter(id: "c", title: "One", text: text)],
            contentId: "book"
        )
        let report = await EnglishProcessor().analyze(
            book: book, context: .init(processing: context(locale: "en-GB"))
        )
        #expect(report.candidates.count == 10)
        #expect(report.candidates.contains { $0.surfaceForms.contains("SQL") })
        // Full dates are spoken deterministically now — nothing to review.
        #expect(!report.candidates.contains { $0.surfaceForms.contains("1/2/2026") })
        // A name mentioned twice is not worth a review row; one that recurs is.
        #expect(!report.candidates.contains { $0.surfaceForms.contains("Sjoerd") })
        #expect(report.candidates.contains { $0.surfaceForms.contains("Zyxwverian") })
        #expect(zip(report.candidates, report.candidates.dropFirst()).allSatisfy {
            $0.riskScore >= $1.riskScore
        })
        let repeated = await EnglishProcessor().analyze(
            book: book, context: .init(processing: context(locale: "en-GB"))
        )
        #expect(report.candidates == repeated.candidates)
    }

    @Test("Locale profiles and fallback processor are deterministic")
    func localeAndFallback() async {
        #expect(LocaleProfile("nl_BE").identifier == "nl-BE")
        #expect(LocaleProfile.defaultIdentifier(for: "en") == "en-US")
        let chunk = Chunker.Chunk(text: "Texto 42.", beginsMidSentence: false, endsMidSentence: false)
        let result = await FallbackProcessor(languageCode: "es").process(
            chunk: chunk, context: context(language: "es", locale: "es-ES")
        )
        #expect(result.spokenText == chunk.text)
    }

    @Test("eSpeak calls go through the serialized backend boundary")
    func espeakBoundary() async throws {
        let backend = EspeakBackend { text, language in "\(language):\(text.lowercased())" }
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for word in ["One", "Two", "Three"] {
                group.addTask { try await backend.phonemes(for: word, languageCode: "EN") }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(values) == ["en:one", "en:two", "en:three"])
    }
}

struct LanguagePackTests {
    @Test("installs a fully signed data-only pack and activates it")
    func signedInstall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let privateKey = Curve25519.Signing.PrivateKey()
        let keyId = "test-2026"
        let licenses = try canonicalJSON([LanguagePackLicense(
            component: "gruut-lang-en", version: "2.0.1", sourceURL: "https://example.invalid",
            license: "MIT", attribution: "Test fixture", sourceHash: String(repeating: "a", count: 64)
        )])
        let rules = Data("{}".utf8)
        let files = [
            "LICENSES.json": hash(licenses),
            "rules.json": hash(rules),
        ]
        let unsigned = LanguagePackManifest(
            languageCode: "en", version: "1.0.0", backendIdentifier: "english-v1",
            localeProfiles: ["en-US", "en-GB"], files: files, keyId: keyId
        )
        let signature = try privateKey.signature(for: canonicalJSON(unsigned)).base64EncodedString()
        let signed = LanguagePackManifest(
            languageCode: "en", version: "1.0.0", backendIdentifier: "english-v1",
            localeProfiles: ["en-US", "en-GB"], files: files, keyId: keyId, signature: signature
        )
        let archive = ZipWriter.archive([
            ("manifest.json", String(decoding: try canonicalJSON(signed), as: UTF8.self)),
            ("LICENSES.json", String(decoding: licenses, as: UTF8.self)),
            ("rules.json", "{}"),
        ])
        let manager = try LanguagePackManager(
            root: root, trustedPublicKeys: [keyId: privateKey.publicKey.rawRepresentation]
        )
        let installed = try await manager.install(archive: archive)
        #expect(installed.active)
        #expect(installed.languageCode == "en")
        #expect(try await manager.installed().count == 1)
    }

    @Test("rejects traversal before writing any archive member")
    func traversal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try LanguagePackManager(root: root, trustedPublicKeys: [:])
        let archive = ZipWriter.archive([("../manifest.json", "{}")])
        await #expect(throws: LanguagePackManager.PackError.self) {
            try await manager.install(archive: archive)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
