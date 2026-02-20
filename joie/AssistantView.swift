import SwiftUI

struct AssistantView: View {
    @ObservedObject var model: AssistantCoordinator

    private enum VoiceLayout {
        static let horizontalPadding: CGFloat = 22
        static let topPadding: CGFloat = 12
        static let bottomPadding: CGFloat = 14
        static let contentSpacing: CGFloat = 10
        static let headerSpacing: CGFloat = 10
        static let actionSpacing: CGFloat = 8
        static let actionButtonSize: CGFloat = 26
        static let waveformWidth: CGFloat = 28
        static let waveformHeight: CGFloat = 20
        static let titleSize: CGFloat = 18
        static let bodySize: CGFloat = 16
        static let bodyLineSpacing: CGFloat = 1
        static let baselineTopCornerRadius: CGFloat = 6
    }

    private var closedSize: CGSize {
        model.closedNotchSize
    }

    private var currentNotchSize: CGSize {
        AssistantLayoutMetrics.size(
            for: model.state,
            closedSize: closedSize,
            listeningText: model.liveTranscript,
            speakingText: model.speakingText
        )
    }

    private var notchClearance: CGFloat {
        AssistantLayoutMetrics.notchClearance(for: closedSize)
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
            listeningContent(
                title: "Listening",
                text: listeningDisplayText,
                textColor: Color.white.opacity(0.90)
            )

        case .thinking:
            thinkingContent(
                title: "Thinking",
                text: nil,
                textColor: Color.white.opacity(0.80)
            )

        case .speaking:
            speakingContent(
                title: "Speaking",
                text: speakingDisplayText,
                textColor: Color.white.opacity(0.90)
            )
        }
    }

    private var speakingDisplayText: String {
        let text = model.speakingText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    private var listeningDisplayText: String? {
        let text = model.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private var contentHorizontalPadding: CGFloat {
        // Keep visual inset consistent when top corner radius grows (e.g. speaking state).
        VoiceLayout.horizontalPadding + max(0, topCornerRadius - VoiceLayout.baselineTopCornerRadius)
    }

    @ViewBuilder
    private func statusHeader(title: String, showsSpeakingActions: Bool = false) -> some View {
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

            if showsSpeakingActions {
                HStack(spacing: VoiceLayout.actionSpacing) {
                    speakingActionButton(symbolName: "doc.on.doc") {
                        model.copySpeakingTextToPasteboard()
                    }
                    speakingActionButton(symbolName: "xmark") {
                        model.closeSpeakingAndReturnIdle()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
            }
        }
    }

    @ViewBuilder
    private func listeningContent(title: String, text: String?, textColor: Color) -> some View {
        VStack(alignment: .leading, spacing: VoiceLayout.contentSpacing) {
            statusHeader(title: title)

            if let text, !text.isEmpty {
                SpeakingScrollableText(
                    text: text,
                    textColor: textColor,
                    bodyHeight: AssistantLayoutMetrics.listeningVisibleBodyHeight(for: text),
                    bodySize: VoiceLayout.bodySize,
                    lineSpacing: VoiceLayout.bodyLineSpacing
                )
            }
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.top, VoiceLayout.topPadding + notchClearance)
        .padding(.bottom, VoiceLayout.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func thinkingContent(title: String, text: String?, textColor: Color) -> some View {
        voiceContent(title: title, text: text, textColor: textColor)
    }

    @ViewBuilder
    private func speakingContent(title: String, text: String?, textColor: Color) -> some View {
        VStack(alignment: .leading, spacing: VoiceLayout.contentSpacing) {
            statusHeader(title: title, showsSpeakingActions: model.speakingActionsVisible)

            if let text, !text.isEmpty {
                SpeakingScrollableText(
                    text: text,
                    textColor: textColor,
                    bodyHeight: AssistantLayoutMetrics.speakingVisibleBodyHeight(for: text),
                    bodySize: VoiceLayout.bodySize,
                    lineSpacing: VoiceLayout.bodyLineSpacing
                )
            }
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.top, VoiceLayout.topPadding + notchClearance)
        .padding(.bottom, VoiceLayout.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func speakingActionButton(symbolName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.86))
                .frame(width: VoiceLayout.actionButtonSize, height: VoiceLayout.actionButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func voiceContent(title: String, text: String?, textColor: Color) -> some View {
        VStack(alignment: .leading, spacing: VoiceLayout.contentSpacing) {
            statusHeader(title: title)

            if let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: VoiceLayout.bodySize, weight: .medium))
                    .foregroundStyle(textColor)
                    .lineLimit(nil)
                    .lineSpacing(VoiceLayout.bodyLineSpacing)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.top, VoiceLayout.topPadding + notchClearance)
        .padding(.bottom, VoiceLayout.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SpeakingScrollableText: View {
    let text: String
    let textColor: Color
    let bodyHeight: CGFloat
    let bodySize: CGFloat
    let lineSpacing: CGFloat

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(text)
                .font(.system(size: bodySize, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(nil)
                .lineSpacing(lineSpacing)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(height: max(1, ceil(bodyHeight)), alignment: .top)
        .clipped()
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
