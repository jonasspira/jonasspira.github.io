import AppKit
import OpenPopsCore

/// Visual settings shared by every cell in a grid.
struct CellStyle {
    var appearance: PopAppearance
    var spec: GridSpec
    var hover: HoverHighlight
    var pressFeedback: Bool
}

/// An icon with its label. Grid cells stack them; list cells put them side by side.
final class ItemCellView: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private(set) var entry: GridEntry
    private var style: CellStyle

    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    private(set) var isPressed = false

    override var isFlipped: Bool { true }

    init(entry: GridEntry, icon: NSImage, style: CellStyle) {
        self.entry = entry
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = icon
        iconView.alphaValue = entry.isMissing ? 0.55 : 1
        iconView.wantsLayer = true
        addSubview(iconView)

        let grid = style.spec.layout == .grid
        label.stringValue = entry.name
        label.font = style.appearance.labelFont
        label.textColor = style.appearance.labelColor
        label.alignment = grid ? .center : .left
        label.maximumNumberOfLines = grid ? max(style.spec.labelLines, 1) : 1
        label.lineBreakMode = grid ? .byWordWrapping : .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = false
        label.drawsBackground = false
        label.isHidden = grid && !style.spec.showLabels
        if let shadow = style.appearance.labelShadow {
            label.wantsLayer = true
            label.shadow = shadow
        }
        addSubview(label)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.name)
        toolTip = entry.isMissing ? "\(entry.name) can't be found" : entry.name
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setIcon(_ image: NSImage) {
        iconView.image = image
    }

    private var iconSize: CGFloat {
        style.spec.layout == .grid ? CGFloat(style.spec.iconSize) : CGFloat(style.spec.listIconSize)
    }

    private func iconFrame(pressed: Bool) -> NSRect {
        let s = iconSize
        var r: NSRect
        switch style.spec.layout {
        case .grid:
            r = NSRect(x: (bounds.width - s) / 2, y: 6, width: s, height: s)
        case .list:
            r = NSRect(x: 7, y: (bounds.height - s) / 2, width: s, height: s)
        }
        if pressed && style.pressFeedback {
            r = r.insetBy(dx: s * 0.07, dy: s * 0.07)
        }
        return r
    }

    override func layout() {
        super.layout()
        iconView.frame = iconFrame(pressed: isPressed)
        let line = CGFloat(style.spec.lineHeight)
        switch style.spec.layout {
        case .grid:
            let top = 6 + iconSize + 4
            label.frame = NSRect(x: 2, y: top, width: bounds.width - 4,
                                 height: line * CGFloat(max(style.spec.labelLines, 1)) + 2)
        case .list:
            let x = 7 + iconSize + 8
            label.frame = NSRect(x: x, y: (bounds.height - line) / 2 - 1, width: bounds.width - x - 8, height: line + 2)
        }
    }

    func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        let target = iconFrame(pressed: pressed)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = pressed ? 0.07 : 0.14
            ctx.allowsImplicitAnimation = true
            iconView.animator().frame = target
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        var alpha: CGFloat = 0
        if isSelected {
            alpha = max(CGFloat(style.hover.opacity), 0.16) + 0.08
        } else if isHovered {
            alpha = CGFloat(style.hover.opacity)
        }
        guard alpha > 0 else { return }
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        style.appearance.highlightBase.withAlphaComponent(alpha).setFill()
        path.fill()
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 10.5, yRadius: 10.5)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}
