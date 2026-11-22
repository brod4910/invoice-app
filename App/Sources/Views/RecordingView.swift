import SwiftData
import SwiftUI

/// Full-screen recorder. Every clip is saved the moment Stop is tapped.
/// If Dad stops by accident, "Keep talking" records another clip into the same job.
struct RecordingView: View {
    /// nil starts a new job; otherwise clips are added to this job.
    let existingJob: Job?
    /// Called with the job the clips went into (nil if nothing was recorded).
    let onFinish: (Job?) -> Void

    @Environment(JobProcessor.self) private var processor
    @State private var recorder = AudioRecorder()
    @State private var job: Job?
    @State private var phase: Phase = .recording
    @State private var errorMessage: String?

    enum Phase { case recording, saved }

    var body: some View {
        VStack(spacing: 32) {
            switch phase {
            case .recording: recordingBody
            case .saved: savedBody
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear { job = existingJob; begin() }
        .interactiveDismissDisabled()
    }

    private var recordingBody: some View {
        VStack(spacing: 32) {
            Text(recorder.state == .paused ? "Paused" : "Listening…")
                .font(.largeTitle.bold())
            Text(existingJob == nil && job == nil ? "Say who the job was for, what you did, and what each part costs."
                                                  : "Add anything you forgot.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            ZStack {
                Circle().stroke(Color.red.opacity(0.2), lineWidth: 16)
                Circle()
                    .trim(from: 0, to: CGFloat(recorder.level))
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: recorder.level)
                Text(Duration.seconds(recorder.elapsed), format: .time(pattern: .minuteSecond))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 240, height: 240)

            Spacer()

            if let errorMessage {
                Text(errorMessage).font(.title3).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            Button(action: stop) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, minHeight: 96)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Button(recorder.state == .paused ? "Resume" : "Pause") {
                recorder.state == .paused ? recorder.resume() : recorder.pause()
            }
            .font(.title2)
            .frame(minHeight: 56)
        }
    }

    private var savedBody: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 120))
                .foregroundStyle(.green)
            Text("Saved").font(.largeTitle.bold())
            Text("The app is writing it up now. You can check it in a moment.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button { onFinish(job) } label: {
                Text("Done").font(.largeTitle.bold()).frame(maxWidth: .infinity, minHeight: 96)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            Button { phase = .recording; begin() } label: {
                Label("Oops, keep talking", systemImage: "mic.fill")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.bordered)
        }
    }

    private func begin() {
        do {
            try recorder.start()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stop() {
        guard let clip = recorder.stop() else { onFinish(job); return }
        // Ignore taps that produced almost nothing (under one second).
        guard clip.duration >= 1 else {
            try? FileManager.default.removeItem(at: AudioStorage.directory.appendingPathComponent(clip.fileName))
            if job == nil { onFinish(nil) } else { phase = .saved }
            return
        }
        if let job {
            processor.add(fileName: clip.fileName, duration: clip.duration, to: job)
        } else {
            job = processor.startNewJob(fileName: clip.fileName, duration: clip.duration)
        }
        phase = .saved
    }
}
