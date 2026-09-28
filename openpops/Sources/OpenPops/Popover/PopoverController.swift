import AppKit
import OpenPopsCore

/// Shows Pops in a popover above the Dock (or below the menu bar icon) and handles
/// everything that happens inside it.
@MainActor
final class PopoverController: NSObject {
    enum Anchor {
        /// Mouse location when the Dock tile was clicked.
        case dock(NSPoint)
        /// Screen frame of the menu bar icon.
        case statusItem(NSRect)
        /// Not opened from the Dock (URL command, Spotlight): center on screen.
        case centered
        /// An explicit anchor point and arrow edge (self-test).
        case point(CGPoint, ArrowEdge)
    }

    enum CloseReason: String {
        case escape, outsideClick, resignKey, resignActive, launched, toggle, programmatic
    }

    enum Arrival { case none, first, last }

    private let model: AppModel
    private let mode: RunMode
    private var panel: PopoverPanel?
    private var root: PopoverContentView?
    private(set) var popIDs: [UUID] = []
    private var requestedIDs: [UUID]?
    private(set) var pageIndex = 0
    private var folderStack: [URL] = []
    private(set) var entries: [GridEntry] = []
    private var anchorPoint = CGPoint.zero
    private var anchorEdge: ArrowEdge = .none
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var sessionObservers: [NSObjectProtocol] = []
    private var menuObservers: [NSObjectProtocol] = []
    private var lastClose: (time: TimeInterval, reason: CloseReason) = (0, .programmatic)
    private var confirmingOpenAll = false
    private var typeahead = ""
    private var typeaheadTime: TimeInterval = 0
    private var swipeAccumulator: CGFloat = 0
    private var swipeFired = false
    private var gestureHorizontal: Bool?
    private var lastGestureHorizontal = false
    private var lastWheelPage: TimeInterval = 0
    private var closing = false
    private var menuTracking = false
    let preview = QuickLookPreview()

    var onOpenOrganizer: ((UUID?) -> Void)?
    var onPopOut: ((UUID) -> Void)?
    var onActivePopChanged: ((UUID) -> Void)?

