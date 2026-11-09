import Foundation

/// One symbol on the watchlist and its own settings.
public struct WatchlistEntry: Equatable, Sendable, Identifiable {
    public let symbol: TickerSymbol
    /// Pinned symbols list before the others.
    public var isPinned = false
    /// A disabled symbol stays on the list but isn't monitored.
    public var isEnabled = true
    /// This symbol's thresholds, or nil to use the global defaults.
    public var thresholds: PullbackThresholds?

    public var id: TickerSymbol { symbol }

    public init(symbol: TickerSymbol) {
        self.symbol = symbol
    }
}

/// The user's symbols in their order, and the one the menu bar shows. Each symbol is on it once,
/// and the menu-bar symbol is one of them: nil only when the list is empty.
public struct Watchlist: Equatable, Sendable {
    public private(set) var entries: [WatchlistEntry] = []
    public private(set) var menuBarSymbol: TickerSymbol?

    public init() {}

    /// The entries as they're listed: pinned first, each group in the user's order.
    public var displayOrder: [WatchlistEntry] {
        entries.filter(\.isPinned) + entries.filter { !$0.isPinned }
    }

    public func entry(for symbol: TickerSymbol) -> WatchlistEntry? {
        entries.first { $0.symbol == symbol }
    }

    /// Adds the symbol at the end, enabled and on the global thresholds. The first symbol added
    /// becomes the menu bar's.
    public mutating func add(_ symbol: TickerSymbol) throws(WatchlistError) {
        guard entry(for: symbol) == nil else { throw .alreadyInList(symbol) }
        entries.append(WatchlistEntry(symbol: symbol))
        if menuBarSymbol == nil { menuBarSymbol = symbol }
    }

    /// Removes the symbol. If the menu bar showed it, it shows the first one left.
    public mutating func remove(_ symbol: TickerSymbol) throws(WatchlistError) {
        let index = try index(of: symbol)
        entries.remove(at: index)
        if menuBarSymbol == symbol { menuBarSymbol = entries.first?.symbol }
    }

    /// Moves the entries at `source` to before `destination`, as SwiftUI's `onMove` reports a
    /// drag: offsets into `entries`, `destination` from 0 to `entries.count`.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { entries[$0] }
        let remaining = entries.indices.filter { !source.contains($0) }.map { entries[$0] }
        let insertAt = destination - source.filter { $0 < destination }.count
        entries = Array(remaining[..<insertAt]) + moving + remaining[insertAt...]
    }

    public mutating func setPinned(_ pinned: Bool, for symbol: TickerSymbol) throws(WatchlistError) {
        entries[try index(of: symbol)].isPinned = pinned
    }

    public mutating func setEnabled(_ enabled: Bool, for symbol: TickerSymbol) throws(WatchlistError) {
        entries[try index(of: symbol)].isEnabled = enabled
    }

    /// Sets the symbol's own thresholds, or nil to go back to the global defaults.
    public mutating func setThresholds(
        _ thresholds: PullbackThresholds?, for symbol: TickerSymbol
    ) throws(WatchlistError) {
        entries[try index(of: symbol)].thresholds = thresholds
    }

    public mutating func showInMenuBar(_ symbol: TickerSymbol) throws(WatchlistError) {
        _ = try index(of: symbol)
        menuBarSymbol = symbol
    }

    private func index(of symbol: TickerSymbol) throws(WatchlistError) -> Int {
        guard let index = entries.firstIndex(where: { $0.symbol == symbol }) else { throw .notInList(symbol) }
        return index
    }
}

public enum WatchlistError: Error, Equatable, LocalizedError {
    case alreadyInList(TickerSymbol), notInList(TickerSymbol)

    public var errorDescription: String? {
        switch self {
        case .alreadyInList(let symbol): "\(symbol) is already on the watchlist."
        case .notInList(let symbol): "\(symbol) isn't on the watchlist."
        }
    }
}

// Decoding fills a field an older file doesn't have with its default, and rejects a list that
// breaks the invariants above.

extension WatchlistEntry: Codable {
    private enum CodingKeys: String, CodingKey { case symbol, isPinned, isEnabled, thresholds }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try container.decode(TickerSymbol.self, forKey: .symbol)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        thresholds = try container.decodeIfPresent(PullbackThresholds.self, forKey: .thresholds)
    }
}

extension Watchlist: Codable {
    private enum CodingKeys: String, CodingKey { case entries, menuBarSymbol }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([WatchlistEntry].self, forKey: .entries) ?? []
        guard Set(entries.map(\.symbol)).count == entries.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .entries, in: container, debugDescription: "A symbol is on the watchlist twice.")
        }
        let selected = try container.decodeIfPresent(TickerSymbol.self, forKey: .menuBarSymbol)
        if let selected, entry(for: selected) == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .menuBarSymbol, in: container, debugDescription: "The menu-bar symbol isn't on the watchlist.")
        }
        menuBarSymbol = selected ?? entries.first?.symbol
    }
}
