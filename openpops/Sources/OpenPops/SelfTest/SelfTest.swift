import AppKit
import OpenPopsCore

/// `OpenPops --self-test <folder>` builds a sample library, renders every part of the UI,
/// saves screenshots to <folder>, launches a generated Dock tile and checks that it
/// responds to a reopen, then exits with status 0 (all passed) or 1. CI runs this on a
/// macOS runner; it leaves your own library as it found it.
@MainActor
enum SelfTest {
    private static var failures: [String] = []
    private static var out = URL(fileURLWithPath: "build/self-test")

    static func run(outputDirectory: URL) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        out = outputDirectory
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            Task { @MainActor in
                await steps()
                let summary = failures.isEmpty ? "ALL PASSED" : "FAILED:\n" + failures.joined(separator: "\n")
                print(summary)
                try? summary.write(to: out.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
                exit(failures.isEmpty ? 0 : 1)
            }
        }
        app.run()
        exit(1)
    }

    private static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures.append(what) }
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Steps

    private static func steps() async {
        let fm = FileManager.default
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), screens: \(NSScreen.screens.map { NSStringFromRect($0.frame) })")

        // Work in the real data folder so tile apps (separate processes) read the same library,
        // but put the user's own library aside first and restore it at the end.
        let support = LibraryStore.defaultDirectory
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        let libraryURL = support.appendingPathComponent("library.json")
        let backupURL = support.appendingPathComponent("library.selftest-backup.json")
        let hadLibrary = fm.fileExists(atPath: libraryURL.path)
        if hadLibrary {
            try? fm.removeItem(at: backupURL)
            try? fm.moveItem(at: libraryURL, to: backupURL)
        }
        let flag = support.appendingPathComponent("debug-log-enabled")
        let hadFlag = fm.fileExists(atPath: flag.path)
        fm.createFile(atPath: flag.path, contents: nil)
        let logURL = support.appendingPathComponent("debug.log")
        try? Data().write(to: logURL)

        let model = AppModel(store: LibraryStore(directory: support))
        let ids = buildSampleLibrary(model)
        check(model.library.pops.count >= 5, "sample library has \(model.library.pops.count) pops")

        dockIcons(model)
        await popovers(model, ids: ids)
        await organizer(model, ids: ids)
        await tileApp(model, ids: ids, logURL: logURL)

        try? fm.copyItem(at: logURL, to: out.appendingPathComponent("debug.log"))
        try? fm.removeItem(at: libraryURL)
        if hadLibrary { try? fm.moveItem(at: backupURL, to: libraryURL) }
        if !hadFlag { try? fm.removeItem(at: flag) }
    }

    struct SampleIDs {
        var work = UUID(), utilities = UUID(), sunset = UUID(), matrix = UUID(), list = UUID(), spiiira = UUID()
        var group = UUID()
    }

    private static func buildSampleLibrary(_ model: AppModel) -> SampleIDs {
        let fm = FileManager.default
        let files = out.appendingPathComponent("sample-files", isDirectory: true)
        try? fm.createDirectory(at: files.appendingPathComponent("Projects/Drafts"), withIntermediateDirectories: true)
        try? "Meeting notes\n\n- Ship OpenPops\n- Test the Dock tiles\n".write(to: files.appendingPathComponent("Notes.txt"),
                                                                              atomically: true, encoding: .utf8)
        try? "# Plan\n\nA Markdown file for Quick Look.\n".write(to: files.appendingPathComponent("Projects/Plan.md"),
                                                                  atomically: true, encoding: .utf8)
        let swatch = NSImage.rendered(pixels: 400) { r in
            NSGradient(colors: [.systemOrange, .systemPink, .systemPurple])?.draw(in: r, angle: 45)
        }
        try? swatch.pngData()?.write(to: files.appendingPathComponent("Projects/Swatch.png"))

        func apps(_ paths: [String]) -> [PopItem] {
            paths.filter { fm.fileExists(atPath: $0) }.map { PopItem(kind: .app, target: $0) }
        }
        let utilitiesFolder = "/System/Applications/Utilities"
        let utilityApps = ((try? fm.contentsOfDirectory(atPath: utilitiesFolder)) ?? [])
            .filter { $0.hasSuffix(".app") }.sorted().prefix(14).map { utilitiesFolder + "/" + $0 }
        let everyday = apps(["/Applications/Safari.app", "/System/Applications/Mail.app", "/System/Applications/Notes.app",
                             "/System/Applications/Calendar.app", "/System/Applications/Music.app",
                             "/System/Applications/Photos.app", "/System/Applications/Maps.app",
                             "/System/Applications/Reminders.app", "/System/Applications/Messages.app"])
        var ids = SampleIDs()
        let theme = { (id: String) in BuiltInThemes.theme(id) }
        let workItems = Array(everyday.prefix(5)) + [
            PopItem(kind: .folder, target: files.path),
            PopItem(kind: .file, target: files.appendingPathComponent("Notes.txt").path),
            PopItem(kind: .link, target: "https://github.com/jonasspira", customName: "GitHub"),
        ]
        let listItems = Array(everyday.prefix(4)) + [PopItem(kind: .file, target: files.appendingPathComponent("Notes.txt").path)]
        let s = ids
        let groupPops = [s.sunset, s.matrix, s.spiiira]
        model.update(immediately: true) { lib in
            lib.pops = []
            lib.groups = []
            lib.addPop(named: "Work", items: workItems, id: s.work)
            lib.addPop(named: "Utilities", theme: theme("graphite"), items: apps(Array(utilityApps)), id: s.utilities)
            lib.addPop(named: "Sunset", theme: theme("sunset"), items: Array(everyday.suffix(6)), id: s.sunset)
            lib.addPop(named: "Matrix", theme: theme("matrix"), items: Array(everyday.prefix(6)), id: s.matrix)
            lib.addPop(named: "List", theme: theme("paper"), items: listItems, id: s.list)
            lib.addPop(named: "Spiiira", theme: theme("spiiira"), items: Array(everyday.prefix(4)), id: s.spiiira)
            lib.updatePop(s.list) { $0.layout = .list }
            lib.updatePop(s.matrix) {
                $0.dockIcon.mode = .glyph
                $0.dockIcon.glyph = ">_"
            }
            lib.addGroup(named: "Themed", popIDs: groupPops, id: s.group)
            lib.settings.hasCompletedOnboarding = true
            lib.settings.lastActivePopID = s.work
        }
        ids = s
        return ids
    }

    // MARK: Dock icons

    private static func dockIcons(_ model: AppModel) {
        for pop in model.library.pops {
            let image = DockIconRenderer.image(for: pop)
            let ok = save(image, "dock-\(safe(pop.name))")
            check(ok, "Dock icon renders for \(pop.name)")
        }
        if let group = model.library.groups.first {
            let ok = save(DockIconRenderer.image(forGroup: group, pops: model.library.pops(inGroup: group.id)), "dock-group")
            check(ok, "Dock icon renders for a group")
        }
        if var pop = model.library.pops.first {
            for density in IconDensity.allCases {
                pop.dockIcon.density = density
                _ = save(DockIconRenderer.image(for: pop, pixels: 256), "dock-density-\(density.rawValue)")
            }
        }
    }

    // MARK: Popovers

    private static func popovers(_ model: AppModel, ids: SampleIDs) async {
        let controller = PopoverController(model: model, mode: .main)
        guard let screen = NSScreen.main else {
            check(false, "a screen is available")
            return
        }
        let v = screen.visibleFrame
        let bottom = CGPoint(x: v.midX, y: v.minY + 4)
        let carousel = model.library.carouselPops.map(\.id)

        for (i, pop) in model.library.carouselPops.enumerated() {
            controller.show(anchor: .point(bottom, .bottom), popIDs: carousel, initial: pop.id)
            await wait(0.7)
            check(controller.isShown && controller.currentPopID == pop.id, "popover shows \(pop.name)")
            snapshot(controller, "popover-\(i + 1)-\(safe(pop.name))")
            controller.close(.programmatic)
            await wait(0.3)
        }

        // Paging with the keyboard-driven API.
        controller.show(anchor: .point(bottom, .bottom), popIDs: carousel, initial: ids.work)
        await wait(0.5)
        controller.nextPage()
        await wait(0.6)
        check(controller.currentPopID == carousel.dropFirst().first, "next page moves to the second Pop")
        controller.previousPage()
        await wait(0.6)

        // What drops, drag-reordering and dragging an item off the Pop do to the library.
        if let grid = controller.grid, let pop = controller.currentPop {
            let before = pop.items.map(\.id)
            let extra = out.appendingPathComponent("sample-files/Projects/Plan.md")
            controller.grid(grid, didDrop: [extra], titles: [:], at: 0)
            await wait(0.4)
            let afterDrop = model.pop(pop.id)?.items ?? []
            check(afterDrop.count == before.count + 1 && afterDrop.first?.target == extra.path,
                  "dropping a file into the Pop adds it where it was dropped")
            if let g = controller.grid, controller.entries.count >= 2 {
                var order = Array(controller.entries.indices)
                order.swapAt(0, 1)
                let expected = order.compactMap { controller.entries[$0].popItem?.id }
                controller.grid(g, didReorder: order)
                await wait(0.4)
                check(model.pop(pop.id)?.items.map(\.id) == expected, "dragging an item reorders the Pop")
            }
            if let g = controller.grid, let index = controller.entries.firstIndex(where: { $0.popItem?.target == extra.path }) {
                controller.grid(g, didDragOut: index)
                await wait(0.4)
                check(!(model.pop(pop.id)?.items.contains { $0.target == extra.path } ?? true),
                      "dragging an item off the Pop removes it")
            }
            model.update(immediately: true) { lib in lib.updatePop(pop.id) { p in
                p.items.sort { a, b in (before.firstIndex(of: a.id) ?? 0) < (before.firstIndex(of: b.id) ?? 0) }
            } }
            controller.render(transition: nil, animateFrame: false)
            await wait(0.3)
        }

        // Browse into a folder.
        if let folderIndex = controller.entries.firstIndex(where: { $0.popItem?.kind == .folder }) {
            controller.activate(folderIndex, modifiers: [])
            await wait(0.7)
            check(controller.isBrowsingFolder, "clicking a folder browses it inside the Pop")
            check(controller.entries.contains { $0.name == "Notes.txt" }, "folder contents are listed")
            var endsWithFinder = false
            if let last = controller.entries.last, case .openInFinder = last.kind { endsWithFinder = true }
            check(endsWithFinder, "folder view ends with Open in Finder")
            snapshot(controller, "popover-folder")
            if let projects = controller.entries.firstIndex(where: { $0.name == "Projects" }) {
                controller.activate(projects, modifiers: [])
                await wait(0.8)
                snapshot(controller, "popover-folder-nested")
                // Quick Look a file.
                if let md = controller.entries.firstIndex(where: { $0.name == "Swatch.png" }) {
                    controller.grid?.selectedIndex = md
                    controller.toggleQuickLook()
                    await wait(1.5)
                    check(controller.preview.isShown, "Space opens Quick Look")
                    captureScreen("screen-quicklook")
                    controller.preview.close()
                }
                controller.goBack()
                await wait(0.5)
            }
            controller.goBack()
            await wait(0.5)
            check(!controller.isBrowsingFolder, "back returns to the Pop")
        } else {
            check(false, "sample Pop has a folder")
        }
        controller.grid?.selectedIndex = 1
        await wait(0.3)
        snapshot(controller, "popover-selection")
        captureScreen("screen-popover-bottom")
        controller.close(.programmatic)
        await wait(0.3)

        // Other Dock positions and the menu bar.
        let placements: [(String, CGPoint, ArrowEdge)] = [
            ("left", CGPoint(x: v.minX + 4, y: v.midY), .left),
            ("right", CGPoint(x: v.maxX - 4, y: v.midY), .right),
            ("menubar", CGPoint(x: v.maxX - 200, y: v.maxY - 2), .top),
            ("centered", .zero, .none),
        ]
        for (name, point, edge) in placements {
            controller.show(anchor: .point(point, edge), popIDs: [ids.sunset], initial: ids.sunset)
            await wait(0.6)
            if let frame = controller.panelFrame {
                let inside = NSScreen.screens.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(frame) }
                check(inside, "popover for a \(name) anchor stays on screen \(NSStringFromRect(frame))")
            }
            snapshot(controller, "popover-edge-\(name)")
            controller.close(.programmatic)
            await wait(0.3)
        }

        // List layout and an empty Pop.
        controller.show(anchor: .point(bottom, .bottom), popIDs: [ids.list], initial: ids.list)
        await wait(0.6)
        snapshot(controller, "popover-list-layout")
        controller.close(.programmatic)
        await wait(0.3)
        let emptyID = UUID()
        model.update(immediately: true) { $0.addPop(named: "Empty", id: emptyID) }
        controller.show(anchor: .point(bottom, .bottom), popIDs: [emptyID], initial: emptyID)
        await wait(0.6)
        snapshot(controller, "popover-empty")
        controller.close(.programmatic)
        model.update(immediately: true) { $0.deletePop(emptyID) }
        await wait(0.3)
    }

    // MARK: Organizer

    private static func organizer(_ model: AppModel, ids: SampleIDs) async {
        let tiles = TileManager(model: model)
        let organizer = OrganizerWindowController(model: model, tiles: tiles)
        organizer.show(selecting: ids.work)
        await wait(2.0)
        check(organizer.isVisible, "Organizer opens")
        snapshotWindow(of: organizer.contentView, "organizer-pop")
        organizer.state.selection = .pop(ids.sunset)
        await wait(1.0)
        snapshotWindow(of: organizer.contentView, "organizer-pop-sunset")
        organizer.state.editorTab = .appearance
        await wait(1.0)
        snapshotWindow(of: organizer.contentView, "organizer-appearance")
        organizer.state.editorTab = .dockIcon
        await wait(1.0)
        snapshotWindow(of: organizer.contentView, "organizer-dock-icon")
        organizer.state.editorTab = .items
        organizer.state.selection = .group(ids.group)
        await wait(1.0)
        snapshotWindow(of: organizer.contentView, "organizer-group")
        organizer.state.selection = .themes
        await wait(1.0)
        snapshotWindow(of: organizer.contentView, "organizer-themes")
        organizer.state.selection = .settings
        await wait(1.0)
        snapshotWindow(of: organizer.contentView, "organizer-settings")
        organizer.state.selection = .welcome
        await wait(1.0)
        snapshotWindow(of: organizer.contentView, "organizer-welcome")
        captureScreen("screen-organizer")
        organizer.contentView?.window?.close()
        await wait(0.5)

        let popOuts = PopOutManager(model: model)
        popOuts.open(ids.sunset)
        await wait(1.0)
        check(!popOuts.isEmpty, "Pop Out window opens")
        let statusItem = StatusItemController(model: model)
        statusItem.install()
        await wait(0.8)
        check(statusItem.isInstalled, "menu bar icon installs")
        captureScreen("screen-popout-and-menubar")
        statusItem.remove()
        for window in NSApp.windows where window.isVisible && window.level == .floating { window.close() }
        await wait(0.4)
    }

    // MARK: Tile app

    private static func tileApp(_ model: AppModel, ids: SampleIDs, logURL: URL) async {
        let tiles = TileManager(model: model)
        let target = TileTarget.pop(ids.utilities)
        let record: TileRecord
        do {
            record = try tiles.ensureTile(for: target)
        } catch {
            check(false, "tile app is created (\(error.localizedDescription))")
            return
        }
        let url = URL(fileURLWithPath: record.path)
        check(FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/OpenPops").path),
              "tile app bundle exists at \(record.path)")
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        check(info?[AppInfo.tileTargetKey] as? String == target.stringValue, "tile Info.plist names its Pop")
        check(info?["LSUIElement"] as? Bool == true, "tile stays out of the Dock's running apps")

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            check(false, "tile app launches (\(error.localizedDescription))")
            return
        }
        await wait(3.0)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: record.bundleIdentifier)
        check(running.count == 1, "tile app is running (\(running.count) instance)")
        captureScreen("screen-tile-launched")

        // A second open is what a Dock click on a running app sends: a reopen event.
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        await wait(2.0)
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        await wait(2.0)
        captureScreen("screen-tile-reopened")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let tileLines = log.split(separator: "\n").filter { $0.contains("[tile ") }
        check(tileLines.contains { $0.contains("popover shown") }, "tile shows its Pop when launched")
        check(tileLines.contains { $0.contains("reopen") }, "tile receives reopen events")
        check(NSRunningApplication.runningApplications(withBundleIdentifier: record.bundleIdentifier).count == 1,
              "reopening doesn't start a second tile process")

        NSRunningApplication.runningApplications(withBundleIdentifier: record.bundleIdentifier).forEach { $0.terminate() }
        await wait(1.0)
        tiles.removeFromDock(target)
        check(!FileManager.default.fileExists(atPath: record.path), "tile app is removed")
    }

    // MARK: Snapshots

    private static func safe(_ s: String) -> String {
        s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
    }

    @discardableResult
    private static func save(_ image: NSImage, _ name: String) -> Bool {
        guard let data = image.pngData() else { return false }
        do {
            try data.write(to: out.appendingPathComponent(name + ".png"))
            return data.count > 1000
        } catch {
            return false
        }
    }

    private static func snapshot(_ controller: PopoverController, _ name: String) {
        guard let view = controller.contentView else { return }
        snapshotWindow(of: view, name)
    }

    /// Saves the window through screencapture (real pixels, when screen recording is allowed)
    /// and through AppKit's own rendering (always works, but without blur).
    private static func snapshotWindow(of view: NSView?, _ name: String) {
        guard let view = view, let window = view.window else { return }
        runScreencapture(["-x", "-o", "-l", String(window.windowNumber), out.appendingPathComponent(name + ".png").path])
        if let image = window.contentView?.snapshotImage() {
            _ = save(image, name + "-appkit")
        }
    }

    private static func captureScreen(_ name: String) {
        runScreencapture(["-x", out.appendingPathComponent(name + ".png").path])
    }

    /// Turned off after the first capture that fails or hangs (no screen recording permission).
    private static var screencaptureWorks = true

    private static func runScreencapture(_ args: [String]) {
        guard screencaptureWorks else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return
        }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            p.terminate()
            screencaptureWorks = false
            print("note: screencapture hung; using AppKit snapshots only")
        } else if p.terminationStatus != 0 {
            screencaptureWorks = false
            print("note: screencapture failed (\(p.terminationStatus)); using AppKit snapshots only")
        }
    }
}
