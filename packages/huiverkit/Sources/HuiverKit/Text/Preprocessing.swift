import CryptoKit
import Foundation
import NaturalLanguage

// MARK: - Locale and language processors

public struct LocaleProfile: Codable, Sendable, Hashable, Identifiable {
    public let identifier: String
    public var id: String { identifier }
    public var languageCode: String {
        identifier.split(separator: "-").first.map(String.init)?.lowercased() ?? "en"
    }

    public init(_ identifier: String) {
        self.identifier = Self.canonicalIdentifier(identifier)
            ?? Self.defaultIdentifier(for: identifier)
    }

    public static func canonicalIdentifier(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !trimmed.isEmpty else { return nil }
        let canonical = Locale.canonicalIdentifier(from: trimmed)
            .replacingOccurrences(of: "_", with: "-")
        let language = canonical.split(separator: "-").first.map(String.init)?.lowercased()
        guard let language, Language.all.contains(where: { $0.code == language }) else { return nil }
        return canonical
    }

    public static func defaultIdentifier(for languageCode: String) -> String {
        switch languageCode.lowercased() {
        case "nl": "nl-NL"
        case "en": "en-US"
        default: languageCode.lowercased()
        }
    }
}

public struct ChunkingProfile: Codable, Sendable, Hashable {
    public let id: String
    public let abbreviations: Set<String>

    public init(id: String, abbreviations: Set<String>) {
        self.id = id
        self.abbreviations = abbreviations
    }
}

public struct LanguageProcessorDescriptor: Codable, Sendable, Hashable {
    public let languageCode: String
    public let backend: String
    public let version: String
    public let locales: [String]

    public init(languageCode: String, backend: String, version: String, locales: [String]) {
        self.languageCode = languageCode
        self.backend = backend
        self.version = version
        self.locales = locales
    }
}

public struct TextSubstitution: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case userOverride, alias, number, date, time, currency }
    public let source: String
    public let replacement: String
    public let kind: Kind
}

public struct ProcessedChunk: Codable, Sendable, Equatable {
    public let displayText: String
    public let spokenText: String
    public let substitutions: [TextSubstitution]
    public let fingerprint: String
}

public struct ProcessingContext: Sendable {
    public let language: Language
    public let locale: LocaleProfile
    public let contentId: String
    public let overrides: [PronunciationOverride]

    public init(
        language: Language, locale: LocaleProfile, contentId: String,
        overrides: [PronunciationOverride]
    ) {
        self.language = language
        self.locale = locale
        self.contentId = contentId
        self.overrides = overrides
    }
}

public struct AnalysisContext: Sendable {
    public let processing: ProcessingContext
    public init(processing: ProcessingContext) { self.processing = processing }
}

public protocol LanguageProcessor: Sendable {
    var descriptor: LanguageProcessorDescriptor { get }
    func chunkingProfile(locale: LocaleProfile) -> ChunkingProfile
    func prepare(_ chunk: Chunker.Chunk, context: ProcessingContext) async -> ProcessedChunk
    func analyze(book: Book, context: AnalysisContext) async -> PreflightReport
}

public extension LanguageProcessor {
    /// Compatibility spelling for call sites that treat preparation as a
    /// transformation operation.
    func process(chunk: Chunker.Chunk, context: ProcessingContext) async -> ProcessedChunk {
        await prepare(chunk, context: context)
    }
}

public enum LanguageProcessorRegistry {
    public static func processor(for languageCode: String) -> any LanguageProcessor {
        switch languageCode.lowercased() {
        case "en": EnglishProcessor()
        case "nl": DutchProcessor()
        default: FallbackProcessor(languageCode: languageCode)
        }
    }
}

// MARK: - Overrides and decisions

public struct PronunciationOverride: Codable, Sendable, Hashable, Identifiable {
    public enum Mode: String, Codable, Sendable { case sayAs, spellLetters }
    public enum MatchCase: String, Codable, Sendable { case sensitive, insensitive }

    public let id: UUID
    public var languageCode: String
    public var bookContentId: String?
    public var matchText: String
    public var replacement: String
    public var mode: Mode
    public var matchCase: MatchCase
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var updatedByDevice: String

    public init(
        id: UUID = UUID(), languageCode: String, bookContentId: String? = nil,
        matchText: String, replacement: String = "", mode: Mode = .sayAs,
        matchCase: MatchCase = .insensitive, createdAt: Date = Date(),
        updatedAt: Date = Date(), deletedAt: Date? = nil, updatedByDevice: String = "local"
    ) {
        self.id = id
        self.languageCode = languageCode.lowercased()
        self.bookContentId = bookContentId
        self.matchText = matchText.precomposedStringWithCanonicalMapping
        self.replacement = replacement.precomposedStringWithCanonicalMapping
        self.mode = mode
        self.matchCase = matchCase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.updatedByDevice = updatedByDevice
    }

    public var isValid: Bool {
        let words = matchText.split(whereSeparator: \.isWhitespace)
        guard (1...5).contains(words.count), !matchText.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { return false }
        if mode == .sayAs {
            return !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !replacement.contains("<") && !replacement.contains(">")
        }
        return true
    }
}

