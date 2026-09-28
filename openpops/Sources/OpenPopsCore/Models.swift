import Foundation

// MARK: - Items

public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case app, file, folder, link

    public var title: String {
        switch self {
        case .app: return "App"
        case .file: return "File"
        case .folder: return "Folder"
        case .link: return "Link"
        }
    }

    /// Picks a kind for a file system path. Packages that aren't apps (e.g. .pages, .rtfd)
    /// open like files instead of being browsed like folders.
    public static func detect(path: String, isDirectory: Bool, isPackage: Bool) -> ItemKind {
        if (path as NSString).pathExtension.lowercased() == "app" { return .app }
        if isDirectory && !isPackage { return .folder }
        return .file
    }
}

/// One thing inside a Pop: an app, a file, a folder or a web link.
public struct PopItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: ItemKind
    /// Absolute file path for apps, files and folders; the URL string for links.
    public var target: String
    /// Label that replaces the file or app name.
    public var customName: String?
    public var addedAt: Date
    public var launchCount: Int
    public var lastLaunchedAt: Date?

    public init(id: UUID = UUID(), kind: ItemKind, target: String, customName: String? = nil,
                addedAt: Date = Date(), launchCount: Int = 0, lastLaunchedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.target = target
        self.customName = customName
        self.addedAt = addedAt
        self.launchCount = launchCount
        self.lastLaunchedAt = lastLaunchedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, target, customName, addedAt, launchCount, lastLaunchedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        kind = try c.decode(ItemKind.self, forKey: .kind)
        target = try c.decode(String.self, forKey: .target)
        customName = c.value(.customName, default: nil as String?)
        addedAt = c.value(.addedAt, default: Date())
        launchCount = c.value(.launchCount, default: 0)
        lastLaunchedAt = c.value(.lastLaunchedAt, default: nil as Date?)
    }

    public var isFileBased: Bool { kind != .link }

    public var fileURL: URL? {
        isFileBased ? URL(fileURLWithPath: target) : nil
    }

    public var linkURL: URL? {
        kind == .link ? URL(string: target) : nil
    }

    /// Name derived from the target, used when there is no custom name.
    public var defaultName: String {
        switch kind {
        case .link:
            if let url = URL(string: target), let host = url.host, !host.isEmpty {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
            return target
        case .app:
            let name = (target as NSString).lastPathComponent
            return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
        case .file, .folder:
            let name = (target as NSString).lastPathComponent
            return name.isEmpty ? target : name
        }
    }

    public var name: String {
        if let custom = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        return defaultName
    }

    /// Key used to spot duplicates: the standardized path, or the URL string for links.
    public var identityKey: String {
        switch kind {
        case .link: return target
        default: return PopItem.standardizedPath(target)
        }
    }

    public static func standardizedPath(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

// MARK: - Pops and groups

public enum SortMode: String, Codable, CaseIterable, Sendable {
    case manual, name, mostUsed, recentlyAdded, kind

    public var title: String {
        switch self {
        case .manual: return "Manual"
        case .name: return "Name"
        case .mostUsed: return "Most Used"
        case .recentlyAdded: return "Recently Added"
        case .kind: return "Kind"
        }
    }
}

public enum PopLayout: String, Codable, CaseIterable, Sendable {
    case grid, list

    public var title: String {
        switch self {
        case .grid: return "Grid"
        case .list: return "List"
        }
    }
}

/// A named collection of items that opens from the Dock.
public struct Pop: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var items: [PopItem]
    public var style: PopStyle
    public var dockIcon: DockIconStyle
    public var sortMode: SortMode
    public var layout: PopLayout
    /// Hidden Pops don't appear in the main carousel but still work from their own Dock tile.
    public var hiddenFromCarousel: Bool
    /// The theme last applied, used to highlight it in the Organizer.
    public var themeID: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, items: [PopItem] = [], style: PopStyle = PopStyle(),
                dockIcon: DockIconStyle = DockIconStyle(), sortMode: SortMode = .manual,
                layout: PopLayout = .grid, hiddenFromCarousel: Bool = false, themeID: String? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.items = items
        self.style = style
        self.dockIcon = dockIcon
        self.sortMode = sortMode
        self.layout = layout
        self.hiddenFromCarousel = hiddenFromCarousel
        self.themeID = themeID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, items, style, dockIcon, sortMode, layout, hiddenFromCarousel, themeID, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        name = c.value(.name, default: "Pop")
        // Decode items one by one so a single bad entry doesn't drop the whole Pop.
        if let lossy = try? c.decode(LossyArray<PopItem>.self, forKey: .items) {
            items = lossy.elements
        } else {
            items = []
        }
        style = c.value(.style, default: PopStyle())
        dockIcon = c.value(.dockIcon, default: DockIconStyle())
        sortMode = c.value(.sortMode, default: .manual)
        layout = c.value(.layout, default: .grid)
        hiddenFromCarousel = c.value(.hiddenFromCarousel, default: false)
        themeID = c.value(.themeID, default: nil as String?)
        createdAt = c.value(.createdAt, default: Date())
    }

    public func sortedItems() -> [PopItem] {
        ItemSorter.sorted(items, by: sortMode)
    }
}

