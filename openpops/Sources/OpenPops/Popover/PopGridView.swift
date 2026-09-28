import AppKit
import OpenPopsCore

@MainActor
protocol PopGridViewDelegate: AnyObject {
    func grid(_ grid: PopGridView, activate index: Int, modifiers: NSEvent.ModifierFlags)
    func grid(_ grid: PopGridView, menuFor index: Int) -> NSMenu?
    /// The user dragged a cell to a new position. `order` lists entry indices in their new order.
    func grid(_ grid: PopGridView, didReorder order: [Int])
    /// The user dragged a cell out of the window to remove it.
    func grid(_ grid: PopGridView, didDragOut index: Int)
    func grid(_ grid: PopGridView, didDrop urls: [URL], titles: [URL: String], at slot: Int)
    func gridAcceptsDrops(_ grid: PopGridView) -> Bool
    func gridHoverChanged(_ grid: PopGridView)
}

/// The grid of items inside a popover or Pop Out window. Handles hover, press feedback,
/// keyboard selection, drag to reorder, drag out to remove, and drops from Finder.
final class PopGridView: NSView {
    weak var delegate: PopGridViewDelegate?

    private(set) var entries: [GridEntry] = []
    private(set) var metrics = GridLayoutEngine.metrics(count: 0, spec: GridSpec())
    private var cells: [ItemCellView] = []
    private var style: CellStyle?
    /// Reordering and drag-out only make sense for a Pop's own items (not folder contents).
    var allowsReordering = true
    var emptyMessage = "Drag apps, files or folders here"

    var selectedIndex: Int? {
        didSet {
            for (i, c) in cells.enumerated() { c.isSelected = i == selectedIndex }
            if let i = selectedIndex, cells.indices.contains(i) {
                cells[i].scrollToVisible(cells[i].bounds.insetBy(dx: 0, dy: -8))
            }
        }
    }
    private(set) var hoverIndex: Int? {
        didSet {
            guard hoverIndex != oldValue else { return }
            for (i, c) in cells.enumerated() { c.isHovered = i == hoverIndex }
            delegate?.gridHoverChanged(self)
        }
    }

