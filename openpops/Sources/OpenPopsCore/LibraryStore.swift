import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reads and writes library.json. The main app and every Dock tile app share this file,
/// so writes happen under an exclusive file lock and always start from the latest copy
/// on disk.
public final class LibraryStore {
    public let directory: URL
    public let fileURL: URL
    private let lockPath: String

    public private(set) var library: Library
    /// False on the very first launch, before library.json exists.
    public let fileExisted: Bool
    public private(set) var lastError: String?

    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }
    private var stamp: Stamp?

    public init(directory: URL = LibraryStore.defaultDirectory) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("library.json")
        self.lockPath = directory.appendingPathComponent(".library.lock").path
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.library = Library()
        self.fileExisted = FileManager.default.fileExists(atPath: fileURL.path)
        reload(force: true)
    }

    /// ~/Library/Application Support/OpenPops
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OpenPops", isDirectory: true)
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func currentStamp() -> Stamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else { return nil }
        let date = attrs[.modificationDate] as? Date ?? .distantPast
        let size = (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int) ?? 0
        return Stamp(modified: date, size: size)
    }

    /// Re-reads the file if it changed since the last read or write. Returns true when the
    /// in-memory library was replaced.
    @discardableResult
    public func reload(force: Bool = false) -> Bool {
        let now = currentStamp()
        if !force && now == stamp { return false }
        stamp = now
        guard now != nil, let data = try? Data(contentsOf: fileURL) else { return false }
        do {
            library = try LibraryStore.decoder.decode(Library.self, from: data)
            lastError = nil
            return true
        } catch {
            lastError = "library.json could not be read (\(error.localizedDescription)). A copy was saved next to it."
            backUpUnreadable(data)
            return false
        }
    }

    /// Applies `body` to the latest library on disk and saves the result.
    @discardableResult
    public func update(_ body: (inout Library) -> Void) -> Bool {
        withLock {
            reload()
            var copy = library
            body(&copy)
            copy.version = Library.currentVersion
            library = copy
            do {
                try write(copy)
                lastError = nil
                return true
            } catch {
                lastError = "Could not save library.json: \(error.localizedDescription)"
                return false
            }
        }
    }

    /// Replaces the whole library, e.g. after an import.
    @discardableResult
    public func replace(with newLibrary: Library) -> Bool {
        update { $0 = newLibrary }
    }

    public func exportData() throws -> Data {
        try LibraryStore.encoder.encode(library)
    }

    public static func decodeLibrary(from data: Data) throws -> Library {
        try decoder.decode(Library.self, from: data)
    }

    /// Keeps one copy of the library from the start of each launch.
    public func makeLaunchBackup() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let backup = directory.appendingPathComponent("library.backup.json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: fileURL, to: backup)
    }

    private func write(_ lib: Library) throws {
        let data = try LibraryStore.encoder.encode(lib)
        try data.write(to: fileURL, options: .atomic)
        stamp = currentStamp()
    }

    private func backUpUnreadable(_ data: Data) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("library.unreadable-\(f.string(from: Date())).json")
        try? data.write(to: url, options: .atomic)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return body()
    }
}
