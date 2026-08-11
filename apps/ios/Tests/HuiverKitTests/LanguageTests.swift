import Foundation
import Testing

@testable import HuiverKit

struct LanguageTests {
    @Test("covers Chatterbox's 23 languages")
    func roster() {
        // The list in chatterbox/mtl_tts.py. Dutch is in it, which is the whole
        // reason this file exists — but see ChatterboxEngine.languages: being on
        // this list is not the same as Nano being able to read it.
        #expect(Language.all.count == 23)
        #expect(Language.all.map(\.code).contains("nl"))
        #expect(Set(Language.all.map(\.code)).count == 23)
    }

    @Test("unknown codes fall back to English rather than failing")
    func fallback() {
        #expect(Language.named("nl").name == "Dutch")
        #expect(Language.named("NL").code == "nl")
        #expect(Language.named("klingon").code == "en")
    }

    @Test("recognises Dutch")
    func detectsDutch() {
        let dutch = """
            Het was een koude, grijze ochtend toen de boten de haven verlieten. \
            De meeuwen draaiden boven de pier en de kerkklok sloeg zeven uur. \
            Zij vond het een goede morgen voor de oversteek, en dat zei ze ook. \
            De mannen keken naar het water en zwegen, want er was niets meer \
            te zeggen over de reis die voor hen lag.
            """
        #expect(Language.detect(in: dutch).code == "nl")
    }

    @Test("recognises English")
    func detectsEnglish() {
        let english = """
            The quiet harbour town woke slowly. Gulls turned above the jetty, \
            a church bell rang past the bridge, and the first boats pushed out \
            through thin grey water. She judged it a fair morning for the \
            crossing, and said so. The men watched the water and said nothing.
            """
        #expect(Language.detect(in: english).code == "en")
    }

    @Test("falls back to English on text it cannot place")
    func detectsNothing() {
        #expect(Language.detect(in: "").code == "en")
        #expect(Language.detect(in: "1 2 3 4 5").code == "en")
    }

    @Test("a book keeps its language, and older libraries default to English")
    func bookCoding() throws {
        // A library written before languages existed has no `language` key.
        let old = """
            [{"id":"b1","title":"Old","added":0,"chapters":[]}]
            """
        let books = try JSONDecoder().decode([Book].self, from: Data(old.utf8))
        #expect(books[0].languageCode == "en")

        var book = books[0]
        book.language = "nl"
        let round = try JSONDecoder().decode(
            [Book].self, from: try JSONEncoder().encode([book])
        )
        #expect(round[0].languageCode == "nl")
    }
}
