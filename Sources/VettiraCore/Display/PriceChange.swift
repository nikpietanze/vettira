import Foundation

/// Which characters of a price changed, as the menu bar shows it, and which way it moved. The two
/// prices are compared as displayed, character by character from the left: everything from the
/// first character that differs to the end changed, and the menu bar colours it, green for up and
/// red for down. When the number of characters changes (`99.98` to `100.02`), all of it changed.
public struct PriceChange: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case up, down
    }

    /// The old price, as displayed: `740.43`.
    public let from: String
    /// The new price, as displayed: `741.12`.
    public let to: String
    public let direction: Direction
    /// How many characters at the start of `to` are the same as `from`'s.
    public let unchangedCount: Int

    /// The change from `old` to `new`, or `nil` when they display the same.
    public init?(from old: Double, to new: Double) {
        from = DisplayFormat.price(old)
        to = DisplayFormat.price(new)
        guard from != to else { return nil }
        direction = new > old ? .up : .down
        unchangedCount = from.count == to.count ? zip(from, to).prefix { $0 == $1 }.count : 0
    }

    /// The start of `to` that stayed the same: `74` in `741.12`, after `740.43`.
    public var unchanged: Substring { to.prefix(unchangedCount) }
    /// The rest of `to`, which changed: `1.12` in `741.12`, after `740.43`.
    public var changed: Substring { to.dropFirst(unchangedCount) }
}

/// Each symbol's latest price and its last change, from every snapshot the app gets, so each
/// symbol keeps its own colouring until its price next changes, whichever symbol the menu bar is
/// showing. It only remembers prices the monitor already has: it asks for nothing.
public struct PriceChanges: Equatable, Sendable {
    private var prices: [TickerSymbol: Double] = [:]
    private var changes: [TickerSymbol: PriceChange] = [:]

    public init() {}

    /// Takes each symbol's price from `snapshot`: a price that displays differently from the last
    /// one is the symbol's new change; one that displays the same keeps the last change.
    public mutating func record(_ snapshot: MonitorSnapshot) {
        for (symbol, state) in snapshot.symbols {
            guard let price = state.quote?.price else { continue }
            if let old = prices[symbol], let change = PriceChange(from: old, to: price) {
                changes[symbol] = change
            }
            prices[symbol] = price
        }
    }

    /// The symbol's last change, or `nil` before its price has changed.
    public subscript(symbol: TickerSymbol) -> PriceChange? {
        changes[symbol]
    }
}
