import Foundation
import FoundationModels
import InvoiceCore

/// Pulls client, items and prices out of a transcript with Apple's on-device model (iOS 26).
/// Free and private, but needs an iPhone with Apple Intelligence (iPhone 15 Pro or newer) with it turned on.
enum OnDeviceExtractor {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// A plain-English reason the model can't be used, or nil if it can.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This iPhone can't run Apple's on-device AI. It needs an iPhone 15 Pro or newer."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings so the app can write up jobs."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading. It will try again later."
        case .unavailable:
            return "Apple's on-device AI isn't available right now."
        }
    }

    static func extract(_ request: ExtractionRequest) async throws -> ExtractionResult {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt(for: request), generating: JobNotes.self)
        return response.content.asResult()
    }

    static func prompt(for request: ExtractionRequest) -> String {
        var parts: [String] = []
        // Keep the prompt small: the on-device model has a short context window.
        let clients = request.knownClients.suffix(50)
        if !clients.isEmpty { parts.append("Known clients:\n" + clients.joined(separator: "\n")) }
        if !request.existingItems.isEmpty {
            parts.append("Items already on this job (do not repeat):\n" + request.existingItems.joined(separator: "\n"))
        }
        parts.append("Transcript:\n" + request.transcript)
        return parts.joined(separator: "\n\n")
    }

    static let instructions = """
    You read a transcript of a handyman describing a job and copy out the details he said.
    Copy only what is in the transcript. Do not add anything that is not in it.

    Rules:
    - Every item must be something the transcript says was done or charged for. If no work is described, return no items.
    - A price must be a number said in the transcript. If no price is said for an item, leave its price empty.
    - Prices are US dollars. For a per-unit or hourly price, set quantity to the count or hours. Otherwise quantity is 1.
    - Leave any field empty if the transcript does not mention it.
    - Write spoken email addresses with @ and dots.
    - If the client's name matches a known client, use that spelling.
    - Do not repeat items already on the job.
    """
}

@Generable
struct JobNotes {
    @Guide(description: "The client's name, if mentioned")
    var clientName: String?
    @Guide(description: "The client's email address, written normally")
    var clientEmail: String?
    @Guide(description: "The client's phone number")
    var clientPhone: String?
    @Guide(description: "Where the job was done")
    var jobAddress: String?
    @Guide(description: "A few words summarizing the job, only if work is described")
    var jobTitle: String?
    @Guide(description: "Each thing the transcript says was done or charged for. Empty if none.")
    var items: [JobNotesItem]
    @Guide(description: "Anything unclear the reviewer should check")
    var notes: String?

    func asResult() -> ExtractionResult {
        ExtractionResult(
            clientName: clientName.nonEmpty,
            clientEmail: clientEmail.nonEmpty,
            clientPhone: clientPhone.nonEmpty,
            jobAddress: jobAddress.nonEmpty,
            jobTitle: jobTitle.nonEmpty,
            items: items.map {
                ExtractedItem(
                    description: $0.title,
                    quantity: $0.quantity > 0 ? $0.quantity : 1,
                    unitPriceCents: $0.priceDollars.map { Int(($0 * 100).rounded()) },
                    details: $0.details.nonEmpty
                )
            },
            notes: notes.nonEmpty
        )
    }
}

@Generable
struct JobNotesItem {
    @Guide(description: "Short description of work the transcript says was done")
    var title: String
    @Guide(description: "How many units or hours; 1 if a single total")
    var quantity: Double
    @Guide(description: "Price per unit in US dollars, only if the transcript says it")
    var priceDollars: Double?
    @Guide(description: "Materials, sizes or other specifics")
    var details: String?
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
