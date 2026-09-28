import AppKit
import OpenPopsCore

/// Reads the Dock's position and size, and adds or removes pinned apps.
/// Pinning edits com.apple.dock's "persistent-apps" and restarts the Dock, which is the
/// only way to pin an app programmatically.
enum DockPrefs {
    private static let domain = "com.apple.dock" as CFString

    private static func value(_ key: String) -> CFPropertyList? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    static func layout() -> DockLayout {
        CFPreferencesAppSynchronize(domain)
        let orientation = (value("orientation") as? String).flatMap(DockLayout.Orientation.init(rawValue:)) ?? .bottom
        let autohide = (value("autohide") as? NSNumber)?.boolValue ?? false
        let tileSize = (value("tilesize") as? NSNumber)?.doubleValue ?? 48
        return DockLayout(orientation: orientation, autohide: autohide, tileSize: tileSize)
    }

    private static func persistentApps() -> [[String: Any]] {
        CFPreferencesAppSynchronize(domain)
        return (value("persistent-apps") as? [[String: Any]]) ?? []
    }

    private static func path(of entry: [String: Any]) -> String? {
        guard let tile = entry["tile-data"] as? [String: Any],
              let file = tile["file-data"] as? [String: Any],
              let raw = file["_CFURLString"] as? String else { return nil }
        if raw.hasPrefix("file://") {
            return URL(string: raw).map { PopItem.standardizedPath($0.path) }
        }
        return PopItem.standardizedPath(raw)
    }

    static func isPinned(path: String) -> Bool {
        let target = PopItem.standardizedPath(path)
        return persistentApps().contains { self.path(of: $0) == target }
    }

    /// Adds an app to the Dock's pinned apps. Returns false if it was already there.
    @discardableResult
    static func pin(path: String, label: String, bundleID: String?) -> Bool {
        var apps = persistentApps()
        let target = PopItem.standardizedPath(path)
        guard !apps.contains(where: { self.path(of: $0) == target }) else { return false }
        var tileData: [String: Any] = [
            "file-data": [
                "_CFURLString": URL(fileURLWithPath: target, isDirectory: true).absoluteString,
                "_CFURLStringType": 15,
            ],
            "file-label": label,
            "file-type": 41,
        ]
        if let bundleID = bundleID { tileData["bundle-identifier"] = bundleID }
        apps.append(["tile-data": tileData, "tile-type": "file-tile"])
        CFPreferencesSetAppValue("persistent-apps" as CFString, apps as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        return true
    }

    /// Removes an app from the Dock's pinned apps. Returns false if it wasn't pinned.
    @discardableResult
    static func unpin(path: String) -> Bool {
        let target = PopItem.standardizedPath(path)
        let apps = persistentApps()
        let kept = apps.filter { self.path(of: $0) != target }
        guard kept.count != apps.count else { return false }
        CFPreferencesSetAppValue("persistent-apps" as CFString, kept as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        return true
    }

    /// Relaunches the Dock so it picks up pinned apps and new icons.
    static func restartDock() {
        DebugLog.log("restarting Dock")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
    }
}
