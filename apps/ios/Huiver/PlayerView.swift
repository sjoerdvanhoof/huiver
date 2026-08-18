import SwiftUI

/// The full player: art, title, a scrubber, transport, speed.
///
/// A port of `legacy/mobile/app/player.tsx`, with two differences that matter on
/// iOS. The scrubber is a real drag gesture rather than tap-to-seek, and it
/// stops at what has been rendered — seeking into audio that does not exist yet
/// is not a thing that can be done, so the track shows where the edge is instead
/// of letting you fall off it.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var dragging: Double?
    /// Swap the cover for the chapter's text.
    @State private var readingAlong = false
    /// The chunk texts and their times. Loaded when read-along is opened and
    /// when the chapter changes — reading the WAV headers for a whole chapter
    /// is not something to do four times a second.
    @State private var chunkMap = ChunkMap(chunks: [])

    var body: some View {
        ZStack {
            theme.colors.background.ignoresSafeArea()

            if let narrator = model.narrator, narrator.chapterId != nil {
                player(narrator)
            } else {
                Text("Nothing playing.")
                    .font(.huiverBody)
                    .foregroundStyle(theme.colors.mutedForeground)
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func player(_ narrator: Narrator) -> some View {
        VStack(spacing: Palette.Space.lg) {
            Spacer(minLength: 0)

            if readingAlong {
                ReadAlongView(
                    map: chunkMap,
                    currentIndex: chunkMap.index(at: dragging ?? narrator.position),
                    renderedChunks: narrator.renderedChunks,
                    seek: { narrator.seek(to: $0) }
                )
                .frame(maxHeight: .infinity)
            } else if let book = narrator.book {
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
        .padding(.horizontal, Palette.Space.xl)
        .padding(.vertical, Palette.Space.xl)
        // The map is rebuilt when the chapter changes, and again as synthesis
        // extends it — a chunk with no file yet has no duration, so every
        // chunk after it would otherwise sit at the wrong time.
        .task(id: narrator.chapterId) { await loadChunkMap() }
        .task(id: narrator.renderedChunks) { await loadChunkMap() }
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
                .contentShape(.rect.inset(by: -14))
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

    /// What the scrubber says about the part of the chapter that does not exist
    /// yet. Three different situations, and the middle one is the common one that
    /// used to look like a bug: locking the phone stops Core ML dead, so
    /// synthesis dies within seconds and only what was already rendered plays.
    private func footnote(_ narrator: Narrator) -> String {
        if narrator.isReloadingModels {
            return "Loading the model again — it stops working once the screen has been locked, and has to be replaced rather than restarted."
        }
        if narrator.renderFailure != nil {
            return "Reading stopped at \(Format.duration(narrator.renderedSeconds)) — the model cannot run with the screen locked. It carries on from here now that you are back."
        }
        if narrator.state == .preparing { return "Reading ahead…" }
        return "Rendered up to \(Format.duration(narrator.renderedSeconds)) — synthesis pauses if you leave the app with nothing playing."
    }

    // MARK: - Transport

    private func transport(_ narrator: Narrator) -> some View {
        HStack {
            Button { narrator.changeChapter(by: -1) } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(!narrator.hasPreviousChapter)

            Spacer()
            Button { narrator.skip(by: -15) } label: {
                Image(systemName: "gobackward.15")
            }

            Spacer()
            Button {
                narrator.state == .speaking ? narrator.pause() : narrator.resume()
            } label: {
                Image(systemName: narrator.state == .speaking ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(theme.colors.primaryForeground)
                    .frame(width: 64, height: 64)
                    .background(theme.colors.primary, in: .circle)
            }
            .disabled(narrator.state == .preparing)

            Spacer()
            Button { narrator.skip(by: 30) } label: {
                Image(systemName: "goforward.30")
            }

            Spacer()
            Button { narrator.changeChapter(by: 1) } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(!narrator.hasNextChapter)
        }
        .font(.title3)
        .foregroundStyle(theme.colors.foreground)
        .buttonStyle(.plain)
        .padding(.top, Palette.Space.sm)
    }

    /// Speed, and a way out. There is no sleep timer yet — the Expo app has one,
    /// and it belongs here too, but it needs playback to end cleanly on a timer
    /// rather than just stopping.
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

            sleepMenu

            Button {
                readingAlong.toggle()
            } label: {
                Image(systemName: readingAlong ? "text.quote" : "text.alignleft")
                    .font(.huiverLabel)
                    .foregroundStyle(
                        readingAlong ? theme.colors.primary : theme.colors.foreground
                    )
                    .padding(.horizontal, Palette.Space.md)
                    .padding(.vertical, Palette.Space.xs)
                    .background(theme.colors.muted, in: .capsule)
            }
            .buttonStyle(.plain)
            .padding(.leading, Palette.Space.sm)
            .accessibilityLabel(readingAlong ? "Show the cover" : "Read along")

            Spacer()

            Button("Stop", role: .destructive) {
                narrator.stop()
                dismiss()
            }
            .font(.huiverLabel)
            .foregroundStyle(theme.colors.destructive)
        }
        .padding(.top, Palette.Space.sm)
    }

    /// Stop reading after a while. In the app only: there is no lock-screen
    /// control for a sleep timer to attach to.
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
        .padding(.leading, Palette.Space.sm)
    }
}
