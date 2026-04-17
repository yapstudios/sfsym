import Foundation

/// SF Symbols category and semantic-search metadata. Lives only inside
/// /Applications/SF Symbols.app (not in the OS's CoreGlyphs bundle), so this
/// is a soft dependency — if the app isn't installed, the lookups return
/// empty and the `--category` / `--search` filters just match nothing.
///
/// Three files drive us:
///   categories.plist         — array of {key, label, icon}
///   symbol_categories.plist  — { symbol: [categoryKey, …] }
///   symbol_search.plist      — { symbol: [keyword, …] }
enum Metadata {
    static let metadataDir = "/Applications/SF Symbols.app/Contents/Resources/Metadata"

    /// True if SF Symbols.app is installed and the metadata files are readable.
    static var available: Bool { FileManager.default.fileExists(atPath: metadataDir) }

    struct Category {
        let key: String
        let label: String
        let icon: String
    }

    /// All categories in display order. Empty if metadata is unavailable.
    static let categories: [Category] = {
        let path = "\(metadataDir)/categories.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let arr = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { d in
            guard let k = d["key"] as? String,
                  let l = d["label"] as? String else { return nil }
            return Category(key: k, label: l, icon: (d["icon"] as? String) ?? "")
        }
    }()

    /// symbol → category keys. Empty if metadata is unavailable.
    static let symbolCategories: [String: [String]] = {
        loadStringArrayMap("\(metadataDir)/symbol_categories.plist")
    }()

    /// symbol → search keywords. Empty if metadata is unavailable.
    static let symbolSearchKeywords: [String: [String]] = {
        loadStringArrayMap("\(metadataDir)/symbol_search.plist")
    }()

    private static func loadStringArrayMap(_ path: String) -> [String: [String]] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: [String]]
        else { return [:] }
        return dict
    }

    /// Return only names that belong to the given category key.
    static func filter(names: [String], category: String) -> [String] {
        let wanted = category.lowercased()
        return names.filter { name in
            (symbolCategories[name] ?? []).contains(where: { $0.lowercased() == wanted })
        }
    }

    /// Return names whose semantic-search keywords contain the given needle
    /// (case-insensitive substring). Fall through to the name itself so bare
    /// "magnifyingglass" still matches even without metadata.
    static func filter(names: [String], search: String) -> [String] {
        let needle = search.lowercased()
        return names.filter { name in
            if name.lowercased().contains(needle) { return true }
            for kw in symbolSearchKeywords[name] ?? [] {
                if kw.lowercased().contains(needle) { return true }
            }
            return false
        }
    }
}
