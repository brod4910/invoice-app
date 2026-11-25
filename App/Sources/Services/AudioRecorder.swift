import AVFoundation
import Observation
import UIKit

/// Records one clip at a time to an .m4a file. Pause/resume stays in the same file.
@MainActor
@Observable
final class AudioRecorder {
    enum State { case idle, recording, paused }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0
    private(set) var currentFileName: String?
    /// Loudest moment of this clip in dB (-160 is silence, 0 is max).
    private var loudestPower: Float = -160
    /// Talking near the phone peaks well above this; a quiet room or a pocket stays below it.
    static let speechPeakThreshold: Float = -40

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    /// True when a phone call or Siri paused the clip, so it picks up again on its own afterwards.
    private var pausedByInterruption = false

    init() {
        // A phone call or alarm pauses the microphone. The clip so far is kept; recording
        // carries on in the same file once the call ends.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init) == .began
            MainActor.assumeIsolated { self?.handleInterruption(began: began) }
        }
    }

    private func handleInterruption(began: Bool) {
        if began {
            guard state == .recording else { return }
            recorder?.pause()
            state = .paused
            pausedByInterruption = true
        } else if pausedByInterruption {
            pausedByInterruption = false
            try? AVAudioSession.sharedInstance().setActive(true)
            if recorder?.record() == true { state = .recording }
        }
    }

    /// The screen stays on while recording, so the phone doesn't lock mid-job. If it locks
    /// anyway (side button, pocket), recording continues in the background.
    private func keepScreenOn(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Starts recording a new clip. Turning on the microphone can block for a moment,
    /// so that part runs off the main thread to keep the screen responsive.
    /// `withSpokenPrompts`: the guided recorder speaks questions between clips, so it keeps one
    /// audio mode that can both play and record. Switching modes between clips left the
    /// questions after the first one silent.
    func start(withSpokenPrompts: Bool = false) async throws {
        let fileName = "\(UUID().uuidString).m4a"
        let url = AudioStorage.directory.appendingPathComponent(fileName)
        let box = try await Task.detached(priority: .userInitiated) {
            try Self.startRecorder(at: url, withSpokenPrompts: withSpokenPrompts)
        }.value
        recorder = box.recorder
        currentFileName = fileName
        elapsed = 0
        loudestPower = -160
        state = .recording
        pausedByInterruption = false
        keepScreenOn(true)
        startTimer()
    }

    private nonisolated static func startRecorder(at url: URL, withSpokenPrompts: Bool) throws -> RecorderBox {
        let session = AVAudioSession.sharedInstance()
        if withSpokenPrompts {
            try setSpokenPromptMode()
        } else {
            // Record-only when nothing is spoken: play-and-record turns the speaker on, which can pop.
            try session.setCategory(.record, mode: .default)
        }
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw RecorderError.couldNotStart }
        return RecorderBox(recorder: recorder)
    }

    /// One mode for the whole guided recording: speak through the loudspeaker and record.
    nonisolated static func setSpokenPromptMode() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord || !session.categoryOptions.contains(.defaultToSpeaker) else { return }
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
    }

    /// Carries the recorder back to the main thread.
    private struct RecorderBox: @unchecked Sendable {
        let recorder: AVAudioRecorder
    }

    func pause() {
        recorder?.pause()
        state = .paused
        pausedByInterruption = false
    }

    func resume() {
        recorder?.record()
        state = .recording
    }

    /// Stops and returns the finished file name, duration, and whether anything loud enough
    /// to be speech was heard.
    /// `deactivate: false` keeps the audio session on between guided steps, so the next spoken
    /// question isn't cut off.
    func stop(deactivate: Bool = true) -> (fileName: String, duration: TimeInterval, heardSound: Bool)? {
        guard let recorder, let fileName = currentFileName else { return nil }
        let duration = recorder.currentTime > 0 ? recorder.currentTime : elapsed
        recorder.stop()
        timer?.invalidate()
        timer = nil
        self.recorder = nil
        currentFileName = nil
        state = .idle
        level = 0
        pausedByInterruption = false
        keepScreenOn(false)
        // Deactivating blocks briefly, so do it off the main thread to keep the UI responsive.
        if deactivate {
            Task.detached {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        return (fileName, duration, loudestPower >= Self.speechPeakThreshold)
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
                self.loudestPower = max(self.loudestPower, recorder.peakPower(forChannel: 0))
            }
        }
    }

    enum RecorderError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "The microphone could not start. Please try again." }
    }
}
