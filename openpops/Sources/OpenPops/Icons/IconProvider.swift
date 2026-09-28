import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import OpenPopsCore

/// Icons for Pop items, with Quick Look thumbnails for documents and images.
@MainActor
final class IconProvider {
    static let shared = IconProvider()

    private var icons: [String: NSImage] = [:]
    private var thumbnails: [String: NSImage] = [:]
    private var failedThumbnails = Set<String>()
    private var waiting: [String: [(NSImage) -> Void]] = [:]

    /// The Finder icon for a path, or a generic icon with a question mark if it's missing.
    func icon(forPath path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let image: NSImage
        if FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            image = missingIcon()
        }
        icons[path] = image
        return image
    }

    func icon(for item: PopItem) -> NSImage {
        switch item.kind {
        case .link: return linkIcon(for: item.target)
        default: return icon(forPath: item.target)
        }
    }

    /// Cached thumbnail if one was made already.
    func cachedThumbnail(forPath path: String) -> NSImage? {
        thumbnails[path]
    }

    /// Requests a Quick Look thumbnail for a file. `completion` runs on the main thread only
    /// when a thumbnail exists.
    func thumbnail(forPath path: String, size: CGFloat, completion: @escaping (NSImage) -> Void) {
        if let t = thumbnails[path] { completion(t); return }
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

    private var linkIcons: [String: NSImage] = [:]

    /// The default browser's icon with a small link badge.
    func linkIcon(for target: String) -> NSImage {
        if let cached = linkIcons[target] { return cached }
        var base: NSImage?
        if let url = URL(string: target), let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
            base = NSWorkspace.shared.icon(forFile: app.path)
        }
        let badge = NSImage(systemSymbolName: "link.circle.fill", accessibilityDescription: nil)
        let image = NSImage.rendered(pixels: 256, points: 128) { rect in
            if let base = base {
                base.draw(in: rect)
            } else {
                let body = rect.insetBy(dx: 22, dy: 22)
                NSColor.systemBlue.setFill()
                NSBezierPath(roundedRect: body, xRadius: 44, yRadius: 44).fill()
            }
            if let badge = badge?.withSymbolConfiguration(.init(pointSize: 80, weight: .bold)
                .applying(.init(paletteColors: [.white, .systemBlue]))) {
                let b = CGRect(x: rect.maxX - 104, y: rect.minY + 8, width: 96, height: 96)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: b.insetBy(dx: 8, dy: 8)).fill()
                badge.draw(in: b)
            }
        }
        linkIcons[target] = image
        return image
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
