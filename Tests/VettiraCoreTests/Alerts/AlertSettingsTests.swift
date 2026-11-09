import Foundation
import Testing
import VettiraCore

// The defaults are the issue's (a rearm 0.10% above the last alerted high, a 60-second staleness
// tolerance) and the engine's documented ones (a 5-minute cooldown, a 10% spike limit).

@Test func theStandardSettingsAreTheDocumentedDefaults() {
    let standard = AlertSettings.standard
    #expect(standard.rearmPercent == 0.10)
    #expect(standard.cooldown == 300)
    #expect(standard.staleTolerance == 60)
    #expect(standard.spikePercent == 10)
}

@Test func settingsLeftOutAreTheDefaults() throws {
    let settings = try AlertSettings(staleTolerance: 120)
    #expect(settings.staleTolerance == 120)
    #expect(settings.rearmPercent == 0.10)
    #expect(settings.cooldown == 300)
    #expect(settings.spikePercent == 10)
}

@Test func settingsAtTheEdgesOfTheirRangesAreKept() throws {
    let settings = try AlertSettings(rearmPercent: 0, cooldown: 0, staleTolerance: 1, spikePercent: 0.5)
    #expect(settings.rearmPercent == 0)
    #expect(settings.cooldown == 0)
}

@Test(arguments: [
    (AlertSettingsCase(rearmPercent: -0.1), AlertSettingsError.rearmOutOfRange),
    (AlertSettingsCase(rearmPercent: 100), .rearmOutOfRange),
    (AlertSettingsCase(rearmPercent: .nan), .rearmOutOfRange),
    (AlertSettingsCase(cooldown: -1), .cooldownOutOfRange),
    (AlertSettingsCase(cooldown: .infinity), .cooldownOutOfRange),
    (AlertSettingsCase(staleTolerance: 0), .staleToleranceOutOfRange),
    (AlertSettingsCase(staleTolerance: -60), .staleToleranceOutOfRange),
    (AlertSettingsCase(spikePercent: 0), .spikeOutOfRange),
    (AlertSettingsCase(spikePercent: .nan), .spikeOutOfRange),
])
func settingsOutOfRangeAreRejected(values: AlertSettingsCase, error: AlertSettingsError) {
    #expect(throws: error) {
        try AlertSettings(rearmPercent: values.rearmPercent, cooldown: values.cooldown,
                          staleTolerance: values.staleTolerance, spikePercent: values.spikePercent)
    }
}

@Test func settingsDecodeOnlyIfValidAndFillInWhatsMissing() throws {
    let partial = Data(#"{"staleTolerance": 90}"#.utf8)
    #expect(try JSONDecoder().decode(AlertSettings.self, from: partial) == AlertSettings(staleTolerance: 90))
    let invalid = Data(#"{"cooldown": -5}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(AlertSettings.self, from: invalid) }
}

@Test func settingsRoundTripThroughJSON() throws {
    let settings = try AlertSettings(rearmPercent: 0.2, cooldown: 120, staleTolerance: 45, spikePercent: 15)
    #expect(try JSONDecoder().decode(AlertSettings.self, from: JSONEncoder().encode(settings)) == settings)
}

/// One set of values to build `AlertSettings` from, each the default unless given.
struct AlertSettingsCase: Sendable {
    var rearmPercent = 0.10
    var cooldown: TimeInterval = 300
    var staleTolerance: TimeInterval = 60
    var spikePercent = 10.0
}
