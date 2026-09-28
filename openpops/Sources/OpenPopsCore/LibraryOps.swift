import Foundation

// Lookups and edits on the library. Every edit addresses Pops and items by id, so a
// queued edit can be replayed safely on a copy that another process changed meanwhile.

extension Library {

    // MARK: Lookups

    public func pop(_ id: UUID) -> Pop? {
        pops.first { $0.id == id }
    }

    public func popIndex(_ id: UUID) -> Int? {
        pops.firstIndex { $0.id == id }
    }

    public func group(_ id: UUID) -> PopGroup? {
        groups.first { $0.id == id }
    }

    public func groupIndex(_ id: UUID) -> Int? {
        groups.firstIndex { $0.id == id }
    }

    /// Pops shown when the main OpenPops icon is clicked.
    public var carouselPops: [Pop] {
        pops.filter { !$0.hiddenFromCarousel }
    }

    /// Pops in a group, in the group's order, skipping deleted ones.
    public func pops(inGroup id: UUID) -> [Pop] {
        guard let g = group(id) else { return [] }
        return g.popIDs.compactMap { pop($0) }
    }

    /// Pops a tile shows.
    public func pops(for target: TileTarget) -> [Pop] {
        switch target {
        case .pop(let id): return pop(id).map { [$0] } ?? []
        case .group(let id): return pops(inGroup: id)
        }
    }

    public func targetExists(_ target: TileTarget) -> Bool {
        switch target {
        case .pop(let id): return pop(id) != nil
        case .group(let id): return group(id) != nil
        }
    }

    public func name(of target: TileTarget) -> String? {
        switch target {
        case .pop(let id): return pop(id)?.name
        case .group(let id): return group(id)?.name
        }
    }

    public func tile(for target: TileTarget) -> TileRecord? {
        tiles.first { $0.target == target }
    }

    /// Pops that already contain an item with this path or URL.
    public func pops(containing identityKey: String) -> [Pop] {
        pops.filter { pop in pop.items.contains { $0.identityKey == identityKey } }
    }

    public var allThemes: [Theme] { BuiltInThemes.all + customThemes }

    public func theme(_ id: String) -> Theme? {
        allThemes.first { $0.id == id }
    }

