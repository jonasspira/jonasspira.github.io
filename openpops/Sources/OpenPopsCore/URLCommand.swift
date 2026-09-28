import Foundation

/// Commands the app accepts through `openpops://` links, for Shortcuts, Raycast, Alfred,
/// keyboard launchers and scripts.
///
///     openpops://show                      the carousel
///     openpops://show?pop=Work             one Pop (name or id)
///     openpops://show?group=Projects       a Pop Group
///     openpops://organizer?pop=Work        the Organizer, optionally on a Pop
///     openpops://add?pop=Work&url=https://example.com&name=Example
///     openpops://add?pop=Work&path=/Users/me/Notes.txt
///     openpops://popout?pop=Work           a floating Pop Out window
///     openpops://openall?pop=Work          launch everything in a Pop
///     openpops://tile?pop=Work&pin=1       create (and pin) a Dock tile
public enum URLCommand: Equatable, Sendable {
    case show(pop: String?)
    case showGroup(String)
    case organizer(pop: String?)
    case add(pop: String?, target: String, name: String?)
    case popOut(pop: String)
    case openAll(pop: String)
    case makeTile(pop: String?, group: String?, pin: Bool)

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "openpops" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? {
            guard let v = items.first(where: { $0.name.lowercased() == name })?.value else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var host = (url.host ?? "").lowercased()
        if host.isEmpty {
            // Accept "openpops:show?pop=x" as well as "openpops://show?pop=x".
            host = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        }
        switch host {
        case "", "show", "open":
            if let g = q("group") {
                self = .showGroup(g)
            } else {
                self = .show(pop: q("pop"))
            }
        case "organizer", "organize", "settings", "edit":
            self = .organizer(pop: q("pop"))
        case "add":
            guard let target = q("url") ?? q("path") else { return nil }
            self = .add(pop: q("pop"), target: target, name: q("name"))
        case "popout", "pop-out":
            guard let pop = q("pop") else { return nil }
            self = .popOut(pop: pop)
        case "openall", "open-all":
            guard let pop = q("pop") else { return nil }
            self = .openAll(pop: pop)
        case "tile":
            let pop = q("pop"), group = q("group")
            guard pop != nil || group != nil else { return nil }
            self = .makeTile(pop: pop, group: group, pin: q("pin") != "0")
        default:
            return nil
        }
    }

    /// Builds the item an `add` command describes: a link for web URLs, a file item for paths.
    public static func item(forTarget target: String, name: String?, isDirectory: (String) -> (exists: Bool, directory: Bool, package: Bool)) -> PopItem? {
        if target.hasPrefix("/") || target.hasPrefix("~") || target.lowercased().hasPrefix("file://") {
            var path = target
            if target.lowercased().hasPrefix("file://"), let url = URL(string: target) { path = url.path }
            path = (path as NSString).expandingTildeInPath
            let info = isDirectory(path)
            guard info.exists else { return nil }
            let kind = ItemKind.detect(path: path, isDirectory: info.directory, isPackage: info.package)
            return PopItem(kind: kind, target: PopItem.standardizedPath(path), customName: name)
        }
        guard let url = URL(string: target), let scheme = url.scheme, !scheme.isEmpty else { return nil }
        return PopItem(kind: .link, target: target, customName: name)
    }
}