public struct PronunciationDecision: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var contentId: String
    public var candidateId: String
    public var updatedAt: Date
    public var updatedByDevice: String

    public init(contentId: String, candidateId: String, updatedAt: Date = Date(), updatedByDevice: String = "local") {
        self.contentId = contentId
        self.candidateId = candidateId
        self.updatedAt = updatedAt
        self.updatedByDevice = updatedByDevice
        self.id = "\(contentId)/\(candidateId)"
    }
}

public struct PronunciationSnapshot: Codable, Sendable, Equatable {
    public var overrides: [PronunciationOverride]
    public var ignored: [PronunciationDecision]
    public var reviewedFingerprints: [String: String]

    public init(
        overrides: [PronunciationOverride] = [], ignored: [PronunciationDecision] = [],
        reviewedFingerprints: [String: String] = [:]
    ) {
        self.overrides = overrides
        self.ignored = ignored
        self.reviewedFingerprints = reviewedFingerprints
    }
}

public actor PronunciationStore {
    public static let shared = PronunciationStore()

    private var url: URL?
    private var snapshot = PronunciationSnapshot()

    public func configure(root: URL) {
        let target = root.appendingPathComponent("pronunciations.json")
        guard url != target else { return }
        url = target
        if let data = try? Data(contentsOf: target),
           let decoded = try? JSONDecoder().decode(PronunciationSnapshot.self, from: data) {
            snapshot = decoded
        }
    }

    public func all() -> PronunciationSnapshot { snapshot }

    public func effective(language: String, contentId: String) -> [PronunciationOverride] {
        snapshot.overrides.filter {
            $0.languageCode == language.lowercased() && $0.deletedAt == nil
                && ($0.bookContentId == nil || $0.bookContentId == contentId) && $0.isValid
        }
    }

    public func upsert(_ value: PronunciationOverride) throws {
        guard value.isValid else { throw StoreError.invalidOverride }
        if let index = snapshot.overrides.firstIndex(where: { $0.id == value.id }) {
            snapshot.overrides[index] = value
        } else {
            snapshot.overrides.append(value)
        }
        try save()
    }

    public func ignore(_ decision: PronunciationDecision) throws {
        if let index = snapshot.ignored.firstIndex(where: { $0.id == decision.id }) {
            snapshot.ignored[index] = decision
        } else {
            snapshot.ignored.append(decision)
        }
        try save()
    }

    public func markReviewed(contentId: String, fingerprint: String) throws {
        snapshot.reviewedFingerprints[contentId] = fingerprint
        try save()
    }

    public func isIgnored(contentId: String, candidateId: String) -> Bool {
        snapshot.ignored.contains { $0.contentId == contentId && $0.candidateId == candidateId }
    }

    public func merge(_ incoming: PronunciationSnapshot) throws {
        for item in incoming.overrides {
            guard let local = snapshot.overrides.first(where: { $0.id == item.id }) else {
                snapshot.overrides.append(item); continue
            }
            if Self.newer(item.updatedAt, item.updatedByDevice, than: local.updatedAt, local.updatedByDevice),
               let index = snapshot.overrides.firstIndex(where: { $0.id == item.id }) {
                snapshot.overrides[index] = item
            }
        }
        for item in incoming.ignored {
            guard let local = snapshot.ignored.first(where: { $0.id == item.id }) else {
                snapshot.ignored.append(item); continue
            }
            if Self.newer(item.updatedAt, item.updatedByDevice, than: local.updatedAt, local.updatedByDevice),
               let index = snapshot.ignored.firstIndex(where: { $0.id == item.id }) {
                snapshot.ignored[index] = item
            }
        }
        for (book, fingerprint) in incoming.reviewedFingerprints {
            if snapshot.reviewedFingerprints[book] == nil { snapshot.reviewedFingerprints[book] = fingerprint }
        }
        try save()
    }

    private static func newer(_ date: Date, _ device: String, than other: Date, _ otherDevice: String) -> Bool {
        date > other || (date == other && device > otherDevice)
    }

    private func save() throws {
        guard let url else { return }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public enum StoreError: LocalizedError {
        case invalidOverride
        public var errorDescription: String? { "Pronunciation corrections need one to five match words and safe spoken text." }
    }
}

// MARK: - Analysis

public struct PronunciationCandidate: Codable, Sendable, Hashable, Identifiable {
    public enum Category: String, Codable, Sendable { case name, acronym, ambiguous, technical, unusual }
    public let id: String
    public let surfaceForms: [String]
    public let category: Category
    public let reasons: [String]
    public let occurrenceCount: Int
    public let chapterCount: Int
    public let representativeSentence: String
    public let riskScore: Double
}

public struct PreflightReport: Codable, Sendable, Equatable {
    public let fingerprint: String
    public let candidates: [PronunciationCandidate]
    public let analysisDuration: Double
    public let packVersion: String
}

public actor PreflightStore {
    public static let shared = PreflightStore()
    private var root: URL?

    public func configure(root: URL) {
        let directory = root.appendingPathComponent("Preflight", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.root = directory
    }

    public func report(contentId: String) -> PreflightReport? {
        guard let root else { return nil }
        let url = root.appendingPathComponent(Self.filename(contentId))
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PreflightReport.self, from: $0) }
    }

    public func store(_ report: PreflightReport, contentId: String) {
        guard let root, let data = try? JSONEncoder().encode(report) else { return }
        try? data.write(to: root.appendingPathComponent(Self.filename(contentId)), options: .atomic)
    }

    private static func filename(_ id: String) -> String {
        Data(SHA256.hash(data: Data(id.utf8))).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_") + ".json"
    }
}

