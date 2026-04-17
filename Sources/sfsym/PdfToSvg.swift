import Foundation
import Compression
import CoreGraphics

// Minimal PDF-to-SVG translator for the PDFs we generate via
// CUINamedVectorGlyph.drawInContext. Handles the subset of the PDF content-stream
// language Apple's vector symbol renderer actually emits:
//
//   path construction: m l c v y h re
//   path painting:     S s f F f* B B* b b* n
//   graphics state:    q Q
//   color:             rg RG sc scn (non-stroke / stroke RGB with optional alpha)
//   transform:         cm
//
// For each path painted, we emit an <svg:path d="..."> element with the
// effective fill color + opacity captured at the paint operator.

struct PdfPath {
    var d: String            // the accumulated SVG d-attribute
    var fill: CGColor        // effective fill color (RGBA)
    var fillRule: FillRule   // PDF f/F → nonzero, f*/B*/b* → evenodd

    enum FillRule { case nonzero, evenodd }
}

enum PdfToSvg {

    /// Parse all painted paths out of the given PDF bytes.
    static func extractPaths(from pdf: Data, pageSize: CGSize) -> [PdfPath] {
        var paths: [PdfPath] = []
        // Walk each /Contents stream block, inflate, and interpret.
        let start = Data("stream\n".utf8)
        let end = Data("\nendstream".utf8)
        var cursor = 0
        while let s = pdf.range(of: start, in: cursor..<pdf.count) {
            guard let e = pdf.range(of: end, in: s.upperBound..<pdf.count) else { break }
            let chunk = pdf.subdata(in: s.upperBound..<e.lowerBound)
            if let infl = inflate(chunk) {
                paths.append(contentsOf: interpret(stream: infl, pageSize: pageSize))
            }
            cursor = e.upperBound
        }
        return paths
    }

