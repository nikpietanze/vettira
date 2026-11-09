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

    private init(checkedEarly early: Double, strong: Double) {
        self.early = early
        self.strong = strong
    }

    private static func inRange(_ percent: Double) -> Bool { percent > 0 && percent < 100 }
}

public enum PullbackThresholdsError: Error, Equatable, LocalizedError {
    case outOfRange, earlyNotBelowStrong

    public var errorDescription: String? {
        switch self {
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
