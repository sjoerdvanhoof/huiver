import SwiftUI

/// The chapter's text, with the sentence being spoken lit up.
///
/// Highlighting is per chunk, which is roughly per sentence. Word-level would
/// mean forced alignment — a second model, on both devices, for all 23
/// languages — to gain something nobody asked for: the point is following
/// along, and knowing which sentence is being read is following along.
///
/// It also reads perfectly well paused, which is the other half of what this is
/// for. Scrolling ahead does not drag the audio with it, and tapping a sentence
/// is how you go there.
struct ReadAlongView: View {
    let map: ChunkMap
    let currentIndex: Int?
    /// Chunks past this have no audio yet, so there is nothing to seek to.
    let renderedChunks: Int
    let seek: (Double) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Suspends auto-scroll while someone is reading ahead by hand, and for a
    /// few seconds after they stop. Without it the view yanks itself back to
    /// the narrator mid-sentence, which makes reading ahead impossible.
    @State private var browsingUntil: Date?

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
                            .font(.huiverBody)
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
                                // Tapping is a decision to follow again.
                                browsingUntil = nil
                            }
                            .id(chunk.index)
                    }
                }
                .padding(.vertical, Palette.Space.md)
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in
                    browsingUntil = Date().addingTimeInterval(4)
                }
            )
            .onChange(of: currentIndex) { _, new in
                guard let new, !isBrowsing else { return }
                // Reduce Motion means what it says — jump, do not glide.
                if reduceMotion {
                    proxy.scrollTo(new, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
            .onAppear {
                guard let currentIndex else { return }
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
