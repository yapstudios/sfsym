import AppKit
import CoreGraphics

enum RenderMode: String {
    case monochrome, hierarchical, palette, multicolor
}

struct RenderOptions {
    var name: String
    var mode: RenderMode = .monochrome
    var weight: NSFont.Weight = .regular
    var scale: NSImage.SymbolScale = .medium
    /// Point size for PNG output; also governs the PDF alignment rect scale.
    var pointSize: CGFloat = 32
    /// Monochrome / hierarchical tint.
    var tint: NSColor = .labelColor
    /// Palette fills in layer order.
    var paletteColors: [NSColor] = [.systemRed, .systemGreen, .systemBlue]
}

enum Render {

    /// Build the NSImage.SymbolConfiguration that feeds NSSymbolImageRep's
    /// `_vectorGlyph` derivation. Shared by every render path so the three
    /// formats stay aligned on what "this mode" means.
    private static func configuration(for o: RenderOptions) -> NSImage.SymbolConfiguration {
        let base = NSImage.SymbolConfiguration(pointSize: o.pointSize,
                                               weight: o.weight,
                                               scale: o.scale)
        switch o.mode {
        case .monochrome:   return base
        case .hierarchical: return base.applying(.init(hierarchicalColor: o.tint))
        case .palette:      return base.applying(.init(paletteColors: o.paletteColors))
        case .multicolor:   return base.applying(.preferringMulticolor())
        }
    }

    // MARK: - PDF (vector, via CUINamedVectorGlyph)

    static func pdf(options o: RenderOptions) throws -> Data {
        var opts = o
        return try renderPdf(options: &opts).data
    }

