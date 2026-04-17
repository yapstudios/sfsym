import Foundation
import AppKit

enum CLIError: Error {
    case usage(String)
    case bad(String)
}

struct CLI {
    var args: [String]
    var cursor: Int = 1

    mutating func next() -> String? {
        guard cursor < args.count else { return nil }
        defer { cursor += 1 }
        return args[cursor]
    }

    mutating func optValue(_ flag: String) -> String? {
        // Supports "--flag value" and "--flag=value".
        for i in cursor..<args.count {
            if args[i] == flag, i + 1 < args.count {
                let v = args[i+1]
                args.remove(at: i+1); args.remove(at: i)
                return v
            }
            if args[i].hasPrefix(flag + "=") {
                let v = String(args[i].dropFirst(flag.count + 1))
                args.remove(at: i)
                return v
            }
        }
        return nil
    }

    /// Consume a boolean flag if present anywhere in argv (after the cursor).
    mutating func flag(_ name: String) -> Bool {
        for i in cursor..<args.count where args[i] == name {
            args.remove(at: i)
            return true
        }
        return false
    }
}

func parseWeight(_ s: String) throws -> NSFont.Weight {
    switch s.lowercased() {
    case "ultralight": return .ultraLight
    case "thin": return .thin
    case "light": return .light
    case "regular", "": return .regular
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    case "heavy": return .heavy
    case "black": return .black
    default: throw CLIError.bad("unknown weight: \(s)")
    }
}

func parseScale(_ s: String) throws -> NSImage.SymbolScale {
    switch s.lowercased() {
    case "small": return .small
    case "medium", "": return .medium
    case "large": return .large
    default: throw CLIError.bad("unknown scale: \(s)")
    }
}

func parseMode(_ s: String) throws -> RenderMode {
    guard let m = RenderMode(rawValue: s.lowercased()) else {
        throw CLIError.bad("unknown mode: \(s)")
    }
    return m
}

