import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import OpenPopsCore

/// Icons for Pop items, with Quick Look thumbnails for documents and images.
///
/// macOS renders app and file icons asynchronously: the first time an icon is drawn it can
/// come out as an empty placeholder while the real one is still being made. Icons here are
/// drawn into bitmaps, and `settledIcon` redraws an icon a couple of times shortly after it
/// was first requested, so callers can swap the placeholder for the real thing.
@MainActor
final class IconProvider {
    static let shared = IconProvider()

    private struct Entry {
        var image: NSImage
        var created: Date
        var draws: Int
    }

    private var icons: [String: Entry] = [:]
    private var linkIcons: [String: Entry] = [:]
    private var thumbnails: [String: NSImage] = [:]
    private var failedThumbnails = Set<String>()
    private var waiting: [String: [(NSImage) -> Void]] = [:]
    private var appearanceName: NSAppearance.Name?

    /// Drops cached icons when the system switches between light and dark.
    private func checkAppearance() {
        let name = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        if name != appearanceName {
            appearanceName = name
            icons.removeAll()
            linkIcons.removeAll()
        }
    }

    /// The Finder icon for a path, or a generic icon with a question mark if it's missing.
    func icon(forPath path: String) -> NSImage {
        checkAppearance()
        if let cached = icons[path] { return cached.image }
        let image = draw(path)
        // Browsing big folders adds an icon per file; keep the cache bounded.
        if icons.count > 500 { icons.removeAll() }
        icons[path] = Entry(image: image, created: Date(), draws: 1)
        return image
    }

    /// Redraws an icon that was first drawn in the last few seconds, in case the first
    /// draw was a placeholder.
    func settledIcon(forPath path: String) -> NSImage {
        checkAppearance()
        guard var entry = icons[path] else { return icon(forPath: path) }
        if entry.draws < 3 && Date().timeIntervalSince(entry.created) < 12 {
            entry.image = draw(path)
            entry.draws += 1
            icons[path] = entry
        }
        return entry.image
    }

    func icon(for item: PopItem) -> NSImage {
        item.kind == .link ? linkIcon(for: item.target) : icon(forPath: item.target)
    }

    func settledIcon(for item: PopItem) -> NSImage {
        item.kind == .link ? settledLinkIcon(for: item.target) : settledIcon(forPath: item.target)
    }

    private func draw(_ path: String) -> NSImage {
        // Follow symlinks (e.g. /Applications/Safari.app) so icons don't get an alias badge.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: resolved) else { return missingIcon() }
        let source = NSWorkspace.shared.icon(forFile: resolved)
        return Self.flatten(source)
    }

    /// Draws an image into a bitmap using the app's current appearance. 192 pixels covers
    /// the largest icon size (96 pt) on Retina screens.
    static func flatten(_ source: NSImage, pixels: Int = 192) -> NSImage {
        NSImage.rendered(pixels: pixels, points: CGFloat(pixels) / 2) { rect in
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
                source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
    }

    // MARK: Thumbnails

    /// Cached thumbnail if one was made already.
    func cachedThumbnail(forPath path: String) -> NSImage? {
        thumbnails[path]
    }

    /// Requests a Quick Look thumbnail for a file. `completion` runs on the main thread only
    /// when a thumbnail exists.
    func thumbnail(forPath path: String, size: CGFloat, completion: @escaping (NSImage) -> Void) {
        if let t = thumbnails[path] {
            completion(t)
            return
        }
        guard !failedThumbnails.contains(path), Self.wantsThumbnail(path) else { return }
        if waiting[path] != nil {
            waiting[path]?.append(completion)
            return
        }
        waiting[path] = [completion]
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path),
                                                   size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage
            Task { @MainActor in
                IconProvider.shared.finishThumbnail(path: path, image: image)
            }
        }
    }

    private func finishThumbnail(path: String, image: NSImage?) {
        let callbacks = waiting.removeValue(forKey: path) ?? []
        guard let image = image else {
            failedThumbnails.insert(path)
            return
        }
        if thumbnails.count > 500 { thumbnails.removeAll() }
        thumbnails[path] = image
        callbacks.forEach { $0(image) }
    }

    /// Thumbnails are worth it for documents and media; apps and folders keep their icons.
    static func wantsThumbnail(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext.isEmpty || ext == "app" { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        return !isDir.boolValue || ["pages", "numbers", "key", "rtfd"].contains(ext)
    }

    func invalidate() {
        icons.removeAll()
        thumbnails.removeAll()
        failedThumbnails.removeAll()
        linkIcons.removeAll()
    }

    // MARK: Links

    /// The default browser's icon with a small link badge.
    func linkIcon(for target: String) -> NSImage {
        checkAppearance()
        if let cached = linkIcons[target] { return cached.image }
        let image = drawLinkIcon(target)
        linkIcons[target] = Entry(image: image, created: Date(), draws: 1)
        return image
    }

    func settledLinkIcon(for target: String) -> NSImage {
        guard var entry = linkIcons[target] else { return linkIcon(for: target) }
        if entry.draws < 3 && Date().timeIntervalSince(entry.created) < 12 {
            entry.image = drawLinkIcon(target)
            entry.draws += 1
            linkIcons[target] = entry
        }
        return entry.image
    }

    private func drawLinkIcon(_ target: String) -> NSImage {
        var base: NSImage?
        if let url = URL(string: target), let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
            base = NSWorkspace.shared.icon(forFile: app.resolvingSymlinksInPath().path)
        }
        let badge = NSImage(systemSymbolName: "link.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 80, weight: .bold)
                .applying(.init(paletteColors: [.white, .systemBlue])))
        return NSImage.rendered(pixels: 256, points: 128) { rect in
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
                if let base = base {
                    base.draw(in: rect)
                } else {
                    NSColor.systemBlue.setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: 22, dy: 22), xRadius: 44, yRadius: 44).fill()
                }
                if let badge = badge {
                    let b = CGRect(x: rect.maxX - 104, y: rect.minY + 8, width: 96, height: 96)
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: b.insetBy(dx: 8, dy: 8)).fill()
                    badge.draw(in: b)
                }
            }
        }
    }

    private func missingIcon() -> NSImage {
        let base = NSWorkspace.shared.icon(for: .data)
        return NSImage.rendered(pixels: 256, points: 128) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.45)
            if let q = NSImage(systemSymbolName: "questionmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 90, weight: .bold)
                    .applying(.init(paletteColors: [.white, .systemOrange]))) {
                q.draw(in: CGRect(x: rect.maxX - 110, y: rect.minY + 6, width: 104, height: 104))
            }
        }
    }
}
