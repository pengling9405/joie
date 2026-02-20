import AppKit
import SwiftUI

@MainActor
final class AssistantCoordinator: ObservableObject {
    @Published private(set) var state: AssistantState = .idle
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var speakingText: String = ""
    @Published private(set) var speakingActionsVisible: Bool = false
    @Published private(set) var closedNotchSize: CGSize = AssistantLayoutMetrics.fallbackClosedSize

    private let speechManager = SpeechManager()
    private let ttsManager = TTSManager()
    private let eventTapManager = EventTapManager()
    private let gatewayClient = GatewayClient()

    private lazy var windowController = AssistantWindowController(model: self)

    private var hideTask: Task<Void, Never>?
    private var stopListeningTask: Task<Void, Never>?
    private var gatewayEventTask: Task<Void, Never>?
    private var gatewaySendTask: Task<Void, Never>?
    private var gatewayRunTimeoutTask: Task<Void, Never>?
    private var interactionSessionID: UInt64 = 0
    private var hideRequestID: UInt64 = 0
    private var activeGatewayRunID: String?
    private var activeGatewaySessionID: UInt64?
    private var gatewayReplyBuffer: String = ""
    private let debugEventTapEnabled = ProcessInfo.processInfo.environment["JOIE_DEBUG_EVENTTAP"] == "1"
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

    private func setState(_ next: AssistantState, animation: Animation, clearSpeakingText: Bool = false) {
        if debugEventTapEnabled, state != next {
            print("[joie][state] \(String(describing: state)) -> \(String(describing: next))")
        }
        withAnimation(animation) {
            state = next
            if clearSpeakingText {
                speakingText = ""
            }
        }
        applyWindowSize(animated: true)
        updateWindowInteractivity()
    }

    func start() {
        requestPermissions()
        startGatewayEventStream()

        ttsManager.onFinished = { [weak self] in
            guard let self else { return }
            guard self.state == .speaking else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                self.speakingActionsVisible = true
            }
            self.updateWindowInteractivity()
        }

        eventTapManager.onFnDown = { [weak self] in
            self?.handleFnDown()
        }

        eventTapManager.onFnUp = { [weak self] in
            self?.handleFnUp()
        }

        eventTapManager.onEscapeDown = { [weak self] in
            self?.handleEscapeDown()
        }

        windowController.hide()
        windowController.refreshClosedNotchMetrics()
        windowController.setInteractive(false)
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
        guard state == .idle else {
            if debugEventTapEnabled {
                print("[joie] Fn down 忽略：当前状态 \(String(describing: state))（仅 idle 可触发 listening）")
            }
            return
        }

        interactionSessionID &+= 1
        let sessionID = interactionSessionID
        stopListeningTask?.cancel()
        hideTask?.cancel()
        hideTask = nil
        hideRequestID &+= 1
        gatewaySendTask?.cancel()
        windowController.refreshClosedNotchMetrics()
        cancelGatewayRunIfNeeded(reason: "fn-down")

        windowController.show()
        liveTranscript = ""
        speakingText = ""
        speakingActionsVisible = false
        setState(.listening, animation: listeningAnimation)

