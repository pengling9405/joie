import AVFoundation
import Speech

@MainActor
final class SpeechManager {
    private let audioEngine = AVAudioEngine()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var lastTranscript: String = ""
    private var partialHandler: (@MainActor (String) -> Void)?
    private var stopContinuation: CheckedContinuation<String, Never>?
    private var stopTimeoutTask: Task<Void, Never>?
    private var hasInstalledTap = false
    private var pendingStopText: String?

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status == .authorized)
        }
    }

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted)
        }
    }

    func startListening(onPartial: @MainActor @escaping (String) -> Void) throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw SpeechError.notAuthorized
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw SpeechError.microphoneNotAuthorized
        }
        let recognizer = Self.makeRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable
        }

        stopInternal()

        partialHandler = onPartial
        lastTranscript = ""
        pendingStopText = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        hasInstalledTap = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            removeInputTapIfNeeded()
            recognitionRequest = nil
            partialHandler = nil
            throw error
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                guard self.recognitionRequest != nil || self.recognitionTask != nil else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.lastTranscript {
                        self.lastTranscript = text
                        self.partialHandler?(text)
                    }

                    if result.isFinal {
                        self.completeRecognition(with: text)
                        return
                    }
                }

                if error != nil {
                    self.completeRecognition(with: self.lastTranscript)
                }
            }
        }
    }

    func stopListening() async -> String {
        if let pendingStopText {
            self.pendingStopText = nil
            return pendingStopText
        }

        guard recognitionRequest != nil || recognitionTask != nil || hasInstalledTap || audioEngine.isRunning else {
            return lastTranscript
        }

        stopAudioCapture()
        if recognitionTask == nil {
            completeRecognition(with: lastTranscript)
            let text = pendingStopText ?? lastTranscript
            pendingStopText = nil
            return text
        }

        return await withCheckedContinuation { continuation in
            stopContinuation = continuation
            stopTimeoutTask?.cancel()
            stopTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                if self.stopContinuation != nil {
                    self.completeRecognition(with: self.lastTranscript)
                }
            }
        }
    }

    private func stopInternal() {
        stopAudioCapture()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        partialHandler = nil
        pendingStopText = nil
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil

        if let stopContinuation {
            stopContinuation.resume(returning: lastTranscript)
            self.stopContinuation = nil
        }
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        removeInputTapIfNeeded()
        recognitionRequest?.endAudio()
    }

    private func removeInputTapIfNeeded() {
        guard hasInstalledTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        hasInstalledTap = false
    }

    private func completeRecognition(with text: String) {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        partialHandler = nil
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        lastTranscript = text

        if let stopContinuation {
            stopContinuation.resume(returning: text)
            self.stopContinuation = nil
        } else {
            pendingStopText = text
        }
    }

    private static func makeRecognizer() -> SFSpeechRecognizer? {
        let supportedLocales = Array(SFSpeechRecognizer.supportedLocales())

        for preferred in Locale.preferredLanguages {
            for candidate in localeCandidates(from: preferred) {
                if let matched = supportedLocales.first(where: { normalizedLocaleID($0.identifier) == candidate }) {
                    return SFSpeechRecognizer(locale: matched)
                }
            }
        }

        if let zhCN = supportedLocales.first(where: { normalizedLocaleID($0.identifier) == "zh-cn" }) {
            return SFSpeechRecognizer(locale: zhCN)
        }

        return SFSpeechRecognizer()
    }

    private static func localeCandidates(from preferredLanguage: String) -> [String] {
        let normalizedInput = preferredLanguage.replacingOccurrences(of: "_", with: "-")
        let parts = normalizedInput
            .split(separator: "-")
            .map { String($0) }

        let language = parts.first?.lowercased()
        let region = parts.dropFirst().first(where: { $0.count == 2 || $0.count == 3 })?.lowercased()

        var candidates: [String] = []
        if let language, let region {
            candidates.append("\(language)-\(region)")
        }
        if let language {
            candidates.append(language)
        }
        candidates.append(normalizedLocaleID(normalizedInput))

        var deduped: [String] = []
        var seen = Set<String>()
        for candidate in candidates where !candidate.isEmpty {
            if seen.insert(candidate).inserted {
                deduped.append(candidate)
            }
        }
        return deduped
    }

    private static func normalizedLocaleID(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

enum SpeechError: LocalizedError {
    case notAuthorized
    case microphoneNotAuthorized
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Speech 语音识别未授权"
        case .microphoneNotAuthorized:
            "麦克风未授权"
        case .recognizerUnavailable:
            "SFSpeechRecognizer 不可用"
        }
    }
}
