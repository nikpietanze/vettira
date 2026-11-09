import Foundation

/// The two pullbacks from the high, in percent, that raise an alert: an early warning and a
/// stronger one. Illustrative levels the user picks, not validated trading signals.
public struct PullbackThresholds: Equatable, Sendable {
    /// The defaults: 0.25% for the early warning, 0.40% for the stronger one.
    public static let standard = PullbackThresholds(checkedEarly: 0.25, strong: 0.40)

    /// Percent below the high for the early warning.
    public let early: Double
    /// Percent below the high for the stronger warning, above `early`.
    public let strong: Double

    /// Each is more than 0 and less than 100 percent, and `early` is below `strong`.
    public init(early: Double, strong: Double) throws(PullbackThresholdsError) {
        guard Self.inRange(early), Self.inRange(strong) else { throw .outOfRange }
        guard early < strong else { throw .earlyNotBelowStrong }
        self.init(checkedEarly: early, strong: strong)
    }

    /// From what the user typed: each a percent such as `0.25`, `0,25` or `0.25%`, with the same
    /// checks as above.
    public init(early: String, strong: String) throws(PullbackThresholdsError) {
        guard let early = Self.percent(early), let strong = Self.percent(strong) else { throw .notANumber }
        try self.init(early: early, strong: strong)
    }

    private init(checkedEarly early: Double, strong: Double) {
        self.early = early
        self.strong = strong
    }

    private static func inRange(_ percent: Double) -> Bool { percent > 0 && percent < 100 }

    /// A typed percent: digits with one `.` or `,`, an optional `%` after them, spaces around.
    private static func percent(_ text: String) -> Double? {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("%") { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        text = text.replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        return Double(text)
    }
}

public enum PullbackThresholdsError: Error, Equatable, LocalizedError {
    case outOfRange, earlyNotBelowStrong, notANumber

    public var errorDescription: String? {
        switch self {
        case .notANumber: "Enter each threshold as a percent, like 0.25."
        case .outOfRange: "A threshold is more than 0% and less than 100%."
        case .earlyNotBelowStrong: "The early warning is a smaller pullback than the stronger warning."
        }
    }
}

extension PullbackThresholds: Codable {
    private enum CodingKeys: String, CodingKey { case early, strong }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                early: container.decode(Double.self, forKey: .early),
                strong: container.decode(Double.self, forKey: .strong))
        } catch let error as PullbackThresholdsError {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: error.errorDescription ?? ""))
        }
    }
}
