import XCTest
@testable import OpenPopsCore

final class LibraryOpsTests: XCTestCase {

    private func item(_ path: String, _ kind: ItemKind = .app) -> PopItem {
        PopItem(kind: kind, target: path)
    }

    func testUniqueNames() {
        var lib = Library()
        lib.addPop(named: "Work")
        XCTAssertEqual(lib.uniquePopName("Work"), "Work 2")
        lib.addPop(named: "work")
        XCTAssertEqual(lib.pops.map(\.name), ["Work", "work 2"])
        XCTAssertEqual(lib.uniquePopName("  "), "New Pop")
    }

    func testAddItemsSkipsDuplicates() {
        var lib = Library()
        let id = lib.addPop(named: "A")
        XCTAssertEqual(lib.addItems([item("/Applications/Safari.app"), item("/Applications/Safari.app/")], to: id), 1)
        XCTAssertEqual(lib.addItems([item("/Applications/Safari.app"), item("/Applications/Mail.app")], to: id), 1)
        XCTAssertEqual(lib.pop(id)?.items.map(\.name), ["Safari", "Mail"])
        XCTAssertEqual(lib.addItems([item("/Applications/Notes.app")], to: id, at: 0), 1)
        XCTAssertEqual(lib.pop(id)?.items.map(\.name), ["Notes", "Safari", "Mail"])
        XCTAssertEqual(lib.addItems([item("/x.app")], to: UUID()), 0)
    }

    func testMoveAndRemoveItems() {
        var lib = Library()
        let id = lib.addPop(named: "A")
        let items = ["/a.app", "/b.app", "/c.app", "/d.app"].map { item($0) }
        lib.addItems(items, to: id)
        lib.moveItem(items[0].id, in: id, to: 3)
        XCTAssertEqual(lib.pop(id)?.items.map(\.name), ["b", "c", "d", "a"])
        lib.moveItem(items[3].id, in: id, to: 0)
        XCTAssertEqual(lib.pop(id)?.items.map(\.name), ["d", "b", "c", "a"])
        lib.moveItem(items[1].id, in: id, to: 99)
        XCTAssertEqual(lib.pop(id)?.items.map(\.name), ["d", "c", "a", "b"])
        lib.removeItem(items[2].id, from: id)
        XCTAssertEqual(lib.pop(id)?.items.map(\.name), ["d", "a", "b"])
    }

    func testMoveItemBetweenPops() {
        var lib = Library()
        let a = lib.addPop(named: "A"), b = lib.addPop(named: "B")
        let safari = item("/Applications/Safari.app")
        lib.addItems([safari], to: a)
        XCTAssertTrue(lib.moveItem(safari.id, from: a, to: b))
        XCTAssertEqual(lib.pop(a)?.items.count, 0)
        XCTAssertEqual(lib.pop(b)?.items.map(\.name), ["Safari"])
        // Moving into a Pop that already has it does nothing.
        let copy = item("/Applications/Safari.app")
        lib.addItems([copy], to: a)
        XCTAssertFalse(lib.moveItem(copy.id, from: a, to: b))
        XCTAssertEqual(lib.pop(a)?.items.count, 1)
    }

    func testDeletePopCleansUpReferences() {
        var lib = Library()
        let a = lib.addPop(named: "A"), b = lib.addPop(named: "B")
        let g = lib.addGroup(named: "G", popIDs: [a, b])
        lib.settings.lastActivePopID = a
        lib.settings.openPopOuts = [a]
        lib.tiles.append(TileRecord(target: .pop(a), bundleIdentifier: "x", path: "/tmp/A.app", buildID: "1"))
        lib.tiles.append(TileRecord(target: .group(g), bundleIdentifier: "y", path: "/tmp/G.app", buildID: "1"))
        lib.deletePop(a)
        XCTAssertEqual(lib.group(g)?.popIDs, [b])
        XCTAssertNil(lib.settings.lastActivePopID)
        XCTAssertEqual(lib.settings.openPopOuts, [])
        let dead = lib.removeDanglingReferences()
        XCTAssertEqual(dead.map(\.path), ["/tmp/A.app"])
        XCTAssertEqual(lib.tiles.map(\.path), ["/tmp/G.app"])
    }

