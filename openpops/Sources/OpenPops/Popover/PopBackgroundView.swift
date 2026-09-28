import AppKit
import OpenPopsCore

/// The popover's shape: a rounded rectangle with an arrow toward the Dock, filled with the
/// blurred system material plus the Pop's color, gradient or photo, and a border.
final class PopBackgroundView: NSView {
    private let effectView = NSVisualEffectView()
    private let fillView = NSView()
    private let borderView = NSView()
    private let fillMask = CAShapeLayer()
    private let borderMask = CAShapeLayer()
    private var fillLayer: CALayer?
    private var borderLayer: CALayer?

    private(set) var style = PopStyle()
    private var isDark = false

    var edge: ArrowEdge = .none { didSet { needsLayout = true } }
    /// Screen point the arrow should touch. The arrow position is derived from the window's
    /// current frame, so it stays put while the window animates to a new size.
    var anchorScreenPoint: CGPoint = .zero { didSet { needsLayout = true } }
    var cornerRadius: CGFloat = CGFloat(PopoverGeometry.cornerRadius) { didSet { needsLayout = true } }
    /// When set, the arrow sits here instead of pointing at `anchorScreenPoint` (used in previews).
    var fixedArrowPosition: CGFloat? { didSet { needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        effectView.blendingMode = .behindWindow
        effectView.material = .popover
        effectView.state = .active
        addSubview(effectView)

        // Layer-hosting views: we own their layer trees.
        fillView.layer = CALayer()
        fillView.wantsLayer = true
        fillView.layer?.mask = fillMask
        addSubview(fillView)

        borderView.layer = CALayer()
        borderView.wantsLayer = true
        borderView.layer?.mask = borderMask
        addSubview(borderView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { false }

    /// The body rectangle (without the arrow) for a view of the given size.
    static func bodyRect(for bounds: CGRect, edge: ArrowEdge) -> CGRect {
        let a = CGFloat(PopoverGeometry.arrowLength)
        switch edge {
        case .bottom: return CGRect(x: 0, y: a, width: bounds.width, height: bounds.height - a)
        case .top: return CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - a)
        case .left: return CGRect(x: a, y: 0, width: bounds.width - a, height: bounds.height)
        case .right: return CGRect(x: 0, y: 0, width: bounds.width - a, height: bounds.height)
        case .none: return bounds
        }
    }

    var bodyRect: CGRect { PopBackgroundView.bodyRect(for: bounds, edge: edge) }

    func apply(style: PopStyle, appearance: PopAppearance) {
        self.style = style
        self.isDark = appearance.isDark
        effectView.appearance = appearance.nsAppearance

        fillLayer?.removeFromSuperlayer()
        fillLayer = nil
        switch style.background {
        case .system:
            break
        case .color(let c):
            let l = CALayer()
            l.backgroundColor = c.withAlpha(1).nsColor.cgColor
            fillLayer = l
        case .gradient(let g):
            let l = CAGradientLayer()
            GradientSpec(colors: g.colors.map { $0.withAlpha(1) }, angle: g.angle).configure(l)
            fillLayer = l
        case .image(let path):
            let l = CALayer()
            l.contents = NSImage(contentsOfFile: path)
            l.contentsGravity = .resizeAspectFill
            l.masksToBounds = true
            l.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
            fillLayer = l
        }
        if let l = fillLayer { fillView.layer?.addSublayer(l) }
        fillView.alphaValue = CGFloat(1 - min(max(style.glass, 0), 1))

        borderLayer?.removeFromSuperlayer()
        let border: CALayer
        switch style.border {
        case .none:
            let s = CAShapeLayer()
            s.fillColor = nil
            s.strokeColor = (isDark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.1)).cgColor
            s.lineWidth = 2
            border = s
        case .color(let c, let width):
            let s = CAShapeLayer()
            s.fillColor = nil
            s.strokeColor = c.nsColor.cgColor
            s.lineWidth = CGFloat(width) * 2
            border = s
        case .gradient(let g, let width):
            let gl = CAGradientLayer()
            g.configure(gl)
            let stroke = CAShapeLayer()
            stroke.fillColor = nil
            stroke.strokeColor = NSColor.black.cgColor
            stroke.lineWidth = CGFloat(width) * 2
            gl.mask = stroke
            border = gl
        }
        borderView.layer?.addSublayer(border)
        borderLayer = border
        needsLayout = true
    }

    private func currentArrowPosition(body: CGRect) -> CGFloat {
        guard edge != .none else { return 0 }
        let inset = cornerRadius + CGFloat(PopoverGeometry.arrowWidth) / 2 + 2
        if let fixed = fixedArrowPosition {
            let length = (edge == .top || edge == .bottom) ? body.width : body.height
            return length < inset * 2 ? length / 2 : min(max(fixed, inset), length - inset)
        }
        let frame = window?.frame ?? .zero
        let viewOrigin = window == nil ? NSPoint.zero : convert(NSPoint.zero, to: nil)
        let raw: CGFloat
        switch edge {
        case .top, .bottom:
            raw = anchorScreenPoint.x - frame.minX - viewOrigin.x - body.minX
            let length = body.width
            return length < inset * 2 ? length / 2 : min(max(raw, inset), length - inset)
        case .left, .right:
            raw = anchorScreenPoint.y - frame.minY - viewOrigin.y - body.minY
            let length = body.height
            return length < inset * 2 ? length / 2 : min(max(raw, inset), length - inset)
        case .none:
            return 0
        }
    }

    /// The outline path in this view's coordinates.
    func outlinePath() -> NSBezierPath {
        let body = bodyRect
        return Shapes.popoverPath(body: body, edge: edge, arrowPosition: currentArrowPosition(body: body),
                                  radius: cornerRadius)
    }

    override func layout() {
        super.layout()
        let path = outlinePath()
        let cg = path.cgPath

        effectView.frame = bounds
        let size = bounds.size
        effectView.maskImage = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            path.fill()
            return true
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillView.frame = bounds
        borderView.frame = bounds
        fillMask.frame = bounds
        fillMask.path = cg
        borderMask.frame = bounds
        borderMask.path = cg
        fillLayer?.frame = bounds
        if let shape = borderLayer as? CAShapeLayer {
            shape.frame = bounds
            shape.path = cg
        } else if let gradient = borderLayer as? CAGradientLayer {
            gradient.frame = bounds
            if let stroke = gradient.mask as? CAShapeLayer {
                stroke.frame = bounds
                stroke.path = cg
            }
        }
        CATransaction.commit()
        window?.invalidateShadow()
    }
}