// MARK: - Built-in English and Dutch processors

public struct EnglishProcessor: LanguageProcessor {
    public let descriptor = LanguageProcessorDescriptor(
        languageCode: "en", backend: "foundation+rules", version: "1.2.0",
        locales: ["en-US", "en-GB"]
    )

    public init() {}

    public func chunkingProfile(locale: LocaleProfile) -> ChunkingProfile {
        ChunkingProfile(id: "en-1", abbreviations: Self.abbreviations)
    }

    public func prepare(_ chunk: Chunker.Chunk, context: ProcessingContext) async -> ProcessedChunk {
        ProcessorRules.process(chunk: chunk, context: context, descriptor: descriptor, rules: .english)
    }

    public func analyze(book: Book, context: AnalysisContext) async -> PreflightReport {
        await CandidateAnalyzer.analyze(book: book, context: context, descriptor: descriptor, rules: .english)
    }

    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "rev", "sr", "jr", "vs", "etc", "cf", "ca", "vol"
    ]
}

public struct DutchProcessor: LanguageProcessor {
    public let descriptor = LanguageProcessorDescriptor(
        languageCode: "nl", backend: "foundation+rules", version: "1.2.0",
        locales: ["nl-NL", "nl-BE"]
    )

    public init() {}

    public func chunkingProfile(locale: LocaleProfile) -> ChunkingProfile {
        ChunkingProfile(id: "nl-1", abbreviations: [
            "dhr", "mevr", "dr", "prof", "ds", "mr", "mw", "bijv", "enz", "etc", "nr", "ca"
        ])
    }

    public func prepare(_ chunk: Chunker.Chunk, context: ProcessingContext) async -> ProcessedChunk {
        ProcessorRules.process(chunk: chunk, context: context, descriptor: descriptor, rules: .dutch)
    }

    public func analyze(book: Book, context: AnalysisContext) async -> PreflightReport {
        await CandidateAnalyzer.analyze(book: book, context: context, descriptor: descriptor, rules: .dutch)
    }
}

public struct FallbackProcessor: LanguageProcessor {
    public let descriptor: LanguageProcessorDescriptor
    public init(languageCode: String) {
        descriptor = LanguageProcessorDescriptor(
            languageCode: languageCode, backend: "unchanged", version: "1", locales: [languageCode]
        )
    }
    public func chunkingProfile(locale: LocaleProfile) -> ChunkingProfile {
        ChunkingProfile(id: "fallback-1", abbreviations: EnglishProcessor.abbreviations)
    }
    public func prepare(_ chunk: Chunker.Chunk, context: ProcessingContext) async -> ProcessedChunk {
        ProcessorRules.result(chunk.text, spoken: chunk.text, substitutions: [], context: context, descriptor: descriptor)
    }
    public func analyze(book: Book, context: AnalysisContext) async -> PreflightReport {
        PreflightReport(
            fingerprint: ProcessorRules.hash("\(book.contentId ?? book.derivedContentId)|fallback"),
            candidates: [], analysisDuration: 0, packVersion: descriptor.version
        )
    }
}

public enum TextPreprocessing {
    public static func process(_ chunk: Chunker.Chunk, book: Book) async -> ProcessedChunk {
        let contentId = book.contentId ?? book.derivedContentId
        let overrides = await PronunciationStore.shared.effective(
            language: book.languageCode, contentId: contentId
        )
        let context = ProcessingContext(
            language: .named(book.languageCode), locale: LocaleProfile(book.spokenLocaleIdentifier),
            contentId: contentId, overrides: overrides
        )
        return await LanguageProcessorRegistry.processor(for: book.languageCode)
            .process(chunk: chunk, context: context)
    }

    public static func analyze(_ book: Book) async -> PreflightReport {
        let contentId = book.contentId ?? book.derivedContentId
        let overrides = await PronunciationStore.shared.effective(
            language: book.languageCode, contentId: contentId
        )
        let processing = ProcessingContext(
            language: .named(book.languageCode), locale: LocaleProfile(book.spokenLocaleIdentifier),
            contentId: contentId, overrides: overrides
        )
        return await LanguageProcessorRegistry.processor(for: book.languageCode)
            .analyze(book: book, context: AnalysisContext(processing: processing))
    }
}

// MARK: - Deterministic transformations

private struct ProcessorRules: Sendable {
    enum Flavor: Sendable { case english, dutch }
    let flavor: Flavor
    let aliases: [String: String]
    let initialisms: [String: String]
    let ambiguous: Set<String>

