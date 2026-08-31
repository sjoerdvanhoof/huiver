#if DEBUG
import AVFoundation
import SwiftUI

/// Debug-only workbench for the speech front end.
///
/// A fixed suite of phrases — times, dates, money, ordinals, abbreviations,
/// dotted acronyms, initials — is run through the live language processor so
/// every rule change is visible as text immediately and audible on demand.
/// The whole file is compiled out of Release builds; listeners never see it.
struct DevLabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var language = "en"
    @State private var locale = "en-US"
    @State private var adHoc = ""
    @State private var adHocResult: ProcessedChunk?
    @State private var results: [String: ProcessedChunk] = [:]
    @State private var synthesizingId: String?
    @State private var player: AVAudioPlayer?
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                Picker("Language", selection: $language) {
                    Text("English").tag("en")
                    Text("Nederlands").tag("nl")
                }
                .pickerStyle(.segmented)
                Picker("Locale", selection: $locale) {
                    ForEach(locales, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Processor")
            } footer: {
                Text("Rules \(rulesVersion) · global corrections for the language apply, book-scoped ones do not.")
                    .font(.huiverCaption)
                    .foregroundStyle(theme.colors.mutedForeground)
            }

            Section("Try anything") {
                TextField("Type a phrase to preview its spoken form", text: $adHoc, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                if let adHocResult, !adHoc.isEmpty {
                    row(id: "ad-hoc", original: adHoc, processed: adHocResult)
                }
            }

            ForEach(categories, id: \.self) { category in
                Section(category) {
                    ForEach(phrases.filter { $0.category == category }) { phrase in
                        if let processed = results[phrase.text] {
                            row(id: phrase.id, original: phrase.text, processed: processed)
                        } else {
                            Text(phrase.text).font(.huiverBody)
                        }
                    }
                }
            }
        }
        .navigationTitle("Pronunciation Lab")
        .task(id: "\(language)|\(locale)") { await reprocess() }
        .task(id: "\(adHoc)|\(language)|\(locale)") {
            guard !adHoc.isEmpty else { adHocResult = nil; return }
            let processed = await model.devProcess(adHoc, languageCode: language, localeIdentifier: locale)
            guard !Task.isCancelled else { return }
            adHocResult = processed
        }
        .onChange(of: language) { _, fresh in
            locale = fresh == "nl" ? "nl-NL" : "en-US"
        }
        .alert("Could not preview", isPresented: .init(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func row(id: String, original: String, processed: ProcessedChunk) -> some View {
        HStack(alignment: .top, spacing: Palette.Space.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(original)
                    .font(.huiverBody)
                    .textSelection(.enabled)
                if processed.spokenText == original {
                    Text("unchanged")
                        .font(.huiverCaption)
                        .foregroundStyle(theme.colors.mutedForeground)
                } else {
                    Text(processed.spokenText)
                        .font(.huiverBody)
                        .foregroundStyle(theme.colors.primary)
                        .textSelection(.enabled)
                    Text(substitutionSummary(processed))
                        .font(.huiverCaption)
                        .foregroundStyle(theme.colors.mutedForeground)
                }
            }
            Spacer()
            if synthesizingId == id {
                ProgressView().controlSize(.small)
            } else {
                // "raw" feeds the untouched source text to the model, so a
                // rule can be judged against what it replaced.
                Button("Play", systemImage: "waveform") {
                    speak(processed.spokenText, id: id)
                }
                Button("Raw", systemImage: "play") {
                    speak(original, id: id)
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
    }

    private func speak(_ text: String, id: String) {
        guard synthesizingId == nil else { return }
        synthesizingId = id
        Task {
            do {
                let url = try await model.devSpeak(text, languageCode: language)
                player = try AVAudioPlayer(contentsOf: url)
                player?.play()
            } catch { failure = error.localizedDescription }
            synthesizingId = nil
        }
    }

    private func reprocess() async {
        var fresh: [String: ProcessedChunk] = [:]
        for phrase in phrases {
            fresh[phrase.text] = await model.devProcess(
                phrase.text, languageCode: language, localeIdentifier: locale
            )
        }
        // Switching language re-fires this task with the locale mid-reset; a
        // superseded pass must not overwrite the current one's results.
        guard !Task.isCancelled else { return }
        results = fresh
    }

    private func substitutionSummary(_ processed: ProcessedChunk) -> String {
        let kinds = Dictionary(grouping: processed.substitutions, by: \.kind.rawValue)
            .map { "\($0.value.count)× \($0.key)" }
            .sorted()
        return kinds.isEmpty ? "no substitutions" : kinds.joined(separator: " · ")
    }

    private var locales: [String] {
        language == "nl" ? ["nl-NL", "nl-BE"] : ["en-US", "en-GB"]
    }

    private var rulesVersion: String {
        LanguageProcessorRegistry.processor(for: language).descriptor.version
    }

    private var phrases: [DevPhrase] {
        language == "nl" ? Self.dutch : Self.english
    }

    private var categories: [String] {
        var seen: [String] = []
        for phrase in phrases where !seen.contains(phrase.category) {
            seen.append(phrase.category)
        }
        return seen
    }

    private struct DevPhrase: Identifiable {
        let category: String
        let text: String
        var id: String { text }
    }

    private static let english: [DevPhrase] = [
        .init(category: "Times", text: "The train leaves at 14:30 and arrives at 9:05."),
        .init(category: "Times", text: "They met at 12:00, not at 8 P.M."),
        .init(category: "Dates", text: "She was born on 12/03/1999, a Friday."),
        .init(category: "Dates", text: "The deadline is 2026-08-30, mind you."),
        .init(category: "Money", text: "It costs $12.50, roughly €11 or £9.99."),
        .init(category: "Money", text: "She gave $1 and got £0.75 back."),
        .init(category: "Numbers", text: "Sales rose 25% to 1,250 units in 2026."),
        .init(category: "Numbers", text: "Her 21st birthday fell on the 3rd of June."),
        .init(category: "Titles", text: "Dr. Smith met Mr. Jones, Mrs. Lee and Prof. Chen."),
        .init(category: "Abbreviations", text: "Bring fruit, e.g. apples, i.e. no meat, etc."),
        .init(category: "Acronyms", text: "The U.S. and the U.N. pressured the EU and the UK."),
        .init(category: "Acronyms", text: "He moved from the US to the UK on 4/07/2010."),
        .init(category: "Acronyms", text: "NASA briefed the FBI, the CIA and a CEO with a Ph.D."),
        .init(category: "Names", text: "J. K. Rowling and J.R.R. Tolkien never met."),
        .init(
            category: "Stress test",
            text: "At 14:05, Dr. Kim wired €1,250.50 — 25% of the U.S. budget — to the U.N."
        ),
    ]

    private static let dutch: [DevPhrase] = [
        .init(category: "Tijden", text: "De trein vertrekt om 14:30 van spoor 7."),
        .init(category: "Datums", text: "Geboren op 12-03-1999, verhuisd op 30-08-2026."),
        .init(category: "Geld", text: "Het kost €12,50, met 25% korting."),
        .init(category: "Titels", text: "Dhr. Jansen en mevr. de Vries kijken tv."),
        .init(category: "Acroniemen", text: "De V.S. en de V.N. overleggen met de EU."),
        .init(category: "Afkortingen", text: "Neem fruit mee, bijv. appels, enz."),
        .init(category: "Afkortingen", text: "D.w.z. dat het o.a. hier werkt, t/m vrijdag."),
        .init(
            category: "Stresstest",
            text: "Om 14:05 betaalde dr. Kim €1.250,50 — 25% van het budget van de V.S."
        ),
    ]
}
#endif