    func testMovePopsMatchesSwiftUISemantics() {
        var lib = Library()
        for n in ["A", "B", "C", "D"] { lib.addPop(named: n) }
        lib.movePops(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        XCTAssertEqual(lib.pops.map(\.name), ["B", "C", "D", "A"])
        lib.movePops(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(lib.pops.map(\.name), ["A", "B", "C", "D"])
        lib.movePops(fromOffsets: IndexSet([0, 2]), toOffset: 4)
        XCTAssertEqual(lib.pops.map(\.name), ["B", "D", "A", "C"])
        lib.movePops(fromOffsets: IndexSet(integer: 1), toOffset: 1)
        XCTAssertEqual(lib.pops.map(\.name), ["B", "D", "A", "C"])
    }

    func testRecordLaunch() {
        var lib = Library()
        let id = lib.addPop(named: "A")
        let safari = item("/Applications/Safari.app")
        lib.addItems([safari], to: id)
        let date = Date(timeIntervalSince1970: 1_000_000)
        lib.recordLaunch(itemID: safari.id, in: id, at: date)
        lib.recordLaunch(itemID: safari.id, in: id, at: date)
        XCTAssertEqual(lib.pop(id)?.items.first?.launchCount, 2)
        XCTAssertEqual(lib.pop(id)?.items.first?.lastLaunchedAt, date)
    }

    func testThemes() {
        var lib = Library()
        let id = lib.addPop(named: "A")
        lib.applyTheme(BuiltInThemes.theme("matrix")!, to: id)
        XCTAssertEqual(lib.pop(id)?.themeID, "matrix")
        lib.updatePop(id) { $0.style.glass = 0.5 }
        let themeID = lib.saveTheme(named: "Mine", from: id)!
        XCTAssertEqual(lib.customThemes.count, 1)
        XCTAssertEqual(lib.theme(themeID)?.style.glass, 0.5)
        XCTAssertEqual(lib.pop(id)?.themeID, themeID)
        lib.deleteTheme(themeID)
        XCTAssertNil(lib.pop(id)?.themeID)
        XCTAssertEqual(lib.allThemes.count, BuiltInThemes.all.count)
    }

    func testResolveAndTargets() {
        var lib = Library()
        let a = lib.addPop(named: "Café Work")
        let hidden = lib.addPop(named: "Hidden")
        lib.updatePop(hidden) { $0.hiddenFromCarousel = true }
        let g = lib.addGroup(named: "Both", popIDs: [hidden, a, UUID()])
        XCTAssertEqual(lib.resolvePop("cafe work")?.id, a)
        XCTAssertEqual(lib.resolvePop(a.uuidString)?.id, a)
        XCTAssertNil(lib.resolvePop("nope"))
        XCTAssertEqual(lib.carouselPops.map(\.id), [a])
        XCTAssertEqual(lib.pops(for: .group(g)).map(\.id), [hidden, a])
        XCTAssertEqual(lib.pops(for: .pop(hidden)).map(\.id), [hidden])
        XCTAssertEqual(lib.resolveGroup("both")?.id, g)
    }

    func testReplayingEditsWithFixedIDsIsIdempotent() {
        var lib = Library()
        let popID = UUID(), groupID = UUID(), copyID = UUID()
        for _ in 0..<2 {
            lib.addPop(named: "Work", id: popID)
            lib.addGroup(named: "G", popIDs: [popID], id: groupID)
            lib.duplicatePop(popID, as: copyID)
            lib.saveTheme(named: "Mine", from: popID, id: "custom-fixed")
        }
        XCTAssertEqual(lib.pops.map(\.id), [popID, copyID])
        XCTAssertEqual(lib.groups.map(\.id), [groupID])
        XCTAssertEqual(lib.customThemes.map(\.id), ["custom-fixed"])
    }

    func testDuplicatePop() {
        var lib = Library()
        let a = lib.addPop(named: "A")
        lib.addItems([item("/a.app")], to: a)
        let copy = lib.duplicatePop(a)!
        XCTAssertEqual(lib.pops.map(\.name), ["A", "A Copy"])
        XCTAssertNotEqual(lib.pop(copy)?.items.first?.id, lib.pop(a)?.items.first?.id)
        XCTAssertEqual(lib.pop(copy)?.items.first?.target, "/a.app")
    }
}
