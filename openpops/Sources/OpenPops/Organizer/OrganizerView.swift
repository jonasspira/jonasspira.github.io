import AppKit
import SwiftUI
import OpenPopsCore

struct OrganizerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var state: OrganizerState

    var body: some View {
        NavigationSplitView {
            OrganizerSidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("OpenPops", isPresented: Binding(get: { state.alertMessage != nil },
                                                set: { if !$0 { state.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.alertMessage ?? "")
        }
        .onAppear { state.loadApps() }
    }

    @ViewBuilder private var detail: some View {
        switch state.selection {
        case .pop(let id)?:
            if model.library.pop(id) != nil {
                PopEditorView(popID: id).id(id)
            } else {
                WelcomeView()
            }
        case .group(let id)?:
            if model.library.group(id) != nil {
                GroupEditorView(groupID: id).id(id)
            } else {
                WelcomeView()
            }
        case .themes?:
            ThemesView()
        case .settings?:
            SettingsView()
        case .welcome?, nil:
            WelcomeView()
        }
    }
}

/// List selection is optional, so row tags must be optional too.
private func sel(_ s: OrganizerState.Selection) -> OrganizerState.Selection? { s }

struct OrganizerSidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var state: OrganizerState

    var body: some View {
        List(selection: $state.selection) {
            Section("Pops") {
                ForEach(model.library.pops) { pop in
                    PopRow(pop: pop)
                        .tag(sel(.pop(pop.id)))
                        .contextMenu { popMenu(pop) }
                }
                .onMove { from, to in
                    model.update { $0.movePops(fromOffsets: from, toOffset: to) }
                }
            }
            Section("Groups") {
                ForEach(model.library.groups) { group in
                    GroupRow(group: group)
                        .tag(sel(.group(group.id)))
                        .contextMenu {
                            Button("Delete Group", role: .destructive) { state.deleteGroup(group.id) }
                        }
                }
                .onMove { from, to in
                    model.update { $0.groups.opMove(fromOffsets: from, toOffset: to) }
                }
            }
            Section {
                Label("Themes", systemImage: "paintpalette").tag(sel(.themes))
                Label("Settings", systemImage: "gearshape").tag(sel(.settings))
                Label("Getting Started", systemImage: "questionmark.circle").tag(sel(.welcome))
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    state.createPop()
                } label: {
                    Label("New Pop", systemImage: "plus")
                }
                .help("New Pop (⌘N)")
                Button {
                    state.createGroup()
                } label: {
                    Label("New Group", systemImage: "square.stack")
                }
                .help("Several Pops behind one Dock icon")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder private func popMenu(_ pop: Pop) -> some View {
        Button("Open Pop") { state.onPreviewPop?(pop.id) }
        Button("Duplicate") { state.duplicatePop(pop.id) }
        Button(pop.hiddenFromCarousel ? "Show in Main Carousel" : "Hide from Main Carousel") {
            let id = pop.id
            model.update { $0.updatePop(id) { $0.hiddenFromCarousel.toggle() } }
        }
        Divider()
        if state.isPinned(.pop(pop.id)) {
            Button("Remove from Dock") { state.removeFromDock(.pop(pop.id)) }
        } else {
            Button("Add to Dock") { state.addToDock(.pop(pop.id)) }
        }
        Divider()
        Button("Delete…", role: .destructive) { state.deletePop(pop.id) }
    }
}

struct PopRow: View {
    let pop: Pop

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: IconCache.shared.icon(for: pop, pixels: 64))
                .resizable()
                .frame(width: 24, height: 24)
            Text(pop.name).lineLimit(1)
            Spacer()
            if pop.hiddenFromCarousel {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .help("Hidden from the main carousel")
            }
            Text("\(pop.items.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

struct GroupRow: View {
    let group: PopGroup
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: IconCache.shared.icon(forGroup: group, pops: model.library.pops(inGroup: group.id), pixels: 64))
                .resizable()
                .frame(width: 24, height: 24)
            Text(group.name).lineLimit(1)
            Spacer()
            Text("\(group.popIDs.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var state: OrganizerState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable()
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenPops").font(.largeTitle.bold())
                        Text("Folders of apps, files, folders and links that open from your Dock.")
                            .foregroundStyle(.secondary)
                    }
                }

                step(1, "Keep OpenPops in the Dock",
                     "Its icon is how you open your Pops. It stays after you quit if you keep it in the Dock.") {
                    if state.mainAppIsPinned {
                        Label("OpenPops is in your Dock", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Keep in Dock") { state.keepMainAppInDock() }
                    }
                }
                step(2, "Click the icon",
                     "Your Pops open right above it. Swipe with two fingers, click the dots, or press ← and → to move between Pops. Click an app to open it.")
                step(3, "Fill your Pops",
                     "Drag apps, files, folders or links onto the OpenPops icon or into an open Pop. Drag an item off the Pop to remove it, or drag it inside the Pop to reorder. Pick a Pop on the left to edit it here.")
                step(4, "Give a Pop its own Dock icon",
                     "Select a Pop, open the Dock Icon tab and click Add to Dock. That icon opens just that Pop. Groups do the same for a set of Pops.")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Keyboard").font(.headline)
                    shortcut("← → ↑ ↓", "Move between items (and on to the next Pop at the edges)")
                    shortcut("Return", "Open the selected item")
                    shortcut("Space", "Quick Look the selected or hovered file")
                    shortcut("Esc", "Close Quick Look, leave a folder, or close the Pop")
                    shortcut("⌘1 – ⌘9, Tab", "Jump to a Pop, or go to the next one")
                    shortcut("Type a name", "Select the first matching item")
                    shortcut("⌘ click", "Show in Finder instead of opening")
                    shortcut("⌥ click", "Open a folder in Finder instead of browsing it")
                    shortcut("⌘⌫", "Remove the selected item from the Pop")
                }

                if !model.library.settings.hasCompletedOnboarding {
                    Button {
                        model.update { $0.settings.hasCompletedOnboarding = true }
                        state.selection = model.library.pops.first.map { .pop($0.id) } ?? .welcome
                    } label: {
                        Text("Start Organizing").frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(32)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        step(n, title, text) { EmptyView() }
    }

    private func step<Accessory: View>(_ n: Int, _ title: String, _ text: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                accessory()
            }
        }
    }

    private func shortcut(_ keys: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .frame(width: 130, alignment: .leading)
            Text(text).foregroundStyle(.secondary)
        }
    }
}