/// Several Pops behind one Dock tile.
public struct PopGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var popIDs: [UUID]
    public var dockIcon: DockIconStyle

    public init(id: UUID = UUID(), name: String, popIDs: [UUID] = [], dockIcon: DockIconStyle = DockIconStyle()) {
        self.id = id
        self.name = name
        self.popIDs = popIDs
        self.dockIcon = dockIcon
    }

    private enum CodingKeys: String, CodingKey { case id, name, popIDs, dockIcon }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        name = c.value(.name, default: "Group")
        popIDs = c.value(.popIDs, default: [])
        dockIcon = c.value(.dockIcon, default: DockIconStyle())
    }
}

// MARK: - Dock tiles

/// What an extra Dock tile opens: one Pop, or a group of Pops.
public enum TileTarget: Hashable, Sendable {
    case pop(UUID)
    case group(UUID)

    public var stringValue: String {
        switch self {
        case .pop(let id): return "pop:" + id.uuidString
        case .group(let id): return "group:" + id.uuidString
        }
    }

    public init?(string: String) {
        let parts = string.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "pop": self = .pop(id)
        case "group": self = .group(id)
        default: return nil
        }
    }

    public var id: UUID {
        switch self {
        case .pop(let id), .group(let id): return id
        }
    }
}

extension TileTarget: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let t = TileTarget(string: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid tile target \(s)")
        }
        self = t
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(stringValue)
    }
}

/// A generated tile app that sits in the Dock.
public struct TileRecord: Codable, Hashable, Sendable {
    public var target: TileTarget
    public var bundleIdentifier: String
    public var path: String
    public var buildID: String
    public var createdAt: Date

    public init(target: TileTarget, bundleIdentifier: String, path: String, buildID: String, createdAt: Date = Date()) {
        self.target = target
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.buildID = buildID
        self.createdAt = createdAt
    }
}

// MARK: - Settings

public enum Presentation: String, Codable, CaseIterable, Sendable {
    case dock, menuBar, both

    public var title: String {
        switch self {
        case .dock: return "Dock"
        case .menuBar: return "Menu Bar"
        case .both: return "Dock and Menu Bar"
        }
    }

    public var showsDockIcon: Bool { self != .menuBar }
    public var showsStatusItem: Bool { self != .dock }
}

public enum MenuBarClick: String, Codable, CaseIterable, Sendable {
    case carousel, menu

    public var title: String {
        switch self {
        case .carousel: return "Open the Pop carousel"
        case .menu: return "Show a quick menu"
        }
    }
}

public enum AnimationSpeed: String, Codable, CaseIterable, Sendable {
    case slow, medium, fast

    public var title: String { rawValue.capitalized }

    public var duration: Double {
        switch self {
        case .slow: return 0.32
        case .medium: return 0.2
        case .fast: return 0.12
        }
    }
}

public enum HoverHighlight: String, Codable, CaseIterable, Sendable {
    case none, subtle, heavy

    public var title: String { rawValue.capitalized }

    public var opacity: Double {
        switch self {
        case .none: return 0
        case .subtle: return 0.12
        case .heavy: return 0.26
        }
    }
}

public enum FolderClickAction: String, Codable, CaseIterable, Sendable {
    case browse, openInFinder

