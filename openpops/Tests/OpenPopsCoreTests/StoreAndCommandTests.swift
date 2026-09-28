import XCTest
@testable import OpenPopsCore

final class StoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("openpops-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testFirstRunAndPersistence() {
        let store = LibraryStore(directory: dir)
        XCTAssertFalse(store.fileExisted)
        XCTAssertTrue(store.library.pops.isEmpty)
        store.update { $0.addPop(named: "Work") }

        let again = LibraryStore(directory: dir)
        XCTAssertTrue(again.fileExisted)
        XCTAssertEqual(again.library.pops.map(\.name), ["Work"])
    }

    func testUpdateStartsFromLatestDiskCopy() {
        // Two processes (the app and a Dock tile) each hold a store for the same file.
        let app = LibraryStore(directory: dir)
        let tile = LibraryStore(directory: dir)
        app.update { $0.addPop(named: "A") }
        tile.update { $0.addPop(named: "B") }
        app.update { $0.addPop(named: "C") }
        XCTAssertEqual(app.library.pops.map(\.name), ["A", "B", "C"])
        XCTAssertTrue(tile.reload())
        XCTAssertEqual(tile.library.pops.map(\.name), ["A", "B", "C"])
        XCTAssertFalse(tile.reload(), "no change since the last read")
    }

    func testUnreadableFileIsBackedUp() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("library.json"))
        let store = LibraryStore(directory: dir)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.library.pops.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("library.unreadable-") })
    }

    func testLaunchBackup() throws {
        let store = LibraryStore(directory: dir)
        store.update { $0.addPop(named: "Keep") }
        store.makeLaunchBackup()
        let data = try Data(contentsOf: dir.appendingPathComponent("library.backup.json"))
        XCTAssertEqual(try LibraryStore.decodeLibrary(from: data).pops.map(\.name), ["Keep"])
    }
}

final class SortingTests: XCTestCase {
    func testModes() {
        let t0 = Date(timeIntervalSince1970: 0)
        let items = [
            PopItem(kind: .link, target: "https://zeta.com", addedAt: t0.addingTimeInterval(30), launchCount: 1),
            PopItem(kind: .app, target: "/b.app", addedAt: t0.addingTimeInterval(10), launchCount: 5),
            PopItem(kind: .file, target: "/a10.txt", addedAt: t0.addingTimeInterval(20), launchCount: 5,
                    lastLaunchedAt: t0.addingTimeInterval(100)),
            PopItem(kind: .folder, target: "/A2", addedAt: t0.addingTimeInterval(40)),
        ]
        XCTAssertEqual(ItemSorter.sorted(items, by: .manual).map(\.name), ["zeta.com", "b", "a10.txt", "A2"])
        XCTAssertEqual(ItemSorter.sorted(items, by: .name).map(\.name), ["A2", "a10.txt", "b", "zeta.com"])
        XCTAssertEqual(ItemSorter.sorted(items, by: .mostUsed).map(\.name), ["a10.txt", "b", "zeta.com", "A2"])
        XCTAssertEqual(ItemSorter.sorted(items, by: .recentlyAdded).map(\.name), ["A2", "zeta.com", "a10.txt", "b"])
        XCTAssertEqual(ItemSorter.sorted(items, by: .kind).map(\.name), ["b", "A2", "a10.txt", "zeta.com"])
    }
}

final class URLCommandTests: XCTestCase {
    private func cmd(_ s: String) -> URLCommand? { URLCommand(url: URL(string: s)!) }

    func testParsing() {
        XCTAssertEqual(cmd("openpops://show"), .show(pop: nil))
        XCTAssertEqual(cmd("openpops://show?pop=Work"), .show(pop: "Work"))
        XCTAssertEqual(cmd("openpops:show?pop=Work"), .show(pop: "Work"))
        XCTAssertEqual(cmd("openpops://show?group=Projects"), .showGroup("Projects"))
        XCTAssertEqual(cmd("openpops://organizer"), .organizer(pop: nil))
        XCTAssertEqual(cmd("openpops://add?pop=Work&url=https%3A%2F%2Fexample.com&name=Ex"),
                       .add(pop: "Work", target: "https://example.com", name: "Ex"))
        XCTAssertEqual(cmd("openpops://popout?pop=Work"), .popOut(pop: "Work"))
        XCTAssertEqual(cmd("openpops://openall?pop=Work"), .openAll(pop: "Work"))
        XCTAssertEqual(cmd("openpops://tile?pop=Work&pin=0"), .makeTile(pop: "Work", group: nil, pin: false))
        XCTAssertEqual(cmd("openpops://tile?group=G"), .makeTile(pop: nil, group: "G", pin: true))
        XCTAssertNil(cmd("openpops://popout"))
        XCTAssertNil(cmd("openpops://tile"))
        XCTAssertNil(cmd("openpops://unknown"))
        XCTAssertNil(cmd("https://show?pop=Work"))
    }

