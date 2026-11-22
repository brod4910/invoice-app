import Foundation
import InvoiceCore

/// Turns a job into an invoice document, and records the draft once Gmail accepts it.
@MainActor
enum InvoiceBuilder {
    static func document(for job: Job, number: Int) -> InvoiceDocument {
        InvoiceDocument(
            number: number,
            date: Date(),
            business: BusinessSettings.info,
            clientName: job.client?.name ?? "",
            clientEmail: job.client?.email,
            jobAddress: job.address.isEmpty ? job.client?.address : job.address,
            jobTitle: job.title,
            lines: job.sortedItems.map {
                InvoiceLine(
                    description: $0.itemDescription,
                    details: $0.details,
                    quantity: $0.quantity,
                    unitPriceCents: $0.unitPriceCents ?? 0
                )
            },
            notes: nil
        )
    }

    /// Problems worth showing before drafting. Empty means good to go.
    static func warnings(for job: Job) -> [String] {
        var out: [String] = []
        if job.client == nil || job.client?.name.isEmpty == true { out.append("Who is this for? Add the client's name.") }
        if !EmailAddress.isPlausible(job.client?.email) { out.append("The client's email address is missing or looks wrong.") }
        if job.items.isEmpty { out.append("There are no items on this job.") }
        if job.hasMissingPrices { out.append("Some items don't have a price yet.") }
        return out
    }
}