    init(model: AppModel, mode: RunMode) {
        self.model = model
        self.mode = mode
        super.init()
        preview.onOpen = { [weak self] in self?.close(.launched) }
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = true }
        })
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = false }
        })
    }

    var isShown: Bool { (panel?.isVisible ?? false) && !closing }
    var panelFrame: NSRect? { panel?.frame }
    var contentView: PopoverContentView? { root }
    var grid: PopGridView? { root?.grid }
    var isBrowsingFolder: Bool { !folderStack.isEmpty }

    var currentPopID: UUID? {
        popIDs.indices.contains(pageIndex) ? popIDs[pageIndex] : nil
    }

    var currentPop: Pop? {
        currentPopID.flatMap { model.pop($0) }
    }

    private var settings: AppSettings { model.library.settings }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var speed: Double { settings.animationSpeed.duration }

    // MARK: Showing and hiding

    func toggle(anchor: Anchor, popIDs ids: [UUID]? = nil, initial: UUID? = nil) {
        if isShown {
            close(.toggle)
            return
        }
        // Clicking our own Dock tile while the popover is open first registers as a click
        // outside (closing it) and then arrives as a reopen. Treat that as "close".
        let now = ProcessInfo.processInfo.systemUptime
        if [.outsideClick, .resignActive, .resignKey].contains(lastClose.reason), now - lastClose.time < 0.45 {
            DebugLog.log("toggle ignored right after closing (\(lastClose.reason.rawValue))")
            return
        }
        show(anchor: anchor, popIDs: ids, initial: initial)
    }

    func show(anchor: Anchor, popIDs ids: [UUID]? = nil, initial: UUID? = nil) {
        model.reloadFromDisk()
        requestedIDs = ids
        let list = (ids ?? model.popIDs(for: mode)).filter { model.pop($0) != nil }
        guard !list.isEmpty else {
            DebugLog.log("nothing to show")
            onOpenOrganizer?(nil)
            return
        }
        popIDs = list
        let preferred = initial ?? settings.lastActivePopID
        pageIndex = preferred.flatMap { list.firstIndex(of: $0) } ?? 0
        folderStack = []
        confirmingOpenAll = false
        typeahead = ""
        preview.close()
        resolveAnchor(anchor)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        closing = false
        render(transition: nil, animateFrame: false)
        presentPanel()
        installMonitors()
        if let id = currentPopID { onActivePopChanged?(id) }
        DebugLog.log("popover shown: \(currentPop?.name ?? "?") edge=\(anchorEdge.rawValue) frame=\(NSStringFromRect(panel.frame)) items=\(entries.count)")
    }

    func close(_ reason: CloseReason) {
        guard let panel = panel, panel.isVisible, !closing else { return }
        closing = true
        removeMonitors()
        preview.close()
        lastClose = (ProcessInfo.processInfo.systemUptime, reason)
        if let id = currentPopID { model.setLastActivePop(id) }
        model.flush()
        DebugLog.log("popover closed: \(reason.rawValue)")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
                self?.closing = false
                if reason == .escape || reason == .toggle { self?.giveUpFocusIfIdle() }
            }
        })
    }

    /// After Esc, hand focus back to the previous app unless one of our windows is open.
    private func giveUpFocusIfIdle() {
        let busy = NSApp.windows.contains { w in
            w !== panel && w.isVisible && !(w is NonKeyPanel) && (w.level == .normal || w.level == .floating)
                && w.frame.width > 40
        }
        if !busy && NSApp.isActive { NSApp.hide(nil) }
    }

    private func resolveAnchor(_ anchor: Anchor) {
        switch anchor {
        case .dock(let mouse):
            let scr = NSScreen.containing(mouse)
            screen = scr
            if let scr = scr,
               let hit = DockPrefs.layout().anchor(mouse: mouse, screenFrame: scr.frame,
                                                  visibleFrame: scr.visibleFrame, gap: settings.dockGap) {
                anchorPoint = hit.point
                anchorEdge = hit.edge
            } else {
                anchorPoint = .zero
                anchorEdge = .none
            }
        case .statusItem(let rect):
            screen = NSScreen.containing(NSPoint(x: rect.midX, y: rect.midY))
            anchorPoint = CGPoint(x: rect.midX, y: rect.minY - 2)
            anchorEdge = .top
        case .centered:
            screen = NSScreen.containing(NSEvent.mouseLocation)
            anchorPoint = .zero
            anchorEdge = .none
        case .point(let point, let edge):
            screen = NSScreen.containing(point)
            anchorPoint = point
            anchorEdge = edge
        }
    }

    private func makePanel() -> PopoverPanel {
        let panel = PopoverPanel()
        panel.onResignKey = { [weak self] in self?.panelResignedKey() }
        let root = PopoverContentView(frame: NSRect(origin: .zero, size: panel.frame.size))
        root.autoresizingMask = [.width, .height]
        panel.contentView = root
        root.header.onTitleClick = { [weak self] view in self?.showSwitcher(from: view) }
        root.header.onBack = { [weak self] in self?.goBack() }
        root.footer.onPrevious = { [weak self] in self?.previousPage() }
        root.footer.onNext = { [weak self] in self?.nextPage() }
        root.footer.onGear = { [weak self] view in self?.showGearMenu(from: view) }
        root.footer.dots.onSelect = { [weak self] i in self?.goTo(page: i) }
        root.footer.onConfirm = { [weak self] in self?.performOpenAll() }
        root.footer.onCancel = { [weak self] in
            self?.confirmingOpenAll = false
            self?.refreshFooter()
        }
        self.root = root
        return panel
    }

    private func presentPanel() {
        guard let panel = panel else { return }
        let final = panel.frame
        panel.alphaValue = 0
        if !reduceMotion {
            var start = final
            switch anchorEdge {
            case .bottom: start.origin.y -= 8
            case .top: start.origin.y += 8
            case .left: start.origin.x -= 8
            case .right: start.origin.x += 8
            case .none: start.origin.y -= 6
            }
            panel.setFrame(start, display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = min(speed, 0.18)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrame(final, display: true) }
        }
    }

    // MARK: Rendering

    private func visibleBounds() -> NSRect {
        (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func pageEntries(for pop: Pop) -> [GridEntry] {
        ItemSorter.sorted(pop.items, by: pop.sortMode, name: { GridEntry.displayName(for: $0) })
            .map(GridEntry.forItem)
    }

    private func gridSpec(for pop: Pop, layout: PopLayout) -> GridSpec {
        settings.gridSpec(labelFontSize: pop.style.label.size, layout: layout)
    }

    /// Size of the largest Pop in the carousel, for "lock popover size while swiping".
    private func lockedBodyLayout(maxBody: CGSize, chrome: PopoverChrome) -> PopoverBodyLayout? {
        var best: PopoverBodyLayout?
        for id in popIDs {
            guard let pop = model.pop(id) else { continue }
            let spec = gridSpec(for: pop, layout: pop.layout)
            let m = GridLayoutEngine.metrics(count: pop.items.count, spec: spec, fixedColumns: settings.columns,
                                             maxColumns: settings.maxColumns)
            let b = GridLayoutEngine.bodyLayout(for: m, chrome: chrome, maxBodySize: maxBody)
            if let current = best {
                best = PopoverBodyLayout(size: CGSize(width: max(current.size.width, b.size.width),
                                                      height: max(current.size.height, b.size.height)),
                                         gridViewportHeight: max(current.gridViewportHeight, b.gridViewportHeight),
                                         scrolls: false)
            } else {
                best = b
            }
        }
        return best
    }

    func render(transition: CATransitionSubtype?, animateFrame: Bool) {
        guard let panel = panel, let root = root, let pop = currentPop else { return }
        let appearance = PopAppearance(style: pop.style)
        let folder = folderStack.last
        var readable = true
        if let folder = folder {
            let result = GridEntry.forFolder(folder)
            entries = result.entries
            readable = result.readable
        } else {
            entries = pageEntries(for: pop)
        }

        let layout: PopLayout = folder == nil ? pop.layout : .grid
        let spec = gridSpec(for: pop, layout: layout)
        let metrics = GridLayoutEngine.metrics(count: entries.count, spec: spec,
                                               fixedColumns: folder == nil ? settings.columns : 0,
                                               maxColumns: folder == nil ? settings.maxColumns : 6)
        let bounds = visibleBounds()
        let maxBody = PopoverGeometry.maxBodySize(anchor: anchorPoint, edge: anchorEdge, in: bounds)
        var body = GridLayoutEngine.bodyLayout(for: metrics, chrome: root.chrome, maxBodySize: maxBody)
        if folder == nil, settings.lockSizeWhileSwiping, popIDs.count > 1,
           let locked = lockedBodyLayout(maxBody: maxBody, chrome: root.chrome) {
            body = locked
        }
        let placement = PopoverGeometry.place(bodySize: body.size, anchor: anchorPoint, edge: anchorEdge, in: bounds)

        panel.appearance = appearance.nsAppearance
        root.background.edge = placement.edge
        root.background.anchorScreenPoint = anchorPoint
        root.background.apply(style: pop.style, appearance: appearance)
        let backTitle = folder.map { FileManager.default.displayName(atPath: $0.path) }
        root.header.configure(title: pop.name, backTitle: backTitle,
                              count: settings.showItemCount && folder == nil ? pop.items.count : nil,
                              canSwitch: popIDs.count > 1, appearance: appearance)
        root.footer.configure(pageIndex: pageIndex, pageCount: popIDs.count, showDots: settings.showPageDots,
                              appearance: appearance,
                              confirmText: confirmingOpenAll ? "Open all \(pop.items.count) items?" : nil)

        let grid = PopGridView()
        grid.delegate = self
        grid.allowsReordering = folder == nil
        if folder != nil {
            grid.emptyMessage = readable ? "This folder is empty" : "OpenPops can't read this folder."
        }
        grid.configure(entries: entries, metrics: metrics,
                       style: CellStyle(appearance: appearance, spec: spec, hover: settings.hoverHighlight,
                                        pressFeedback: settings.pressFeedback))

        if animateFrame && panel.isVisible && !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = speed
                ctx.allowsImplicitAnimation = true
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(placement.frame, display: true)
            }
        } else {
            panel.setFrame(placement.frame, display: panel.isVisible)
        }
        root.installPage(grid, transition: transition, duration: panel.isVisible ? speed : 0, reduceMotion: reduceMotion)
    }

    private func refreshFooter() {
        guard let root = root, let pop = currentPop else { return }
        root.footer.configure(pageIndex: pageIndex, pageCount: popIDs.count, showDots: settings.showPageDots,
                              appearance: PopAppearance(style: pop.style),
                              confirmText: confirmingOpenAll ? "Open all \(pop.items.count) items?" : nil)
    }

    /// Re-renders after the library changed (edits here, in the Organizer or in another tile).
    func libraryDidChange() {
        guard isShown, grid?.isInteracting != true else { return }
        let fresh = (requestedIDs ?? model.popIDs(for: mode)).filter { model.pop($0) != nil }
        guard !fresh.isEmpty else {
            close(.programmatic)
            return
        }
        let current = currentPopID
        popIDs = fresh
        pageIndex = current.flatMap { fresh.firstIndex(of: $0) } ?? min(pageIndex, fresh.count - 1)
        let selected = grid?.selectedIndex
        render(transition: nil, animateFrame: true)
        if let s = selected, s < entries.count { grid?.selectedIndex = s }
    }

    // MARK: Pages and folders

    func goTo(page index: Int, arrival: Arrival = .none) {
        guard popIDs.indices.contains(index), index != pageIndex || !folderStack.isEmpty else { return }
        let old = pageIndex
        pageIndex = index
        folderStack = []
        confirmingOpenAll = false
        preview.close()
        render(transition: index >= old ? .fromRight : .fromLeft, animateFrame: true)
        switch arrival {
        case .first: grid?.selectedIndex = entries.isEmpty ? nil : 0
        case .last: grid?.selectedIndex = entries.isEmpty ? nil : entries.count - 1
        case .none: break
        }
        if let id = currentPopID {
            model.setLastActivePop(id)
            onActivePopChanged?(id)
        }
    }

    func nextPage(arrival: Arrival = .none) {
        if pageIndex < popIDs.count - 1 { goTo(page: pageIndex + 1, arrival: arrival) }
    }

    func previousPage(arrival: Arrival = .none) {
        if pageIndex > 0 { goTo(page: pageIndex - 1, arrival: arrival) }
    }

    func openFolder(_ url: URL) {
        folderStack.append(url)
        confirmingOpenAll = false
        preview.close()
        render(transition: .fromRight, animateFrame: true)
        DebugLog.log("browsing folder \(url.path) (\(entries.count) entries)")
    }

    func goBack() {
        guard !folderStack.isEmpty else { return }
        folderStack.removeLast()
        preview.close()
        render(transition: .fromLeft, animateFrame: true)
    }

    // MARK: Opening things

    func activate(_ index: Int, modifiers: NSEvent.ModifierFlags) {
        guard entries.indices.contains(index), let pop = currentPop else { return }
        let entry = entries[index]
        let reveal = modifiers.contains(.command)
        switch entry.kind {
        case .item(let item):
            if entry.isMissing {
                handleMissing(item, in: pop)
                return
            }
            if reveal, let url = item.fileURL {
                Launcher.reveal([url])
                close(.launched)
                return
            }
            model.recordLaunch(itemID: item.id, popID: pop.id)
            if item.kind == .folder,
               (settings.folderClick == .browse) != modifiers.contains(.option),
               let url = item.fileURL {
                openFolder(url)
                return
            }
            DebugLog.log("activate \(entry.name)")
            Launcher.open(item)
            closeAfterLaunch()
        case .child(let url, let kind):
            if reveal {
                Launcher.reveal([url])
                close(.launched)
                return
            }
            if kind == .folder && !modifiers.contains(.option) {
                openFolder(url)
                return
            }
            DebugLog.log("activate \(entry.name)")
            if kind == .app { Launcher.openApp(url) } else { Launcher.open(url: url) }
            closeAfterLaunch()
        case .openInFinder(let url):
            Launcher.open(url: url)
            closeAfterLaunch()
        }
    }

    private func closeAfterLaunch() {
        if settings.closeAfterLaunch { close(.launched) }
    }

    func requestOpenAll() {
        guard let pop = currentPop, !pop.items.isEmpty else {
            NSSound.beep()
            return
        }
        if settings.confirmOpenAll && !confirmingOpenAll {
            confirmingOpenAll = true
            refreshFooter()
            return
        }
        performOpenAll()
    }

    private func performOpenAll() {
        guard let pop = currentPop else { return }
        confirmingOpenAll = false
        let items = pop.sortedItems()
        let popID = pop.id
        model.update { lib in
            for item in items { lib.recordLaunch(itemID: item.id, in: popID) }
        }
        close(.launched)
        Launcher.openAll(items)
    }

    private func handleMissing(_ item: PopItem, in pop: Pop) {
        close(.programmatic)
        let alert = NSAlert()
        alert.messageText = "“\(GridEntry.displayName(for: item))” can't be found"
        alert.informativeText = "It may have been moved, renamed or deleted.\n\n\(item.target)"
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Remove from Pop")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let open = NSOpenPanel()
            open.canChooseFiles = true
            open.canChooseDirectories = true
            open.allowsMultipleSelection = false
            open.prompt = "Use This"
            open.directoryURL = URL(fileURLWithPath: (item.target as NSString).deletingLastPathComponent)
            if open.runModal() == .OK, let url = open.url, let replacement = ItemFactory.item(for: url) {
                model.update { lib in
                    lib.updateItem(item.id, in: pop.id) {
                        $0.target = replacement.target
                        $0.kind = replacement.kind
                    }
                }
            }
        case .alertSecondButtonReturn:
            model.update { $0.removeItem(item.id, from: pop.id) }
        default:
            break
        }
    }

    // MARK: Adding

    func addFiles(to popID: UUID) {
        close(.programmatic)
        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = true
        open.allowsMultipleSelection = true
        open.prompt = "Add"
        open.message = "Choose apps, files or folders to add to “\(model.pop(popID)?.name ?? "the Pop")”."
        NSApp.activate()
        if open.runModal() == .OK {
            model.add(urls: open.urls, to: popID)
        }
    }

    func addLink(to popID: UUID) {
        close(.programmatic)
        let alert = NSAlert()
        alert.messageText = "Add a Link"
        alert.informativeText = "Paste a web address. Any link a Mac app understands works too (for example obsidian:// or zoommtg://)."
        let urlField = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        urlField.placeholderString = "https://"
        if let clip = NSPasteboard.general.string(forType: .string), let u = URL(string: clip), u.scheme != nil, !u.isFileURL {
            urlField.stringValue = clip
        }
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        nameField.placeholderString = "Name (optional)"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
        box.addSubview(urlField)
        box.addSubview(nameField)
        alert.accessoryView = box
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = urlField
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") && !raw.hasPrefix("mailto:") && raw.contains(".") { raw = "https://" + raw }
        guard let url = URL(string: raw), url.scheme != nil else {
            NSSound.beep()
            return
        }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        model.add(urls: [url], titles: name.isEmpty ? [:] : [url: name], to: popID)
    }

    private func rename(_ item: PopItem, in pop: Pop) {
        close(.programmatic)
        let alert = NSAlert()
        alert.messageText = "Rename “\(GridEntry.displayName(for: item))”"
        alert.informativeText = "Changes the label in the Pop only. Leave it empty to use the original name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = item.customName ?? ""
        field.placeholderString = item.defaultName
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        model.update { lib in
            lib.updateItem(item.id, in: pop.id) { $0.customName = name.isEmpty ? nil : name }
        }
    }

    // MARK: Menus

    private func showSwitcher(from view: NSView) {
        guard popIDs.count > 1 else { return }
        let menu = NSMenu()
        for (i, id) in popIDs.enumerated() {
            guard let pop = model.pop(id) else { continue }
            let item = ClosureMenuItem(pop.name, key: i < 9 ? "\(i + 1)" : "") { [weak self] in
                self?.goTo(page: i)
            }
            item.keyEquivalentModifierMask = .command
            item.state = i == pageIndex ? .on : .off
            let icon = DockIconRenderer.image(for: pop, pixels: 64)
            icon.size = NSSize(width: 18, height: 18)
            item.image = icon
            menu.addItem(item)
        }
        _ = menu.popUp(positioning: menu.item(at: pageIndex), at: NSPoint(x: 0, y: view.bounds.height - 2), in: view)
    }

    private func showGearMenu(from view: NSView) {
        guard let pop = currentPop else { return }
        let popID = pop.id
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open All (\(pop.items.count))", symbol: "square.stack.3d.up",
                                     enabled: !pop.items.isEmpty) { [weak self] in self?.requestOpenAll() })
        menu.addItem(ClosureMenuItem("Pop Out", symbol: "macwindow.on.rectangle") { [weak self] in
            self?.close(.programmatic)
            self?.onPopOut?(popID)
        })
        menu.addSubmenu("Sort By", symbol: "arrow.up.arrow.down") { sub in
            for sortMode in SortMode.allCases {
                let item = ClosureMenuItem(sortMode.title) { [weak self] in
                    self?.model.update { $0.updatePop(popID) { $0.sortMode = sortMode } }
                    self?.render(transition: nil, animateFrame: false)
                }
                item.state = pop.sortMode == sortMode ? .on : .off
                sub.addItem(item)
            }
        }
        menu.addSubmenu("Layout", symbol: "square.grid.2x2") { sub in
            for layout in PopLayout.allCases {
                let item = ClosureMenuItem(layout.title) { [weak self] in
                    self?.model.update { $0.updatePop(popID) { $0.layout = layout } }
                    self?.render(transition: nil, animateFrame: true)
                }
                item.state = pop.layout == layout ? .on : .off
                sub.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Add Apps, Files or Folders…", symbol: "plus") { [weak self] in
            self?.addFiles(to: popID)
        })
        menu.addItem(ClosureMenuItem("Add Link…", symbol: "link") { [weak self] in self?.addLink(to: popID) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Edit “\(pop.name)”…", symbol: "slider.horizontal.3") { [weak self] in
            self?.close(.programmatic)
            self?.onOpenOrganizer?(popID)
        })
        menu.addItem(ClosureMenuItem("Open Organizer…", symbol: "gearshape") { [weak self] in
            self?.close(.programmatic)
            self?.onOpenOrganizer?(nil)
        })
        if mode.isMain {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Quit OpenPops") { NSApp.terminate(nil) })
        }
        _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private func contextMenu(for index: Int) -> NSMenu? {
        guard entries.indices.contains(index), let pop = currentPop else { return nil }
        grid?.selectedIndex = index
        let entry = entries[index]
        let popID = pop.id
        let menu = NSMenu()
        switch entry.kind {
        case .item(let item):
            menu.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { [weak self] in
                self?.activate(index, modifiers: [])
            })
            if item.kind == .folder, let url = item.fileURL {
                menu.addItem(ClosureMenuItem("Open in Finder", symbol: "folder") { [weak self] in
                    Launcher.open(url: url)
                    self?.closeAfterLaunch()
                })
            }
            if let url = item.fileURL, !entry.isMissing {
                menu.addItem(ClosureMenuItem("Show in Finder", symbol: "magnifyingglass") { [weak self] in
                    Launcher.reveal([url])
                    self?.close(.launched)
                })
                menu.addItem(ClosureMenuItem("Quick Look", symbol: "eye") { [weak self] in self?.toggleQuickLook() })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Rename…", symbol: "pencil") { [weak self] in self?.rename(item, in: pop) })
            let others = model.library.pops.filter { $0.id != popID }
            if !others.isEmpty {
                menu.addSubmenu("Move to", symbol: "arrow.right.square") { sub in
                    for other in others {
                        sub.addItem(ClosureMenuItem(other.name) { [weak self] in
                            self?.model.update { $0.moveItem(item.id, from: popID, to: other.id) }
                            self?.render(transition: nil, animateFrame: true)
                        })
                    }
                }
            }
            menu.addItem(ClosureMenuItem(item.kind == .link ? "Copy Link" : "Copy Path", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.target, forType: .string)
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Remove from “\(pop.name)”", symbol: "minus.circle") { [weak self] in
                self?.model.update { $0.removeItem(item.id, from: popID) }
                self?.render(transition: nil, animateFrame: true)
            })
        case .child(let url, let kind):
            menu.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { [weak self] in
                self?.activate(index, modifiers: kind == .folder ? [.option] : [])
            })
            if kind == .folder {
                menu.addItem(ClosureMenuItem("Browse", symbol: "folder") { [weak self] in self?.openFolder(url) })
            }
            menu.addItem(ClosureMenuItem("Show in Finder", symbol: "magnifyingglass") { [weak self] in
                Launcher.reveal([url])
                self?.close(.launched)
            })
            menu.addItem(ClosureMenuItem("Quick Look", symbol: "eye") { [weak self] in self?.toggleQuickLook() })
            menu.addItem(.separator())
            menu.addSubmenu("Add to Pop", symbol: "plus.square.on.square") { sub in
                for p in model.library.pops {
                    sub.addItem(ClosureMenuItem(p.name) { [weak self] in
                        self?.model.add(urls: [url], to: p.id)
                    })
                }
            }
            menu.addItem(ClosureMenuItem("Copy Path", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            })
        case .openInFinder:
            return nil
        }
        return menu
    }

    // MARK: Keyboard

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isShown, let panel = panel, panel.isKeyWindow else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        switch Int(event.keyCode) {
        case 53: // Esc
            escape()
            return true
        case 123: // Left
            if command { previousPage() } else { moveSelection(dx: -1, dy: 0) }
            return true
        case 124: // Right
            if command { nextPage() } else { moveSelection(dx: 1, dy: 0) }
            return true
        case 125: // Down
            moveSelection(dx: 0, dy: 1)
            return true
        case 126: // Up
            moveSelection(dx: 0, dy: -1)
            return true
        case 36, 76: // Return, Enter
            if confirmingOpenAll {
                performOpenAll()
            } else if let i = grid?.selectedIndex {
                activate(i, modifiers: flags)
            }
            return true
        case 49: // Space
            toggleQuickLook()
            return true
        case 48: // Tab
            if flags.contains(.shift) { previousPage(arrival: .first) } else { nextPage(arrival: .first) }
            return true
        case 51, 117: // Delete
            if command {
                removeSelected()
                return true
            }
        default:
            break
        }
        if command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case ",":
                close(.programmatic)
                onOpenOrganizer?(currentPopID)
                return true
            case "w":
                close(.escape)
                return true
            case "o":
                if let i = grid?.selectedIndex { activate(i, modifiers: []) }
                return true
            case "r":
                if let i = grid?.selectedIndex, entries.indices.contains(i), let url = entries[i].fileURL {
                    Launcher.reveal([url])
                    close(.launched)
                }
                return true
            case "[":
                previousPage()
                return true
            case "]":
                nextPage()
                return true
            default:
                if let n = Int(chars), (1...9).contains(n) {
                    goTo(page: n - 1)
                    return true
                }
                return false
            }
        }
        let plain = flags.subtracting([.shift, .capsLock, .numericPad, .function]).isEmpty
        if plain, let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || CharacterSet.punctuationCharacters.contains($0) }) {
            typeToSelect(chars)
            return true
        }
        return false
    }

    private func escape() {
        if preview.isShown {
            preview.close()
        } else if confirmingOpenAll {
            confirmingOpenAll = false
            refreshFooter()
        } else if !folderStack.isEmpty {
            goBack()
        } else {
            close(.escape)
        }
    }

    private func moveSelection(dx: Int, dy: Int) {
        guard let grid = grid else { return }
        let count = entries.count
        guard count > 0 else {
            if dx > 0 { nextPage() } else if dx < 0 { previousPage() }
            return
        }
        guard let current = grid.selectedIndex else {
            grid.selectedIndex = (dx < 0 || dy < 0) ? count - 1 : 0
            syncPreview()
            return
        }
        if let next = grid.metrics.neighbor(of: current, dx: dx, dy: dy, count: count) {
            grid.selectedIndex = next
            syncPreview()
        } else if dx != 0, folderStack.isEmpty, popIDs.count > 1 {
            // At the left or right edge, continue into the neighboring Pop.
            if dx > 0 { nextPage(arrival: .first) } else { previousPage(arrival: .last) }
        }
    }

    private func typeToSelect(_ chars: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - typeaheadTime > 1.0 { typeahead = "" }
        typeaheadTime = now
        typeahead += chars.lowercased()
        let match = entries.firstIndex { $0.name.lowercased().hasPrefix(typeahead) }
            ?? entries.firstIndex { $0.name.lowercased().contains(typeahead) }
        if let i = match {
            grid?.selectedIndex = i
            syncPreview()
        } else {
            NSSound.beep()
        }
    }

    private func removeSelected() {
        guard let pop = currentPop, let i = grid?.selectedIndex, entries.indices.contains(i),
              let item = entries[i].popItem else { return }
        model.update { $0.removeItem(item.id, from: pop.id) }
        render(transition: nil, animateFrame: true)
        if !entries.isEmpty { grid?.selectedIndex = min(i, entries.count - 1) }
    }

    func toggleQuickLook() {
        guard let panel = panel, let grid = grid else { return }
        guard let i = grid.selectedIndex ?? grid.hoverIndex, entries.indices.contains(i),
              entries[i].isPreviewable, let url = entries[i].fileURL else {
            if preview.isShown { preview.close() } else { NSSound.beep() }
            return
        }
        grid.selectedIndex = i
        preview.toggle(url, beside: panel.frame, appearance: panel.appearance)
    }

    private func syncPreview() {
        guard preview.isShown, let i = grid?.selectedIndex, entries.indices.contains(i),
              entries[i].isPreviewable, let url = entries[i].fileURL else { return }
        preview.update(url)
    }

    // MARK: Swipes

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard isShown, let panel = panel, event.window === panel, popIDs.count > 1, folderStack.isEmpty else {
            return false
        }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            if !event.momentumPhase.isEmpty { return lastGestureHorizontal }
            if event.phase.contains(.began) {
                swipeAccumulator = 0
                swipeFired = false
                gestureHorizontal = nil
            }
            if event.phase.contains(.began) || event.phase.contains(.changed) {
                if gestureHorizontal == nil && (abs(dx) > 0.3 || abs(dy) > 0.3) {
                    gestureHorizontal = abs(dx) > abs(dy) * 1.2
                }
                guard gestureHorizontal == true else { return false }
                // Positive when the fingers move right, whatever the scroll direction setting.
                let finger = event.isDirectionInvertedFromDevice ? dx : -dx
                swipeAccumulator += finger
                if !swipeFired && abs(swipeAccumulator) > 40 {
                    swipeFired = true
                    if swipeAccumulator < 0 { nextPage() } else { previousPage() }
                }
                return true
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                lastGestureHorizontal = gestureHorizontal == true
                gestureHorizontal = nil
                return lastGestureHorizontal
            }
            return false
        }
        // Mouse wheels: horizontal wheel or Shift + scroll.
        guard dx != 0, abs(dx) >= abs(dy) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastWheelPage > 0.35 {
            lastWheelPage = now
            if dx < 0 { nextPage() } else { previousPage() }
        }
        return true
    }

    // MARK: Event monitors

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self = self else { return event }
            return MainActor.assumeIsolated { self.handleKeyDown(event) } ? nil : event
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self = self else { return event }
            return MainActor.assumeIsolated { self.handleScroll(event) } ? nil : event
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                     handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close(.outsideClick) }
        }) {
            monitors.append(m)
        }
        sessionObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.isShown, !(self.panel?.isKeyWindow ?? false) else { return }
                self.close(.resignActive)
            }
        })
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sessionObservers.removeAll()
    }

    private func panelResignedKey() {
        guard isShown else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard let self = self, self.isShown, let panel = self.panel else { return }
            if panel.isKeyWindow || self.menuTracking || NSApp.modalWindow != nil { return }
            if let key = NSApp.keyWindow, key is NonKeyPanel { return }
            self.close(.resignKey)
        }
    }
}

