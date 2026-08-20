import Foundation
import Testing

@testable import HuiverKit

/// The multilingual tokenizer, against the Python original.
///
/// Every case in the fixture is `(text, language, ids)` recorded from
/// chatterbox's own `MTLTokenizer` by `tools/export/mtl_tokenizer_fixture.py`.
/// A port of a HuggingFace pipeline is only as good as its output, so that is
/// what is compared — not the stages.
struct MTLTokenizerTests {
    struct Fixture: Decodable {
        struct Case: Decodable {
            let text: String
            let language: String
            let ids: [Int32]
        }
        let cases: [Case]
    }

    /// The checkpoint's tokenizer file, wherever it is on this machine.
    static var directory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hub = home.appendingPathComponent(
            ".cache/huggingface/hub/models--ResembleAI--chatterbox/snapshots", isDirectory: true
        )
        guard let snapshots = try? FileManager.default.contentsOfDirectory(
            at: hub, includingPropertiesForKeys: nil
        ) else { return nil }
        return snapshots.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent(MTLTokenizer.filename).path
            )
        }
    }

    func fixture() throws -> Fixture {
        let url = try #require(
            Bundle.module.url(forResource: "mtl-tokenizer", withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "mtl-tokenizer", withExtension: "json")
        )
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    @Test("every fixture case tokenizes exactly as the original does")
    func matchesPython() throws {
        guard let directory = Self.directory else {
            // The multilingual checkpoint is a 3 GB download; a machine without
            // it should skip rather than fail.
            print("skipping: no multilingual checkpoint in the Hugging Face cache")
            return
        }
        let tokenizer = try MTLTokenizer(directory: directory)
        for item in try fixture().cases {
            let got = tokenizer.encode(item.text, language: item.language)
            #expect(
                got == item.ids,
                "\(item.language) \"\(item.text)\"\n  got  \(got)\n  want \(item.ids)"
            )
        }
    }

    @Test("the languages needing an unported normaliser are refused")
    func refusesUnnormalisedLanguages() throws {
        guard let directory = Self.directory else { return }
        let tokenizer = try MTLTokenizer(directory: directory)
        for code in ["zh", "ja", "he", "ko", "ru"] {
            #expect(!tokenizer.canRead(code), "\(code) needs a normaliser this port lacks")
        }
        for code in ["en", "nl", "de", "fr", "es", "it", "pt", "sv", "da", "no", "fi", "pl", "tr"] {
            #expect(tokenizer.canRead(code))
        }
        #expect(!tokenizer.canRead("xx"), "a language the vocabulary has no tag for")
    }

    @Test("the language list is what the app can offer")
    func languageList() throws {
        guard let directory = Self.directory else { return }
        let tokenizer = try MTLTokenizer(directory: directory)
        #expect(tokenizer.languages.contains("nl"))
        #expect(tokenizer.languages.contains("en"))
        #expect(!tokenizer.languages.contains("zh"))
    }
}
