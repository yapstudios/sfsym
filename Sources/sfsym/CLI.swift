import Foundation
import AppKit

enum CLIError: Error {
    case usage(String)
    case bad(String)
    case io(String)
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
    // Accept #RGB, #RGBA, #RRGGBB, #RRGGBBAA, or named ("red", "systemBlue", "label").
    // Web-style short hex (#f00 → #ff0000) is supported for agent convenience —
    // every designer tries it first.
    let raw = s.hasPrefix("#") ? String(s.dropFirst()) : s
    let expanded: String
    switch raw.count {
    case 3:  expanded = raw.map { "\($0)\($0)" }.joined()
    case 4:  expanded = raw.map { "\($0)\($0)" }.joined()
    case 6, 8: expanded = raw
    default: expanded = raw  // bail to named-color branch below
    }
    if (expanded.count == 6 || expanded.count == 8),
       let scalar = UInt32(expanded, radix: 16) {
        let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
        if expanded.count == 6 {
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
    // Split without dropping empties so an empty slot ("#f00,,#00f") is caught
    // as a user error instead of silently producing a shorter palette.
    let parts = s.split(separator: ",", omittingEmptySubsequences: false)
    var out: [NSColor] = []
    for (i, part) in parts.enumerated() {
        let token = String(part).trimmingCharacters(in: .whitespaces)
        if token.isEmpty {
            throw CLIError.bad("empty color in --palette at position \(i + 1)")
        }
        out.append(try parseColor(token))
    }
    return out
}

let usage = """
sfsym — export Apple SF Symbols as graphics files.

Usage:
  sfsym export <name>  [--format pdf|png|svg]        (inferred from -o ext)
                       [--mode monochrome|hierarchical|palette|multicolor]
                       [--weight ultralight|thin|light|regular|medium|semibold|bold|heavy|black]
                       [--scale small|medium|large]
                       [--size <pt>]                (default 32, max 2048)
                       [--color <hex|systemName>]     monochrome / hierarchical tint
                       [--palette <hex,hex,…>]        palette mode fills, in layer order
                       [-o <path>|-]                  '-' = stdout (default)

  sfsym info <name> [--json]                           layer counts + alignment rect
  sfsym list [--prefix <str>] [--contains <sub>]
             [--category <key>] [--search <kw>]
             [--limit <n>] [--json]                    enumerate symbols (offline, from Assets.car)
  sfsym modes <name> [--json]                          which rendering modes the symbol supports
  sfsym categories [--json]                            list category keys (needs SF Symbols.app)
  sfsym colors [--json]                                list named colors + their hex values
  sfsym batch [--fail-fast]                            bulk exports from stdin (30× faster than one-per-exec)
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
let sfsymVersion = "0.2.10"

/// Shared export dispatcher: takes raw argv starting at the symbol name and runs
/// through format/mode/color/output parsing. Used by both `export` and `batch`.
func runExportArgv(_ rawArgv: [String]) throws {
    // CLI.cursor starts at 1 (skipping args[0] by convention), so we only need
    // the "export" marker at index 1 before the real args.
    var cli = CLI(args: ["sfsym", "export"] + rawArgv)
    _ = cli.next()  // drain "export"
    // Honor `sfsym export --help` here too (for when runExportArgv is hit via
    // the top-level `export` case in runCLI). The Set in runCLI catches the
    // common path; this makes the helper self-sufficient if ever called
    // differently.
    if rawArgv.contains("--help") || rawArgv.contains("-h") {
        print(usage)
        return
    }
    // Snapshot raw argv so we can tell whether the user *explicitly* passed
    // flags that don't apply to the chosen mode. `optValue` mutates `cli.args`
    // as it consumes, so we can't ask after-the-fact. We look for the long
    // form with and without the `=value` attachment.
    func rawHasFlag(_ name: String) -> Bool {
        return rawArgv.contains(name) || rawArgv.contains(where: { $0.hasPrefix(name + "=") })
    }
    let userGaveColor = rawHasFlag("--color")
    let userGavePalette = rawHasFlag("--palette")
    // Consume --json up front so it's not flagged as unknown later. Agents
    // standardize on passing --json; a successful export emits an envelope,
    // and errors already get JSON via main.swift's emitRuntimeError.
    let json = cli.flag("--json")
    guard let name = cli.next() else { throw CLIError.usage(usage) }
    if name.trimmingCharacters(in: .whitespaces).isEmpty {
        throw CLIError.bad("symbol name is required")
    }
    let explicitFormat = cli.optValue("--format") ?? cli.optValue("-f")
    let mode = try parseMode(cli.optValue("--mode") ?? "monochrome")
    let weight = try parseWeight(cli.optValue("--weight") ?? "regular")
    let scale = try parseScale(cli.optValue("--scale") ?? "medium")
    let sizeStr = cli.optValue("--size") ?? "32"
    guard let sizeD = Double(sizeStr), sizeD >= 1, sizeD <= 2048,
          sizeD.truncatingRemainder(dividingBy: 1) == 0 else {
        throw CLIError.bad("invalid --size: \(sizeStr) (must be an integer ≥ 1 and ≤ 2048)")
    }
    let size = CGFloat(sizeD)
    let tint = try parseColor(cli.optValue("--color") ?? "black")
    let paletteRaw = cli.optValue("--palette") ?? "systemRed,systemGreen,systemBlue"
    // Reject all-whitespace / empty user input up front: the downstream parser
    // reports per-slot errors, but "" alone isn't a slot, it's a missing value.
    if paletteRaw.trimmingCharacters(in: .whitespaces).isEmpty {
        throw CLIError.bad("--palette requires at least one color")
    }
    let palette = try parsePalette(paletteRaw)
    if mode == .palette && palette.isEmpty {
        throw CLIError.bad("--palette requires at least one color")
    }
    let outPath = cli.optValue("-o") ?? cli.optValue("--out") ?? "-"
    if outPath.isEmpty {
        throw CLIError.bad("output path cannot be empty (use - for stdout)")
    }

    // Reject typo'd flags: anything left after option parsing is unconsumed.
    if cli.cursor < cli.args.count {
        let remaining = Array(cli.args[cli.cursor..<cli.args.count])
        throw CLIError.bad("unknown args: \(remaining.joined(separator: " "))")
    }

    // Resolve final format: if -f/--format was NOT explicit, infer from the
    // -o path extension (agents all type `-o heart.svg` assuming it DTRT).
    // If it WAS explicit but -o's extension disagrees, warn but honor -f.
    // Stdout and unknown/missing extensions fall back to the default svg.
    let knownExt: [String: String] = ["svg": "svg", "pdf": "pdf", "png": "png"]
    // Distinguish: no path / stdout → nil; known ext → known; unknown non-empty
    // ext → .unknown(raw). An empty pathExtension is "ambiguous, default to svg"
    // (documented); a non-empty unknown one is probably a typo worth warning.
    enum OutExt { case none, known(String), unknown(String) }
    let outExt: OutExt = {
        guard outPath != "-" else { return .none }
        let raw = (outPath as NSString).pathExtension.lowercased()
        if raw.isEmpty { return .none }
        if let mapped = knownExt[raw] { return .known(mapped) }
        return .unknown(raw)
    }()
    let format: String
    if let explicit = explicitFormat {
        format = explicit
        if case .known(let oe) = outExt, oe != explicit.lowercased() {
            FileHandle.standardError.write(Data("warning: -f \(explicit.lowercased()) contradicts -o .\(oe) extension; writing \(explicit.lowercased())\n".utf8))
        }
    } else {
        switch outExt {
        case .known(let oe):
            format = oe
        case .unknown(let raw):
            FileHandle.standardError.write(Data("warning: unknown extension '.\(raw)' for -o; defaulting to svg\n".utf8))
            format = "svg"
        case .none:
            format = "svg"
        }
    }

    // Warn (but don't fail) when the user explicitly passed a flag that's a
    // no-op for the chosen mode. Silent drops surprise agents (the render
    // looks wrong but the CLI reported success); warnings let humans notice
    // immediately and agents grep stderr if they care.
    if userGaveColor && (mode == .palette || mode == .multicolor) {
        FileHandle.standardError.write(Data("warning: --color is ignored in \(mode.rawValue) mode\n".utf8))
    }
    if userGavePalette && (mode == .monochrome || mode == .hierarchical || mode == .multicolor) {
        FileHandle.standardError.write(Data("warning: --palette is ignored in \(mode.rawValue) mode\n".utf8))
    }

    let resolvedTint = tint.usingColorSpace(.sRGB) ?? tint
    var opts = RenderOptions(name: name, mode: mode, weight: weight, scale: scale,
                             pointSize: size, tint: resolvedTint, paletteColors: palette)
    opts.paletteColors = opts.paletteColors.map { $0.usingColorSpace(.sRGB) ?? $0 }

    let data: Data
    let resolvedFormat: String
    switch format.lowercased() {
    case "pdf": data = try Render.pdf(options: opts); resolvedFormat = "pdf"
    case "png": data = try Render.png(options: opts); resolvedFormat = "png"
    case "svg": data = try Render.svg(options: opts); resolvedFormat = "svg"
    default: throw CLIError.bad("unknown format: \(format) (use pdf, png, or svg)")
    }
    if outPath == "-" {
        FileHandle.standardOutput.write(data)
    } else {
        // Stat the path up front: writing to an existing directory surfaces as
        // NSFileWriteFileExistsError (516) with a verbose UserInfo blob that
        // leaks through if we let it hit the catch below. Detecting here
        // attacks the root cause instead of pattern-matching NSError text.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: outPath, isDirectory: &isDir), isDir.boolValue {
            throw CLIError.io("cannot write to \(outPath): path is a directory")
        }
        do {
            try data.write(to: URL(fileURLWithPath: outPath))
        } catch {
            // Collapse raw NSCocoaErrorDomain / NSError.description (which dumps
            // UserInfo) into a single human sentence. Map common POSIX codes to
            // plain English; otherwise fall back to the first-sentence
            // localizedDescription so we never leak the UserInfo blob.
            let ns = error as NSError
            let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? ns.code
            let detail: String
            switch posix {
            case 2 /* ENOENT */: detail = "parent directory does not exist"
            case 13 /* EACCES */: detail = "permission denied"
            case 21 /* EISDIR */: detail = "path is a directory"
            case 28 /* ENOSPC */: detail = "disk full"
            default: detail = ns.localizedDescription
            }
            throw CLIError.io("cannot write to \(outPath): \(detail)")
        }
    }
    if json {
        // Success envelope: agents can parse one line to confirm where bytes
        // went and how many there were. When stdout is the payload (-o -), we
        // route the envelope to stderr so stdout stays clean binary.
        let envelope: [String: Any] = [
            "name": name,
            "format": resolvedFormat,
            "path": outPath,
            "bytes": data.count
        ]
        if let j = try? JSONSerialization.data(
            withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes]
        ) {
            let sink = (outPath == "-") ? FileHandle.standardError : FileHandle.standardOutput
            sink.write(j)
            sink.write(Data("\n".utf8))
        }
    }
}

/// Tokenize a batch line: whitespace-separated args with support for '...' and "..." quoting.
/// Tracks whether a token was quoted so empty quoted tokens (e.g. `""` or `''`)
/// still emit as empty strings — otherwise `-o ""` would drop the value and the
/// next flag would be parsed as the output path.
func tokenizeLine(_ s: String) -> [String] {
    var out: [String] = []
    var cur = ""
    var quote: Character? = nil
    var wasQuoted = false
    for ch in s {
        if let q = quote {
            if ch == q { quote = nil } else { cur.append(ch) }
        } else if ch == "'" || ch == "\"" {
            quote = ch
            wasQuoted = true
        } else if ch == " " || ch == "\t" {
            if !cur.isEmpty || wasQuoted { out.append(cur); cur.removeAll(); wasQuoted = false }
        } else {
            cur.append(ch)
        }
    }
    if !cur.isEmpty || wasQuoted { out.append(cur) }
    return out
}

func runCLI() throws {
    var cli = CLI(args: CommandLine.arguments)
    guard let cmd = cli.next() else { print(usage); return }
    // Honor `<subcommand> --help` (and `-h`) as a synonym for the top-level
    // help. We don't maintain per-topic docs — a placeholder page would rot —
    // so this just stops `sfsym export --help` from being parsed as a symbol
    // name. The subcommands listed here are every real subcommand that takes
    // further argv; `help`/`version` aliases already DTRT.
    let helpCommands: Set<String> = [
        "export", "info", "modes", "list", "batch",
        "colors", "categories", "schema", "completions"
    ]
    if helpCommands.contains(cmd) {
        for a in cli.args.dropFirst(cli.cursor) where a == "--help" || a == "-h" {
            print(usage)
            return
        }
    }
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
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw CLIError.bad("symbol name is required")
        }
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
        let json = cli.flag("--json")
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: input, encoding: .utf8) else { return }
        var ok = 0, fail = 0
        let start = Date()
        // Single source of truth for the JSON summary line: emitted at end of
        // batch and also from the failFast early-exit branch so the JSONL
        // stream contract ("failures then summary") holds either way.
        func emitSummary(ok: Int, fail: Int, dt: TimeInterval) {
            let rate = Double(ok + fail) / max(dt, 0.001)
            let fixedJSON = String(
                format: "{\"code\":\"summary\",\"fail\":%d,\"ok\":%d,\"rate\":%.1f,\"seconds\":%.2f}",
                fail, ok, rate, dt
            )
            FileHandle.standardError.write(Data(fixedJSON.utf8))
            FileHandle.standardError.write(Data("\n".utf8))
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // Tokenize respecting single-quoted args (e.g. color hexes passed as '#ff00ff').
            var argv = tokenizeLine(trimmed)
            // Tolerate top-level syntax being pasted into a batch line: users
            // copy `sfsym export heart.fill ...` out of docs and drop it in.
            // Strip a leading `sfsym` and/or `export` so it parses the same as
            // the documented `<symbol> -f svg -o path.svg` form.
            if argv.first == "sfsym" { argv.removeFirst() }
            if argv.first == "export" { argv.removeFirst() }
            do {
                try runExportArgv(argv)
                ok += 1
            } catch {
                fail += 1
                // Normalize known errors to clean strings; Swift's default enum
                // CustomStringConvertible leaks e.g. `notFound("name")` into
                // stderr, which is ugly and not machine-parseable.
                let (msg, code): (String, String)
                switch error {
                case CLIError.bad(let m):         (msg, code) = (m, "bad_args")
                case CLIError.usage:
                    // runExportArgv throws CLIError.usage(usage) when argv has
                    // no symbol name (e.g. a bare `export` line after the
                    // leading-word strip). Dumping the 40-line help into a
                    // batch failure line breaks JSONL consumers, so collapse
                    // it to a one-liner here.
                    (msg, code) = ("missing symbol name", "bad_args")
                case CLIError.io(let m):          (msg, code) = (m, "io_error")
                case GlyphError.notFound(let n):  (msg, code) = ("symbol not found: \(n)", "not_found")
                case GlyphError.bad(let m):       (msg, code) = (m, "render_error")
                default:                          (msg, code) = (String(describing: error), "internal_error")
                }
                if json {
                    let obj: [String: Any] = ["line": trimmed, "code": code, "error": msg]
                    if let j = try? JSONSerialization.data(
                        withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]
                    ) {
                        FileHandle.standardError.write(j)
                        FileHandle.standardError.write(Data("\n".utf8))
                    }
                } else {
                    FileHandle.standardError.write(Data("batch fail: \(trimmed) — \(msg)\n".utf8))
                }
                if failFast {
                    // Preserve the JSONL stream contract on early exit: the
                    // summary line still has to follow the per-line failures.
                    if json {
                        emitSummary(ok: ok, fail: fail, dt: Date().timeIntervalSince(start))
                    }
                    exit(2)
                }
            }
        }
        let dt = Date().timeIntervalSince(start)
        let rate = Double(ok + fail) / max(dt, 0.001)
        if json {
            // Emit the summary as a JSON line too so callers can `2>&1 | jq`
            // the entire stream (failures + summary) without a text fallback.
            // JSONSerialization on Double dumps full precision (e.g.
            // 40.100000000000001 for 40.1), so we hand-assemble the line with
            // pre-formatted fixed-width numbers for seconds and rate.
            emitSummary(ok: ok, fail: fail, dt: dt)
        } else {
            FileHandle.standardError.write(Data(String(format: "batch: ok=%d fail=%d in %.2fs (%.1f/s)\n",
                                                        ok, fail, dt, rate).utf8))
        }
        // Non-zero exit if any line failed so agents can branch on $? without
        // having to regex the summary line.
        if fail > 0 { exit(2) }

    case "list":
        let json = cli.flag("--json")
        let prefix = cli.optValue("--prefix") ?? ""
        let contains = cli.optValue("--contains")
        // Treat all-whitespace / empty `--category` and `--search` the same as
        // the unset case (and as `--contains ''` already does) so empty-string
        // filter semantics are consistent: empty == no filter.
        let categoryRaw = cli.optValue("--category")
        let searchRaw = cli.optValue("--search")
        let category = categoryRaw?.trimmingCharacters(in: .whitespaces).isEmpty == true ? nil : categoryRaw
        let search = searchRaw?.trimmingCharacters(in: .whitespaces).isEmpty == true ? nil : searchRaw
        let limit: Int?
        if let s = cli.optValue("--limit") {
            guard let n = Int(s), n >= 0 else {
                throw CLIError.bad("invalid --limit: \(s) (must be a non-negative integer)")
            }
            limit = n
        } else {
            limit = nil
        }
        if (category != nil || search != nil) && !Metadata.available {
            throw CLIError.bad("--category / --search require SF Symbols.app to be installed at /Applications/SF Symbols.app (needed for metadata)")
        }
        // Normalize --category to lowercase so the CLI is symmetric with
        // -f/--format and --mode (both already accept any case). Plist keys
        // are lowercase; this is a defensive match on user input.
        let categoryNormalized: String?
        if let cat = category {
            let lc = cat.lowercased()
            guard Metadata.categories.contains(where: { $0.key.lowercased() == lc }) else {
                let known = Metadata.categories.map { $0.key }.joined(separator: ", ")
                throw CLIError.bad("unknown category: \(cat) (known: \(known))")
            }
            categoryNormalized = lc
        } else {
            categoryNormalized = nil
        }
        let catalog = try Catalog()
        var names = catalog.names(prefix: prefix, limit: nil)
        if let sub = contains, !sub.isEmpty {
            let needle = sub.lowercased()
            names = names.filter { $0.lowercased().contains(needle) }
        }
        if let cat = categoryNormalized { names = Metadata.filter(names: names, category: cat) }
        if let kw = search  { names = Metadata.filter(names: names, search: kw) }
        if let lim = limit { names = Array(names.prefix(lim)) }
        if json {
            try emitJSON(names)
        } else {
            for n in names { print(n) }
        }

    case "modes":
        let json = cli.flag("--json")
        guard let name = cli.next() else { throw CLIError.usage(usage) }
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw CLIError.bad("symbol name is required")
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        let glyph = try Glyph.load(name: name, configuration: cfg)
        let modes = supportedModes(for: glyph)
        if json {
            try emitJSON(modes)
        } else {
            print(modes.joined(separator: "\n"))
        }

    case "categories":
        // Apple's category taxonomy — one label per semantic bucket
        // (communication, weather, editing, …). Sourced from SF Symbols.app's
        // categories.plist; empty if the app isn't installed.
        let json = cli.flag("--json")
        let cats = Metadata.categories
        if json {
            let obj = cats.map { ["key": $0.key, "label": $0.label, "icon": $0.icon] }
            try emitJSON(obj)
        } else {
            if cats.isEmpty {
                FileHandle.standardError.write(Data("no categories: SF Symbols.app not installed\n".utf8))
                exit(1)
            }
            for c in cats { print("\(c.key.padding(toLength: 28, withPad: " ", startingAt: 0))\(c.label)") }
        }

    case "colors":
        // Enumerate every named color accepted by --color / --palette, with its
        // resolved sRGB hex. Saves agents a guessing round-trip.
        let json = cli.flag("--json")
        let entries = AppleSystemColor.allNames.map { name -> (String, String) in
            let ns = AppleSystemColor(rawValue: name)!.nsColor.usingColorSpace(.sRGB)!
            let hex = String(format: "#%02x%02x%02x",
                             Int((ns.redComponent * 255).rounded()),
                             Int((ns.greenComponent * 255).rounded()),
                             Int((ns.blueComponent * 255).rounded()))
            return (name, hex)
        }
        if json {
            let obj = entries.map { ["name": $0.0, "hex": $0.1] }
            try emitJSON(obj)
        } else {
            for (n, h) in entries { print("\(n.padding(toLength: 30, withPad: " ", startingAt: 0))\(h)") }
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
    // JSONSerialization's pretty printer renders an empty array as "[\n\n]"
    // (valid but ugly). Short-circuit to the literal "[]" so `list --limit 0`
    // and `list --prefix <no-matches>` emit a clean one-liner.
    if let arr = obj as? [Any], arr.isEmpty {
        FileHandle.standardOutput.write(Data("[]\n".utf8))
        return
    }
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
        ["code": 2, "meaning": "runtime error (bad args, render failure, file I/O 'io_error', batch had any failing line)"],
        ["code": 64, "meaning": "usage error"]
    ],
    "errorShape": [
        "description": "When any runtime error occurs while `--json` is present in argv, the error is emitted to stderr as a single-line JSON object. Usage errors (exit 64) remain plain text (multi-line help).",
        "fields": [
            "error": "string — human-readable message",
            "code":  "string — stable error class: 'not_found' | 'bad_args' | 'render_error' | 'io_error' | 'internal_error'"
        ]
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
                 "choices": ["pdf", "png", "svg"], "default": "svg",
                 "description": "Output format. SVG and PDF are vector for mono/hier/palette; PDF multicolor embeds raster; SVG multicolor is not supported. When unset, inferred from the -o file extension (.svg/.pdf/.png); stdout or missing extensions default to svg silently. If -o has a non-empty but unknown extension (e.g. .xyz), emits 'warning: unknown extension '.xyz' for -o; defaulting to svg' on stderr and proceeds with svg. If explicitly set and -o's known extension disagrees, emits 'warning: -f X contradicts -o .Y extension; writing X' on stderr and honors -f."],
                ["name": "--mode", "type": "enum",
                 "choices": ["monochrome", "hierarchical", "palette", "multicolor"],
                 "default": "monochrome"],
                ["name": "--weight", "type": "enum",
                 "choices": ["ultralight", "thin", "light", "regular", "medium",
                             "semibold", "bold", "heavy", "black"], "default": "regular"],
                ["name": "--scale", "type": "enum",
                 "choices": ["small", "medium", "large"], "default": "medium"],
                ["name": "--size", "type": "integer", "default": 32,
                 "description": "Point size. Integer, ≥ 1, ≤ 2048 (fractional values rejected). Produces a square canvas of size × size pts in every format, with the symbol fit-centered (uniform scale, preserving aspect). PNG renders at 2× pixel density (so max PNG is 4096×4096); SVG emits viewBox=\"0 0 size size\" with width/height=size; PDF uses a size × size mediaBox."],
                ["name": "--color", "type": "string", "default": "black",
                 "description": "Tint for monochrome / hierarchical. Hex (#rrggbb / #rrggbbaa) or Apple systemXxx name. Emits 'warning: --color is ignored in <mode> mode' on stderr if explicitly passed with --mode palette or --mode multicolor (render still proceeds)."],
                ["name": "--palette", "type": "string",
                 "default": "systemRed,systemGreen,systemBlue",
                 "description": "Comma-separated colors for palette mode, one per palette layer. If fewer colors are passed than the symbol has palette layers, colors cycle (colors[i % count]) and a 'warning: --palette has N color(s) but symbol has M palette layers; cycling' line is emitted on stderr. If more colors are passed than layers, the extras are dropped and 'warning: --palette has N colors but symbol has M palette layer(s); extras ignored' is emitted. Emits 'warning: --palette is ignored in <mode> mode' on stderr if explicitly passed with --mode monochrome/hierarchical/multicolor (render still proceeds)."],
                ["name": "-o", "long": "--out", "type": "path", "default": "-",
                 "description": "Output path. '-' writes to stdout."],
                ["name": "--json", "type": "bool", "default": false,
                 "description": "On success, emit a JSON envelope {name, format, path, bytes}. Goes to stdout normally; routed to stderr when -o - (so stdout stays the binary payload). Errors already emit JSON on stderr when --json is set."]
            ],
            "jsonShape": [
                "name": "string — the symbol name",
                "format": "string — 'pdf' | 'png' | 'svg'",
                "path": "string — the resolved output path ('-' for stdout)",
                "bytes": "number — payload byte count"
            ],
            "examples": [
                "sfsym export heart.fill -f svg --color '#ff3b30' -o heart.svg",
                "sfsym export cloud.sun.rain.fill -f svg --mode palette --palette '#ff3b30,#ffcc00,#4477ff' -o weather.svg",
                "sfsym export heart.fill -f svg --json -o heart.svg"
            ]
        ],
        [
            "name": "batch",
            "summary": "Read one export invocation per line from stdin. Amortizes Swift/AppKit startup across many renders (~30× faster than one-exec-per-render for bulk work).",
            "flags": [
                ["name": "--fail-fast", "type": "bool", "default": false,
                 "description": "Exit on first failing line instead of skipping."],
                ["name": "--json", "type": "bool", "default": false,
                 "description": "Emit one JSON object per failure on stderr {line, code, error} instead of the plain 'batch fail:' prose, plus a final JSON summary line {code:'summary', ok, fail, seconds, rate} so the whole stream is jq-parseable."]
            ],
            "jsonShape": [
                "failure": [
                    "line": "string — the original stdin line that failed",
                    "code": "string — 'not_found' | 'bad_args' | 'render_error' | 'io_error' | 'internal_error'",
                    "error": "string — human-readable message"
                ],
                "summary": [
                    "code": "string — always 'summary'",
                    "ok": "number — lines that succeeded",
                    "fail": "number — lines that failed",
                    "seconds": "number — elapsed wall time",
                    "rate": "number — (ok+fail)/seconds"
                ]
            ],
            "stdin": "One export command per line: <symbol> [flags...] -o <path>. A leading 'export' or 'sfsym export' is tolerated (stripped), so lines copied from top-level docs also work. Blank lines and '#' comments are ignored.",
            "stderr": "Per-failure lines ('batch fail: <line> — <error>', or a JSON line with --json) plus a final summary line: plain 'batch: ok=N fail=N in Ns (rate/s)', or a JSON object {code:'summary', ok, fail, seconds, rate} when --json is set. The JSON summary line is always emitted when --json is set — including on --fail-fast early exit — so the JSONL stream always ends with a parseable summary.",
            "exitBehavior": "Exit 2 if any line failed (0 only when every line succeeded). With --fail-fast, exits 2 on the first failure (after emitting the summary line when --json is set).",
            "examples": [
                "printf 'heart.fill -f svg -o h.svg\\nstar.fill -f svg -o s.svg\\n' | sfsym batch",
                "printf 'nope -o n.svg\\n' | sfsym batch --json"
            ]
        ],
        [
            "name": "list",
            "summary": "Enumerate all SF Symbol names (8303+ as of macOS 26). Reads directly from the OS's Assets.car so the list is always current.",
            "flags": [
                ["name": "--prefix", "type": "string", "default": "",
                 "description": "Only include names starting with this prefix."],
                ["name": "--contains", "type": "string",
                 "description": "Case-insensitive substring filter on the symbol name."],
                ["name": "--category", "type": "string",
                 "description": "Filter by Apple's category key (see `sfsym categories`). Case-insensitive. Empty string means no filter (same as --prefix/--contains). Requires SF Symbols.app."],
                ["name": "--search", "type": "string",
                 "description": "Filter by Apple's semantic search keywords (e.g. 'search' matches magnifyingglass). Empty string means no filter. Requires SF Symbols.app."],
                ["name": "--limit", "type": "number",
                 "description": "Cap to N names (non-negative). Omit for no cap."],
                ["name": "--json", "type": "bool", "default": false,
                 "description": "Emit JSON array of strings instead of newline-separated."]
            ],
            "jsonShape": "array of string (symbol names, sorted ASCII)",
            "examples": [
                "sfsym list | wc -l",
                "sfsym list --prefix cloud --json",
                "sfsym list --contains checkmark"
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
            "jsonShape": "array of string from {monochrome, hierarchical, palette, multicolor}",
            "examples": ["sfsym modes cloud.sun.rain.fill --json"]
        ],
        [
            "name": "colors",
            "summary": "Enumerate every named color accepted by --color / --palette (systemRed, label, etc.), with its resolved sRGB hex.",
            "flags": [["name": "--json", "type": "bool", "default": false]],
            "jsonShape": "array of {name: string, hex: string}",
            "examples": ["sfsym colors --json"]
        ],
        [
            "name": "categories",
            "summary": "List Apple's symbol category taxonomy (communication, weather, …). Sourced from SF Symbols.app's metadata; empty with exit 1 if the app isn't installed.",
            "flags": [["name": "--json", "type": "bool", "default": false]],
            "jsonShape": "array of {key: string, label: string, icon: string}",
            "examples": ["sfsym categories", "sfsym list --category communication"]
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
