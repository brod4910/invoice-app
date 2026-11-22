import InvoiceCore
import SwiftData
import SwiftUI
import WebKit

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

            HTMLView(html: InvoiceRenderer.html(doc))

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
            let id = try await gmail.createDraft(
                to: to,
                subject: doc.subject,
                html: InvoiceRenderer.html(doc),
                text: InvoiceRenderer.plainText(doc)
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

private struct HTMLView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.loadHTMLString(html, baseURL: nil)
    }
}
