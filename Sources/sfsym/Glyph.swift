import AppKit
import ObjectiveC

/// Thin wrapper over the private CUINamedVectorGlyph behind NSSymbolImageRep.
/// Exposes the vector draw entry points used for PDF output.
struct Glyph {
    let raw: AnyObject               // CUINamedVectorGlyph
    let size: CGSize                 // NSSymbolImageRep.size — alignment rect in points

    static func load(name: String, configuration: NSImage.SymbolConfiguration) throws -> Glyph {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            throw GlyphError.notFound(name)
        }
        guard let sized = base.withSymbolConfiguration(configuration) else {
            throw GlyphError.bad("withSymbolConfiguration failed for \(name)")
        }
        guard let rep = sized.representations.first else {
            throw GlyphError.bad("no representation for \(name)")
        }
        guard let obj = rep.value(forKey: "_vectorGlyph") else {
            throw GlyphError.bad("rep has no _vectorGlyph (symbol probably missing)")
        }
        return Glyph(raw: obj as AnyObject, size: rep.size)
    }

    /// Private-API bridge: look up the IMP for `selName` on the raw glyph and
    /// bit-cast it to the caller-declared C function type. Every public property
    /// and draw method below funnels through here.
    private func imp<Fn>(_ selName: String, as: Fn.Type) -> (Fn, Selector) {
        let sel = NSSelectorFromString(selName)
        let p = class_getMethodImplementation(object_getClass(raw)!, sel)!
        return (unsafeBitCast(p, to: Fn.self), sel)
    }

    var numberOfHierarchyLayers: Int {
        let (fn, sel) = imp("numberOfHierarchyLayers", as: (@convention(c) (AnyObject, Selector) -> Int).self)
        return fn(raw, sel)
    }

    var numberOfPaletteLayers: Int {
        let (fn, sel) = imp("numberOfPaletteLayers", as: (@convention(c) (AnyObject, Selector) -> Int).self)
        return fn(raw, sel)
    }

    var numberOfTemplateLayers: Int {
        let (fn, sel) = imp("numberOfTemplateLayers", as: (@convention(c) (AnyObject, Selector) -> Int).self)
        return fn(raw, sel)
    }

    /// CUINamedVectorGlyph draws into its native pixel space — `pointSize × scale`
    /// units in each axis. Callers must pre-scale the CGContext by 1/scale to
    /// land inside `rep.size`.
    var renderScale: CGFloat {
        let (fn, sel) = imp("scale", as: (@convention(c) (AnyObject, Selector) -> CGFloat).self)
        return fn(raw, sel)
    }

    /// The glyph's alignment rect in point-space.
    var alignmentRect: CGRect {
        let (fn, sel) = imp("alignmentRect", as: (@convention(c) (AnyObject, Selector) -> CGRect).self)
        return fn(raw, sel)
    }

    /// The monochrome path's own bounding box — this is exactly the extent
    /// `drawInContext:` paints into. Used to size hierarchical rendering so
    /// every mode ends up at the same scale.
    var monochromePathBounds: CGRect {
        let (fn, sel) = imp("CGPath", as: (@convention(c) (AnyObject, Selector) -> CGPath).self)
        return fn(raw, sel).boundingBox
    }

    /// Apple's preferred rendering mode enum value (3 = multicolor).
    var preferredRenderingMode: Int {
        let (fn, sel) = imp("preferredRenderingMode", as: (@convention(c) (AnyObject, Selector) -> Int).self)
        return fn(raw, sel)
    }

    /// Supports multicolor if the baked-in rendering preference says so.
    var supportsMulticolor: Bool { preferredRenderingMode == 3 }

    /// One tier per painted path: 0 = primary, 1 = secondary, 2 = tertiary.
    /// Apple's hierarchical renderer doesn't apply per-tier alpha when invoked
    /// out-of-process, so the SVG emitter layers it in by path index.
    var hierarchyLevels: [Int] {
        let (fn, sel) = imp("hierarchyLevels", as: (@convention(c) (AnyObject, Selector) -> NSArray?).self)
        let arr = fn(raw, sel) ?? NSArray()
        return (arr as? [NSNumber])?.map { $0.intValue } ?? []
    }

    /// Apple's canonical hierarchical opacity ladder, shared with the SVG emitter
    /// so both sides stay in sync.
    static let hierarchicalAlphas: [CGFloat] = [1.0, 0.68, 0.32]

    /// Monochrome draw — fills a single `sc 0 0 0` path set.
    func drawMonochrome(in ctx: CGContext) {
        let (fn, sel) = imp("drawInContext:",
            as: (@convention(c) (AnyObject, Selector, CGContext) -> Void).self)
        fn(raw, sel, ctx)
    }

    /// Palette draw with explicit colors.
    func drawPalette(in ctx: CGContext, colors: [NSColor]) {
        let (fn, sel) = imp("drawInContext:withPaletteColors:",
            as: (@convention(c) (AnyObject, Selector, CGContext, NSArray) -> Void).self)
        fn(raw, sel, ctx, colors as NSArray)
    }

    /// Per-layer hierarchical draw: layers are stacked with caller-supplied colors.
    func drawHierarchical(in ctx: CGContext, baseColor: NSColor, scaleFactor: CGFloat, targetSize: CGSize) {
        let alphas = Glyph.hierarchicalAlphas
        let resolver: @convention(block) (NSString) -> NSColor = { name in
            switch name as String {
            case "primary":   return baseColor.withAlphaComponent(alphas[0])
            case "secondary": return baseColor.withAlphaComponent(alphas[1])
            case "tertiary":  return baseColor.withAlphaComponent(alphas[2])
            default:          return baseColor
            }
        }
        let (fn, sel) = imp("_drawHierarchicalLayersInContext:scaleFactor:targetSize:colorResolver:",
            as: (@convention(c) (AnyObject, Selector, CGContext, CGFloat, CGSize, AnyObject) -> Void).self)
        fn(raw, sel, ctx, scaleFactor, targetSize, resolver as AnyObject)
    }

    /// Multicolor draw — uses Apple's baked-in per-layer colors (layer names like
    /// `systemRedColor`, `systemYellowColor`). Currently crashes out-of-process;
    /// callers use NSImage.draw for multicolor instead.
    func drawMulticolor(in ctx: CGContext, scaleFactor: CGFloat, targetSize: CGSize) {
        let resolver: @convention(block) (NSString) -> NSColor = { name in
            let stripped = (name as String).replacingOccurrences(of: "Color", with: "")
            return AppleSystemColor(rawValue: stripped)?.nsColor ?? .labelColor
        }
        let (fn, sel) = imp("_drawMulticolorLayersInContext:scaleFactor:targetSize:colorResolver:",
            as: (@convention(c) (AnyObject, Selector, CGContext, CGFloat, CGSize, AnyObject) -> Void).self)
        fn(raw, sel, ctx, scaleFactor, targetSize, resolver as AnyObject)
    }
}

