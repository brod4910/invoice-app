import AVFoundation
import Speech

/// Turns a recorded audio file into text, on the device.
/// Uses SpeechAnalyzer (iOS 26). Falls back to SFSpeechRecognizer if the on-device model isn't available.
enum Transcriber {
    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    static func transcribe(fileURL: URL, locale: Locale = Locale(identifier: "en-US")) async throws -> String {
        let analyzerError: Error
        do {
            return try await transcribeWithAnalyzer(fileURL: fileURL, locale: locale)
        } catch {
            analyzerError = error
        }
        // Fallback: let the system choose on-device or Apple's servers. Forcing on-device
        // fails with "Failed to initialize recognizer" when the on-device model isn't installed
        // (and always in the Simulator).
        do {
            return try await transcribeWithRecognizer(fileURL: fileURL, locale: locale)
        } catch {
            throw TranscriptionError.bothFailed(analyzer: analyzerError, recognizer: error)
        }
    }

    private static func transcribeWithAnalyzer(fileURL: URL, locale: Locale) async throws -> String {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collect results concurrently while the file is analyzed.
        let collector = Task {
            var text = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                text += result.text
                text += AttributedString(" ")
            }
            return String(text.characters)
        }

        let file = try AVAudioFile(forReading: fileURL)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func transcribeWithRecognizer(fileURL: URL, locale: Locale) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = false
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    enum TranscriptionError: LocalizedError {
        case unsupportedLocale, unavailable
        case bothFailed(analyzer: Error, recognizer: Error)
        var errorDescription: String? {
            switch self {
            case .unsupportedLocale: "Speech recognition doesn't support this language."
            case .unavailable: "Speech recognition isn't available right now."
            case .bothFailed(let analyzer, let recognizer):
                "Couldn't turn the recording into text. (\(analyzer.localizedDescription) / \(recognizer.localizedDescription))"
            }
        }
    }
}
