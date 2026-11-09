import Foundation

/// Saves the alert engine's state (`ReversalAlertEngine.State`) as JSON in one file,
/// `alert-state.json`, in the same directory as the settings, so a relaunch carries on without
/// alerting again for a pullback it already alerted.
///
/// The file is only a cache of what the engine remembers: a missing one is an empty state, and
/// one that can't be read, isn't valid state or is another version throws, for the app to log
/// and start from an empty state. The next save replaces it.
public struct AlertStateStore: Sendable {
    public static let fileName = "alert-state.json"
    /// The file's format. A file of any other version is read as no saved state.
    public static let version = 1

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var fileURL: URL { directory.appending(path: Self.fileName) }

    /// The saved state, or an empty one if nothing is saved yet.
    public func load() throws(AlertStateStoreError) -> ReversalAlertEngine.State {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return .init()
        } catch {
            throw .unreadable(fileURL, reason: error.localizedDescription)
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw .corrupt(fileURL) }
        guard header.version == Self.version else { throw .unsupportedVersion(header.version, fileURL) }
        do {
            return try decoder.decode(Saved.self, from: data).state
        } catch {
            throw .corrupt(fileURL)
        }
    }

    /// Writes the state, replacing the file whole, so a crash leaves the old file or the new one,
    /// never half of each.
    public func save(_ state: ReversalAlertEngine.State) throws(AlertStateStoreError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(Saved(version: Self.version, state: state))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw .unwritable(fileURL, reason: error.localizedDescription)
        }
    }

    private struct Header: Decodable {
        let version: Int
    }

    private struct Saved: Codable {
        let version: Int
        let state: ReversalAlertEngine.State
    }
}

public enum AlertStateStoreError: Error, Equatable, LocalizedError {
    /// The file exists but couldn't be read.
    case unreadable(URL, reason: String)
    /// The file isn't valid alert state.
    case corrupt(URL)
    /// The file is valid JSON of a format version this build doesn't read.
    case unsupportedVersion(Int, URL)
    case unwritable(URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url, let reason):
            "Couldn't read the saved alert state at \(url.path), so alerts start afresh: \(reason)"
        case .corrupt(let url):
            "The saved alert state at \(url.path) isn't valid, so alerts start afresh."
        case .unsupportedVersion(let version, let url):
            "The saved alert state at \(url.path) is version \(version), not \(AlertStateStore.version), so alerts start afresh."
        case .unwritable(let url, let reason): "Couldn't save the alert state to \(url.path): \(reason)"
        }
    }
}
