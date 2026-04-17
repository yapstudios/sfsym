#!/bin/zsh
# Generate monochrome + hierarchical + palette SVGs for every symbol, then
# build an HTML page with all 8303 tiles, search, and category filter.
set -euo pipefail
cd "${0:A:h}/.."
setopt NULL_GLOB

BIN=.build/release/sfsym
[[ -x "$BIN" ]] || swift build -c release >/dev/null

OUT=web/all
SVG=$OUT/svg
mkdir -p "$SVG"

# Nuke old output so renames/removals flush.
rm -f "$SVG"/*.svg 2>/dev/null || true

# Build the batch script: 3 modes per symbol.
TINT='#0a84ff'
PALETTE='#ff3b30,#ffcc00,#4477ff,#34c759,#af52de,#ff9500,#ff2d55,#5ac8fa,#30d158'

tmp=$(mktemp)
trap "rm -f $tmp" EXIT

echo "enumerating symbols..."
$BIN list > "$tmp.names"
count=$(/usr/bin/wc -l < "$tmp.names" | /usr/bin/tr -d ' ')
echo "  $count symbols"

echo "building batch script..."
/usr/bin/python3 -c "
out = open('$tmp', 'w')
for name in open('$tmp.names').read().split():
    out.write(f'{name} -f svg --mode monochrome --color $TINT --size 32 -o $SVG/{name}__m.svg\\n')
    out.write(f'{name} -f svg --mode hierarchical --color $TINT --size 32 -o $SVG/{name}__h.svg\\n')
    out.write(f'{name} -f svg --mode palette --palette $PALETTE --size 32 -o $SVG/{name}__p.svg\\n')
"
lines=$(/usr/bin/wc -l < "$tmp" | /usr/bin/tr -d ' ')
echo "  $lines renders queued"

echo "rendering..."
"$BIN" batch < "$tmp"

echo "building HTML..."
/usr/bin/python3 web/build-all.py

echo "done. open web/all.html"
