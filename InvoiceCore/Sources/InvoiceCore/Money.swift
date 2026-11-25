import Foundation

/// Money is stored as whole cents to avoid floating point rounding errors.
public enum Money {
    /// Formats cents as a US dollar string, e.g. 12345 -> "$123.45".
    public static func format(cents: Int, locale: Locale = Locale(identifier: "en_US")) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = "USD"
        let amount = Decimal(cents) / 100
        return formatter.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }

    /// Parses user-typed text such as "120", "$1,200.50" or "45.5" into cents.
    public static func parseCents(_ text: String) -> Int? {
        let cleaned = text
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US")) else {
            return nil
        }
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// quantity × unit price, rounded to the nearest cent.
    public static func lineTotal(quantity: Double, unitPriceCents: Int) -> Int {
        Int((quantity * Double(unitPriceCents)).rounded())
    }
}
