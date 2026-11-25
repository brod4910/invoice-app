import Foundation

/// Builds the invoice email body. HTML uses inline styles only, because Gmail strips <style> blocks in some clients.
public enum InvoiceRenderer {
    public static func html(_ doc: InvoiceDocument) -> String {
        let b = doc.business
        let headerName = escape(b.name.isEmpty ? b.ownerName : b.name)
        let contact = [b.address, b.phone, b.email].filter { !$0.isEmpty }.map(escape).joined(separator: "<br>")
        let cell = "padding:8px 6px;border-bottom:1px solid #e5e5e5;vertical-align:top;"
        let right = "text-align:right;white-space:nowrap;"

        var rows = ""
        for line in doc.lines {
            let details = line.details.flatMap { $0.isEmpty ? nil : $0 }
                .map { "<div style=\"color:#666;font-size:13px;margin-top:2px;\">\(escape($0))</div>" } ?? ""
            rows += """
            <tr>
              <td style="\(cell)">\(escape(line.description))\(details)</td>
              <td style="\(cell)\(right)">\(formatQuantity(line.quantity))</td>
              <td style="\(cell)\(right)">\(Money.format(cents: line.unitPriceCents))</td>
              <td style="\(cell)\(right)">\(Money.format(cents: line.totalCents))</td>
            </tr>

            """
        }

        var totals = ""
        if doc.taxCents > 0 {
            totals += totalRow("Subtotal", Money.format(cents: doc.subtotalCents), bold: false)
            totals += totalRow("Tax (\(formatPercent(b.taxRatePercent)))", Money.format(cents: doc.taxCents), bold: false)
        }
        totals += totalRow("Total due", Money.format(cents: doc.totalCents), bold: true)

        let billTo = [doc.clientName, doc.jobAddress ?? ""].filter { !$0.isEmpty }.map(escape).joined(separator: "<br>")
        let jobLine = doc.jobTitle.flatMap { $0.isEmpty ? nil : $0 }
            .map { "<p style=\"margin:0 0 12px;\"><strong>Job:</strong> \(escape($0))</p>" } ?? ""
        let notes = doc.notes.flatMap { $0.isEmpty ? nil : $0 }
            .map { "<p style=\"margin:16px 0 0;color:#444;\">\(escape($0))</p>" } ?? ""
        let terms = b.paymentTerms.isEmpty ? "" : "<p style=\"margin:16px 0 0;color:#444;\">\(escape(b.paymentTerms))</p>"

        return """
        <!doctype html>
        <html><body style="margin:0;padding:0;background:#ffffff;">
        <div style="max-width:640px;margin:0 auto;padding:24px;font-family:Helvetica,Arial,sans-serif;font-size:15px;color:#222;">
          <table width="100%" style="border-collapse:collapse;margin-bottom:24px;"><tr>
            <td style="vertical-align:top;">
              <div style="font-size:22px;font-weight:bold;">\(headerName)</div>
              <div style="color:#555;font-size:13px;margin-top:4px;">\(contact)</div>
            </td>
            <td style="vertical-align:top;text-align:right;">
              <div style="font-size:22px;font-weight:bold;">INVOICE</div>
              <div style="color:#555;font-size:13px;margin-top:4px;">#\(doc.formattedNumber)<br>\(formatDate(doc.date))</div>
            </td>
          </tr></table>
          <p style="margin:0 0 4px;color:#555;font-size:13px;">BILL TO</p>
          <p style="margin:0 0 16px;">\(billTo)</p>
          \(jobLine)
          <table width="100%" style="border-collapse:collapse;">
            <tr style="background:#f4f4f4;">
              <th style="\(cell)text-align:left;">Description</th>
              <th style="\(cell)\(right)">Qty</th>
              <th style="\(cell)\(right)">Price</th>
              <th style="\(cell)\(right)">Amount</th>
            </tr>
        \(rows)\(totals)
          </table>
          \(notes)
          \(terms)
          <p style="margin:24px 0 0;">Thank you for your business.</p>
        </div>
        </body></html>
        """
    }

