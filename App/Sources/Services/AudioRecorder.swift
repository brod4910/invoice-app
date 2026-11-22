import AVFoundation
import Observation

/// Records one clip at a time to an .m4a file. Pause/resume stays in the same file.
@MainActor
@Observable
final class AudioRecorder {
    enum State { case idle, recording, paused }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0
    private(set) var currentFileName: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
        try session.setActive(true)

        let fileName = "\(UUID().uuidString).m4a"
        let url = AudioStorage.directory.appendingPathComponent(fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw RecorderError.couldNotStart }
        self.recorder = recorder
        currentFileName = fileName
        elapsed = 0
        state = .recording
        startTimer()
    }

    func pause() {
        recorder?.pause()
        state = .paused
    }

    func resume() {
        recorder?.record()
        state = .recording
    }

    /// Stops and returns the finished file name and duration.
    func stop() -> (fileName: String, duration: TimeInterval)? {
        guard let recorder, let fileName = currentFileName else { return nil }
        let duration = recorder.currentTime > 0 ? recorder.currentTime : elapsed
        recorder.stop()
        timer?.invalidate()
        timer = nil
        self.recorder = nil
        currentFileName = nil
        state = .idle
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (fileName, duration)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder, self.state == .recording else { return }
                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                // Map -60...0 dB to 0...1 for the level ring.
                self.level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 60) / 60))
            }
        }
    }

    enum RecorderError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "The microphone could not start. Please try again." }
    }
}
