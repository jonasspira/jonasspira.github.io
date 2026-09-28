import Foundation

// MARK: - Color

/// An sRGB color with components in 0...1. Stored in JSON as "#RRGGBB" or "#RRGGBBAA".
public struct RGBA: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = RGBA.clamp(r)
        self.g = RGBA.clamp(g)
        self.b = RGBA.clamp(b)
        self.a = RGBA.clamp(a)
    }

    /// Parses "#RGB", "#RRGGBB" or "#RRGGBBAA" (the "#" is optional).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(Double((value >> 16) & 0xFF) / 255,
                      Double((value >> 8) & 0xFF) / 255,
                      Double(value & 0xFF) / 255)
        } else {
            self.init(Double((value >> 24) & 0xFF) / 255,
                      Double((value >> 16) & 0xFF) / 255,
                      Double((value >> 8) & 0xFF) / 255,
                      Double(value & 0xFF) / 255)
        }
    }

    public var hexString: String {
        func byte(_ v: Double) -> Int { Int((RGBA.clamp(v) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
        return a >= 0.999 ? rgb : rgb + String(format: "%02X", byte(a))
    }

    /// WCAG relative luminance, ignoring alpha.
    public var relativeLuminance: Double {
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    public func contrastRatio(with other: RGBA) -> Double {
        let l1 = relativeLuminance, l2 = other.relativeLuminance
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// True when black text reads better on this color than white text.
    public var prefersDarkText: Bool {
        contrastRatio(with: .black) > contrastRatio(with: .white)
    }

    public func mixed(with other: RGBA, _ t: Double) -> RGBA {
        let t = RGBA.clamp(t)
        return RGBA(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t, a + (other.a - a) * t)
    }

    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }

    public static let white = RGBA(1, 1, 1)
    public static let black = RGBA(0, 0, 0)

    private static func clamp(_ v: Double) -> Double { v.isNaN ? 0 : min(1, max(0, v)) }
}

extension RGBA: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let color = RGBA(hex: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid color \(s)")
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hexString)
    }
}

// MARK: - Fills

/// A linear gradient. `angle` is in degrees, counterclockwise from the +x axis, in a
/// y-up coordinate system: 0 runs left to right, 90 runs bottom to top.
public struct GradientSpec: Codable, Hashable, Sendable {
    public var colors: [RGBA]
    public var angle: Double

    public init(colors: [RGBA], angle: Double = 90) {
        self.colors = colors.isEmpty ? [.white, .black] : colors
        self.angle = angle
    }

    /// Start and end points in a unit square with a bottom-left origin.
    public var unitPoints: (start: (x: Double, y: Double), end: (x: Double, y: Double)) {
        let radians = angle * .pi / 180
        let dx = cos(radians) / 2, dy = sin(radians) / 2
        return ((0.5 - dx, 0.5 - dy), (0.5 + dx, 0.5 + dy))
    }

    /// Color halfway along the gradient, used for contrast decisions.
    public var averageColor: RGBA {
        guard let first = colors.first else { return .white }
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        for c in colors { r += c.r; g += c.g; b += c.b; a += c.a }
        let n = Double(colors.count)
        return colors.count == 1 ? first : RGBA(r / n, g / n, b / n, a / n)
    }
}

public enum BackgroundFill: Hashable, Sendable {
    /// The system popover material only.
    case system
    case color(RGBA)
    case gradient(GradientSpec)
    /// An image file on disk, drawn aspect-fill.
    case image(String)

    public var kindName: String {
        switch self {
        case .system: return "system"
        case .color: return "color"
        case .gradient: return "gradient"
        case .image: return "image"
        }
    }

    /// Representative color for contrast decisions (nil for the system material and images).
    public var representativeColor: RGBA? {
        switch self {
        case .system, .image: return nil
        case .color(let c): return c
        case .gradient(let g): return g.averageColor
        }
    }
}

extension BackgroundFill: Codable {
    private enum CodingKeys: String, CodingKey { case type, color, gradient, path }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "color": self = .color(try c.decode(RGBA.self, forKey: .color))
        case "gradient": self = .gradient(try c.decode(GradientSpec.self, forKey: .gradient))
        case "image": self = .image(try c.decode(String.self, forKey: .path))
        default: self = .system
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kindName, forKey: .type)
        switch self {
        case .system: break
        case .color(let color): try c.encode(color, forKey: .color)
        case .gradient(let g): try c.encode(g, forKey: .gradient)
        case .image(let path): try c.encode(path, forKey: .path)
        }
    }
}

