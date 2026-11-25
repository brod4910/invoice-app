import Foundation

/// A private record of a job for Dad and Brian: everything that was said, the notes, and the
/// items, so work that never made it onto the invoice is still written down. Drafted next to
/// the invoice in Gmail; never addressed to the client.
public struct JobRecord: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var description: String
        public var quantity: Double
        public var unitPriceCents: Int?
        public init(description: String, quantity: Double, unitPriceCents: Int?) {
            self.description = description
            self.quantity = quantity
            self.unitPriceCents = unitPriceCents
        }
    }

    public struct Said: Equatable, Sendable {
        public var at: Date
        public var text: String
        public init(at: Date, text: String) {
            self.at = at
            self.text = text
        }
    }

    public var invoiceNumber: Int
    public var clientName: String
    public var address: String
    public var jobDate: Date
    public var items: [Item]
    public var said: [Said]
    public var notes: String

    public init(invoiceNumber: Int, clientName: String, address: String, jobDate: Date,
                items: [Item], said: [Said], notes: String) {
        self.invoiceNumber = invoiceNumber
        self.clientName = clientName
        self.address = address
        self.jobDate = jobDate
        self.items = items
        self.said = said
        self.notes = notes
    }

    public var subject: String {
        var s = "Job record for Invoice #\(String(format: "%04d", invoiceNumber))"
        if !clientName.isEmpty { s += " - \(clientName)" }
        return s
    }

    public func plainText(locale: Locale = Locale(identifier: "en_US"), timeZone: TimeZone = .current) -> String {
        var out: [String] = []
        out.append(subject)
        out.append("Not for the client. Check that everything said below is on the invoice.")
        out.append("")
        if !address.isEmpty { out.append("Address: \(address)") }
        out.append("Job date: \(Self.dateString(jobDate, locale: locale, timeZone: timeZone))")
        out.append("")
        out.append("ITEMS ON THE INVOICE")
        if items.isEmpty { out.append("(none)") }
        for item in items {
            let qty = item.quantity == 1 ? "" : " x \(InvoiceRenderer.formatQuantity(item.quantity))"
            let price = item.unitPriceCents.map { Money.format(cents: $0) } ?? "NO PRICE"
            out.append("- \(item.description)\(qty): \(price)")
        }
        out.append("")
        out.append("WHAT WAS SAID")
        if said.isEmpty { out.append("(nothing recorded)") }
        for entry in said {
            out.append("[\(Self.dateString(entry.at, locale: locale, timeZone: timeZone, time: true))]")
            out.append(entry.text)
            out.append("")
        }
        if !notes.isEmpty {
            out.append("NOTES")
            out.append(notes)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    public func html(locale: Locale = Locale(identifier: "en_US"), timeZone: TimeZone = .current) -> String {
        let body = InvoiceRenderer.escape(plainText(locale: locale, timeZone: timeZone))
        return "<div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:16px;line-height:1.5\">\(body)</div>"
    }

    static func dateString(_ date: Date, locale: Locale, timeZone: TimeZone, time: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = time ? .short : .none
        return f.string(from: date)
    }
}
