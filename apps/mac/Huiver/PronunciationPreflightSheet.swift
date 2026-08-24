import AVFoundation
import SwiftUI

struct PronunciationPreflightSheet: View {
    let book: Book
    let report: PreflightReport
    let completed: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var candidates: [PronunciationCandidate]
    @State private var selectedId: String?
    @State private var replacement = ""
    @State private var spellLetters = false
    @State private var global = false
    @State private var player: AVAudioPlayer?
    @State private var previewing = false
    @State private var failure: String?

    init(book: Book, report: PreflightReport, completed: @escaping () -> Void) {
        self.book = book
        self.report = report
        self.completed = completed
        _candidates = State(initialValue: report.candidates)
        _selectedId = State(initialValue: report.candidates.first?.id)
    }

    private var selected: PronunciationCandidate? {
        candidates.first { $0.id == selectedId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Palette.Space.lg) {
            VStack(alignment: .leading, spacing: Palette.Space.xs) {
                Text("Pronunciation preflight").font(.huiverTitle)
                Text("Review the few terms most likely to be read inconsistently. Corrections affect future audio only.")
                    .font(.huiverBody)
                    .foregroundStyle(theme.colors.mutedForeground)
            }

            HSplitView {
                List(candidates, selection: $selectedId) { candidate in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.surfaceForms.first ?? "Unknown").font(.huiverLabel)
                        Text("\(candidate.occurrenceCount) uses · \(candidate.chapterCount) chapters")
                            .font(.huiverCaption)
                            .foregroundStyle(theme.colors.mutedForeground)
                    }
                    .tag(candidate.id)
                }
                .frame(minWidth: 210)

                Group {
                    if let candidate = selected {
                        editor(candidate)
                    } else {
                        ContentUnavailableView(
                            "All reviewed", systemImage: "checkmark.circle",
                            description: Text("No unresolved high-risk terms remain in this report.")
                        )
                    }
                }
                .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Text("Pack/rules \(report.packVersion) · \(String(format: "%.2f", report.analysisDuration)) s")
                    .font(.huiverCaption)
                    .foregroundStyle(theme.colors.mutedForeground)
                Spacer()
                Button("Continue without reviewing") { finish() }
                Button("Done") { finish() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Palette.Space.xl)
        .frame(minWidth: 720, minHeight: 520)
        .alert("Could not preview", isPresented: .init(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func editor(_ candidate: PronunciationCandidate) -> some View {
        VStack(alignment: .leading, spacing: Palette.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.surfaceForms.first ?? "Unknown").font(.huiverTitle)
                Spacer()
                Text("risk \(Int(candidate.riskScore.rounded()))")
                    .font(.huiverCaption)
                    .foregroundStyle(theme.colors.mutedForeground)
            }
            Text(candidate.reasons.joined(separator: " · "))
                .font(.huiverCaption)
                .foregroundStyle(theme.colors.mutedForeground)
            Text(candidate.representativeSentence)
                .font(.huiverBody)
                .textSelection(.enabled)
                .padding(Palette.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.colors.muted, in: .rect(cornerRadius: Palette.Radius.md))

            Toggle("Spell as individual letters", isOn: $spellLetters)
            if !spellLetters {
                TextField("Say as", text: $replacement, prompt: Text("Phonetic written approximation"))
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Use in every \(Language.named(book.languageCode).name) book", isOn: $global)

            HStack {
                Button("Play original", systemImage: "play") { preview(candidate, corrected: false) }
                    .disabled(previewing)
                Button("Play correction", systemImage: "waveform") { preview(candidate, corrected: true) }
                    .disabled(previewing || (!spellLetters && replacement.trimmingCharacters(in: .whitespaces).isEmpty))
                if previewing { ProgressView().controlSize(.small) }
                Spacer()
            }

            Spacer()
            HStack {
                Button("Ignore for this book") {
                    Task {
                        await model.ignorePronunciation(candidate, in: book)
                        remove(candidate)
                    }
                }
                Spacer()
                Button(global ? "Save globally" : "Save for this book") {
                    Task {
                        do {
                            try await model.savePronunciation(
                                candidate: candidate, replacement: replacement,
                                spellLetters: spellLetters, global: global, in: book
                            )
                            remove(candidate)
                        } catch { failure = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!spellLetters && replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Palette.Space.lg)
        .onChange(of: selectedId) { _, _ in
            replacement = ""
            spellLetters = false
            global = false
        }
    }

    private func preview(_ candidate: PronunciationCandidate, corrected: Bool) {
        let override: PronunciationOverride? = corrected ? .init(
            languageCode: book.languageCode,
            bookContentId: book.contentId ?? book.derivedContentId,
            matchText: candidate.surfaceForms.first ?? "",
            replacement: replacement,
            mode: spellLetters ? .spellLetters : .sayAs,
            matchCase: candidate.category == .acronym ? .sensitive : .insensitive
        ) : nil
        previewing = true
        Task {
            do {
                let url = try await model.pronunciationPreview(
                    candidate.representativeSentence, replacement: override, book: book
                )
                player = try AVAudioPlayer(contentsOf: url)
                player?.play()
            } catch { failure = error.localizedDescription }
            previewing = false
        }
    }

    private func remove(_ candidate: PronunciationCandidate) {
        let index = candidates.firstIndex(where: { $0.id == candidate.id }) ?? 0
        candidates.removeAll { $0.id == candidate.id }
        selectedId = candidates.isEmpty ? nil : candidates[min(index, candidates.count - 1)].id
        replacement = ""
        spellLetters = false
    }

    private func finish() {
        Task {
            await model.markPreflightReviewed(report, book: book)
            completed()
        }
    }
}
