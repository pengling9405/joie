import AppKit
import CoreGraphics

enum AssistantState {
    case idle
    case listening
    case thinking
    case speaking
}

enum AssistantLayoutMetrics {
    static let fallbackClosedSize = CGSize(width: 185, height: 32)

    private static let closedWidthRange: ClosedRange<CGFloat> = 160 ... 240
    private static let closedHeightRange: ClosedRange<CGFloat> = 28 ... 38

    private static let listeningWidth: CGFloat = 560
    private static let listeningBodyHeight: CGFloat = 26
    private static let speakingMaxLines = 10
    private static let contentHorizontalPadding: CGFloat = 22
    private static let contentTopPadding: CGFloat = 12
    private static let contentBottomPadding: CGFloat = 14
    private static let headerHeight: CGFloat = 20
    private static let contentSpacing: CGFloat = 10
    private static let bodyFontSize: CGFloat = 16
    private static let bodyLineSpacing: CGFloat = 1
    // Keep a small reserve to avoid clipping descenders during dynamic height transitions,
    // but avoid making the bottom padding look heavier than the top.
    private static let speakingSafetyInset: CGFloat = 4
    // Tune header vertical alignment so content starts close to notch baseline instead of
    // being pushed too far down in expanded states.
    private static let notchClearanceOffset: CGFloat = 26

    private static let speakingWidth: CGFloat = listeningWidth
    private static let speakingMaxHeight: CGFloat = 360
    static let canvasSize = CGSize(width: speakingWidth, height: speakingMaxHeight)

    static func clampedClosedSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, closedWidthRange.lowerBound), closedWidthRange.upperBound),
            height: min(max(size.height, closedHeightRange.lowerBound), closedHeightRange.upperBound)
        )
    }

    static func size(
        for state: AssistantState,
        closedSize: CGSize,
        hasListeningText: Bool,
        speakingText: String
    ) -> CGSize {
        switch state {
        case .idle:
            return closedSize
        case .listening:
            let headerOnlyHeight = contentHeaderHeight(closedSize: closedSize)
            let targetHeight =
                hasListeningText
                ? headerOnlyHeight + contentSpacing + listeningBodyHeight
                : headerOnlyHeight
            return CGSize(width: listeningWidth, height: max(closedSize.height, ceil(targetHeight)))
        case .thinking:
            return CGSize(
                width: speakingWidth,
                height: max(closedSize.height, ceil(contentHeaderHeight(closedSize: closedSize)))
            )
        case .speaking:
            let measured = speakingHeight(for: speakingText, closedSize: closedSize)
            return CGSize(width: speakingWidth, height: max(closedSize.height, measured))
        }
    }

    static func notchClearance(for closedSize: CGSize) -> CGFloat {
        max(0, closedSize.height - notchClearanceOffset)
    }

    static func speakingVisibleBodyHeight(for text: String) -> CGFloat {
        speakingBodyMetrics(for: text).visibleBodyHeight
    }

    static func speakingHasOverflow(for text: String) -> Bool {
        speakingBodyMetrics(for: text).measuredLines > speakingMaxLines
    }

    private static func contentHeaderHeight(closedSize: CGSize) -> CGFloat {
        notchClearance(for: closedSize) + contentTopPadding + headerHeight + contentBottomPadding
    }

    private static func speakingHeight(for text: String, closedSize: CGSize) -> CGFloat {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return contentHeaderHeight(closedSize: closedSize) }

        let metrics = speakingBodyMetrics(for: cleaned)

        let fullHeight = contentHeaderHeight(closedSize: closedSize) +
            contentSpacing +
            metrics.visibleBodyHeight +
            speakingSafetyInset
        return min(speakingMaxHeight, ceil(fullHeight))
    }

    private struct SpeakingBodyMetrics {
        let measuredLines: Int
        let visibleBodyHeight: CGFloat
    }

    private static func speakingBodyMetrics(for text: String) -> SpeakingBodyMetrics {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return SpeakingBodyMetrics(measuredLines: 0, visibleBodyHeight: 0)
        }

        let maxTextWidth = speakingWidth - (contentHorizontalPadding * 2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = bodyLineSpacing

        let font = NSFont.systemFont(ofSize: bodyFontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
        ]

        let bounding = (cleaned as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let singleLine = ("A" as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        ).height

        let lineHeight = max(1, ceil(singleLine))
        let measuredLines = max(1, Int(ceil(ceil(bounding.height) / lineHeight)))
        let visibleLines = min(speakingMaxLines, measuredLines)
        let visibleBodyHeight =
            (lineHeight * CGFloat(visibleLines)) +
            (bodyLineSpacing * CGFloat(max(0, visibleLines - 1)))

        return SpeakingBodyMetrics(
            measuredLines: measuredLines,
            visibleBodyHeight: visibleBodyHeight
        )
    }
}
