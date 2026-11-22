import Foundation
import InvoiceCore
import Observation
import SwiftData

/// Runs each recording through transcription and extraction, then adds the results to its job.
/// Failures leave the recording in a retryable state; nothing Dad said is ever thrown away.
@MainActor
@Observable
final class JobProcessor {
    private let context: ModelContext
    private var running = Set<UUID>()

    init(context: ModelContext) {
        self.context = context
    }

    /// Creates a new job holding this recording, and starts processing it.
    @discardableResult
    func startNewJob(fileName: String, duration: TimeInterval) -> Job {
        let job = Job()
        context.insert(job)
        add(fileName: fileName, duration: duration, to: job)
        return job
    }

    /// Adds another recording to an existing job (an accidental stop, or something forgotten).
    func add(fileName: String, duration: TimeInterval, to job: Job) {
        let recording = Recording(fileName: fileName, duration: duration)
        context.insert(recording)
        recording.job = job
        if job.status == .invoiced { job.status = .draft }
        try? context.save()
        Task { await process(recording) }
    }

    /// Re-runs anything that failed or was interrupted, e.g. after the phone regains signal.
    func retryPending() async {
        let descriptor = FetchDescriptor<Recording>()
        let all = (try? context.fetch(descriptor)) ?? []
        for recording in all where recording.state != .done && !running.contains(recording.id) {
            await process(recording)
        }
    }

    func process(_ recording: Recording) async {
        guard !running.contains(recording.id) else { return }
        running.insert(recording.id)
        defer { running.remove(recording.id) }

        do {
            if recording.transcript.isEmpty {
                recording.state = .transcribing
                try? context.save()
                recording.transcript = try await Transcriber.transcribe(fileURL: recording.fileURL)
            }
            guard !recording.transcript.isEmpty else {
                recording.state = .done
                try? context.save()
                return
            }

            recording.state = .extracting
            try? context.save()
            guard let job = recording.job else { return }
            let request = ExtractionRequest(
                transcript: recording.transcript,
                existingItems: job.sortedItems.map(\.itemDescription),
                knownClients: knownClientNames()
            )
            let result = try await ExtractionClient.extract(request)
            apply(result, to: job, from: recording)
            recording.state = .done
            recording.lastError = ""
        } catch {
            recording.state = .failed
            recording.lastError = error.localizedDescription
        }
        try? context.save()
    }

    private func apply(_ result: ExtractionResult, to job: Job, from recording: Recording) {
        if job.address.isEmpty, let address = result.jobAddress { job.address = address }
        if job.client == nil { resolveClient(for: job, spokenName: result.clientName) }
        if let client = job.client {
            if client.email.isEmpty, let email = result.clientEmail { client.email = email }
            if client.phone.isEmpty, let phone = result.clientPhone { client.phone = phone }
        }
        if job.title.isEmpty, let title = result.jobTitle { job.title = title }
        if let notes = result.notes, !notes.isEmpty {
            job.notes = job.notes.isEmpty ? notes : job.notes + "\n" + notes
        }

        var next = (job.items.map(\.sortIndex).max() ?? -1) + 1
        for item in result.items {
            let line = LineItem(
                description: item.description,
                details: item.details ?? "",
                quantity: item.quantity,
                unitPriceCents: item.unitPriceCents,
                sortIndex: next,
                sourceRecordingID: recording.id
            )
            context.insert(line)
            line.job = job
            next += 1
        }
        job.status = .draft
    }

    private func knownClientNames() -> [String] {
        ((try? context.fetch(FetchDescriptor<Client>())) ?? []).map(\.name)
    }

    /// Links the job to a past client when the name and/or address make it clear who it is.
    /// When it isn't clear, the job keeps the spoken name but no client, so the email stays blank
    /// and the job screen asks which client it is.
    private func resolveClient(for job: Job, spokenName: String?) {
        let clients = ((try? context.fetch(FetchDescriptor<Client>())) ?? []).filter { !$0.name.isEmpty }
        let history = clients.map { client in
            ClientRecord(
                id: client.id,
                name: client.name,
                addresses: client.jobs.filter { $0.id != job.id }.map(\.address) + [client.address]
            )
        }
        var name = spokenName?.trimmingCharacters(in: .whitespaces) ?? ""
        // A follow-up recording without a name keeps the name said earlier.
        if name.isEmpty, job.clientNameHint != "Unknown client" { name = job.clientNameHint }

        switch ClientResolver.resolve(name: name, address: job.address, history: history) {
        case .existing(let id):
            guard let client = clients.first(where: { $0.id == id }) else { return }
            job.client = client
            job.clientNameHint = ""
            // Repeat job, no address said: use the client's address if they've only ever had one.
            if job.address.isEmpty, let record = history.first(where: { $0.id == id }),
               let usual = ClientResolver.usualAddress(of: record) {
                job.address = usual
            }
        case .new:
            let client = Client(name: name)
            context.insert(client)
            job.client = client
            job.clientNameHint = ""
        case .ambiguous:
            job.clientNameHint = name.isEmpty ? "Unknown client" : name
        case .unknown:
            break
        }
    }
}
