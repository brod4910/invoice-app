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
        if !title.isEmpty { return title }
        return "New job"
    }

    var isProcessing: Bool { recordings.contains { $0.state == .transcribing || $0.state == .extracting } }
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
    var createdAt: Date = Date()
    var totalCents: Int = 0

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
