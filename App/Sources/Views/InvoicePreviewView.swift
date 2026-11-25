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
    @State private var emailSearch: EmailSearch = .idle
    @Environment(JobProcessor.self) private var processor

    enum EmailSearch { case idle, searching, found, notFound, choose([EmailSuggestion]) }

    /// Reuse the job's earlier invoice number if it already has one, so numbers don't skip.
    private var number: Int {
        job.latestInvoice?.number ?? BusinessSettings.nextInvoiceNumber
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
            emailSearchStatus

            PDFPreview(data: InvoicePDF.make(doc))

            VStack(spacing: 12) {
                if working, job.media.contains(where: { $0.isVideo && $0.driveLink.isEmpty }) {
                    Text("Putting the videos on Google Drive. This can take a few minutes. Keep the app open.")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                }
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
                        Label(job.latestInvoice == nil ? "Put in Gmail drafts" : "Update Gmail draft", systemImage: "envelope.fill")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || job.items.isEmpty)
            }
            .padding()
        }
        .task { await searchForEmail() }
        .navigationTitle("Invoice #\(doc.formattedNumber)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func draft(_ doc: InvoiceDocument) async {
        working = true
        defer { working = false }
        do {
            message = try await InvoiceBuilder.saveToGmail(job: job, gmail: gmail, context: context)
            succeeded = true
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

extension InvoicePreviewView {
    @ViewBuilder
    fileprivate var emailSearchStatus: some View {
        switch emailSearch {
        case .searching:
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking for the client's email in your contacts and Gmail…")
            }
            .font(.title3)
            .padding(.horizontal)
        case .found:
            Label("Found the email: \(job.client?.email ?? "")", systemImage: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .padding(.horizontal)
        case .notFound:
            Text(job.client == nil
                 ? "Choose the client on the job screen first."
                 : "Couldn't find one clear email for \(job.client?.name ?? "this client"). Tap the client's name on the job screen to type it.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        case .choose(let people):
            emailChoices(people)
        case .idle:
            EmptyView()
        }
    }

    /// Several people for one client, like Veronica and Earle at Crown Management: Dad taps who
    /// gets the invoice. It's saved on the client, so he's only asked once.
    fileprivate func emailChoices(_ people: [EmailSuggestion]) -> some View {
        let clientName = job.client?.name ?? "this client"
        return VStack(alignment: .leading, spacing: 10) {
            Text("Who gets the invoice for \(clientName)?")
                .font(.title3.bold())
            ForEach(people) { person in
                Button {
                    guard let client = job.client else { return }
                    client.email = person.email
                    try? context.save()
                    emailSearch = .found
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name.isEmpty ? person.email : person.name).font(.title3.bold())
                        if !person.name.isEmpty { Text(person.email).font(.body) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            Text(people.contains(where: \.strong)
                 ? "None of these? Tap the client's name on the job screen to type it."
                 : "These might be from \(clientName). None of them? Tap the client's name on the job screen to type it.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Fills a missing email when the invoice is opened, for jobs recorded before lookup existed
    /// or when the name was fixed by hand.
    fileprivate func searchForEmail() async {
        guard EmailAddress.isPlausible(job.client?.email) == false else { return }
        guard let client = job.client, !client.name.isEmpty else {
            emailSearch = .notFound
            return
        }
        // Something was typed but looks wrong: leave it for Dad to fix, don't overwrite it.
        guard client.email.isEmpty else { return }
        emailSearch = .searching
        switch await processor.findEmail(for: client, address: job.address) {
        case .found: emailSearch = .found
        case .choices(let people): emailSearch = .choose(people)
        case .none: emailSearch = client.email.isEmpty ? .notFound : .found
        }
    }
}

