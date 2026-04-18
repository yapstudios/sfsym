import Foundation

/// Offline symbol enumeration via Assets.car FACETKEYS.
/// Used for `sfsym list` / `sfsym info`. Rendering goes through AppKit.
final class Catalog {
    let facets: [String: AssetsCar.FacetAttrs]

    init(path: String = Catalog.defaultAssetsPath) throws {
        // Walk the BOM once, capture the name → attributes map, then drop the
        // 160 MB mmap. Catalog instances are cheap to hold for the life of a
        // CLI invocation.
        self.facets = try AssetsCar(path: path).loadFacets()
    }

    static let defaultAssetsPath =
        "/System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources/CoreGlyphs.bundle/Contents/Resources/Assets.car"

    /// Symbol names, sorted. Drops internal facets (no `identifier` attribute).
    func names(prefix: String = "", limit: Int? = nil) -> [String] {
        var out: [String] = []
        for (name, attrs) in facets where attrs.identifier != nil {
            if prefix.isEmpty || name.hasPrefix(prefix) { out.append(name) }
        }
        out.sort()
        if let lim = limit { return Array(out.prefix(lim)) }
        return out
    }
}
