import AppKit
import Combine
import OpenPopsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let mode = RunMode.current
    let model: AppModel
    private(set) lazy var popover = PopoverController(model: model, mode: mode)
    private(set) lazy var tiles = TileManager(model: model)
    private(set) lazy var statusItem = StatusItemController(model: model)
    private(set) lazy var popOuts = PopOutManager(model: model)
    private var organizer: OrganizerWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var didFinishLaunching = false
    private var launchedToOpenSomething = false
    private var appliedPresentation: Presentation?
    private var appliedTilesInSwitcher: Bool?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAsLoginItem = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        DebugLog.log("launched (loginItem=\(launchedAsLoginItem), openRequest=\(launchedToOpenSomething))")

        MainMenu.install(for: self)
        wireCallbacks()
        applyPresentation()

        switch mode {
        case .main:
            model.store.makeLaunchBackup()
            if !model.store.fileExisted {
                createStarterPops()
            }
            tiles.maintainTiles()
            popOuts.restore(allowed: model.library.pops.map(\.id))
        case .tile(let target):
            if !model.library.targetExists(target) {
                offerToRemoveOrphanTile()
                return
            }
        }

        updateDockIcon()
        model.$library
            .dropFirst()
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.libraryChanged() }
            }
            .store(in: &cancellables)

        didFinishLaunching = true
        let showWelcome = mode.isMain && !model.library.settings.hasCompletedOnboarding
        if showWelcome {
            openOrganizer(nil)
        } else if !launchedToOpenSomething && !launchedAsLoginItem {
            // Launched by clicking the Dock tile, or from Finder or Spotlight.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.showFromClick(toggle: false) }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DebugLog.log("reopen")
        showFromClick(toggle: true)
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Spring-loading: a drag hovering over our Dock tile activates the app. Open the
        // popover so the drop can land inside it.
        if didFinishLaunching, NSEvent.pressedMouseButtons & 1 == 1, !popover.isShown {
            DebugLog.log("spring-loaded open")
            showFromClick(toggle: false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model.flush()
    }

    private func showFromClick(toggle: Bool) {
        let anchor = PopoverController.Anchor.dock(NSEvent.mouseLocation)
        if toggle {
            popover.toggle(anchor: anchor)
        } else {
            popover.show(anchor: anchor)
        }
    }

    private func wireCallbacks() {
        popover.onOpenOrganizer = { [weak self] id in self?.openOrganizer(id) }
        popover.onPopOut = { [weak self] id in self?.popOuts.open(id) }
        popover.onActivePopChanged = { [weak self] _ in self?.updateDockIcon() }
        popOuts.onOpenOrganizer = { [weak self] id in self?.openOrganizer(id) }
        statusItem.onShowCarousel = { [weak self] frame in
            guard let self = self else { return }
            if self.popover.isShown { self.popover.close(.toggle) } else { self.popover.show(anchor: .statusItem(frame)) }
        }
        statusItem.onOpenOrganizer = { [weak self] id in self?.openOrganizer(id) }
    }

    // MARK: Presentation

    /// Dock icon, menu bar icon, or both (main app); Cmd-Tab visibility (tiles).
    func applyPresentation() {
        switch mode {
        case .main:
            let p = model.library.settings.presentation
            guard p != appliedPresentation else { return }
            appliedPresentation = p
            NSApp.setActivationPolicy(p.showsDockIcon ? .regular : .accessory)
            if p.showsStatusItem { statusItem.install() } else { statusItem.remove() }
            updateDockIcon()
        case .tile:
            let inSwitcher = model.library.settings.tilesInAppSwitcher
            guard inSwitcher != appliedTilesInSwitcher else { return }
            appliedTilesInSwitcher = inSwitcher
            NSApp.setActivationPolicy(inSwitcher ? .regular : .accessory)
            updateDockIcon()
        }
    }

    /// Shows the active Pop's live icon on our own Dock tile.
    func updateDockIcon() {
        guard NSApp.activationPolicy() == .regular else { return }
        switch mode {
        case .main:
            let pops = model.library.carouselPops
            let active = model.library.settings.lastActivePopID.flatMap { id in pops.first { $0.id == id } } ?? pops.first
            NSApp.applicationIconImage = active.map { DockIconRenderer.image(for: $0) }
        case .tile(let target):
            switch target {
            case .pop(let id):
                NSApp.applicationIconImage = model.pop(id).map { DockIconRenderer.image(for: $0) }
            case .group(let id):
                if let group = model.library.group(id) {
                    NSApp.applicationIconImage = DockIconRenderer.image(forGroup: group, pops: model.library.pops(inGroup: id))
                }
            }
        }
    }

    private func libraryChanged() {
        if case .tile(let target) = mode, !model.library.targetExists(target) {
            DebugLog.log("tile target deleted; quitting")
            NSApp.terminate(nil)
            return
        }
        applyPresentation()
        popover.libraryDidChange()
        popOuts.refreshAll()
        updateDockIcon()
        if mode.isMain { tiles.scheduleIconRefresh() }
    }

    // MARK: Dock menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let pops: [Pop]
        switch mode {
        case .main: pops = model.library.carouselPops
        case .tile(let target): pops = model.library.pops(for: target)
        }
        if pops.count > 1 {
            for pop in pops {
                menu.addItem(ClosureMenuItem(pop.name) { [weak self] in
                    self?.popover.show(anchor: .dock(NSEvent.mouseLocation), initial: pop.id)
                })
            }
            menu.addItem(.separator())
        }
        if let pop = pops.first(where: { $0.id == model.library.settings.lastActivePopID }) ?? pops.first {
            menu.addItem(ClosureMenuItem("Open All in “\(pop.name)”", enabled: !pop.items.isEmpty) { [weak self] in
                let popID = pop.id
                self?.model.update { lib in
                    for i in pop.items { lib.recordLaunch(itemID: i.id, in: popID) }
                }
                Launcher.openAll(pop.sortedItems())
            })
            menu.addItem(ClosureMenuItem("Pop Out “\(pop.name)”") { [weak self] in self?.popOuts.open(pop.id) })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("Open Organizer…") { [weak self] in self?.openOrganizer(nil) })
        return menu
    }

    // MARK: Opening files and links

    func application(_ application: NSApplication, open urls: [URL]) {
        if !didFinishLaunching { launchedToOpenSomething = true }
        let commands = urls.filter { $0.scheme?.lowercased() == AppInfo.urlScheme }
        let files = urls.filter { $0.isFileURL }
        for url in commands {
            DebugLog.log("url command \(url.absoluteString)")
            handle(URLCommand(url: url))
        }
        if !files.isEmpty { addDroppedOnDockIcon(files) }
    }

    /// Files dropped on the Dock icon go into the Pop that's showing (or was last shown).
    private func addDroppedOnDockIcon(_ files: [URL]) {
        let candidates = model.popIDs(for: mode)
        let target = popover.currentPopID.flatMap { candidates.contains($0) ? $0 : nil }
            ?? model.library.settings.lastActivePopID.flatMap { candidates.contains($0) ? $0 : nil }
            ?? candidates.first
        guard let popID = target else {
            NSSound.beep()
            return
        }
        let added = model.add(urls: files, to: popID)
        model.flush()
        DebugLog.log("added \(added) dropped file(s) to \(model.pop(popID)?.name ?? "?")")
        let anchor = PopoverController.Anchor.dock(NSEvent.mouseLocation)
        if popover.isShown {
            popover.libraryDidChange()
        } else if didFinishLaunching {
            popover.show(anchor: anchor, initial: popID)
        } else {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.popover.show(anchor: anchor, initial: popID) }
            }
        }
    }

    private func resolvePop(_ ref: String?) -> Pop? {
        if let ref = ref { return model.library.resolvePop(ref) }
        let id = model.library.settings.lastActivePopID
        return id.flatMap { model.pop($0) } ?? model.library.pops.first
    }

    private func handle(_ command: URLCommand?) {
        guard let command = command else { return }
        let anchor = PopoverController.Anchor.dock(NSEvent.mouseLocation)
        switch command {
        case .show(let ref):
            if let ref = ref {
                guard let pop = model.library.resolvePop(ref) else { return NSSound.beep() }
                popover.show(anchor: anchor, popIDs: [pop.id], initial: pop.id)
            } else {
                popover.show(anchor: anchor)
            }
        case .showGroup(let ref):
            guard let group = model.library.resolveGroup(ref) else { return NSSound.beep() }
            popover.show(anchor: anchor, popIDs: group.popIDs)
        case .organizer(let ref):
            openOrganizer(ref.flatMap { model.library.resolvePop($0)?.id })
        case .add(let ref, let target, let name):
            guard let pop = resolvePop(ref),
                  let item = URLCommand.item(forTarget: target, name: name, isDirectory: ItemFactory.probe) else {
                return NSSound.beep()
            }
            model.update(immediately: true) { $0.addItems([item], to: pop.id) }
        case .popOut(let ref):
            guard let pop = model.library.resolvePop(ref) else { return NSSound.beep() }
            popOuts.open(pop.id)
        case .openAll(let ref):
            guard let pop = model.library.resolvePop(ref) else { return NSSound.beep() }
            Launcher.openAll(pop.sortedItems())
        case .makeTile(let popRef, let groupRef, let pin):
            let target: TileTarget?
            if let p = popRef.flatMap({ model.library.resolvePop($0) }) {
                target = .pop(p.id)
            } else if let g = groupRef.flatMap({ model.library.resolveGroup($0) }) {
                target = .group(g.id)
            } else {
                target = nil
            }
            guard let t = target else { return NSSound.beep() }
            do {
                if pin { try tiles.addToDock(t) } else { try tiles.ensureTile(for: t) }
            } catch {
                DebugLog.log("tile error: \(error.localizedDescription)")
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: Organizer

    func openOrganizer(_ popID: UUID?) {
        guard mode.isMain else {
            // Tiles hand off to the main app, which owns the Organizer.
            var components = URLComponents()
            components.scheme = AppInfo.urlScheme
            components.host = "organizer"
            if let id = popID { components.queryItems = [URLQueryItem(name: "pop", value: id.uuidString)] }
            guard let url = components.url, let app = AppInfo.mainAppURL else { return NSSound.beep() }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if organizer == nil {
            let controller = OrganizerWindowController(model: model, tiles: tiles)
            controller.onClose = { [weak self] in self?.organizerClosed() }
            controller.onPreviewPop = { [weak self] id in
                self?.popover.show(anchor: .centered, popIDs: nil, initial: id)
            }
            organizer = controller
        }
        organizer?.show(selecting: popID)
    }

    func newPopFromMenu() {
        openOrganizer(nil)
        organizer?.createPop()
    }

    private func organizerClosed() {
        model.flush()
        tiles.maintainTiles()
        tiles.restartDockIfIconsChanged()
    }

    // MARK: First launch

    private func createStarterPops() {
        let pops = StarterPops.makePops(home: NSHomeDirectory(), probe: ItemFactory.probe)
        model.update(immediately: true) { lib in
            guard lib.pops.isEmpty else { return }
            lib.pops = pops
            lib.settings.lastActivePopID = pops.first?.id
        }
        DebugLog.log("created \(pops.count) starter pops")
    }

    private func offerToRemoveOrphanTile() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "This Dock tile's Pop no longer exists"
        alert.informativeText = "Remove “\(Bundle.main.bundleURL.deletingPathExtension().lastPathComponent)” from the Dock?"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Keep")
        if alert.runModal() == .alertFirstButtonReturn {
            let path = Bundle.main.bundlePath
            if DockPrefs.unpin(path: path) { DockPrefs.restartDock() }
            try? FileManager.default.removeItem(atPath: path)
        }
        NSApp.terminate(nil)
    }
}

enum MainMenu {
    @MainActor
    static func install(for delegate: AppDelegate) {
        let main = NSMenu()

        let appMenu = NSMenu(title: "OpenPops")
        appMenu.addItem(withTitle: "About OpenPops", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(ClosureMenuItem("Settings…", key: ",") { delegate.openOrganizer(nil) })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide OpenPops", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit OpenPops", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addMenu(appMenu, to: main)

        let file = NSMenu(title: "File")
        file.addItem(ClosureMenuItem("New Pop", key: "n") { delegate.newPopFromMenu() })
        file.addItem(ClosureMenuItem("Show Pops", key: "p") { delegate.popover.show(anchor: .centered) })
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addMenu(file, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addMenu(edit, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        addMenu(window, to: main)
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(ClosureMenuItem("OpenPops Help") { NSWorkspace.shared.open(AppInfo.readmeURL) })
        addMenu(help, to: main)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    private static func addMenu(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
