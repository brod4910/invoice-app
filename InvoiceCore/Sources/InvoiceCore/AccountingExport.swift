import Foundation

/// One job as it goes into the accounting export.
public struct ExportJob: Equatable, Sendable {
    public var invoiceNumber: Int?
    public var date: Date
    public var client: String
    public var email: String
    public var address: String
    public var job: String
    /// e.g. "Invoiced", "Ready", "Needs review"
    public var status: String
    public var lines: [ExportLine]
    /// Every transcript for the job, so work that never became a line item is still on record.
    public var whatWasSaid: String
    public var notes: String

    public init(invoiceNumber: Int?, date: Date, client: String, email: String, address: String, job: String, status: String,
                lines: [ExportLine], whatWasSaid: String = "", notes: String = "") {
        self.whatWasSaid = whatWasSaid
        self.notes = notes
        self.invoiceNumber = invoiceNumber
        self.date = date
        self.client = client
        self.email = email
        self.address = address
        self.job = job
        self.status = status
        self.lines = lines
    }

    public var subtotalCents: Int { lines.reduce(0) { $0 + ($1.amountCents ?? 0) } }
}

public struct ExportLine: Equatable, Sendable {
    public var description: String
    public var details: String
    public var quantity: Double
    /// nil when no price was set.
    public var unitPriceCents: Int?

    public init(description: String, details: String = "", quantity: Double, unitPriceCents: Int?) {
        self.description = description
        self.details = details
        self.quantity = quantity
        self.unitPriceCents = unitPriceCents
    }

    public var amountCents: Int? { unitPriceCents.map { Money.lineTotal(quantity: quantity, unitPriceCents: $0) } }
}

/// Spreadsheet (CSV) files for an accountant: one with a row per invoice, one with a row per line item.
/// Opens in Excel, Numbers and Google Sheets, and imports into most accounting software.
public enum AccountingExport {
    public static func invoicesCSV(_ jobs: [ExportJob], taxRatePercent: Double) -> String {
        var rows = [["Invoice #", "Date", "Client", "Email", "Address", "Job", "Status", "Subtotal", "Tax", "Total", "Missing prices", "What he said", "Notes"]]
        for job in jobs.sorted(by: { $0.date < $1.date }) {
            let subtotal = job.subtotalCents
            let tax = taxRatePercent > 0 ? Int((Double(subtotal) * taxRatePercent / 100).rounded()) : 0
            rows.append([
                job.invoiceNumber.map { String(format: "%04d", $0) } ?? "",
                isoDate(job.date),
                job.client,
                job.email,
                job.address,
                job.job,
                job.status,
                amount(subtotal),
                amount(tax),
                amount(subtotal + tax),
                job.lines.contains { $0.unitPriceCents == nil } ? "Yes" : "",
                job.whatWasSaid,
                job.notes,
            ])
        }
        return csv(rows)
    }

    public static func lineItemsCSV(_ jobs: [ExportJob]) -> String {
        var rows = [["Invoice #", "Date", "Client", "Job", "Item", "Details", "Quantity", "Unit price", "Amount"]]
        for job in jobs.sorted(by: { $0.date < $1.date }) {
            for line in job.lines {
                rows.append([
                    job.invoiceNumber.map { String(format: "%04d", $0) } ?? "",
                    isoDate(job.date),
                    job.client,
                    job.job,
                    line.description,
                    line.details,
                    quantity(line.quantity),
                    line.unitPriceCents.map(amount) ?? "",
                    line.amountCents.map(amount) ?? "",
                ])
            }
        }
        return csv(rows)
    }

    // MARK: - Formatting

    /// Plain numbers with two decimals and no currency sign, so spreadsheets treat them as numbers.
    static func amount(_ cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let c = abs(cents)
        return "\(sign)\(c / 100).\(String(format: "%02d", c % 100))"
    }

    static func quantity(_ q: Double) -> String {
        q == q.rounded() ? String(Int(q)) : String(format: "%.2f", q)
    }

    static func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Quotes a field when needed, and defuses values a spreadsheet would run as a formula.
    static func field(_ value: String) -> String {
        var v = value
        if let first = v.first, "=+-@".contains(first), Double(v) == nil { v = "'" + v }
        if v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
}