enum GlyphError: Error {
    case notFound(String)
    case bad(String)
}

/// Apple's "systemXxxColor" identifiers, mapped to the corresponding NSColor.
/// Used for multicolor rendering; layers carry a fixed tint name.
enum AppleSystemColor: String {
    case systemRed, systemOrange, systemYellow, systemGreen, systemMint, systemTeal
    case systemCyan, systemBlue, systemIndigo, systemPurple, systemPink, systemBrown
    case systemGray, systemGray2, systemGray3, systemGray4, systemGray5, systemGray6
    case systemBackground, secondarySystemBackground, tertiarySystemBackground
    case label, secondaryLabel, tertiaryLabel, quaternaryLabel, placeholderText
    case separator, opaqueSeparator, link
    case white, black

    var nsColor: NSColor {
        switch self {
        case .systemRed: return .systemRed
        case .systemOrange: return .systemOrange
        case .systemYellow: return .systemYellow
        case .systemGreen: return .systemGreen
        case .systemMint: return .systemMint
        case .systemTeal: return .systemTeal
        case .systemCyan: return .systemCyan
        case .systemBlue: return .systemBlue
        case .systemIndigo: return .systemIndigo
        case .systemPurple: return .systemPurple
        case .systemPink: return .systemPink
        case .systemBrown: return .systemBrown
        case .systemGray: return .systemGray
        case .systemGray2: return NSColor(named: "systemGray2") ?? .systemGray
        case .systemGray3: return NSColor(named: "systemGray3") ?? .systemGray
        case .systemGray4: return NSColor(named: "systemGray4") ?? .systemGray
        case .systemGray5: return NSColor(named: "systemGray5") ?? .systemGray
        case .systemGray6: return NSColor(named: "systemGray6") ?? .systemGray
        case .systemBackground: return .windowBackgroundColor
        case .secondarySystemBackground: return .underPageBackgroundColor
        case .tertiarySystemBackground: return .controlBackgroundColor
        case .label: return .labelColor
        case .secondaryLabel: return .secondaryLabelColor
        case .tertiaryLabel: return .tertiaryLabelColor
        case .quaternaryLabel: return .quaternaryLabelColor
        case .placeholderText: return .placeholderTextColor
        case .separator: return .separatorColor
        case .opaqueSeparator: return .separatorColor
        case .link: return .linkColor
        case .white: return .white
        case .black: return .black
        }
    }
}
