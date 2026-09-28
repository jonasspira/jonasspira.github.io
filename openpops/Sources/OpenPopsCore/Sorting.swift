import Foundation

public enum ItemSorter {
    /// Returns items in display order. `name` lets the app supply localized display names.
    public static func sorted(_ items: [PopItem], by mode: SortMode,
                              name: (PopItem) -> String = { $0.name }) -> [PopItem] {
        let indexed = Array(items.enumerated())
        func byName(_ a: (offset: Int, element: PopItem), _ b: (offset: Int, element: PopItem)) -> Bool {
            let r = name(a.element).compare(name(b.element), options: [.caseInsensitive, .numeric, .diacriticInsensitive])
            if r != .orderedSame { return r == .orderedAscending }
            return a.offset < b.offset
        }
        let result: [(offset: Int, element: PopItem)]
        switch mode {
        case .manual:
            return items
        case .name:
            result = indexed.sorted(by: byName)
        case .mostUsed:
            result = indexed.sorted { a, b in
                if a.element.launchCount != b.element.launchCount {
                    return a.element.launchCount > b.element.launchCount
                }
                let da = a.element.lastLaunchedAt ?? .distantPast
                let db = b.element.lastLaunchedAt ?? .distantPast
                if da != db { return da > db }
                return a.offset < b.offset
            }
        case .recentlyAdded:
            result = indexed.sorted { a, b in
                if a.element.addedAt != b.element.addedAt { return a.element.addedAt > b.element.addedAt }
                return a.offset < b.offset
            }
        case .kind:
            func rank(_ k: ItemKind) -> Int {
                switch k {
                case .app: return 0
                case .folder: return 1
                case .file: return 2
                case .link: return 3
                }
            }
            result = indexed.sorted { a, b in
                let ra = rank(a.element.kind), rb = rank(b.element.kind)
                if ra != rb { return ra < rb }
                return byName(a, b)
            }
        }
        return result.map { $0.element }
    }
}