extension PopoverController: PopGridViewDelegate {
    func grid(_ grid: PopGridView, activate index: Int, modifiers: NSEvent.ModifierFlags) {
        activate(index, modifiers: modifiers)
    }

    func grid(_ grid: PopGridView, menuFor index: Int) -> NSMenu? {
        contextMenu(for: index)
    }

    func grid(_ grid: PopGridView, didReorder order: [Int]) {
        guard let pop = currentPop, folderStack.isEmpty else { return }
        let ids = order.compactMap { entries.indices.contains($0) ? entries[$0].popItem?.id : nil }
        model.reorder(popID: pop.id, displayedIDs: ids)
        render(transition: nil, animateFrame: false)
    }

    func grid(_ grid: PopGridView, didDragOut index: Int) {
        guard let pop = currentPop, entries.indices.contains(index), let item = entries[index].popItem else { return }
        model.update { $0.removeItem(item.id, from: pop.id) }
        render(transition: nil, animateFrame: true)
    }

    func grid(_ grid: PopGridView, didDrop urls: [URL], titles: [URL: String], at slot: Int) {
        guard let pop = currentPop, folderStack.isEmpty else { return }
        // Position only matters when the Pop is ordered by hand.
        let index = pop.sortMode == .manual ? slot : nil
        let added = model.add(urls: urls, titles: titles, to: pop.id, at: index)
        DebugLog.log("dropped \(urls.count) item(s) on \(pop.name), \(added) new")
        if added == 0 { NSSound.beep() }
        render(transition: nil, animateFrame: true)
    }

    func gridAcceptsDrops(_ grid: PopGridView) -> Bool {
        currentPop != nil && folderStack.isEmpty
    }

    func gridHoverChanged(_ grid: PopGridView) {}
}
