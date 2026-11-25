import Foundation

/// What the AI pulls out of a transcript. Mirrors the JSON returned by the proxy.
public struct ExtractionResult: Codable, Equatable, Sendable {
    public var clientName: String?
    public var clientEmail: String?
    public var clientPhone: String?
    public var jobAddress: String?
    public var jobTitle: String?
    public var items: [ExtractedItem]
    public var notes: String?
    /// Spoken corrections to items already on the job ("instead of kitchen I meant living room").
    public var changes: [ItemChange]

    public init(
        clientName: String? = nil,
        clientEmail: String? = nil,
        clientPhone: String? = nil,
        jobAddress: String? = nil,
        jobTitle: String? = nil,
        items: [ExtractedItem] = [],
        notes: String? = nil,
        changes: [ItemChange] = []
    ) {
        self.clientName = clientName
        self.clientEmail = clientEmail
        self.clientPhone = clientPhone
        self.jobAddress = jobAddress
        self.jobTitle = jobTitle
        self.items = items
        self.notes = notes
        self.changes = changes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientName = try c.decodeIfPresent(String.self, forKey: .clientName)
        clientEmail = try c.decodeIfPresent(String.self, forKey: .clientEmail)
        clientPhone = try c.decodeIfPresent(String.self, forKey: .clientPhone)
        jobAddress = try c.decodeIfPresent(String.self, forKey: .jobAddress)
        jobTitle = try c.decodeIfPresent(String.self, forKey: .jobTitle)
        items = try c.decodeIfPresent([ExtractedItem].self, forKey: .items) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        // Older servers don't send changes.
        changes = try c.decodeIfPresent([ItemChange].self, forKey: .changes) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case clientName = "client_name"
        case clientEmail = "client_email"
        case clientPhone = "client_phone"
        case jobAddress = "job_address"
        case jobTitle = "job_title"
        case items
        case notes
        case changes
    }
}

/// A correction to one item already on the job, by its 1-based number in the list the AI was shown.
public struct ItemChange: Codable, Equatable, Sendable {
    public var itemNumber: Int
    public var newDescription: String?
    public var newQuantity: Double?
    public var newUnitPriceCents: Int?
    public var remove: Bool

    public init(itemNumber: Int, newDescription: String? = nil, newQuantity: Double? = nil,
                newUnitPriceCents: Int? = nil, remove: Bool = false) {
        self.itemNumber = itemNumber
        self.newDescription = newDescription
        self.newQuantity = newQuantity
        self.newUnitPriceCents = newUnitPriceCents
        self.remove = remove
    }

    public var isEmpty: Bool {
        newDescription == nil && newQuantity == nil && newUnitPriceCents == nil && !remove
    }

    enum CodingKeys: String, CodingKey {
        case itemNumber = "item_number"
        case newDescription = "new_description"
        case newQuantity = "new_quantity"
        case newUnitPriceCents = "new_unit_price_cents"
        case remove
    }
}

/// An item already on the job, as shown to the AI so it can be corrected by number.
public struct ExistingItem: Equatable, Sendable {
    public var description: String
    public var unitPriceCents: Int?
    public var quantity: Double

    public init(description: String, unitPriceCents: Int?, quantity: Double = 1) {
        self.description = description
        self.unitPriceCents = unitPriceCents
        self.quantity = quantity
    }

    /// Numbered lines for the prompt: "1. Paint kitchen and clean floor ($450.00)".
    public static func numberedList(_ items: [ExistingItem]) -> [String] {
        items.enumerated().map { index, item in
            var line = "\(index + 1). \(item.description)"
            if item.quantity != 1 { line += " x \(String(format: "%g", item.quantity))" }
            if let cents = item.unitPriceCents { line += " (\(Money.format(cents: cents)))" } else { line += " (no price)" }
            return line
        }
    }
}

public struct ExtractedItem: Codable, Equatable, Sendable {
    public var description: String
    public var quantity: Double
    /// nil when the price was not spoken. The app highlights these for review.
    public var unitPriceCents: Int?
    public var details: String?

    public init(description: String, quantity: Double = 1, unitPriceCents: Int? = nil, details: String? = nil) {
        self.description = description
        self.quantity = quantity
        self.unitPriceCents = unitPriceCents
        self.details = details
    }

    enum CodingKeys: String, CodingKey {
        case description
        case quantity
        case unitPriceCents = "unit_price_cents"
        case details
    }
}

/// The request body the app sends to the extraction proxy.
public struct ExtractionRequest: Codable, Equatable, Sendable {
    public var transcript: String
    /// Items already on the job, so a follow-up recording only adds what is new.
    public var existingItems: [String]
    /// Clients Dad has invoiced before, so the AI can reuse the exact spelling.
    public var knownClients: [String]

    public init(transcript: String, existingItems: [String] = [], knownClients: [String] = []) {
        self.transcript = transcript
        self.existingItems = existingItems
        self.knownClients = knownClients
    }

    enum CodingKeys: String, CodingKey {
        case transcript
        case existingItems = "existing_items"
        case knownClients = "known_clients"
    }
}

public enum ExtractionDecoding {
    public static func decode(_ data: Data) throws -> ExtractionResult {
        try JSONDecoder().decode(ExtractionResult.self, from: data)
    }
}
