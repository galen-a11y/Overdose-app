import Foundation

/// Someone who gets a text if the person doesn't respond. Stored only on the
/// phone; sent to the server with each session and deleted there when it ends.
public struct EmergencyContact: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// E.164 format, for example "+15035550123".
    public var phone: String
    /// Set once the contact has confirmed they received the setup test text.
    public var testConfirmed: Bool

    public init(id: UUID = UUID(), name: String, phone: String, testConfirmed: Bool = false) {
        self.id = id
        self.name = name
        self.phone = phone
        self.testConfirmed = testConfirmed
    }

    public static let maximumCount = 3
}

public enum PhoneNumber {
    /// Normalizes what a person typed into E.164. Numbers without a country code
    /// are treated as US/Canada (+1). Returns `nil` if it can't be a real number.
    public static func normalize(_ input: String, defaultCountryCode: String = "1") -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPlus = trimmed.hasPrefix("+")
        let digits = trimmed.filter(\.isASCIIDigit)

        let e164: String
        if hasPlus {
            e164 = "+" + digits
        } else if defaultCountryCode == "1", digits.count == 11, digits.hasPrefix("1") {
            e164 = "+" + digits
        } else if defaultCountryCode == "1", digits.count == 10 {
            e164 = "+1" + digits
        } else if defaultCountryCode != "1", digits.count >= 6 {
            e164 = "+" + defaultCountryCode + digits.drop(while: { $0 == "0" })
        } else {
            return nil
        }
        return isValidE164(e164) ? e164 : nil
    }

    public static func isValidE164(_ value: String) -> Bool {
        guard value.hasPrefix("+") else { return false }
        let digits = value.dropFirst()
        guard (8...15).contains(digits.count), digits.allSatisfy(\.isASCIIDigit), digits.first != "0" else {
            return false
        }
        // North American numbers: area code and exchange can't start with 0 or 1.
        if digits.first == "1" {
            guard digits.count == 11 else { return false }
            let area = digits.dropFirst().first!
            let exchange = digits.dropFirst(4).first!
            return area >= "2" && exchange >= "2"
        }
        return true
    }

    /// "+15035550123" -> "(503) 555-0123" for US numbers; anything else is returned as is.
    public static func display(_ e164: String) -> String {
        let digits = Array(e164.dropFirst())
        guard e164.hasPrefix("+1"), digits.count == 11 else { return e164 }
        let d = digits.map(String.init)
        return "(\(d[1...3].joined())) \(d[4...6].joined())-\(d[7...10].joined())"
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
