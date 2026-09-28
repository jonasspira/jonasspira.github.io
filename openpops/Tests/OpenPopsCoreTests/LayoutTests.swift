import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import OpenPopsCore

final class LayoutTests: XCTestCase {

    func testAutoColumns() {
        XCTAssertEqual(GridLayoutEngine.autoColumns(count: 0), 3)
        XCTAssertEqual(GridLayoutEngine.autoColumns(count: 1), 1)
        XCTAssertEqual(GridLayoutEngine.autoColumns(count: 3), 3)
        XCTAssertEqual(GridLayoutEngine.autoColumns(count: 4), 3)
        XCTAssertEqual(GridLayoutEngine.autoColumns(count: 9), 3)
        XCTAssertEqual(GridLayoutEngine.autoColumns(count: 14), 4)
        XCTAssertEqual(GridLayoutEngine.autoColumns(count: 25), 5)
        XCTAssertEqual(GridLayoutEngine.autoColumns(count: 40), 6)
        XCTAssertEqual(GridLayoutEngine.autoColumns(count: 40, maxColumns: 4), 4)
    }

    func testMetricsAndFrames() {
        let spec = GridSpec(iconSize: 64, showLabels: true, labelLines: 2, labelFontSize: 11.5, spacing: 8)
        let m = GridLayoutEngine.metrics(count: 8, spec: spec)
        XCTAssertEqual(m.columns, 3)
        XCTAssertEqual(m.rows, 3)
        XCTAssertEqual(m.cellSize.width, 92)
        XCTAssertEqual(m.frame(at: 0).origin, .zero)
        XCTAssertEqual(m.frame(at: 4).origin.x, 100)
        XCTAssertEqual(m.frame(at: 4).origin.y, m.cellSize.height + 8)
        XCTAssertEqual(m.contentSize.width, 3 * 92 + 2 * 8)
        XCTAssertEqual(m.contentSize.height, 3 * m.cellSize.height + 16)
    }

    func testHitTesting() {
        let spec = GridSpec(iconSize: 64, spacing: 10)
        let m = GridLayoutEngine.metrics(count: 5, spec: spec)
        XCTAssertEqual(m.index(at: CGPoint(x: 5, y: 5), count: 5), 0)
        XCTAssertEqual(m.index(at: CGPoint(x: m.pitch.width + 5, y: 5), count: 5), 1)
        // The gap between cells hits nothing.
        XCTAssertNil(m.index(at: CGPoint(x: m.cellSize.width + 4, y: 5), count: 5))
        // Empty slot after the last item.
        XCTAssertNil(m.index(at: CGPoint(x: 2 * m.pitch.width + 5, y: m.pitch.height + 5), count: 5))
        XCTAssertNil(m.index(at: CGPoint(x: -1, y: 5), count: 5))
    }

    func testSlotIndex() {
        let m = GridLayoutEngine.metrics(count: 7, spec: GridSpec())
        XCTAssertEqual(m.slotIndex(at: CGPoint(x: 1, y: 1), maxIndex: 6), 0)
        XCTAssertEqual(m.slotIndex(at: CGPoint(x: m.pitch.width * 2.5, y: m.pitch.height * 1.5), maxIndex: 6), 5)
        XCTAssertEqual(m.slotIndex(at: CGPoint(x: 9999, y: 9999), maxIndex: 6), 6)
        XCTAssertEqual(m.slotIndex(at: CGPoint(x: -50, y: -50), maxIndex: 6), 0)
        XCTAssertEqual(m.slotIndex(at: CGPoint(x: 9999, y: 9999), maxIndex: 7), 7)
    }

    func testNeighbors() {
        let m = GridLayoutEngine.metrics(count: 7, spec: GridSpec())  // 3 columns: rows of 3, 3, 1
        XCTAssertEqual(m.neighbor(of: 0, dx: 1, dy: 0, count: 7), 1)
        XCTAssertNil(m.neighbor(of: 2, dx: 1, dy: 0, count: 7))
        XCTAssertNil(m.neighbor(of: 0, dx: -1, dy: 0, count: 7))
        XCTAssertEqual(m.neighbor(of: 1, dx: 0, dy: 1, count: 7), 4)
        XCTAssertEqual(m.neighbor(of: 5, dx: 0, dy: 1, count: 7), 6, "down into a short row lands on the last item")
        XCTAssertNil(m.neighbor(of: 6, dx: 0, dy: 1, count: 7))
        XCTAssertNil(m.neighbor(of: 1, dx: 0, dy: -1, count: 7))
    }

    func testListLayout() {
        let spec = GridSpec(iconSize: 64, layout: .list)
        XCTAssertEqual(GridLayoutEngine.metrics(count: 5, spec: spec).columns, 1)
        XCTAssertEqual(GridLayoutEngine.metrics(count: 12, spec: spec).columns, 2)
        XCTAssertEqual(spec.listIconSize, 29)
    }

    func testBodyLayoutScrollsWhenTooTall() {
        let m = GridLayoutEngine.metrics(count: 40, spec: GridSpec())
        let free = GridLayoutEngine.bodyLayout(for: m)
        XCTAssertFalse(free.scrolls)
        let capped = GridLayoutEngine.bodyLayout(for: m, maxBodySize: CGSize(width: 2000, height: 400))
        XCTAssertTrue(capped.scrolls)
        XCTAssertEqual(capped.size.height, 400)
        XCTAssertEqual(capped.gridViewportHeight, 400 - PopoverChrome().verticalChrome)
        let one = GridLayoutEngine.bodyLayout(for: GridLayoutEngine.metrics(count: 1, spec: GridSpec()))
        XCTAssertEqual(one.size.width, PopoverChrome().minBodyWidth)
    }

