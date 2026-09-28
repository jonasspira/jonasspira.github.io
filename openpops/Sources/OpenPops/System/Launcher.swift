import AppKit
import OpenPopsCore

/// Opens apps, files, folders and links.
@MainActor
enum Launcher {
    static func exists(_ item: PopItem) -> Bool {
        guard item.isFileBased else { return true }
        return FileManager.default.fileExists(atPath: item.target)
    }

    /// Opens an item. Folders open in Finder here; browsing inside a Pop is handled by the popover.
    static func open(_ item: PopItem) {
        switch item.kind {
        case .app:
            openApp(URL(fileURLWithPath: item.target))
        case .file, .folder:
            open(url: URL(fileURLWithPath: item.target))
        case .link:
            if let url = item.linkURL { open(url: url) }
        }
    }

    static func openApp(_ url: URL) {
        if let id = Bundle(url: url)?.bundleIdentifier {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: id)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.promptsUserIfNeeded = true
        DebugLog.log("launch app \(url.path)")
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error = error {
                Task { @MainActor in present(error, for: url) }
            }
        }
    }

    /// Opens a file, folder or web URL with its default app.
    static func open(url: URL) {
        if let app = NSWorkspace.shared.urlForApplication(toOpen: url),
           let id = Bundle(url: app)?.bundleIdentifier {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: id)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.promptsUserIfNeeded = true
        DebugLog.log("open \(url.isFileURL ? url.path : url.absoluteString)")
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            if let error = error {
                Task { @MainActor in present(error, for: url) }
            }
        }
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func openAll(_ items: [PopItem]) {
        for item in items where exists(item) {
            open(item)
        }
    }

    private static func present(_ error: Error, for url: URL) {
        let ns = error as NSError
        // The user cancelled a prompt; nothing to report.
        if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return }
        let alert = NSAlert(error: error)
        alert.messageText = "Couldn't open “\(url.isFileURL ? url.lastPathComponent : url.absoluteString)”"
        NSApp.activate()
        alert.runModal()
    }
}
