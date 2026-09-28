import AppKit
import SwiftUI
import OpenPopsCore

// MARK: Bindings

extension AppModel {
    func popBinding(_ id: UUID) -> Binding<Pop>? {
        guard library.pop(id) != nil else { return nil }
        return Binding(
            get: { [unowned self] in self.library.pop(id) ?? Pop(id: id, name: "") },
            set: { [unowned self] newValue in
                self.update { lib in lib.updatePop(id) { $0 = newValue } }
            })
    }

    func groupBinding(_ id: UUID) -> Binding<PopGroup>? {
        guard library.group(id) != nil else { return nil }
        return Binding(
            get: { [unowned self] in self.library.group(id) ?? PopGroup(id: id, name: "") },
            set: { [unowned self] newValue in
                self.update { lib in lib.updateGroup(id) { $0 = newValue } }
            })
    }

    var settingsBinding: Binding<AppSettings> {
        Binding(
            get: { [unowned self] in self.library.settings },
            set: { [unowned self] newValue in self.update { $0.settings = newValue } })
    }
}

func colorBinding(_ value: RGBA, set: @escaping (RGBA) -> Void) -> Binding<Color> {
    Binding(get: { Color(nsColor: value.nsColor) }, set: { set(RGBA(NSColor($0))) })
}

extension GradientSpec {
    var swiftUIGradient: LinearGradient {
        let p = unitPoints
        // SwiftUI's unit points have a top-left origin.
        return LinearGradient(colors: colors.map { Color(nsColor: $0.nsColor) },
                              startPoint: UnitPoint(x: p.start.x, y: 1 - p.start.y),
                              endPoint: UnitPoint(x: p.end.x, y: 1 - p.end.y))
    }
}

// MARK: Controls

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var format: (Double) -> String = { String(format: "%.0f", $0) }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                if let step = step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
            }
        }
    }
}

/// A color picker with an "Automatic" switch for optional colors.
struct OptionalColorPicker: View {
    let title: String
    @Binding var color: RGBA?
    var automaticDefault = RGBA(0.2, 0.2, 0.2)

    var body: some View {
        LabeledContent(title) {
            HStack {
                Toggle("Automatic", isOn: Binding(
                    get: { color == nil },
                    set: { color = $0 ? nil : automaticDefault }))
                .toggleStyle(.checkbox)
                if let c = color {
                    ColorPicker("", selection: colorBinding(c) { color = $0 }, supportsOpacity: true)
                        .labelsHidden()
                }
            }
        }
    }
}

struct GradientEditor: View {
    @Binding var gradient: GradientSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Array(gradient.colors.enumerated()), id: \.offset) { index, c in
                    ColorPicker("", selection: colorBinding(c) { gradient.colors[index] = $0 }, supportsOpacity: false)
                        .labelsHidden()
                }
                Button {
                    let last = gradient.colors.last ?? .white
                    gradient.colors.append(last.mixed(with: .white, 0.3))
                } label: { Image(systemName: "plus") }
                .disabled(gradient.colors.count >= 5)
                .help("Add a color")
                Button {
                    gradient.colors.removeLast()
                } label: { Image(systemName: "minus") }
                .disabled(gradient.colors.count <= 2)
                .help("Remove the last color")
                Spacer()
                RoundedRectangle(cornerRadius: 6)
                    .fill(gradient.swiftUIGradient)
                    .frame(width: 70, height: 24)
            }
            LabeledSlider(title: "Angle", value: $gradient.angle, range: 0...360, step: 15,
                          format: { String(format: "%.0f°", $0) })
        }
    }
}

struct FillEditor: View {
    @Binding var fill: BackgroundFill
    var allowSystem = true

    private var kind: Binding<String> {
        Binding(
            get: { fill.kindName },
            set: { newKind in
                guard newKind != fill.kindName else { return }
                let base = fill.representativeColor ?? RGBA(hex: "#3A6EA5") ?? .black
                switch newKind {
                case "system": fill = .system
                case "color": fill = .color(base)
                case "gradient": fill = .gradient(GradientSpec(colors: [base.mixed(with: .black, 0.25), base.mixed(with: .white, 0.3)]))
                case "image":
                    if let path = ImageStore.chooseImage() { fill = .image(path) }
                default: break
                }
            })
    }

