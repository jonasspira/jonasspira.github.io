import AppKit
import Combine
import OpenPopsCore

/// Shared state for the whole app. Edits apply to the in-memory library right away (so the
/// UI updates) and are written to disk shortly after. Each edit is kept as a closure and
/// replayed on the latest copy from disk, so edits made at the same time by the main app
/// and by Dock tile apps all survive.
@MainActor
final class AppModel: ObservableObject {
    static let changeNotification = Notification.Name("com.spiiira.openpops.libraryChanged")

    let store: LibraryStore
    @Published private(set) var library: Library
    /// Set when library.json couldn't be read or written.
    @Published private(set) var storageError: String?

    private var pending: [(inout Library) -> Void] = []
    private var flushTimer: Timer?
    private let processTag = UUID().uuidString

    init(store: LibraryStore) {
        self.store = store
        self.library = store.library
        self.storageError = store.lastError
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(externalChange(_:)), name: AppModel.changeNotification,
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    /// Applies an edit now and saves it within a moment.
    func update(immediately: Bool = false, _ body: @escaping (inout Library) -> Void) {
        var copy = library
        body(&copy)
        library = copy
        pending.append(body)
        if immediately {
            flush()
        } else {
            flushTimer?.invalidate()
            flushTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
    }

    /// Writes queued edits to disk and tells the other OpenPops processes.
    func flush() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard !pending.isEmpty else { return }
        let ops = pending
        pending = []
        store.update { lib in
            for op in ops { op(&lib) }
        }
        library = store.library
        storageError = store.lastError
        DistributedNotificationCenter.default().postNotificationName(
            AppModel.changeNotification, object: processTag, userInfo: nil, deliverImmediately: true)
        DebugLog.log("saved library (\(ops.count) edits)")
    }

    /// Picks up changes written by another process.
    func reloadFromDisk() {
        if !pending.isEmpty {
            flush()
            return
        }
        if store.reload() {
            library = store.library
            storageError = store.lastError
        }
    }

    @objc private func externalChange(_ note: Notification) {
        if (note.object as? String) == processTag { return }
        reloadFromDisk()
    }

    // MARK: Convenience

    func pop(_ id: UUID) -> Pop? { library.pop(id) }

    var carouselPopIDs: [UUID] { library.carouselPops.map(\.id) }

    func popIDs(for target: TileTarget) -> [UUID] {
        library.pops(for: target).map(\.id)
    }

    /// Pops a mode shows: the carousel for the main app, or the tile's Pop or group.
    func popIDs(for mode: RunMode) -> [UUID] {
        switch mode {
        case .main: return carouselPopIDs
        case .tile(let target): return popIDs(for: target)
        }
    }

    func setLastActivePop(_ id: UUID) {
        guard library.settings.lastActivePopID != id else { return }
        update { $0.settings.lastActivePopID = id }
    }

    func recordLaunch(itemID: UUID, popID: UUID) {
        update { $0.recordLaunch(itemID: itemID, in: popID) }
    }

    /// Reorders a Pop to match the order shown on screen and switches it to manual sorting.
    func reorder(popID: UUID, displayedIDs: [UUID]) {
        update { lib in
            lib.updatePop(popID) { pop in
                var byID = Dictionary(uniqueKeysWithValues: pop.items.map { ($0.id, $0) })
                var result: [PopItem] = []
                for id in displayedIDs {
                    if let item = byID.removeValue(forKey: id) { result.append(item) }
                }
                // Anything not on screen (added meanwhile) keeps its place at the end.
                result.append(contentsOf: pop.items.filter { byID[$0.id] != nil })
                pop.items = result
                pop.sortMode = .manual
            }
        }
    }

    /// Adds files, folders, apps or web links to a Pop. Returns how many were new.
    @discardableResult
    func add(urls: [URL], titles: [URL: String] = [:], to popID: UUID, at index: Int? = nil) -> Int {
        let items = urls.compactMap { url -> PopItem? in
            ItemFactory.item(for: url, title: titles[url])
        }
        guard !items.isEmpty else { return 0 }
        var added = 0
        update { lib in added = lib.addItems(items, to: popID, at: index) }
        return added
    }
}

/// Turns URLs from drops, open panels and commands into Pop items.
enum ItemFactory {
    static func item(for url: URL, title: String? = nil) -> PopItem? {
        if url.isFileURL {
            let path = url.standardizedFileURL.path
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
            let kind = ItemKind.detect(path: path, isDirectory: values?.isDirectory ?? isDir.boolValue,
                                       isPackage: values?.isPackage ?? false)
            return PopItem(kind: kind, target: PopItem.standardizedPath(path))
        }
        guard let scheme = url.scheme, !scheme.isEmpty else { return nil }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PopItem(kind: .link, target: url.absoluteString, customName: (name?.isEmpty ?? true) ? nil : name)
    }

    static func probe(_ path: String) -> (exists: Bool, directory: Bool, package: Bool) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return (false, false, false) }
        let url = URL(fileURLWithPath: path)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        return (true, isDir.boolValue, isPackage)
    }
}
