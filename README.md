# sfsym

![demo](./demo.svg)

[![Homebrew](https://img.shields.io/badge/homebrew-yapstudios%2Ftap-orange)](https://github.com/yapstudios/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)

Export Apple SF Symbols as vector SVG, vector PDF, or PNG -- from the terminal. No Xcode project, no SF Symbols.app at runtime, no redrawing: paths come from Apple's own rendering pipeline.

```sh
sfsym export heart.fill -f svg -o heart.svg
# 620B -> heart.svg
```

## Install

### Homebrew

```sh
brew install yapstudios/tap/sfsym
```

### From source

```sh
git clone https://github.com/yapstudios/sfsym.git
cd sfsym
Scripts/install.sh
```

Builds a release binary and installs it to `~/.local/bin/sfsym`.

### Manual

```sh
swift build -c release
cp -f .build/release/sfsym ~/.local/bin/sfsym
```

### Requirements

- macOS 13+ (Ventura or later)
- Xcode Command Line Tools (`xcode-select --install`)
- Apple Silicon or Intel

## Quick start

```sh
# Any symbol, as vector SVG, to stdout
sfsym export heart.fill -f svg -o -

# Colored and sized
sfsym export star.fill -f svg --color '#FFD60A' --size 48

# Multi-layer symbols in palette mode
sfsym export cloud.sun.rain.fill -f svg \
  --mode palette --palette '#4477ff,#ffcc00,#ff3b30'

# Vector PDF
sfsym export heart.fill -f pdf --mode hierarchical --color '#007AFF'

# Pixel-perfect PNG at any point size (rendered @2x)
sfsym export cloud.sun.rain.fill -f png --mode multicolor --size 128
```

## Commands

### `export`

Render a single symbol. Default format is PDF; use `-f svg` or `-f png` to switch.

```sh
sfsym export <name>  [-f pdf|png|svg]
                     [--mode monochrome|hierarchical|palette|multicolor]
                     [--weight ultralight|thin|light|regular|medium|semibold|bold|heavy|black]
                     [--scale small|medium|large]
                     [--size <pt>]
                     [--color <hex|systemName>]
                     [--palette <hex,hex,...>]
                     [-o <path>|-]
```

Colors accept `#RRGGBB`, `#RRGGBBAA`, or the Apple system palette (`systemRed`, `systemBlue`, `label`, `systemGray2`, and so on).

### `batch`

Read one export invocation per line from stdin. Pays Swift + AppKit startup once; renders at ~800 per second.

```sh
printf 'heart.fill -f svg -o heart.svg\n\
star.fill  -f svg -o star.svg\n' | sfsym batch
# batch: ok=2 fail=0 in 0.01s (284/s)
```

Turning the whole library into SVG:

```sh
sfsym list | awk '{print $1 " -f svg -o out/"$1".svg"}' | sfsym batch
# batch: ok=8302 fail=1 in 10.1s (822/s)
```

### `list`

Every SF Symbol name that the OS knows about (8,300+). Reads directly from the installed Assets.car so the list stays current with OS updates -- no version table baked into the binary.

```sh
sfsym list                              # all names, newline-separated
sfsym list --prefix cloud               # filter by prefix
sfsym list --limit 20                   # cap count
sfsym list --json                       # JSON array
```

### `info`

Geometry and layer metadata for a single symbol.

```sh
sfsym info heart.fill --json
```

```json
{
  "name": "heart.fill",
  "size": { "width": 40, "height": 33 },
  "alignmentRect": { "x": 4, "y": 2, "width": 31.5, "height": 29 },
  "templateLayers": 1,
  "hierarchyLayers": 1,
  "paletteLayers": 1,
  "hierarchyLevels": [0],
  "modes": ["monochrome", "hierarchical", "palette"]
}
```

### `modes`

Which rendering modes are available for a given symbol.

```sh
sfsym modes cloud.sun.rain.fill --json
# ["monochrome","hierarchical","palette","multicolor"]
```

### `schema`

Full machine-readable description of the CLI (every subcommand, flag, enum, default, and a handful of examples) as JSON. Useful for LLMs and automation.

```sh
sfsym schema | jq '.commands[] | .name'
```

## Rendering modes

| Mode | Output | Behavior |
|------|--------|----------|
| `monochrome` | vector | Every layer fills with the `--color` tint |
| `hierarchical` | vector | Primary / secondary / tertiary tiers at Apple's canonical `1.0 / 0.68 / 0.32` opacity ladder of `--color` |
| `palette` | vector | One `--palette` color per layer, in Apple's layer order |
| `multicolor` | raster embedded in PDF; PNG only for `-f png` | Apple's baked-in per-layer tints |

The modes table is format-sensitive:

| Format | monochrome | hierarchical | palette | multicolor |
|--------|:----------:|:------------:|:-------:|:----------:|
| **SVG** | vector | vector | vector | -- |
| **PDF** | vector | vector | vector | raster in PDF |
| **PNG** | raster | raster | raster | raster |

SVG multicolor is not supported: the private vector path inside CoreUI crashes when the color-resolver block is invoked out of SF Symbols.app's process. Use `-f png` for multicolor and stick to `palette` mode if you need vector.

## Shell completions

sfsym ships completion scripts for bash, zsh, and fish. Symbol-name completion is dynamic -- it shells out to `sfsym list` on tab-press -- so new symbols shipped by macOS updates are available immediately, no regeneration required.

```sh
# Zsh
sfsym completions zsh > ~/.zsh/completions/_sfsym
# then in ~/.zshrc:
fpath=(~/.zsh/completions $fpath)
autoload -U compinit && compinit

# Bash
sfsym completions bash > /usr/local/etc/bash_completion.d/sfsym
# or source inline:
source <(sfsym completions bash)

# Fish
sfsym completions fish > ~/.config/fish/completions/sfsym.fish
```

## How it works

![architecture](./architecture.svg)

### Rendering pipeline

1. `NSImage(systemSymbolName:)` with an `NSImage.SymbolConfiguration` produces an `NSSymbolImageRep`.
2. The rep's private `_vectorGlyph` ivar is a `CUINamedVectorGlyph` -- Apple's runtime symbol object, with per-layer CGPath access and a handful of draw entry points.
3. For vector output, `sfsym` draws the glyph into a `CGPDFContext`. The resulting PDF content stream is pure path ops (`m`, `l`, `c`, `re`, `f`), with zero embedded images.
4. For SVG, a small PDF interpreter walks those ops, rewrites them as SVG `d=` commands, flips the Y axis, and tags each path with its Apple layer index (`data-layer="hierarchical-0"`, `palette-3`, etc.) so downstream tools can retheme without touching geometry.
5. For PNG, `NSBitmapImageRep` is driven at 2x pixel density under `NSAppearance.darkAqua` so multicolor system tints resolve predictably.

### Symbol enumeration

`sfsym list` walks the BOM tree inside the OS's `CoreGlyphs.bundle/Contents/Resources/Assets.car` and extracts every FACETKEYS entry with an identifier attribute. Same file AppKit reads from, so the two views never disagree.

## Output conventions

- **SVG:** self-contained, no external CSS, one `<svg>` root with a single `<g transform="matrix(1 0 0 -1 0 H)">` wrapper for the Y flip. Each `<path>` carries `fill` (sRGB hex), `data-layer` (Apple's layer name), and `fill-opacity` (for hierarchical tiers). Exact same paths Apple's renderer emits into PDF; indistinguishable rendered output.
- **PDF:** one-page, media box equal to the symbol's alignment rect. Vector for mono / hierarchical / palette. Multicolor embeds a raster.
- **PNG:** 2x pixel density; resolution = `size * 2`. Always under `darkAqua` so dynamic colors render.

## Comparison

| | sfsym | SF Symbols.app "Copy as SVG" | `Image(systemName:)` | Manual export |
|---|:---:|:---:|:---:|:---:|
| Works from CLI | Yes | No | No | Varies |
| Scriptable | Yes | No | No | No |
| Covers all 8,300+ symbols | Yes | Yes | Yes | Yes |
| Vector SVG | Yes | Yes | n/a | Yes |
| Per-mode output | Yes | No (mono template) | No | No |
| Per-layer data attributes | Yes | No | No | No |
| Stays current with OS updates | Yes (reads installed bundle) | Yes | Yes | No |
| AI agent compatible | Yes (`schema`, `--json`, stable exit codes) | No | No | No |

## Project structure

```
sfsym/
├── Sources/sfsym/
│   ├── main.swift                   # entry point + error → exit-code mapping
│   ├── CLI.swift                    # arg parsing, usage text, schema
│   ├── Render.swift                 # PDF / PNG / SVG orchestration
│   ├── Glyph.swift                  # CUINamedVectorGlyph KVC wrapper
│   ├── PdfToSvg.swift               # PDF content-stream interpreter + SVG emitter
│   ├── AssetsCar.swift              # BOMStore reader for FACETKEYS
│   └── Catalog.swift                # name enumeration for `sfsym list`
├── Sources/harness/
│   └── main.swift                   # diff harness (48 symbols × modes × formats)
├── Scripts/
│   └── install.sh                   # build + copy to ~/.local/bin
├── web/
│   ├── build-all.sh                 # generate 24,906 SVGs + index page
│   ├── build-all.py                 # static HTML generator
│   └── build.sh                     # featured-subset preview (faster rebuild)
├── Package.swift
└── demo.svg                         # header animation
```

## License

MIT. See [LICENSE](./LICENSE).

Output generated by `sfsym` contains symbols that are property of Apple Inc. Use of SF Symbols is governed by the [SF Symbols License](https://developer.apple.com/support/terms/); symbols may be used only in artwork and mockups for apps developed for Apple platforms.

This project is not affiliated with Apple Inc. SF Symbols and related marks are trademarks of Apple Inc.