    /// Returns the PDF bytes plus the already-loaded glyph so `svg()` doesn't
    /// have to reload the symbol just to read alignment-rect / layer metadata.
    /// Mutates `o.paletteColors` in place if cycling is needed so callers (like
    /// svg()) see the same expanded palette used for the PDF draw.
    private static func renderPdf(options o: inout RenderOptions) throws -> (data: Data, glyph: Glyph) {
        // Load once with a baseline config so we can read numberOfPaletteLayers
        // before deciding whether to cycle the palette.
        let baseCfg = NSImage.SymbolConfiguration(pointSize: o.pointSize,
                                                  weight: o.weight,
                                                  scale: o.scale)
        let glyph = try Glyph.load(name: o.name, configuration: baseCfg)
        let sz = glyph.size

        // Palette cycling: if the caller passed fewer colors than the glyph has
        // palette layers, cycle to cover every layer (colors[i % count]). Apple
        // would otherwise drop layers past the supplied count. One-time stderr
        // warning so humans and agents notice the short palette.
        if o.mode == .palette {
            let expected = glyph.numberOfPaletteLayers
            if expected > 0 && o.paletteColors.count < expected && !o.paletteColors.isEmpty {
                FileHandle.standardError.write(Data(
                    "warning: --palette has \(o.paletteColors.count) color\(o.paletteColors.count == 1 ? "" : "s") but symbol has \(expected) palette layers; cycling\n".utf8
                ))
                let src = o.paletteColors
                o.paletteColors = (0..<expected).map { src[$0 % src.count] }
            } else if expected > 0 && o.paletteColors.count > expected {
                // Counterpart to the cycling warning: extras past the layer count
                // silently drop (Apple's palette config just ignores them). Call
                // it out so agents notice a mis-sized palette either direction.
                FileHandle.standardError.write(Data(
                    "warning: --palette has \(o.paletteColors.count) colors but symbol has \(expected) palette layer\(expected == 1 ? "" : "s"); extras ignored\n".utf8
                ))
            }
        }
        // Build the final mode-specific configuration (palette may have grown).
        let cfg = configuration(for: o)

        // Canvas = pointSize × pointSize pt square (matches PNG behavior).
        // Symbol is fit uniformly inside, centered. This gives agents the
        // "--size N ⇒ N×N output" invariant across all three formats instead
        // of the previous intrinsic-extent (e.g. 40×33 for heart) output.
        let box = o.pointSize
        let fit = min(box / sz.width, box / sz.height)
        let drawW = sz.width * fit
        let drawH = sz.height * fit
        let offX = (box - drawW) / 2
        let offY = (box - drawH) / 2

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: CGSize(width: box, height: box))
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw GlyphError.bad("cannot create PDF context") }
        ctx.beginPDFPage(nil)

        // Outer transform: translate to the centered fit-box, then uniform-scale
        // so the glyph's intrinsic sz maps into drawW × drawH inside the square.
        ctx.translateBy(x: offX, y: offY)
        ctx.scaleBy(x: fit, y: fit)
        // Apple draws paths at the glyph's native pixel space (pointSize × scale).
        // Shrink back into point space so everything fits the (pre-fit) mediaBox.
        let inv = 1.0 / glyph.renderScale
        ctx.scaleBy(x: inv, y: inv)

        switch o.mode {
        case .monochrome:
            // drawInContext: produces thinner, cleaner strokes than drawPalette
            // with a single color. The monochrome path color is baked in as
            // black — SvgEmitter overrides it with the user's tint.
            glyph.drawMonochrome(in: ctx)
        case .hierarchical:
            // monoPathBounds is in native pixel space; divide by renderScale to land
            // at the same point-space extent drawInContext would paint into.
            let monoBounds = glyph.monochromePathBounds
            let s = glyph.renderScale
            glyph.drawHierarchical(in: ctx, baseColor: o.tint,
                                   scaleFactor: s,
                                   targetSize: CGSize(width: monoBounds.width / s,
                                                      height: monoBounds.height / s))
        case .palette:
            glyph.drawPalette(in: ctx, colors: o.paletteColors)
        case .multicolor:
            // The private vector multicolor entry crashes inside CoreUI when invoked
            // out-of-process (every color-resolver signature tried). Fall back to
            // NSImage.draw() — PDF ends up embedding a bitmap, not path ops.
            // Aqua appearance pins dynamic colors so systemBackground et al. resolve.
            guard let sized = NSImage(systemSymbolName: o.name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg)
            else { throw GlyphError.notFound(o.name) }
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                sized.draw(in: NSRect(origin: .zero, size: sz))
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        ctx.endPDFPage()
        ctx.closePDF()
        return (data as Data, glyph)
    }

    // MARK: - SVG (vector, derived from the vector PDF)

    /// Produces an SVG whose paths are the exact path operators Apple's renderer
    /// emits into the PDF via `CUINamedVectorGlyph.drawInContext:` (or the
    /// hierarchical / palette equivalents). Each painted path becomes a
    /// `<path>` element, Y-axis flipped, with a `data-layer` tag matching
    /// Apple's per-mode scheme (monochrome-0 / hierarchical-N / palette-N).
    ///
    /// Eraser handling: Apple emits alpha-0 knockout paths inline (via
    /// ExtGState `/ca 0`). These aren't painted — they define regions that
    /// should be subtracted from *earlier* painted paths in the stream (e.g.
    /// the pencil body carves out the underline beneath it). The SVG emitter
    /// collects these alpha-0 paths as SVG `<mask>`s.
    ///
    /// Restricted to modes we have a vector PDF for: monochrome, hierarchical,
    /// palette. Multicolor errors — its PDF is raster-embedded.
    static func svg(options o: RenderOptions) throws -> Data {
        guard o.mode != .multicolor else {
            throw GlyphError.bad("SVG multicolor not supported in v1 (PDF is raster-embedded; no path data to lift)")
        }
        var opts = o
        let (pdf, g) = try renderPdf(options: &opts)
        let box = opts.pointSize
        let canvas = CGSize(width: box, height: box)
        let paths = PdfToSvg.extractPaths(from: pdf, pageSize: canvas)
        let paletteCG = opts.paletteColors.map { $0.cgColor }
        return SvgEmitter.emit(
            paths: paths,
            viewBox: CGRect(origin: .zero, size: canvas),
            mode: opts.mode,
            tintColor: opts.tint.cgColor,
            paletteColors: paletteCG,
            hierarchyLevels: opts.mode == .hierarchical ? g.hierarchyLevels : []
        )
    }

    // MARK: - PNG (raster, via NSBitmapImageRep)

    static func png(options o: RenderOptions) throws -> Data {
        let cfg = configuration(for: o)
        guard let base = NSImage(systemSymbolName: o.name, accessibilityDescription: nil),
              let sized = base.withSymbolConfiguration(cfg)
        else { throw GlyphError.notFound(o.name) }

        // --size N means: output a square N×N pt canvas, rendered at 2× for
        // crisp Retina pixels (2N × 2N). Symbol is fit uniformly inside,
        // preserving aspect ratio. This matches what favicon / icon-grid use
        // cases want ("size = dimension") rather than the symbol's intrinsic
        // alignment-rect extent, which varies per glyph.
        let pixelScale: CGFloat = 2
        let box = o.pointSize
        let pw = Int((box * pixelScale).rounded())
        let ph = Int((box * pixelScale).rounded())

        let symSize = sized.size
        let fit = min(box / symSize.width, box / symSize.height)
        let drawW = symSize.width * fit
        let drawH = symSize.height * fit
        let drawRect = NSRect(x: (box - drawW) / 2, y: (box - drawH) / 2,
                              width: drawW, height: drawH)

        guard let bm = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw GlyphError.bad("cannot create bitmap rep") }
        bm.size = CGSize(width: box, height: box)

        // Pin appearance so multicolor / hierarchical dynamic colors resolve
        // predictably — without this, systemBackground etc. default to white.
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bm)
            sized.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let png = bm.representation(using: .png, properties: [:]) else {
            throw GlyphError.bad("PNG encoding failed")
        }
        return png
    }
}