    private static func inflate(_ src: Data) -> Data? {
        let cap = max(src.count * 40, 65536)
        var dst = Data(count: cap)
        let n = src.withUnsafeBytes { sb -> Int in
            dst.withUnsafeMutableBytes { db -> Int in
                compression_decode_buffer(
                    db.bindMemory(to: UInt8.self).baseAddress!, cap,
                    sb.bindMemory(to: UInt8.self).baseAddress! + 2, max(sb.count - 6, 0),
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        dst.removeSubrange(n..<dst.count)
        return dst
    }

    /// PDF content-stream interpreter. Only tracks what we need for correct vector
    /// re-emission: CTM stack, current point, non-stroke color, constructed path.
    private static func interpret(stream: Data, pageSize: CGSize) -> [PdfPath] {
        guard let text = String(data: stream, encoding: .isoLatin1) else { return [] }
        let tokens = tokenizeStream(text)

        struct GS {
            var ctm = CGAffineTransform.identity
            var fill: CGColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        }
        var stack: [GS] = [GS()]
        var numStack: [Double] = []
        var d = ""          // current SVG d-string
        var hasSub = false  // whether the current subpath has a moveto
        var paths: [PdfPath] = []

        func cur() -> GS { stack[stack.count - 1] }
        func setCur(_ g: GS) { stack[stack.count - 1] = g }

        func fmt(_ x: Double) -> String {
            // Up to 4 decimal places, stripping trailing zeros.
            let s = String(format: "%.4f", x)
            var trimmed = s
            if trimmed.contains(".") {
                while trimmed.hasSuffix("0") { trimmed.removeLast() }
                if trimmed.hasSuffix(".") { trimmed.removeLast() }
            }
            return trimmed
        }

        func applyCTM(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x, y: y).applying(cur().ctm)
        }

        func emitPaint(_ rule: PdfPath.FillRule) {
            guard !d.isEmpty else {
                numStack.removeAll(); return
            }
            paths.append(PdfPath(d: d, fill: cur().fill, fillRule: rule))
            d = ""
            hasSub = false
            numStack.removeAll()
        }

        for tok in tokens {
            if let n = Double(tok) { numStack.append(n); continue }

            switch tok {
            case "q":
                stack.append(cur())
            case "Q":
                if stack.count > 1 { stack.removeLast() }
            case "cm":
                guard numStack.count >= 6 else { numStack.removeAll(); continue }
                let a = numStack[numStack.count-6], b = numStack[numStack.count-5]
                let c = numStack[numStack.count-4], dd = numStack[numStack.count-3]
                let e = numStack[numStack.count-2], f = numStack[numStack.count-1]
                numStack.removeLast(6)
                var g = cur()
                let m = CGAffineTransform(a: a, b: b, c: c, d: dd, tx: e, ty: f)
                g.ctm = m.concatenating(g.ctm)
                setCur(g)
            case "rg":
                guard numStack.count >= 3 else { numStack.removeAll(); continue }
                let r = numStack[numStack.count-3], gg = numStack[numStack.count-2], b = numStack[numStack.count-1]
                numStack.removeLast(3)
                var g = cur()
                g.fill = CGColor(srgbRed: r, green: gg, blue: b, alpha: 1)
                setCur(g)
            case "RG":
                // stroke color — we don't stroke
                if numStack.count >= 3 { numStack.removeLast(3) }
            case "sc", "scn":
                // non-stroke color in current color space — we assume DeviceRGB
                if numStack.count >= 3 {
                    let r = numStack[numStack.count-3], gg = numStack[numStack.count-2], b = numStack[numStack.count-1]
                    numStack.removeLast(3)
                    var g = cur()
                    g.fill = CGColor(srgbRed: r, green: gg, blue: b, alpha: 1)
                    setCur(g)
                } else if numStack.count >= 1 {
                    // grayscale
                    let k = numStack[numStack.count-1]
                    numStack.removeLast(1)
                    var g = cur()
                    g.fill = CGColor(srgbRed: k, green: k, blue: k, alpha: 1)
                    setCur(g)
                }
            case "SC", "SCN":
                // stroke color — discard
                numStack.removeAll()
            case "g":
                if let k = numStack.last {
                    numStack.removeLast()
                    var gs = cur()
                    gs.fill = CGColor(srgbRed: k, green: k, blue: k, alpha: 1)
                    setCur(gs)
                }
            case "G":
                if !numStack.isEmpty { numStack.removeLast() }
            case "m":
                guard numStack.count >= 2 else { numStack.removeAll(); continue }
                let y = numStack[numStack.count-1], x = numStack[numStack.count-2]
                numStack.removeLast(2)
                let p = applyCTM(x, y)
                d += "M\(fmt(p.x)) \(fmt(p.y)) "
                hasSub = true
            case "l":
                guard numStack.count >= 2, hasSub else { numStack.removeAll(); continue }
                let y = numStack[numStack.count-1], x = numStack[numStack.count-2]
                numStack.removeLast(2)
                let p = applyCTM(x, y)
                d += "L\(fmt(p.x)) \(fmt(p.y)) "
            case "c":
                guard numStack.count >= 6, hasSub else { numStack.removeAll(); continue }
                let y3 = numStack[numStack.count-1], x3 = numStack[numStack.count-2]
                let y2 = numStack[numStack.count-3], x2 = numStack[numStack.count-4]
                let y1 = numStack[numStack.count-5], x1 = numStack[numStack.count-6]
                numStack.removeLast(6)
                let p1 = applyCTM(x1, y1), p2 = applyCTM(x2, y2), p3 = applyCTM(x3, y3)
                d += "C\(fmt(p1.x)) \(fmt(p1.y)) \(fmt(p2.x)) \(fmt(p2.y)) \(fmt(p3.x)) \(fmt(p3.y)) "
            case "v":
                // (current, x2 y2, x3 y3) c
                guard numStack.count >= 4, hasSub else { numStack.removeAll(); continue }
                let y3 = numStack[numStack.count-1], x3 = numStack[numStack.count-2]
                let y2 = numStack[numStack.count-3], x2 = numStack[numStack.count-4]
                numStack.removeLast(4)
                let p2 = applyCTM(x2, y2), p3 = applyCTM(x3, y3)
                d += "S\(fmt(p2.x)) \(fmt(p2.y)) \(fmt(p3.x)) \(fmt(p3.y)) "
            case "y":
                guard numStack.count >= 4, hasSub else { numStack.removeAll(); continue }
                let y3 = numStack[numStack.count-1], x3 = numStack[numStack.count-2]
                let y1 = numStack[numStack.count-3], x1 = numStack[numStack.count-4]
                numStack.removeLast(4)
                let p1 = applyCTM(x1, y1), p3 = applyCTM(x3, y3)
                d += "C\(fmt(p1.x)) \(fmt(p1.y)) \(fmt(p3.x)) \(fmt(p3.y)) \(fmt(p3.x)) \(fmt(p3.y)) "
            case "h":
                if hasSub { d += "Z " }
            case "re":
                guard numStack.count >= 4 else { numStack.removeAll(); continue }
                let h = numStack[numStack.count-1], w = numStack[numStack.count-2]
                let y = numStack[numStack.count-3], x = numStack[numStack.count-4]
                numStack.removeLast(4)
                let p0 = applyCTM(x, y), p1 = applyCTM(x+w, y), p2 = applyCTM(x+w, y+h), p3 = applyCTM(x, y+h)
                d += "M\(fmt(p0.x)) \(fmt(p0.y)) L\(fmt(p1.x)) \(fmt(p1.y)) L\(fmt(p2.x)) \(fmt(p2.y)) L\(fmt(p3.x)) \(fmt(p3.y)) Z "
                hasSub = true
            case "f", "F":   emitPaint(.nonzero)
            case "f*":       emitPaint(.evenodd)
            case "B":        emitPaint(.nonzero)
            case "B*":       emitPaint(.evenodd)
            case "b":        if hasSub { d += "Z " }; emitPaint(.nonzero)
            case "b*":       if hasSub { d += "Z " }; emitPaint(.evenodd)
            case "S", "s":
                // stroke only — we don't emit stroke-only paths
                d = ""; hasSub = false; numStack.removeAll()
            case "n":
                d = ""; hasSub = false; numStack.removeAll()
            case "W", "W*":
                // clip — skip silently
                numStack.removeAll()
            case "ri", "cs", "CS", "gs":
                // rendering intent / color space name / ExtGState — skip arguments
                numStack.removeAll()
            default:
                // Unknown operator; drop numeric operands to avoid contaminating
                // the next real op.
                numStack.removeAll()
            }
        }

        return paths
    }

    /// Split a PDF content stream into whitespace-separated tokens. Strings and
    /// hex strings can contain whitespace, but Apple's symbol output never uses
    /// them — we don't bother handling them.
    private static func tokenizeStream(_ s: String) -> [String] {
        var out: [String] = []
        out.reserveCapacity(s.count / 3)
        var buf = ""
        for ch in s.unicodeScalars {
            switch ch {
            case " ", "\n", "\r", "\t":
                if !buf.isEmpty { out.append(buf); buf.removeAll(keepingCapacity: true) }
            case "/":
                // Name object — consume the rest of the token as-is
                if !buf.isEmpty { out.append(buf); buf.removeAll(keepingCapacity: true) }
                buf.append(Character(ch))
            default:
                buf.append(Character(ch))
            }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }
}

// MARK: - Output composition

enum SvgEmitter {
    /// Y-up → Y-down flip: PDF coordinate origin is bottom-left; SVG is top-left.
    /// We emit a viewBox equal to the PDF mediaBox and wrap all paths in a group
    /// with `transform="matrix(1 0 0 -1 0 H)"`.
    static func emit(
        paths: [PdfPath],
        viewBox: CGRect,
        mode: RenderMode,
        tintColor: CGColor? = nil,
        paletteColors: [CGColor] = [],
        hierarchyLevels: [Int] = []
    ) -> Data {
        // Flat, self-contained SVG. Paths carry inline `fill` (the exact sRGB
        // value Apple's renderer wrote to the PDF) plus `data-layer` tags that
        // match Apple's logical layer scheme so downstream tooling can re-theme
        // without touching geometry.
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" "
        out += "viewBox=\"\(fmt(viewBox.minX)) \(fmt(viewBox.minY)) \(fmt(viewBox.width)) \(fmt(viewBox.height))\" "
        out += "width=\"\(fmt(viewBox.width))\" height=\"\(fmt(viewBox.height))\">\n"
        // PDF origin is bottom-left, SVG is top-left — flip once at the wrapper.
        out += "  <g transform=\"matrix(1 0 0 -1 0 \(fmt(viewBox.height)))\">\n"

        // Tint's alpha multiplies into every mono/hier path (PDF content stream
        // loses it — CG writes 3-component `rg`, no alpha). Default 1 if absent.
        let tintAlpha: CGFloat = tintColor.flatMap { $0.components?.count ?? 0 >= 4 ? $0.components![3] : 1 } ?? 1

        // palette-fill → layer-index lookup; multiple paths can share a slot.
        // Keyed by the opaque hex (the PDF always round-trips alpha=1), so a
        // #ff0000aa palette entry still maps to whatever red path the emitter
        // lifted out of the PDF.
        var paletteHex: [String: Int] = [:]
        for (i, c) in paletteColors.enumerated() { paletteHex[cssHex(c)] = i }

        for (i, p) in paths.enumerated() {
            // Default to what we lifted from the PDF; override per-mode so the
            // original caller-provided color (with alpha) wins.
            var fillHex = cssHex(p.fill)
            var fillAlpha: CGFloat = 1
            let tag: String
            var extra = ""
            switch mode {
            case .monochrome:
                tag = "monochrome-0"
                if let tc = tintColor {
                    fillHex = cssHex(tc)
                    fillAlpha = tintAlpha
                }
            case .hierarchical:
                let tier = i < hierarchyLevels.count ? max(0, min(2, hierarchyLevels[i])) : min(i, 2)
                tag = "hierarchical-\(tier)"
                if let tc = tintColor {
                    fillHex = cssHex(tc)
                }
                fillAlpha = Glyph.hierarchicalAlphas[tier] * tintAlpha
            case .palette:
                // Pick the palette slot: first try matching by the PDF-lifted
                // fill hex (handles Apple emitting paths in slot order but with
                // per-layer colors we can identify). Otherwise use the path
                // index, cycling if we've run past the palette length. Never
                // drop a path — short palettes cycle rather than disappear.
                if !paletteColors.isEmpty {
                    let matched = paletteHex[fillHex]
                    let idx = matched ?? (i % paletteColors.count)
                    let pc = paletteColors[idx]
                    fillHex = cssHex(pc)
                    if let comps = pc.components, comps.count >= 4 {
                        fillAlpha = comps[3]
                    }
                    tag = "palette-\(idx)"
                } else {
                    tag = "palette-\(i)"
                }
            case .multicolor:
                tag = "multicolor-\(i)"
            }
            if fillAlpha < 1 {
                extra += " fill-opacity=\"\(fmtAlpha(fillAlpha))\""
            }
            if p.fillRule == .evenodd { extra += " fill-rule=\"evenodd\"" }
            out += "    <path data-layer=\"\(tag)\" fill=\"\(fillHex)\"\(extra) d=\"\(p.d.trimmingCharacters(in: .whitespaces))\"/>\n"
        }

        out += "  </g>\n</svg>\n"
        return Data(out.utf8)
    }

    /// Format an alpha value for SVG `fill-opacity`: 3 decimal places, trailing
    /// zeros stripped. 0.502 for #80, 0.5 for #7f…, keeps output compact.
    private static func fmtAlpha(_ a: CGFloat) -> String {
        let clamped = max(0, min(1, Double(a)))
        let s = String(format: "%.3f", clamped)
        var trimmed = s
        if trimmed.contains(".") {
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
        }
        return trimmed
    }

    private static func fmt(_ x: CGFloat) -> String {
        let s = String(format: "%g", Double(x))
        return s
    }

    private static func cssHex(_ c: CGColor) -> String {
        guard let comps = c.components else { return "#000000" }
        // Round, don't truncate: Apple emits PDF color components as 4-decimal
        // floats, so 0x6B (= 107/255 = 0.41961…) round-trips as 0.4196 → 106.998
        // which Int() chops to 106 (= 0x6A). One-off-in-each-channel drift kills
        // hex round-trip for brand colors. Round to the nearest byte instead.
        func byte(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
        let r = byte(comps.count > 0 ? comps[0] : 0)
        let g = byte(comps.count > 1 ? comps[1] : 0)
        let b = byte(comps.count > 2 ? comps[2] : 0)
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
