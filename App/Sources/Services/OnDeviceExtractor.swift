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
        // Greedy sampling: the same words always give the same write-up.
        let response = try await session.respond(
            to: prompt(for: request),
            generating: JobNotes.self,
            options: GenerationOptions(sampling: .greedy)
        )
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
    - Make one charge for each price said. Put all the work that one price pays for in that charge.
    - When one price covers several tasks, such as a price for the whole job, for both, or a total, those tasks share one charge. Do not split them up.
    - Only make a charge with an empty price for work that clearly has no price said for it.
    - Every charge must be work the transcript says was done. If no work is described, return no charges.
    - A price must be a number said in the transcript. Never make up a price.
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
    @Guide(description: "One entry per price said, holding all the work that price pays for. Empty if no work is described.")
    var charges: [JobNotesCharge]
    @Guide(description: "Anything unclear the reviewer should check")
    var notes: String?

    func asResult() -> ExtractionResult {
        ExtractionResult(
            clientName: clientName.nonEmpty,
            clientEmail: clientEmail.nonEmpty,
            clientPhone: clientPhone.nonEmpty,
            jobAddress: jobAddress.nonEmpty,
            jobTitle: jobTitle.nonEmpty,
            items: charges.map {
                ExtractedItem(
                    description: ExtractionGrounding.joinWork($0.work),
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
struct JobNotesCharge {
    @Guide(description: "Every task this one price pays for, a few words each, as said. Several tasks when one price covers them all.")
    var work: [String]
    @Guide(description: "How many units or hours; 1 for a flat price")
    var quantity: Double
    @Guide(description: "The price said for this work in US dollars, per unit or hour if quantity is more than 1. Empty only if no price was said for it.")
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
