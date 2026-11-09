import Foundation

/// Why a provider couldn't return quotes, each with a message saying what happened and a next step
/// saying what the user can do about it.
///
/// No case carries a raw response, so an error can be shown or logged as it is.
public enum ProviderError: Error, Sendable, Equatable {
    /// Too many requests in a short time. `retryAfter` is how long the provider asked to wait,
    /// when it said.
    case rateLimited(retryAfter: TimeInterval?)
    /// The provider refused the request, or answered with a consent page instead of data.
    case blocked
    /// The provider doesn't know these symbols.
    case unknownSymbols([String])
    /// The provider returned these symbols without a usable price or quote time.
    case noUsableQuote([String])
    /// The provider's response couldn't be read. `detail` says what was wrong with it, never
    /// what it contained.
    case malformedResponse(detail: String)
    /// The provider couldn't be reached, or answered with a server error.
    case unavailable

    /// What happened, in a sentence.
    public var message: String {
        switch self {
        case .rateLimited(let retryAfter):
            if let retryAfter {
                "The provider is limiting requests and asked Vettira to wait \(Self.duration(retryAfter))."
            } else {
                "The provider is limiting requests: too many were sent in a short time."
            }
        case .blocked:
            "The provider refused the request, or sent a consent page instead of quotes."
        case .unknownSymbols(let symbols):
            if symbols.count == 1 {
                "The provider doesn't recognize the symbol \(symbols[0])."
            } else {
                "The provider doesn't recognize the symbols \(symbols.joined(separator: ", "))."
            }
        case .noUsableQuote(let symbols):
            "The provider returned no usable price or quote time for \(symbols.joined(separator: ", "))."
        case .malformedResponse(let detail):
            "The provider sent a response Vettira couldn't read: \(detail)."
        case .unavailable:
            "Vettira couldn't reach the provider, or the provider had an error."
        }
    }

    /// What the user can do about it.
    public var nextStep: String {
        switch self {
        case .rateLimited:
            "Wait before trying again. If it keeps happening, lengthen the update interval."
        case .blocked:
            "Try again later. The provider can block automated requests from some networks or regions, and Vettira can't accept a consent page for you."
        case .unknownSymbols:
            "Check the spelling, and use the ticker the provider lists for the stock or ETF."
        case .noUsableQuote:
            "The symbol may be halted or newly listed. The rest of the watchlist isn't affected: check again later."
        case .malformedResponse:
            "Try again later. If it keeps happening, the provider may have changed its responses: please report it as an issue on Vettira's repository."
        case .unavailable:
            "Check your internet connection. If it's working, the provider may be down: try again later."
        }
    }

    /// A wait, in whole seconds under a minute and whole minutes (rounded up) from there.
    private static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        if whole < 60 {
            return whole == 1 ? "1 second" : "\(whole) seconds"
        }
        let minutes = (whole + 59) / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

extension ProviderError: LocalizedError {
    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { nextStep }
}
