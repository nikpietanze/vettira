import Foundation
import Testing
import VettiraCore

@Test func theStandardThresholdsAreTheSpecs() {
    #expect(PullbackThresholds.standard.early == 0.25)
    #expect(PullbackThresholds.standard.strong == 0.40)
}

@Test func thresholdsInRangeAreKept() throws {
    let thresholds = try PullbackThresholds(early: 0.1, strong: 99.9)
    #expect(thresholds.early == 0.1)
    #expect(thresholds.strong == 99.9)
}

@Test(arguments: [
    (0, 0.4, PullbackThresholdsError.outOfRange), (-0.25, 0.4, .outOfRange), (0.25, 100, .outOfRange),
    (Double.nan, 0.4, .outOfRange), (0.25, .infinity, .outOfRange), (0.4, 0.4, .earlyNotBelowStrong),
    (0.5, 0.4, .earlyNotBelowStrong),
])
func thresholdsOutOfRangeOrOutOfOrderAreRejected(early: Double, strong: Double, error: PullbackThresholdsError) {
    #expect(throws: error) { try PullbackThresholds(early: early, strong: strong) }
}

@Test func thresholdsDecodeOnlyIfValid() throws {
    let valid = Data(#"{"early": 0.3, "strong": 0.5}"#.utf8)
    #expect(try JSONDecoder().decode(PullbackThresholds.self, from: valid) == PullbackThresholds(early: 0.3, strong: 0.5))
    let reversed = Data(#"{"early": 0.5, "strong": 0.3}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(PullbackThresholds.self, from: reversed) }
}

// What the user types in Settings and the dashboard: a percent with a point or a comma.
@Test(arguments: [
    ("0.25", "0.40", 0.25, 0.40), (" 0,3 ", "1", 0.3, 1.0), ("0.5%", "0.75 %", 0.5, 0.75), (".2", "2.", 0.2, 2.0),
])
func typedThresholdsAreRead(early: String, strong: String, expectedEarly: Double, expectedStrong: Double) throws {
    let thresholds = try PullbackThresholds(early: early, strong: strong)
    #expect(thresholds.early == expectedEarly)
    #expect(thresholds.strong == expectedStrong)
}

@Test(arguments: [
    ("", "0.4", PullbackThresholdsError.notANumber), ("abc", "0.4", .notANumber), ("0.25", "-1", .notANumber),
    ("1e-1", "0.4", .notANumber), ("0.2.5", "0.4", .notANumber), ("0", "0.4", .outOfRange),
    ("0.5", "0.4", .earlyNotBelowStrong),
])
func typedThresholdsThatArentPercentsAreRejected(early: String, strong: String, error: PullbackThresholdsError) {
    #expect(throws: error) { try PullbackThresholds(early: early, strong: strong) }
}
