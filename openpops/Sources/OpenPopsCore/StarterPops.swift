import Foundation

/// Pops created on first launch, filled with whichever of these apps and folders exist.
public struct StarterTemplate: Sendable {
    public var name: String
    public var themeID: String
    /// Absolute paths; a leading "~" means the home folder.
    public var paths: [String]
}

public enum StarterPops {
    public static let templates: [StarterTemplate] = [
        StarterTemplate(name: "Everyday", themeID: BuiltInThemes.systemID, paths: [
            "/Applications/Safari.app",
            "/System/Applications/Mail.app",
            "/System/Applications/Calendar.app",
            "/System/Applications/Notes.app",
            "/System/Applications/Reminders.app",
            "/System/Applications/Messages.app",
            "/System/Applications/Photos.app",
            "/System/Applications/Music.app",
            "/System/Applications/Maps.app",
        ]),
        StarterTemplate(name: "Utilities", themeID: "graphite", paths: [
            "/System/Applications/System Settings.app",
            "/System/Applications/Utilities/Activity Monitor.app",
            "/System/Applications/Utilities/Terminal.app",
            "/System/Applications/Utilities/Disk Utility.app",
            "/System/Applications/Utilities/Console.app",
            "/System/Applications/Utilities/Screenshot.app",
            "/System/Applications/Preview.app",
            "/System/Applications/Calculator.app",
            "/System/Applications/TextEdit.app",
        ]),
        StarterTemplate(name: "Folders", themeID: "ocean", paths: [
            "~",
            "~/Desktop",
            "~/Documents",
            "~/Downloads",
            "/Applications",
        ]),
    ]

    /// Builds starter Pops. `probe` reports whether a path exists and is a directory/package.
    public static func makePops(home: String, probe: (String) -> (exists: Bool, directory: Bool, package: Bool)) -> [Pop] {
        var result: [Pop] = []
        for t in templates {
            var items: [PopItem] = []
            for raw in t.paths {
                let path = raw == "~" ? home : (raw.hasPrefix("~/") ? home + String(raw.dropFirst(1)) : raw)
                let info = probe(path)
                guard info.exists else { continue }
                let kind = ItemKind.detect(path: path, isDirectory: info.directory, isPackage: info.package)
                items.append(PopItem(kind: kind, target: PopItem.standardizedPath(path)))
            }
            guard !items.isEmpty else { continue }
            let theme = BuiltInThemes.theme(t.themeID) ?? BuiltInThemes.system
            var pop = Pop(name: t.name, items: items, style: theme.style, themeID: theme.id)
            if let dock = theme.dockBackground {
                pop.dockIcon.matchPopBackground = false
                pop.dockIcon.background = dock
            }
            result.append(pop)
        }
        return result
    }
}