    var body: some View {
        Picker("Fill", selection: kind) {
            if allowSystem { Text("Material").tag("system") }
            Text("Color").tag("color")
            Text("Gradient").tag("gradient")
            Text("Photo").tag("image")
        }
        .pickerStyle(.segmented)
        switch fill {
        case .system:
            Text("The standard translucent popover material. It follows Light and Dark mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .color(let c):
            ColorPicker("Color", selection: colorBinding(c) { fill = .color($0) }, supportsOpacity: false)
        case .gradient(let g):
            GradientEditor(gradient: Binding(get: { g }, set: { fill = .gradient($0) }))
        case .image(let path):
            HStack(spacing: 10) {
                Image(nsImage: NSImage(contentsOfFile: path) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text((path as NSString).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") {
                    if let p = ImageStore.chooseImage() { fill = .image(p) }
                }
            }
        }
    }
}

struct BorderEditor: View {
    @Binding var border: BorderStyle

    private var kind: Binding<String> {
        Binding(
            get: { border.kindName },
            set: { newKind in
                let width = max(border.width, 1)
                switch newKind {
                case "color": border = .color(RGBA(1, 1, 1, 0.5), width: width)
                case "gradient":
                    border = .gradient(GradientSpec(colors: [RGBA(hex: "#6C7BFF")!, RGBA(hex: "#C86CFF")!], angle: 0), width: width)
                default: border = .none
                }
            })
    }

    var body: some View {
        Picker("Border", selection: kind) {
            Text("Hairline").tag("none")
            Text("Color").tag("color")
            Text("Gradient").tag("gradient")
        }
        .pickerStyle(.segmented)
        switch border {
        case .none:
            EmptyView()
        case .color(let c, let w):
            ColorPicker("Color", selection: colorBinding(c) { border = .color($0, width: w) }, supportsOpacity: true)
            LabeledSlider(title: "Width", value: Binding(get: { w }, set: { border = .color(c, width: $0) }),
                          range: 0.5...4, step: 0.5, format: { String(format: "%.1f pt", $0) })
        case .gradient(let g, let w):
            GradientEditor(gradient: Binding(get: { g }, set: { border = .gradient($0, width: w) }))
            LabeledSlider(title: "Width", value: Binding(get: { w }, set: { border = .gradient(g, width: $0) }),
                          range: 0.5...4, step: 0.5, format: { String(format: "%.1f pt", $0) })
        }
    }
}

struct FontFamilyPicker: View {
    @Binding var family: String?
    private static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Picker("Font", selection: Binding(get: { family ?? "" }, set: { family = $0.isEmpty ? nil : $0 })) {
            Text("System").tag("")
            Divider()
            ForEach(Self.families, id: \.self) { name in
                Text(name).tag(name)
            }
        }
    }
}

// MARK: Themes

/// A small picture of a theme: its fill, border and placeholder icons in the label color.
struct ThemeSwatch: View {
    let style: PopStyle
    var size = CGSize(width: 78, height: 54)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let isDark = style.resolvedDarkAppearance ?? false
        let label = Color(nsColor: style.resolvedLabelColor(isDark: isDark).nsColor)
        ZStack {
            fill.clipShape(shape)
            VStack(spacing: 5) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 3).fill(label.opacity(0.75)).frame(width: 12, height: 12)
                        }
                    }
                }
            }
            border(shape)
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder private var fill: some View {
        switch style.background {
        case .system:
            Rectangle().fill(.regularMaterial)
        case .color(let c):
            Color(nsColor: c.withAlpha(1).nsColor)
        case .gradient(let g):
            Rectangle().fill(g.swiftUIGradient)
        case .image(let path):
            Image(nsImage: NSImage(contentsOfFile: path) ?? NSImage()).resizable().aspectRatio(contentMode: .fill)
        }
    }

    @ViewBuilder private func border(_ shape: RoundedRectangle) -> some View {
        switch style.border {
        case .none:
            shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        case .color(let c, let w):
            shape.strokeBorder(Color(nsColor: c.nsColor), lineWidth: CGFloat(w))
        case .gradient(let g, let w):
            shape.strokeBorder(g.swiftUIGradient, lineWidth: CGFloat(w))
        }
    }
}