    public static func plainText(_ doc: InvoiceDocument) -> String {
        let b = doc.business
        var out: [String] = []
        out.append(b.name.isEmpty ? b.ownerName : b.name)
        out.append(contentsOf: [b.address, b.phone, b.email].filter { !$0.isEmpty })
        out.append("")
        out.append("INVOICE #\(doc.formattedNumber)  \(formatDate(doc.date))")
        out.append("Bill to: \(doc.clientName)")
        if let address = doc.jobAddress, !address.isEmpty { out.append(address) }
        if let title = doc.jobTitle, !title.isEmpty { out.append("Job: \(title)") }
        out.append("")
        for line in doc.lines {
            out.append("- \(line.description): \(formatQuantity(line.quantity)) x \(Money.format(cents: line.unitPriceCents)) = \(Money.format(cents: line.totalCents))")
            if let details = line.details, !details.isEmpty { out.append("    \(details)") }
        }
        out.append("")
        if doc.taxCents > 0 {
            out.append("Subtotal: \(Money.format(cents: doc.subtotalCents))")
            out.append("Tax (\(formatPercent(b.taxRatePercent))): \(Money.format(cents: doc.taxCents))")
        }
        out.append("Total due: \(Money.format(cents: doc.totalCents))")
        if let notes = doc.notes, !notes.isEmpty { out.append(""); out.append(notes) }
        if !b.paymentTerms.isEmpty { out.append(""); out.append(b.paymentTerms) }
        out.append("")
        out.append("Thank you for your business.")
        return out.joined(separator: "\n")
    }

    /// The short email that carries the PDF.
    /// `photosAttached`: how many photos ride along as attachments.
    /// `mediaLinks`: videos (and photos too big to attach) shared from Google Drive.
    public static func coverNoteText(_ doc: InvoiceDocument, photosAttached: Int = 0, mediaLinks: [MediaLink] = []) -> String {
        let b = doc.business
        var lines: [String] = []
        let firstName = doc.clientName.split(separator: " ").first.map(String.init) ?? ""
        lines.append(firstName.isEmpty ? "Hello," : "Hello \(firstName),")
        lines.append("")
        var main = "Attached is invoice #\(doc.formattedNumber) for \(Money.format(cents: doc.totalCents))"
        if let title = doc.jobTitle, !title.isEmpty { main += " for \(title.prefix(1).lowercased() + title.dropFirst())" }
        lines.append(main + ".")
        if photosAttached > 0 {
            lines.append("")
            lines.append(photosAttached == 1 ? "A photo of the work is attached." : "Photos of the work are attached.")
        }
        if !mediaLinks.isEmpty {
            lines.append("")
            lines.append(mediaLinks.count == 1 ? "You can watch the video of the work here:" : "You can see the videos and photos of the work here:")
            lines.append(contentsOf: mediaLinks.map { "\($0.title): \($0.url)" })
        }
        if !b.paymentTerms.isEmpty { lines.append(""); lines.append(b.paymentTerms) }
        lines.append("")
        lines.append("Thank you for your business,")
        let signature = [b.ownerName, b.name, b.phone].filter { !$0.isEmpty }
        lines.append(contentsOf: signature)
        return lines.joined(separator: "\n")
    }

    public static func coverNoteHTML(_ doc: InvoiceDocument, photosAttached: Int = 0, mediaLinks: [MediaLink] = []) -> String {
        let paragraphs = coverNoteText(doc, photosAttached: photosAttached, mediaLinks: mediaLinks)
            .components(separatedBy: "\n\n")
            .map { paragraph in
                var html = escape(paragraph)
                // Turn each shared link into a tappable link with its title.
                for link in mediaLinks {
                    html = html.replacingOccurrences(
                        of: escape("\(link.title): \(link.url)"),
                        with: "<a href=\"\(escape(link.url))\">\(escape(link.title))</a>"
                    )
                }
                return "<p style=\"margin:0 0 14px;\">\(html)</p>"
            }
            .joined()
        return "<div style=\"font-family:Helvetica,Arial,sans-serif;font-size:15px;color:#222;\">\(paragraphs)</div>"
    }

    // MARK: - Helpers

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    public static func formatQuantity(_ q: Double) -> String {
        q == q.rounded() ? String(Int(q)) : String(format: "%.2f", q)
    }

    static func formatPercent(_ p: Double) -> String {
        p == p.rounded() ? "\(Int(p))%" : String(format: "%.2f%%", p)
    }

    static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM d, yyyy"
        return f.string(from: date)
    }

    private static func totalRow(_ label: String, _ value: String, bold: Bool) -> String {
        let weight = bold ? "font-weight:bold;font-size:17px;" : ""
        return """
            <tr>
              <td colspan="3" style="padding:8px 6px;text-align:right;\(weight)">\(escape(label))</td>
              <td style="padding:8px 6px;text-align:right;white-space:nowrap;\(weight)">\(value)</td>
            </tr>

        """
    }
}

/// A photo or video shared by link instead of attached, e.g. "Video 1" -> a Google Drive link.
public struct MediaLink: Equatable, Sendable {
    public var title: String
    public var url: String
    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}
