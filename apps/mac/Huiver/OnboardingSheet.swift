import SwiftUI

/// The first-launch flow, as a sheet over the main window: the brand moment,
/// then recording front and centre, with choosing a bundled voice as the
/// escape at every step. Mirrors `apps/ios/Huiver/OnboardingView.swift` —
/// except the Mac clones synchronously, because its `AppModel` holds a loaded
/// cloner from early in `load()` and does not need a queue.
struct OnboardingSheet: View {
    let onFinished: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step = Step.welcome
    @State private var preview = PreviewPlayer()

    enum Step { case welcome, voice, choose, done }

    /// A previous install already chose a voice and compiled the models: one
    /// welcome page as a rebrand moment, and no nagging about recording.
    private var returning: Bool { model.hasPreparedBefore }

    var body: some View {
        ZStack {
            theme.colors.background
            switch step {
            case .welcome: welcome.transition(pageTransition)
            case .voice: voice.transition(pageTransition)
            case .choose: choose.transition(pageTransition)
            case .done: done.transition(pageTransition)
            }
        }
        .frame(width: 620)
        .frame(minHeight: 460)
        .overlay(alignment: .topTrailing) {
            if step == .voice || step == .choose {
                Button("Skip") { advance(to: .done) }
                    .buttonStyle(.plain)
                    .font(.huiverLabel)
                    .foregroundStyle(theme.colors.mutedForeground)
                    .padding(Palette.Space.lg)
            }
        }
        .interactiveDismissDisabled()
    }

    private var pageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            )
    }

    private func advance(to next: Step) {
        preview.stop()
        withAnimation(.easeInOut) { step = next }
    }

    // MARK: - Welcome

    private var welcome: some View {
        VStack(spacing: Palette.Space.lg) {
            Spacer()

            wordmark

            Text("Every book. Your voice.")
                .font(.huiverTitle)
                .foregroundStyle(theme.colors.foreground)

            Text("Narcisse clones your voice on this Mac and reads any book back to you in it. Nothing leaves the machine.")
                .font(.huiverBody)
                .foregroundStyle(theme.colors.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Palette.Space.xxl)

            Spacer()

            primaryButton(returning ? "Continue" : "Begin") {
                if returning {
                    onFinished()
                } else if model.canCloneVoices {
                    advance(to: .voice)
                } else {
                    advance(to: .choose)
                }
            }
            .padding(.bottom, Palette.Space.xxl)
        }
        .padding(.horizontal, Palette.Space.xxl)
    }

    /// The name over its own reflection: the myth, in one image.
    private var wordmark: some View {
        VStack(spacing: 0) {
            Text("Narcisse")
                .font(.system(.largeTitle, design: .serif, weight: .semibold))
                .foregroundStyle(theme.colors.foreground)

            Rectangle()
                .fill(theme.colors.primary.opacity(0.5))
                .frame(height: 1)
                .padding(.vertical, Palette.Space.xs)

            Text("Narcisse")
                .font(.system(.largeTitle, design: .serif, weight: .semibold))
                .foregroundStyle(theme.colors.foreground)
                .scaleEffect(y: -1)
                .opacity(0.25)
                .mask {
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .background {
                    WaterlineView(fraction: 0.5, resolvedAt: nil)
                        .opacity(0.6)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Narcisse")
    }

    // MARK: - Your voice

    private var voice: some View {
        VStack(alignment: .leading, spacing: Palette.Space.md) {
            Text("Read one passage. Keep your voice forever.")
                .font(.huiverTitle)
                .foregroundStyle(theme.colors.foreground)
                .padding(.top, Palette.Space.xxl)
                .padding(.horizontal, Palette.Space.xl)

            VoiceCaptureView(
                onDone: { _ in advance(to: .done) },
                onCancel: { advance(to: .choose) }
            )

            Button("Choose a voice instead") { advance(to: .choose) }
                .buttonStyle(.plain)
                .font(.huiverLabel)
                .foregroundStyle(theme.colors.mutedForeground)
                .frame(maxWidth: .infinity)
                .padding(.bottom, Palette.Space.xl)
        }
    }

    // MARK: - Choose a bundled voice

    private var choose: some View {
        VStack(alignment: .leading, spacing: Palette.Space.lg) {
            Text("Choose a narrator")
                .font(.huiverTitle)
                .foregroundStyle(theme.colors.foreground)
                .padding(.top, Palette.Space.xxl)

            if model.voices.isEmpty {
                HStack(spacing: Palette.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Fetching the bundled voices…")
                        .font(.huiverBody)
                        .foregroundStyle(theme.colors.mutedForeground)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.voices) { voice in
                            voiceRow(voice)
                            Divider().overlay(theme.colors.border)
                        }
                    }
                    .background(theme.colors.card, in: .rect(cornerRadius: Palette.Radius.lg))
                }
                .frame(maxHeight: 280)
            }

            Text("You can record your own voice any time from the Voices screen.")
                .font(.huiverCaption)
                .foregroundStyle(theme.colors.mutedForeground)

            primaryButton("Continue") { advance(to: .done) }
                .padding(.bottom, Palette.Space.xl)
        }
        .padding(.horizontal, Palette.Space.xxl)
    }

    private func voiceRow(_ voice: Voice) -> some View {
        HStack(spacing: Palette.Space.md) {
            if let url = voice.previewURL {
                Button {
                    preview.toggle(url, id: voice.id)
                } label: {
                    Image(systemName: preview.playing == voice.id
                        ? "stop.circle.fill" : "play.circle")
                        .font(.title2)
                        .foregroundStyle(theme.colors.primary)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "play.circle")
                    .font(.title2)
                    .foregroundStyle(theme.colors.border)
            }

            Button {
                // No re-render confirmation here: nothing exists to re-render.
                model.selectedVoiceId = voice.id
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.name).foregroundStyle(theme.colors.foreground)
                        Text(voice.detail)
                            .font(.huiverCaption)
                            .foregroundStyle(theme.colors.mutedForeground)
                    }
                    Spacer()
                    if model.selectedVoiceId == voice.id {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(Palette.Space.md)
    }

    // MARK: - Done

    private var done: some View {
        VStack(spacing: Palette.Space.lg) {
            Spacer()

            Text("The pool is ready.")
                .font(.huiverTitle)
                .foregroundStyle(theme.colors.foreground)

            Text("Add a book and Narcisse will read it to you. The gold waterline under the window shows the narrator warming up.")
                .font(.huiverBody)
                .foregroundStyle(theme.colors.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Palette.Space.xxl)

            Spacer()

            WaterlineView(fraction: 0.7, resolvedAt: nil)
                .frame(height: 44)
                .padding(.horizontal, Palette.Space.xl)

            primaryButton("Open the library") { onFinished() }
                .padding(.bottom, Palette.Space.xxl)
        }
        .padding(.horizontal, Palette.Space.xxl)
    }

    // MARK: - Shared bits

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.huiverHeading)
                .foregroundStyle(theme.colors.primaryForeground)
                .frame(maxWidth: 280)
                .padding(.vertical, Palette.Space.md)
                .background(theme.colors.primary, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}
