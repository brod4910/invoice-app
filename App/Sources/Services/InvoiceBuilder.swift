import Foundation
import InvoiceCore
import SwiftData

/// Turns a job into an invoice document, and records the draft once Gmail accepts it.
@MainActor
enum InvoiceBuilder {
    static func document(for job: Job, number: Int) -> InvoiceDocument {
        InvoiceDocument(
            number: number,
            date: Date(),
            business: BusinessSettings.info,
            clientName: job.client?.name ?? (job.clientNameHint == "Unknown client" ? "" : job.clientNameHint),
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

    /// Everything that appears on the invoice, so a change to any of it can be detected.
    static func fingerprint(for job: Job) -> String {
        var parts = [job.client?.name ?? job.clientNameHint, job.client?.email ?? "", job.displayAddress, job.title]
        parts += job.sortedItems.map { "\($0.itemDescription)|\($0.details)|\($0.quantity)|\($0.unitPriceCents ?? -1)" }
        return parts.joined(separator: "\n")
    }

    /// True when the job has a Gmail draft that no longer matches the job.
    static func draftIsOutOfDate(_ job: Job) -> Bool {
        guard let invoice = job.latestInvoice, !invoice.gmailDraftID.isEmpty else { return false }
        return invoice.fingerprint != fingerprint(for: job)
    }

    /// Puts the invoice in Gmail drafts, overwriting this job's earlier draft if there is one.
    /// Returns a message to show.
    static func saveToGmail(job: Job, gmail: GmailClient, context: ModelContext) async throws -> String {
        if !gmail.isSignedIn { try await gmail.signIn() }
        let existing = job.latestInvoice
        let number = existing?.number ?? BusinessSettings.nextInvoiceNumber
        let doc = document(for: job, number: number)
        let to = job.client?.email
        let pdf = MIMEMessage.Attachment(filename: doc.pdfFilename, mimeType: "application/pdf", data: InvoicePDF.make(doc))
        let result = try await gmail.saveDraft(
            replacing: existing?.gmailDraftID,
            to: to,
            subject: doc.subject,
            html: InvoiceRenderer.coverNoteHTML(doc),
            text: InvoiceRenderer.coverNoteText(doc),
            attachments: [pdf]
        )

        let invoice: Invoice
        if let existing {
            invoice = existing
        } else {
            invoice = Invoice(number: number, sentTo: "", gmailDraftID: "", totalCents: 0)
            context.insert(invoice)
            invoice.job = job
            BusinessSettings.nextInvoiceNumber = number + 1
        }
        invoice.gmailDraftID = result.id
        invoice.sentTo = to ?? ""
        invoice.totalCents = doc.totalCents
        invoice.fingerprint = fingerprint(for: job)
        invoice.updatedAt = Date()
        job.status = .invoiced
        try? context.save()

        switch result {
        case .updated:
            return "Your Gmail draft has been updated with the latest items. Open Gmail, check it, and press Send."
        case .created(_, let replacedMissing):
            return replacedMissing
                ? "The earlier draft was already sent or deleted in Gmail, so a new draft was made. Check Gmail before sending it."
                : "The invoice is in your Gmail drafts. Open Gmail, check it, and press Send."
        }
    }

    /// Problems worth showing before drafting. Empty means good to go.
    static func warnings(for job: Job) -> [String] {
        var out: [String] = []
        if job.needsClientChoice {
            out.append("It isn't clear which client this is, so the email is left blank. Tap the name to choose.")
        } else if job.client == nil || job.client?.name.isEmpty == true {
            out.append("Who is this for? Add the client's name.")
        }
        if !EmailAddress.isPlausible(job.client?.email) { out.append("The client's email address is missing or looks wrong.") }
        if job.items.isEmpty { out.append("There are no items on this job.") }
        if job.hasMissingPrices { out.append("Some items don't have a price yet.") }
        return out
    }
}
