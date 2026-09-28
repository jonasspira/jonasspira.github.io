import AppKit
import OpenPopsCore

/// Draws Dock icons for Pops and groups: a rounded tile in the Pop's colors with a grid of
/// its item icons (like an iPhone folder), a glyph, or a custom image.
@MainActor
enum DockIconRenderer {
    nonisolated static let defaultPixels = 512

    static func image(for pop: Pop, pixels: Int = defaultPixels) -> NSImage {
        NSImage.rendered(pixels: pixels) { canvas in
            draw(pop: pop, in: canvas)
        }
    }

    /// A group shows up to four of its Pops as small tiles.
    static func image(forGroup group: PopGroup, pops: [Pop], pixels: Int = defaultPixels) -> NSImage {
        NSImage.rendered(pixels: pixels) { canvas in
            switch group.dockIcon.mode {
            case .glyph, .custom:
                let pseudo = Pop(name: group.name, dockIcon: group.dockIcon)
                draw(pop: pseudo, in: canvas)
            case .dynamic:
                let (body, radius) = Shapes.iconBody(in: canvas)
                let fill = group.dockIcon.matchPopBackground
                    ? (pops.first.map { $0.dockIcon.resolvedBackground(popStyle: $0.style) } ?? group.dockIcon.background)
                    : group.dockIcon.background
                drawTile(body: body, radius: radius, fill: fill)
                let shown = Array(pops.prefix(4))
                guard !shown.isEmpty else { return }
                let pad = body.width * 0.12, gap = body.width * 0.06
                let cell = (body.width - 2 * pad - gap) / 2
                for (i, pop) in shown.enumerated() {
                    let col = CGFloat(i % 2), row = CGFloat(i / 2)
                    let r = CGRect(x: body.minX + pad + col * (cell + gap),
                                   y: body.maxY - pad - cell - row * (cell + gap),
                                   width: cell, height: cell)
                    let mini = image(for: pop, pixels: 256)
                    // The mini icon has its own margin; draw it slightly larger to fill the cell.
                    mini.draw(in: r.insetBy(dx: -cell * 0.12, dy: -cell * 0.12))
                }
            }
        }
    }

    static func draw(pop: Pop, in canvas: CGRect) {
        let style = pop.dockIcon
        let (body, radius) = Shapes.iconBody(in: canvas)

        switch style.mode {
        case .custom:
            if let path = style.customImagePath, let custom = NSImage(contentsOfFile: path) {
                drawTile(body: body, radius: radius, fill: style.resolvedBackground(popStyle: pop.style)) {
                    custom.drawAspectFill(in: body)
                }
                return
            }
            fallthrough
        case .glyph:
            let fill = style.resolvedBackground(popStyle: pop.style)
            drawTile(body: body, radius: radius, fill: fill)
            let text = style.glyph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(pop.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
                : style.glyph
            drawGlyph(text.isEmpty ? "?" : text, in: body, color: glyphColor(style: style, fill: fill))
        case .dynamic:
            drawTile(body: body, radius: radius, fill: style.resolvedBackground(popStyle: pop.style))
            let items = pop.sortedItems()
            let n = style.density.gridSize(itemCount: items.count)
            let shown = Array(items.prefix(n * n))
            if shown.isEmpty {
                drawGlyph("+", in: body, color: glyphColor(style: style, fill: style.resolvedBackground(popStyle: pop.style)).withAlphaComponent(0.5))
                return
            }
            let pad = body.width * (n == 2 ? 0.14 : n == 3 ? 0.11 : 0.09)
            let gap = body.width * (n == 2 ? 0.07 : n == 3 ? 0.05 : 0.035)
            let cell = (body.width - 2 * pad - CGFloat(n - 1) * gap) / CGFloat(n)
            for (i, item) in shown.enumerated() {
                let col = CGFloat(i % n), row = CGFloat(i / n)
                let r = CGRect(x: body.minX + pad + col * (cell + gap),
                               y: body.maxY - pad - cell - row * (cell + gap),
                               width: cell, height: cell)
                let icon = IconProvider.shared.icon(for: item)
                // App icons carry their own transparent margin; scale up a bit so they read.
                icon.draw(in: r.insetBy(dx: -cell * 0.08, dy: -cell * 0.08),
                          from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
    }

    /// Fills the rounded tile, with a soft shadow, a sheen and a hairline edge.
    static func drawTile(body: CGRect, radius: CGFloat, fill: BackgroundFill, content: (() -> Void)? = nil) {
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -body.width * 0.012)
        shadow.shadowBlurRadius = body.width * 0.03
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.set()
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        switch fill {
        case .system:
            NSGradient(starting: NSColor(white: 0.96, alpha: 1), ending: NSColor(white: 0.84, alpha: 1))?
                .draw(in: body, angle: -90)
        case .color(let c):
            c.withAlpha(1).nsColor.setFill()
            body.fill()
        case .gradient(let g):
            GradientSpec(colors: g.colors.map { $0.withAlpha(1) }, angle: g.angle).nsGradient?
                .draw(in: body, angle: CGFloat(g.angle))
        case .image(let path):
            NSColor(white: 0.2, alpha: 1).setFill()
            body.fill()
            NSImage(contentsOfFile: path)?.drawAspectFill(in: body)
        }
        content?()
        // Sheen across the top half.
        NSGradient(starting: NSColor.white.withAlphaComponent(0.16), ending: NSColor.white.withAlphaComponent(0))?
            .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.18).setStroke()
        let edge = NSBezierPath(roundedRect: body.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
        edge.lineWidth = max(1, body.width * 0.004)
        edge.stroke()
    }

    private static func glyphColor(style: DockIconStyle, fill: BackgroundFill) -> NSColor {
        if let c = style.glyphColor { return c.nsColor }
        let base = fill.representativeColor ?? RGBA(0.9, 0.9, 0.92)
        return base.prefersDarkText ? NSColor(white: 0.12, alpha: 0.9) : NSColor.white
    }

    private static func drawGlyph(_ text: String, in body: CGRect, color: NSColor) {
        var size = body.height * (text.count <= 1 ? 0.58 : text.count == 2 ? 0.44 : 0.3)
        func font(_ s: CGFloat) -> NSFont {
            let base = NSFont.systemFont(ofSize: s, weight: .bold)
            if let rounded = base.fontDescriptor.withDesign(.rounded) {
                return NSFont(descriptor: rounded, size: s) ?? base
            }
            return base
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: font(size), .foregroundColor: color]
        var measured = (text as NSString).size(withAttributes: attrs)
        while measured.width > body.width * 0.82 && size > 8 {
            size *= 0.9
            attrs[.font] = font(size)
            measured = (text as NSString).size(withAttributes: attrs)
        }
        let origin = NSPoint(x: body.midX - measured.width / 2, y: body.midY - measured.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }
}
