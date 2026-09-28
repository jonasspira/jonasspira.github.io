import Foundation

/// Which side of the popover points at the thing that opened it.
public enum ArrowEdge: String, Sendable {
    /// The anchor is below the popover (Dock at the bottom); the arrow points down.
    case bottom
    /// The anchor is left of the popover (Dock on the left); the arrow points left.
    case left
    /// The anchor is right of the popover (Dock on the right); the arrow points right.
    case right
    /// The anchor is above the popover (menu bar); the arrow points up.
    case top
    /// Not anchored: the popover is centered on screen without an arrow.
    case none
}

/// Where a popover window goes. Screen coordinates have a bottom-left origin (AppKit).
public struct PopoverPlacement: Equatable, Sendable {
    /// Window frame, including the arrow.
    public var frame: CGRect
    /// The body (rounded rectangle) inside the window's bounds.
    public var bodyRect: CGRect
    public var edge: ArrowEdge
    /// Arrow tip position along its edge, in window coordinates: x for top/bottom, y for left/right.
    public var arrowPosition: Double
}

public enum PopoverGeometry {
    /// How far the arrow sticks out of the body.
    public static let arrowLength = 10.0
    /// Width of the arrow where it meets the body.
    public static let arrowWidth = 22.0
    public static let screenMargin = 6.0
    public static let cornerRadius = 16.0

    /// Largest body that fits between the anchor and the screen edges.
    public static func maxBodySize(anchor: CGPoint, edge: ArrowEdge, in bounds: CGRect) -> CGSize {
        let m = screenMargin
        switch edge {
        case .bottom:
            return CGSize(width: bounds.width - 2 * m, height: bounds.maxY - m - (anchor.y + arrowLength))
        case .top:
            return CGSize(width: bounds.width - 2 * m, height: (anchor.y - arrowLength) - (bounds.minY + m))
        case .left:
            return CGSize(width: bounds.maxX - m - (anchor.x + arrowLength), height: bounds.height - 2 * m)
        case .right:
            return CGSize(width: (anchor.x - arrowLength) - (bounds.minX + m), height: bounds.height - 2 * m)
        case .none:
            return CGSize(width: bounds.width * 0.9, height: bounds.height * 0.85)
        }
    }

    public static func place(bodySize: CGSize, anchor: CGPoint, edge: ArrowEdge, in bounds: CGRect,
                             cornerRadius: Double = PopoverGeometry.cornerRadius) -> PopoverPlacement {
        let w = bodySize.width, h = bodySize.height, m = screenMargin, a = arrowLength
        // Keep the arrow clear of the rounded corners.
        let inset = cornerRadius + arrowWidth / 2 + 2

        func clampX(_ x: Double) -> Double {
            let lo = bounds.minX + m, hi = bounds.maxX - m - w
            return hi < lo ? lo : min(max(x, lo), hi)
        }
        func clampY(_ y: Double) -> Double {
            let lo = bounds.minY + m, hi = bounds.maxY - m - h
            return hi < lo ? lo : min(max(y, lo), hi)
        }
        func clampArrow(_ p: Double, length: Double) -> Double {
            length < inset * 2 ? length / 2 : min(max(p, inset), length - inset)
        }

        switch edge {
        case .bottom:
            let x = clampX(anchor.x - w / 2)
            return PopoverPlacement(frame: CGRect(x: x, y: anchor.y, width: w, height: h + a),
                                    bodyRect: CGRect(x: 0, y: a, width: w, height: h),
                                    edge: .bottom, arrowPosition: clampArrow(anchor.x - x, length: w))
        case .top:
            let x = clampX(anchor.x - w / 2)
            return PopoverPlacement(frame: CGRect(x: x, y: anchor.y - h - a, width: w, height: h + a),
                                    bodyRect: CGRect(x: 0, y: 0, width: w, height: h),
                                    edge: .top, arrowPosition: clampArrow(anchor.x - x, length: w))
        case .left:
            let y = clampY(anchor.y - h / 2)
            return PopoverPlacement(frame: CGRect(x: anchor.x, y: y, width: w + a, height: h),
                                    bodyRect: CGRect(x: a, y: 0, width: w, height: h),
                                    edge: .left, arrowPosition: clampArrow(anchor.y - y, length: h))
        case .right:
            let y = clampY(anchor.y - h / 2)
            return PopoverPlacement(frame: CGRect(x: anchor.x - w - a, y: y, width: w + a, height: h),
                                    bodyRect: CGRect(x: 0, y: 0, width: w, height: h),
                                    edge: .right, arrowPosition: clampArrow(anchor.y - y, length: h))
        case .none:
            let x = clampX(bounds.midX - w / 2)
            // Sit a little above center, where Spotlight-style panels usually appear.
            let y = clampY(bounds.midY - h / 2 + bounds.height * 0.08)
            return PopoverPlacement(frame: CGRect(x: x, y: y, width: w, height: h),
                                    bodyRect: CGRect(x: 0, y: 0, width: w, height: h),
                                    edge: .none, arrowPosition: 0)
        }
    }
}

/// Where the Dock sits and how large it is, as read from the Dock's preferences.
public struct DockLayout: Equatable, Sendable {
    public enum Orientation: String, Sendable { case bottom, left, right }

    public var orientation: Orientation
    public var autohide: Bool
    public var tileSize: Double

    public init(orientation: Orientation = .bottom, autohide: Bool = false, tileSize: Double = 48) {
        self.orientation = orientation
        self.autohide = autohide
        self.tileSize = tileSize
    }

    /// Finds the popover anchor for a click at `mouse` on a screen with the given frames.
    /// Returns nil when the mouse isn't over the Dock (the popover is then centered).
    public func anchor(mouse: CGPoint, screenFrame: CGRect, visibleFrame: CGRect, gap: Double) -> (point: CGPoint, edge: ArrowEdge)? {
        // Approximate thickness of the Dock when it doesn't reserve screen space (auto-hide).
        let estimated = tileSize + 18
        let slack = 6.0
        switch orientation {
        case .bottom:
            let reserved = visibleFrame.minY - screenFrame.minY
            let dockTop = reserved > 12 ? visibleFrame.minY : screenFrame.minY + estimated
            guard mouse.y <= dockTop + slack else { return nil }
            return (CGPoint(x: mouse.x, y: dockTop + gap), .bottom)
        case .left:
            let reserved = visibleFrame.minX - screenFrame.minX
            let dockEdge = reserved > 12 ? visibleFrame.minX : screenFrame.minX + estimated
            guard mouse.x <= dockEdge + slack else { return nil }
            return (CGPoint(x: dockEdge + gap, y: mouse.y), .left)
        case .right:
            let reserved = screenFrame.maxX - visibleFrame.maxX
            let dockEdge = reserved > 12 ? visibleFrame.maxX : screenFrame.maxX - estimated
            guard mouse.x >= dockEdge - slack else { return nil }
            return (CGPoint(x: dockEdge - gap, y: mouse.y), .right)
        }
    }
}
