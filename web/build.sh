#!/bin/zsh
# Generates SVGs for a diverse set of symbols × 3 modes, then builds
# web/index.html with them inlined as a 20×20 grid.
set -euo pipefail
cd "${0:A:h}/.."

BIN=.build/release/sfsym
if [[ ! -x "$BIN" ]]; then
  swift build -c release >/dev/null
fi

SYMBOLS=(
  # single-layer shapes
  heart.fill star.fill circle.fill square.fill triangle.fill
  xmark checkmark plus minus questionmark
  # arrows
  arrow.up arrow.down arrow.left arrow.right arrow.clockwise
  chevron.right chevron.down
  # UI / system
  house.fill bell.fill gear magnifyingglass trash
  envelope.fill lock.fill person.fill photo folder.fill
  # connectivity / media
  wifi battery.100 speaker.wave.3.fill mic.fill video.fill
  # multi-layer weather
  cloud.sun.rain.fill cloud.bolt.rain.fill cloud.fog.fill
  moon.stars.fill sparkles sun.max.fill
  # emotive / people
  hand.thumbsup.fill hand.wave.fill message.fill bubble.left.fill person.2.fill
  # commerce
  creditcard.fill cart.fill bag.fill
  # other fun
  flame.fill bolt.fill drop.fill leaf.fill snowflake
  camera.fill clock.fill pawprint.fill globe lightbulb.fill
)

MODES=(monochrome hierarchical palette)
PALETTE='#ff3b30,#ffcc00,#4477ff,#34c759,#af52de,#ff9500,#ff2d55,#5ac8fa,#30d158'
TINT='#0a84ff'

setopt NULL_GLOB
rm -f web/svg/*.svg 2>/dev/null || true

# Build the batch script: one line per render. Pay Swift/AppKit startup once.
batch_input=""
for sym in "${SYMBOLS[@]}"; do
  for mode in "${MODES[@]}"; do
    out="web/svg/${sym}__${mode}.svg"
    case "$mode" in
      monochrome)   batch_input+="$sym -f svg --mode monochrome --color $TINT --size 32 -o $out"$'\n' ;;
      hierarchical) batch_input+="$sym -f svg --mode hierarchical --color $TINT --size 32 -o $out"$'\n' ;;
      palette)      batch_input+="$sym -f svg --mode palette --palette $PALETTE --size 32 -o $out"$'\n' ;;
    esac
  done
done
print -n "$batch_input" | $BIN batch

echo "generated $(ls -1 web/svg/ | wc -l | tr -d ' ') SVGs"
