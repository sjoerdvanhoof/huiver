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
        #expect(report.candidates.contains { $0.surfaceForms.contains("1/2/2026") })
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