    // Drag state
    private var pressIndex: Int?
    private var pressPoint = NSPoint.zero
    private var dragIndex: Int?
    private var dragTarget: Int?
    private var dragOutside = false
    private var dragWindow: NSWindow?
    private var dragOffset = NSPoint.zero
    private var dropSlot: Int?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    /// True while a cell is being dragged or something is being dropped.
    var isInteracting: Bool { dragIndex != nil || dropSlot != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL])
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(entries: [GridEntry], metrics: GridMetrics, style: CellStyle) {
        self.entries = entries
        self.metrics = metrics
        self.style = style
        cells.forEach { $0.removeFromSuperview() }
        let size = CGFloat(style.spec.iconSize)
        cells = entries.enumerated().map { index, entry in
            let cell = ItemCellView(entry: entry, icon: icon(for: entry), style: style)
            cell.frame = metrics.frame(at: index)
            addSubview(cell)
            if let path = entry.path, !entry.isMissing {
                IconProvider.shared.thumbnail(forPath: path, size: size) { [weak cell] image in
                    guard let cell = cell, cell.entry.path == path else { return }
                    cell.setIcon(image)
                }
            }
            return cell
        }
        let content = metrics.contentSize
        setFrameSize(NSSize(width: content.width, height: content.height))
        if let s = selectedIndex, s >= entries.count { selectedIndex = nil }
        hoverIndex = nil
        needsDisplay = true
    }

    private func icon(for entry: GridEntry) -> NSImage {
        switch entry.kind {
        case .item(let item):
            if let path = entry.path, let t = IconProvider.shared.cachedThumbnail(forPath: path) { return t }
            return IconProvider.shared.icon(for: item)
        case .child(let url, _):
            return IconProvider.shared.cachedThumbnail(forPath: url.path) ?? IconProvider.shared.icon(forPath: url.path)
        case .openInFinder:
            return IconProvider.shared.icon(forPath: "/System/Library/CoreServices/Finder.app")
        }
    }

    func cellFrame(at index: Int) -> NSRect? {
        cells.indices.contains(index) ? cells[index].frame : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard entries.isEmpty, let style = style else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: style.appearance.secondaryColor,
            .paragraphStyle: para,
        ]
        let text = emptyMessage as NSString
        let rect = bounds.insetBy(dx: 12, dy: 0)
        let height = text.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin], attributes: attrs).height
        text.draw(with: NSRect(x: rect.minX, y: bounds.midY - height / 2, width: rect.width, height: height),
                  options: [.usesLineFragmentOrigin], attributes: attrs)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        guard dragIndex == nil else { return }
        hoverIndex = metrics.index(at: convert(event.locationInWindow, from: nil), count: entries.count)
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Clicks and drag to reorder

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressPoint = p
        pressIndex = metrics.index(at: p, count: entries.count)
        if let i = pressIndex { cells[i].setPressed(true) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let i = pressIndex else { return }
        let p = convert(event.locationInWindow, from: nil)
        if dragIndex == nil {
            guard allowsReordering, hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 5 else { return }
            beginDrag(i)
        }
        continueDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        if let d = dragIndex {
            finishDrag(d)
            return
        }
        guard let i = pressIndex else { return }
        pressIndex = nil
        if cells.indices.contains(i) { cells[i].setPressed(false) }
        let p = convert(event.locationInWindow, from: nil)
        if metrics.index(at: p, count: entries.count) == i {
            delegate?.grid(self, activate: i, modifiers: event.modifierFlags)
        }
    }

    private func beginDrag(_ index: Int) {
        guard let window = window, cells.indices.contains(index) else { return }
        let cell = cells[index]
        cell.setPressed(false)
        dragIndex = index
        dragTarget = index
        dragOutside = false
        hoverIndex = nil

        let rectInWindow = cell.convert(cell.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        let image = cell.snapshotImage()
        cell.isHidden = true

        let panel = NSPanel(contentRect: screenRect, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: screenRect.size))
        imageView.image = image
        imageView.alphaValue = 0.92
        panel.contentView = imageView
        panel.orderFrontRegardless()
        dragWindow = panel

        let mouse = NSEvent.mouseLocation
        dragOffset = NSPoint(x: mouse.x - screenRect.minX, y: mouse.y - screenRect.minY)
    }

    private func continueDrag(_ event: NSEvent) {
        guard dragIndex != nil else { return }
        let mouse = NSEvent.mouseLocation
        dragWindow?.setFrameOrigin(NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y))
        let outside = !(window?.frame.contains(mouse) ?? true)
        if outside != dragOutside {
            dragOutside = outside
            (outside ? NSCursor.disappearingItem : NSCursor.arrow).set()
            dragWindow?.animator().alphaValue = outside ? 0.55 : 1
            layoutCells(animated: true)
        }
        guard !outside else { return }
        let p = convert(event.locationInWindow, from: nil)
        let slot = metrics.slotIndex(at: p, maxIndex: entries.count - 1)
        if slot != dragTarget {
            dragTarget = slot
            layoutCells(animated: true)
        }
    }

    private func finishDrag(_ index: Int) {
        let outside = dragOutside
        let target = dragTarget ?? index
        dragWindow?.orderOut(nil)
        dragWindow = nil
        dragIndex = nil
        dragTarget = nil
        dragOutside = false
        pressIndex = nil
        NSCursor.arrow.set()
        if cells.indices.contains(index) { cells[index].isHidden = false }

        if outside {
            NSAnimationEffect.poof.show(centeredAt: NSEvent.mouseLocation, size: NSSize(width: 48, height: 48),
                                        completionHandler: {})
            delegate?.grid(self, didDragOut: index)
        } else if target != index {
            var order = Array(entries.indices)
            order.remove(at: index)
            order.insert(index, at: min(target, order.count))
            delegate?.grid(self, didReorder: order)
        } else {
            layoutCells(animated: true)
        }
    }

    /// Positions cells, leaving room for a dragged cell or an incoming drop.
    private func layoutCells(animated: Bool) {
        var order = Array(entries.indices)
        if let d = dragIndex {
            order.removeAll { $0 == d }
            if !dragOutside, let t = dragTarget { order.insert(d, at: min(t, order.count)) }
        }
        var frames: [(ItemCellView, NSRect)] = []
        for (k, index) in order.enumerated() {
            var slot = k
            if let gap = dropSlot, k >= gap { slot += 1 }
            frames.append((cells[index], metrics.frame(at: slot)))
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.18 : 0
            ctx.allowsImplicitAnimation = animated
            for (cell, frame) in frames {
                if animated { cell.animator().frame = frame } else { cell.frame = frame }
            }
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = metrics.index(at: p, count: entries.count) else { return nil }
        return delegate?.grid(self, menuFor: i)
    }

    // MARK: Drops from Finder and browsers

    private func droppedURLs(_ info: NSDraggingInfo) -> (urls: [URL], titles: [URL: String]) {
        let pb = info.draggingPasteboard
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        var titles: [URL: String] = [:]
        if urls.count == 1, !urls[0].isFileURL,
           let title = pb.string(forType: NSPasteboard.PasteboardType("public.url-name")) {
            titles[urls[0]] = title
        }
        return (urls, titles)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard delegate?.gridAcceptsDrops(self) == true, !droppedURLs(sender).urls.isEmpty else { return [] }
        let p = convert(sender.draggingLocation, from: nil)
        let slot = metrics.slotIndex(at: p, maxIndex: entries.count)
        if slot != dropSlot {
            dropSlot = slot
            layoutCells(animated: true)
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropSlot()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearDropSlot()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = droppedURLs(sender)
        let slot = dropSlot ?? entries.count
        clearDropSlot()
        guard !dropped.urls.isEmpty else { return false }
        delegate?.grid(self, didDrop: dropped.urls, titles: dropped.titles, at: slot)
        return true
    }

    private func clearDropSlot() {
        guard dropSlot != nil else { return }
        dropSlot = nil
        layoutCells(animated: true)
    }
}
