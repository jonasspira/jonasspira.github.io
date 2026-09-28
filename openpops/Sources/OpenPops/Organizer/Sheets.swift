import AppKit
import SwiftUI
import OpenPopsCore

/// Browse installed apps and click to add or remove them from a Pop.
struct AppBrowserView: View {
    let popID: UUID
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var state: OrganizerState
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var category = "all"
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All Apps"
        case notInAnyPop = "Not in Any Pop"
        case recent = "Recently Installed"
        case inThisPop = "In This Pop"
        var id: String { rawValue }
    }

    private var members: Set<String> {
        Set(model.pop(popID)?.items.map(\.identityKey) ?? [])
    }

    private var filtered: [InstalledApp] {
        let inAnyPop = Set(model.library.pops.flatMap { $0.items.map(\.identityKey) })
        let mine = members
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        var apps = state.installedApps.filter { app in
            if !query.isEmpty && !app.name.lowercased().contains(query)
                && !(app.bundleID?.lowercased().contains(query) ?? false) { return false }
            if category != "all" && (app.normalizedCategory ?? AppCategory.other) != category { return false }
            let key = PopItem.standardizedPath(app.path)
            switch filter {
            case .all: return true
            case .notInAnyPop: return !inAnyPop.contains(key)
            case .inThisPop: return mine.contains(key)
            case .recent:
                guard let added = app.addedDate else { return false }
                return Date().timeIntervalSince(added) < 60 * 86_400
            }
        }
        if filter == .recent {
            apps.sort { ($0.addedDate ?? .distantPast) > ($1.addedDate ?? .distantPast) }
        }
        return apps
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search apps", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("Category", selection: $category) {
                    Text("All Categories").tag("all")
                    Divider()
                    ForEach(AppCategory.allCategories, id: \.self) { c in
                        Text(AppCategory.title(for: c)).tag(c)
                    }
                }
                .frame(width: 190)
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 190)
            }
            .labelsHidden()
            .padding(12)
            Divider()
            if state.installedApps.isEmpty {
                ProgressView("Finding apps…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let mine = members
                List(filtered) { app in
                    let isIn = mine.contains(PopItem.standardizedPath(app.path))
                    Button {
                        toggle(app, isIn: isIn)
                    } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: IconProvider.shared.icon(forPath: app.path))
                                .resizable()
                                .frame(width: 26, height: 26)
                            Text(app.name)
                            Spacer()
                            Text(AppCategory.title(for: app.category))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: isIn ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(isIn ? Color.accentColor : Color.secondary)
                                .font(.title3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Text("\(members.count) in “\(model.pop(popID)?.name ?? "")”")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Rescan") { state.loadApps(force: true) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 600)
        .onAppear { state.loadApps() }
    }

    private func toggle(_ app: InstalledApp, isIn: Bool) {
        let key = PopItem.standardizedPath(app.path)
        let popID = self.popID
        if isIn {
            model.update { lib in
                guard let pop = lib.pop(popID) else { return }
                for item in pop.items where item.identityKey == key {
                    lib.removeItem(item.id, from: popID)
                }
            }
        } else {
            let item = PopItem(kind: .app, target: key)
            model.update { $0.addItems([item], to: popID) }
        }
    }
}

/// Apps that fit a Pop, from app categories and vendors, and optionally Apple Intelligence.
struct SuggestionsSheet: View {
    let popID: UUID
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var state: OrganizerState
    @Environment(\.dismiss) private var dismiss
    @State private var aiResults: [InstalledApp] = []
    @State private var aiBusy = false
    @State private var aiError: String?

    private var suggestions: [InstalledApp] {
        guard let pop = model.pop(popID) else { return [] }
        var list = Suggestions.suggest(for: pop, installed: state.installedApps, limit: 16)
        let have = Set(pop.items.map(\.identityKey))
        for app in aiResults where !list.contains(app) { list.insert(app, at: 0) }
        list.removeAll { have.contains(PopItem.standardizedPath($0.path)) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Suggestions for “\(model.pop(popID)?.name ?? "")”").font(.headline)
                Text("Based on the categories and makers of the apps already in it, and on its name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            if state.installedApps.isEmpty {
                ProgressView("Finding apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if suggestions.isEmpty {
                ContentUnavailableView("No suggestions yet", systemImage: "sparkles",
                                       description: Text("Add a few apps to this Pop, or give it a descriptive name like “Design” or “Dev”."))
            } else {
                List(suggestions) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: IconProvider.shared.icon(forPath: app.path))
                            .resizable()
                            .frame(width: 26, height: 26)
                        Text(app.name)
                        if aiResults.contains(app) {
                            Image(systemName: "apple.intelligence")
                                .foregroundStyle(.secondary)
                                .help("Suggested by Apple Intelligence")
                        }
                        Spacer()
                        Text(AppCategory.title(for: app.category)).font(.caption).foregroundStyle(.secondary)
                        Button("Add") { add([app]) }
                    }
                }
            }
            Divider()
            HStack {
                if SmartSuggestions.isAvailable {
                    Button {
                        askAppleIntelligence()
                    } label: {
                        if aiBusy { ProgressView().controlSize(.small) } else { Label("Ask Apple Intelligence", systemImage: "sparkles") }
                    }
                    .disabled(aiBusy)
                }
                if let err = aiError {
                    Text(err).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Add All") { add(suggestions) }.disabled(suggestions.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 520)
        .onAppear { state.loadApps() }
    }

    private func add(_ apps: [InstalledApp]) {
        let items = apps.map { PopItem(kind: .app, target: PopItem.standardizedPath($0.path)) }
        let popID = self.popID
        model.update { $0.addItems(items, to: popID) }
    }

    private func askAppleIntelligence() {
        guard let pop = model.pop(popID) else { return }
        aiBusy = true
        aiError = nil
        let have = Set(pop.items.map(\.identityKey))
        let current = pop.items.filter { $0.kind == .app }.map { GridEntry.displayName(for: $0) }
        let candidates = state.installedApps.filter { !have.contains(PopItem.standardizedPath($0.path)) }
        let byName = Dictionary(candidates.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let name = pop.name
        Task {
            do {
                let names = try await SmartSuggestions.suggest(popName: name, current: current,
                                                               candidates: candidates.map(\.name))
                aiResults = names.compactMap { byName[$0.lowercased()] }
                if aiResults.isEmpty { aiError = "No matches this time." }
            } catch {
                aiError = error.localizedDescription
            }
            aiBusy = false
        }
    }
}

struct AddLinkSheet: View {
    let popID: UUID
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    @State private var name = ""

    private var url: URL? {
        var raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains(":") && raw.contains(".") { raw = "https://" + raw }
        guard let u = URL(string: raw), let scheme = u.scheme, !scheme.isEmpty, !u.isFileURL else { return nil }
        return u
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Link").font(.headline)
            Text("A web address, or any link a Mac app understands, like obsidian:// or zoommtg://.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("https://", text: $urlString)
            TextField("Name (optional)", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let url = url {
                        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.add(urls: [url], titles: title.isEmpty ? [:] : [url: title], to: popID)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url == nil)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string), let u = URL(string: clip),
               u.scheme != nil, !u.isFileURL {
                urlString = clip
            }
        }
    }
}

struct SaveThemeSheet: View {
    let popID: UUID
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as Theme").font(.headline)
            Text("Saves this Pop's background, glass, border and label style so you can apply it to other Pops.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Theme name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let themeID = "custom-" + UUID().uuidString.lowercased()
                    let title = name
                    let popID = self.popID
                    model.update { $0.saveTheme(named: title, from: popID, id: themeID) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = model.pop(popID)?.name ?? "" }
    }
}
