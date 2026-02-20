import AVFoundation
import Foundation

final class TTSManager: NSObject, AVSpeechSynthesizerDelegate {
    var onFinished: (@MainActor () -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let debugTTSEnabled = ProcessInfo.processInfo.environment["JOIE_DEBUG_TTS"] == "1"

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            notifyFinished()
            return
        }

        if synthesizer.isSpeaking {
            stopImmediate()
        }

        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = resolveVoice(for: cleaned)
        if debugTTSEnabled {
            let voiceID = utterance.voice?.language ?? "<default>"
            print("[joie][tts] speak voice=\(voiceID) text=\(cleaned)")
        }
        synthesizer.speak(utterance)
    }

    func stopImmediate() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        notifyFinished()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        notifyFinished()
    }

    private func notifyFinished() {
        guard let onFinished else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                onFinished()
            }
        }
    }

    private func resolveVoice(for text: String) -> AVSpeechSynthesisVoice? {
        for language in preferredLanguages(for: text) {
            if let voice = AVSpeechSynthesisVoice(language: language) {
                return voice
            }
        }
        return nil
    }

    private func preferredLanguages(for text: String) -> [String] {
        let hanCount = countHanCharacters(text)
        let latinCount = countLatinLetters(text)

        var candidates: [String] = []

        if hanCount > latinCount {
            candidates.append(contentsOf: ["zh-CN", "zh-TW", "zh-HK"])
        } else if latinCount > hanCount {
            candidates.append(contentsOf: ["en-US", "en-GB", "en-AU"])
        }

        candidates.append(contentsOf: Locale.preferredLanguages.map(normalizedLanguageID))
        candidates.append(normalizedLanguageID(Locale.current.identifier))
        candidates.append(contentsOf: ["zh-CN", "en-US"])

        var deduped: [String] = []
        var seen = Set<String>()
        for candidate in candidates {
            guard !candidate.isEmpty else { continue }
            if seen.insert(candidate).inserted {
                deduped.append(candidate)
            }
        }
        return deduped
    }

    private func normalizedLanguageID(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: "-")
    }

    private func countHanCharacters(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            switch scalar.value {
            case 0x3400 ... 0x4DBF, // CJK Unified Ideographs Extension A
                 0x4E00 ... 0x9FFF, // CJK Unified Ideographs
                 0xF900 ... 0xFAFF: // CJK Compatibility Ideographs
                count += 1
            default:
                break
            }
        }
    }

    private func countLatinLetters(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            switch scalar.value {
            case 0x0041 ... 0x005A, // A-Z
                 0x0061 ... 0x007A, // a-z
                 0x00C0 ... 0x00FF, // Latin-1 Supplement
                 0x0100 ... 0x024F: // Latin Extended-A/B
                count += 1
            default:
                break
            }
        }
    }
}