func parseColor(_ s: String) throws -> NSColor {
    // Accept #RRGGBB, #RRGGBBAA, or named ("red", "systemBlue", "label").
    let trimmed = s.hasPrefix("#") ? String(s.dropFirst()) : s
    if let scalar = UInt32(trimmed, radix: 16), (trimmed.count == 6 || trimmed.count == 8) {
        let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
        if trimmed.count == 6 {
            r = CGFloat((scalar >> 16) & 0xff) / 255
            g = CGFloat((scalar >> 8) & 0xff) / 255
            b = CGFloat(scalar & 0xff) / 255
            a = 1
        } else {
            r = CGFloat((scalar >> 24) & 0xff) / 255
            g = CGFloat((scalar >> 16) & 0xff) / 255
            b = CGFloat((scalar >> 8) & 0xff) / 255
            a = CGFloat(scalar & 0xff) / 255
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
    // Named fall-through — our enum covers the Apple systemXxx namespace and the
    // standard semantic roles (label, link, …). Anything else is a user error.
    if let c = AppleSystemColor(rawValue: s)?.nsColor { return c }
    throw CLIError.bad("unknown color: \(s)")
}

func parsePalette(_ s: String) throws -> [NSColor] {
    try s.split(separator: ",").map { try parseColor(String($0).trimmingCharacters(in: .whitespaces)) }
}

let usage = """
sfsym — export Apple SF Symbols as graphics files.

Usage:
  sfsym export <name>  --format pdf|png|svg
                       [--mode monochrome|hierarchical|palette|multicolor]
                       [--weight ultralight|thin|light|regular|medium|semibold|bold|heavy|black]
                       [--scale small|medium|large]
                       [--size <pt>]                (default 32)
                       [--color <hex|systemName>]     monochrome / hierarchical tint
                       [--palette <hex,hex,…>]        palette mode fills, in layer order
                       [-o <path>|-]                  '-' = stdout (default)

  sfsym info <name> [--json]                           layer counts + alignment rect
  sfsym list [--prefix <str>] [--limit <n>] [--json]   enumerate symbols (offline, from Assets.car)
  sfsym modes <name> [--json]                          which rendering modes the symbol supports
  sfsym batch                                          bulk exports from stdin (30× faster than one-per-exec)
  sfsym schema                                         machine-readable CLI surface (JSON)
  sfsym completions <bash|zsh|fish>                    print shell completion script

Output quality:
  PDF + monochrome / hierarchical / palette  → vector (Apple's CUINamedVectorGlyph draw)
  PDF + multicolor                           → raster embedded in PDF (documented fallback)
  SVG + monochrome / hierarchical / palette  → vector; paths come from Apple's PDF content
                                               stream, re-emitted with inline sRGB fills and
                                               data-layer tags for downstream theming
  SVG + multicolor                           → not supported (no vector path to lift)
  PNG all modes                              → Apple's own rasterizer at 2× pixel density

Colors accept hex (#RRGGBB / #RRGGBBAA) or Apple systemXxx names (systemRed, systemBlue, …).

Examples:
  sfsym export heart.fill -f svg --color '#ff3b30' -o heart.svg
  sfsym export cloud.sun.rain.fill -f svg --mode palette --palette '#ff3b30,#ffcc00,#4477ff'
  sfsym export cloud.sun.rain.fill -f png --mode multicolor --size 128 -o cloud@2x.png
  sfsym list --prefix cloud
"""

/// Single source of truth for the tool's version string. Used by `--version`,
/// the Homebrew formula's test, and the `schema` command.
let sfsymVersion = "0.2.1"

/// Shared export dispatcher: takes raw argv starting at the symbol name and runs
/// through format/mode/color/output parsing. Used by both `export` and `batch`.
func runExportArgv(_ rawArgv: [String]) throws {
    // CLI.cursor starts at 1 (skipping args[0] by convention), so we only need
    // the "export" marker at index 1 before the real args.
    var cli = CLI(args: ["sfsym", "export"] + rawArgv)
    _ = cli.next()  // drain "export"
    guard let name = cli.next() else { throw CLIError.usage(usage) }
    let format = cli.optValue("--format") ?? cli.optValue("-f") ?? "pdf"
    let mode = try parseMode(cli.optValue("--mode") ?? "monochrome")
    let weight = try parseWeight(cli.optValue("--weight") ?? "regular")
    let scale = try parseScale(cli.optValue("--scale") ?? "medium")
    let size = CGFloat(Double(cli.optValue("--size") ?? "32") ?? 32)
    let tint = try parseColor(cli.optValue("--color") ?? "black")
    let palette = try parsePalette(cli.optValue("--palette") ?? "systemRed,systemGreen,systemBlue")
    let outPath = cli.optValue("-o") ?? cli.optValue("--out") ?? "-"

    let resolvedTint = tint.usingColorSpace(.sRGB) ?? tint
    var opts = RenderOptions(name: name, mode: mode, weight: weight, scale: scale,
                             pointSize: size, tint: resolvedTint, paletteColors: palette)
    opts.paletteColors = opts.paletteColors.map { $0.usingColorSpace(.sRGB) ?? $0 }

    let data: Data
    switch format.lowercased() {
    case "pdf": data = try Render.pdf(options: opts)
    case "png": data = try Render.png(options: opts)
    case "svg": data = try Render.svg(options: opts)
    default: throw CLIError.bad("unknown format: \(format) (use pdf, png, or svg)")
    }
    if outPath == "-" {
        FileHandle.standardOutput.write(data)
    } else {
        try data.write(to: URL(fileURLWithPath: outPath))
    }
}

/// Tokenize a batch line: whitespace-separated args with support for '...' and "..." quoting.
func tokenizeLine(_ s: String) -> [String] {
    var out: [String] = []
    var cur = ""
    var quote: Character? = nil
    for ch in s {
        if let q = quote {
            if ch == q { quote = nil } else { cur.append(ch) }
        } else if ch == "'" || ch == "\"" {
            quote = ch
        } else if ch == " " || ch == "\t" {
            if !cur.isEmpty { out.append(cur); cur.removeAll() }
        } else {
            cur.append(ch)
        }
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}

func runCLI() throws {
    var cli = CLI(args: CommandLine.arguments)
    guard let cmd = cli.next() else { print(usage); return }
    switch cmd {

    case "help", "-h", "--help":
        print(usage)

    case "version", "--version", "-V":
        print("sfsym \(sfsymVersion)")

    case "export":
        let argv = Array(CommandLine.arguments.dropFirst(2))
        try runExportArgv(argv)

    case "info":
        let json = cli.flag("--json")
        guard let name = cli.next() else { throw CLIError.usage(usage) }
        let cfg = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        let glyph = try Glyph.load(name: name, configuration: cfg)
        if json {
            let dict: [String: Any] = [
                "name": name,
                "size": ["width": glyph.size.width, "height": glyph.size.height],
                "alignmentRect": [
                    "x": glyph.alignmentRect.minX, "y": glyph.alignmentRect.minY,
                    "width": glyph.alignmentRect.width, "height": glyph.alignmentRect.height
                ],
                "templateLayers": glyph.numberOfTemplateLayers,
                "hierarchyLayers": glyph.numberOfHierarchyLayers,
                "paletteLayers": glyph.numberOfPaletteLayers,
                "hierarchyLevels": glyph.hierarchyLevels,
                "modes": supportedModes(for: glyph)
            ]
            try emitJSON(dict)
        } else {
            print("name:               \(name)")
            print("size (pt):          \(glyph.size)")
            print("template layers:    \(glyph.numberOfTemplateLayers)")
            print("hierarchy layers:   \(glyph.numberOfHierarchyLayers)")
            print("palette layers:     \(glyph.numberOfPaletteLayers)")
        }

    case "batch":
        // Read one export per line from stdin so we pay Swift/AppKit startup once
        // and amortize it across hundreds of renders. Each line is the same argv
        // you'd pass to `export`, space-separated. Writes to whatever -o path the
        // caller specifies per line (defaulting to stdout if '-').
        //
        // Example:
        //   heart.fill -f svg --mode palette -o out/heart.svg
        //   star.fill -f svg --color '#ff0' -o out/star.svg
        //
        // Passing `--fail-fast` stops at the first error; default is skip-and-report.
        let failFast = cli.flag("--fail-fast")
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: input, encoding: .utf8) else { return }
        var ok = 0, fail = 0
        let start = Date()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // Tokenize respecting single-quoted args (e.g. color hexes passed as '#ff00ff').
            let argv = tokenizeLine(trimmed)
            do {
                try runExportArgv(argv)
                ok += 1
            } catch {
                fail += 1
                FileHandle.standardError.write(Data("batch fail: \(trimmed) — \(error)\n".utf8))
                if failFast { exit(2) }
            }
        }
        let dt = Date().timeIntervalSince(start)
        FileHandle.standardError.write(Data(String(format: "batch: ok=%d fail=%d in %.2fs (%.1f/s)\n",
                                                    ok, fail, dt, Double(ok + fail) / max(dt, 0.001)).utf8))

    case "list":
        let json = cli.flag("--json")
        let prefix = cli.optValue("--prefix") ?? ""
        let limit = Int(cli.optValue("--limit") ?? "") ?? -1
        let cat = try Catalog()
        let names = cat.names(prefix: prefix, limit: limit < 0 ? nil : limit)
        if json {
            try emitJSON(names)
        } else {
            for n in names { print(n) }
        }

    case "modes":
        let json = cli.flag("--json")
        guard let name = cli.next() else { throw CLIError.usage(usage) }
        let cfg = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        let glyph = try Glyph.load(name: name, configuration: cfg)
        let modes = supportedModes(for: glyph)
        if json {
            try emitJSON(modes)
        } else {
            print(modes.joined(separator: "\n"))
        }

    case "schema":
        // Machine-readable surface: every subcommand, flag, choice, default, and
        // two concrete example invocations per command. Exists so agents can
        // enumerate the CLI without scraping `--help` prose.
        try emitJSON(cliSchema)

    case "completions":
        guard let shell = cli.next() else {
            throw CLIError.usage("usage: sfsym completions <bash|zsh|fish>")
        }
        let script = try Completions.script(for: shell)
        FileHandle.standardOutput.write(Data(script.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))

    default:
        throw CLIError.usage(usage)
    }
}

// MARK: - JSON helpers

func emitJSON(_ obj: Any) throws {
    let data = try JSONSerialization.data(
        withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func supportedModes(for glyph: Glyph) -> [String] {
    var modes: [String] = ["monochrome"]
    if glyph.numberOfHierarchyLayers > 0 { modes.append("hierarchical") }
    if glyph.numberOfPaletteLayers > 0 { modes.append("palette") }
    if glyph.supportsMulticolor { modes.append("multicolor") }
    return modes
}

// MARK: - CLI schema

let cliSchema: [String: Any] = [
    "name": "sfsym",
    "version": sfsymVersion,
    "description": "Export Apple SF Symbols as vector (PDF, SVG) or raster (PNG) files. Uses Apple's own renderer via private AppKit APIs — paths come from CUINamedVectorGlyph.drawInContext:, not resynthesized.",
    "exitCodes": [
        ["code": 0, "meaning": "success"],
        ["code": 1, "meaning": "symbol not found"],
        ["code": 2, "meaning": "runtime error (bad args, render failure, file I/O)"],
        ["code": 64, "meaning": "usage error"]
    ],
    "commands": [
        [
            "name": "export",
            "summary": "Render a symbol and write to a file or stdout.",
            "positional": [
                ["name": "symbol", "required": true, "description": "Canonical SF Symbol name, e.g. 'heart.fill'"]
            ],
            "flags": [
                ["name": "--format", "short": "-f", "type": "enum",
                 "choices": ["pdf", "png", "svg"], "default": "pdf",
                 "description": "Output format. SVG and PDF are vector for mono/hier/palette; PDF multicolor embeds raster; SVG multicolor is not supported."],
                ["name": "--mode", "type": "enum",
                 "choices": ["monochrome", "hierarchical", "palette", "multicolor"],
                 "default": "monochrome"],
                ["name": "--weight", "type": "enum",
                 "choices": ["ultralight", "thin", "light", "regular", "medium",
                             "semibold", "bold", "heavy", "black"], "default": "regular"],
                ["name": "--scale", "type": "enum",
                 "choices": ["small", "medium", "large"], "default": "medium"],
                ["name": "--size", "type": "number", "default": 32,
                 "description": "Point size. PNG pixel dimensions = size × 2."],
                ["name": "--color", "type": "string", "default": "black",
                 "description": "Tint for monochrome / hierarchical. Hex (#rrggbb / #rrggbbaa) or Apple systemXxx name."],
                ["name": "--palette", "type": "string",
                 "default": "systemRed,systemGreen,systemBlue",
                 "description": "Comma-separated colors for palette mode, one per palette layer."],
                ["name": "-o", "long": "--out", "type": "path", "default": "-",
                 "description": "Output path. '-' writes to stdout."]
            ],
            "examples": [
                "sfsym export heart.fill -f svg --color '#ff3b30' -o heart.svg",
                "sfsym export cloud.sun.rain.fill -f svg --mode palette --palette '#ff3b30,#ffcc00,#4477ff' -o weather.svg"
            ]
        ],
        [
            "name": "batch",
            "summary": "Read one export invocation per line from stdin. Amortizes Swift/AppKit startup across many renders (~30× faster than one-exec-per-render for bulk work).",
            "flags": [
                ["name": "--fail-fast", "type": "bool", "default": false,
                 "description": "Exit on first failing line instead of skipping."]
            ],
            "stdin": "One export command per line: <symbol> [flags...] -o <path>. Blank lines and '#' comments are ignored.",
            "stderr": "Final summary line: 'batch: ok=N fail=N in Ns (rate/s)'",
            "examples": [
                "printf 'heart.fill -f svg -o h.svg\\nstar.fill -f svg -o s.svg\\n' | sfsym batch"
            ]
        ],
        [
            "name": "list",
            "summary": "Enumerate all SF Symbol names (8303+ as of macOS 26). Reads directly from the OS's Assets.car so the list is always current.",
            "flags": [
                ["name": "--prefix", "type": "string", "default": "",
                 "description": "Only include names starting with this prefix."],
                ["name": "--limit", "type": "number", "default": -1,
                 "description": "Cap to N names after sorting."],
                ["name": "--json", "type": "bool", "default": false,
                 "description": "Emit JSON array of strings instead of newline-separated."]
            ],
            "examples": [
                "sfsym list | wc -l",
                "sfsym list --prefix cloud --json"
            ]
        ],
        [
            "name": "info",
            "summary": "Report geometry and layer metadata for a symbol.",
            "positional": [["name": "symbol", "required": true]],
            "flags": [
                ["name": "--json", "type": "bool", "default": false]
            ],
            "jsonShape": [
                "name": "string",
                "size": ["width": "number", "height": "number"],
                "alignmentRect": ["x": "number", "y": "number", "width": "number", "height": "number"],
                "templateLayers": "number",
                "hierarchyLayers": "number",
                "paletteLayers": "number",
                "hierarchyLevels": "array of number (one per painted path; 0=primary, 1=secondary, 2=tertiary)",
                "modes": "array of string"
            ],
            "examples": [
                "sfsym info heart.fill --json"
            ]
        ],
        [
            "name": "modes",
            "summary": "List rendering modes supported by a given symbol.",
            "positional": [["name": "symbol", "required": true]],
            "flags": [["name": "--json", "type": "bool", "default": false]],
            "examples": ["sfsym modes cloud.sun.rain.fill --json"]
        ],
        [
            "name": "schema",
            "summary": "Emit this JSON document.",
            "flags": [],
            "examples": ["sfsym schema"]
        ],
        [
            "name": "completions",
            "summary": "Print a shell completion script for bash, zsh, or fish.",
            "positional": [
                ["name": "shell", "required": true, "choices": ["bash", "zsh", "fish"]]
            ],
            "examples": [
                "sfsym completions zsh > ~/.zsh/completions/_sfsym",
                "source <(sfsym completions bash)"
            ]
        ],
        [
            "name": "help",
            "summary": "Print human-readable usage.",
            "aliases": ["-h", "--help"]
        ]
    ]
]