        do {
            try speechManager.startListening { [weak self] text in
                guard let self else { return }
                guard self.state == .listening, sessionID == self.interactionSessionID else { return }
                guard text != self.liveTranscript else { return }
                self.liveTranscript = text
                self.applyWindowSize(animated: true)
                self.updateWindowInteractivity()
            }
        } catch {
            print("[joie] 无法开始语音识别：\(error.localizedDescription)")
            transitionToIdleAndHide()
        }
    }

    private func handleEscapeDown() {
        guard state == .speaking else {
            if debugEventTapEnabled {
                print("[joie] ESC 忽略：当前状态 \(String(describing: state))（仅 speaking 可打断）")
            }
            return
        }
        ttsManager.stopImmediate()
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
        guard state == .listening else {
            if debugEventTapEnabled {
                print("[joie] Fn up 忽略：当前状态 \(String(describing: state))")
            }
            return
        }
        let sessionID = interactionSessionID

        setState(.thinking, animation: speakingAnimation, clearSpeakingText: true)

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

            self.liveTranscript = cleaned
            self.startGatewayRun(for: cleaned, sessionID: sessionID)
        }
    }

    private func transitionToIdleAndHide() {
        stopListeningTask?.cancel()
        stopListeningTask = nil
        hideTask?.cancel()
        hideTask = nil
        gatewaySendTask?.cancel()
        gatewayRunTimeoutTask?.cancel()

        clearGatewayRunState()

        if debugEventTapEnabled, state != .idle {
            print("[joie][state] \(String(describing: state)) -> idle")
        }
        state = .idle
        liveTranscript = ""
        speakingText = ""
        speakingActionsVisible = false
        windowController.setInteractive(false)
        windowController.hide()
    }

    func copySpeakingTextToPasteboard() {
        let text = speakingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func closeSpeakingAndReturnIdle() {
        guard state == .speaking else { return }
        transitionToIdleAndHide()
    }

    private func scheduleHide(afterNanoseconds delay: UInt64, requestID: UInt64, sessionID: UInt64) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            await MainActor.run {
                guard let self else { return }
                guard !Task.isCancelled else { return }
                guard self.hideRequestID == requestID else { return }
                guard self.interactionSessionID == sessionID else { return }
                guard self.state == .idle else { return }
                self.windowController.hide()
            }
        }
    }

    private func applyWindowSize(animated: Bool) {
        let size = AssistantLayoutMetrics.size(
            for: state,
            closedSize: closedNotchSize,
            listeningText: liveTranscript,
            speakingText: speakingText
        )
        windowController.update(contentSize: size, animated: animated)
    }

    private func startGatewayEventStream() {
        gatewayEventTask?.cancel()
        gatewayEventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.gatewayClient.subscribe()
            for await push in stream {
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    self?.handleGatewayPush(push)
                }
            }
        }
    }

    private func startGatewayRun(for transcript: String, sessionID: UInt64) {
        guard state == .thinking else { return }
        let runID = UUID().uuidString
        clearGatewayRunState()
        activeGatewayRunID = runID
        activeGatewaySessionID = sessionID
        gatewayReplyBuffer = ""

        gatewaySendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.gatewayClient.chatSend(
                    message: transcript,
                    idempotencyKey: runID
                )
                await MainActor.run {
                    guard self.activeGatewayRunID == runID else { return }
                    guard self.interactionSessionID == sessionID else { return }
                    print("[joie][gateway] chat.send ok requestRunId=\(runID) responseRunId=\(result.runID)")
                    if result.runID != runID {
                        self.activeGatewayRunID = result.runID
                    }
                    self.armGatewayRunTimeout(runID: self.activeGatewayRunID ?? runID, sessionID: sessionID)
                }
            } catch {
                await MainActor.run {
                    guard self.activeGatewayRunID == runID else { return }
                    print("[joie][gateway] chat.send 失败：\(error.localizedDescription)")
                    self.transitionToIdleAndHide()
                }
            }
        }
    }

    private func armGatewayRunTimeout(runID: String, sessionID: UInt64) {
        gatewayRunTimeoutTask?.cancel()
        gatewayRunTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            await MainActor.run {
                guard let self else { return }
                guard self.activeGatewayRunID == runID else { return }
                guard self.interactionSessionID == sessionID else { return }
                print("[joie][gateway] run 超时，runId=\(runID)")
                self.cancelGatewayRunIfNeeded(reason: "timeout")
                self.transitionToIdleAndHide()
            }
        }
    }

    private func cancelGatewayRunIfNeeded(reason: String) {
        gatewayRunTimeoutTask?.cancel()
        guard let runID = activeGatewayRunID else { return }
        let currentReason = reason
        Task { [gatewayClient] in
            await gatewayClient.chatAbort(runID: runID)
            print("[joie][gateway] chat.abort runId=\(runID) reason=\(currentReason)")
        }
        clearGatewayRunState()
    }

    private func clearGatewayRunState() {
        gatewaySendTask?.cancel()
        gatewaySendTask = nil
        gatewayRunTimeoutTask?.cancel()
        gatewayRunTimeoutTask = nil
        activeGatewayRunID = nil
        activeGatewaySessionID = nil
        gatewayReplyBuffer = ""
    }

    private func handleGatewayPush(_ push: GatewayPush) {
        switch push {
        case let .connected(authSource):
            print("[joie][gateway] connected auth=\(authSource)")
        case let .disconnected(reason):
            print("[joie][gateway] disconnected reason=\(reason)")
            if state == .thinking {
                transitionToIdleAndHide()
            }
        case let .event(name, payload):
            guard name == "chat" || name.hasPrefix("chat.") else { return }
            guard let payload else { return }
            handleChatEvent(name: name, data: payload)
        }
    }

    private func handleChatEvent(name: String, data: Data) {
        guard state == .thinking else { return }
        guard let activeRunID = activeGatewayRunID,
              let activeSessionID = activeGatewaySessionID
        else {
            return
        }
        guard activeSessionID == interactionSessionID else { return }

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if let text = String(data: data, encoding: .utf8) {
                print("[joie][gateway] 无法解析 chat 事件：\(text)")
            } else {
                print("[joie][gateway] 无法解析 chat 事件（二进制）")
            }
            return
        }

        let inferredState: String? = {
            guard name.hasPrefix("chat.") else { return nil }
            return String(name.dropFirst("chat.".count))
        }()
        let eventState = (stringValue(in: object, keys: ["state", "phase"]) ?? inferredState ?? "").lowercased()
        let eventRunID = extractRunID(from: object)
        let eventSessionKey = stringValue(in: object, keys: ["sessionKey", "session_key"])

        if let eventRunID,
           eventRunID != activeRunID
        {
            return
        }

        if let eventSessionKey,
           !sessionKeyMatches(eventSessionKey, local: gatewayClient.configuredSessionKey)
        {
            if ProcessInfo.processInfo.environment["JOIE_DEBUG_GATEWAY"] == "1" {
                print("[joie][gateway] sessionKey 不一致，event=\(eventSessionKey) local=\(gatewayClient.configuredSessionKey)")
            }
            return
        }

        if ProcessInfo.processInfo.environment["JOIE_DEBUG_GATEWAY"] == "1" {
            print("[joie][gateway] chat event name=\(name) state=\(eventState) runId=\(eventRunID ?? "<nil>") activeRunId=\(activeRunID) session=\(eventSessionKey ?? "<nil>")")
        }

        switch eventState {
        case "delta", "partial", "streaming":
            let delta = extractText(from: object).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !delta.isEmpty else { return }
            if delta.count >= gatewayReplyBuffer.count,
               delta.hasPrefix(gatewayReplyBuffer)
            {
                // Some gateways emit cumulative chunks; replace buffer to avoid duplicated text.
                gatewayReplyBuffer = delta
            } else if !gatewayReplyBuffer.hasSuffix(delta) {
                gatewayReplyBuffer += delta
            }
        case "final", "completed", "done":
            let explicitFinal = extractText(from: object).trimmingCharacters(in: .whitespacesAndNewlines)
            let finalText = explicitFinal.isEmpty
                ? gatewayReplyBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                : explicitFinal
            clearGatewayRunState()
            guard !finalText.isEmpty else {
                transitionToIdleAndHide()
                return
            }
            showSpeaking(finalText, sessionID: interactionSessionID)
        case "error", "failed":
            let message = stringValue(in: object, keys: ["errorMessage", "error_message", "message"]) ?? "unknown"
            print("[joie][gateway] run error=\(message)")
            transitionToIdleAndHide()
        case "aborted":
            transitionToIdleAndHide()
        default:
            if name == "chat.final" {
                let explicitFinal = extractText(from: object).trimmingCharacters(in: .whitespacesAndNewlines)
                let finalText = explicitFinal.isEmpty
                    ? gatewayReplyBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    : explicitFinal
                clearGatewayRunState()
                guard !finalText.isEmpty else {
                    transitionToIdleAndHide()
                    return
                }
                showSpeaking(finalText, sessionID: interactionSessionID)
            }
            break
        }
    }

    private func showSpeaking(_ text: String, sessionID: UInt64) {
        guard interactionSessionID == sessionID else { return }
        guard state == .thinking else { return }
        speakingActionsVisible = false
        let displayText = SpeakingTextFormatter.displayText(from: text)
        let speechText = SpeakingTextFormatter.speechText(from: text)
        speakingText = displayText
        setState(.speaking, animation: speakingAnimation)
        ttsManager.speak(speechText.isEmpty ? displayText : speechText)
    }

    private func updateWindowInteractivity() {
        let interactive =
            state == .speaking ||
            (state == .listening && AssistantLayoutMetrics.listeningHasOverflow(for: liveTranscript))
        windowController.setInteractive(interactive)
    }

    private func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let str = value as? String {
                let cleaned = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    private func extractRunID(from object: [String: Any]) -> String? {
        if let direct = stringValue(in: object, keys: ["runId", "runID", "run_id", "id"]) {
            return direct
        }
        if let run = object["run"] as? [String: Any],
           let nested = stringValue(in: run, keys: ["id", "runId", "runID", "run_id"])
        {
            return nested
        }
        return nil
    }

    private func extractText(from object: [String: Any]) -> String {
        if let topText = stringValue(in: object, keys: ["text", "delta", "output", "reply"]) {
            return topText
        }

        if let message = object["message"] as? [String: Any] {
            if let text = stringValue(in: message, keys: ["text", "delta", "content"]) {
                return text
            }
            if let content = message["content"] as? [[String: Any]] {
                let parts = content.compactMap { part in
                    stringValue(in: part, keys: ["text", "value"])
                }
                if !parts.isEmpty {
                    return parts.joined()
                }
            }
        }

        if let content = object["content"] as? [[String: Any]] {
            let parts = content.compactMap { part in
                stringValue(in: part, keys: ["text", "value"])
            }
            if !parts.isEmpty {
                return parts.joined()
            }
        }

        return ""
    }

    private func sessionKeyMatches(_ event: String, local: String) -> Bool {
        let eventTrimmed = event.trimmingCharacters(in: .whitespacesAndNewlines)
        let localTrimmed = local.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eventTrimmed.isEmpty, !localTrimmed.isEmpty else { return false }
        if eventTrimmed == localTrimmed { return true }

        // OpenClaw may namespace session keys like "agent:main:main".
        let eventParts = eventTrimmed.split(separator: ":").map(String.init)
        if eventParts.contains(localTrimmed) {
            return true
        }
        let localParts = localTrimmed.split(separator: ":").map(String.init)
        return !Set(eventParts).isDisjoint(with: Set(localParts))
    }
}

