import AppKit
import SwiftUI
import OpenPopsCore

struct GroupEditorView: View {
    let groupID: UUID
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var state: OrganizerState

    var body: some View {
        if let group = model.groupBinding(groupID) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(nsImage: IconCache.shared.icon(forGroup: group.wrappedValue,
                                                             pops: model.library.pops(inGroup: groupID), pixels: 128))
                            .resizable()
                            .frame(width: 44, height: 44)
                        TextField("Name", text: group.name)
                            .textFieldStyle(.plain)
                            .font(.title2.bold())
                    }
                    Text("A group puts several Pops behind one Dock icon. Clicking it opens those Pops, and you swipe between them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Pops in this group") {
                    ForEach(model.library.pops) { pop in
                        Toggle(isOn: membership(pop.id, group: group)) {
                            HStack(spacing: 8) {
                                Image(nsImage: IconCache.shared.icon(for: pop, pixels: 64))
                                    .resizable()
                                    .frame(width: 20, height: 20)
                                Text(pop.name)
                            }
                        }
                    }
                    Text("Pops appear in the order they have in the sidebar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Dock Icon") {
                    Picker("Style", selection: group.dockIcon.mode) {
                        Text("Its Pops").tag(DockIconMode.dynamic)
                        Text("Glyph").tag(DockIconMode.glyph)
                        Text("Custom Image").tag(DockIconMode.custom)
                    }
                    .pickerStyle(.segmented)
                    if group.wrappedValue.dockIcon.mode == .glyph {
                        TextField("Glyph", text: group.dockIcon.glyph,
                                  prompt: Text(String(group.wrappedValue.name.prefix(1)).uppercased()))
                    }
                    if group.wrappedValue.dockIcon.mode == .custom {
                        HStack {
                            Text(group.wrappedValue.dockIcon.customImagePath.map { ($0 as NSString).lastPathComponent } ?? "No image chosen")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose Image…") {
                                if let path = ImageStore.chooseImage() { group.wrappedValue.dockIcon.customImagePath = path }
                            }
                        }
                    }
                    Toggle("Match the first Pop's background", isOn: group.dockIcon.matchPopBackground)
                    if !group.wrappedValue.dockIcon.matchPopBackground {
                        FillEditor(fill: group.dockIcon.background, allowSystem: false)
                    }
                }
                Section("Dock Tile") {
                    DockTileControls(target: .group(groupID), name: group.wrappedValue.name)
                }
                Section {
                    Button("Delete Group", role: .destructive) { state.deleteGroup(groupID) }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func membership(_ popID: UUID, group: Binding<PopGroup>) -> Binding<Bool> {
        Binding(
            get: { group.wrappedValue.popIDs.contains(popID) },
            set: { isOn in
                let order = model.library.pops.map(\.id)
                var members = Set(group.wrappedValue.popIDs)
                if isOn { members.insert(popID) } else { members.remove(popID) }
                group.wrappedValue.popIDs = order.filter { members.contains($0) }
            })
    }
}

struct ThemesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Themes").font(.largeTitle.bold())
                Text("Apply a theme to any Pop from here or from the Pop's Appearance tab. To make your own, style a Pop and choose Save This Look as a Theme.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 16) {
                    ForEach(model.library.allThemes) { theme in
                        ThemeCard(theme: theme)
                    }
                }
            }
            .padding(28)
        }
    }
}

