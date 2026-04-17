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
        try renderPdf(options: o).data
    }

    /// Returns the PDF bytes plus the already-loaded glyph so `svg()` doesn't
    /// have to reload the symbol just to read alignment-rect / layer metadata.
    private static func renderPdf(options o: RenderOptions) throws -> (data: Data, glyph: Glyph) {
        let cfg = configuration(for: o)
        let glyph = try Glyph.load(name: o.name, configuration: cfg)
        let sz = glyph.size

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: sz)
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw GlyphError.bad("cannot create PDF context") }
        ctx.beginPDFPage(nil)

        // Apple draws paths at the glyph's native pixel space (pointSize × scale).
        // Shrink back into point space so everything fits the mediaBox.
        let inv = 1.0 / glyph.renderScale
        ctx.scaleBy(x: inv, y: inv)

        switch o.mode {
        case .monochrome:
            // Route mono through single-color palette — same vector draw path,
            // with arbitrary tint support that plain drawInContext: lacks.
            glyph.drawPalette(in: ctx, colors: [o.tint])
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
    /// emits into the PDF via `CUINamedVectorGlyph.drawInContext:`. Each painted
    /// path becomes a <path> element, Y-axis flipped, with a `data-layer` tag
    /// matching Apple's per-mode scheme (monochrome-0 / hierarchical-N /
    /// palette-N).
    ///
    /// Restricted to modes we have a vector PDF for: monochrome, hierarchical,
    /// palette. Multicolor errors — its PDF is raster-embedded.
    static func svg(options o: RenderOptions) throws -> Data {
        guard o.mode != .multicolor else {
            throw GlyphError.bad("SVG multicolor not supported in v1 (PDF is raster-embedded; no path data to lift)")
        }
        let (pdf, glyph) = try renderPdf(options: o)
        let paths = PdfToSvg.extractPaths(from: pdf, pageSize: glyph.size)
        let paletteCG = o.paletteColors.map { $0.cgColor }
        return SvgEmitter.emit(
            paths: paths,
            viewBox: CGRect(origin: .zero, size: glyph.size),
            mode: o.mode,
            paletteColors: paletteCG,
            hierarchyLevels: o.mode == .hierarchical ? glyph.hierarchyLevels : []
        )
    }

    // MARK: - PNG (raster, via NSBitmapImageRep)

    static func png(options o: RenderOptions) throws -> Data {
        let cfg = configuration(for: o)
        guard let base = NSImage(systemSymbolName: o.name, accessibilityDescription: nil),
              let sized = base.withSymbolConfiguration(cfg)
        else { throw GlyphError.notFound(o.name) }

        // Render at 2× pixel density for crisp output.
        let pixelScale: CGFloat = 2
        let pw = Int(ceil(sized.size.width * pixelScale))
        let ph = Int(ceil(sized.size.height * pixelScale))
        guard let bm = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw GlyphError.bad("cannot create bitmap rep") }
        bm.size = sized.size

        // Pin appearance so multicolor / hierarchical dynamic colors resolve
        // predictably — without this, systemBackground etc. default to white.
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bm)
            sized.draw(in: NSRect(origin: .zero, size: sized.size),
                       from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let png = bm.representation(using: .png, properties: [:]) else {
            throw GlyphError.bad("PNG encoding failed")
        }
        return png
    }
}
