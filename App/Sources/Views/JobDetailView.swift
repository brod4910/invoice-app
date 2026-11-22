import InvoiceCore
import SwiftData
import SwiftUI

struct JobDetailView: View {
    @Bindable var job: Job
    @Environment(\.modelContext) private var context
    @Environment(JobProcessor.self) private var processor
    @Environment(\.dismiss) private var dismiss

    @State private var showRecorder = false
    @State private var editingItem: LineItem?
    @State private var editingClient = false
    @State private var showMerge = false
    @State private var showInvoice = false
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Button { editingClient = true } label: {
                        HStack {
                            Text(job.client?.name.isEmpty == false ? job.client!.name : "Add client name")
                                .font(.title.bold())
                            Image(systemName: "pencil").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    if let email = job.client?.email, !email.isEmpty {
                        Text(email).foregroundStyle(.secondary)
                    }
                    if !job.title.isEmpty { Text(job.title).font(.title3) }
                    Text(job.jobDate, format: .dateTime.weekday(.wide).month(.wide).day())
                        .foregroundStyle(.secondary)
                    Text(Money.format(cents: job.totalCents))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    StatusBadge(job: job).font(.title3)
                }
                .padding(.vertical, 8)
            }

            Section("Items") {
                if job.items.isEmpty {
                    Text(job.isProcessing ? "Writing up what you said…" : "No items yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(job.sortedItems) { item in
                    LineItemRow(item: item) { editingItem = item }
                }
                .onDelete { offsets in
                    let items = job.sortedItems
                    for index in offsets { context.delete(items[index]) }
                    try? context.save()
                }
                Button {
                    let item = LineItem(description: "", unitPriceCents: nil, sortIndex: (job.items.map(\.sortIndex).max() ?? -1) + 1)
                    context.insert(item)
                    item.job = job
                    editingItem = item
                } label: {
                    Label("Type an item", systemImage: "plus").font(.title3)
                }
            }

            Section {
                Button { showRecorder = true } label: {
                    Label("Add more to this job", systemImage: "mic.fill")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .listRowInsets(EdgeInsets())

                Button { showInvoice = true } label: {
                    Label("Make invoice", systemImage: "envelope.fill")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(job.items.isEmpty)
                .listRowInsets(EdgeInsets())
            }
            .listRowBackground(Color.clear)

            Section("What you said") {
                ForEach(job.sortedRecordings) { recording in
                    RecordingRow(recording: recording) {
                        Task { await processor.process(recording) }
                    }
                }
            }
        }
        .navigationTitle(job.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button { showMerge = true } label: { Label("Combine with another job", systemImage: "arrow.triangle.merge") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete job", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("More")
            }
        }
        .sheet(item: $editingItem) { LineItemEditor(item: $0) }
        .sheet(isPresented: $editingClient) { ClientEditor(job: job) }
        .sheet(isPresented: $showMerge) { MergePickerView(target: job) }
        .navigationDestination(isPresented: $showInvoice) { InvoicePreviewView(job: job) }
        .fullScreenCover(isPresented: $showRecorder) {
            RecordingView(existingJob: job) { _ in showRecorder = false }
        }
        .confirmationDialog("Delete this job and its recordings?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete job", role: .destructive) {
                context.delete(job)
                try? context.save()
                dismiss()
            }
        }
    }
}

/// One line item. Tap the arrow to open its details (the "drop-down"); tap the text to edit.
struct LineItemRow: View {
    let item: LineItem
    let onEdit: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if !item.details.isEmpty { Text(item.details) }
                Text("Quantity: \(formatQuantity(item.quantity))")
                Text("Price each: \(item.unitPriceCents.map { Money.format(cents: $0) } ?? "not set")")
                Button("Edit this item", action: onEdit).font(.title3)
            }
            .font(.body)
            .padding(.vertical, 4)
        } label: {
            HStack {
                Text(item.itemDescription.isEmpty ? "New item" : item.itemDescription)
                    .font(.title3)
                Spacer()
                if item.unitPriceCents == nil {
                    Text("Price?")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.orange, in: Capsule())
                } else {
                    Text(Money.format(cents: item.totalCents)).font(.title3.bold()).monospacedDigit()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)
        }
    }

    private func formatQuantity(_ q: Double) -> String {
        q == q.rounded() ? String(Int(q)) : String(format: "%.2f", q)
    }
}

struct RecordingRow: View {
    let recording: Recording
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(recording.recordedAt, format: .dateTime.hour().minute())
                Text("· \(Int(recording.duration.rounded())) sec").foregroundStyle(.secondary)
                Spacer()
                switch recording.state {
                case .transcribing, .extracting: ProgressView()
                case .failed: Button("Try again", action: onRetry).buttonStyle(.bordered)
                default: EmptyView()
                }
            }
            if !recording.transcript.isEmpty {
                Text(recording.transcript).foregroundStyle(.secondary)
            }
            if recording.state == .failed, !recording.lastError.isEmpty {
                Text(recording.lastError).font(.footnote).foregroundStyle(.orange)
            }
        }
    }
}
