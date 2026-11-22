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

    public init(
        clientName: String? = nil,
        clientEmail: String? = nil,
        clientPhone: String? = nil,
        jobAddress: String? = nil,
        jobTitle: String? = nil,
        items: [ExtractedItem] = [],
        notes: String? = nil
    ) {
        self.clientName = clientName
        self.clientEmail = clientEmail
        self.clientPhone = clientPhone
        self.jobAddress = jobAddress
        self.jobTitle = jobTitle
        self.items = items
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case clientName = "client_name"
        case clientEmail = "client_email"
        case clientPhone = "client_phone"
        case jobAddress = "job_address"
        case jobTitle = "job_title"
        case items
        case notes
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