    static let english = ProcessorRules(
        flavor: .english,
        aliases: [
            "Dr": "Doctor", "Mr": "Mister", "Mrs": "Missus", "Ms": "Miz", "Prof": "Professor",
            "e.g": "for example,", "i.e": "that is,", "etc": "et cetera", "vs": "versus",
            "Ph.D": "P H D",
        ],
        initialisms: [
            "FBI": "F B I", "CIA": "C I A", "BBC": "B B C", "USA": "U S A", "NASA": "NASA",
            "US": "U S", "UN": "U N", "UK": "U K", "EU": "E U", "USSR": "U S S R",
            "CEO": "C E O", "TV": "T V", "DNA": "D N A", "AI": "A I", "PhD": "P H D",
        ],
        ambiguous: ["sql", "st", "read", "lead", "wind", "live"]
    )
    static let dutch = ProcessorRules(
        flavor: .dutch,
        aliases: [
            "dhr": "de heer", "mevr": "mevrouw", "mw": "mevrouw", "dr": "doctor",
            "prof": "professor", "nr": "nummer", "bijv": "bijvoorbeeld", "enz": "enzovoort",
            "o.a": "onder andere", "d.w.z": "dat wil zeggen,", "m.a.w": "met andere woorden,",
            "e.d": "en dergelijke", "t/m": "tot en met",
        ],
        initialisms: [
            "EU": "E U", "VN": "V N", "VS": "V S", "NAVO": "NAVO",
            "tv": "tee vee", "cd": "see dee", "dvd": "dee vee dee", "wc": "wee see",
            "btw": "bee tee wee",
        ],
        ambiguous: ["sql", "st", "mr", "ds"]
    )

    static func process(
        chunk: Chunker.Chunk, context: ProcessingContext,
        descriptor: LanguageProcessorDescriptor, rules: ProcessorRules
    ) -> ProcessedChunk {
        var text = chunk.text.precomposedStringWithCanonicalMapping
        var substitutions: [TextSubstitution] = []

        let book = context.overrides.filter { $0.bookContentId == context.contentId }
        let global = context.overrides.filter { $0.bookContentId == nil }
        let ordered = [book, global].flatMap {
            $0.sorted { $0.matchText.count > $1.matchText.count }
        }
        var protectedReplacements: [String] = []
        for item in ordered where item.isValid {
            let replacement = item.mode == .spellLetters
                ? spell(item.matchText, flavor: rules.flavor) : item.replacement
            text = replace(
                item.matchText, in: text, with: replacement,
                caseSensitive: item.matchCase == .sensitive,
                protectedReplacements: &protectedReplacements,
                substitution: .init(source: item.matchText, replacement: replacement, kind: .userOverride),
                substitutions: &substitutions
            )
        }

        for (source, replacement) in rules.aliases.sorted(by: { $0.key.count > $1.key.count }) {
            // A replacement that carries its own comma ("for example,") also
            // consumes one after the source, so "e.g., x" cannot double up.
            var pattern = NSRegularExpression.escapedPattern(for: source) + #"\.?"#
            if replacement.hasSuffix(",") { pattern += ",?" }
            text = replace(
                pattern, in: text, with: replacement, caseSensitive: false,
                protectedReplacements: &protectedReplacements, isRegex: true,
                substitution: .init(source: source, replacement: replacement, kind: .alias),
                substitutions: &substitutions
            )
        }
        for (source, replacement) in rules.initialisms {
            text = replace(
                source, in: text, with: replacement, caseSensitive: true,
                protectedReplacements: &protectedReplacements,
                substitution: .init(source: source, replacement: replacement, kind: .alias),
                substitutions: &substitutions
            )
        }

        // Dotted initialisms — "U.S.", "U.N.", "J.R.R." — spelled as letters.
        // The dictionary above cannot reach them: its keys carry no dots and
        // the word-boundary lookarounds stop at the first period. Spaced
        // initials ("J. K. Rowling") stay untouched. The optional bare capital
        // at the end absorbs a missing final dot ("U.S.A" before a comma).
        let dottedPattern = #"(?<![\p{L}\p{N}])(?:\p{Lu}\.){2,}\p{Lu}?(?![\p{L}\p{N}])"#
        text = replacingMatches(dottedPattern, in: text) { groups in
            let replacement = spell(groups[0], flavor: rules.flavor)
            substitutions.append(.init(source: groups[0], replacement: replacement, kind: .alias))
            return replacement
        }

        text = normalizeStructured(text, context: context, rules: rules, substitutions: &substitutions)
        for (index, replacement) in protectedReplacements.enumerated() {
            text = text.replacingOccurrences(of: placeholder(index), with: replacement)
        }
        return result(chunk.text, spoken: text, substitutions: substitutions, context: context, descriptor: descriptor)
    }

    static func result(
        _ display: String, spoken: String, substitutions: [TextSubstitution],
        context: ProcessingContext, descriptor: LanguageProcessorDescriptor
    ) -> ProcessedChunk {
        let overrideStamp = context.overrides.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            "\($0.id):\($0.updatedAt.timeIntervalSince1970):\($0.deletedAt?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
        let fingerprint = hash(
            "\(descriptor.languageCode)|\(descriptor.version)|\(context.locale.identifier)|\(overrideStamp)|\(spoken)"
        )
        return ProcessedChunk(
            displayText: display, spokenText: spoken, substitutions: substitutions,
            fingerprint: fingerprint
        )
    }

