import InvoiceCore
import SwiftData
import SwiftUI

/// The first screen: one big button that starts a new job.
struct HomeView: View {
    @Query(sort: \Job.createdAt, order: .reverse) private var jobs: [Job]
    @State private var showRecorder = false
    @State private var path: [Job] = []
    @State private var permissionMessage: String?
    @State private var deletingJob: Job?
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack(path: $path) {
            // A List (not a ScrollView) so the recent-job cards can be swiped to delete.
            List {
                Group {
                    RecordButton { Task { await startRecording() } }
                        .buttonStyle(.plain)
                        .padding(.top, 24)

                    if let permissionMessage {
                        Text(permissionMessage)
                            .font(.title3)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    if !jobs.isEmpty {
                        Text("Recent jobs").font(.title2.bold())
                            .padding(.top, 20)
                        ForEach(jobs.prefix(3)) { job in
                            NavigationLink(value: job) { JobCard(job: job) }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button { deletingJob = job } label: { Label("Delete", systemImage: "trash") }
                                        .tint(.red)
                                }
                        }
                        NavigationLink {
                            JobsListView()
                        } label: {
                            Text("See all jobs")
                                .font(.title3.bold())
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(.bordered)
                        .padding(.bottom, 32)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .sheet(item: $deletingJob) { job in
                DeleteConfirmView.forJob(job) {
                    context.delete(job)
                    try? context.save()
                }
            }
            .navigationTitle("Jobs")
            .navigationDestination(for: Job.self) { JobDetailView(job: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: {
                        Image(systemName: "gearshape").accessibilityLabel("Settings")
                    }
                }
            }
            .fullScreenCover(isPresented: $showRecorder) {
                RecordingView(existingJob: nil) { job in
                    showRecorder = false
                    if let job, !job.isGone { path = [job] }
                }
            }
        }
    }

    private func startRecording() async {
        guard await AudioRecorder.requestPermission() else {
            permissionMessage = "Please allow the microphone in Settings so the app can hear you."
            return
        }
        _ = await Transcriber.requestPermission()
        permissionMessage = nil
        showRecorder = true
    }
}

struct RecordButton: View {
    var title = "Record a job"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                Image(systemName: "mic.fill").font(.system(size: 72, weight: .bold))
                Text(title).font(.largeTitle.bold())
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 280)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 36))
        }
        .accessibilityHint("Starts recording. Talk through the job, then tap Stop.")
    }
}

struct JobCard: View {
    let job: Job

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayTitle).font(.title3.bold()).lineLimit(1)
                if !job.displayAddress.isEmpty {
                    Text(job.displayAddress).lineLimit(1)
                }
                Text(job.jobDate, format: .dateTime.month(.wide).day().year())
                    .foregroundStyle(.secondary)
                StatusBadge(job: job)
            }
            Spacer()
            Text(Money.format(cents: job.totalCents))
                .font(.title2.bold())
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct StatusBadge: View {
    let job: Job

    var body: some View {
        if job.recordings.isEmpty && job.items.isEmpty {
            Label("Nothing was heard", systemImage: "ear.trianglebadge.exclamationmark").foregroundStyle(.secondary)
        } else if job.isProcessing {
            Label("Working on it…", systemImage: "hourglass").foregroundStyle(.orange)
        } else if job.recordings.contains(where: { $0.state == .failed }) {
            Label("Couldn't finish. Open to fix", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            switch job.status {
            case .draft: Label(job.status.label, systemImage: "pencil").foregroundStyle(.blue)
            case .ready: Label(job.status.label, systemImage: "checkmark").foregroundStyle(.green)
            case .invoiced: Label(job.status.label, systemImage: "envelope.fill").foregroundStyle(.green)
            }
        }
    }
}
