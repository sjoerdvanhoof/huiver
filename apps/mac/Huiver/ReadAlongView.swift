import SwiftUI

/// The chapter's text, with the sentence being spoken lit up.
///
/// The Mac cut of the iOS ReadAlongView. Highlighting is per chunk, which is
/// roughly per sentence — word-level would mean forced alignment, a second
/// model on both devices, to gain something nobody asked for: the point is
/// following along, and knowing which sentence is being read is following
/// along.
///
/// It also reads perfectly well paused. Scrolling ahead does not drag the
/// audio with it, and clicking a sentence is how you go there.
struct ReadAlongView: View {
    let map: ChunkMap
    let currentIndex: Int?
    /// Chunks past this have no audio yet, so there is nothing to seek to.
    let renderedChunks: Int
    let seek: (Double) -> Void

    @Environment(\.theme) private var theme

    /// Suspends auto-scroll while someone is reading ahead by hand, and for a
    /// few seconds after they stop. Without it the view yanks itself back to
    /// the narrator mid-sentence, which makes reading ahead impossible.
    @State private var browsingUntil: Date?
    /// When the view last moved itself. The scroll-wheel is the only way this
    /// pane scrolls on a Mac, so the offset changing is how browsing is
    /// noticed — and the view's own animation must not count as browsing.
    @State private var lastAutoScroll: Date = .distantPast

    private var isBrowsing: Bool {
        guard let browsingUntil else { return false }
        return browsingUntil > Date()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Palette.Space.md) {
                    ForEach(map.chunks) { chunk in
                        Text(chunk.text)
                            .font(.body)
                            .lineSpacing(3)
                            .foregroundStyle(color(for: chunk))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Palette.Space.md)
                            .padding(.vertical, Palette.Space.sm)
                            .background(
                                chunk.index == currentIndex
                                    ? theme.colors.primary.opacity(0.14)
                                    : .clear,
                                in: .rect(cornerRadius: Palette.Radius.md)
                            )
                            .contentShape(.rect)
                            .onTapGesture {
                                guard chunk.index < renderedChunks else { return }
                                seek(chunk.start + 0.01)
                                // Clicking is a decision to follow again.
                                browsingUntil = nil
                            }
                            .id(chunk.index)
                    }
                }
                // A measure, not a phone width: lines the full window wide are
                // unreadable, and the highlight should not span half a metre.
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Palette.Space.lg)
                .padding(.horizontal, Palette.Space.lg)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { old, new in
                guard old != new,
                      Date().timeIntervalSince(lastAutoScroll) > 0.8
                else { return }
                browsingUntil = Date().addingTimeInterval(4)
            }
            .onChange(of: currentIndex) { _, new in
                guard let new, !isBrowsing else { return }
                lastAutoScroll = Date()
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
            .onAppear {
                guard let currentIndex else { return }
                lastAutoScroll = Date()
                proxy.scrollTo(currentIndex, anchor: .center)
            }
        }
    }

    private func color(for chunk: ChunkMap.Chunk) -> Color {
        if chunk.index == currentIndex { return theme.colors.foreground }
        // Not yet rendered: readable, but visibly not somewhere you can jump to.
        if chunk.index >= renderedChunks { return theme.colors.mutedForeground.opacity(0.55) }
        return theme.colors.mutedForeground
    }
}
