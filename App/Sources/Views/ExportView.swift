import InvoiceCore
import SwiftData
import SwiftUI

/// Makes two spreadsheet (CSV) files for the accountant: invoices and line items.
struct ExportView: View {
    @Query(sort: \Job.jobDate) private var jobs: [Job]
    @State private var range: Range = .thisMonth
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var onlyInvoiced = false
    @State private var files: [URL] = []
    @State private var errorMessage: String?

    enum Range: String, CaseIterable, Identifiable {
        case thisMonth = "This month"
        case lastMonth = "Last month"
        case thisQuarter = "This quarter"
        case lastQuarter = "Last quarter"
        case thisYear = "This year"
        case lastYear = "Last year"
        case custom = "Custom dates"
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section("Which jobs") {
                Picker("Dates", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                if range == .custom {
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                }
                Toggle("Only jobs already invoiced", isOn: $onlyInvoiced)
                let selected = selectedJobs
                Text("\(selected.count) job\(selected.count == 1 ? "" : "s"), \(Money.format(cents: selected.reduce(0) { $0 + $1.totalCents })) before tax")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Create spreadsheet files") { createFiles() }
                    .font(.title3.bold())
                    .disabled(selectedJobs.isEmpty)
                if !files.isEmpty {
                    ShareLink(items: files) {
                        Label("Share or save the files", systemImage: "square.and.arrow.up").font(.title3)
                    }
                    ForEach(files, id: \.self) { Text($0.lastPathComponent).font(.footnote).foregroundStyle(.secondary) }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            } footer: {
                Text("Two CSV files: one row per invoice, and one row per item. They open in Excel, Numbers and Google Sheets, and most accounting software can import them.")
            }
        }
        .navigationTitle("Export for accounting")
        .onChange(of: range) { files = [] }
        .onChange(of: onlyInvoiced) { files = [] }
        .onChange(of: customStart) { files = [] }
        .onChange(of: customEnd) { files = [] }
    }

    private var interval: DateInterval {
        let cal = Calendar.current
        let now = Date()
        func span(_ component: Calendar.Component, offset: Int) -> DateInterval {
            let shifted = cal.date(byAdding: component, value: offset, to: now) ?? now
            return cal.dateInterval(of: component, for: shifted) ?? DateInterval(start: now, end: now)
        }
        switch range {
        case .thisMonth: return span(.month, offset: 0)
        case .lastMonth: return span(.month, offset: -1)
        case .thisQuarter: return quarter(containing: now)
        case .lastQuarter: return quarter(containing: cal.date(byAdding: .month, value: -3, to: now) ?? now)
        case .thisYear: return span(.year, offset: 0)
        case .lastYear: return span(.year, offset: -1)
        case .custom:
            let start = cal.startOfDay(for: min(customStart, customEnd))
            let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(customStart, customEnd))) ?? customEnd
            return DateInterval(start: start, end: end)
        }
    }

    private func quarter(containing date: Date) -> DateInterval {
        let cal = Calendar.current
        let month = cal.component(.month, from: date)
        let year = cal.component(.year, from: date)
        let firstMonth = ((month - 1) / 3) * 3 + 1
        let start = cal.date(from: DateComponents(year: year, month: firstMonth, day: 1)) ?? date
        let end = cal.date(byAdding: .month, value: 3, to: start) ?? date
        return DateInterval(start: start, end: end)
    }

    private var selectedJobs: [Job] {
        let window = interval
        return jobs.filter { job in
            job.jobDate >= window.start && job.jobDate < window.end
                && !job.items.isEmpty
                && (!onlyInvoiced || job.latestInvoice != nil)
        }
    }

    private func createFiles() {
        let export = selectedJobs.map { job in
            ExportJob(
                invoiceNumber: job.latestInvoice?.number,
                date: job.jobDate,
                client: job.client?.name ?? (job.clientNameHint == "Unknown client" ? "" : job.clientNameHint),
                email: job.client?.email ?? "",
                address: job.displayAddress,
                job: job.title,
                status: job.status.label,
                lines: job.sortedItems.map {
                    ExportLine(description: $0.itemDescription, details: $0.details, quantity: $0.quantity, unitPriceCents: $0.unitPriceCents)
                }
            )
        }
        let tax = BusinessSettings.info.taxRatePercent
        let label = filenameLabel
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let invoices = folder.appendingPathComponent("Invoices \(label).csv")
            let items = folder.appendingPathComponent("Line items \(label).csv")
            try AccountingExport.invoicesCSV(export, taxRatePercent: tax).write(to: invoices, atomically: true, encoding: .utf8)
            try AccountingExport.lineItemsCSV(export).write(to: items, atomically: true, encoding: .utf8)
            files = [invoices, items]
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't create the files: \(error.localizedDescription)"
        }
    }

    private var filenameLabel: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let window = interval
        let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: window.end) ?? window.end
        return "\(f.string(from: window.start)) to \(f.string(from: lastDay))"
    }
}
