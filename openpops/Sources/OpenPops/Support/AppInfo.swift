import AppKit
import OpenPopsCore

/// Whether this process is the main OpenPops app or one of the Dock tile apps it generates.
/// Tile apps are copies of this same executable whose Info.plist names the Pop (or group)
/// they open.
enum RunMode: Equatable {
    case main
    case tile(TileTarget)

    static let current: RunMode = {
        if let raw = Bundle.main.object(forInfoDictionaryKey: AppInfo.tileTargetKey) as? String,
           let target = TileTarget(string: raw) {
            return .tile(target)
        }
        return .main
    }()

    var isMain: Bool { self == .main }

    var tileTarget: TileTarget? {
        if case .tile(let t) = self { return t }
        return nil
    }
}

enum AppInfo {
    static let mainBundleID = "com.spiiira.openpops"
    static let tileBundlePrefix = "com.spiiira.openpops.tile."
    static let tileTargetKey = "OPTileTarget"
    static let mainAppPathKey = "OPMainAppPath"
    static let buildIDKey = "OPBuildID"
    static let urlScheme = "openpops"
    static let readmeURL = URL(string: "https://github.com/jonasspira/jonasspira.github.io/tree/main/openpops#readme")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Identifies the build a tile was generated from, so outdated tiles get rebuilt.
    static var buildID: String {
        Bundle.main.object(forInfoDictionaryKey: buildIDKey) as? String ?? "dev"
    }

    /// Where the main app lives. Tiles use this to open the Organizer.
    static var mainAppURL: URL? {
        if RunMode.current.isMain { return Bundle.main.bundleURL }
        if let path = Bundle.main.object(forInfoDictionaryKey: mainAppPathKey) as? String,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: mainBundleID)
    }

    /// ~/Applications/OpenPops Tiles, where generated Dock tile apps live.
    static var tilesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/OpenPops Tiles", isDirectory: true)
    }

    /// True when running from an .app bundle (not a bare executable during development).
    static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}

/// Appends to ~/Library/Application Support/OpenPops/debug.log when the file
/// "debug-log-enabled" exists in that folder. Used by the CI smoke tests.
enum DebugLog {
    static let directory = LibraryStore.defaultDirectory
    static let enabled: Bool = {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("debug-log-enabled").path)
            || ProcessInfo.processInfo.environment["OPENPOPS_DEBUG"] == "1"
    }()
    private static let url = directory.appendingPathComponent("debug.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let who: String
        switch RunMode.current {
        case .main: who = "main"
        case .tile(let t): who = "tile " + t.stringValue.prefix(13)
        }
        let line = "\(formatter.string(from: Date())) [\(who)] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
