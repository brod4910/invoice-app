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
    You turn a handyman's spoken description of a finished job into invoice line items.
    The transcript comes from speech-to-text, so expect filler words, restarts and numbers spelled out.
    A person reviews the invoice before it is sent, so be accurate rather than complete.

    Rules:
    - Only use prices the speaker actually says. If an item has no stated price, leave its price empty. Never guess a price.
    - Prices are in US dollars: "a hundred and twenty five bucks" is 125, "forty an hour" is 40.
    - For a per-unit or hourly price, set quantity to the count or hours and the price to the rate. For one total, use quantity 1.
    - Keep descriptions short and client-friendly. Put materials, brands or sizes in details.
    - If the speaker corrects something, use the corrected value.
    - Write spoken email addresses normally: "mary at gmail dot com" is mary@gmail.com.
    - If the client's name sounds like a known client, use the known spelling exactly.
    - Return only new items, not ones already on the job.
    - Leave a field empty if it wasn't mentioned.
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
    @Guide(description: "A few words summarizing the job, e.g. Fence repair")
    var jobTitle: String?
    @Guide(description: "Each thing done or charged for, in the order mentioned")
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
    @Guide(description: "Short, client-friendly description, e.g. Replace kitchen faucet")
    var title: String
    @Guide(description: "How many units or hours; 1 if a single total")
    var quantity: Double
    @Guide(description: "Price per unit in US dollars, only if spoken")
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
