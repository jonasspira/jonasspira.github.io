import AppKit
import OpenPopsCore

/// Borderless floating panel that can take keyboard focus without activating the app,
/// the same way Spotlight-style panels work.
final class PopoverPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        worksWhenModal = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// Everything inside the popover: background shape, header, paged grid and footer.
final class PopoverContentView: NSView {
    let background = PopBackgroundView()
    let bodyView = NSView()
    let header = PopHeaderView()
    let footer = PopFooterView()
    let pageContainer = NSView()
    private(set) var scrollView: NSScrollView?
    private(set) var grid: PopGridView?
    var chrome = PopoverChrome()
    private var gridContentSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(background)
        addSubview(bodyView)
        bodyView.addSubview(header)
        bodyView.addSubview(pageContainer)
        bodyView.addSubview(footer)
        pageContainer.wantsLayer = true
        pageContainer.layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Swaps in a new grid, optionally sliding it in from one side.
    func installPage(_ grid: PopGridView, transition: CATransitionSubtype?, duration: Double, reduceMotion: Bool) {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .allowed
        scroll.borderType = .noBorder
        scroll.documentView = grid
        gridContentSize = grid.frame.size

        if let subtype = transition, duration > 0 {
            let t = CATransition()
            t.type = reduceMotion ? .fade : .push
            t.subtype = subtype
            t.duration = duration
            t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pageContainer.layer?.add(t, forKey: "page")
        }
        scrollView?.removeFromSuperview()
        pageContainer.addSubview(scroll)
        scrollView = scroll
        self.grid = grid
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        let body = background.bodyRect
        bodyView.frame = body
        let w = body.width, h = body.height
        header.frame = NSRect(x: 0, y: h - CGFloat(chrome.headerHeight), width: w, height: CGFloat(chrome.headerHeight))
        footer.frame = NSRect(x: 0, y: 0, width: w, height: CGFloat(chrome.footerHeight))
        let pageY = CGFloat(chrome.footerHeight + chrome.gridBottomPadding)
        let pageH = max(0, h - CGFloat(chrome.verticalChrome))
        pageContainer.frame = NSRect(x: 0, y: pageY, width: w, height: pageH)
        if let scroll = scrollView {
            let needsScroll = gridContentSize.height > pageH + 0.5
            let width = min(gridContentSize.width + (needsScroll ? 10 : 0), w)
            scroll.frame = NSRect(x: ((w - width) / 2).rounded(), y: 0, width: width, height: pageH)
        }
    }
}