    /// Finds a Pop by id string or by name (case-insensitive).
    public func resolvePop(_ reference: String) -> Pop? {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: ref), let p = pop(id) { return p }
        return pops.first { $0.name.compare(ref, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    public func resolveGroup(_ reference: String) -> PopGroup? {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: ref), let g = group(id) { return g }
        return groups.first { $0.name.compare(ref, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    // MARK: Pops

    /// Returns `base`, or `base 2`, `base 3`… if a Pop already uses the name.
    public func uniquePopName(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "New Pop" : trimmed
        let taken = Set(pops.map { $0.name.lowercased() })
        if !taken.contains(root.lowercased()) { return root }
        var n = 2
        while taken.contains("\(root) \(n)".lowercased()) { n += 1 }
        return "\(root) \(n)"
    }

    @discardableResult
    public mutating func addPop(named name: String, theme: Theme? = nil, items: [PopItem] = [], at index: Int? = nil) -> UUID {
        var pop = Pop(name: uniquePopName(name), items: [])
        if let theme = theme {
            pop.style = theme.style
            pop.themeID = theme.id
            if let dock = theme.dockBackground {
                pop.dockIcon.matchPopBackground = false
                pop.dockIcon.background = dock
            }
        }
        var seen = Set<String>()
        pop.items = items.filter { seen.insert($0.identityKey).inserted }
        if let index = index, index >= 0, index <= pops.count {
            pops.insert(pop, at: index)
        } else {
            pops.append(pop)
        }
        return pop.id
    }

    @discardableResult
    public mutating func duplicatePop(_ id: UUID) -> UUID? {
        guard let i = popIndex(id) else { return nil }
        var copy = pops[i]
        copy.id = UUID()
        copy.name = uniquePopName(pops[i].name + " Copy")
        copy.createdAt = Date()
        copy.items = copy.items.map { item in
            var c = item
            c.id = UUID()
            return c
        }
        pops.insert(copy, at: i + 1)
        return copy.id
    }

    public mutating func deletePop(_ id: UUID) {
        pops.removeAll { $0.id == id }
        for g in groups.indices {
            groups[g].popIDs.removeAll { $0 == id }
        }
        if settings.lastActivePopID == id { settings.lastActivePopID = nil }
        settings.openPopOuts.removeAll { $0 == id }
        settings.popOutFrames[id.uuidString] = nil
    }

    public mutating func renamePop(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = popIndex(id), !trimmed.isEmpty else { return }
        pops[i].name = trimmed
    }

    public mutating func movePops(fromOffsets source: IndexSet, toOffset destination: Int) {
        pops.opMove(fromOffsets: source, toOffset: destination)
    }

    public mutating func updatePop(_ id: UUID, _ body: (inout Pop) -> Void) {
        guard let i = popIndex(id) else { return }
        body(&pops[i])
    }

    public mutating func applyTheme(_ theme: Theme, to id: UUID) {
        updatePop(id) { pop in
            pop.style = theme.style
            pop.themeID = theme.id
            if let dock = theme.dockBackground {
                pop.dockIcon.matchPopBackground = false
                pop.dockIcon.background = dock
            } else {
                pop.dockIcon.matchPopBackground = true
            }
        }
    }

    // MARK: Items

    /// Adds items, skipping any the Pop already has. Returns how many were added.
    @discardableResult
    public mutating func addItems(_ newItems: [PopItem], to popID: UUID, at index: Int? = nil) -> Int {
        guard let i = popIndex(popID) else { return 0 }
        var existing = Set(pops[i].items.map { $0.identityKey })
        var toInsert: [PopItem] = []
        for item in newItems where existing.insert(item.identityKey).inserted {
            toInsert.append(item)
        }
        guard !toInsert.isEmpty else { return 0 }
        let at = min(max(index ?? pops[i].items.count, 0), pops[i].items.count)
        pops[i].items.insert(contentsOf: toInsert, at: at)
        return toInsert.count
    }

    public mutating func removeItem(_ itemID: UUID, from popID: UUID) {
        updatePop(popID) { $0.items.removeAll { $0.id == itemID } }
    }

    /// Moves an item to a new position within its Pop's manual order.
    public mutating func moveItem(_ itemID: UUID, in popID: UUID, to newIndex: Int) {
        updatePop(popID) { pop in
            guard let from = pop.items.firstIndex(where: { $0.id == itemID }) else { return }
            let item = pop.items.remove(at: from)
            let to = min(max(newIndex, 0), pop.items.count)
            pop.items.insert(item, at: to)
        }
    }

    /// Moves an item from one Pop to another. Returns false if the target already has it.
    @discardableResult
    public mutating func moveItem(_ itemID: UUID, from sourceID: UUID, to targetID: UUID) -> Bool {
        guard sourceID != targetID,
              let s = popIndex(sourceID),
              let item = pops[s].items.first(where: { $0.id == itemID }),
              popIndex(targetID) != nil else { return false }
        guard addItems([item], to: targetID) == 1 else { return false }
        removeItem(itemID, from: sourceID)
        return true
    }

    public mutating func updateItem(_ itemID: UUID, in popID: UUID, _ body: (inout PopItem) -> Void) {
        updatePop(popID) { pop in
            guard let j = pop.items.firstIndex(where: { $0.id == itemID }) else { return }
            body(&pop.items[j])
        }
    }

    public mutating func recordLaunch(itemID: UUID, in popID: UUID, at date: Date = Date()) {
        updateItem(itemID, in: popID) { item in
            item.launchCount += 1
            item.lastLaunchedAt = date
        }
    }

    // MARK: Groups

    @discardableResult
    public mutating func addGroup(named name: String, popIDs: [UUID] = []) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = PopGroup(name: trimmed.isEmpty ? "New Group" : trimmed, popIDs: popIDs)
        groups.append(group)
        return group.id
    }

    public mutating func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
    }

    public mutating func updateGroup(_ id: UUID, _ body: (inout PopGroup) -> Void) {
        guard let i = groupIndex(id) else { return }
        body(&groups[i])
    }

    // MARK: Themes

    @discardableResult
    public mutating func saveTheme(named name: String, from popID: UUID) -> String? {
        guard let pop = pop(popID) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let theme = Theme(id: "custom-" + UUID().uuidString.lowercased(),
                          name: trimmed.isEmpty ? pop.name : trimmed,
                          style: pop.style,
                          dockBackground: pop.dockIcon.matchPopBackground ? nil : pop.dockIcon.background)
        customThemes.append(theme)
        updatePop(popID) { $0.themeID = theme.id }
        return theme.id
    }

    public mutating func deleteTheme(_ id: String) {
        customThemes.removeAll { $0.id == id }
        for i in pops.indices where pops[i].themeID == id {
            pops[i].themeID = nil
        }
    }

    // MARK: Cleanup

    /// Drops group members that no longer exist and returns tiles whose target is gone,
    /// removing them from the library.
    public mutating func removeDanglingReferences() -> [TileRecord] {
        let popIDs = Set(pops.map { $0.id })
        for g in groups.indices {
            groups[g].popIDs.removeAll { !popIDs.contains($0) }
        }
        let groupIDs = Set(groups.map { $0.id })
        func exists(_ t: TileTarget) -> Bool {
            switch t {
            case .pop(let id): return popIDs.contains(id)
            case .group(let id): return groupIDs.contains(id)
            }
        }
        let dead = tiles.filter { !exists($0.target) }
        tiles.removeAll { !exists($0.target) }
        settings.openPopOuts.removeAll { !popIDs.contains($0) }
        return dead
    }
}

extension Array {
    /// Same behavior as SwiftUI's `move(fromOffsets:toOffset:)`, available without SwiftUI.
    public mutating func opMove(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = source.filter { $0 >= 0 && $0 < count }
        guard !valid.isEmpty else { return }
        let moving = valid.map { self[$0] }
        let before = valid.filter { $0 < destination }.count
        for i in valid.sorted(by: >) { remove(at: i) }
        let insertAt = Swift.max(0, Swift.min(count, destination - before))
        insert(contentsOf: moving, at: insertAt)
    }
}