    public var title: String {
        switch self {
        case .browse: return "Browse inside the Pop"
        case .openInFinder: return "Open in Finder"
        }
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var presentation: Presentation = .dock
    public var menuBarClick: MenuBarClick = .carousel
    public var animationSpeed: AnimationSpeed = .medium
    public var hoverHighlight: HoverHighlight = .subtle
    public var pressFeedback: Bool = true
    public var showLabels: Bool = true
    public var labelLines: Int = 2
    public var iconSize: Double = 64
    /// Fixed number of columns, or 0 to pick automatically from the item count.
    public var columns: Int = 0
    public var maxColumns: Int = 6
    public var gridSpacing: Double = 8
    /// Gap between the popover's arrow and the Dock.
    public var dockGap: Double = 4
    public var lockSizeWhileSwiping: Bool = false
    public var closeAfterLaunch: Bool = true
    public var folderClick: FolderClickAction = .browse
    public var confirmOpenAll: Bool = true
    public var showPageDots: Bool = true
    public var showItemCount: Bool = false
    /// When false, tile apps stay out of Cmd-Tab and show no running dot.
    public var tilesInAppSwitcher: Bool = false
    /// Restart the Dock after tile icons change so pinned tiles show the new icon.
    public var autoRefreshDock: Bool = true
    public var lastActivePopID: UUID? = nil
    public var hasCompletedOnboarding: Bool = false
    /// Saved Pop Out window frames keyed by Pop id, as "x y w h".
    public var popOutFrames: [String: String] = [:]
    /// Pops whose Pop Out windows were open at quit, reopened at launch.
    public var openPopOuts: [UUID] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case presentation, menuBarClick, animationSpeed, hoverHighlight, pressFeedback, showLabels,
             labelLines, iconSize, columns, maxColumns, gridSpacing, dockGap, lockSizeWhileSwiping,
             closeAfterLaunch, folderClick, confirmOpenAll, showPageDots, showItemCount,
             tilesInAppSwitcher, autoRefreshDock, lastActivePopID, hasCompletedOnboarding,
             popOutFrames, openPopOuts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        presentation = c.value(.presentation, default: d.presentation)
        menuBarClick = c.value(.menuBarClick, default: d.menuBarClick)
        animationSpeed = c.value(.animationSpeed, default: d.animationSpeed)
        hoverHighlight = c.value(.hoverHighlight, default: d.hoverHighlight)
        pressFeedback = c.value(.pressFeedback, default: d.pressFeedback)
        showLabels = c.value(.showLabels, default: d.showLabels)
        labelLines = c.value(.labelLines, default: d.labelLines)
        iconSize = c.value(.iconSize, default: d.iconSize)
        columns = c.value(.columns, default: d.columns)
        maxColumns = c.value(.maxColumns, default: d.maxColumns)
        gridSpacing = c.value(.gridSpacing, default: d.gridSpacing)
        dockGap = c.value(.dockGap, default: d.dockGap)
        lockSizeWhileSwiping = c.value(.lockSizeWhileSwiping, default: d.lockSizeWhileSwiping)
        closeAfterLaunch = c.value(.closeAfterLaunch, default: d.closeAfterLaunch)
        folderClick = c.value(.folderClick, default: d.folderClick)
        confirmOpenAll = c.value(.confirmOpenAll, default: d.confirmOpenAll)
        showPageDots = c.value(.showPageDots, default: d.showPageDots)
        showItemCount = c.value(.showItemCount, default: d.showItemCount)
        tilesInAppSwitcher = c.value(.tilesInAppSwitcher, default: d.tilesInAppSwitcher)
        autoRefreshDock = c.value(.autoRefreshDock, default: d.autoRefreshDock)
        lastActivePopID = c.value(.lastActivePopID, default: d.lastActivePopID)
        hasCompletedOnboarding = c.value(.hasCompletedOnboarding, default: d.hasCompletedOnboarding)
        popOutFrames = c.value(.popOutFrames, default: d.popOutFrames)
        openPopOuts = c.value(.openPopOuts, default: d.openPopOuts)
    }

    /// Grid parameters for popovers built from these settings.
    public func gridSpec(labelFontSize: Double, layout: PopLayout) -> GridSpec {
        GridSpec(iconSize: iconSize, showLabels: showLabels, labelLines: labelLines,
                 labelFontSize: labelFontSize, spacing: gridSpacing, layout: layout)
    }
}

// MARK: - Library

/// Everything OpenPops stores: Pops, groups, custom themes, generated tiles and settings.
public struct Library: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int = Library.currentVersion
    public var pops: [Pop] = []
    public var groups: [PopGroup] = []
    public var customThemes: [Theme] = []
    public var tiles: [TileRecord] = []
    public var settings: AppSettings = AppSettings()

    public init() {}

    private enum CodingKeys: String, CodingKey { case version, pops, groups, customThemes, tiles, settings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, default: Library.currentVersion)
        pops = (try? c.decode(LossyArray<Pop>.self, forKey: .pops))?.elements ?? []
        groups = (try? c.decode(LossyArray<PopGroup>.self, forKey: .groups))?.elements ?? []
        customThemes = (try? c.decode(LossyArray<Theme>.self, forKey: .customThemes))?.elements ?? []
        tiles = (try? c.decode(LossyArray<TileRecord>.self, forKey: .tiles))?.elements ?? []
        settings = c.value(.settings, default: AppSettings())
    }
}

/// Decodes an array while skipping elements that fail to decode.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    /// Accepts any JSON value so the container moves past a bad element.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !c.isAtEnd {
            if let e = try? c.decode(Element.self) {
                out.append(e)
            } else {
                _ = try? c.decode(Skip.self)
            }
        }
        elements = out
    }
}
