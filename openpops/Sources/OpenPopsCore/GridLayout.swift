import Foundation

/// Inputs that decide the size of a Pop's grid.
public struct GridSpec: Equatable, Sendable {
    public var iconSize: Double
    public var showLabels: Bool
    public var labelLines: Int
    public var labelFontSize: Double
    public var spacing: Double
    public var layout: PopLayout

    public init(iconSize: Double = 64, showLabels: Bool = true, labelLines: Int = 2,
                labelFontSize: Double = 11.5, spacing: Double = 8, layout: PopLayout = .grid) {
        self.iconSize = iconSize
        self.showLabels = showLabels
        self.labelLines = labelLines
        self.labelFontSize = labelFontSize
        self.spacing = spacing
        self.layout = layout
    }

    public var lineHeight: Double { (labelFontSize * 1.26).rounded(.up) }

    /// Icon size used in list rows.
    public var listIconSize: Double { min(max((iconSize * 0.45).rounded(), 20), 36) }
}

/// Cell positions for a grid. Coordinates use a top-left origin.
public struct GridMetrics: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public var cellSize: CGSize
    public var spacing: Double

    public var pitch: CGSize {
        CGSize(width: cellSize.width + spacing, height: cellSize.height + spacing)
    }

    public var contentSize: CGSize {
        let c = Double(max(columns, 1)), r = Double(max(rows, 1))
        return CGSize(width: c * cellSize.width + (c - 1) * spacing,
                      height: r * cellSize.height + (r - 1) * spacing)
    }

    public func frame(at index: Int) -> CGRect {
        let cols = max(columns, 1)
        let col = index % cols, row = index / cols
        return CGRect(x: Double(col) * pitch.width, y: Double(row) * pitch.height,
                      width: cellSize.width, height: cellSize.height)
    }

    /// The cell under `point`, ignoring the gaps between cells.
    public func index(at point: CGPoint, count: Int) -> Int? {
        guard point.x >= 0, point.y >= 0, columns > 0 else { return nil }
        let col = Int(point.x / pitch.width), row = Int(point.y / pitch.height)
        guard col < columns else { return nil }
        let i = row * columns + col
        guard i < count, frame(at: i).contains(point) else { return nil }
        return i
    }

    /// The slot under `point`, clamped to 0...maxIndex. Used for drag reordering and drops.
    public func slotIndex(at point: CGPoint, maxIndex: Int) -> Int {
        guard columns > 0 else { return 0 }
        let col = min(max(Int((point.x / pitch.width).rounded(.down)), 0), columns - 1)
        let row = max(Int((point.y / pitch.height).rounded(.down)), 0)
        return min(max(row * columns + col, 0), max(maxIndex, 0))
    }

    /// Index reached by moving the selection with the arrow keys, or nil at an edge.
    public func neighbor(of index: Int, dx: Int, dy: Int, count: Int) -> Int? {
        guard count > 0, columns > 0 else { return nil }
        let col = index % columns, row = index / columns
        let newCol = col + dx, newRow = row + dy
        guard newCol >= 0, newCol < columns, newRow >= 0 else { return nil }
        let i = newRow * columns + newCol
        if i < count { return i }
        // Moving down into a short last row lands on its last item.
        if dy > 0 && newRow * columns < count { return count - 1 }
        return nil
    }
}

public enum GridLayoutEngine {
    /// Columns for a grid of `count` items: 3 up to 9 items, 4 up to 16, 5 up to 25, then 6.
    public static func autoColumns(count: Int, maxColumns: Int = 6) -> Int {
        let base: Int
        switch count {
        case ..<1: base = 3
        case 1...3: base = count
        case 4...9: base = 3
        case 10...16: base = 4
        case 17...25: base = 5
        default: base = 6
        }
        return max(1, min(base, max(maxColumns, 1)))
    }

    public static func cellSize(for spec: GridSpec) -> CGSize {
        switch spec.layout {
        case .grid:
            let width = max(76, (spec.iconSize * 1.25 + 12).rounded())
            let labels = spec.showLabels ? 4 + spec.lineHeight * Double(max(spec.labelLines, 1)) : 0
            return CGSize(width: width, height: (6 + spec.iconSize + labels + 6).rounded(.up))
        case .list:
            return CGSize(width: 250, height: spec.listIconSize + 10)
        }
    }

    /// - Parameters:
    ///   - fixedColumns: a user-chosen column count, or 0 for automatic.
    public static func metrics(count: Int, spec: GridSpec, fixedColumns: Int = 0, maxColumns: Int = 6) -> GridMetrics {
        let columns: Int
        switch spec.layout {
        case .grid:
            columns = fixedColumns > 0 ? fixedColumns : autoColumns(count: count, maxColumns: maxColumns)
        case .list:
            columns = fixedColumns > 0 ? min(fixedColumns, 3) : (count > 10 ? 2 : 1)
        }
        let rows = count == 0 ? 1 : Int((Double(count) / Double(columns)).rounded(.up))
        return GridMetrics(columns: columns, rows: rows, cellSize: cellSize(for: spec),
                           spacing: spec.layout == .list ? 2 : spec.spacing)
    }
}

/// Fixed parts of the popover around the grid.
public struct PopoverChrome: Equatable, Sendable {
    public var headerHeight: Double = 34
    public var footerHeight: Double = 30
    public var sidePadding: Double = 12
    public var gridTopPadding: Double = 2
    public var gridBottomPadding: Double = 4
    public var minBodyWidth: Double = 214

    public init() {}

    public var verticalChrome: Double {
        headerHeight + gridTopPadding + gridBottomPadding + footerHeight
    }
}

public struct PopoverBodyLayout: Equatable, Sendable {
    /// Size of the popover body, without the arrow.
    public var size: CGSize
    /// Height of the visible grid area. Smaller than the grid when it scrolls.
    public var gridViewportHeight: Double
    public var scrolls: Bool
}

extension GridLayoutEngine {
    public static func bodyLayout(for metrics: GridMetrics, chrome: PopoverChrome = PopoverChrome(),
                                  maxBodySize: CGSize? = nil) -> PopoverBodyLayout {
        let content = metrics.contentSize
        var width = max(chrome.minBodyWidth, content.width + chrome.sidePadding * 2)
        var viewport = content.height
        var height = chrome.verticalChrome + viewport
        var scrolls = false
        if let maxSize = maxBodySize {
            width = min(width, max(maxSize.width, chrome.minBodyWidth))
            if height > maxSize.height {
                // Keep at least one row visible even on tiny screens.
                viewport = max(min(content.height, metrics.cellSize.height), maxSize.height - chrome.verticalChrome)
                height = chrome.verticalChrome + viewport
                scrolls = viewport < content.height
            }
        }
        return PopoverBodyLayout(size: CGSize(width: width.rounded(.up), height: height.rounded(.up)),
                                 gridViewportHeight: viewport, scrolls: scrolls)
    }
}
