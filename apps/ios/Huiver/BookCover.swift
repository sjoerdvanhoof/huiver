import SwiftUI

/// A book's cover: the image out of the EPUB when it had one, and the
/// deterministic gradient when it did not.
///
/// The gradient hash comes from `packages/shared/src/cover.ts`, so a book
/// without artwork is the same colour here as in the browser and in the Expo
/// app. Proportions are 2:3, the shape of a paperback; a real cover is filled to
/// that frame rather than letterboxed, since a strip of background around a
/// slightly-off aspect ratio looks worse than a few cropped pixels.
struct BookCover: View {
    let bookId: String
    let title: String
    var url: URL?
    var width: CGFloat = 56
    var radius: CGFloat = Palette.Radius.md

    /// Held so the image survives a redraw. `CoverImages` is the cache; this is
    /// what tells SwiftUI the load has finished.
    @State private var loaded: Image?

    private var height: CGFloat { width * 1.5 }

    var body: some View {
        Group {
            // The cache is consulted in the body as well as in the task, so a
            // cover already decoded draws immediately instead of showing a
            // frame of gradient every time a row scrolls back into view.
            if let image = loaded ?? url.flatMap(CoverImages.cached) {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: radius))
        // A hairline and a soft shadow give a flat cover enough edge to read as
        // an object on the shelf rather than a coloured rectangle.
        .overlay {
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: width * 0.06, y: width * 0.03)
        .accessibilityHidden(true)
        // Keyed on the URL, so it runs once per cover rather than once per
        // redraw — which is the whole point, see `CoverImages`.
        .task(id: url) {
            guard let url else {
                loaded = nil
                return
            }
            loaded = await CoverImages.image(at: url)
        }
    }

    private var placeholder: some View {
        let (from, to) = Cover.gradient(for: bookId)
        return LinearGradient(
            colors: [Palette.hex(from), Palette.hex(to)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Text(Cover.initial(for: title))
                .font(.system(size: width * 0.5, weight: .light, design: .serif))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

/// Covers, decoded once and kept.
///
/// `AsyncImage` is the obvious way to show these and it cannot be used here.
/// Every cover is a local file, but `AsyncImage` restarts its load whenever the
/// view is rebuilt — and the mini player and the player are rebuilt **four
/// times a second** while a chapter plays, because the playhead moves and they
/// are drawn from it. At that rate the load never reaches `.success`, so the
/// only thing either of them ever showed was the fallback gradient, for books
/// with a perfectly good cover sitting on disk. The library rows, redrawn
/// rarely, looked fine — which is why it read as "the player is broken" rather
/// than "`AsyncImage` is the wrong tool".
///
/// `NSCache` rather than a dictionary so a large library does not hold every
/// cover it has ever scrolled past; the cost of a miss is reading one small
/// file again.
@MainActor
enum CoverImages {
    private static let cache = NSCache<NSURL, UIImage>()

    /// The decoded cover, if this one has been read already.
    static func cached(_ url: URL) -> Image? {
        cache.object(forKey: url as NSURL).map(Image.init(uiImage:))
    }

    /// The decoded cover, reading it if this is the first ask.
    static func image(at url: URL) async -> Image? {
        if let hit = cached(url) { return hit }
        // Off the main actor: most covers are tens of kilobytes, but an EPUB is
        // entitled to ship a megabyte of artwork and the player is animating.
        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value
        guard let data, let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return Image(uiImage: image)
    }
}
