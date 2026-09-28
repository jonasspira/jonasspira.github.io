import XCTest
@testable import OpenPopsCore

final class ModelTests: XCTestCase {

    func testDefaultNames() {
        XCTAssertEqual(PopItem(kind: .app, target: "/Applications/Safari.app").name, "Safari")
        XCTAssertEqual(PopItem(kind: .file, target: "/Users/me/Reports/pacing.html").name, "pacing.html")
        XCTAssertEqual(PopItem(kind: .folder, target: "/Users/me/Reports").name, "Reports")
        XCTAssertEqual(PopItem(kind: .link, target: "https://www.example.com/path").name, "example.com")
        XCTAssertEqual(PopItem(kind: .link, target: "https://github.com").name, "github.com")
        XCTAssertEqual(PopItem(kind: .app, target: "/Applications/Safari.app", customName: "  Browser ").name, "Browser")
        XCTAssertEqual(PopItem(kind: .app, target: "/Applications/Safari.app", customName: "   ").name, "Safari")
    }

    func testKindDetection() {
        XCTAssertEqual(ItemKind.detect(path: "/Applications/Xcode.app", isDirectory: true, isPackage: true), .app)
        XCTAssertEqual(ItemKind.detect(path: "/Users/me/Docs", isDirectory: true, isPackage: false), .folder)
        XCTAssertEqual(ItemKind.detect(path: "/Users/me/Report.pages", isDirectory: true, isPackage: true), .file)
        XCTAssertEqual(ItemKind.detect(path: "/Users/me/a.txt", isDirectory: false, isPackage: false), .file)
    }

    func testIdentityKeyStandardizesPaths() {
        let a = PopItem(kind: .folder, target: "/Users/me/Docs/")
        let b = PopItem(kind: .folder, target: "/Users/me/./Docs")
        XCTAssertEqual(a.identityKey, b.identityKey)
        XCTAssertEqual(PopItem.standardizedPath("/"), "/")
    }

    func testTileTargetRoundTrip() throws {
        let id = UUID()
        for t in [TileTarget.pop(id), .group(id)] {
            XCTAssertEqual(TileTarget(string: t.stringValue), t)
            let data = try JSONEncoder().encode([t])
            XCTAssertEqual(try JSONDecoder().decode([TileTarget].self, from: data), [t])
        }
        XCTAssertNil(TileTarget(string: "pop:not-a-uuid"))
        XCTAssertNil(TileTarget(string: "window:" + id.uuidString))
    }

    func testLibraryRoundTrip() throws {
        var lib = Library()
        let popID = lib.addPop(named: "Work", theme: BuiltInThemes.theme("sunset"))
        lib.addItems([PopItem(kind: .app, target: "/Applications/Safari.app"),
                      PopItem(kind: .link, target: "https://example.com", customName: "Example")], to: popID)
        lib.addGroup(named: "Projects", popIDs: [popID])
        lib.settings.iconSize = 72
        lib.settings.presentation = .both
        lib.tiles.append(TileRecord(target: .pop(popID), bundleIdentifier: "com.spiiira.openpops.tile.abc",
                                    path: "/Users/me/Applications/OpenPops Tiles/Work.app", buildID: "1"))

        let data = try LibraryStore.encoder.encode(lib)
        let decoded = try LibraryStore.decoder.decode(Library.self, from: data)
        XCTAssertEqual(decoded.pops.count, 1)
        XCTAssertEqual(decoded.pops[0].name, "Work")
        XCTAssertEqual(decoded.pops[0].items.map(\.name), ["Safari", "Example"])
        XCTAssertEqual(decoded.pops[0].style, BuiltInThemes.theme("sunset")!.style)
        XCTAssertEqual(decoded.pops[0].themeID, "sunset")
        XCTAssertEqual(decoded.groups.first?.popIDs, [popID])
        XCTAssertEqual(decoded.settings.iconSize, 72)
        XCTAssertEqual(decoded.settings.presentation, .both)
        XCTAssertEqual(decoded.tiles.first?.target, .pop(popID))
    }

