import SwiftUI

/// The full player: art, title, a scrubber, transport, speed, sleep timer —
/// with the chapter's text reading along beside it.
///
/// The Mac cut of the iOS PlayerView. On the phone the cover and the text
/// trade places; a Mac window has the width to show both, so read-along is a
/// pane rather than a mode. The scrubber is a real drag and stops at what has
/// been rendered — seeking into audio that does not exist yet is not a thing
/// that can be done, so the track shows where the edge is instead of letting
/// you fall off it.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var dragging: Double?
    /// The chunk texts and their times. Loaded when the chapter changes and as
    /// synthesis extends it — reading the WAV headers for a whole chapter is
    /// not something to do four times a second.
    @State private var chunkMap = ChunkMap(chunks: [])

    var body: some View {
        ZStack {
            theme.colors.background.ignoresSafeArea()

            if let narrator = model.narrator, narrator.chapterId != nil {
                player(narrator)
            } else {
                empty
            }
        }
        .navigationTitle("Now Playing")
    }

    private var empty: some View {
        VStack(spacing: Palette.Space.sm) {
            Image(systemName: "play.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.colors.mutedForeground)
            Text("Nothing playing")
                .font(.huiverLabel)
                .foregroundStyle(theme.colors.foreground)
            Text("Play a chapter from its book and it will appear here.")
                .font(.huiverCaption)
                .foregroundStyle(theme.colors.mutedForeground)
                .multilineTextAlignment(.center)
        }
        .padding(Palette.Space.xl)
    }

    private func player(_ narrator: Narrator) -> some View {
        HStack(spacing: 0) {
            controls(narrator)
                .frame(width: 340)
                .padding(Palette.Space.xl)
                .frame(maxHeight: .infinity)

            Divider().overlay(theme.colors.border)

            ReadAlongView(
                map: chunkMap,
                currentIndex: chunkMap.index(at: dragging ?? narrator.position),
                renderedChunks: narrator.renderedChunks,
                seek: { narrator.seek(to: $0) }
            )
            .frame(maxWidth: .infinity)
        }
        // The map is rebuilt when the chapter changes, and again as synthesis
        // extends it — a chunk with no file yet has no duration, so every
        // chunk after it would otherwise sit at the wrong time.
        .task(id: narrator.chapterId) { await loadChunkMap() }
        .task(id: narrator.renderedChunks) { await loadChunkMap() }
    }

    private func controls(_ narrator: Narrator) -> some View {
        VStack(spacing: Palette.Space.lg) {
            Spacer(minLength: 0)

            if let book = narrator.book {
                BookCover(
                    bookId: book.id,
                    title: book.title,
                    url: model.coverURL(for: book),
                    width: 190,
                    radius: Palette.Radius.xl
                )
            }

            VStack(spacing: Palette.Space.xs) {
                Text(narrator.chapterTitle)
                    .font(.huiverTitle)
                    .foregroundStyle(theme.colors.foreground)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(subtitle(narrator))
                    .font(.huiverBody)
                    .foregroundStyle(theme.colors.mutedForeground)
                    .lineLimit(1)
            }

            scrubber(narrator)
            transport(narrator)
            extras(narrator)

            Spacer(minLength: 0)
        }
    }

    private func loadChunkMap() async {
        guard let narrator = model.narrator, let book = narrator.book,
              let chapter = narrator.chapter, let library = model.library
        else { return }
        chunkMap = ChunkMap.load(book: book, chapter: chapter, library: library)
    }

    private func subtitle(_ narrator: Narrator) -> String {
        guard let book = narrator.book else { return "" }
        return [book.title, book.author].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Scrubber

    private func scrubber(_ narrator: Narrator) -> some View {
        let total = max(narrator.estimatedDuration, 1)
        let shown = dragging ?? narrator.position

        return VStack(spacing: Palette.Space.xs) {
            GeometryReader { geometry in
                TwoStageBar(
                    played: shown / total,
                    rendered: narrator.renderedSeconds / total,
                    height: 6
                )
                .contentShape(.rect.inset(by: -10))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = min(1, max(0, value.location.x / geometry.size.width))
                            // Clamped to what exists: dragging past the rendered
                            // edge should stop there rather than seek nowhere.
                            dragging = min(fraction * total, narrator.renderedSeconds)
                        }
                        .onEnded { _ in
                            if let target = dragging { narrator.seek(to: target) }
                            dragging = nil
                        }
                )
            }
            .frame(height: 6)

            HStack {
                Text(Format.duration(shown))
                Spacer()
                Text("\(narrator.isFullyRendered ? "" : "~")\(Format.duration(narrator.estimatedDuration))")
            }
            .font(.huiverCaption)
            .monospacedDigit()
            .foregroundStyle(theme.colors.mutedForeground)

            if !narrator.isFullyRendered {
                Text(footnote(narrator))
                    .font(.huiverCaption)
                    .foregroundStyle(theme.colors.mutedForeground)
                    .multilineTextAlignment(.center)
                    .padding(.top, Palette.Space.xs)
            }
        }
    }

    /// What the scrubber says about the part of the chapter that does not
    /// exist yet — the track ahead is not unbuffered, it is unwritten.
    private func footnote(_ narrator: Narrator) -> String {
        if narrator.isReloadingModels {
            return "Loading the model again…"
        }
        if let failure = narrator.renderFailure {
            return "Synthesis stopped at \(Format.duration(narrator.renderedSeconds)) — \(failure)"
        }
        if narrator.state == .preparing { return "Reading ahead…" }
        return "Rendered up to \(Format.duration(narrator.renderedSeconds)) — the scrubber stops at what exists."
    }

    // MARK: - Transport

    private func transport(_ narrator: Narrator) -> some View {
        HStack {
            Button { narrator.changeChapter(by: -1) } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(!narrator.hasPreviousChapter)
            .help("Previous chapter")

            Spacer()
            Button { narrator.skip(by: -15) } label: {
                Image(systemName: "gobackward.15")
            }
            .help("Back 15 seconds")

            Spacer()
            Button {
                narrator.state == .speaking ? narrator.pause() : narrator.resume()
            } label: {
                Image(systemName: narrator.state == .speaking ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.colors.primaryForeground)
                    .frame(width: 56, height: 56)
                    .background(theme.colors.primary, in: .circle)
            }
            .disabled(narrator.state == .preparing)

            Spacer()
            Button { narrator.skip(by: 30) } label: {
                Image(systemName: "goforward.30")
            }
            .help("Forward 30 seconds")

            Spacer()
            Button { narrator.changeChapter(by: 1) } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(!narrator.hasNextChapter)
            .help("Next chapter")
        }
        .font(.title3)
        .foregroundStyle(theme.colors.foreground)
        .buttonStyle(.plain)
        .padding(.top, Palette.Space.sm)
    }

    /// Speed, sleep, and a way out.
    private func extras(_ narrator: Narrator) -> some View {
        HStack {
            Menu {
                // The model has no speed control of its own, so this is the
                // player stretching time — pitch-corrected, so it still sounds
                // like the same narrator.
                ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                    Button {
                        narrator.rate = Float(rate)
                    } label: {
                        if abs(Double(narrator.rate) - rate) < 0.01 {
                            Label("\(rate.formatted())×", systemImage: "checkmark")
                        } else {
                            Text("\(rate.formatted())×")
                        }
                    }
                }
            } label: {
                Text("\(Double(narrator.rate).formatted())×")
                    .font(.huiverLabel)
                    .foregroundStyle(theme.colors.foreground)
                    .padding(.horizontal, Palette.Space.md)
                    .padding(.vertical, Palette.Space.xs)
                    .background(theme.colors.muted, in: .capsule)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            sleepMenu

            Spacer()

            // Playing an unrendered chapter is also converting it, so while
            // synthesis is still writing, this stops that too — and says so.
            Button(narrator.isFullyRendered ? "Stop" : "Stop conversion", role: .destructive) {
                narrator.stop()
            }
            .buttonStyle(.plain)
            .font(.huiverLabel)
            .foregroundStyle(theme.colors.destructive)
        }
        .padding(.top, Palette.Space.sm)
    }

    /// Stop reading after a while — the timer itself lives on the AppModel so
    /// it outlives this pane.
    private var sleepMenu: some View {
        Menu {
            if model.sleepTimer.isArmed {
                Button("Off", systemImage: "xmark") { model.sleepTimer.cancel() }
            }
            ForEach(SleepTimer.presets, id: \.self) { preset in
                Button {
                    model.sleepTimer.start(preset)
                } label: {
                    if model.sleepTimer.mode == preset {
                        Label(preset.label, systemImage: "checkmark")
                    } else {
                        Text(preset.label)
                    }
                }
            }
        } label: {
            HStack(spacing: Palette.Space.xs) {
                Image(systemName: model.sleepTimer.isArmed ? "moon.zzz.fill" : "moon.zzz")
                if let remaining = model.sleepTimer.remaining {
                    Text(Format.duration(remaining))
                } else if model.sleepTimer.mode == .endOfChapter {
                    Text("chapter")
                }
            }
            .font(.huiverLabel)
            .foregroundStyle(
                model.sleepTimer.isArmed ? theme.colors.primary : theme.colors.foreground
            )
            .padding(.horizontal, Palette.Space.md)
            .padding(.vertical, Palette.Space.xs)
            .background(theme.colors.muted, in: .capsule)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.leading, Palette.Space.sm)
        .help("Stop reading after a while")
    }
}
