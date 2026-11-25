import InvoiceCore
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
    @AppStorage("recorder.talkMeThrough") private var talkMeThrough = true
    @State private var prompt = VoicePrompt()
    @State private var step: Step = .job
    @State private var spokenStep: Step?
    @State private var speaking = false

    enum Phase { case recording, saved, nothingHeard }

    /// A new job asks for the client, then the address, then the work, so Dad doesn't have to
    /// remember to say "client" and "address". Adding to a job goes straight to listening.
    enum Step {
        case client, address, job

        var title: String {
            switch self {
            case .client: "Who is the client?"
            case .address: "What's the address?"
            case .job: "Now explain the job"
            }
        }

        var hint: String {
            switch self {
            case .client: "Say their name, then tap Next."
            case .address: "Say the address of the job, then tap Next."
            case .job: "Say what you did and what each part costs. Tap Stop when you're done."
            }
        }

        var spoken: String {
            switch self {
            case .client: "Who is the client? Say their name, then tap Next."
            case .address: "What is the address? Then tap Next."
            case .job: "Now explain the job. Say what you did, and what each part costs. Tap Stop when you're done."
            }
        }

        var kind: GuidedAnswer.Kind? {
            switch self {
            case .client: .client
            case .address: .address
            case .job: nil
            }
        }

        var next: Step? {
            switch self {
            case .client: .address
            case .address: .job
            case .job: nil
            }
        }
    }

    private var guided: Bool { existingJob == nil && talkMeThrough }

    var body: some View {
        VStack(spacing: 32) {
            switch phase {
            case .recording: recordingBody
            case .saved: savedBody
            case .nothingHeard: nothingHeardBody
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear {
            job = existingJob
            step = guided ? .client : .job
            begin()
        }
        .onDisappear { prompt.stop() }
        .interactiveDismissDisabled()
    }

    private var recordingBody: some View {
        VStack(spacing: 32) {
            Text(guided ? step.title : recorder.state == .paused ? "Paused" : "Listening…")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(guided ? (speaking ? "Listen…" : recorder.state == .paused ? "Paused" : step.hint)
                 : existingJob == nil && job == nil ? "Say who the job was for, what you did, and what each part costs."
                 : "Add anything you forgot, or fix something. For example: \"the floor was 200\".")
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

            if guided, step.next != nil {
                Button { finishStep(keep: true) } label: {
                    Label("Next", systemImage: "arrow.right")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, minHeight: 96)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(recorder.state == .idle)

                Button("Skip this") { finishStep(keep: false) }
                    .font(.title2)
                    .frame(minHeight: 56)
                    .disabled(recorder.state == .idle)
            } else {
                Button(action: stop) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, minHeight: 96)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(recorder.state == .idle)
            }

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
            Button { onFinish(job.flatMap { $0.isGone ? nil : $0 }) } label: {
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

    private var nothingHeardBody: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "ear.trianglebadge.exclamationmark")
                .font(.system(size: 100))
                .foregroundStyle(.orange)
            Text("I didn't hear anything").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("Nothing was saved. Hold the phone closer and talk normally.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button { phase = .recording; begin() } label: {
                Label("Try again", systemImage: "mic.fill")
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, minHeight: 96)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Button { onFinish(job.flatMap { $0.isGone ? nil : $0 }) } label: {
                Text("Close").font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.bordered)
        }
    }

    private func begin() {
        Task {
            // Ask the question out loud once per step, then listen.
            if guided, spokenStep != step {
                spokenStep = step
                speaking = true
                await prompt.say(step.spoken)
                speaking = false
            }
            do {
                try await recorder.start()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
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
        // Silence (a pocket, a quiet room, the mic covered): don't make a recording or a job.
        guard clip.heardSound else {
            try? FileManager.default.removeItem(at: AudioStorage.directory.appendingPathComponent(clip.fileName))
            phase = .nothingHeard
            return
        }
        save(clip.fileName, duration: clip.duration, answering: nil)
        phase = .saved
    }

    /// Ends the client or address step and moves on. Silence or "Skip this" saves nothing.
    private func finishStep(keep: Bool) {
        guard let clip = recorder.stop(deactivate: false) else { return }
        if keep, clip.heardSound, clip.duration >= 1 {
            save(clip.fileName, duration: clip.duration, answering: step.kind)
        } else {
            try? FileManager.default.removeItem(at: AudioStorage.directory.appendingPathComponent(clip.fileName))
        }
        if let next = step.next { step = next }
        begin()
    }

    private func save(_ fileName: String, duration: TimeInterval, answering kind: GuidedAnswer.Kind?) {
        // The job may have been removed meanwhile (an earlier clip turned out to be silence).
        if let current = job, current.isGone { job = nil }
        if let job {
            processor.add(fileName: fileName, duration: duration, to: job, answering: kind)
        } else {
            job = processor.startNewJob(fileName: fileName, duration: duration, answering: kind)
        }
    }
}
