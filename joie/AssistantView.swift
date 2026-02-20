import SwiftUI

struct AssistantView: View {
    @ObservedObject var model: AssistantCoordinator

    private enum VoiceLayout {
        static let horizontalPadding: CGFloat = 22
        static let topPadding: CGFloat = 12
        static let bottomPadding: CGFloat = 14
        static let contentSpacing: CGFloat = 10
        static let headerSpacing: CGFloat = 10
        static let waveformWidth: CGFloat = 28
        static let waveformHeight: CGFloat = 20
        static let titleSize: CGFloat = 18
        static let bodySize: CGFloat = 16
        static let bodyLineSpacing: CGFloat = 1
        static let baselineTopCornerRadius: CGFloat = 6
    }

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
        NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
    }

    private var topCornerRadius: CGFloat { 6 }

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
            voiceContent(
                title: "Listening",
                text: listeningDisplayText,
                textColor: listeningTextColor
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .center)))

        case .speaking:
            voiceContent(
                title: "Speaking",
                text: speakingDisplayText,
                textColor: Color.white.opacity(0.90)
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .center)))
        }
    }

    private var speakingDisplayText: String {
        let text = model.speakingText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "..." : text
    }

    private var listeningDisplayText: String {
        let text = model.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "..." : text
    }

    private var listeningTextColor: Color {
        let text = model.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? Color.white.opacity(0.34) : Color.white.opacity(0.90)
    }

    private var contentHorizontalPadding: CGFloat {
        // Keep visual inset consistent when top corner radius grows (e.g. speaking state).
        VoiceLayout.horizontalPadding + max(0, topCornerRadius - VoiceLayout.baselineTopCornerRadius)
    }

    @ViewBuilder
    private func statusHeader(title: String) -> some View {
        HStack(spacing: VoiceLayout.headerSpacing) {
            ListeningEqualizer()
                .frame(
                    width: VoiceLayout.waveformWidth,
                    height: VoiceLayout.waveformHeight,
                    alignment: .leading
                )
                .opacity(0.95)

            Text(title)
                .font(.system(size: VoiceLayout.titleSize, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.88))

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func voiceContent(title: String, text: String, textColor: Color) -> some View {
        VStack(alignment: .leading, spacing: VoiceLayout.contentSpacing) {
            statusHeader(title: title)

            Text(text)
                .font(.system(size: VoiceLayout.bodySize, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(4)
                .truncationMode(.tail)
                .lineSpacing(VoiceLayout.bodyLineSpacing)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.top, VoiceLayout.topPadding)
        .padding(.bottom, VoiceLayout.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
