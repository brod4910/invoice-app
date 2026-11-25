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
        parts += job.sortedMedia.map { "media|\($0.fileName)" }
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

        // Photos ride along as attachments while they fit in Gmail's 25 MB. Videos, and any
        // photos that don't fit, go to Google Drive and are linked in the email instead.
        let photos = job.sortedMedia.filter { !$0.isVideo }
        let fits = MediaBudget.pick(sizes: photos.map(\.byteSize))
        var attachments = [pdf]
        for (n, index) in fits.attach.enumerated() {
            guard let data = try? Data(contentsOf: photos[index].fileURL) else { continue }
            attachments.append(MIMEMessage.Attachment(filename: "Photo-\(n + 1).jpg", mimeType: "image/jpeg", data: data))
        }
        let shared = fits.skip.map { photos[$0] } + job.sortedMedia.filter(\.isVideo)
        var links: [MediaLink] = []
        var videoNumber = 0, photoNumber = fits.attach.count
        for media in shared {
            let title: String
            if media.isVideo { videoNumber += 1; title = "Video \(videoNumber)" } else { photoNumber += 1; title = "Photo \(photoNumber)" }
            let name = "Invoice \(doc.formattedNumber) - \(doc.clientName.isEmpty ? "job" : doc.clientName) - \(title).\(media.isVideo ? "mp4" : "jpg")"
            links.append(MediaLink(title: title, url: try await DriveClient.shareLink(for: media, name: name)))
            try? context.save()
        }

        let result = try await gmail.saveDraft(
            replacing: existing?.gmailDraftID,
            to: to,
            subject: doc.subject,
            html: InvoiceRenderer.coverNoteHTML(doc, photosAttached: attachments.count - 1, mediaLinks: links),
            text: InvoiceRenderer.coverNoteText(doc, photosAttached: attachments.count - 1, mediaLinks: links),
            attachments: attachments
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

        // The private job record goes in a second draft, never to the client. If it fails,
        // the invoice draft is still fine; it's tried again on the next update.
        let record = jobRecord(for: job, number: number)
        let recordTo = BusinessSettings.recordEmail
        if let saved = try? await gmail.saveDraft(
            replacing: invoice.recordDraftID,
            to: EmailAddress.isPlausible(recordTo) ? recordTo : nil,
            subject: record.subject,
            html: record.html(),
            text: record.plainText()
        ) {
            invoice.recordDraftID = saved.id
            try? context.save()
        }

        switch result {
        case .updated:
            return "Your Gmail draft has been updated with the latest items. Open Gmail, check it, and press Send. The job record draft was updated too."
        case .created(_, let replacedMissing):
            return replacedMissing
                ? "The earlier draft was already sent or deleted in Gmail, so a new draft was made. Check Gmail before sending it."
                : "The invoice is in your Gmail drafts, with a second draft holding everything you said. Open Gmail, check the invoice, and press Send."
        }
    }

    static func jobRecord(for job: Job, number: Int) -> JobRecord {
        JobRecord(
            invoiceNumber: number,
            clientName: job.client?.name ?? (job.clientNameHint == "Unknown client" ? "" : job.clientNameHint),
            address: job.displayAddress,
            jobDate: job.jobDate,
            items: job.sortedItems.map {
                JobRecord.Item(description: $0.itemDescription, quantity: $0.quantity, unitPriceCents: $0.unitPriceCents)
            },
            said: job.sortedRecordings.filter { !$0.transcript.isEmpty }.map {
                JobRecord.Said(at: $0.recordedAt, text: $0.transcript)
            },
            notes: job.notes
        )
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