struct ThemeGrid: View {
    let themes: [Theme]
    let selectedID: String?
    let onPick: (Theme) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
            ForEach(themes) { theme in
                Button {
                    onPick(theme)
                } label: {
                    VStack(spacing: 4) {
                        ThemeSwatch(style: theme.style)
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: theme.id == selectedID ? 2.5 : 0)
                                    .padding(-3))
                        Text(theme.name).font(.caption).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("Apply \(theme.name)")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Icons and previews

/// Dock icon images for the Organizer, cached so lists don't redraw them on every change.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [Int: (image: NSImage, created: Date)] = [:]

    /// Entries younger than a few seconds may contain placeholder item icons, so they're redrawn.
    private func lookup(_ key: Int, make: () -> NSImage) -> NSImage {
        if let hit = cache[key], Date().timeIntervalSince(hit.created) > 3 { return hit.image }
        let image = make()
        if cache.count > 300 { cache.removeAll() }
        cache[key] = (image, cache[key]?.created ?? Date())
        return image
    }

    func icon(for pop: Pop, pixels: Int = 128) -> NSImage {
        var h = Hasher()
        h.combine(pop.dockIcon)
        h.combine(pop.style.background)
        h.combine(pop.name)
        h.combine(pixels)
        for item in pop.sortedItems().prefix(16) { h.combine(item.target) }
        return lookup(h.finalize()) { DockIconRenderer.image(for: pop, pixels: pixels) }
    }

    func icon(forGroup group: PopGroup, pops: [Pop], pixels: Int = 128) -> NSImage {
        var h = Hasher()
        h.combine(group.dockIcon)
        h.combine(group.name)
        h.combine(pixels)
        for p in pops {
            h.combine(p.dockIcon)
            h.combine(p.style.background)
            for item in p.sortedItems().prefix(9) { h.combine(item.target) }
        }
        return lookup(h.finalize()) { DockIconRenderer.image(forGroup: group, pops: pops, pixels: pixels) }
    }
}

/// An item icon that redraws itself shortly after appearing, replacing any placeholder.
struct ItemIconView: View {
    let item: PopItem
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? IconProvider.shared.icon(for: item))
            .resizable()
            .task(id: item.target) {
                for delay in [400_000_000, 1_200_000_000] as [UInt64] {
                    try? await Task.sleep(nanoseconds: delay)
                    image = IconProvider.shared.settledIcon(for: item)
                }
            }
    }
}

struct PathIconView: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? IconProvider.shared.icon(forPath: path))
            .resizable()
            .task(id: path) {
                for delay in [400_000_000, 1_200_000_000] as [UInt64] {
                    try? await Task.sleep(nanoseconds: delay)
                    image = IconProvider.shared.settledIcon(forPath: path)
                }
            }
    }
}

/// A live, non-interactive rendering of a Pop's popover for the Organizer.
struct PopoverPreview: NSViewRepresentable {
    let pop: Pop
    let settings: AppSettings

    func makeNSView(context: Context) -> PopoverPreviewNSView {
        PopoverPreviewNSView()
    }

    func updateNSView(_ view: PopoverPreviewNSView, context: Context) {
        view.configure(pop: pop, settings: settings)
    }
}

final class PopoverPreviewNSView: NSView {
    private let content = PopoverContentView()
    private var naturalSize = CGSize(width: 240, height: 200)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(content)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(pop: Pop, settings: AppSettings) {
        let appearance = PopAppearance(style: pop.style)
        let spec = settings.gridSpec(labelFontSize: pop.style.label.size, layout: pop.layout)
        let entries = ItemSorter.sorted(pop.items, by: pop.sortMode, name: { GridEntry.displayName(for: $0) })
            .map(GridEntry.forItem)
        let metrics = GridLayoutEngine.metrics(count: entries.count, spec: spec, fixedColumns: settings.columns,
                                               maxColumns: settings.maxColumns)
        let body = GridLayoutEngine.bodyLayout(for: metrics, chrome: content.chrome,
                                               maxBodySize: CGSize(width: 900, height: 420))
        naturalSize = CGSize(width: body.size.width, height: body.size.height + CGFloat(PopoverGeometry.arrowLength))
        content.appearance = appearance.nsAppearance
        content.background.edge = .bottom
        content.background.fixedArrowPosition = naturalSize.width / 2
        content.background.apply(style: pop.style, appearance: appearance)
        content.header.configure(title: pop.name, backTitle: nil,
                                 count: settings.showItemCount ? pop.items.count : nil,
                                 canSwitch: false, appearance: appearance)
        content.footer.configure(pageIndex: 0, pageCount: 1, showDots: false, appearance: appearance, confirmText: nil)
        let grid = PopGridView()
        grid.allowsReordering = false
        grid.configure(entries: entries, metrics: metrics,
                       style: CellStyle(appearance: appearance, spec: spec, hover: settings.hoverHighlight,
                                        pressFeedback: false))
        content.installPage(grid, transition: nil, duration: 0, reduceMotion: true)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Scale down to fit, keeping the popover's own layout at its natural size.
        let scale = min(1, bounds.width / max(naturalSize.width, 1), bounds.height / max(naturalSize.height, 1))
        let w = naturalSize.width * scale, h = naturalSize.height * scale
        content.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        content.bounds = NSRect(origin: .zero, size: naturalSize)
        content.needsLayout = true
    }
}
