import Foundation

/// How `ReversalAlertEngine` judges quotes and rearms, for every symbol. The thresholds are per
/// symbol (`PullbackThresholds`), given with each quote.
public struct AlertSettings: Equatable, Sendable {
    /// The defaults: rearm 0.10% above the last alerted high, a 5-minute cooldown, a 60-second
    /// staleness tolerance, and a 10% spike limit.
    public static let standard = AlertSettings(
        checkedRearmPercent: 0.10, cooldown: 300, staleTolerance: 60, spikePercent: 10)

    /// How far above the last alerted high, in percent, a new high must be to rearm the thresholds.
    public let rearmPercent: Double
    /// The shortest time between two alerts for the same threshold and symbol, by quote time.
    public let cooldown: TimeInterval
    /// The oldest a quote can be, and the most a provider can say it's delayed, for it to be used.
    public let staleTolerance: TimeInterval
    /// The largest move from the last accepted price, in percent, that a single quote can make. A
    /// bigger one is used only once a later quote confirms it.
    public let spikePercent: Double

    /// Each is a finite number: the rearm margin from 0 to under 100 percent, the cooldown 0 or
    /// more, and the staleness tolerance and spike limit more than 0. Any left out is the default.
    public init(
        rearmPercent: Double = AlertSettings.standard.rearmPercent,
        cooldown: TimeInterval = AlertSettings.standard.cooldown,
        staleTolerance: TimeInterval = AlertSettings.standard.staleTolerance,
        spikePercent: Double = AlertSettings.standard.spikePercent
    ) throws(AlertSettingsError) {
        guard rearmPercent.isFinite, rearmPercent >= 0, rearmPercent < 100 else { throw .rearmOutOfRange }
        guard cooldown.isFinite, cooldown >= 0 else { throw .cooldownOutOfRange }
        guard staleTolerance.isFinite, staleTolerance > 0 else { throw .staleToleranceOutOfRange }
        guard spikePercent.isFinite, spikePercent > 0 else { throw .spikeOutOfRange }
        self.init(checkedRearmPercent: rearmPercent, cooldown: cooldown, staleTolerance: staleTolerance,
                  spikePercent: spikePercent)
    }

    private init(checkedRearmPercent rearmPercent: Double, cooldown: TimeInterval,
                 staleTolerance: TimeInterval, spikePercent: Double) {
        self.rearmPercent = rearmPercent
        self.cooldown = cooldown
        self.staleTolerance = staleTolerance
        self.spikePercent = spikePercent
    }
}

public enum AlertSettingsError: Error, Equatable, LocalizedError {
    case rearmOutOfRange, cooldownOutOfRange, staleToleranceOutOfRange, spikeOutOfRange

    public var errorDescription: String? {
        switch self {
        case .rearmOutOfRange: "The rearm margin is from 0% to under 100%."
        case .cooldownOutOfRange: "The cooldown is 0 seconds or more."
        case .staleToleranceOutOfRange: "The staleness tolerance is more than 0 seconds."
        case .spikeOutOfRange: "The spike limit is more than 0%."
        }
    }
}

extension AlertSettings: Codable {
    private enum CodingKeys: String, CodingKey { case rearmPercent, cooldown, staleTolerance, spikePercent }

    // A field an older file doesn't have gets its default; a value out of range is rejected.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = Self.standard
        do {
            try self.init(
                rearmPercent: container.decodeIfPresent(Double.self, forKey: .rearmPercent) ?? standard.rearmPercent,
                cooldown: container.decodeIfPresent(Double.self, forKey: .cooldown) ?? standard.cooldown,
                staleTolerance: container.decodeIfPresent(Double.self, forKey: .staleTolerance) ?? standard.staleTolerance,
                spikePercent: container.decodeIfPresent(Double.self, forKey: .spikePercent) ?? standard.spikePercent)
        } catch let error as AlertSettingsError {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: error.errorDescription ?? ""))
        }
    }
}