    func testDecodingFillsInMissingKeysAndSkipsBadEntries() throws {
        let json = """
        {
          "pops": [
            { "name": "Minimal", "items": [
                { "kind": "app", "target": "/Applications/Safari.app" },
                { "kind": "hologram", "target": "/nope" },
                { "target": "/missing-kind" }
            ] },
            "not a pop",
            { "name": "Styled", "style": { "background": { "type": "color", "color": "#FF0000" }, "glass": "oops" },
              "sortMode": "futureMode" }
          ],
          "settings": { "iconSize": 80, "presentation": "hologram" },
          "someFutureKey": true
        }
        """
        let lib = try LibraryStore.decoder.decode(Library.self, from: Data(json.utf8))
        XCTAssertEqual(lib.pops.count, 2)
        XCTAssertEqual(lib.pops[0].items.count, 1)
        XCTAssertEqual(lib.pops[0].items[0].name, "Safari")
        XCTAssertEqual(lib.pops[0].sortMode, .manual)
        XCTAssertEqual(lib.pops[1].style.background, .color(RGBA(1, 0, 0)))
        XCTAssertEqual(lib.pops[1].style.glass, PopStyle().glass)
        XCTAssertEqual(lib.pops[1].sortMode, .manual)
        XCTAssertEqual(lib.settings.iconSize, 80)
        XCTAssertEqual(lib.settings.presentation, .dock)
        XCTAssertEqual(lib.settings.labelLines, AppSettings().labelLines)
    }

    func testFillAndBorderCoding() throws {
        let fills: [BackgroundFill] = [
            .system, .color(RGBA(hex: "#12345680")!),
            .gradient(GradientSpec(colors: [.white, .black], angle: 45)), .image("/tmp/bg.jpg"),
        ]
        for f in fills {
            let data = try JSONEncoder().encode(f)
            XCTAssertEqual(try JSONDecoder().decode(BackgroundFill.self, from: data), f)
        }
        let borders: [BorderStyle] = [.none, .color(.white, width: 2),
                                      .gradient(GradientSpec(colors: [.white, .black]), width: 1.5)]
        for b in borders {
            let data = try JSONEncoder().encode(b)
            XCTAssertEqual(try JSONDecoder().decode(BorderStyle.self, from: data), b)
        }
    }

    func testColorHexAndContrast() {
        XCTAssertEqual(RGBA(hex: "#FF8000")?.hexString, "#FF8000")
        XCTAssertEqual(RGBA(hex: "fff")?.hexString, "#FFFFFF")
        XCTAssertEqual(RGBA(hex: "#00000080")?.hexString, "#00000080")
        XCTAssertNil(RGBA(hex: "#12"))
        XCTAssertNil(RGBA(hex: "zzzzzz"))
        XCTAssertTrue(RGBA.white.prefersDarkText)
        XCTAssertFalse(RGBA.black.prefersDarkText)
        XCTAssertFalse(RGBA(hex: "#1E5663")!.prefersDarkText)
        XCTAssertTrue(RGBA(hex: "#BFEDE0")!.prefersDarkText)
        XCTAssertEqual(RGBA.white.contrastRatio(with: .black), 21, accuracy: 0.01)
    }

    func testResolvedAppearance() {
        XCTAssertNil(PopStyle(background: .system).resolvedDarkAppearance)
        XCTAssertEqual(PopStyle(background: .color(.black), glass: 0.2).resolvedDarkAppearance, true)
        XCTAssertEqual(PopStyle(background: .color(.white), glass: 0.2).resolvedDarkAppearance, false)
        XCTAssertNil(PopStyle(background: .color(.black), glass: 0.95).resolvedDarkAppearance)
        XCTAssertEqual(PopStyle(background: .color(.white), appearance: .dark).resolvedDarkAppearance, true)
    }

    func testGradientUnitPoints() {
        let up = GradientSpec(colors: [.white, .black], angle: 90).unitPoints
        XCTAssertEqual(up.start.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(up.start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(up.end.y, 1, accuracy: 1e-9)
        let right = GradientSpec(colors: [.white, .black], angle: 0).unitPoints
        XCTAssertEqual(right.start.x, 0, accuracy: 1e-9)
        XCTAssertEqual(right.end.x, 1, accuracy: 1e-9)
    }

    func testDensity() {
        XCTAssertEqual(IconDensity.auto.gridSize(itemCount: 1), 2)
        XCTAssertEqual(IconDensity.auto.gridSize(itemCount: 4), 2)
        XCTAssertEqual(IconDensity.auto.gridSize(itemCount: 5), 3)
        XCTAssertEqual(IconDensity.auto.gridSize(itemCount: 9), 3)
        XCTAssertEqual(IconDensity.auto.gridSize(itemCount: 10), 4)
        XCTAssertEqual(IconDensity.two.gridSize(itemCount: 25), 2)
    }

    func testBuiltInThemes() {
        XCTAssertEqual(BuiltInThemes.all.count, 12)
        XCTAssertEqual(Set(BuiltInThemes.all.map(\.id)).count, 12, "theme ids must be unique")
        XCTAssertTrue(BuiltInThemes.system.isBuiltIn)
        XCTAssertNotNil(BuiltInThemes.theme("matrix"))
    }
}
