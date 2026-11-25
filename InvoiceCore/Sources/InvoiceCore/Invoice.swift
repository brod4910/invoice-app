import Foundation

public struct BusinessInfo: Equatable, Sendable {
    public var name: String
    public var ownerName: String
    public var address: String
    public var phone: String
    public var email: String
    /// e.g. "Payment due within 30 days. Checks payable to Joe Smith."
    public var paymentTerms: String
    /// Sales tax as a percentage (8.25 means 8.25%). 0 turns tax off.
    public var taxRatePercent: Double

    public init(
        name: String = "",
        ownerName: String = "",
        address: String = "",
        phone: String = "",
        email: String = "",
        paymentTerms: String = "",
        taxRatePercent: Double = 0
    ) {
        self.name = name
        self.ownerName = ownerName
        self.address = address
        self.phone = phone
        self.email = email
        self.paymentTerms = paymentTerms
        self.taxRatePercent = taxRatePercent
    }
}

public struct InvoiceLine: Equatable, Sendable {
    public var description: String
    public var details: String?
    public var quantity: Double
    public var unitPriceCents: Int

    public init(description: String, details: String? = nil, quantity: Double, unitPriceCents: Int) {
        self.description = description
        self.details = details
        self.quantity = quantity
        self.unitPriceCents = unitPriceCents
    }

    public var totalCents: Int { Money.lineTotal(quantity: quantity, unitPriceCents: unitPriceCents) }
}

public struct InvoiceDocument: Equatable, Sendable {
    public var number: Int
    public var date: Date
    public var business: BusinessInfo
    public var clientName: String
    public var clientEmail: String?
    public var jobAddress: String?
    public var jobTitle: String?
    public var lines: [InvoiceLine]
    public var notes: String?

    public init(
        number: Int,
        date: Date,
        business: BusinessInfo,
        clientName: String,
        clientEmail: String? = nil,
        jobAddress: String? = nil,
        jobTitle: String? = nil,
        lines: [InvoiceLine],
        notes: String? = nil
    ) {
        self.number = number
        self.date = date
        self.business = business
        self.clientName = clientName
        self.clientEmail = clientEmail
        self.jobAddress = jobAddress
        self.jobTitle = jobTitle
        self.lines = lines
        self.notes = notes
    }

    public var subtotalCents: Int { lines.reduce(0) { $0 + $1.totalCents } }

    public var taxCents: Int {
        guard business.taxRatePercent > 0 else { return 0 }
        return Int((Double(subtotalCents) * business.taxRatePercent / 100).rounded())
    }

    public var totalCents: Int { subtotalCents + taxCents }

    public var formattedNumber: String { String(format: "%04d", number) }

    public var pdfFilename: String { "Invoice-\(formattedNumber).pdf" }

    public var subject: String {
        let from = business.name.isEmpty ? business.ownerName : business.name
        let base = "Invoice #\(formattedNumber)"
        return from.isEmpty ? base : "\(base) from \(from)"
    }
}
