import AppKit
import SwiftUI

@MainActor
final class AssistantCoordinator: ObservableObject {
    @Published private(set) var state: AssistantState = .idle
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var speakingText: String = ""
    @Published private(set) var closedNotchSize: CGSize = AssistantLayoutMetrics.fallbackClosedSize

    private let speechManager = SpeechManager()
    private let ttsManager = TTSManager()
    private let eventTapManager = EventTapManager()

    private lazy var windowController = AssistantWindowController(model: self)

    private var hideTask: Task<Void, Never>?
    private var stopListeningTask: Task<Void, Never>?
    private var interactionSessionID: UInt64 = 0
    private var isListeningSessionActive = false
    private var suppressNextTTSFinishedCallback = false
    private let listeningAnimation = Animation.interactiveSpring(
        response: 0.42,
        dampingFraction: 0.84,
        blendDuration: 0.10
    )
    private let speakingAnimation = Animation.interactiveSpring(
        response: 0.50,
        dampingFraction: 0.88,
        blendDuration: 0.12
    )
    private let closingAnimation = Animation.interactiveSpring(
        response: 0.54,
        dampingFraction: 0.92,
        blendDuration: 0.14
    )

    func start() {
        requestPermissions()

        ttsManager.onFinished = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.suppressNextTTSFinishedCallback {
                    self.suppressNextTTSFinishedCallback = false
                    return
                }
                guard self.state == .speaking else { return }
                self.transitionToIdleAndHide()
            }
        }

        eventTapManager.onFnDown = { [weak self] in
            Task { @MainActor in
                self?.handleFnDown()
            }
        }

        eventTapManager.onFnUp = { [weak self] in
            Task { @MainActor in
                self?.handleFnUp()
            }
        }

        windowController.hide()
        windowController.refreshClosedNotchMetrics()
        eventTapManager.start()
    }

    private func requestPermissions() {
        speechManager.requestAuthorization { granted in
            if !granted {
                print("[joie] Speech 语音识别权限未授权，系统将无法进行 ASR。")
            }
        }

        speechManager.requestMicrophoneAccess { granted in
            if !granted {
                print("[joie] 麦克风权限未授权，系统将无法进行 ASR。")
            }
        }
    }

    private func handleFnDown() {
        interactionSessionID &+= 1
        let sessionID = interactionSessionID
        stopListeningTask?.cancel()
        hideTask?.cancel()
        isListeningSessionActive = false
        windowController.refreshClosedNotchMetrics()

        if state == .speaking {
            suppressNextTTSFinishedCallback = true
            ttsManager.stopImmediate()
            speakingText = ""
        }

        windowController.show()

        withAnimation(listeningAnimation) {
            state = .listening
            liveTranscript = ""
        }
        applyWindowSize(animated: true)

        do {
            try speechManager.startListening { [weak self] text in
                guard let self else { return }
                guard self.state == .listening, sessionID == self.interactionSessionID else { return }
                self.liveTranscript = text
            }
            isListeningSessionActive = true
        } catch {
            print("[joie] 无法开始语音识别：\(error.localizedDescription)")
            isListeningSessionActive = false
            transitionToIdleAndHide()
        }
    }

    func updateClosedNotchSize(_ size: CGSize) {
        let normalizedSize = AssistantLayoutMetrics.clampedClosedSize(size)
        let widthDelta = abs(closedNotchSize.width - normalizedSize.width)
        let heightDelta = abs(closedNotchSize.height - normalizedSize.height)
        guard widthDelta >= 0.5 || heightDelta >= 0.5 else { return }
        closedNotchSize = normalizedSize
        applyWindowSize(animated: false)
    }

    private func handleFnUp() {
        guard state == .listening, isListeningSessionActive else { return }
        let sessionID = interactionSessionID

        isListeningSessionActive = false
        stopListeningTask?.cancel()
        stopListeningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let finalText = await self.speechManager.stopListening()
            guard !Task.isCancelled else { return }
            guard sessionID == self.interactionSessionID else { return }
            let cleaned = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

            if cleaned.isEmpty {
                self.transitionToIdleAndHide()
                return
            }

            withAnimation(self.speakingAnimation) {
                self.state = .speaking
                self.speakingText = finalText
            }
            self.suppressNextTTSFinishedCallback = false
            self.applyWindowSize(animated: true)
            self.ttsManager.speak(finalText)
        }
    }

    private func transitionToIdleAndHide() {
        stopListeningTask?.cancel()
        hideTask?.cancel()
        isListeningSessionActive = false

        liveTranscript = ""
        speakingText = ""

        withAnimation(closingAnimation) {
            state = .idle
        }
        applyWindowSize(animated: true)
        scheduleHide(afterNanoseconds: 560_000_000)
    }

    private func scheduleHide(afterNanoseconds delay: UInt64) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await MainActor.run {
                guard let self, self.state == .idle else { return }
                self.windowController.hide()
            }
        }
    }

    private func applyWindowSize(animated: Bool) {
        windowController.update(contentSize: AssistantLayoutMetrics.canvasSize, animated: animated)
    }
}