private enum SpeakingTextFormatter {
    static func displayText(from markdown: String) -> String {
        let stripped = basicMarkdownStripped(markdown)
        return normalizedParagraphs(stripped)
    }

    static func speechText(from markdown: String) -> String {
        var text = basicMarkdownStripped(markdown)
        text = removingURLs(text)
        text = normalizedParagraphs(text)
        return text
    }

    private static func basicMarkdownStripped(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")

        value = replacingRegex(
            #"```[\s\S]*?```"#,
            in: value,
            with: "\n"
        )
        value = replacingRegex(
            #"!\[[^\]]*\]\([^)]+\)"#,
            in: value,
            with: ""
        )
        value = replacingRegex(
            #"\[([^\]]+)\]\([^)]+\)"#,
            in: value,
            with: "$1"
        )
        value = replacingRegex(
            #"`([^`]+)`"#,
            in: value,
            with: "$1"
        )
        value = replacingRegex(
            #"(?m)^\s{0,3}#{1,6}\s+"#,
            in: value,
            with: ""
        )
        value = replacingRegex(
            #"(?m)^\s*([-*+]|\d+\.)\s+"#,
            in: value,
            with: ""
        )
        value = replacingRegex(#"(\*\*|__)(.*?)\1"#, in: value, with: "$2")
        value = replacingRegex(#"(\*|_)(.*?)\1"#, in: value, with: "$2")
        value = replacingRegex(#"~~(.*?)~~"#, in: value, with: "$1")
        value = replacingRegex(#"(?m)^\s{0,3}>\s?"#, in: value, with: "")
        value = replacingRegex(#"[ \t]{2,}"#, in: value, with: " ")
        value = replacingRegex(#"(?m)[ \t]+$"#, in: value, with: "")
        value = replacingRegex(#"(?m)^[ \t]+"#, in: value, with: "")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingURLs(_ text: String) -> String {
        replacingRegex(
            #"https?://[^\s]+"#,
            in: text,
            with: ""
        )
    }

    private static func normalizedParagraphs(_ text: String) -> String {
        var value = replacingRegex(
            #"\n{3,}"#,
            in: text,
            with: "\n\n"
        )
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    private static func replacingRegex(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
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

    func setInteractive(_ interactive: Bool) {
        window?.ignoresMouseEvents = !interactive
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

        // Keep window frame updates deterministic. Double animations between SwiftUI and NSWindow
        // caused intermittent clipping and state visibility glitches in notch transitions.
        _ = animated
        window.setFrame(frame, display: true)
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