public enum BorderStyle: Hashable, Sendable {
    case none
    case color(RGBA, width: Double)
    case gradient(GradientSpec, width: Double)

    public var width: Double {
        switch self {
        case .none: return 0
        case .color(_, let w), .gradient(_, let w): return w
        }
    }

    public var kindName: String {
        switch self {
        case .none: return "none"
        case .color: return "color"
        case .gradient: return "gradient"
        }
    }
}

extension BorderStyle: Codable {
    private enum CodingKeys: String, CodingKey { case type, color, gradient, width }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let width = (try? c.decodeIfPresent(Double.self, forKey: .width)) ?? 1.5
        switch try c.decode(String.self, forKey: .type) {
        case "color": self = .color(try c.decode(RGBA.self, forKey: .color), width: width)
        case "gradient": self = .gradient(try c.decode(GradientSpec.self, forKey: .gradient), width: width)
        default: self = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kindName, forKey: .type)
        switch self {
        case .none: break
        case .color(let color, let width):
            try c.encode(color, forKey: .color)
            try c.encode(width, forKey: .width)
        case .gradient(let g, let width):
            try c.encode(g, forKey: .gradient)
            try c.encode(width, forKey: .width)
        }
    }
}

// MARK: - Labels and appearance

public enum FontWeightName: String, Codable, CaseIterable, Sendable {
    case regular, medium, semibold, bold, heavy

    public var title: String { rawValue.capitalized }
}

public struct LabelStyle: Codable, Hashable, Sendable {
    /// Font family name, or nil for the system font.
    public var fontFamily: String?
    public var size: Double
    public var weight: FontWeightName
    /// Label color, or nil to pick black or white automatically from the background.
    public var color: RGBA?
    public var shadow: Bool

    public init(fontFamily: String? = nil, size: Double = 11.5, weight: FontWeightName = .regular,
                color: RGBA? = nil, shadow: Bool = false) {
        self.fontFamily = fontFamily
        self.size = size
        self.weight = weight
        self.color = color
        self.shadow = shadow
    }

    private enum CodingKeys: String, CodingKey { case fontFamily, size, weight, color, shadow }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LabelStyle()
        fontFamily = c.value(.fontFamily, default: d.fontFamily)
        size = c.value(.size, default: d.size)
        weight = c.value(.weight, default: d.weight)
        color = c.value(.color, default: d.color)
        shadow = c.value(.shadow, default: d.shadow)
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case auto, light, dark

    public var title: String {
        switch self {
        case .auto: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// How a Pop's popover looks.
public struct PopStyle: Codable, Hashable, Sendable {
    public var background: BackgroundFill
    /// 0 draws the background fill fully opaque; 1 shows only the blurred system material.
    public var glass: Double
    public var border: BorderStyle
    public var label: LabelStyle
    public var appearance: AppearanceMode

    public init(background: BackgroundFill = .system, glass: Double = 0.3, border: BorderStyle = .none,
                label: LabelStyle = LabelStyle(), appearance: AppearanceMode = .auto) {
        self.background = background
        self.glass = glass
        self.border = border
        self.label = label
        self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey { case background, glass, border, label, appearance }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PopStyle()
        background = c.value(.background, default: d.background)
        glass = c.value(.glass, default: d.glass)
        border = c.value(.border, default: d.border)
        label = c.value(.label, default: d.label)
        appearance = c.value(.appearance, default: d.appearance)
    }

    /// Whether the popover should use dark appearance, or nil to follow the system.
    public var resolvedDarkAppearance: Bool? {
        switch appearance {
        case .light: return false
        case .dark: return true
        case .auto:
            switch background {
            case .system: return nil
            case .image: return true
            case .color, .gradient:
                // A mostly transparent fill barely changes the material, so follow the system.
                if glass >= 0.9 { return nil }
                return !(background.representativeColor ?? .white).prefersDarkText
            }
        }
    }

    /// The label color to use, given whether the popover ended up dark.
    public func resolvedLabelColor(isDark: Bool) -> RGBA {
        if let c = label.color { return c }
        return isDark ? RGBA(1, 1, 1, 0.92) : RGBA(0, 0, 0, 0.85)
    }
}

// MARK: - Dock icons

public enum DockIconMode: String, Codable, CaseIterable, Sendable {
    /// A live grid of the Pop's item icons, like an iPhone folder.
    case dynamic
    /// A letter, word or emoji on a colored tile.
    case glyph
    /// An image file chosen by the user.
    case custom

    public var title: String {
        switch self {
        case .dynamic: return "Dynamic"
        case .glyph: return "Glyph"
        case .custom: return "Custom Image"
        }
    }
}

public enum IconDensity: String, Codable, CaseIterable, Sendable {
    case auto, two, three, four

    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .two: return "2 × 2"
        case .three: return "3 × 3"
        case .four: return "4 × 4"
        }
    }

    /// Number of columns (and rows) in the Dock icon grid.
    public func gridSize(itemCount: Int) -> Int {
        switch self {
        case .two: return 2
        case .three: return 3
        case .four: return 4
        case .auto:
            if itemCount <= 4 { return 2 }
            if itemCount <= 9 { return 3 }
            return 4
        }
    }
}

public struct DockIconStyle: Codable, Hashable, Sendable {
    public var mode: DockIconMode
    public var density: IconDensity
    /// Use the Pop's popover background for the tile. When false, `background` is used.
    public var matchPopBackground: Bool
    public var background: BackgroundFill
    /// Text for glyph mode; empty means the first letter of the Pop's name.
    public var glyph: String
    public var glyphColor: RGBA?
    public var customImagePath: String?

