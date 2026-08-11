import Foundation
import Observation

/// Everything the screens share: the library, the engine, the voice list.
///
/// The engine is loaded lazily and its failure is kept rather than thrown, so
/// an app whose models have not been exported yet still opens and explains
/// itself instead of crashing on launch.
@MainActor
@Observable
final class AppModel {
    private(set) var books: [Book] = []
    private(set) var voices: [Voice] = []
    private(set) var narrator: Narrator?
    private(set) var loadFailure: String?
    private(set) var isLoading = true
    private(set) var bytesOnDisk: Int64 = 0

    /// What the engine is doing while it loads, for the preparing screen.
    /// Which processor Core ML gave each model, shown in Settings.
    private(set) var placement: [String: String] = [:]
    private(set) var preparing: ChatterboxEngine.LoadProgress?
    private(set) var preparingSince: Date?
    /// True on the run that actually compiles the models, which is the slow one
    /// worth explaining. Set once the first load finishes.
    var hasPreparedBefore: Bool {
        UserDefaults.standard.bool(forKey: "preparedOnce")
    }

    var options = SamplingOptions()
    var selectedVoiceId: String {
        didSet { UserDefaults.standard.set(selectedVoiceId, forKey: "voice") }
    }

    var selectedVoice: Voice? {
        voices.first { $0.id == selectedVoiceId } ?? voices.first
    }

    private var library: Library?

    init() {
        selectedVoiceId = UserDefaults.standard.string(forKey: "voice") ?? "nano_default"
    }

    /// The models and voices are bundled with the app, and the library lives in
    /// Documents so it survives an update and shows up in the Files app.
    func load() async {
        isLoading = true
        defer { isLoading = false }

        let documents = URL.documentsDirectory
        do {
            let library = try Library(root: documents)
            self.library = library
            books = await library.all()
            bytesOnDisk = await library.bytesOnDisk()
        } catch {
            loadFailure = "Could not open the library: \(error.localizedDescription)"
            return
        }

        guard let resources = Bundle.main.resourceURL else {
            loadFailure = "No resources in the app bundle"
            return
        }

        do {
            voices = try VoicePack.load(from: resources.appendingPathComponent("Voices"))
        } catch {
            loadFailure = error.localizedDescription
            return
        }

        preparingSince = Date()
        do {
            let engine = try await ChatterboxEngine.load(
                models: .init(directory: resources.appendingPathComponent("Models"))
            ) { [weak self] progress in
                Task { @MainActor in self?.preparing = progress }
            }
            narrator = Narrator(engine: engine, library: library!)
            placement = engine.placement
            UserDefaults.standard.set(true, forKey: "preparedOnce")
        } catch {
            loadFailure = error.localizedDescription
        }
        preparing = nil
        preparingSince = nil
    }

    func importBook(from url: URL) async {
        guard let library else { return }
        // A file handed over by the document picker lives outside the sandbox
        // until it is read, and the scope has to be given back afterwards.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let extracted = try Extract.book(from: data, filename: url.lastPathComponent)
            _ = try await library.add(extracted)
            books = await library.all()
        } catch {
            loadFailure = error.localizedDescription
        }
    }

    func delete(_ book: Book) async {
        guard let library else { return }
        if narrator?.chapterId != nil, book.chapters.contains(where: { $0.id == narrator?.chapterId }) {
            narrator?.stop()
        }
        try? await library.remove(book.id)
        books = await library.all()
        bytesOnDisk = await library.bytesOnDisk()
    }

    func refresh() async {
        guard let library else { return }
        books = await library.all()
        bytesOnDisk = await library.bytesOnDisk()
    }

    func clearFailure() { loadFailure = nil }
}
