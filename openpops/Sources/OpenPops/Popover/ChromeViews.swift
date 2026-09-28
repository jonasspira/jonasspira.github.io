import AppKit
import OpenPopsCore

/// Title row: the Pop's name (click to jump to another Pop) or a back button while browsing a folder.
final class PopHeaderView: NSView {
    private let titleButton = NSButton(title: "", target: nil, action: nil)
    private let backButton = NSButton(title: "", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")

    var onTitleClick: ((NSView) -> Void)?
    var onBack: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for b in [titleButton, backButton] {
            b.isBordered = false
            b.bezelStyle = .inline
            b.setButtonType(.momentaryChange)
            b.focusRingType = .none
            addSubview(b)
        }
        titleButton.target = self
        titleButton.action = #selector(titleClicked)
        titleButton.imagePosition = .imageTrailing
        titleButton.imageHugsTitle = true
        backButton.target = self
        backButton.action = #selector(backClicked)
        backButton.imagePosition = .imageLeading
        backButton.imageHugsTitle = true
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        backButton.toolTip = "Back (Esc)"
        countLabel.alignment = .right
        addSubview(countLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String, backTitle: String?, count: Int?, canSwitch: Bool, appearance: PopAppearance) {
        let attrs: [NSAttributedString.Key: Any] = [.font: appearance.titleFont, .foregroundColor: appearance.labelColor]
        if let back = backTitle {
            backButton.isHidden = false
            backButton.attributedTitle = NSAttributedString(string: " " + back, attributes: attrs)
            backButton.contentTintColor = appearance.labelColor
            titleButton.isHidden = true
        } else {
            backButton.isHidden = true
            titleButton.isHidden = false
            titleButton.attributedTitle = NSAttributedString(string: title, attributes: attrs)
            titleButton.image = canSwitch
                ? NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Switch Pop")?
                    .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
                : nil
            titleButton.contentTintColor = appearance.secondaryColor
            titleButton.toolTip = canSwitch ? "Jump to another Pop" : nil
        }
        if let count = count {
            countLabel.isHidden = false
            countLabel.stringValue = "\(count)"
            countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            countLabel.textColor = appearance.secondaryColor
        } else {
            countLabel.isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        titleButton.sizeToFit()
        let tw = min(titleButton.frame.width, bounds.width - 60)
        titleButton.frame = NSRect(x: (bounds.width - tw) / 2, y: (h - titleButton.frame.height) / 2 - 1,
                                   width: tw, height: titleButton.frame.height)
        backButton.sizeToFit()
        let bw = min(backButton.frame.width, bounds.width - 40)
        backButton.frame = NSRect(x: 12, y: (h - backButton.frame.height) / 2 - 1, width: bw, height: backButton.frame.height)
        countLabel.frame = NSRect(x: bounds.width - 52, y: (h - 14) / 2, width: 40, height: 14)
    }

    @objc private func titleClicked() { onTitleClick?(titleButton) }
    @objc private func backClicked() { onBack?() }
}

/// Page dots; the current page is drawn as a wider pill.
final class PageDotsView: NSView {
    var count = 0 { didSet { needsDisplay = true } }
    var current = 0 { didSet { needsDisplay = true } }
    var color: NSColor = .labelColor { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?

    private let dot: CGFloat = 6
    private var spacing: CGFloat { count > 1 ? min(12, max(7, (bounds.width - 16) / CGFloat(count))) : 12 }

    var idealWidth: CGFloat { CGFloat(max(count, 1)) * 12 + 10 }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 1 else { return }
        let total = spacing * CGFloat(count - 1) + 10
        var x = (bounds.width - total) / 2
        let y = bounds.midY - dot / 2
        for i in 0..<count {
            let rect: NSRect
            if i == current {
                rect = NSRect(x: x - 2, y: y, width: dot + 8, height: dot)
                color.withAlphaComponent(0.85).setFill()
                x += 4
            } else {
                rect = NSRect(x: x, y: y, width: dot, height: dot)
                color.withAlphaComponent(0.3).setFill()
            }
            NSBezierPath(roundedRect: rect, xRadius: dot / 2, yRadius: dot / 2).fill()
            x += spacing
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard count > 1 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let total = spacing * CGFloat(count - 1) + 10
        let start = (bounds.width - total) / 2
        let i = Int(((p.x - start) / spacing).rounded())
        onSelect?(min(max(i, 0), count - 1))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Bottom row: previous/next arrows around the page dots, a gear menu, and the
/// confirmation bar for Open All.
final class PopFooterView: NSView {
    private let prevButton = PopFooterView.symbolButton("chevron.left", "Previous Pop")
    private let nextButton = PopFooterView.symbolButton("chevron.right", "Next Pop")
    private let gearButton = PopFooterView.symbolButton("gearshape", "Options")
    let dots = PageDotsView()
    private let confirmLabel = NSTextField(labelWithString: "")
    private let confirmButton = NSButton(title: "Open", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onGear: ((NSView) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    private var confirming = false
    private var pageCount = 0

    static func symbolButton(_ symbol: String, _ tip: String) -> NSButton {
        let b = NSButton(title: "", target: nil, action: nil)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        b.isBordered = false
        b.bezelStyle = .inline
        b.imagePosition = .imageOnly
        b.toolTip = tip
        b.focusRingType = .none
        return b
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (b, sel) in [(prevButton, #selector(prev)), (nextButton, #selector(next)), (gearButton, #selector(gear)),
                         (confirmButton, #selector(confirm)), (cancelButton, #selector(cancel))] {
            b.target = self
            b.action = sel
            addSubview(b)
        }
        confirmButton.bezelStyle = .push
        confirmButton.controlSize = .small
        confirmButton.keyEquivalent = "\r"
        cancelButton.bezelStyle = .push
        cancelButton.controlSize = .small
        addSubview(dots)
        confirmLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        addSubview(confirmLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(pageIndex: Int, pageCount: Int, showDots: Bool, appearance: PopAppearance, confirmText: String?) {
        self.pageCount = pageCount
        confirming = confirmText != nil
        let paging = pageCount > 1
        dots.count = pageCount
        dots.current = pageIndex
        dots.color = appearance.labelColor
        dots.isHidden = !paging || !showDots || confirming
        prevButton.isHidden = !paging || confirming
        nextButton.isHidden = !paging || confirming
        prevButton.isEnabled = pageIndex > 0
        nextButton.isEnabled = pageIndex < pageCount - 1
        gearButton.isHidden = confirming
        for b in [prevButton, nextButton, gearButton] { b.contentTintColor = appearance.secondaryColor }
        confirmLabel.isHidden = !confirming
        confirmButton.isHidden = !confirming
        cancelButton.isHidden = !confirming
        confirmLabel.stringValue = confirmText ?? ""
        confirmLabel.textColor = appearance.labelColor
        confirmButton.appearance = appearance.nsAppearance
        cancelButton.appearance = appearance.nsAppearance
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        gearButton.frame = NSRect(x: w - 34, y: (h - 22) / 2, width: 24, height: 22)
        let dotsWidth = min(dots.idealWidth, w - 120)
        dots.frame = NSRect(x: (w - dotsWidth) / 2, y: 0, width: dotsWidth, height: h)
        prevButton.frame = NSRect(x: dots.frame.minX - 24, y: (h - 22) / 2, width: 22, height: 22)
        nextButton.frame = NSRect(x: dots.frame.maxX + 2, y: (h - 22) / 2, width: 22, height: 22)

        confirmButton.sizeToFit()
        cancelButton.sizeToFit()
        confirmButton.frame.origin = NSPoint(x: w - confirmButton.frame.width - 10, y: (h - confirmButton.frame.height) / 2)
        cancelButton.frame.origin = NSPoint(x: confirmButton.frame.minX - cancelButton.frame.width - 4,
                                            y: (h - cancelButton.frame.height) / 2)
        confirmLabel.frame = NSRect(x: 12, y: (h - 16) / 2, width: max(cancelButton.frame.minX - 18, 40), height: 16)
    }

    @objc private func prev() { onPrevious?() }
    @objc private func next() { onNext?() }
    @objc private func gear() { onGear?(gearButton) }
    @objc private func confirm() { onConfirm?() }
    @objc private func cancel() { onCancel?() }
}
