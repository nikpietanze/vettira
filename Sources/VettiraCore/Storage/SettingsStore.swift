import Foundation

/// Saves `UserSettings` as JSON in one file, `settings.json`, in a directory: for the app,
/// `~/Library/Application Support/Vettira/`.
public struct SettingsStore: Sendable {
    public static let fileName = "settings.json"
    /// Where a file that can't be read as settings is moved, so a save doesn't overwrite it.
    public static let corruptFileName = "settings.corrupt.json"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The app's store, in the user's Application Support directory.
    public static func applicationSupport() throws -> SettingsStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return SettingsStore(directory: base.appending(path: Vettira.name, directoryHint: .isDirectory))
    }

    public var fileURL: URL { directory.appending(path: Self.fileName) }
    public var corruptFileURL: URL { directory.appending(path: Self.corruptFileName) }

    /// The saved settings, or the defaults if nothing is saved yet. A file that isn't valid
    /// settings is moved to `corruptFileURL`, replacing an older one, and throws `.corrupt`; the
    /// next load then returns the defaults.
    public func load() throws(SettingsStoreError) -> UserSettings {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return .defaults
        } catch {
            throw .unreadable(fileURL, reason: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(UserSettings.self, from: data)
        } catch {
            try moveAside()
            throw .corrupt(movedTo: corruptFileURL)
        }
    }

    /// Writes the settings, replacing the file whole, so a crash leaves the old file or the new
    /// one, never half of each.
    public func save(_ settings: UserSettings) throws(SettingsStoreError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(settings)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw .unwritable(fileURL, reason: error.localizedDescription)
        }
    }

    private func moveAside() throws(SettingsStoreError) {
        do {
            do {
                try FileManager.default.removeItem(at: corruptFileURL)
            } catch CocoaError.fileNoSuchFile {}
            try FileManager.default.moveItem(at: fileURL, to: corruptFileURL)
        } catch {
            throw .unwritable(corruptFileURL, reason: error.localizedDescription)
        }
    }
}

public enum SettingsStoreError: Error, Equatable, LocalizedError {
    /// The file exists but couldn't be read; it's left where it is.
    case unreadable(URL, reason: String)
    /// The file wasn't valid settings; it was moved to `movedTo`.
    case corrupt(movedTo: URL)
    case unwritable(URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url, let reason): "Couldn't read your settings at \(url.path): \(reason)"
        case .corrupt(let url):
            "Your settings couldn't be read, so Vettira started from the defaults. The old file is at \(url.path)."
        case .unwritable(let url, let reason): "Couldn't save your settings to \(url.path): \(reason)"
        }
    }
}
