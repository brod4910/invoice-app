import InvoiceCore
import SwiftData
import SwiftUI

struct JobDetailView: View {
    @Bindable var job: Job
    @Environment(\.modelContext) private var context
    @Environment(JobProcessor.self) private var processor
    @Environment(GmailClient.self) private var gmail
    @Environment(\.dismiss) private var dismiss

    @State private var showRecorder = false
    @State private var editingItem: LineItem?
    @State private var deletingItem: LineItem?
    @State private var sayingAgain: Recording?
    @State private var viewingMedia: JobMedia?
    @State private var deletingMedia: JobMedia?
    @State private var editingClient = false
    @State private var pickingClient = false
    @State private var showMerge = false
    @State private var showInvoice = false
    @State private var confirmDelete = false
    @State private var updatingDraft = false
    @State private var draftMessage: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if job.needsClientChoice {
                        Button { pickingClient = true } label: {
                            Label("Which client is this? Tap to choose.", systemImage: "questionmark.circle.fill")
                                .font(.title3.bold())
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                    }
                    Button { editingClient = true } label: {
                        HStack {
                            Text(job.client?.name.isEmpty == false ? job.client!.name
                                 : (job.needsClientChoice ? job.displayTitle : "Add client name"))
                                .font(.title.bold())
                            Image(systemName: "pencil").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    if job.client == nil && !job.needsClientChoice {
                        Button("Pick a past client") { pickingClient = true }.font(.title3)
                    }
                    if !job.displayAddress.isEmpty {
                        Label(job.displayAddress, systemImage: "mappin.and.ellipse")
                            .font(.title3)
                    }
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

            // The three things Dad does on a job, together near the top.
            Section {
                VStack(spacing: 12) {
                    Button { showRecorder = true } label: {
                        Label("Add more to this job", systemImage: "mic.fill")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    AddMediaButtons(job: job)

                    Button { showInvoice = true } label: {
                        Label(job.latestInvoice.map { "View invoice #\(String(format: "%04d", $0.number))" } ?? "Make invoice",
                              systemImage: "envelope.fill")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(job.items.isEmpty)
                }
                .buttonStyle(.borderless)
                .listRowInsets(EdgeInsets())
            }
            .listRowBackground(Color.clear)

            if let invoice = job.latestInvoice, !invoice.gmailDraftID.isEmpty, !InvoiceBuilder.draftIsOutOfDate(job) {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Invoice #\(String(format: "%04d", invoice.number)) is in Gmail drafts").font(.headline)
                            Text("Up to date as of \(invoice.updatedAt.formatted(date: .abbreviated, time: .shortened)). Open Gmail to check it and press Send.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if InvoiceBuilder.draftIsOutOfDate(job) || draftMessage != nil {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        if InvoiceBuilder.draftIsOutOfDate(job) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "envelope.badge").foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Invoice needs updating").font(.headline)
                                    Text("You've changed this job since the invoice was saved to Gmail.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Button {
                                Task { await updateDraft() }
                            } label: {
                                Group {
                                    if updatingDraft { ProgressView() } else { Text("Update invoice in Gmail") }
                                }
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(updatingDraft)
                        }
                        if let draftMessage {
                            Text(draftMessage).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Items") {
                if job.items.isEmpty {
                    Text(job.isProcessing ? "Writing up what you said…" : "No items yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(job.sortedItems) { item in
                    LineItemRow(item: item) { editingItem = item }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button { deletingItem = item } label: { Label("Delete", systemImage: "trash") }
                                .tint(.red)
                        }
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

            JobMediaSection(job: job, onOpen: { viewingMedia = $0 }, onDelete: { deletingMedia = $0 })

            Section("What you said") {
                ForEach(job.sortedRecordings) { recording in
                    RecordingRow(
                        recording: recording,
                        onRetry: { Task { await processor.process(recording) } },
                        onRedo: { Task { await processor.redo(recording) } },
                        onSayAgain: { sayingAgain = recording }
                    )
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
        .onAppear { processor.jobScreenOpened(job) }
        .onDisappear { processor.jobScreenClosed(job) }
        // Only silence was recorded and the recording was dropped: nothing to show, so go back.
        .onChange(of: job.isEmpty) { _, empty in
            if empty && !showRecorder && sayingAgain == nil { dismiss() }
        }
        .sheet(item: $editingItem) { LineItemEditor(item: $0) }
        .sheet(isPresented: $editingClient) { ClientEditor(job: job) }
        .sheet(isPresented: $pickingClient) { ClientPickerView(job: job) }
        .sheet(isPresented: $showMerge) { MergePickerView(target: job) }
        .navigationDestination(isPresented: $showInvoice) { InvoicePreviewView(job: job) }
        .fullScreenCover(isPresented: $showRecorder) {
            RecordingView(existingJob: job) { _ in showRecorder = false }
        }
        .fullScreenCover(item: $sayingAgain) { _ in
            // A new recording on the same job: what he says fixes or adds to the items already here.
            RecordingView(existingJob: job) { _ in sayingAgain = nil }
        }
        .fullScreenCover(item: $viewingMedia) { MediaViewer(media: $0) }
        .sheet(item: $deletingMedia) { media in
            DeleteConfirmView(
                question: media.isVideo ? "Are you sure you want to delete this video?" : "Are you sure you want to delete this photo?",
                name: job.displayTitle,
                detail: nil,
                deleteLabel: media.isVideo ? "Yes, delete video" : "Yes, delete photo"
            ) {
                MediaImporter.delete(media, context: context)
            }
        }
        .sheet(item: $deletingItem) { item in
            DeleteConfirmView.forItem(item) {
                context.delete(item)
                try? context.save()
            }
        }
        .sheet(isPresented: $confirmDelete) {
            DeleteConfirmView.forJob(job) {
                context.delete(job)
                try? context.save()
                dismiss()
            }
        }
    }
}

extension JobDetailView {
    fileprivate func updateDraft() async {
        updatingDraft = true
        defer { updatingDraft = false }
        do {
            draftMessage = try await InvoiceBuilder.saveToGmail(job: job, gmail: gmail, context: context)
        } catch {
            draftMessage = error.localizedDescription
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
    /// Words were changed: rewrite this recording's items from them.
    let onRedo: () -> Void
    let onSayAgain: () -> Void
    @State private var typing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(recording.recordedAt, format: .dateTime.hour().minute())
                Text("· \(Int(recording.duration.rounded())) sec").foregroundStyle(.secondary)
                Spacer()
                switch recording.state {
                case .transcribing, .extracting: ProgressView()
                case .failed:
                    HStack {
                        if recording.transcript.isEmpty {
                            Button("Type it") { typing = true }.buttonStyle(.bordered)
                        }
                        Button("Try again", action: onRetry).buttonStyle(.bordered)
                    }
                default: EmptyView()
                }
            }
            if !recording.transcript.isEmpty {
                Text(recording.transcript).foregroundStyle(.secondary)
            }
            if recording.state == .failed, !recording.lastError.isEmpty {
                Text(recording.lastError).font(.footnote).foregroundStyle(.orange)
            }
            if recording.state == .done {
                HStack(spacing: 12) {
                    Button { typing = true } label: {
                        Label("Fix the words", systemImage: "pencil")
                    }
                    Button(action: onSayAgain) {
                        Label("Fix by talking", systemImage: "mic")
                    }
                }
                .font(.body.bold())
                // Two buttons in one list row: borderless keeps each tap to its own button.
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
        }
        .sheet(isPresented: $typing) {
            TranscriptEditor(recording: recording, onSave: onRedo)
        }
    }
}

/// Type what was said (when speech-to-text couldn't run) or fix the words it heard.
/// Saving rewrites this recording's items from the words.
struct TranscriptEditor: View {
    let recording: Recording
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .font(.title3)
                if !recording.transcript.isEmpty {
                    Text("When you save, the items from this recording are written up again from these words.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
                .padding()
                .onAppear { text = recording.transcript }
                .navigationTitle("What was said")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            recording.transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            dismiss()
                            onSave()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
