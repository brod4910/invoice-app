import Foundation
import SwiftData
import InvoiceCore

@Model
final class Client {
    var id: UUID = UUID()
    var name: String = ""
    var email: String = ""
    var phone: String = ""
    var address: String = ""
    @Relationship(inverse: \Job.client) var jobs: [Job] = []

    init(name: String, email: String = "", phone: String = "", address: String = "") {
        self.name = name
        self.email = email
        self.phone = phone
        self.address = address
    }
}

enum JobStatus: String, Codable, CaseIterable {
    case draft, ready, invoiced

    var label: String {
        switch self {
        case .draft: "Needs review"
        case .ready: "Ready"
        case .invoiced: "Invoiced"
        }
    }
}

@Model
final class Job {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var jobDate: Date = Date()
    var title: String = ""
    var address: String = ""
    var notes: String = ""
    /// The spoken client name when it couldn't be matched to one past client (ambiguous).
    /// Non-empty means the job screen asks "Which client is this?".
    var clientNameHint: String = ""
    var statusRaw: String = JobStatus.draft.rawValue
    var client: Client?
    @Relationship(deleteRule: .cascade, inverse: \Recording.job) var recordings: [Recording] = []
    @Relationship(deleteRule: .cascade, inverse: \LineItem.job) var items: [LineItem] = []
    @Relationship(deleteRule: .cascade, inverse: \Invoice.job) var invoices: [Invoice] = []

    init(jobDate: Date = Date()) {
        self.jobDate = jobDate
        self.createdAt = Date()
    }

    var status: JobStatus {
        get { JobStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    var sortedItems: [LineItem] { items.sorted { $0.sortIndex < $1.sortIndex } }
    var sortedRecordings: [Recording] { recordings.sorted { $0.recordedAt < $1.recordedAt } }

    /// Calculated, never stored, so it can't drift from the line items.
    var totalCents: Int { items.reduce(0) { $0 + $1.totalCents } }

    var hasMissingPrices: Bool { items.contains { $0.unitPriceCents == nil } }

    var displayTitle: String {
        if let name = client?.name, !name.isEmpty { return name }
        if !clientNameHint.isEmpty { return clientNameHint }
        if !title.isEmpty { return title }
        return "New job"
    }

    /// The job's address, or the client's address if the job has none.
    var displayAddress: String {
        if !address.isEmpty { return address }
        return client?.address ?? ""
    }

    /// The invoice drafted for this job, if any (one per job; re-drafting updates it).
    var latestInvoice: Invoice? { invoices.max { $0.updatedAt < $1.updatedAt } }

    var needsClientChoice: Bool { client == nil && !clientNameHint.isEmpty }

    var isProcessing: Bool { recordings.contains { $0.state == .transcribing || $0.state == .extracting } }

    /// True when only silence was recorded: nothing heard, nothing typed, nothing invoiced.
    var isEmpty: Bool { recordings.isEmpty && items.isEmpty && invoices.isEmpty }

    /// True once the job has been deleted, so screens holding on to it can let go.
    var isGone: Bool { isDeleted || modelContext == nil }
}

enum RecordingState: String, Codable {
    case recorded, transcribing, extracting, done, failed
}

@Model
final class Recording {
    var id: UUID = UUID()
    var job: Job?
    /// File name inside the app's Documents/Recordings folder.
    var fileName: String = ""
    var transcript: String = ""
    var recordedAt: Date = Date()
    var duration: TimeInterval = 0
    var stateRaw: String = RecordingState.recorded.rawValue
    var lastError: String = ""
    /// Set when this clip answered one of the recorder's questions: "client" or "address".
    var guidedKindRaw: String = ""

    init(fileName: String, duration: TimeInterval) {
        self.fileName = fileName
        self.duration = duration
        self.recordedAt = Date()
    }

    var state: RecordingState {
        get { RecordingState(rawValue: stateRaw) ?? .recorded }
        set { stateRaw = newValue.rawValue }
    }

    var fileURL: URL { AudioStorage.directory.appendingPathComponent(fileName) }

    var guidedKind: GuidedAnswer.Kind? { GuidedAnswer.Kind(rawValue: guidedKindRaw) }
}

@Model
final class LineItem {
    var id: UUID = UUID()
    var job: Job?
    var itemDescription: String = ""
    var details: String = ""
    var quantity: Double = 1
    /// nil means Dad didn't say a price; the UI flags it.
    var unitPriceCents: Int?
    var sortIndex: Int = 0
    var sourceRecordingID: UUID?

    init(description: String, details: String = "", quantity: Double = 1, unitPriceCents: Int?, sortIndex: Int, sourceRecordingID: UUID? = nil) {
        self.itemDescription = description
        self.details = details
        self.quantity = quantity
        self.unitPriceCents = unitPriceCents
        self.sortIndex = sortIndex
        self.sourceRecordingID = sourceRecordingID
    }

    var totalCents: Int {
        guard let price = unitPriceCents else { return 0 }
        return Money.lineTotal(quantity: quantity, unitPriceCents: price)
    }
}

@Model
final class Invoice {
    var id: UUID = UUID()
    var job: Job?
    var number: Int = 0
    var sentTo: String = ""
    var gmailDraftID: String = ""
    /// The private job-record draft (transcripts and notes) made next to the invoice.
    var recordDraftID: String = ""
    var createdAt: Date = Date()
    var totalCents: Int = 0
    /// What the drafted invoice contained, to tell when the job has changed since.
    var fingerprint: String = ""
    var updatedAt: Date = Date()

    init(number: Int, sentTo: String, gmailDraftID: String, totalCents: Int) {
        self.number = number
        self.sentTo = sentTo
        self.gmailDraftID = gmailDraftID
        self.totalCents = totalCents
        self.createdAt = Date()
    }
}

enum AudioStorage {
    static var directory: URL {
        let url = URL.documentsDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