    func testPlacementAboveBottomDock() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let p = PopoverGeometry.place(bodySize: CGSize(width: 300, height: 400), anchor: CGPoint(x: 700, y: 80),
                                      edge: .bottom, in: screen)
        XCTAssertEqual(p.frame, CGRect(x: 550, y: 80, width: 300, height: 400 + PopoverGeometry.arrowLength))
        XCTAssertEqual(p.bodyRect.minY, PopoverGeometry.arrowLength)
        XCTAssertEqual(p.arrowPosition, 150)
    }

    func testPlacementClampsToScreenAndKeepsArrowOnAnchor() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let p = PopoverGeometry.place(bodySize: CGSize(width: 300, height: 400), anchor: CGPoint(x: 40, y: 80),
                                      edge: .bottom, in: screen)
        XCTAssertEqual(p.frame.minX, PopoverGeometry.screenMargin)
        // Still reachable: the arrow points straight at the anchor.
        XCTAssertEqual(p.arrowPosition, 40 - PopoverGeometry.screenMargin)

        // Closer to the edge the arrow can't sit on the rounded corner, so it stops at the inset.
        let edge = PopoverGeometry.place(bodySize: CGSize(width: 300, height: 400), anchor: CGPoint(x: 10, y: 80),
                                         edge: .bottom, in: screen)
        let inset = PopoverGeometry.cornerRadius + PopoverGeometry.arrowWidth / 2 + 2
        XCTAssertEqual(edge.arrowPosition, inset)

        let right = PopoverGeometry.place(bodySize: CGSize(width: 300, height: 400), anchor: CGPoint(x: 1400, y: 80),
                                          edge: .bottom, in: screen)
        XCTAssertEqual(right.frame.maxX, 1440 - PopoverGeometry.screenMargin)
        XCTAssertEqual(right.arrowPosition, 1400 - right.frame.minX)
    }

    func testPlacementSideDocksAndMenuBar() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = PopoverGeometry.place(bodySize: CGSize(width: 300, height: 200), anchor: CGPoint(x: 70, y: 450),
                                         edge: .left, in: screen)
        XCTAssertEqual(left.frame.minX, 70)
        XCTAssertEqual(left.bodyRect.minX, PopoverGeometry.arrowLength)
        XCTAssertEqual(left.arrowPosition, 100)

        let right = PopoverGeometry.place(bodySize: CGSize(width: 300, height: 200), anchor: CGPoint(x: 1370, y: 450),
                                          edge: .right, in: screen)
        XCTAssertEqual(right.frame.maxX, 1370)
        XCTAssertEqual(right.bodyRect.minX, 0)

        let top = PopoverGeometry.place(bodySize: CGSize(width: 300, height: 200), anchor: CGPoint(x: 1200, y: 875),
                                        edge: .top, in: screen)
        XCTAssertEqual(top.frame.maxY, 875)
        XCTAssertEqual(top.bodyRect.minY, 0)

        let center = PopoverGeometry.place(bodySize: CGSize(width: 300, height: 200), anchor: .zero, edge: .none, in: screen)
        XCTAssertEqual(center.frame.midX, 720)
    }

    func testMaxBodySize() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let s = PopoverGeometry.maxBodySize(anchor: CGPoint(x: 700, y: 80), edge: .bottom, in: screen)
        XCTAssertEqual(s.height, 900 - PopoverGeometry.screenMargin - 80 - PopoverGeometry.arrowLength)
    }

    func testDockAnchor() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)
        let dock = DockLayout(orientation: .bottom, autohide: false, tileSize: 48)
        let hit = dock.anchor(mouse: CGPoint(x: 600, y: 30), screenFrame: frame, visibleFrame: visible, gap: 4)
        XCTAssertEqual(hit?.point, CGPoint(x: 600, y: 74))
        XCTAssertEqual(hit?.edge, .bottom)
        XCTAssertNil(dock.anchor(mouse: CGPoint(x: 600, y: 400), screenFrame: frame, visibleFrame: visible, gap: 4))

        // Auto-hidden Dock doesn't reserve space; the tile size estimates its height.
        let hidden = DockLayout(orientation: .bottom, autohide: true, tileSize: 48)
        let hv = CGRect(x: 0, y: 4, width: 1440, height: 871)
        XCTAssertEqual(hidden.anchor(mouse: CGPoint(x: 600, y: 30), screenFrame: frame, visibleFrame: hv, gap: 4)?.point.y, 70)

        let left = DockLayout(orientation: .left)
        let lv = CGRect(x: 64, y: 0, width: 1376, height: 875)
        XCTAssertEqual(left.anchor(mouse: CGPoint(x: 30, y: 500), screenFrame: frame, visibleFrame: lv, gap: 4)?.point,
                       CGPoint(x: 68, y: 500))

        let right = DockLayout(orientation: .right)
        let rv = CGRect(x: 0, y: 0, width: 1376, height: 875)
        XCTAssertEqual(right.anchor(mouse: CGPoint(x: 1410, y: 500), screenFrame: frame, visibleFrame: rv, gap: 4)?.edge, .right)
    }
}