    public init(mode: DockIconMode = .dynamic, density: IconDensity = .auto, matchPopBackground: Bool = true,
                background: BackgroundFill = .color(RGBA(hex: "#3A3D44")!), glyph: String = "",
                glyphColor: RGBA? = nil, customImagePath: String? = nil) {
        self.mode = mode
        self.density = density
        self.matchPopBackground = matchPopBackground
        self.background = background
        self.glyph = glyph
        self.glyphColor = glyphColor
        self.customImagePath = customImagePath
    }

    private enum CodingKeys: String, CodingKey {
        case mode, density, matchPopBackground, background, glyph, glyphColor, customImagePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DockIconStyle()
        mode = c.value(.mode, default: d.mode)
        density = c.value(.density, default: d.density)
        matchPopBackground = c.value(.matchPopBackground, default: d.matchPopBackground)
        background = c.value(.background, default: d.background)
        glyph = c.value(.glyph, default: d.glyph)
        glyphColor = c.value(.glyphColor, default: d.glyphColor)
        customImagePath = c.value(.customImagePath, default: d.customImagePath)
    }

    /// The fill used behind the Dock icon.
    public func resolvedBackground(popStyle: PopStyle) -> BackgroundFill {
        guard matchPopBackground else { return background }
        switch popStyle.background {
        case .system: return .gradient(GradientSpec(colors: [RGBA(hex: "#F2F2F4")!, RGBA(hex: "#D9DADF")!], angle: 90))
        default: return popStyle.background
        }
    }
}

// MARK: - Themes

/// A saved look that can be applied to any Pop.
public struct Theme: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var style: PopStyle
    /// Dock tile background for this theme, or nil to match the popover background.
    public var dockBackground: BackgroundFill?

    public init(id: String, name: String, style: PopStyle, dockBackground: BackgroundFill? = nil) {
        self.id = id
        self.name = name
        self.style = style
        self.dockBackground = dockBackground
    }

    public var isBuiltIn: Bool { BuiltInThemes.all.contains { $0.id == id } }
}

// MARK: - Forgiving decoding

extension KeyedDecodingContainer {
    /// Decodes a value, falling back to `def` when the key is missing or the value is invalid.
    /// This keeps older or newer library files loadable.
    func value<T: Decodable>(_ key: Key, default def: T) -> T {
        guard contains(key) else { return def }
        if let v = try? decode(T.self, forKey: key) { return v }
        return def
    }

    func value<T: Decodable>(_ key: Key, default def: T?) -> T? {
        guard contains(key) else { return def }
        if (try? decodeNil(forKey: key)) == true { return nil }
        if let v = try? decode(T.self, forKey: key) { return v }
        return def
    }
}
