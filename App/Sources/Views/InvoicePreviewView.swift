import InvoiceCore
import SwiftData
import SwiftUI
import PDFKit

struct InvoicePreviewView: View {
    @Bindable var job: Job
    @Environment(GmailClient.self) private var gmail
    @Environment(\.modelContext) private var context
    @State private var working = false
    @State private var message: String?
    @State private var succeeded = false

    /// Reuse the job's earlier invoice number if it already has one, so numbers don't skip.
    private var number: Int {
        job.invoices.sorted { $0.createdAt < $1.createdAt }.last?.number ?? BusinessSettings.nextInvoiceNumber
    }

    var body: some View {
        let doc = InvoiceBuilder.document(for: job, number: number)
        let warnings = InvoiceBuilder.warnings(for: job)

        VStack(spacing: 0) {
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill") }
                }
                .font(.title3)
                .foregroundStyle(.orange)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            PDFPreview(data: InvoicePDF.make(doc))

            VStack(spacing: 12) {
                if let message {
                    Text(message)
                        .font(.title3)
                        .foregroundStyle(succeeded ? .green : .red)
                        .multilineTextAlignment(.center)
                }
                Button { Task { await draft(doc) } } label: {
                    if working {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 72)
                    } else {
                        Label(succeeded ? "Draft again" : "Put in Gmail drafts", systemImage: "envelope.fill")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || job.items.isEmpty)
            }
            .padding()
        }
        .navigationTitle("Invoice #\(doc.formattedNumber)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func draft(_ doc: InvoiceDocument) async {
        working = true
        defer { working = false }
        do {
            if !gmail.isSignedIn { try await gmail.signIn() }
            let to = job.client?.email
            let pdf = MIMEMessage.Attachment(filename: doc.pdfFilename, mimeType: "application/pdf", data: InvoicePDF.make(doc))
            let id = try await gmail.createDraft(
                to: to,
                subject: doc.subject,
                html: InvoiceRenderer.coverNoteHTML(doc),
                text: InvoiceRenderer.coverNoteText(doc),
                attachments: [pdf]
            )
            let isNewNumber = job.invoices.isEmpty
            let invoice = Invoice(number: doc.number, sentTo: to ?? "", gmailDraftID: id, totalCents: doc.totalCents)
            context.insert(invoice)
            invoice.job = job
            job.status = .invoiced
            if isNewNumber { BusinessSettings.nextInvoiceNumber = doc.number + 1 }
            try? context.save()
            succeeded = true
            message = "The invoice is in your Gmail drafts. Open Gmail, check it, and press Send."
        } catch {
            succeeded = false
            message = error.localizedDescription
        }
    }
}

/// Shows the exact PDF that will be attached.
private struct PDFPreview: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.document = PDFDocument(data: data)
    }
}
