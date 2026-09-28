import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OpenPopsCore

/// Selection and shared helpers for the Organizer window.
@MainActor
final class OrganizerState: ObservableObject {
    enum Selection: Hashable {
        case welcome
        case pop(UUID)
        case group(UUID)
        case themes
        case settings
    }

    @Published var selection: Selection? = .welcome
    /// The Pop editor's tab, kept here so it survives switching between Pops.
    @Published var editorTab: PopEditorView.EditorTab = .items
    @Published var installedApps: [InstalledApp] = []
    @Published var isScanning = false
    @Published var alertMessage: String?

    let model: AppModel
    let tiles: TileManager
    var onPreviewPop: ((UUID) -> Void)?

    init(model: AppModel, tiles: TileManager) {
        self.model = model
        self.tiles = tiles
    }

    func loadApps(force: Bool = false) {
        guard force || (installedApps.isEmpty && !isScanning) else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = AppScanner.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.installedApps = apps
                    self.isScanning = false
                }
            }
        }
    }

    func createPop(named name: String = "New Pop") {
        let id = UUID()
        model.update(immediately: true) { $0.addPop(named: name, id: id) }
        selection = .pop(id)
    }

    func createGroup() {
        let id = UUID()
        let members = model.library.pops.prefix(2).map(\.id)
        model.update(immediately: true) { $0.addGroup(named: "New Group", popIDs: Array(members), id: id) }
        selection = .group(id)
    }

    func duplicatePop(_ id: UUID) {
        let newID = UUID()
        model.update(immediately: true) { $0.duplicatePop(id, as: newID) }
        selection = .pop(newID)
    }

    func deletePop(_ id: UUID) {
        guard let pop = model.pop(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(pop.name)”?"
        alert.informativeText = "The Pop and its Dock tile are removed. The apps and files in it are not touched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        tiles.removeFromDock(.pop(id))
        model.update(immediately: true) { $0.deletePop(id) }
        if selection == .pop(id) { selection = model.library.pops.first.map { .pop($0.id) } ?? .welcome }
    }

    func deleteGroup(_ id: UUID) {
        tiles.removeFromDock(.group(id))
        model.update(immediately: true) { $0.deleteGroup(id) }
        if selection == .group(id) { selection = .welcome }
    }

    func addToDock(_ target: TileTarget) {
        do {
            try tiles.addToDock(target)
        } catch {
            alertMessage = error.localizedDescription
        }
        objectWillChange.send()
    }

    func removeFromDock(_ target: TileTarget) {
        tiles.removeFromDock(target)
        objectWillChange.send()
    }

    func isPinned(_ target: TileTarget) -> Bool {
        tiles.isPinned(target)
    }

    func addFiles(to popID: UUID) {
        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = true
        open.allowsMultipleSelection = true
        open.prompt = "Add"
        if open.runModal() == .OK {
            model.add(urls: open.urls, to: popID)
        }
    }

    func renameItem(_ item: PopItem, in popID: UUID) {
        let alert = NSAlert()
        alert.messageText = "Rename “\(GridEntry.displayName(for: item))”"
        alert.informativeText = "Changes the label in the Pop only. Leave it empty to use the original name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = item.customName ?? ""
        field.placeholderString = item.defaultName
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        model.update { lib in
            lib.updateItem(item.id, in: popID) { $0.customName = name.isEmpty ? nil : name }
        }
    }

    func exportLibrary() {
        model.flush()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "OpenPops Library.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.store.exportData().write(to: url, options: .atomic)
        } catch {
            alertMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func importLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try LibraryStore.decodeLibrary(from: Data(contentsOf: url))
            let alert = NSAlert()
            alert.messageText = "Replace your Pops with \(imported.pops.count) imported Pops?"
            alert.informativeText = "Your current library is saved as library.backup.json in the data folder first."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            model.store.makeLaunchBackup()
            model.update(immediately: true) { $0 = imported }
            tiles.maintainTiles()
            selection = .welcome
        } catch {
            alertMessage = "Couldn't read that file: \(error.localizedDescription)"
        }
    }

    func keepMainAppInDock() {
        guard AppInfo.isBundled else { return }
        if DockPrefs.pin(path: Bundle.main.bundlePath, label: "OpenPops", bundleID: AppInfo.mainBundleID) {
            DockPrefs.restartDock()
        }
        objectWillChange.send()
    }

    var mainAppIsPinned: Bool {
        DockPrefs.isPinned(path: Bundle.main.bundlePath)
    }
}

/// Copies images chosen for backgrounds and Dock icons into the data folder, so the Pop
/// keeps working if the original file moves.
@MainActor
enum ImageStore {
    static var folder: URL { LibraryStore.defaultDirectory.appendingPathComponent("Images", isDirectory: true) }

    static func chooseImage() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Image"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let dest = folder.appendingPathComponent(UUID().uuidString + "." + ext)
        do {
            try fm.copyItem(at: url, to: dest)
            return dest.path
        } catch {
            return url.path
        }
    }
}

@MainActor
final class OrganizerWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    let state: OrganizerState
    private let model: AppModel
    var onClose: (() -> Void)?
    var onPreviewPop: ((UUID) -> Void)? {
        get { state.onPreviewPop }
        set { state.onPreviewPop = newValue }
    }

    init(model: AppModel, tiles: TileManager) {
        self.model = model
        state = OrganizerState(model: model, tiles: tiles)
        let root = OrganizerView()
            .environmentObject(model)
            .environmentObject(state)
        let hosting = NSHostingController(rootView: root)
        window = NSWindow(contentViewController: hosting)
        window.title = "OpenPops"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1040, height: 700))
        window.minSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        if !window.setFrameUsingName("OpenPopsOrganizer") { window.center() }
        window.setFrameAutosaveName("OpenPopsOrganizer")
        if !model.library.settings.hasCompletedOnboarding {
            state.selection = .welcome
        } else if let first = model.library.pops.first {
            state.selection = .pop(first.id)
        }
    }

    var isVisible: Bool { window.isVisible }

    func show(selecting popID: UUID?) {
        if let id = popID, model.pop(id) != nil { state.selection = .pop(id) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DebugLog.log("organizer shown")
    }

    func createPop() {
        state.createPop()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    /// For snapshots in the self-test.
    var contentView: NSView? { window.contentView }
    var windowFrame: NSRect { window.frame }
}