final class AssistantWindowController: NSWindowController {
    private unowned let model: AssistantCoordinator
    private let contentSizeEpsilon: CGFloat = 0.5
    private let fallbackClosedSize = AssistantLayoutMetrics.fallbackClosedSize
    private var lastContentSize: CGSize = AssistantLayoutMetrics.canvasSize
    private let debugLayoutEnabled = ProcessInfo.processInfo.environment["JOIE_DEBUG_LAYOUT"] == "1"

    init(model: AssistantCoordinator) {
        self.model = model

        let window = AssistantOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: lastContentSize.width, height: lastContentSize.height),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )

        window.isFloatingPanel = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .mainMenu + 3
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.ignoresMouseEvents = true
        window.isMovableByWindowBackground = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        let hostingView = NSHostingView(rootView: AssistantView(model: model))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        window.contentView = hostingView

        super.init(window: window)
        refreshClosedNotchMetrics()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        refreshClosedNotchMetrics()
        update(contentSize: lastContentSize, animated: false)
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func update(contentSize: CGSize) {
        update(contentSize: contentSize, animated: true)
    }

    func refreshClosedNotchMetrics() {
        let closedSize = closedNotchSize(for: targetScreen())
        model.updateClosedNotchSize(closedSize)
    }

    fileprivate func update(contentSize: CGSize, animated: Bool) {
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        if animated, shouldSkipUpdate(for: contentSize) {
            return
        }
        lastContentSize = contentSize

        guard let window else { return }

        let screen = targetScreen()
        let screenFrame = screen?.frame ?? NSScreen.main?.frame ?? .zero
        let centerX = notchFrame(for: screen)?.midX ?? screenFrame.midX

        let x = centerX - (contentSize.width / 2)
        let y = screenFrame.maxY - contentSize.height

        let frame = NSRect(x: x, y: y, width: contentSize.width, height: contentSize.height).integral
        if debugLayoutEnabled {
            let notchMidX = notchFrame(for: screen)?.midX ?? -1
            let left = screen?.auxiliaryTopLeftArea
            let right = screen?.auxiliaryTopRightArea
            print(
                "[joie][layout] state=\(String(describing: model.state)) screenOrigin=(\(Int(screenFrame.origin.x)),\(Int(screenFrame.origin.y))) screenSize=(\(Int(screenFrame.width)),\(Int(screenFrame.height))) screenMidX=\(Int(screenFrame.midX)) notchMidX=\(Int(notchMidX)) auxL=(\(Int(left?.minX ?? -1)),\(Int(left?.maxX ?? -1))) auxR=(\(Int(right?.minX ?? -1)),\(Int(right?.maxX ?? -1))) content=(\(Int(contentSize.width))x\(Int(contentSize.height))) frameOrigin=(\(Int(frame.origin.x)),\(Int(frame.origin.y)))"
            )
        }
        if isApproximatelySameFrame(window.frame, frame) {
            return
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    private func shouldSkipUpdate(for size: CGSize) -> Bool {
        let widthDelta = abs(size.width - lastContentSize.width)
        let heightDelta = abs(size.height - lastContentSize.height)
        return widthDelta < contentSizeEpsilon && heightDelta < contentSizeEpsilon
    }

    private func isApproximatelySameFrame(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < contentSizeEpsilon &&
            abs(lhs.origin.y - rhs.origin.y) < contentSizeEpsilon &&
            abs(lhs.size.width - rhs.size.width) < contentSizeEpsilon &&
            abs(lhs.size.height - rhs.size.height) < contentSizeEpsilon
    }

    private func targetScreen() -> NSScreen? {
        if let windowScreen = window?.screen, hasHardwareNotch(on: windowScreen) {
            return windowScreen
        }
        if let main = NSScreen.main, hasHardwareNotch(on: main) {
            return main
        }
        if let notchedScreen = NSScreen.screens.first(where: { hasHardwareNotch(on: $0) }) {
            return notchedScreen
        }
        return window?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func hasHardwareNotch(on screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        guard #available(macOS 12.0, *) else { return false }
        return screen.safeAreaInsets.top > 0 && notchMetrics(for: screen) != nil
    }

    private func closedNotchSize(for screen: NSScreen?) -> CGSize {
        guard let metrics = notchMetrics(for: screen) else {
            return fallbackClosedSize
        }
        return AssistantLayoutMetrics.clampedClosedSize(metrics)
    }

    private func notchMetrics(for screen: NSScreen?) -> CGSize? {
        notchFrame(for: screen)?.size
    }

    private func notchFrame(for screen: NSScreen?) -> CGRect? {
        guard let screen else { return nil }
        guard #available(macOS 12.0, *),
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea
        else {
            return nil
        }

        let notchMinX = leftArea.maxX - 2
        let notchMaxX = rightArea.minX + 2
        let notchWidth = max(120, notchMaxX - notchMinX)
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let notchHeight = max(24, menuBarHeight, screen.safeAreaInsets.top)
        let notchX = notchMinX
        let notchY = screen.frame.maxY - notchHeight
        return CGRect(x: notchX, y: notchY, width: notchWidth, height: notchHeight)
    }
}

final class AssistantOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
