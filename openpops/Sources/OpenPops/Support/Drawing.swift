import AppKit
import OpenPopsCore

extension RGBA {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) ?? .black
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }
}

extension GradientSpec {
    var nsGradient: NSGradient? {
        let colors = self.colors.map(\.nsColor)
        if colors.count == 1 { return NSGradient(starting: colors[0], ending: colors[0]) }
        return NSGradient(colors: colors)
    }

    /// Colors and unit points for CAGradientLayer (bottom-left origin, like AppKit layers).
    func configure(_ layer: CAGradientLayer) {
        layer.colors = colors.map { $0.nsColor.cgColor }
        let p = unitPoints
        layer.startPoint = CGPoint(x: p.start.x, y: p.start.y)
        layer.endPoint = CGPoint(x: p.end.x, y: p.end.y)
    }
}

extension FontWeightName {
    var nsWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }

    /// NSFontManager's 0–15 weight scale.
    var managerWeight: Int {
        switch self {
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 11
        }
    }
}

extension LabelStyle {
    func font(size overrideSize: Double? = nil, weight overrideWeight: FontWeightName? = nil) -> NSFont {
        let s = CGFloat(overrideSize ?? size)
        let w = overrideWeight ?? weight
        if let family = fontFamily, !family.isEmpty,
           let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: w.managerWeight, size: s) {
            return f
        }
        return NSFont.systemFont(ofSize: s, weight: w.nsWeight)
    }
}

/// Resolved colors and fonts for drawing one Pop.
struct PopAppearance {
    let style: PopStyle
    let isDark: Bool
    let labelColor: NSColor
    let secondaryColor: NSColor
    let labelFont: NSFont
    let titleFont: NSFont
    let labelShadow: NSShadow?
    let nsAppearance: NSAppearance?

    init(style: PopStyle) {
        self.style = style
        let forced = style.resolvedDarkAppearance
        let systemDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        isDark = forced ?? systemDark
        let label = style.resolvedLabelColor(isDark: isDark).nsColor
        labelColor = label
        secondaryColor = label.withAlphaComponent(label.alphaComponent * 0.62)
        labelFont = style.label.font()
        titleFont = style.label.font(size: max(style.label.size + 1.5, 12), weight: .semibold)
        if style.label.shadow {
            let s = NSShadow()
            s.shadowBlurRadius = 2.5
            s.shadowOffset = NSSize(width: 0, height: -1)
            s.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.55 : 0.35)
            labelShadow = s
        } else {
            labelShadow = nil
        }
        if let forced = forced {
            nsAppearance = NSAppearance(named: forced ? .darkAqua : .aqua)
        } else {
            nsAppearance = nil
        }
    }

    /// Color for hover and selection highlights.
    var highlightBase: NSColor { isDark ? .white : .black }
}

enum Shapes {
    /// A rounded rectangle with an arrow on one edge, in a y-up coordinate space.
    static func popoverPath(body: CGRect, edge: ArrowEdge, arrowPosition: CGFloat,
                            radius: CGFloat = CGFloat(PopoverGeometry.cornerRadius),
                            arrowWidth aw: CGFloat = CGFloat(PopoverGeometry.arrowWidth),
                            arrowLength al: CGFloat = CGFloat(PopoverGeometry.arrowLength)) -> NSBezierPath {
        let r = min(radius, body.width / 2, body.height / 2)
        let x0 = body.minX, x1 = body.maxX, y0 = body.minY, y1 = body.maxY
        let p = NSBezierPath()

        func arrow(base: NSPoint, along: NSPoint, out: NSPoint) {
            func pt(_ u: CGFloat, _ v: CGFloat) -> NSPoint {
                NSPoint(x: base.x + along.x * u + out.x * v, y: base.y + along.y * u + out.y * v)
            }
            p.line(to: pt(-aw / 2, 0))
            p.curve(to: pt(-1.8, al - 1.1), controlPoint1: pt(-aw / 4, 0), controlPoint2: pt(-3.6, al - 2.6))
            p.curve(to: pt(1.8, al - 1.1), controlPoint1: pt(-0.6, al), controlPoint2: pt(0.6, al))
            p.curve(to: pt(aw / 2, 0), controlPoint1: pt(3.6, al - 2.6), controlPoint2: pt(aw / 4, 0))
        }

        p.move(to: NSPoint(x: x0 + r, y: y0))
        if edge == .bottom {
            arrow(base: NSPoint(x: x0 + arrowPosition, y: y0), along: NSPoint(x: 1, y: 0), out: NSPoint(x: 0, y: -1))
        }
        p.line(to: NSPoint(x: x1 - r, y: y0))
        p.appendArc(withCenter: NSPoint(x: x1 - r, y: y0 + r), radius: r, startAngle: 270, endAngle: 360)
        if edge == .right {
            arrow(base: NSPoint(x: x1, y: y0 + arrowPosition), along: NSPoint(x: 0, y: 1), out: NSPoint(x: 1, y: 0))
        }
        p.line(to: NSPoint(x: x1, y: y1 - r))
        p.appendArc(withCenter: NSPoint(x: x1 - r, y: y1 - r), radius: r, startAngle: 0, endAngle: 90)
        if edge == .top {
            arrow(base: NSPoint(x: x0 + arrowPosition, y: y1), along: NSPoint(x: -1, y: 0), out: NSPoint(x: 0, y: 1))
        }
        p.line(to: NSPoint(x: x0 + r, y: y1))
        p.appendArc(withCenter: NSPoint(x: x0 + r, y: y1 - r), radius: r, startAngle: 90, endAngle: 180)
        if edge == .left {
            arrow(base: NSPoint(x: x0, y: y0 + arrowPosition), along: NSPoint(x: 0, y: -1), out: NSPoint(x: -1, y: 0))
        }
        p.line(to: NSPoint(x: x0, y: y0 + r))
        p.appendArc(withCenter: NSPoint(x: x0 + r, y: y0 + r), radius: r, startAngle: 180, endAngle: 270)
        p.close()
        return p
    }

    /// The rounded square used for Dock icons, sized like macOS app icons (824 of 1024).
    static func iconBody(in canvas: CGRect) -> (rect: CGRect, radius: CGFloat) {
        let inset = canvas.width * 100 / 1024
        let rect = canvas.insetBy(dx: inset, dy: inset)
        return (rect, canvas.width * 185 / 1024)
    }
}

extension NSImage {
    /// Draws into a bitmap of `pixels` × `pixels` and returns it as an image of `points` size.
    static func rendered(pixels: Int, points: CGFloat? = nil, _ draw: (CGRect) -> Void) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return NSImage(size: NSSize(width: pixels, height: pixels))
        }
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            draw(CGRect(x: 0, y: 0, width: pixels, height: pixels))
            ctx.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        let size = points ?? CGFloat(pixels)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }

    /// PNG data for saving snapshots.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Draws the image scaled to fill `rect`, cropping the overflow.
    func drawAspectFill(in rect: CGRect) {
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h),
             from: .zero, operation: .sourceOver, fraction: 1)
    }
}

extension NSView {
    /// Renders the view hierarchy to an image (used for drag images and snapshots).
    func snapshotImage() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

extension NSScreen {
    static func containing(_ point: NSPoint) -> NSScreen? {
        screens.first { NSMouseInRect(point, $0.frame, false) } ?? main ?? screens.first
    }
}
