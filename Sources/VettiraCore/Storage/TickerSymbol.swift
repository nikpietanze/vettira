import Foundation

/// A stock or ETF ticker, checked where it comes in: trimmed, uppercased, 1 to 15 characters of
/// letters, digits and `.` `-` `^` `=` (`SPY`, `BRK.B`, `BRK-B`, `^GSPC`), with at least one
/// letter or digit.
public struct TickerSymbol: Hashable, Comparable, Sendable, CustomStringConvertible {
    public static let maxLength = 15
    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-^=")
    private static let alphanumeric = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    public let rawValue: String

    public init(_ input: String) throws(TickerSymbolError) {
        let symbol = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty else { throw .empty }
        guard symbol.count <= Self.maxLength else { throw .tooLong }
        guard symbol.allSatisfy(Self.allowed.contains), symbol.contains(where: Self.alphanumeric.contains)
        else { throw .invalidCharacters }
        rawValue = symbol
    }

    public var description: String { rawValue }

    public static func < (lhs: TickerSymbol, rhs: TickerSymbol) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum TickerSymbolError: Error, Equatable, LocalizedError {
    case empty, tooLong, invalidCharacters

    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a ticker symbol."
        case .tooLong: "A ticker symbol is at most \(TickerSymbol.maxLength) characters."
        case .invalidCharacters: "A ticker symbol has only letters, digits and . - ^ =."
        }
    }
}

extension TickerSymbol: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        do {
            self = try TickerSymbol(raw)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a ticker symbol: \(error.errorDescription ?? "")")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
