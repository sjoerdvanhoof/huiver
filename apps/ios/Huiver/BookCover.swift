import SwiftUI

/// A book's cover: the deterministic gradient and initial from `Cover`.
///
/// The hash comes from `packages/shared/src/cover.ts`, so a book is the same
/// colour here as in the browser and in the Expo app. Proportions are 2:3, the
/// shape of a paperback.
struct BookCover: View {
    let bookId: String
    let title: String
    var width: CGFloat = 56
    var radius: CGFloat = Palette.Radius.md

    private var gradient: LinearGradient {
        let (from, to) = Cover.gradient(for: bookId)
        return LinearGradient(
            colors: [Palette.hex(from), Palette.hex(to)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        gradient
            .frame(width: width, height: width * 1.5)
            .overlay {
                Text(Cover.initial(for: title))
                    .font(.system(size: width * 0.5, weight: .light, design: .serif))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .clipShape(.rect(cornerRadius: radius))
            // A hairline and a soft shadow give the flat gradient enough edge to
            // read as an object on the shelf rather than a coloured rectangle.
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: width * 0.06, y: width * 0.03)
            .accessibilityHidden(true)
    }
}
