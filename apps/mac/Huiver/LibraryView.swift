import SwiftUI
import UniformTypeIdentifiers

/// The shelf, as a grid of covers — a Mac window has the width for it that a
/// phone does not. Books arrive through the open panel or by dropping an EPUB
/// anywhere on the grid.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var importing = false
    /// The book being pushed, driving navigation in place of a link.
    @State private var opened: Book?

    var body: some View {
        NavigationStack {
            ZStack {
                theme.colors.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: {
                        Label("Add a book", systemImage: "plus")
                    }
                }
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
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: Palette.Space.lg)],
                alignment: .leading,
                spacing: Palette.Space.xl
            ) {
                ForEach(model.books) { book in
                    Button { opened = book } label: { BookTile(book: book) }
                        .buttonStyle(.plain)
                }
            }
            .padding(Palette.Space.xl)
        }
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
