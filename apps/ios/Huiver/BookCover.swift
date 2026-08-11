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

    private var height: CGFloat { width * 1.5 }

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        // Shown while loading and if the file has gone missing.
                        placeholder
                    }
                }
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