struct ThemeCard: View {
    let theme: Theme
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemeSwatch(style: theme.style, size: CGSize(width: 170, height: 104))
            HStack {
                Text(theme.name).font(.headline)
                Spacer()
                Menu {
                    ForEach(model.library.pops) { pop in
                        Button(pop.name) {
                            let id = pop.id
                            model.update { $0.applyTheme(theme, to: id) }
                        }
                    }
                    Divider()
                    Button("Apply to All Pops") {
                        model.update { lib in
                            for pop in lib.pops { lib.applyTheme(theme, to: pop.id) }
                        }
                    }
                    if !theme.isBuiltIn {
                        Divider()
                        Button("Delete Theme", role: .destructive) {
                            let id = theme.id
                            model.update { $0.deleteTheme(id) }
                        }
                    }
                } label: {
                    Text("Apply")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var state: OrganizerState
    @State private var loginEnabled = LoginItem.isEnabled

    var body: some View {
        let s = model.settingsBinding
        Form {
            Section("OpenPops") {
                Picker("Show OpenPops in", selection: s.presentation) {
                    ForEach(Presentation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if s.wrappedValue.presentation.showsStatusItem {
                    Picker("Clicking the menu bar icon", selection: s.menuBarClick) {
                        ForEach(MenuBarClick.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Toggle("Open at login", isOn: $loginEnabled)
                    .onChange(of: loginEnabled) { _, newValue in
                        if let error = LoginItem.setEnabled(newValue) {
                            state.alertMessage = "Couldn't change the login item: \(error)"
                            loginEnabled = LoginItem.isEnabled
                        }
                    }
                if LoginItem.needsApproval {
                    Button("Approve in System Settings…") { LoginItem.openSystemSettings() }
                }
            }
            Section("Popover") {
                LabeledSlider(title: "Icon size", value: s.iconSize, range: 40...96, step: 4,
                              format: { String(format: "%.0f pt", $0) })
                Toggle("Show labels", isOn: s.showLabels)
                Stepper("Label lines: \(s.wrappedValue.labelLines)", value: s.labelLines, in: 1...3)
                Picker("Columns", selection: s.columns) {
                    Text("Automatic").tag(0)
                    ForEach(2...8, id: \.self) { Text("\($0)").tag($0) }
                }
                LabeledSlider(title: "Spacing", value: s.gridSpacing, range: 0...24, step: 1,
                              format: { String(format: "%.0f pt", $0) })
                LabeledSlider(title: "Gap above the Dock", value: s.dockGap, range: 0...40, step: 1,
                              format: { String(format: "%.0f pt", $0) })
                Picker("Hover highlight", selection: s.hoverHighlight) {
                    ForEach(HoverHighlight.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Shrink icons when pressed", isOn: s.pressFeedback)
                Toggle("Keep the same size while swiping between Pops", isOn: s.lockSizeWhileSwiping)
                Toggle("Show page dots", isOn: s.showPageDots)
                Toggle("Show item count", isOn: s.showItemCount)
                Picker("Animation speed", selection: s.animationSpeed) {
                    ForEach(AnimationSpeed.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Opening Items") {
                Toggle("Close the popover after opening an item", isOn: s.closeAfterLaunch)
                Picker("Clicking a folder", selection: s.folderClick) {
                    ForEach(FolderClickAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Ask before Open All", isOn: s.confirmOpenAll)
            }
            Section("Dock Tiles") {
                Toggle("Show tile apps in Cmd-Tab, with a running dot", isOn: s.tilesInAppSwitcher)
                Text("With this on, a Pop's own Dock icon updates live while its tile app runs. With it off, tiles stay out of the app switcher and their icons refresh when the Dock restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Refresh tile icons when the Organizer closes (restarts the Dock)", isOn: s.autoRefreshDock)
                Button("Refresh Dock Icons Now") {
                    state.tiles.refreshAllIcons()
                    state.tiles.restartDockNow()
                }
            }
            Section("Data") {
                HStack {
                    Button("Export Library…") { state.exportLibrary() }
                    Button("Import Library…") { state.importLibrary() }
                    Button("Show Data Folder") { Launcher.reveal([model.store.fileURL]) }
                }
                if let error = model.storageError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            Section("About") {
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.buildID))")
                Link("OpenPops help and source", destination: AppInfo.readmeURL)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginEnabled = LoginItem.isEnabled }
    }
}
