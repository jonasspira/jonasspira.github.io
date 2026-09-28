import AppKit
import CoreServices
import OpenPopsCore

enum TileError: LocalizedError {
    case notMainApp
    case missingTarget
    case copyFailed(String)
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notMainApp: return "Dock tiles can only be created by the main OpenPops app."
        case .missingTarget: return "That Pop or group no longer exists."
        case .copyFailed(let why): return "Couldn't create the tile app: \(why)"
        case .signingFailed(let why): return "Couldn't sign the tile app: \(why)"
        }
    }
}

/// Creates and maintains the small apps that give a Pop (or a group of Pops) its own Dock
/// icon. Each tile is a copy of this executable with its own bundle identifier and an
/// Info.plist key naming what it opens; it's re-signed ad hoc after the copy. The tile's
/// Dock icon is set as a custom Finder icon, so updating it doesn't touch the signature.
@MainActor
final class TileManager {
    private let model: AppModel
    private var iconRefreshTimer: Timer?
    private var dockNeedsRestart = false

    init(model: AppModel) {
        self.model = model
    }

    static var tilesFolder: URL { AppInfo.tilesFolder }

    // MARK: Creating

    /// Creates (or rebuilds) the tile app for a Pop or group and records it in the library.
    @discardableResult
    func ensureTile(for target: TileTarget) throws -> TileRecord {
        guard RunMode.current.isMain else { throw TileError.notMainApp }
        guard let name = model.library.name(of: target) else { throw TileError.missingTarget }
        let existing = model.library.tile(for: target)
        let bundleID = existing?.bundleIdentifier ?? Self.bundleIdentifier(for: target)
        let url = existing.map { URL(fileURLWithPath: $0.path) } ?? uniqueURL(for: name)
        try build(at: url, bundleID: bundleID, name: name, target: target)
        let record = TileRecord(target: target, bundleIdentifier: bundleID, path: url.path, buildID: AppInfo.buildID,
                                createdAt: existing?.createdAt ?? Date())
        model.update(immediately: true) { lib in
            lib.tiles.removeAll { $0.target == target }
            lib.tiles.append(record)
        }
        refreshIcon(for: record)
        // Redraw once the item icons have settled (the first draw can have placeholders).
        Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIcon(for: record) }
        }
        DebugLog.log("tile ready: \(url.path)")
        return record
    }

    /// Creates the tile and pins it to the Dock (restarting the Dock).
    func addToDock(_ target: TileTarget) throws {
        let record = try ensureTile(for: target)
        let name = model.library.name(of: target) ?? "Pop"
        DockPrefs.pin(path: record.path, label: name, bundleID: record.bundleIdentifier)
        DockPrefs.restartDock()
        dockNeedsRestart = false
    }

    func removeFromDock(_ target: TileTarget, deleteApp: Bool = true) {
        guard let record = model.library.tile(for: target) else { return }
        terminateRunningTile(record.bundleIdentifier)
        let wasPinned = DockPrefs.unpin(path: record.path)
        if deleteApp {
            try? FileManager.default.removeItem(atPath: record.path)
            model.update(immediately: true) { $0.tiles.removeAll { $0.target == target } }
        }
        if wasPinned { DockPrefs.restartDock() }
    }

    func isPinned(_ target: TileTarget) -> Bool {
        guard let record = model.library.tile(for: target) else { return false }
        return DockPrefs.isPinned(path: record.path)
    }

    func reveal(_ target: TileTarget) {
        guard let record = model.library.tile(for: target) else { return }
        Launcher.reveal([URL(fileURLWithPath: record.path)])
    }

    static func bundleIdentifier(for target: TileTarget) -> String {
        let kind: String
        switch target {
        case .pop: kind = "pop"
        case .group: kind = "group"
        }
        let short = target.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        return AppInfo.tileBundlePrefix + kind + "-" + short
    }

    /// A file name for the tile that isn't taken by another tile.
    private func uniqueURL(for name: String) -> URL {
        var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base.hasPrefix(".") { base = "Pop" }
        base = String(base.prefix(60))
        let folder = Self.tilesFolder
        var candidate = folder.appendingPathComponent(base + ".app")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n).app")
            n += 1
        }
        return candidate
    }

    private func build(at url: URL, bundleID: String, name: String, target: TileTarget) throws {
        let fm = FileManager.default
        guard let executable = Bundle.main.executableURL else { throw TileError.copyFailed("no executable") }
        terminateRunningTile(bundleID)
        do {
            try fm.createDirectory(at: Self.tilesFolder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            let contents = url.appendingPathComponent("Contents")
            let macOS = contents.appendingPathComponent("MacOS")
            let resources = contents.appendingPathComponent("Resources")
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            try fm.copyItem(at: executable, to: macOS.appendingPathComponent("OpenPops"))
            if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
                try fm.copyItem(at: icon, to: resources.appendingPathComponent("AppIcon.icns"))
            }
            let plist = infoPlist(bundleID: bundleID, name: name, target: target)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        } catch {
            throw TileError.copyFailed(error.localizedDescription)
        }
        try sign(url)
        LSRegisterURL(url as CFURL, true)
    }

    private func infoPlist(bundleID: String, name: String, target: TileTarget) -> [String: Any] {
        let main = Bundle.main.infoDictionary ?? [:]
        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": "OpenPops",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": main["CFBundleShortVersionString"] ?? "1.0",
            "CFBundleVersion": main["CFBundleVersion"] ?? "1",
            "LSMinimumSystemVersion": main["LSMinimumSystemVersion"] ?? "14.0",
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            AppInfo.tileTargetKey: target.stringValue,
            AppInfo.mainAppPathKey: Bundle.main.bundlePath,
            AppInfo.buildIDKey: AppInfo.buildID,
        ]
        for key in ["CFBundleDocumentTypes", "NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription",
                    "NSDownloadsFolderUsageDescription", "NSRemovableVolumesUsageDescription",
                    "NSNetworkVolumesUsageDescription"] {
            if let v = main[key] { plist[key] = v }
        }
        return plist
    }

    private func sign(_ url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", "--timestamp=none", url.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do {
            try p.run()
        } catch {
            throw TileError.signingFailed(error.localizedDescription)
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "codesign failed"
            throw TileError.signingFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func terminateRunningTile(_ bundleID: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline && running.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    // MARK: Icons

    func icon(for target: TileTarget) -> NSImage? {
        switch target {
        case .pop(let id):
            return model.pop(id).map { DockIconRenderer.image(for: $0) }
        case .group(let id):
            guard let group = model.library.group(id) else { return nil }
            return DockIconRenderer.image(forGroup: group, pops: model.library.pops(inGroup: id))
        }
    }

    /// Sets the tile's Finder icon (used by the Dock when the tile isn't running).
    func refreshIcon(for record: TileRecord) {
        guard FileManager.default.fileExists(atPath: record.path), let image = icon(for: record.target) else { return }
        NSWorkspace.shared.setIcon(image, forFile: record.path, options: [])
        NSWorkspace.shared.noteFileSystemChanged(record.path)
        if DockPrefs.isPinned(path: record.path) { dockNeedsRestart = true }
    }

    /// Refreshes all tile icons a moment after the last change.
    func scheduleIconRefresh() {
        iconRefreshTimer?.invalidate()
        iconRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAllIcons() }
        }
    }

    private var lastIconSignature: [String: Int] = [:]

    func refreshAllIcons() {
        for record in model.library.tiles {
            // Only redraw tiles whose Pop or group actually changed.
            let signature = iconSignature(for: record.target)
            if lastIconSignature[record.path] == signature { continue }
            lastIconSignature[record.path] = signature
            refreshIcon(for: record)
        }
    }

    private func iconSignature(for target: TileTarget) -> Int {
        var hasher = Hasher()
        for pop in model.library.pops(for: target) {
            hasher.combine(pop.dockIcon)
            hasher.combine(pop.style.background)
            hasher.combine(pop.name)
            for item in pop.sortedItems().prefix(16) { hasher.combine(item.target) }
        }
        if case .group(let id) = target, let g = model.library.group(id) {
            hasher.combine(g.dockIcon)
            hasher.combine(g.name)
        }
        return hasher.finalize()
    }

    /// Restarts the Dock if a pinned tile's icon changed (called when the Organizer closes).
    func restartDockIfIconsChanged() {
        guard dockNeedsRestart, model.library.settings.autoRefreshDock else { return }
        dockNeedsRestart = false
        DockPrefs.restartDock()
    }

    var hasPendingDockRefresh: Bool { dockNeedsRestart }

    func restartDockNow() {
        dockNeedsRestart = false
        DockPrefs.restartDock()
    }

    // MARK: Maintenance

    /// Rebuilds tiles made by an older build, renames tiles whose Pop was renamed, and
    /// removes tiles whose Pop or group was deleted.
    func maintainTiles() {
        guard RunMode.current.isMain else { return }
        var dead: [TileRecord] = []
        model.update(immediately: true) { dead = $0.removeDanglingReferences() }
        var dockChanged = false
        for record in dead {
            terminateRunningTile(record.bundleIdentifier)
            if DockPrefs.unpin(path: record.path) { dockChanged = true }
            try? FileManager.default.removeItem(atPath: record.path)
        }
        for record in model.library.tiles {
            guard let name = model.library.name(of: record.target) else { continue }
            let exists = FileManager.default.fileExists(atPath: record.path)
            let currentName = (URL(fileURLWithPath: record.path).deletingPathExtension().lastPathComponent)
            let renamed = !currentName.hasPrefix(sanitized(name))
            guard !exists || record.buildID != AppInfo.buildID || renamed else { continue }
            let wasPinned = DockPrefs.isPinned(path: record.path)
            if renamed && exists {
                // A new name means a new file; keep the Dock pointing at it.
                terminateRunningTile(record.bundleIdentifier)
                try? FileManager.default.removeItem(atPath: record.path)
                if wasPinned { DockPrefs.unpin(path: record.path) }
                model.update(immediately: true) { $0.tiles.removeAll { $0.target == record.target } }
            }
            if let fresh = try? ensureTile(for: record.target) {
                if renamed && wasPinned {
                    DockPrefs.pin(path: fresh.path, label: name, bundleID: fresh.bundleIdentifier)
                    dockChanged = true
                }
            }
        }
        if dockChanged { DockPrefs.restartDock() }
        refreshAllIcons()
    }

    private func sanitized(_ name: String) -> String {
        let s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(s.prefix(60))
    }
}
