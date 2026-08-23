import SwiftUI

/// The first-launch flow: the brand moment, then a recording front and
/// centre, with choosing a bundled voice as the escape at every step.
///
/// A state-driven pager rather than `TabView(.page)` on purpose — swiping past
/// the voice page mid-recording must be impossible. It runs concurrently with
/// `model.load()`: recording needs no engine, and a finished take is queued
/// through `AppModel.submitClone`, so nobody waits on the compile.
struct OnboardingView: View {
    let onFinished: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step = Step.welcome
    @State private var recorder = VoiceRecorder()
    @State private var preview = PreviewPlayer()
    @State private var recordedName: String?

    enum Step { case welcome, voice, choose, done }

    /// A previous install already chose a voice and compiled the models: one
    /// welcome page as a rebrand moment, and no nagging about recording.
    private var returning: Bool { model.hasPreparedBefore }

    var body: some View {
        ZStack {
            theme.colors.background.ignoresSafeArea()
            switch step {
            case .welcome: welcome.transition(pageTransition)
            case .voice: voice.transition(pageTransition)
            case .choose: choose.transition(pageTransition)
            case .done: done.transition(pageTransition)
            }
        }
        .overlay(alignment: .topTrailing) {
            if step == .voice || step == .choose {
                Button("Skip") { advance(to: .done) }
                    .font(.huiverLabel)
                    .foregroundStyle(theme.colors.mutedForeground)
                    .padding(Palette.Space.lg)
                    .disabled(recorder.state == .recording)
            }
        }
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

            Text("Narcisse clones your voice on this phone and reads any book back to you in it. Nothing leaves the device.")
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
        .padding(.horizontal, Palette.Space.xl)
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
        ScrollView {
            VStack(alignment: .leading, spacing: Palette.Space.xl) {
                Text("Read one passage. Keep your voice forever.")
                    .font(.huiverTitle)
                    .foregroundStyle(theme.colors.foreground)
                    .padding(.top, Palette.Space.xxl)

                VoiceRecordingFlow(
                    recorder: recorder,
                    submitLabel: "Use my voice",
                    busy: false,
                    failure: nil
                ) { samples, name in
                    // Queued, not awaited: the clone runs when the engine is
                    // ready and selects itself; onboarding moves on now.
                    let kept = name.isEmpty ? "My voice" : name
                    recordedName = kept
                    model.submitClone(samples: samples, name: kept)
                    advance(to: .done)
                }

                if recorder.state != .recording {
                    Button("Choose a voice instead") { advance(to: .choose) }
                        .font(.huiverLabel)
                        .foregroundStyle(theme.colors.mutedForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, Palette.Space.xxl)
                }
            }
            .padding(.horizontal, Palette.Space.xl)
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
                    ProgressView()
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
            }

            Text("You can record your own voice any time in Settings.")
                .font(.huiverCaption)
                .foregroundStyle(theme.colors.mutedForeground)

            primaryButton("Continue") { advance(to: .done) }
                .padding(.bottom, Palette.Space.xxl)
        }
        .padding(.horizontal, Palette.Space.xl)
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

            Text(doneMessage)
                .font(.huiverBody)
                .foregroundStyle(theme.colors.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Palette.Space.xxl)

            Spacer()

            WaterlineView(fraction: 0.7, resolvedAt: nil)
                .frame(height: 56)
                .padding(.horizontal, Palette.Space.xl)

            primaryButton("Open the library") { onFinished() }
                .padding(.bottom, Palette.Space.xxl)
        }
        .padding(.horizontal, Palette.Space.xl)
    }

    private var doneMessage: String {
        if recordedName != nil {
            return "Your voice is being prepared while the narrator warms up — "
                + "the gold waterline below the shelf shows the work. Add a book "
                + "in the meantime, and keep Narcisse open while it fills."
        }
        return "Add a book and Narcisse will read it to you."
    }

    // MARK: - Shared bits

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.huiverHeading)
                .foregroundStyle(theme.colors.primaryForeground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Palette.Space.md)
                .background(theme.colors.primary, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}
