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
    private static let listeningMinHeight: CGFloat = 42

    private static let speakingWidthOffset: CGFloat = 440
    private static let speakingWidthRange: ClosedRange<CGFloat> = 600 ... 760
    private static let speakingHeight: CGFloat = 180
    static let canvasSize = CGSize(width: speakingWidthRange.upperBound, height: speakingHeight)

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
            let width = min(
                max(closedSize.width + speakingWidthOffset, speakingWidthRange.lowerBound),
                speakingWidthRange.upperBound
            )
            return CGSize(width: width, height: speakingHeight)
        }
    }
}
