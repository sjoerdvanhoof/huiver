import SwiftUI
import UniformTypeIdentifiers

/// The shelf, as a grid of covers — a Mac window has the width for it that a
/// phone does not. Books arrive through the open panel or by dropping an EPUB
/// anywhere on the grid.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.theme) private var theme

    @State private var importing = false
    /// The book being pushed, driving navigation in place of a link.
    @State private var opened: Book?
    @State private var query = ""
    /// How the shelf is ordered, remembered across launches.
    @AppStorage("librarySort") private var sortRaw = Sort.recent.rawValue

    enum Sort: String, CaseIterable {
        case recent, title, author, progress

        var label: String {
            switch self {
            case .recent: "Recently added"
            case .title: "Title"
            case .author: "Author"
            case .progress: "Progress"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.colors.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if model.isImporting {
                        ProgressView()
                            .controlSize(.small)
                            .help("Reading the book…")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort by", selection: $sortRaw) {
                            ForEach(Sort.allCases, id: \.rawValue) { sort in
                                Text(sort.label).tag(sort.rawValue)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .help("Sort the shelf")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: {
                        Label("Add a book", systemImage: "plus")
                    }
                }
            }
            .searchable(text: $query, prompt: "Title or author")
            // File ▸ Open lands here: the menu cannot present a panel itself.
            .onChange(of: model.wantsImport) { _, wants in
                guard wants else { return }
                model.wantsImport = false
                importing = true
            }
            .navigationDestination(item: $opened) { book in
                BookDetailView(book: book)
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
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task {
                for url in urls { await model.importBook(from: url) }
            }
            return true
        }
    }

    @ViewBuilder
    private var content: some View {
        if let preparing = model.preparing {
            preparingState(preparing)
        } else if model.isLoading && model.books.isEmpty {
            ProgressView()
        } else if model.books.isEmpty {
            emptyShelf
        } else {
            shelf
        }
    }

    /// The first launch compiles the models for this machine; after that it is
    /// a moment. Slim enough to live inline rather than being its own screen.
    private func preparingState(_ progress: ChatterboxEngine.LoadProgress) -> some View {
        VStack(spacing: Palette.Space.md) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text("Getting the voice model ready")
                .font(.huiverHeading)
                .foregroundStyle(theme.colors.foreground)
            VStack(spacing: Palette.Space.xs) {
                ProgressView(value: progress.fraction)
                HStack {
                    Text("\(progress.model) · \(progress.index) of \(progress.total)")
                    Spacer()
                    if let since = model.preparingSince {
                        Text(since, style: .timer).monospacedDigit()
                    }
                }
                .font(.huiverCaption)
                .foregroundStyle(theme.colors.mutedForeground)
            }
            .frame(maxWidth: 360)
        }
        .padding(Palette.Space.xl)
    }

    private var emptyShelf: some View {
        VStack(spacing: Palette.Space.md) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.colors.mutedForeground)
            Text("No books yet")
                .font(.huiverHeading)
                .foregroundStyle(theme.colors.foreground)
            Text("Add an EPUB — or drop one on this window — and huiver will read it to you in a cloned voice, all on this Mac.")
                .font(.huiverBody)
                .foregroundStyle(theme.colors.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

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

    private var shelf: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Palette.Space.xl) {
                if query.isEmpty, let target = continueTarget {
                    continueRow(target)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: Palette.Space.lg)],
                    alignment: .leading,
                    spacing: Palette.Space.xl
                ) {
                    ForEach(shownBooks) { book in
                        Button { opened = book } label: { BookTile(book: book) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(Palette.Space.xl)
        }
    }

    /// The shelf, filtered by the search field and ordered by the sort menu.
    private var shownBooks: [Book] {
        var books = model.books
        if !query.isEmpty {
            let wanted = query.lowercased()
            books = books.filter {
                $0.title.lowercased().contains(wanted)
                    || ($0.author?.lowercased().contains(wanted) ?? false)
            }
        }
        switch Sort(rawValue: sortRaw) ?? .recent {
        case .recent:
            return books
        case .title:
            return books.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .author:
            return books.sorted {
                ($0.author ?? "").localizedCaseInsensitiveCompare($1.author ?? "")
                    == .orderedAscending
            }
        case .progress:
            return books.sorted { finishedFraction($0) > finishedFraction($1) }
        }
    }

    private func finishedFraction(_ book: Book) -> Double {
        guard !book.chapters.isEmpty else { return 0 }
        let finished = book.chapters.filter { model.isFinished($0) }.count
        return Double(finished) / Double(book.chapters.count)
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
    }

    private func resume(_ target: (book: Book, chapter: Chapter, position: Double)) {
        guard let narrator = model.narrator, let voice = model.voice(for: target.book) else {
            return
        }
        narrator.listen(
            book: target.book, chapter: target.chapter, voice: voice,
            options: model.options, from: target.position
        )
        navigation.showPlayer()
    }
}

private struct BookTile: View {
    let book: Book

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Palette.Space.sm) {
            BookCover(
                bookId: book.id,
                title: book.title,
                url: model.coverURL(for: book),
                width: 150,
                radius: Palette.Radius.lg
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.huiverLabel)
                    .foregroundStyle(theme.colors.foreground)
                    .lineLimit(2)
                if let author = book.author {
                    Text(author)
                        .font(.huiverCaption)
                        .foregroundStyle(theme.colors.mutedForeground)
                        .lineLimit(1)
                }
                Text(meta)
                    .font(.huiverCaption)
                    .foregroundStyle(theme.colors.mutedForeground)
            }
        }
        .frame(width: 150, alignment: .leading)
        .contentShape(.rect)
    }

    private var meta: String {
        let done = book.chapters.filter(\.isComplete).count
        return "\(done)/\(book.chapters.count) chapters"
    }
}
