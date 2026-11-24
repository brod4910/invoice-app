import InvoiceCore
import SwiftData
import SwiftUI

struct LineItemEditor: View {
    @Bindable var item: LineItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var priceText = ""
    @State private var quantityText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("What was done") {
                    TextField("Description", text: $item.itemDescription, axis: .vertical)
                        .font(.title3)
                }
                Section("Details (shown under the item)") {
                    TextField("Optional", text: $item.details, axis: .vertical)
                }
                Section("How many") {
                    TextField("1", text: $quantityText).keyboardType(.decimalPad).font(.title3)
                }
                Section("Price each") {
                    TextField("$0.00", text: $priceText).keyboardType(.decimalPad).font(.title3)
                }
            }
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.font(.title3.bold())
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // A brand-new empty item is discarded on cancel.
                        if item.itemDescription.isEmpty && item.unitPriceCents == nil { context.delete(item) }
                        dismiss()
                    }
                }
            }
            .onAppear {
                priceText = item.unitPriceCents.map { String(format: "%.2f", Double($0) / 100) } ?? ""
                quantityText = item.quantity == item.quantity.rounded() ? String(Int(item.quantity)) : String(item.quantity)
            }
        }
    }

    private func save() {
        item.unitPriceCents = Money.parseCents(priceText)
        if let q = Double(quantityText.trimmingCharacters(in: .whitespaces)), q > 0 { item.quantity = q }
        try? context.save()
        dismiss()
    }
}

struct ClientEditor: View {
    @Bindable var job: Job
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Client") {
                    TextField("Name", text: $name).font(.title3).textContentType(.name)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Phone", text: $phone).keyboardType(.phonePad)
                }
                Section("Job") {
                    TextField("Job address", text: $address, axis: .vertical)
                    TextField("What was the job?", text: $job.title)
                    DatePicker("Date", selection: $job.jobDate, displayedComponents: .date)
                }
                if !email.isEmpty && !EmailAddress.isPlausible(email) {
                    Text("That email address doesn't look right.").foregroundStyle(.orange)
                }
            }
            .navigationTitle("Client details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.font(.title3.bold()) }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                name = job.client?.name ?? (job.clientNameHint == "Unknown client" ? "" : job.clientNameHint)
                email = job.client?.email ?? ""
                phone = job.client?.phone ?? ""
                address = job.address
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if job.client == nil, !trimmed.isEmpty {
            // Reuse a past client with this exact name instead of saving them twice.
            let all = (try? context.fetch(FetchDescriptor<Client>())) ?? []
            if let existing = all.first(where: { ClientMatching.normalize($0.name) == ClientMatching.normalize(trimmed) }) {
                job.client = existing
                // Keep their saved email and phone unless something new was typed.
                if email.trimmingCharacters(in: .whitespaces).isEmpty { email = existing.email }
                if phone.isEmpty { phone = existing.phone }
            } else {
                let client = Client(name: trimmed)
                context.insert(client)
                job.client = client
            }
        }
        if let client = job.client {
            client.name = trimmed
            client.email = email.trimmingCharacters(in: .whitespaces)
            client.phone = phone
        }
        job.address = address
        if job.client != nil { job.clientNameHint = "" }
        try? context.save()
        dismiss()
    }
}

/// Pick which past client a job is for. Shown when the app couldn't tell on its own.
struct ClientPickerView: View {
    @Bindable var job: Job
    @Query(sort: \Client.name) private var clients: [Client]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var search = ""

    private var hint: String { job.clientNameHint == "Unknown client" ? "" : job.clientNameHint }

    private var filtered: [Client] {
        let named = clients.filter { !$0.name.isEmpty }
        let query = search.isEmpty ? hint : search
        guard !query.isEmpty else { return named }
        let matches = ClientMatching.candidates(for: query, in: named.map(\.name)).map { named[$0] }
        // If the spoken name matches nobody, show everyone rather than an empty list.
        return matches.isEmpty && search.isEmpty ? named : matches
    }

    var body: some View {
        NavigationStack {
            List {
                if !hint.isEmpty, !clients.contains(where: { ClientMatching.normalize($0.name) == ClientMatching.normalize(hint) }) {
                    Section {
                        Button {
                            let client = Client(name: hint)
                            context.insert(client)
                            choose(client)
                        } label: {
                            Label("New client named \(hint)", systemImage: "person.badge.plus").font(.title3)
                        }
                    }
                }
                Section("Past clients") {
                    ForEach(filtered) { client in
                        Button { choose(client) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(client.name).font(.title3.bold())
                                if !client.email.isEmpty { Text(client.email).foregroundStyle(.secondary) }
                                ForEach(addresses(of: client), id: \.self) { address in
                                    Label(address, systemImage: "mappin.and.ellipse")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $search, prompt: "Search clients")
            .navigationTitle("Which client?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func addresses(of client: Client) -> [String] {
        var out: [String] = []
        for address in client.jobs.map(\.address) + [client.address] where !address.isEmpty {
            if !out.contains(where: { AddressMatching.same($0, address) }) { out.append(address) }
        }
        return Array(out.prefix(3))
    }

    private func choose(_ client: Client) {
        job.client = client
        job.clientNameHint = ""
        if job.address.isEmpty {
            let record = ClientRecord(id: client.id, name: client.name, addresses: addresses(of: client))
            if let usual = ClientResolver.usualAddress(of: record) { job.address = usual }
        }
        try? context.save()
        dismiss()
    }
}

/// A big, hard-to-miss "are you sure?" screen so a slip of the finger never deletes anything.
struct DeleteConfirmView: View {
    let question: String
    let name: String
    let detail: String?
    let deleteLabel: String
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "trash.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.red)
                .padding(.top, 32)
            Text(question)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                Text(name)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Text("This can't be undone.")
                .font(.title2)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("No, keep it")
                    .font(.title.bold())
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            Button {
                // Close the pop-up first so it never redraws a deleted job or item.
                dismiss()
                onDelete()
            } label: {
                Text(deleteLabel)
                    .font(.title.bold())
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding()
        .presentationDetents([.large])
    }
}

extension DeleteConfirmView {
    static func forJob(_ job: Job, onDelete: @escaping () -> Void) -> DeleteConfirmView {
        var parts = [job.jobDate.formatted(date: .abbreviated, time: .omitted)]
        if !job.displayAddress.isEmpty { parts.insert(job.displayAddress, at: 0) }
        if !job.items.isEmpty { parts.append(Money.format(cents: job.totalCents)) }
        return DeleteConfirmView(question: "Are you sure you want to delete this job?",
                                 name: job.displayTitle,
                                 detail: parts.joined(separator: "\n"),
                                 deleteLabel: "Yes, delete job",
                                 onDelete: onDelete)
    }

    static func forItem(_ item: LineItem, onDelete: @escaping () -> Void) -> DeleteConfirmView {
        DeleteConfirmView(question: "Are you sure you want to delete this item?",
                          name: item.itemDescription.isEmpty ? "New item" : item.itemDescription,
                          detail: item.unitPriceCents.map { Money.format(cents: $0) },
                          deleteLabel: "Yes, delete item",
                          onDelete: onDelete)
    }
}
