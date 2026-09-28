import AppKit
import OpenPopsCore

/// One cell in a popover grid: an item of the Pop, a file inside a folder being browsed,
/// or the "Open in Finder" cell at the end of a folder.
struct GridEntry {
    enum Kind {
        case item(PopItem)
        case child(URL, ItemKind)
        case openInFinder(URL)
    }

    let kind: Kind
    let name: String
    /// File path, for icons, thumbnails and Quick Look.
    let path: String?
    let isMissing: Bool

    var fileURL: URL? { path.map { URL(fileURLWithPath: $0) } }

    var popItem: PopItem? {
        if case .item(let item) = kind { return item }
        return nil
    }

    /// Whether Quick Look and "Show in Finder" make sense.
    var isPreviewable: Bool {
        guard path != nil, !isMissing else { return false }
        if case .openInFinder = kind { return false }
        return true
    }

    static func forItem(_ item: PopItem) -> GridEntry {
        GridEntry(kind: .item(item), name: displayName(for: item), path: item.isFileBased ? item.target : nil,
                  isMissing: !Launcher.existsNonisolated(item))
    }

    static func displayName(for item: PopItem) -> String {
        if let custom = item.customName?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        if item.kind == .app, FileManager.default.fileExists(atPath: item.target) {
            let name = FileManager.default.displayName(atPath: item.target)
            return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return item.defaultName
    }

    /// Contents of a folder, sorted like Finder, followed by an "Open in Finder" cell.
    static func forFolder(_ url: URL, limit: Int = 400) -> (entries: [GridEntry], readable: Bool) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .localizedNameKey]
        let finder = GridEntry(kind: .openInFinder(url), name: "Open in Finder", path: nil, isMissing: false)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else {
            return ([finder], false)
        }
        var entries: [GridEntry] = urls.map { child in
            let v = try? child.resourceValues(forKeys: Set(keys))
            let kind = ItemKind.detect(path: child.path, isDirectory: v?.isDirectory ?? false, isPackage: v?.isPackage ?? false)
            var name = child.lastPathComponent
            if kind == .app {
                let localized = v?.localizedName ?? name
                name = localized.lowercased().hasSuffix(".app") ? String(localized.dropLast(4)) : localized
            }
            return GridEntry(kind: .child(child, kind), name: name, path: child.path, isMissing: false)
        }
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if entries.count > limit { entries = Array(entries.prefix(limit)) }
        return (entries + [finder], true)
    }
}

extension Launcher {
    /// Existence check usable outside the main actor.
    nonisolated static func existsNonisolated(_ item: PopItem) -> Bool {
        guard item.isFileBased else { return true }
        return FileManager.default.fileExists(atPath: item.target)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", symbol: String? = nil, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: key)
        target = self
        if let symbol = symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}

extension NSMenu {
    func addSubmenu(_ title: String, symbol: String? = nil, build: (NSMenu) -> Void) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol = symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let sub = NSMenu(title: title)
        build(sub)
        item.submenu = sub
        addItem(item)
    }
}