    static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func replace(
        _ source: String, in input: String, with replacement: String, caseSensitive: Bool,
        protectedReplacements: inout [String], isRegex: Bool = false,
        substitution: TextSubstitution, substitutions: inout [TextSubstitution]
    ) -> String {
        let body = isRegex ? source : NSRegularExpression.escapedPattern(for: source)
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_])(?:\(body))(?![\\p{L}\\p{N}_])",
            options: caseSensitive ? [] : [.caseInsensitive]
        ) else { return input }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }
        var output = input
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let token = placeholder(protectedReplacements.count)
            protectedReplacements.append(replacement)
            output.replaceSubrange(range, with: token)
            substitutions.append(substitution)
        }
        return output
    }

    /// One private-use scalar protects a winning source range from every
    /// lower-precedence rule. It is restored only after deterministic
    /// normalization, preventing both overlap and replacement recursion.
    private static func placeholder(_ index: Int) -> String {
        String(UnicodeScalar(0xF0000 + index)!)
    }

    private static func spell(_ text: String, flavor: Flavor) -> String {
        let letters = text.uppercased().filter(\.isLetter)
        guard flavor == .dutch else { return letters.map(String.init).joined(separator: " ") }
        let names: [Character: String] = [
            "A":"aa", "B":"bee", "C":"see", "D":"dee", "E":"ee", "F":"ef", "G":"gee",
            "H":"haa", "I":"ie", "J":"jee", "K":"kaa", "L":"el", "M":"em", "N":"en",
            "O":"oo", "P":"pee", "Q":"kuu", "R":"er", "S":"es", "T":"tee", "U":"uu",
            "V":"vee", "W":"wee", "X":"iks", "Y":"ij", "Z":"zet"
        ]
        return letters.map { names[$0] ?? String($0) }.joined(separator: " ")
    }

    private static func normalizeStructured(
        _ input: String, context: ProcessingContext, rules: ProcessorRules,
        substitutions: inout [TextSubstitution]
    ) -> String {
        var text = input
        // A context can carry a locale that contradicts its language; numbers
        // must never be spelled in another tongue, so the language wins and
        // the locale falls back to that language's default.
        let flavorLanguage = rules.flavor == .dutch ? "nl" : "en"
        let identifier = context.locale.languageCode == flavorLanguage
            ? context.locale.identifier
            : LocaleProfile.defaultIdentifier(for: flavorLanguage)
        let locale = Locale(identifier: identifier)
        let monthFirst = identifier.replacingOccurrences(of: "_", with: "-")
            .lowercased().hasPrefix("en-us")

        // Dates first: a spoken date must win before the number rules can
        // nibble at its parts. Only forms with a four-digit year are
        // unambiguous enough to speak; anything less stays verbatim.
        let isoDatePattern = #"(?<![\p{L}\p{N}])(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?![\p{L}\p{N}])"#
        text = replacingMatches(isoDatePattern, in: text) { groups in
            guard groups.count == 4, let year = Int(groups[1]), let month = Int(groups[2]),
                  let day = Int(groups[3]),
                  let replacement = spokenDate(
                      day: day, month: month, year: year, monthFirst: monthFirst,
                      locale: locale, flavor: rules.flavor
                  )
            else { return groups[0] }
            substitutions.append(.init(source: groups[0], replacement: replacement, kind: .date))
            return replacement
        }

        let numericDatePattern = #"(?<![\p{L}\p{N}])(\d{1,2})[/-](\d{1,2})[/-](\d{4})(?![\p{L}\p{N}])"#
        text = replacingMatches(numericDatePattern, in: text) { groups in
            guard groups.count == 4, let first = Int(groups[1]), let second = Int(groups[2]),
                  let year = Int(groups[3]) else { return groups[0] }
            // Day/month order follows the spoken locale; a month over twelve
            // can only be the day, whichever way the book writes it.
            var day = monthFirst ? second : first
            var month = monthFirst ? first : second
            if month > 12, day <= 12 { swap(&day, &month) }
            guard let replacement = spokenDate(
                day: day, month: month, year: year, monthFirst: monthFirst,
                locale: locale, flavor: rules.flavor
            ) else { return groups[0] }
            substitutions.append(.init(source: groups[0], replacement: replacement, kind: .date))
            return replacement
        }

        // Currency must run before bare numbers. The amount body accepts
        // grouped thousands in either typography; the locale decides what a
        // lone mark means when it parses.
        let currencyPattern = #"(?<![\p{L}\p{N}])([£€$])\s?("# + numberBody + #")(?![\p{L}\p{N}])"#
        text = replacingMatches(currencyPattern, in: text) { groups in
            guard groups.count == 3, let value = parsedNumber(groups[2], locale: locale) else { return groups[0] }
            let replacement = spokenAmount(value, symbol: groups[1], locale: locale, flavor: rules.flavor)
            substitutions.append(.init(source: groups[0], replacement: replacement, kind: .currency))
            return replacement
        }

        let percentPattern = #"(?<![\p{L}\p{N}])(\d+(?:[.,]\d+)?)\s?%(?![\p{L}\p{N}])"#
        text = replacingMatches(percentPattern, in: text) { groups in
            guard groups.count == 2, let value = parsedNumber(groups[1], locale: locale) else { return groups[0] }
            let replacement = "\(spellNumber(value, locale: locale)) "
                + (rules.flavor == .dutch ? "procent" : "percent")
            substitutions.append(.init(source: groups[0], replacement: replacement, kind: .number))
            return replacement
        }

        let timePattern = #"(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?!\d)"#
        text = replacingMatches(timePattern, in: text) { groups in
            guard groups.count == 3, let hour = Int(groups[1]), let minute = Int(groups[2]) else { return groups[0] }
            let h = spellInteger(hour, locale: locale)
            let m = minute < 10 && rules.flavor == .english
                ? "oh \(spellInteger(minute, locale: locale))"
                : spellInteger(minute, locale: locale)
            let replacement: String
            if rules.flavor == .dutch {
                replacement = minute == 0 ? "\(h) uur" : "\(h) uur \(m)"
            } else {
                replacement = minute == 0 ? "\(h) o'clock" : "\(h) \(m)"
            }
            substitutions.append(.init(source: groups[0], replacement: replacement, kind: .time))
            return replacement
        }

        if rules.flavor == .english {
            let ordinalPattern = #"(?<![\p{L}\p{N}])(\d+)(st|nd|rd|th)(?![\p{L}\p{N}])"#
            text = replacingMatches(ordinalPattern, in: text) { groups in
                guard groups.count == 3, let number = Int(groups[1]) else { return groups[0] }
                let replacement = englishOrdinal(number, locale: locale)
                substitutions.append(.init(source: groups[0], replacement: replacement, kind: .number))
                return replacement
            }
        }

        // Do not touch digits adjacent to dots/slashes/hyphens: versions,
        // IP addresses and identifiers are review material, not safe
        // cardinals. Decimals and grouped thousands are accepted as one unit.
        let numberPattern = #"(?<![\p{L}\p{N}/.-])("# + numberBody + #")(?![\p{L}\p{N}/.-])"#
        text = replacingMatches(numberPattern, in: text) { groups in
            guard groups.count == 2, let value = parsedNumber(groups[1], locale: locale) else { return groups[0] }
            let replacement = spellNumber(value, locale: locale)
            substitutions.append(.init(source: groups[0], replacement: replacement, kind: .number))
            return replacement
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func replacingMatches(
        _ pattern: String, in input: String, transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        var output = input
        for match in matches.reversed() {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: transform(groups))
        }
        return output
    }

    /// Digits with optional grouped thousands in either typography, or a
    /// plain decimal. What a lone mark means is the locale's call at parse
    /// time; this only bounds the span a number rule may claim.
    private static let numberBody =
        #"(?:\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d{1,3}(?:\.\d{3})+(?:,\d+)?|\d+(?:[.,]\d+)?)"#

    private static func parsedNumber(_ source: String, locale: Locale) -> Decimal? {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        if let number = formatter.number(from: source) { return number.decimalValue }
        // EPUB typography is often locale-inconsistent. With both marks
        // present the last one is the decimal separator; repeated marks are
        // grouping; a lone comma reads as a decimal point.
        let commas = source.filter { $0 == "," }.count
        let dots = source.filter { $0 == "." }.count
        let normalized: String
        if commas > 0, dots > 0, let lastComma = source.lastIndex(of: ","),
           let lastDot = source.lastIndex(of: ".") {
            normalized = lastComma > lastDot
                ? source.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                : source.replacingOccurrences(of: ",", with: "")
        } else if commas > 1 {
            normalized = source.replacingOccurrences(of: ",", with: "")
        } else if dots > 1 {
            normalized = source.replacingOccurrences(of: ".", with: "")
        } else {
            normalized = source.replacingOccurrences(of: ",", with: ".")
        }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// "€1,250.50" → "one thousand two hundred fifty euros and fifty cents".
    /// Exact cent amounts are read as money; anything else falls back to the
    /// plain number reading with a plural unit.
    private static func spokenAmount(
        _ value: Decimal, symbol: String, locale: Locale, flavor: Flavor
    ) -> String {
        let whole = NSDecimalNumber(decimal: value).intValue
        let subunits = NSDecimalNumber(decimal: (value - Decimal(whole)) * 100).intValue
        let exact = Decimal(whole) + Decimal(subunits) / 100 == value
        if flavor == .dutch {
            // Dutch units stay singular: "twaalf euro vijftig".
            let unit = switch symbol { case "£": "pond"; case "$": "dollar"; default: "euro" }
            guard exact else { return "\(spellNumber(value, locale: locale)) \(unit)" }
            if whole == 0, subunits > 0 {
                return "\(spellInteger(subunits, locale: locale)) cent"
            }
            return subunits == 0
                ? "\(spellInteger(whole, locale: locale)) \(unit)"
                : "\(spellInteger(whole, locale: locale)) \(unit) \(spellInteger(subunits, locale: locale))"
        }
        let units: (one: String, many: String, centOne: String, centMany: String) = switch symbol {
        case "£": ("pound", "pounds", "penny", "pence")
        case "$": ("dollar", "dollars", "cent", "cents")
        default: ("euro", "euros", "cent", "cents")
        }
        guard exact else { return "\(spellNumber(value, locale: locale)) \(units.many)" }
        let unit = whole == 1 ? units.one : units.many
        guard subunits > 0 else { return "\(spellInteger(whole, locale: locale)) \(unit)" }
        let cent = subunits == 1 ? units.centOne : units.centMany
        if whole == 0 { return "\(spellInteger(subunits, locale: locale)) \(cent)" }
        return "\(spellInteger(whole, locale: locale)) \(unit) and \(spellInteger(subunits, locale: locale)) \(cent)"
    }

    private static func spokenDate(
        day: Int, month: Int, year: Int, monthFirst: Bool,
        locale: Locale, flavor: Flavor
    ) -> String? {
        guard (1...12).contains(month), (1...31).contains(day), (1000...2999).contains(year)
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        let monthName = formatter.monthSymbols[month - 1]
        if flavor == .dutch {
            return "\(spellInteger(day, locale: locale)) \(monthName) \(dutchYear(year, locale: locale))"
        }
        let spokenYear = englishYear(year, locale: locale)
        return monthFirst
            ? "\(monthName) \(englishOrdinal(day, locale: locale)), \(spokenYear)"
            : "the \(englishOrdinal(day, locale: locale)) of \(monthName), \(spokenYear)"
    }

    /// Years read in pairs the way people say them: "nineteen ninety-nine",
    /// "nineteen oh five", "twenty twenty-six" — not "one thousand nine
    /// hundred ninety-nine".
    private static func englishYear(_ year: Int, locale: Locale) -> String {
        let remainder = year % 100
        switch year {
        case 1100...1999:
            let head = spellInteger(year / 100, locale: locale)
            if remainder == 0 { return "\(head) hundred" }
            if remainder < 10 { return "\(head) oh \(spellInteger(remainder, locale: locale))" }
            return "\(head) \(spellInteger(remainder, locale: locale))"
        case 2000...2009:
            return spellInteger(year, locale: locale)
        case 2010...2099:
            return "twenty \(spellInteger(remainder, locale: locale))"
        default:
            return spellInteger(year, locale: locale)
        }
    }

    private static func dutchYear(_ year: Int, locale: Locale) -> String {
        guard (1100...1999).contains(year) else { return spellInteger(year, locale: locale) }
        let head = "\(spellInteger(year / 100, locale: locale))honderd"
        let remainder = year % 100
        return remainder == 0 ? head : "\(head) \(spellInteger(remainder, locale: locale))"
    }

    private static func spellNumber(_ value: Decimal, locale: Locale) -> String {
        let number = NSDecimalNumber(decimal: value)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .spellOut
        // Dutch spell-out joins compounds with soft hyphens; the tokenizer
        // must never see an invisible character.
        return (formatter.string(from: number) ?? number.stringValue)
            .replacingOccurrences(of: "\u{00AD}", with: "")
    }

    private static func spellInteger(_ value: Int, locale: Locale) -> String {
        spellNumber(Decimal(value), locale: locale)
    }

    /// Spell the cardinal, then ordinalize its last word, so any magnitude
    /// works: 21 → "twenty-first", 30 → "thirtieth", 100 → "one hundredth".
    private static func englishOrdinal(_ number: Int, locale: Locale) -> String {
        let cardinal = spellInteger(number, locale: locale)
        let irregular = [
            "one": "first", "two": "second", "three": "third", "five": "fifth",
            "eight": "eighth", "nine": "ninth", "twelve": "twelfth",
        ]
        guard let last = cardinal.split(whereSeparator: { $0 == " " || $0 == "-" }).last
        else { return cardinal }
        let word = String(last)
        let ordinal = irregular[word]
            ?? (word.hasSuffix("y") ? word.dropLast() + "ieth" : word + "th")
        return cardinal.dropLast(word.count) + ordinal
    }
}

private enum CandidateAnalyzer {
    private struct Seen {
        var forms: Set<String> = []
        var count = 0
        var chapters: Set<Int> = []
        var first = Int.max
        var sentence = ""
        var category: PronunciationCandidate.Category = .unusual
        var reasons: Set<String> = []
        var points = 0.0
    }

    static func analyze(
        book: Book, context: AnalysisContext,
        descriptor: LanguageProcessorDescriptor, rules: ProcessorRules
    ) async -> PreflightReport {
        let clock = ContinuousClock.now
        var seen: [String: Seen] = [:]
        var ordinal = 0
        let tokenRegex = try! NSRegularExpression(
            pattern: #"[\p{L}][\p{L}\p{M}\p{N}_'’\-]*|\d{1,4}[/-]\d{1,2}(?:[/-]\d{2,4})?"#
        )
        let covered = Set(context.processing.overrides.map { $0.matchText.lowercased() })
        // The system lexicon: anything it knows — common words, countries,
        // famous names — reads fine and is not worth a review row.
        let lexicon = NLEmbedding.wordEmbedding(for: NLLanguage(rawValue: descriptor.languageCode))

        for (chapterIndex, chapter) in book.chapters.enumerated() {
            let ns = chapter.text as NSString
            let matches = tokenRegex.matches(
                in: chapter.text, range: NSRange(location: 0, length: ns.length)
            )
            for match in matches {
                ordinal += 1
                let form = ns.substring(with: match.range)
                let key = form.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: context.processing.locale.identifier))
                guard !covered.contains(key), !isFullDate(form),
                      !looksLikeURLNeighbour(chapter.text, range: match.range) else { continue }
                var category: PronunciationCandidate.Category?
                var reasons: [String] = []
                var points = 0.0
                let letters = form.filter(\.isLetter)
                let isUpper = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
                let hasDigit = form.contains(where: \.isNumber)
                let camel = form.dropFirst().contains(where: \.isUppercase) && form.contains(where: \.isLowercase)
                let ambiguousDate = (form.contains("/") || form.contains("-") && hasDigit)
                    && !isFullDate(form)

                if rules.ambiguous.contains(key) || ambiguousDate {
                    category = .ambiguous; reasons.append("More than one common reading"); points += 6
                }
                if isUpper && rules.initialisms[form] == nil {
                    category = .acronym; reasons.append("Unknown capitalized abbreviation"); points += 5
                }
                if hasDigit || camel {
                    category = .technical; reasons.append("Mixed-format term"); points += 5
                }
                if form.first?.isUppercase == true, form.count >= 4,
                   midSentence(ns, before: match.range.location),
                   lexicon?.contains(key) != true {
                    category = category ?? .name; reasons.append("Possible proper name"); points += 4
                }
                if form.count >= 12, lexicon?.contains(key) != true {
                    category = category ?? .unusual; reasons.append("Unusually long word"); points += 2
                }
                guard let category else { continue }
                var item = seen[key] ?? Seen()
                item.forms.insert(form)
                item.count += 1
                item.chapters.insert(chapterIndex)
                item.first = min(item.first, ordinal)
                item.category = category
                item.reasons.formUnion(reasons)
                item.points = max(item.points, points)
                if item.sentence.isEmpty { item.sentence = contextSentence(chapter.text, around: match.range) }
                seen[key] = item
            }
        }

        let ignored = await PronunciationStore.shared.all().ignored
        let ignoredIds = Set(ignored.filter { $0.contentId == context.processing.contentId }.map(\.candidateId))
        let candidates = seen.map { key, item -> (PronunciationCandidate, Int) in
            let score = item.points + 4 * log2(Double(item.count + 1))
            let id = ProcessorRules.hash("\(descriptor.languageCode)|\(key)")
            return (
                PronunciationCandidate(
                    id: id, surfaceForms: item.forms.sorted(), category: item.category,
                    reasons: item.reasons.sorted(), occurrenceCount: item.count,
                    chapterCount: item.chapters.count, representativeSentence: item.sentence,
                    riskScore: score
                ), item.first
            )
        }
        // A name a book only drops a handful of times is not worth a review
        // row; the listener hears it wrong six times and moves on.
        .filter {
            !ignoredIds.contains($0.0.id) && $0.0.riskScore >= 6
                && ($0.0.category != .name || $0.0.occurrenceCount > 6)
        }
        .sorted {
            if $0.0.riskScore != $1.0.riskScore { return $0.0.riskScore > $1.0.riskScore }
            if $0.0.occurrenceCount != $1.0.occurrenceCount { return $0.0.occurrenceCount > $1.0.occurrenceCount }
            return $0.1 < $1.1
        }
        .prefix(10).map(\.0)

        let fingerprint = ProcessorRules.hash(
            "\(book.contentId ?? book.derivedContentId)|\(book.languageCode)|\(context.processing.locale.identifier)|\(descriptor.version)|\(context.processing.overrides.map(\.updatedAt.timeIntervalSince1970))"
        )
        let elapsed = clock.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return PreflightReport(
            fingerprint: fingerprint, candidates: candidates, analysisDuration: seconds,
            packVersion: descriptor.version
        )
    }

    private static func contextSentence(_ text: String, around range: NSRange) -> String {
        let ns = text as NSString
        let lower = max(0, range.location - 90)
        let upper = min(ns.length, NSMaxRange(range) + 90)
        return ns.substring(with: NSRange(location: lower, length: upper - lower))
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Looks past whitespace and quotes for the previous printable character,
    /// so a capital that merely opens a sentence is not mistaken for a name.
    private static func midSentence(_ text: NSString, before location: Int) -> Bool {
        var cursor = location - 1
        while cursor >= 0 {
            let character = Character(text.substring(with: NSRange(location: cursor, length: 1)))
            if character.isWhitespace || "\"'“”‘’«»()[]".contains(character) {
                cursor -= 1
                continue
            }
            return !".!?…:;".contains(character)
        }
        return false
    }

    /// A three-part numeric token with a four-digit year is spoken
    /// deterministically by the date rules — nothing left to review.
    private static func isFullDate(_ form: String) -> Bool {
        let parts = form.split(whereSeparator: { $0 == "/" || $0 == "-" })
        return parts.count == 3 && (parts.first?.count == 4 || parts.last?.count == 4)
    }

    private static func looksLikeURLNeighbour(_ text: String, range: NSRange) -> Bool {
        let ns = text as NSString
        let lower = max(0, range.location - 10)
        let upper = min(ns.length, NSMaxRange(range) + 10)
        let sample = ns.substring(with: NSRange(location: lower, length: upper - lower)).lowercased()
        return sample.contains("http") || sample.contains("www.") || sample.contains("@")
    }
}
