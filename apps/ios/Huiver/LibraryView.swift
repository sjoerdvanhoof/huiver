import SwiftUI
import UniformTypeIdentifiers

/// The shelf. Cover, title, author, and how much of it has been rendered —
/// laid out as in `apps/mobile/app/index.tsx`, with the "Add a book" button
/// pinned to the bottom where a thumb reaches it.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.theme) private var theme

    @State private var importing = false
    @State private var showingPlayer = false
    /// The prepare screen can be put aside: adding a book works while the models
    /// are still compiling, even though playing one does not.
    @State private var preparingDismissed = false

    var body: some View {
        NavigationStack {
            ZStack {
                theme.colors.background.ignoresSafeArea()
                content
            }
            .navigationTitle("huiver")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottom }
        }
        .huiverTheme(scheme)
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
        }
    }

    private var shelf: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.books) { book in
                    NavigationLink {
                        BookView(book: book)
                    } label: {
                        BookRow(book: book)
                    }
                    .buttonStyle(.plain)

                    if book.id != model.books.last?.id {
                        Divider()
                            .overlay(theme.colors.border)
                            .padding(.leading, 56 + Palette.Space.lg * 2)
                    }
                }
            }
            .padding(.vertical, Palette.Space.sm)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private var bottom: some View {
        VStack(spacing: 0) {
            if let preparing = model.preparing, preparingDismissed {
                PreparingStrip(progress: preparing, since: model.preparingSince)
            }
            if model.narrator?.chapterId != nil {
                MiniPlayer { showingPlayer = true }
            }
            Button {
                importing = true
            } label: {
                Text("Add a book")
                    .font(.huiverHeading)
                    .foregroundStyle(theme.colors.primaryForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Palette.Space.md)
                    .background(theme.colors.primary, in: .rect(cornerRadius: Palette.Radius.xl))
            }
            .buttonStyle(.plain)
            .padding(Palette.Space.lg)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider().overlay(theme.colors.border) }
    }
}

private struct BookRow: View {
    let book: Book
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Palette.Space.lg) {
            BookCover(bookId: book.id, title: book.title)

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

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.colors.border)
        }
        .padding(.horizontal, Palette.Space.lg)
        .padding(.vertical, Palette.Space.md)
        .contentShape(.rect)
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
