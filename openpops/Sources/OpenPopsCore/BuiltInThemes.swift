import Foundation

public enum BuiltInThemes {
    public static let systemID = "system"

    private static func c(_ hex: String) -> RGBA { RGBA(hex: hex) ?? .white }

    private static func gradient(_ hexes: [String], _ angle: Double = 90) -> GradientSpec {
        GradientSpec(colors: hexes.map(c), angle: angle)
    }

    public static let all: [Theme] = [
        Theme(id: systemID, name: "System",
              style: PopStyle(background: .system, glass: 1)),

        Theme(id: "graphite", name: "Graphite",
              style: PopStyle(background: .color(c("#2C2E33")), glass: 0.18,
                              border: .color(c("#FFFFFF24"), width: 1))),

        Theme(id: "sunset", name: "Sunset",
              style: PopStyle(background: .gradient(gradient(["#B8327A", "#FF5E62", "#FFA45B"])), glass: 0.1,
                              label: LabelStyle(weight: .semibold, color: c("#FFFFFF"), shadow: true))),

        Theme(id: "ocean", name: "Ocean",
              style: PopStyle(background: .gradient(gradient(["#0B3C6D", "#1672A8", "#2CB5C9"])), glass: 0.12,
                              label: LabelStyle(weight: .medium, color: c("#F2FBFF"), shadow: true))),

        Theme(id: "matrix", name: "Matrix",
              style: PopStyle(background: .color(c("#030A04")), glass: 0.04,
                              border: .color(c("#00FF41"), width: 1),
                              label: LabelStyle(fontFamily: "Menlo", size: 10.5, weight: .medium, color: c("#00FF41")),
                              appearance: .dark)),

        Theme(id: "forest", name: "Forest",
              style: PopStyle(background: .gradient(gradient(["#0F3B2E", "#2E7D5B", "#7FB77E"])), glass: 0.12,
                              label: LabelStyle(weight: .medium, color: c("#F4FFF6"), shadow: true))),

        Theme(id: "lavender", name: "Lavender",
              style: PopStyle(background: .color(c("#E7E1F7")), glass: 0.22,
                              label: LabelStyle(color: c("#3E3360")))),

        Theme(id: "rose", name: "Rose",
              style: PopStyle(background: .gradient(gradient(["#F4B6CC", "#FFE3EC"])), glass: 0.18,
                              label: LabelStyle(color: c("#5B2336")))),

        Theme(id: "mint", name: "Mint",
              style: PopStyle(background: .color(c("#BFEDE0")), glass: 0.22,
                              label: LabelStyle(color: c("#1F4E44")))),

        Theme(id: "midnight", name: "Midnight",
              style: PopStyle(background: .gradient(gradient(["#0B1026", "#1B2150", "#3A2A6B"])), glass: 0.1,
                              border: .gradient(gradient(["#6C7BFF", "#C86CFF"], 0), width: 1.5),
                              label: LabelStyle(color: c("#E6E8FF")))),

        Theme(id: "paper", name: "Paper",
              style: PopStyle(background: .color(c("#FAF7F0")), glass: 0.03,
                              border: .color(c("#D8D0BF"), width: 1),
                              label: LabelStyle(fontFamily: "Georgia", size: 12, color: c("#2B2620")),
                              appearance: .light)),

        Theme(id: "spiiira", name: "Spiiira",
              style: PopStyle(background: .color(c("#0D0D0C")), glass: 0.06,
                              border: .gradient(gradient(["#1E5663", "#1E5663", "#FF4A14", "#F28C00", "#D6C2A7"], 0), width: 1.5),
                              label: LabelStyle(fontFamily: "Menlo", size: 10.5, color: c("#EBE2CF")),
                              appearance: .dark)),
    ]

    public static func theme(_ id: String) -> Theme? {
        all.first { $0.id == id }
    }

    public static var system: Theme { all[0] }
}
