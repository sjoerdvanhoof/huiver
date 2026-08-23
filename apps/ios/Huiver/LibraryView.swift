import SwiftUI
import UniformTypeIdentifiers

/// The shelf. Cover, title, author, and how much of it has been rendered —
/// laid out as in `legacy/mobile/app/index.tsx`, with the "Add a book" button
/// pinned to the bottom where a thumb reaches it.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var importing = false
    @State private var showingPlayer = false
    /// The prepare screen can be put aside: adding a book works while the models
    /// are still compiling, even though playing one does not.
    @State private var preparingDismissed = false
    /// The book a swipe has offered to delete, held until it is confirmed.
    @State private var pendingDeletion: Book?
    /// The book being pushed, driving navigation in place of a link.
    @State private var opened: Book?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ZStack {
                theme.colors.background.ignoresSafeArea()
                content
            }
            .navigationTitle("huiver")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { importing = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a book")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottom }
            .navigationDestination(item: $opened) { book in
                BookView(book: book)
            }
        }
        .fileImporter(
            isPresented: $importing,
            // Identified by contents rather than name, so anything readable is
            // offered and a mislabelled file still works.
            allowedContentTypes: [.epub, .plainText, .html, .zip, .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await model.importBook(from: url) }
        }
        .sheet(isPresented: $showingPlayer) { PlayerView() }
        .confirmationDialog(
            pendingDeletion.map { "Delete \($0.title)?" } ?? "Delete this book?",
            isPresented: .init(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let book = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await model.delete(book) }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            if let book = pendingDeletion {
                let rendered = book.chapters.filter(\.isComplete).count
                Text(rendered > 0
                    ? "Its text and the audio for \(rendered) rendered chapter\(rendered == 1 ? "" : "s") will be removed."
                    : "Its text will be removed. Nothing has been rendered yet.")
            }
        }
        .alert(
            "Something went wrong",
            isPresented: .init(
                get: { model.loadFailure != nil },
                set: { if !$0 { model.clearFailure() } }
            )
        ) {
            Button("OK") { model.clearFailure() }
        } message: {
            Text(model.loadFailure ?? "")
        }
        // Imports get their own alert: a bad EPUB is not the engine's fault,
        // and used to be reported as if it were.
        .alert(
            "Could not import",
            isPresented: .init(
                get: { model.importFailure != nil },
                set: { if !$0 { model.importFailure = nil } }
            )
        ) {
            Button("OK") { model.importFailure = nil }
        } message: {
            Text(model.importFailure ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let preparing = model.preparing, !preparingDismissed {
            VStack(spacing: Palette.Space.lg) {
                PreparingView(
                    progress: preparing,
                    since: model.preparingSince,
                    firstRun: !model.hasPreparedBefore
                )
                Button("Add a book while you wait") { preparingDismissed = true }
                    .font(.huiverLabel)
            }
        } else if model.isLoading && model.books.isEmpty {
            ProgressView()
        } else if model.books.isEmpty {
            emptyShelf
        } else {
            shelf
        }
    }

    private var emptyShelf: some View {
        VStack(spacing: Palette.Space.md) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.colors.mutedForeground)
            Text("No books yet")
                .font(.huiverHeading)
                .foregroundStyle(theme.colors.foreground)
            Text("Add an EPUB and huiver will read it to you in a cloned voice — all on this phone.")
                .font(.huiverBody)
                .foregroundStyle(theme.colors.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Palette.Space.xl)

            Button("Add a book") { importing = true }
                .font(.huiverHeading)
                .foregroundStyle(theme.colors.primaryForeground)
                .padding(.horizontal, Palette.Space.xl)
                .padding(.vertical, Palette.Space.md)
                .background(theme.colors.primary, in: .capsule)
                .buttonStyle(.plain)
                .padding(.top, Palette.Space.sm)
        }
    }

    /// A `List` rather than a `ScrollView`, for the swipe actions — they are not
    /// available on an ordinary stack, and re-implementing the gesture by hand
    /// would get the rubber-banding and the accessibility affordance wrong.
    /// The row styling is stripped back so it still looks like the stack did.
    private var shelf: some View {
        List {
            if query.isEmpty, let target = continueTarget {
                continueRow(target)
                    .listRowInsets(EdgeInsets(
                        top: Palette.Space.sm, leading: Palette.Space.lg,
                        bottom: Palette.Space.sm, trailing: Palette.Space.lg
                    ))
                    .listRowBackground(theme.colors.background)
                    .listRowSeparatorTint(theme.colors.border)
            }
            ForEach(shownBooks) { book in
                // A Button with an explicit destination rather than a
                // NavigationLink: a link inside a List insists on drawing a
                // disclosure chevron, and there is no API to turn it off.
                Button { opened = book } label: { BookRow(book: book) }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowBackground(theme.colors.background)
                .listRowSeparatorTint(theme.colors.border)
                .alignmentGuide(.listRowSeparatorLeading) { _ in
                    56 + Palette.Space.lg * 2
                }
                // Leading edge, so it is a swipe to the right. Full swipe is off:
                // deleting a book throws away every chapter rendered for it, and
                // that is too much to lose to a flick.
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDeletion = book
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.refresh() }
        .searchable(text: $query, prompt: "Title or author")
    }

    /// The shelf, filtered by the search field. A shelf of forty
    /// public-domain books is exactly what this app accumulates.
    private var shownBooks: [Book] {
        guard !query.isEmpty else { return model.books }
        let wanted = query.lowercased()
        return model.books.filter {
            $0.title.lowercased().contains(wanted)
                || ($0.author?.lowercased().contains(wanted) ?? false)
        }
    }

    // MARK: - Continue listening

    /// The most recently touched unfinished chapter across the whole shelf —
    /// the one thing a listener opening the app almost always wants first.
    private var continueTarget: (book: Book, chapter: Chapter, position: Double)? {
        var best: (Book, Chapter, ChapterProgress)?
        for book in model.books {
            for chapter in book.chapters {
                guard let record = model.progress[chapter.id],
                      !record.finished, record.position > 1
                else { continue }
                if best == nil || record.updatedAt > best!.2.updatedAt {
                    best = (book, chapter, record)
                }
            }
        }
        return best.map { ($0.0, $0.1, $0.2.position) }
    }

    private func continueRow(
        _ target: (book: Book, chapter: Chapter, position: Double)
    ) -> some View {
        Button {
            resume(target)
        } label: {
            HStack(spacing: Palette.Space.md) {
                BookCover(
                    bookId: target.book.id,
                    title: target.book.title,
                    url: model.coverURL(for: target.book),
                    width: 48,
                    radius: Palette.Radius.md
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue listening")
                        .font(.huiverCaption)
                        .foregroundStyle(theme.colors.mutedForeground)
                    Text(target.chapter.title)
                        .font(.huiverLabel)
                        .foregroundStyle(theme.colors.foreground)
                        .lineLimit(1)
                    Text("\(target.book.title) · \(Format.duration(target.position)) in")
                        .font(.huiverCaption)
                        .foregroundStyle(theme.colors.mutedForeground)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.colors.primaryForeground)
                    .frame(width: 32, height: 32)
                    .background(theme.colors.primary, in: .circle)
            }
            .padding(Palette.Space.md)
            .background(theme.colors.card, in: .rect(cornerRadius: Palette.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Palette.Radius.lg)
                    .strokeBorder(theme.colors.border)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(model.narrator == nil)
        .accessibilityLabel(
            "Continue listening, \(target.chapter.title), \(target.book.title)"
        )
    }

    private func resume(_ target: (book: Book, chapter: Chapter, position: Double)) {
        guard let narrator = model.narrator, let voice = model.selectedVoice else { return }
        narrator.listen(
            book: target.book, chapter: target.chapter, voice: voice,
            options: model.options, from: target.position
        )
        showingPlayer = true
    }

    @ViewBuilder
    private var bottom: some View {
        VStack(spacing: 0) {
            if let preparing = model.preparing, preparingDismissed {
                PreparingStrip(progress: preparing, since: model.preparingSince)
            }
            if model.narrator?.chapterId != nil {
                MiniPlayer { showingPlayer = true }
                    .background(.bar)
                    .overlay(alignment: .top) { Divider().overlay(theme.colors.border) }
            }
        }
    }
}

private struct BookRow: View {
    let book: Book
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Palette.Space.lg) {
            BookCover(bookId: book.id, title: book.title, url: model.coverURL(for: book))

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.huiverHeading)
                    .foregroundStyle(theme.colors.foreground)
                    .lineLimit(2)
                if let author = book.author {
                    Text(author)
                        .font(.huiverBody)
                        .foregroundStyle(theme.colors.mutedForeground)
                        .lineLimit(1)
                }
                Text(meta)
                    .font(.huiverCaption)
                    .foregroundStyle(theme.colors.mutedForeground)
            }

            // No chevron here: the row is a NavigationLink inside a List, which
            // draws its own disclosure indicator. Adding one drew two.
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Palette.Space.lg)
        .padding(.vertical, Palette.Space.md)
        .contentShape(.rect)
        // One element, one sentence — not four Texts read as a run-on.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [book.title, book.author, meta].compactMap { $0 }.joined(separator: ", ")
        )
    }

    private var meta: String {
        let done = book.chapters.filter(\.isComplete).count
        let estimate = Double(book.characters) / Format.assumedCharactersPerSecond
        var parts = ["\(done)/\(book.chapters.count) chapters", Format.estimate(estimate)]
        // Only worth saying when it is not the obvious answer.
        if book.languageCode != Language.english.code {
            parts.append(Language.named(book.languageCode).name)
        }
        return parts.joined(separator: " · ")
    }
}

/// The slim version of the prepare progress, for once it has been dismissed.
struct PreparingStrip: View {
    let progress: ChatterboxEngine.LoadProgress
    let since: Date?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Palette.Space.xs) {
            ProgressView(value: progress.fraction)
            HStack {
                Text("Getting the voice model ready · \(progress.model)")
                Spacer()
                if let since { Text(since, style: .timer).monospacedDigit() }
            }
            .font(.huiverCaption)
            .foregroundStyle(theme.colors.mutedForeground)
        }
        .padding(.horizontal, Palette.Space.lg)
        .padding(.vertical, Palette.Space.sm)
    }
}
