import CoreGraphics

enum AssistantState {
    case idle
    case listening
    case speaking
}

enum AssistantLayoutMetrics {
    static let fallbackClosedSize = CGSize(width: 185, height: 32)

    private static let closedWidthRange: ClosedRange<CGFloat> = 160 ... 240
    private static let closedHeightRange: ClosedRange<CGFloat> = 28 ... 38

    private static let listeningWidth: CGFloat = 560
    private static let listeningMinHeight: CGFloat = 86

    private static let speakingWidth: CGFloat = listeningWidth
    private static let speakingHeight: CGFloat = listeningMinHeight
    static let canvasSize = CGSize(width: speakingWidth, height: speakingHeight)

    static func clampedClosedSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, closedWidthRange.lowerBound), closedWidthRange.upperBound),
            height: min(max(size.height, closedHeightRange.lowerBound), closedHeightRange.upperBound)
        )
    }

    static func size(for state: AssistantState, closedSize: CGSize) -> CGSize {
        switch state {
        case .idle:
            return closedSize
        case .listening:
            return CGSize(width: listeningWidth, height: max(closedSize.height, listeningMinHeight))
        case .speaking:
            return CGSize(width: speakingWidth, height: speakingHeight)
        }
    }
}
