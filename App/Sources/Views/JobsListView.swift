import InvoiceCore
import SwiftData
import SwiftUI

struct JobsListView: View {
    @Query(sort: \Job.jobDate, order: .reverse) private var jobs: [Job]
    @Environment(\.modelContext) private var context
    @State private var pendingMerge: (keep: Job, mergeIn: Job)?
    @State private var dismissedPairs = Set<String>()
    @State private var deletingJob: Job?

    var body: some View {
        List {
            if let pair = suggestedDuplicate {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("These two look like the same job", systemImage: "arrow.triangle.merge")
                            .font(.title3.bold())
                        Text("\(pair.keep.displayTitle), \(pair.keep.jobDate.formatted(date: .abbreviated, time: .omitted))")
                        HStack {
                            Button("Combine them") { pendingMerge = pair }
                                .buttonStyle(.borderedProminent)
                            Button("They're different") { dismissedPairs.insert(key(pair)) }
                                .buttonStyle(.bordered)
                        }
                        .font(.title3)
                    }
                    .padding(.vertical, 6)
                }
            }

            ForEach(jobs) { job in
                NavigationLink { JobDetailView(job: job) } label: { JobCard(job: job) }
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { deletingJob = job } label: { Label("Delete", systemImage: "trash") }
                            .tint(.red)
                    }
            }
        }
        .listStyle(.plain)
        .navigationTitle("All jobs")
        .overlay {
            if jobs.isEmpty {
                ContentUnavailableView("No jobs yet", systemImage: "mic", description: Text("Tap Record a job on the first screen."))
            }
        }
        .sheet(isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } })) {
            if let pair = pendingMerge {
                MergeConfirmView(target: pair.keep, source: pair.mergeIn) { pendingMerge = nil }
            }
        }
        .sheet(item: $deletingJob) { job in
            DeleteConfirmView.forJob(job) {
                context.delete(job)
                try? context.save()
            }
        }
    }

    private var suggestedDuplicate: (keep: Job, mergeIn: Job)? {
        let prints = jobs.map { JobFingerprint(id: $0.id, clientName: $0.client?.name, jobDate: $0.jobDate) }
        for pair in DuplicateDetection.likelyDuplicates(prints) {
            guard let keep = jobs.first(where: { $0.id == pair.keep }),
                  let other = jobs.first(where: { $0.id == pair.mergeIn }) else { continue }
            if !dismissedPairs.contains(key((keep, other))) { return (keep, other) }
        }
        return nil
    }

    private func key(_ pair: (keep: Job, mergeIn: Job)) -> String {
        "\(pair.keep.id)-\(pair.mergeIn.id)"
    }
}

/// Lets Dad (or Brian) pick another job to fold into this one.
struct MergePickerView: View {
    let target: Job
    @Query(sort: \Job.jobDate, order: .reverse) private var jobs: [Job]
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Job?

    var body: some View {
        NavigationStack {
            List(jobs.filter { $0.id != target.id }) { job in
                Button { selected = job } label: { JobCard(job: job) }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .navigationTitle("Combine with…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationDestination(item: $selected) { other in
                MergeConfirmView(target: target, source: other) { dismiss() }
            }
        }
    }
}

struct MergeConfirmView: View {
    let target: Job
    let source: Job
    let onDone: () -> Void
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(spacing: 24) {
            Text("Combine these jobs?").font(.largeTitle.bold())
            JobCard(job: target)
            Image(systemName: "plus").font(.title.bold())
            JobCard(job: source)
            Text("Together: \(Money.format(cents: target.totalCents + source.totalCents))")
                .font(.title.bold())
            Text("All items and recordings will be kept in one job.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                JobMerger.merge(source, into: target, context: context)
                onDone()
            } label: {
                Text("Combine").font(.title.bold()).frame(maxWidth: .infinity, minHeight: 72)
            }
            .buttonStyle(.borderedProminent)
            Button("Cancel", action: onDone).font(.title2)
        }
        .padding()
    }
}
