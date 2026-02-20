import SwiftUI

struct AssistantView: View {
    @ObservedObject var model: AssistantCoordinator

    @State private var previousState: AssistantState = .idle
    @State private var showListeningWave = false
    @State private var waveRevealTask: Task<Void, Never>?

    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.80, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    private let speakingAnimation = Animation.spring(response: 0.40, dampingFraction: 0.84, blendDuration: 0)

    private var textAnimation: Animation {
        .easeOut(duration: 0.18)
    }

    private var notchAnimation: Animation {
        switch model.state {
        case .idle:
            closeAnimation
        case .listening:
            openAnimation
        case .speaking:
            speakingAnimation
        }
    }

    private var closedSize: CGSize {
        model.closedNotchSize
    }

    private var currentNotchSize: CGSize {
        AssistantLayoutMetrics.size(for: model.state, closedSize: closedSize)
    }

    private var clipShape: NotchShape {
        switch model.state {
        case .idle, .listening:
            NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
        case .speaking:
            NotchShape(topCornerRadius: 19, bottomCornerRadius: 24)
        }
    }

    private var topCornerRadius: CGFloat {
        switch model.state {
        case .idle, .listening:
            6
        case .speaking:
            19
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            content
                .frame(
                    width: currentNotchSize.width,
                    height: currentNotchSize.height,
                    alignment: .topLeading
                )
                .background(Color.black)
                .clipShape(clipShape)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.black)
                        .frame(height: 2)
                        .offset(y: -0.5)
                        .padding(.horizontal, topCornerRadius)
                }
                .overlay(strokeOverlay)
                .animation(textAnimation, value: model.liveTranscript)
                .animation(textAnimation, value: model.speakingText)
                .animation(notchAnimation, value: model.state)
        }
        .frame(
            width: AssistantLayoutMetrics.canvasSize.width,
            height: AssistantLayoutMetrics.canvasSize.height,
            alignment: .top
        )
        .onAppear {
            previousState = model.state
            showListeningWave = model.state == .listening
        }
        .onDisappear {
            waveRevealTask?.cancel()
        }
        .onChange(of: model.state) { newState in
            let oldState = previousState
            previousState = newState
            handleStateTransition(from: oldState, to: newState)
        }
    }

    @ViewBuilder
    private var strokeOverlay: some View {
        if model.state == .idle {
            EmptyView()
        } else {
            clipShape.stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            Color.clear
                .frame(width: closedSize.width, height: closedSize.height)

        case .listening:
            HStack(spacing: 0) {
                HStack {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.leading, 18)

                Spacer(minLength: 0)

                ListeningEqualizer()
                    .opacity(showListeningWave ? 1 : 0)
                    .scaleEffect(showListeningWave ? 1 : 0.72, anchor: .trailing)
                    .offset(x: showListeningWave ? 0 : 8)
                    .padding(.trailing, 18)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .center)))

        case .speaking:
            VStack(alignment: .leading, spacing: 12) {
                Text("Speaking")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))

                Text(displayText)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .center)))
        }
    }

    private var displayText: String {
        let text = model.speakingText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "…" : text
    }

    private func handleStateTransition(from oldState: AssistantState, to newState: AssistantState) {
        waveRevealTask?.cancel()

        switch newState {
        case .idle:
            showListeningWave = false

        case .listening:
            showListeningWave = false

            waveRevealTask = Task { @MainActor in
                let revealDelay: UInt64 = oldState == .idle ? 260_000_000 : 180_000_000
                try? await Task.sleep(nanoseconds: revealDelay)
                guard !Task.isCancelled, model.state == .listening else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    showListeningWave = true
                }
            }

        case .speaking:
            showListeningWave = false
        }
    }
}

private struct ListeningEqualizer: View {
    private let barColor = Color(red: 0.72, green: 0.53, blue: 0.97)

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(barColor)
                        .frame(width: 4, height: barHeight(for: index, time: t))
                }
            }
            .frame(height: 20)
        }
    }

    private func barHeight(for index: Int, time: TimeInterval) -> CGFloat {
        let phase = time * 6 + (Double(index) * 0.8)
        let normalized = abs(sin(phase))
        return 6 + (normalized * 10)
    }
}

private struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            .init(topCornerRadius, bottomCornerRadius)
        }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )

        path.addLine(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius)
        )

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )

        path.addLine(
            to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY)
        )

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )

        path.addLine(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius)
        )

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))

        return path
    }
}
