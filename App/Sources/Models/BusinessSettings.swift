import Foundation
import InvoiceCore

/// Business details set once (by Brian) in Settings. Stored in UserDefaults.
enum BusinessSettings {
    private static let defaults = UserDefaults.standard

    enum Key {
        static let name = "business.name"
        static let owner = "business.owner"
        static let address = "business.address"
        static let phone = "business.phone"
        static let email = "business.email"
        static let terms = "business.terms"
        static let tax = "business.taxPercent"
        static let nextInvoice = "business.nextInvoiceNumber"
        static let recordEmail = "business.jobRecordEmail"
    }

    static var info: BusinessInfo {
        BusinessInfo(
            name: defaults.string(forKey: Key.name) ?? "",
            ownerName: defaults.string(forKey: Key.owner) ?? "",
            address: defaults.string(forKey: Key.address) ?? "",
            phone: defaults.string(forKey: Key.phone) ?? "",
            email: defaults.string(forKey: Key.email) ?? "",
            paymentTerms: defaults.string(forKey: Key.terms) ?? "",
            taxRatePercent: defaults.double(forKey: Key.tax)
        )
    }

    /// Who the job-record draft is addressed to (e.g. Brian). Empty: no recipient.
    static var recordEmail: String {
        defaults.string(forKey: Key.recordEmail)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Next invoice number to use. Starts at 1.
    static var nextInvoiceNumber: Int {
        get { max(1, defaults.integer(forKey: Key.nextInvoice)) }
        set { defaults.set(newValue, forKey: Key.nextInvoice) }
    }
}

/// Values injected at build time from Config/Secrets.xcconfig through Info.plist.
enum AppConfig {
    static var extractionURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "ExtractionProxyURL") as? String)
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    static var appToken: String {
        Bundle.main.object(forInfoDictionaryKey: "ExtractionAppToken") as? String ?? ""
    }
}
