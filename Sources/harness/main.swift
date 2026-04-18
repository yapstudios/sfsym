import Foundation

// Diff harness: for a fixed set of 50 SF Symbols × 4 modes × 2 formats,
// invokes `sfsym export` (built CLI) and verifies the output against claimed
// invariants:
//
//   PDF monochrome / hierarchical / palette → vector (≥1 path op, 0 image ops)
//   PDF multicolor                           → raster (0 path ops, ≥1 image op) — accepted
//   PNG *                                    → valid PNG (starts with \x89PNG)
//
// Prints a green PASS / red FAIL per cell and a summary at the end. Exits
// non-zero if any invariant fails.

import CoreFoundation

let symbols = [
    // Simple single-layer shapes
    "heart.fill", "star.fill", "circle.fill", "square.fill", "triangle.fill",
    "xmark", "checkmark", "chevron.right", "arrow.right", "plus",
    // Common icons
    "house.fill", "bell.fill", "gear", "magnifyingglass", "trash",
    "envelope.fill", "lock.fill", "person.fill", "photo", "folder.fill",
    // Multi-layer (hierarchical / palette matter)
    "cloud.sun.rain.fill", "cloud.bolt.rain.fill", "cloud.fog.fill",
    "moon.stars.fill", "sparkles",
    // Text-ish
    "textformat", "textformat.size", "textformat.alt", "bold", "italic",
    // System chrome
    "wifi", "battery.100", "speaker.wave.3.fill", "mic.fill", "video.fill",
    // Arrows & nav
    "arrow.up", "arrow.down", "arrow.left", "arrow.clockwise", "arrow.counterclockwise",
    // Finance / commerce
    "creditcard.fill", "cart.fill", "bag.fill",
    // People / social
    "hand.thumbsup.fill", "hand.wave.fill", "message.fill", "bubble.left.fill",
    "person.2.fill"
]

let modes = ["monochrome", "hierarchical", "palette", "multicolor"]

struct CellResult {
    var pass: Bool
    var detail: String
    var bytes: Int
}

func runExport(_ args: [String]) -> Data? {
    let t = Process()
    t.executableURL = URL(fileURLWithPath: ".build/release/sfsym")
    t.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    t.standardOutput = outPipe
    t.standardError = errPipe
    do { try t.run() } catch { return nil }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    t.waitUntilExit()
    guard t.terminationStatus == 0 else { return nil }
    return data
}

// Minimal PDF content-stream sniff: flate-decompressed streams, count ops.
import Compression

