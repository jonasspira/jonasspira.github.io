import AppKit
import OpenPopsCore

/// A Pop in its own floating, always-on-top window. Items launch without closing it.
@MainActor
final class PopOutWindow: NSObject, NSWindowDelegate, PopGridViewDelegate {
    let popID: UUID
    private let model: AppModel
    private let panel: NSPanel
    private let background = PopBackgroundView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let grid = PopGridView()
    private var entries: [GridEntry] = []
    var onClose: ((UUID) -> Void)?
    var onOpenOrganizer: ((UUID) -> Void)?

    init(popID: UUID, model: AppModel) {
        self.popID = popID
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 200, height: 160)
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let content = NSView()
        content.wantsLayer = true
        panel.contentView = content
        background.edge = .none
        background.frame = content.bounds
        background.autoresizingMask = [.width, .height]
        content.addSubview(background)

        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 70, y: content.bounds.height - 28, width: content.bounds.width - 140, height: 18)
        titleLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(titleLabel)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = grid
        scroll.frame = NSRect(x: 8, y: 8, width: content.bounds.width - 16, height: content.bounds.height - 44)
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)
        grid.delegate = self

        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSWindow.didResizeNotification,
                                               object: panel)
    }

    func show() {
        render()
        let key = popID.uuidString
        if let saved = model.library.settings.popOutFrames[key] {
            let r = NSRectFromString(saved)
            if r.width > 100 && NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) {
                panel.setFrame(r, display: false)
            } else {
                panel.center()
            }
        } else {
            panel.setContentSize(idealSize())
            panel.center()
        }
        panel.orderFrontRegardless()
        render()
        model.update { lib in
            if !lib.settings.openPopOuts.contains(self.popID) { lib.settings.openPopOuts.append(self.popID) }
        }
    }

    func close() {
        panel.close()
    }

    func bringToFront() {
        panel.orderFrontRegardless()
    }

    private func idealSize() -> NSSize {
        guard let pop = model.pop(popID) else { return NSSize(width: 360, height: 320) }
        let spec = model.library.settings.gridSpec(labelFontSize: pop.style.label.size, layout: pop.layout)
        let m = GridLayoutEngine.metrics(count: pop.items.count, spec: spec, fixedColumns: model.library.settings.columns,
                                         maxColumns: model.library.settings.maxColumns)
        let s = m.contentSize
        return NSSize(width: min(max(s.width + 16, 220), 900), height: min(max(s.height + 52, 160), 700))
    }

    @objc private func resized() {
        render()
    }

    func render() {
        guard let pop = model.pop(popID) else {
            close()
            return
        }
        let appearance = PopAppearance(style: pop.style)
        panel.appearance = appearance.nsAppearance
        background.apply(style: pop.style, appearance: appearance)
        titleLabel.stringValue = pop.name
        titleLabel.font = appearance.titleFont
        titleLabel.textColor = appearance.labelColor
        panel.title = pop.name

        entries = ItemSorter.sorted(pop.items, by: pop.sortMode, name: { GridEntry.displayName(for: $0) })
            .map(GridEntry.forItem)
        let settings = model.library.settings
        let spec = settings.gridSpec(labelFontSize: pop.style.label.size, layout: pop.layout)
        // Fit as many columns as the window is wide.
        let cell = GridLayoutEngine.cellSize(for: spec)
        let spacing = pop.layout == .list ? 2.0 : spec.spacing
        let width = Double(max(scroll.contentSize.width, 100))
        let columns = max(1, Int((width + spacing) / (Double(cell.width) + spacing)))
        let metrics = GridLayoutEngine.metrics(count: entries.count, spec: spec, fixedColumns: columns, maxColumns: columns)
        grid.configure(entries: entries, metrics: metrics,
                       style: CellStyle(appearance: appearance, spec: spec, hover: settings.hoverHighlight,
                                        pressFeedback: settings.pressFeedback))
        // Center the grid horizontally in the window.
        let gridWidth = CGFloat(metrics.contentSize.width)
        let inset = max(0, (scroll.contentSize.width - gridWidth) / 2)
        scroll.contentInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: 0)
    }

    func windowWillClose(_ notification: Notification) {
        let id = popID
        let frame = NSStringFromRect(panel.frame)
        model.update { lib in
            lib.settings.popOutFrames[id.uuidString] = frame
            lib.settings.openPopOuts.removeAll { $0 == id }
        }
        onClose?(id)
    }

    func windowDidMove(_ notification: Notification) {
        let id = popID
        let frame = NSStringFromRect(panel.frame)
        model.update { $0.settings.popOutFrames[id.uuidString] = frame }
    }

    // MARK: PopGridViewDelegate

    func grid(_ grid: PopGridView, activate index: Int, modifiers: NSEvent.ModifierFlags) {
        guard entries.indices.contains(index), let item = entries[index].popItem else { return }
        if entries[index].isMissing {
            NSSound.beep()
            return
        }
        if modifiers.contains(.command), let url = item.fileURL {
            Launcher.reveal([url])
            return
        }
        model.recordLaunch(itemID: item.id, popID: popID)
        Launcher.open(item)
    }

    func grid(_ grid: PopGridView, menuFor index: Int) -> NSMenu? {
        guard entries.indices.contains(index), let item = entries[index].popItem else { return nil }
        let popID = self.popID
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { [weak self] in
            self?.grid(grid, activate: index, modifiers: [])
        })
        if let url = item.fileURL {
            menu.addItem(ClosureMenuItem("Show in Finder", symbol: "magnifyingglass") { Launcher.reveal([url]) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Remove from Pop", symbol: "minus.circle") { [weak self] in
            self?.model.update { $0.removeItem(item.id, from: popID) }
            self?.render()
        })
        menu.addItem(ClosureMenuItem("Edit Pop…", symbol: "slider.horizontal.3") { [weak self] in
            self?.onOpenOrganizer?(popID)
        })
        return menu
    }

    func grid(_ grid: PopGridView, didReorder order: [Int]) {
        let ids = order.compactMap { entries.indices.contains($0) ? entries[$0].popItem?.id : nil }
        model.reorder(popID: popID, displayedIDs: ids)
        render()
    }

    func grid(_ grid: PopGridView, didDragOut index: Int) {
        guard entries.indices.contains(index), let item = entries[index].popItem else { return }
        let popID = self.popID
        model.update { $0.removeItem(item.id, from: popID) }
        render()
    }

    func grid(_ grid: PopGridView, didDrop urls: [URL], titles: [URL: String], at slot: Int) {
        let manual = model.pop(popID)?.sortMode == .manual
        model.add(urls: urls, titles: titles, to: popID, at: manual ? slot : nil)
        render()
    }

    func gridAcceptsDrops(_ grid: PopGridView) -> Bool { true }

    func gridHoverChanged(_ grid: PopGridView) {}
}

/// Keeps track of open Pop Out windows.
@MainActor
final class PopOutManager {
    private let model: AppModel
    private var windows: [UUID: PopOutWindow] = [:]
    var onOpenOrganizer: ((UUID) -> Void)?

    init(model: AppModel) {
        self.model = model
    }

    func open(_ popID: UUID) {
        if let existing = windows[popID] {
            existing.bringToFront()
            return
        }
        let window = PopOutWindow(popID: popID, model: model)
        window.onClose = { [weak self] id in self?.windows[id] = nil }
        window.onOpenOrganizer = { [weak self] id in self?.onOpenOrganizer?(id) }
        windows[popID] = window
        window.show()
    }

    func refreshAll() {
        for (id, window) in windows {
            if model.pop(id) == nil {
                window.close()
            } else {
                window.render()
            }
        }
    }

    /// Reopens Pop Outs that were open when the app last quit.
    func restore(allowed: [UUID]) {
        for id in model.library.settings.openPopOuts where allowed.contains(id) && model.pop(id) != nil {
            open(id)
        }
    }

    var isEmpty: Bool { windows.isEmpty }
}
