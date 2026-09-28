import Foundation

/// An app found on disk, for the App Browser and suggestions.
public struct InstalledApp: Hashable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var bundleID: String?
    /// The app's LSApplicationCategoryType, e.g. "public.app-category.developer-tools".
    public var category: String?
    public var addedDate: Date?
    public var lastUsedDate: Date?

    public var id: String { path }

    public init(path: String, name: String, bundleID: String? = nil, category: String? = nil,
                addedDate: Date? = nil, lastUsedDate: Date? = nil) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.category = category
        self.addedDate = addedDate
        self.lastUsedDate = lastUsedDate
    }

    public var normalizedCategory: String? { AppCategory.normalize(category) }
}

public enum AppCategory {
    public static let other = "other"

    private static let titles: [String: String] = [
        "public.app-category.business": "Business",
        "public.app-category.developer-tools": "Developer Tools",
        "public.app-category.education": "Education",
        "public.app-category.entertainment": "Entertainment",
        "public.app-category.finance": "Finance",
        "public.app-category.games": "Games",
        "public.app-category.graphics-design": "Graphics & Design",
        "public.app-category.healthcare-fitness": "Health & Fitness",
        "public.app-category.lifestyle": "Lifestyle",
        "public.app-category.medical": "Medical",
        "public.app-category.music": "Music",
        "public.app-category.news": "News",
        "public.app-category.photography": "Photography",
        "public.app-category.productivity": "Productivity",
        "public.app-category.reference": "Reference",
        "public.app-category.social-networking": "Social Networking",
        "public.app-category.sports": "Sports",
        "public.app-category.travel": "Travel",
        "public.app-category.utilities": "Utilities",
        "public.app-category.video": "Video",
        "public.app-category.weather": "Weather",
        other: "Other",
    ]

    /// Folds the many game subcategories into "games" and unknown values into "other".
    public static func normalize(_ type: String?) -> String? {
        guard let t = type?.lowercased(), !t.isEmpty else { return nil }
        if t.hasPrefix("public.app-category.") && t.hasSuffix("-games") { return "public.app-category.games" }
        return titles[t] != nil ? t : other
    }

    public static func title(for type: String?) -> String {
        guard let n = normalize(type) else { return "Other" }
        return titles[n] ?? "Other"
    }

    /// All categories in display order.
    public static var allCategories: [String] {
        titles.keys.filter { $0 != other }.sorted { title(for: $0) < title(for: $1) } + [other]
    }

    /// Words in a Pop's name that hint at a category.
    static let keywords: [String: [String]] = [
        "work": ["productivity", "business"],
        "office": ["productivity", "business"],
        "business": ["business", "productivity"],
        "writing": ["productivity"],
        "docs": ["productivity"],
        "dev": ["developer-tools"],
        "code": ["developer-tools"],
        "coding": ["developer-tools"],
        "developer": ["developer-tools"],
        "development": ["developer-tools"],
        "engineering": ["developer-tools"],
        "design": ["graphics-design", "photography"],
        "creative": ["graphics-design", "photography", "video", "music"],
        "art": ["graphics-design"],
        "photo": ["photography"],
        "photos": ["photography"],
        "video": ["video"],
        "film": ["video"],
        "music": ["music"],
        "audio": ["music"],
        "games": ["games"],
        "gaming": ["games"],
        "play": ["games", "entertainment"],
        "fun": ["games", "entertainment"],
        "media": ["entertainment", "video", "music"],
        "social": ["social-networking"],
        "chat": ["social-networking"],
        "communication": ["social-networking", "productivity"],
        "messaging": ["social-networking"],
        "utilities": ["utilities"],
        "utility": ["utilities"],
        "tools": ["utilities", "developer-tools"],
        "system": ["utilities"],
        "finance": ["finance"],
        "money": ["finance"],
        "school": ["education", "reference"],
        "study": ["education", "reference"],
        "learning": ["education"],
        "reading": ["news", "reference", "education"],
        "news": ["news"],
        "health": ["healthcare-fitness", "medical"],
        "fitness": ["healthcare-fitness"],
        "travel": ["travel"],
        "weather": ["weather"],
    ]

    public static func hintedCategories(forName name: String) -> Set<String> {
        var result = Set<String>()
        let words = name.lowercased().split { !$0.isLetter }.map(String.init)
        for w in words {
            for c in keywords[w] ?? [] { result.insert("public.app-category." + c) }
        }
        return result
    }
}

public enum Suggestions {
    /// Ranks installed apps that fit a Pop, using the categories and vendors of the apps
    /// already in it and hints from its name. Works offline on every Mac.
    public static func suggest(for pop: Pop, installed: [InstalledApp], limit: Int = 12, now: Date = Date()) -> [InstalledApp] {
        let inPop = Set(pop.items.map { $0.identityKey })
        let byPath = Dictionary(installed.map { (PopItem.standardizedPath($0.path), $0) }, uniquingKeysWith: { a, _ in a })
        let members = pop.items.compactMap { byPath[$0.identityKey] }

        var categoryCounts: [String: Int] = [:]
        var vendors = Set<String>()
        for app in members {
            if let c = app.normalizedCategory, c != AppCategory.other { categoryCounts[c, default: 0] += 1 }
            if let v = vendor(of: app.bundleID) { vendors.insert(v) }
        }
        let hinted = AppCategory.hintedCategories(forName: pop.name)
        let nameWords = pop.name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }

        var scored: [(app: InstalledApp, score: Double)] = []
        for app in installed where !inPop.contains(PopItem.standardizedPath(app.path)) {
            var score = 0.0
            let cat = app.normalizedCategory
            if let cat = cat, let n = categoryCounts[cat] { score += 3 + Double(n) }
            if let cat = cat, hinted.contains(cat) { score += 4 }
            let lowerName = app.name.lowercased()
            if nameWords.contains(where: { lowerName.contains($0) }) { score += 5 }
            if let v = vendor(of: app.bundleID), vendors.contains(v), v != "com.apple" { score += 2 }
            guard score > 0 else { continue }
            if let used = app.lastUsedDate, now.timeIntervalSince(used) < 14 * 86_400 { score += 1 }
            scored.append((app, score))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.app.name.compare(b.app.name, options: [.caseInsensitive, .numeric]) == .orderedAscending
        }
        return scored.prefix(max(limit, 0)).map { $0.app }
    }

    /// "com.adobe.Photoshop" -> "com.adobe"
    static func vendor(of bundleID: String?) -> String? {
        guard let parts = bundleID?.lowercased().split(separator: "."), parts.count >= 3 else { return nil }
        return parts[0] + "." + parts[1]
    }
}
