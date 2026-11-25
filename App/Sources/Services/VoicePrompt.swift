import AVFoundation

/// Speaks the recorder's questions out loud ("Who is the client?") before listening.
@MainActor
final class VoicePrompt: NSObject, AVSpeechSynthesizerDelegate {
    private var synthesizer: AVSpeechSynthesizer?
    private var finished: CheckedContinuation<Void, Never>?

    /// Says `text` and returns when it has finished, so the recording doesn't pick up the prompt.
    func say(_ text: String) async {
        stop()
        // Switching the audio session can block for a moment, so keep it off the main thread.
        // Same audio mode the guided recorder uses, so nothing switches between question and answer.
        await Task.detached(priority: .userInitiated) {
            try? AudioRecorder.setSpokenPromptMode()
            try? AVAudioSession.sharedInstance().setActive(true)
        }.value
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        // A fresh synthesizer each time: a reused one can go quiet after the audio session changes.
        let speaker = AVSpeechSynthesizer()
        speaker.delegate = self
        synthesizer = speaker
        await withCheckedContinuation { continuation in
            finished = continuation
            speaker.speak(utterance)
        }
    }

    func stop() {
        if let synthesizer, synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finished?.resume()
        finished = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished?.resume(); self.finished = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished?.resume(); self.finished = nil }
    }
}
