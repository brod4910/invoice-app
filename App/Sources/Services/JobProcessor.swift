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
    /// Jobs whose screen is open right now; deleting one of those under the screen could crash.
    private var openJobs = Set<UUID>()

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

    private func discard(_ recording: Recording) {
        let job = recording.job
        try? FileManager.default.removeItem(at: recording.fileURL)
        context.delete(recording)
        try? context.save()
        // Remove the job too if that was all it had. If its screen is open, the screen closes
        // itself and the job is removed as it closes (see jobScreenClosed).
        if let job, job.isEmpty, !openJobs.contains(job.id) {
            context.delete(job)
            try? context.save()
        }
    }

    func jobScreenOpened(_ job: Job) { openJobs.insert(job.id) }

    func jobScreenClosed(_ job: Job) {
        openJobs.remove(job.id)
        guard !job.isGone, job.isEmpty, !job.isProcessing else { return }
        context.delete(job)
        try? context.save()
    }

    /// Removes jobs that ended up empty (only silence was recorded), e.g. if the app was
    /// closed mid-way. Runs at launch, when no job screen is open.
    /// Folds together clients saved twice under the same name (e.g. by tapping "New client"
    /// for a name that already existed), which would otherwise make every later job ask
    /// "Which client is this?". Clients with the same name but different emails are left alone.
    func mergeDuplicateClients() {
        let clients = (try? context.fetch(FetchDescriptor<Client>())) ?? []
        let groups = Dictionary(grouping: clients.filter { !$0.name.isEmpty }) { ClientMatching.normalize($0.name) }
        for (_, group) in groups where group.count > 1 {
            let emails = Set(group.map { $0.email.lowercased() }.filter { !$0.isEmpty })
            guard emails.count <= 1 else { continue }
            let keep = group.max { $0.jobs.count < $1.jobs.count }!
            for other in group where other.id != keep.id {
                for job in other.jobs { job.client = keep }
                if keep.email.isEmpty { keep.email = other.email }
                if keep.phone.isEmpty { keep.phone = other.phone }
                if keep.address.isEmpty { keep.address = other.address }
                context.delete(other)
            }
        }
        try? context.save()
    }

    func removeEmptyJobs() {
        let jobs = (try? context.fetch(FetchDescriptor<Job>())) ?? []
        for job in jobs where job.isEmpty {
            context.delete(job)
        }
        try? context.save()
    }

    /// Re-runs anything that failed or was interrupted, e.g. after the phone regains signal.
    func retryPending() async {
        let descriptor = FetchDescriptor<Recording>()
        let all = (try? context.fetch(descriptor)) ?? []
        for recording in all where recording.state != .done && !running.contains(recording.id) {
            await process(recording)
        }
    }

    /// After the words of a recording are corrected: throw away the items that recording made
    /// and write them up again from the new words.
    func redo(_ recording: Recording) async {
        removeItems(madeBy: recording)
        recording.state = .recorded
        recording.lastError = ""
        try? context.save()
        await process(recording)
    }

    /// Dad said it again: the new clip takes the old one's place, along with the items it made.
    func replace(_ recording: Recording, fileName: String, duration: TimeInterval) {
        removeItems(madeBy: recording)
        try? FileManager.default.removeItem(at: recording.fileURL)
        recording.fileName = fileName
        recording.duration = duration
        recording.recordedAt = Date()
        recording.transcript = ""
        recording.state = .recorded
        recording.lastError = ""
        if let job = recording.job, job.status == .invoiced { job.status = .draft }
        try? context.save()
        Task { await process(recording) }
    }

    private func removeItems(madeBy recording: Recording) {
        guard let job = recording.job else { return }
        for item in job.items where item.sourceRecordingID == recording.id {
            context.delete(item)
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
            guard !recording.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // No words were heard: drop the recording. A job left with nothing in it is
                // cleaned up the next time the app opens (it may be on screen right now).
                discard(recording)
                return
            }

            recording.state = .extracting
            try? context.save()
            guard let job = recording.job else { return }
            // Number the current items so a spoken correction ("I meant living room") can point at one.
            let current = job.sortedItems
            let existing = current.map {
                ExistingItem(description: $0.itemDescription, unitPriceCents: $0.unitPriceCents, quantity: $0.quantity)
            }
            let request = ExtractionRequest(
                transcript: recording.transcript,
                existingItems: ExistingItem.numberedList(existing),
                knownClients: knownClientNames()
            )
            let result = try await ExtractionClient.extract(request, existing: existing)
            applyChanges(result.changes, to: current)
            apply(result, to: job, from: recording)
            recording.state = .done
            recording.lastError = ""
        } catch {
            recording.state = .failed
            recording.lastError = error.localizedDescription
        }
        try? context.save()
    }

    /// Edits items in place for spoken corrections. `items` is the list the numbers refer to.
    private func applyChanges(_ changes: [ItemChange], to items: [LineItem]) {
        for change in changes where items.indices.contains(change.itemNumber - 1) {
            let item = items[change.itemNumber - 1]
            if change.remove {
                context.delete(item)
                continue
            }
            if let text = change.newDescription { item.itemDescription = text }
            if let cents = change.newUnitPriceCents { item.unitPriceCents = cents }
            if let quantity = change.newQuantity { item.quantity = quantity }
        }
    }

    private func apply(_ result: ExtractionResult, to job: Job, from recording: Recording) {
        if job.address.isEmpty, let address = result.jobAddress { job.address = address }
        if job.client == nil { resolveClient(for: job, spokenName: result.clientName) }
        if let client = job.client {
            if client.email.isEmpty, let email = result.clientEmail { client.email = email }
            if client.phone.isEmpty, let phone = result.clientPhone { client.phone = phone }
        }
        if let client = job.client, client.email.isEmpty, !client.name.isEmpty {
            lookUpEmail(for: client, address: job.address)
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

    /// Fills a client's email from contacts or Gmail when exactly one address matches.
    private func lookUpEmail(for client: Client, address: String) {
        Task { await findEmail(for: client, address: address) }
    }

    /// Looks up and saves the client's email. Returns true if one was found.
    @discardableResult
    func findEmail(for client: Client, address: String) async -> Bool {
        let name = client.name
        let own = UserDefaults.standard.string(forKey: "gmail.signedInEmail")
        guard let email = await ContactLookup.email(forName: name, address: address, ownEmail: own),
              client.modelContext != nil, client.email.isEmpty, client.name == name else { return false }
        client.email = email
        try? context.save()
        return true
    }

    private func knownClientNames() -> [String] {
        ((try? context.fetch(FetchDescriptor<Client>())) ?? []).map(\.name)
    }

    /// Links the job to a past client when the name and/or address make it clear who it is.
    /// When it isn't clear, the job keeps the spoken name but no client, so the email stays blank
    /// and the job screen asks which client it is.
    private func resolveClient(for job: Job, spokenName: String?) {
        mergeDuplicateClients()
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