func inflate(_ src: Data) -> Data? {
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

func countPdfOps(_ pdf: Data) -> (paths: Int, images: Int) {
    var paths = 0, images = 0
    let startMarker = Data("stream\n".utf8)
    let endMarker = Data("\nendstream".utf8)
    var cursor = 0
    while let sR = pdf.range(of: startMarker, in: cursor..<pdf.count) {
        guard let eR = pdf.range(of: endMarker, in: sR.upperBound..<pdf.count) else { break }
        let chunk = pdf.subdata(in: sR.upperBound..<eR.lowerBound)
        if let infl = inflate(chunk) {
            // Tokenize on ASCII whitespace and match single/double-letter path ops.
            var i = infl.startIndex
            let e = infl.endIndex
            while i < e {
                // skip whitespace
                while i < e, infl[i] == 0x20 || infl[i] == 0x0a || infl[i] == 0x0d || infl[i] == 0x09 { i += 1 }
                let tok = i
                while i < e, infl[i] != 0x20, infl[i] != 0x0a, infl[i] != 0x0d, infl[i] != 0x09 { i += 1 }
                let len = i - tok
                if len == 1 {
                    switch infl[tok] {
                    case 0x6d, 0x6c, 0x63, 0x76, 0x79: paths += 1  // m l c v y
                    default: break
                    }
                } else if len == 2 {
                    if infl[tok] == 0x72, infl[tok+1] == 0x65 { paths += 1 }        // "re"
                    else if infl[tok] == 0x44, infl[tok+1] == 0x6f { images += 1 }  // "Do"
                }
            }
        }
        cursor = eR.upperBound
    }
    return (paths, images)
}

func isPNG(_ data: Data) -> Bool {
    guard data.count >= 8 else { return false }
    let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    for i in 0..<8 where data[i] != sig[i] { return false }
    return true
}

var table: [String: [String: CellResult]] = [:]
var fails = 0

for name in symbols {
    var row: [String: CellResult] = [:]
    for mode in modes {
        // PDF cell
        let pdfArgs = ["export", name, "-f", "pdf", "--mode", mode, "--size", "48", "-o", "-"]
        if let pdf = runExport(pdfArgs) {
            let (p, i) = countPdfOps(pdf)
            var pass = true
            var detail = "paths=\(p), images=\(i)"
            switch mode {
            case "multicolor":
                // Raster fallback acceptable: expect ≥1 image op.
                if i < 1 { pass = false; detail += " [expected image op]" }
            default:
                // Vector: expect path ops, zero image ops.
                if p < 1 { pass = false; detail += " [no path ops]" }
                if i > 0 { pass = false; detail += " [unexpected image op]" }
            }
            row["pdf-\(mode)"] = CellResult(pass: pass, detail: detail, bytes: pdf.count)
            if !pass { fails += 1 }
        } else {
            row["pdf-\(mode)"] = CellResult(pass: false, detail: "export failed", bytes: 0)
            fails += 1
        }

        // PNG cell
        let pngArgs = ["export", name, "-f", "png", "--mode", mode, "--size", "48", "-o", "-"]
        if let png = runExport(pngArgs) {
            let ok = isPNG(png)
            row["png-\(mode)"] = CellResult(pass: ok, detail: ok ? "valid PNG" : "not PNG", bytes: png.count)
            if !ok { fails += 1 }
        } else {
            row["png-\(mode)"] = CellResult(pass: false, detail: "export failed", bytes: 0)
            fails += 1
        }

        // SVG cell — multicolor skipped (no vector path)
        if mode != "multicolor" {
            let svgArgs = ["export", name, "-f", "svg", "--mode", mode, "--size", "48", "-o", "-"]
            if let svg = runExport(svgArgs) {
                let text = String(data: svg, encoding: .utf8) ?? ""
                // Valid: starts with XML prolog, closes with </svg>, contains at least one <path
                let ok = text.hasPrefix("<?xml") && text.contains("</svg>") && text.contains("<path")
                // Count <path elements — must be ≥ 1
                let pathCount = text.components(separatedBy: "<path").count - 1
                let detail = "paths=\(pathCount)"
                row["svg-\(mode)"] = CellResult(pass: ok && pathCount >= 1, detail: detail, bytes: svg.count)
                if !(ok && pathCount >= 1) { fails += 1 }
            } else {
                row["svg-\(mode)"] = CellResult(pass: false, detail: "export failed", bytes: 0)
                fails += 1
            }
        }
    }
    table[name] = row
}

// Print summary
let cols: [String] = modes.flatMap { m -> [String] in
    m == "multicolor" ? ["pdf-\(m)", "png-\(m)"] : ["pdf-\(m)", "png-\(m)", "svg-\(m)"]
}
print("symbol".padding(toLength: 26, withPad: " ", startingAt: 0), terminator: "")
for c in cols { print(c.padding(toLength: 18, withPad: " ", startingAt: 0), terminator: "") }
print("")
for name in symbols {
    print(name.padding(toLength: 26, withPad: " ", startingAt: 0), terminator: "")
    for c in cols {
        let r = table[name]?[c]
        let mark = r?.pass == true ? "✓" : "✗"
        let brief = "\(mark) \(r?.bytes ?? 0)B"
        print(brief.padding(toLength: 18, withPad: " ", startingAt: 0), terminator: "")
    }
    print("")
}
print("")
let total = symbols.count * cols.count
print("PASS: \(total - fails) / \(total)")
if fails > 0 {
    print("First failures:")
    var shown = 0
    outer: for name in symbols {
        for c in cols {
            if let r = table[name]?[c], !r.pass {
                print("  \(name) \(c): \(r.detail)")
                shown += 1
                if shown >= 10 { break outer }
            }
        }
    }
}
exit(fails == 0 ? 0 : 1)
