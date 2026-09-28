import AppKit
import SwiftUI
import OpenPopsCore

struct PopEditorView: View {
    let popID: UUID
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var state: OrganizerState

    enum EditorTab: String, CaseIterable, Identifiable {
        case items = "Items"
        case appearance = "Appearance"
        case dockIcon = "Dock Icon"
        var id: String { rawValue }
    }

    var body: some View {
        if let pop = model.popBinding(popID) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header(pop)
                    Picker("", selection: $state.editorTab) {
                        ForEach(EditorTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    Divider()
                    switch state.editorTab {
                    case .items: ItemsEditor(pop: pop)
                    case .appearance: AppearanceEditor(pop: pop)
                    case .dockIcon: DockIconEditor(pop: pop)
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity)
                Divider()
                PreviewPane(pop: pop.wrappedValue)
                    .frame(width: 320)
            }
        }
    }

    private func header(_ pop: Binding<Pop>) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: IconCache.shared.icon(for: pop.wrappedValue, pixels: 128))
                .resizable()
                .frame(width: 40, height: 40)
            TextField("Name", text: pop.name)
                .textFieldStyle(.plain)
                .font(.title2.bold())
            Spacer()
            Text(pop.wrappedValue.items.count == 1 ? "1 item" : "\(pop.wrappedValue.items.count) items")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

// MARK: Items

struct ItemsEditor: View {
    @Binding var pop: Pop
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var state: OrganizerState
    @State private var selection = Set<UUID>()
    @State private var showBrowser = false
    @State private var showLink = false
    @State private var showSuggestions = false

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                addButtons.labelStyle(.titleAndIcon)
                addButtons.labelStyle(.iconOnly)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            List(selection: $selection) {
                ForEach(pop.items) { item in
                    ItemRow(item: item, popID: pop.id)
                        .tag(item.id)
                }
                .onMove { from, to in
                    let id = pop.id
                    model.update { lib in
                        lib.updatePop(id) {
                            $0.items.opMove(fromOffsets: from, toOffset: to)
                            $0.sortMode = .manual
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { pop.items[$0].id }
                    remove(ids)
                }
            }
            .onDeleteCommand { remove(Array(selection)) }
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls: urls, to: pop.id) > 0
            }
            .overlay {
                if pop.items.isEmpty {
                    ContentUnavailableView("No items yet", systemImage: "tray",
                                           description: Text("Drop apps, files, folders or links here, or use the buttons above."))
                }
            }

