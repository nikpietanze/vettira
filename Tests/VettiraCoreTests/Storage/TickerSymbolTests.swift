import Foundation
import Testing
import VettiraCore

@Test(arguments: [
    ("SPY", "SPY"), (" aapl\n", "AAPL"), ("brk.b", "BRK.B"), ("BRK-B", "BRK-B"), ("^GSPC", "^GSPC"),
    ("ES=F", "ES=F"), ("ABCDEFGHIJKLMNO", "ABCDEFGHIJKLMNO"),
])
func aTickerIsTrimmedAndUppercased(input: String, expected: String) throws {
    #expect(try TickerSymbol(input).rawValue == expected)
}

@Test(arguments: [
    ("", TickerSymbolError.empty), ("   ", .empty), ("ABCDEFGHIJKLMNOP", .tooLong), ("SP Y", .invalidCharacters),
    ("AAPL$", .invalidCharacters), ("ÄPL", .invalidCharacters), ("...", .invalidCharacters), ("^", .invalidCharacters),
])
func aTickerThatIsntOneIsRejected(input: String, error: TickerSymbolError) {
    #expect(throws: error) { try TickerSymbol(input) }
}

@Test func aTickerDecodesOnlyIfValid() throws {
    #expect(try JSONDecoder().decode(TickerSymbol.self, from: Data(#""spy""#.utf8)) == TickerSymbol("SPY"))
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(TickerSymbol.self, from: Data(#""S P Y""#.utf8)) }
}
