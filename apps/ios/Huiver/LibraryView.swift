import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    /// The prepare screen can be put aside: adding a book works while the
    /// models are still compiling, even though playing one does not.
    @State private var preparingDismissed = false

    var body: some View {
        NavigationStack {
            Group {
                if let preparing = model.preparing, !preparingDismissed {
                    VStack(spacing: 18) {
                        PreparingView(
                            progress: preparing,
                            since: model.preparingSince,
                            firstRun: !model.hasPreparedBefore
                        )
                        Button("Add a book while you wait") { preparingDismissed = true }
                            .font(.callout)
                    }
                } else if model.isLoading && model.books.isEmpty {
                    ProgressView("Opening the library")
                } else if model.books.isEmpty {
                    emptyShelf
                } else {
                    shelf
                }
            }
            .navigationTitle("huiver")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Image(systemName: "plus") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    // Once the prepare screen is put aside, the work still needs
                    // to be visible somewhere — otherwise a play button that
                    // does nothing looks broken rather than not-ready-yet.
                    if let preparing = model.preparing, preparingDismissed {
                        VStack(spacing: 4) {
                            ProgressView(value: preparing.fraction).tint(.accentColor)
                            HStack {
                                Text("Getting the voice model ready · \(preparing.model)")
                                Spacer()
                                if let since = model.preparingSince {
                                    Text(since, style: .timer).monospacedDigit()
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                    }
                    MiniPlayer()
                }
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

    private var emptyShelf: some View {
        ContentUnavailableView {
            Label("No books yet", systemImage: "books.vertical")
        } description: {
            Text("Add an EPUB, or a plain text file, and huiver will read it to you in a cloned voice — all on this phone.")
        } actions: {
            Button("Add a book") { importing = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var shelf: some View {
        List {
            ForEach(model.books) { book in
                NavigationLink {
                    BookView(book: book)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.title).font(.headline)
                        Text(subtitle(for: book))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .onDelete { offsets in
                let doomed = offsets.map { model.books[$0] }
                Task { for book in doomed { await model.delete(book) } }
            }
        }
        .refreshable { await model.refresh() }
    }

    private func subtitle(for book: Book) -> String {
        let done = book.chapters.filter(\.isComplete).count
        var parts: [String] = []
        if let author = book.author { parts.append(author) }
        parts.append("\(book.chapters.count) chapters")
        if done > 0 { parts.append("\(done) rendered") }
        return parts.joined(separator: " · ")
    }
}