            Divider()
            Form {
                Picker("Sort by", selection: $pop.sortMode) {
                    ForEach(SortMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Layout", selection: $pop.layout) {
                    ForEach(PopLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Show in the main carousel", isOn: Binding(get: { !pop.hiddenFromCarousel },
                                                                   set: { pop.hiddenFromCarousel = !$0 }))
            }
            .formStyle(.grouped)
            .frame(height: 160)
        }
        .sheet(isPresented: $showBrowser) { AppBrowserView(popID: pop.id) }
        .sheet(isPresented: $showLink) { AddLinkSheet(popID: pop.id) }
        .sheet(isPresented: $showSuggestions) { SuggestionsSheet(popID: pop.id) }
    }

    private var addButtons: some View {
        HStack(spacing: 10) {
            Button { showBrowser = true } label: { Label("Add Apps…", systemImage: "square.grid.2x2") }
                .help("Add apps from the App Browser")
            Button { state.addFiles(to: pop.id) } label: { Label("Add Files…", systemImage: "doc.badge.plus") }
                .help("Add files or folders")
            Button { showLink = true } label: { Label("Add Link…", systemImage: "link") }
                .help("Add a web link")
            Button { showSuggestions = true } label: { Label("Suggestions", systemImage: "sparkles") }
                .help("Apps that fit this Pop")
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func remove(_ ids: [UUID]) {
        let popID = pop.id
        model.update { lib in
            for id in ids { lib.removeItem(id, from: popID) }
        }
        selection.subtract(ids)
    }
}

struct ItemRow: View {
    let item: PopItem
    let popID: UUID
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var state: OrganizerState

    var body: some View {
        let missing = !Launcher.existsNonisolated(item)
        HStack(spacing: 10) {
            ItemIconView(item: item)
                .frame(width: 28, height: 28)
                .opacity(missing ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(GridEntry.displayName(for: item)).lineLimit(1)
                Text(item.kind == .link ? item.target : (item.target as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Can't be found at this path")
            }
            if item.launchCount > 0 {
                Text("\(item.launchCount)×")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("Times opened from OpenPops")
            }
            Text(item.kind.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Open") { Launcher.open(item) }
            if let url = item.fileURL {
                Button("Show in Finder") { Launcher.reveal([url]) }
            }
            Button("Rename…") { state.renameItem(item, in: popID) }
            let others = model.library.pops.filter { $0.id != popID }
            if !others.isEmpty {
                Menu("Move to") {
                    ForEach(others) { other in
                        Button(other.name) {
                            model.update { $0.moveItem(item.id, from: popID, to: other.id) }
                        }
                    }
                }
            }
            Divider()
            Button("Remove", role: .destructive) {
                model.update { $0.removeItem(item.id, from: popID) }
            }
        }
    }
}

// MARK: Appearance

struct AppearanceEditor: View {
    @Binding var pop: Pop
    @EnvironmentObject var model: AppModel
    @State private var showSaveTheme = false

    var body: some View {
        Form {
            Section("Theme") {
                ThemeGrid(themes: model.library.allThemes, selectedID: pop.themeID) { theme in
                    let id = pop.id
                    model.update { $0.applyTheme(theme, to: id) }
                }
                Button("Save This Look as a Theme…") { showSaveTheme = true }
            }
            Section("Background") {
                FillEditor(fill: $pop.style.background)
                if pop.style.background != .system {
                    LabeledSlider(title: "Glass", value: $pop.style.glass, range: 0...1,
                                  format: { String(format: "%.0f%%", $0 * 100) })
                }
                Picker("Appearance", selection: $pop.style.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Border") {
                BorderEditor(border: $pop.style.border)
            }
            Section("Labels") {
                FontFamilyPicker(family: $pop.style.label.fontFamily)
                LabeledSlider(title: "Size", value: $pop.style.label.size, range: 9...16, step: 0.5,
                              format: { String(format: "%.1f pt", $0) })
                Picker("Weight", selection: $pop.style.label.weight) {
                    ForEach(FontWeightName.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                OptionalColorPicker(title: "Color", color: $pop.style.label.color)
                Toggle("Shadow", isOn: $pop.style.label.shadow)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showSaveTheme) { SaveThemeSheet(popID: pop.id) }
    }
}

// MARK: Dock icon

struct DockIconEditor: View {
    @Binding var pop: Pop

    var body: some View {
        Form {
            Section("Icon") {
                Picker("Style", selection: $pop.dockIcon.mode) {
                    ForEach(DockIconMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                switch pop.dockIcon.mode {
                case .dynamic:
                    Picker("Grid", selection: $pop.dockIcon.density) {
                        ForEach(IconDensity.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("Shows the first items of the Pop, like an iPhone folder, and updates as the Pop changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .glyph:
                    TextField("Glyph", text: $pop.dockIcon.glyph,
                              prompt: Text(String(pop.name.prefix(1)).uppercased()))
                    OptionalColorPicker(title: "Glyph color", color: $pop.dockIcon.glyphColor,
                                        automaticDefault: .white)
                case .custom:
                    HStack {
                        Text(pop.dockIcon.customImagePath.map { ($0 as NSString).lastPathComponent } ?? "No image chosen")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Choose Image…") {
                            if let path = ImageStore.chooseImage() { pop.dockIcon.customImagePath = path }
                        }
                    }
                }
            }
            Section("Tile Background") {
                Toggle("Match the popover", isOn: $pop.dockIcon.matchPopBackground)
                if !pop.dockIcon.matchPopBackground {
                    FillEditor(fill: $pop.dockIcon.background, allowSystem: false)
                }
            }
            Section("Dock Tile") {
                DockTileControls(target: .pop(pop.id), name: pop.name)
            }
        }
        .formStyle(.grouped)
    }
}

struct DockTileControls: View {
    let target: TileTarget
    let name: String
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var state: OrganizerState

    var body: some View {
        let hasTile = model.library.tile(for: target) != nil
        let pinned = hasTile && state.isPinned(target)
        VStack(alignment: .leading, spacing: 10) {
            Text(pinned
                 ? "“\(name)” has its own icon in the Dock."
                 : "Give “\(name)” its own icon in the Dock. Clicking it opens just this, right above the icon.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if pinned {
                    Button("Remove from Dock") { state.removeFromDock(target) }
                } else {
                    Button("Add to Dock") { state.addToDock(target) }
                        .buttonStyle(.borderedProminent)
                }
                if hasTile {
                    Button("Show in Finder") { state.tiles.reveal(target) }
                }
            }
            Text("Adding one restarts the Dock once. Tile apps live in ~/Applications/OpenPops Tiles; you can also drag them into the Dock yourself.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Preview

struct PreviewPane: View {
    let pop: Pop
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var state: OrganizerState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preview").font(.headline)
            PopoverPreview(pop: pop, settings: model.library.settings)
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 400)
            HStack(spacing: 14) {
                Image(nsImage: IconCache.shared.icon(for: pop, pixels: 256))
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dock icon").font(.subheadline.bold())
                    Text(pop.dockIcon.mode.title).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Button {
                state.onPreviewPop?(pop.id)
            } label: {
                Label("Open This Pop", systemImage: "rectangle.on.rectangle")
            }
            Spacer()
        }
        .padding(16)
    }
}