    func testItemForTarget() {
        let probe: (String) -> (exists: Bool, directory: Bool, package: Bool) = { path in
            switch path {
            case "/Applications/Safari.app": return (true, true, true)
            case "/Users/me/Docs": return (true, true, false)
            default: return (false, false, false)
            }
        }
        XCTAssertEqual(URLCommand.item(forTarget: "https://example.com", name: nil, isDirectory: probe)?.kind, .link)
        XCTAssertEqual(URLCommand.item(forTarget: "/Applications/Safari.app", name: nil, isDirectory: probe)?.kind, .app)
        XCTAssertEqual(URLCommand.item(forTarget: "file:///Users/me/Docs", name: "D", isDirectory: probe)?.kind, .folder)
        XCTAssertNil(URLCommand.item(forTarget: "/missing", name: nil, isDirectory: probe))
        XCTAssertNil(URLCommand.item(forTarget: "not a url", name: nil, isDirectory: probe))
    }
}

final class SuggestionTests: XCTestCase {
    func testCategoryAndVendorRanking() {
        let installed = [
            InstalledApp(path: "/Applications/Xcode.app", name: "Xcode", bundleID: "com.apple.dt.Xcode",
                         category: "public.app-category.developer-tools"),
            InstalledApp(path: "/Applications/Tower.app", name: "Tower", bundleID: "com.fournova.Tower3",
                         category: "public.app-category.developer-tools"),
            InstalledApp(path: "/Applications/Photoshop.app", name: "Photoshop", bundleID: "com.adobe.Photoshop",
                         category: "public.app-category.graphics-design"),
            InstalledApp(path: "/Applications/Illustrator.app", name: "Illustrator", bundleID: "com.adobe.illustrator",
                         category: "public.app-category.graphics-design"),
            InstalledApp(path: "/Applications/Chess.app", name: "Chess", bundleID: "com.apple.Chess",
                         category: "public.app-category.board-games"),
        ]
        let dev = Pop(name: "Code", items: [PopItem(kind: .app, target: "/Applications/Xcode.app")])
        XCTAssertEqual(Suggestions.suggest(for: dev, installed: installed).map(\.name), ["Tower"])

        let design = Pop(name: "Stuff", items: [PopItem(kind: .app, target: "/Applications/Photoshop.app")])
        XCTAssertEqual(Suggestions.suggest(for: design, installed: installed).map(\.name), ["Illustrator"])

        let games = Pop(name: "Games", items: [])
        XCTAssertEqual(Suggestions.suggest(for: games, installed: installed).map(\.name), ["Chess"])

        XCTAssertEqual(AppCategory.title(for: "public.app-category.board-games"), "Games")
        XCTAssertEqual(AppCategory.title(for: nil), "Other")
    }

    func testStarterPopsOnlyUseExistingPaths() {
        let existing: Set<String> = ["/Applications/Safari.app", "/System/Applications/Notes.app", "/Users/me/Downloads"]
        let pops = StarterPops.makePops(home: "/Users/me") { path in
            (existing.contains(path), path.hasSuffix(".app") || path.hasSuffix("Downloads"), path.hasSuffix(".app"))
        }
        XCTAssertEqual(pops.map(\.name), ["Everyday", "Folders"])
        XCTAssertEqual(pops[0].items.map(\.name), ["Safari", "Notes"])
        XCTAssertEqual(pops[1].items.first?.kind, .folder)
        XCTAssertEqual(pops[1].items.first?.target, "/Users/me/Downloads")
    }
}
