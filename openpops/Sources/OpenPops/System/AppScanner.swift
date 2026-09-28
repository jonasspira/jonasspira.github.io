import AppKit
import OpenPopsCore

/// Finds installed apps for the App Browser and suggestions.
enum AppScanner {
    static var searchFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/Applications/Utilities",
            home.appendingPathComponent("Applications").path,
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Scans app folders two levels deep (to catch apps inside vendor folders).
    /// Runs synchronously; call it off the main thread.
    static func scan() -> [InstalledApp] {
        var seen = Set<String>()
        var result: [InstalledApp] = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .addedToDirectoryDateKey, .creationDateKey]
        let tilesFolder = AppInfo.tilesFolder.standardizedFileURL.path

        func visit(_ folder: URL, depth: Int) {
            guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles]) else { return }
            for url in children {
                if url.standardizedFileURL.path == tilesFolder { continue }
                if url.pathExtension.lowercased() == "app" {
                    add(url)
                } else if depth < 2, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    visit(url, depth: depth + 1)
                }
            }
        }

        func add(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath()
            let path = PopItem.standardizedPath(url.path)
            guard seen.insert(PopItem.standardizedPath(resolved.path)).inserted else { return }
            let info = Bundle(url: url)?.infoDictionary ?? [:]
            let bundleID = info["CFBundleIdentifier"] as? String
            if let id = bundleID, id.hasPrefix(AppInfo.mainBundleID) { return }
            let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
            result.append(InstalledApp(
                path: path,
                name: displayName(fm.displayName(atPath: url.path)),
                bundleID: bundleID,
                category: info["LSApplicationCategoryType"] as? String,
                addedDate: values?.addedToDirectoryDate ?? values?.creationDate))
        }

        func displayName(_ name: String) -> String {
            name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
        }

        for folder in searchFolders { visit(folder, depth: 1) }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }
}
