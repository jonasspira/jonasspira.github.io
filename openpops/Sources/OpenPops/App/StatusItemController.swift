import AppKit
import OpenPopsCore

/// The menu bar icon. A click opens the Pop carousel under it, or a quick menu of Pops,
/// depending on settings. A right-click always shows the menu.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private var item: NSStatusItem?

    var onShowCarousel: ((NSRect) -> Void)?
    var onOpenOrganizer: ((UUID?) -> Void)?

    init(model: AppModel) {
        self.model = model
    }

    var isInstalled: Bool { item != nil }

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "OpenPops")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "OpenPops"
        }
        self.item = item
    }

    func remove() {
        if let item = item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// Screen frame of the menu bar icon.
    var buttonFrame: NSRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let right = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if right || model.library.settings.menuBarClick == .menu {
            showMenu(from: sender)
        } else if let frame = buttonFrame {
            onShowCarousel?(frame)
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        for pop in model.library.pops {
            let icon = DockIconRenderer.image(for: pop, pixels: 64)
            icon.size = NSSize(width: 18, height: 18)
            menu.addSubmenu(pop.name) { sub in
                for entry in pop.sortedItems().map(GridEntry.forItem) {
                    guard let item = entry.popItem else { continue }
                    let menuItem = ClosureMenuItem(entry.name) { [weak self] in
                        self?.model.recordLaunch(itemID: item.id, popID: pop.id)
                        Launcher.open(item)
                    }
                    let itemIcon = IconProvider.shared.icon(for: item).copy() as? NSImage
                    itemIcon?.size = NSSize(width: 16, height: 16)
                    menuItem.image = itemIcon
                    menuItem.isEnabled = !entry.isMissing
                    sub.addItem(menuItem)
                }
                if !pop.items.isEmpty { sub.addItem(.separator()) }
                sub.addItem(ClosureMenuItem("Open All") { [weak self] in
                    let popID = pop.id
                    self?.model.update { lib in
                        for i in pop.items { lib.recordLaunch(itemID: i.id, in: popID) }
                    }
                    Launcher.openAll(pop.sortedItems())
                })
                sub.addItem(ClosureMenuItem("Edit “\(pop.name)”…") { [weak self] in self?.onOpenOrganizer?(pop.id) })
            }
            menu.items.last?.image = icon
        }
        if model.library.pops.isEmpty {
            menu.addItem(NSMenuItem(title: "No Pops yet", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Show Carousel") { [weak self] in
            guard let self = self, let frame = self.buttonFrame else { return }
            self.onShowCarousel?(frame)
        })
        menu.addItem(ClosureMenuItem("Open Organizer…", key: ",") { [weak self] in self?.onOpenOrganizer?(nil) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit OpenPops", key: "q") { NSApp.terminate(nil) })
        _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }
}
