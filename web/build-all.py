#!/usr/bin/env python3
"""Build a single static page listing every SF Symbol with live SVGs.

Reads the symbol list from the sfsym CLI (authoritative), and optional category
metadata from SF Symbols.app's plists when available. Emits web/all.html with
embedded data so the page is self-contained except for the svg/ sibling dir.
"""
from pathlib import Path
import plistlib
import subprocess
import json
import re

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "all.html"
SVG_DIR = ROOT / "all" / "svg"
BIN = ROOT.parent / ".build" / "release" / "sfsym"

# Authoritative list of available symbols.
names = subprocess.check_output([str(BIN), "list"], text=True).strip().splitlines()

# Optional: category labels + symbol → categories map. Present if SF Symbols.app
# is installed; graceful fallback if not.
APP = Path("/Applications/SF Symbols.app/Contents/Resources/Metadata")
categories: list[dict] = []
symbol_cats: dict[str, list[str]] = {}
if (APP / "categories.plist").exists():
    with (APP / "categories.plist").open("rb") as f:
        for entry in plistlib.load(f):
            key = entry.get("key"); label = entry.get("label"); icon = entry.get("icon")
            if key and label:
                categories.append({"key": key, "label": label, "icon": icon or ""})
if (APP / "symbol_categories.plist").exists():
    with (APP / "symbol_categories.plist").open("rb") as f:
        symbol_cats = plistlib.load(f)

# Only tiles that exist on disk go in the grid — skips underscore-prefixed
# internal facets AppKit doesn't resolve.
valid_names = [n for n in names if (SVG_DIR / f"{n}__m.svg").exists()]
skipped = len(names) - len(valid_names)
print(f"{len(valid_names)} tiles ({skipped} skipped — no SVG produced)")

# Each tile carries its category list as a space-separated class-ready string.
# JS uses a Set lookup for O(1) filter.
tiles_data = [
    {"n": n, "c": symbol_cats.get(n, [])}
    for n in valid_names
]

css = r"""
:root {
  color-scheme: dark;
  --bg: #0b0b0c;
  --panel: #141416;
  --line: #1f1f22;
  --text: #eaeaee;
  --muted: #6b6b72;
  --accent: #0a84ff;
  --tile-size: 72px;
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: var(--bg); color: var(--text); }
body {
  font: 13px/1.5 -apple-system, "SF Pro Text", "Helvetica Neue", system-ui, sans-serif;
  letter-spacing: 0.01em;
  min-height: 100vh;
}
header {
  position: sticky; top: 0; z-index: 10;
  background: rgba(11, 11, 12, 0.85);
  backdrop-filter: saturate(180%) blur(20px);
  -webkit-backdrop-filter: saturate(180%) blur(20px);
  border-bottom: 1px solid var(--line);
  padding: 20px 28px 18px;
}
.title-row {
  display: flex; align-items: baseline; gap: 18px;
  margin-bottom: 12px;
}
h1 { font-size: 19px; font-weight: 500; letter-spacing: -0.01em; margin: 0; }
.count { color: var(--muted); font-variant-numeric: tabular-nums; font-size: 12px; }
.filters {
  display: flex; gap: 12px; align-items: center; flex-wrap: wrap;
}
input[type="search"] {
  flex: 0 1 320px;
  padding: 8px 12px;
  font: 13px -apple-system, system-ui, sans-serif;
  color: var(--text);
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 7px;
  outline: none;
}
input[type="search"]:focus { border-color: var(--accent); }
.cat-pills {
  display: flex; gap: 6px; flex-wrap: wrap;
  flex: 1;
}
.pill {
  padding: 5px 10px;
  font: 11px "SF Mono", ui-monospace, monospace;
  text-transform: lowercase;
  letter-spacing: 0.02em;
  color: var(--muted);
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 5px;
  cursor: pointer;
  user-select: none;
  transition: all 0.1s;
}
.pill:hover { color: var(--text); border-color: var(--muted); }
.pill.active { color: var(--bg); background: var(--accent); border-color: var(--accent); }

main { padding: 20px 28px 64px; }
/* Virtualized grid: .grid has explicit height for the scrollbar; tiles are
   absolutely positioned and only mounted when they're near the viewport.
   Keeps the DOM at ~few-hundred elements even for 8k+ symbols. */
.grid {
  position: relative;
  width: 100%;
}
.tile {
  position: absolute;
  display: flex; align-items: center; justify-content: center;
  background: transparent;
  border: 1px solid transparent;
  border-radius: 6px;
  cursor: pointer;
  color: var(--accent);
  box-sizing: border-box;
}
.tile:hover {
  background: var(--panel);
  border-color: var(--line);
}
.tile img {
  width: 28px; height: 28px;
  object-fit: contain;
  pointer-events: none;
}
.tile .name {
  position: absolute;
  bottom: 2px; left: 0; right: 0;
  font: 9px "SF Mono", ui-monospace, monospace;
  color: var(--muted);
  text-align: center;
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  padding: 0 4px;
  opacity: 0;
  transition: opacity 0.1s;
}
.tile:hover .name { opacity: 1; }

/* Detail dialog */
dialog {
  padding: 0;
  background: var(--panel);
  color: var(--text);
  border: 1px solid var(--line);
  border-radius: 10px;
  max-width: 720px;
  width: calc(100% - 48px);
}
dialog::backdrop { background: rgba(0,0,0,0.6); backdrop-filter: blur(8px); }
.dialog-body { padding: 28px 32px 24px; }
.dialog-body h2 {
  margin: 0 0 4px; font: 500 18px -apple-system, system-ui;
}
.dialog-body .sub {
  margin: 0 0 24px; color: var(--muted); font-size: 12px;
  font-family: "SF Mono", ui-monospace, monospace;
}
.modes-row {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 18px;
  margin-bottom: 20px;
}
.mode-cell {
  background: var(--bg);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 24px 12px 12px;
  text-align: center;
}
.mode-cell img {
  width: 96px; height: 96px; object-fit: contain;
  color: var(--accent);
  display: block; margin: 0 auto 10px;
}
.mode-cell .label {
  font: 10px "SF Mono", ui-monospace, monospace;
  color: var(--muted);
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
.actions {
  display: flex; gap: 8px; align-items: center; margin-top: 4px;
}
button {
  padding: 7px 12px;
  font: 12px "SF Mono", ui-monospace, monospace;
  color: var(--text);
  background: var(--bg);
  border: 1px solid var(--line);
  border-radius: 6px;
  cursor: pointer;
}
button:hover { border-color: var(--muted); }
button.primary { background: var(--accent); border-color: var(--accent); color: var(--bg); }
.dialog-close {
  position: absolute; top: 12px; right: 12px;
  width: 26px; height: 26px; padding: 0;
  display: flex; align-items: center; justify-content: center;
}
.empty {
  padding: 60px 20px;
  text-align: center;
  color: var(--muted);
}
""".strip()

data_json = json.dumps({
    "tiles": tiles_data,
    "categories": categories,
}, separators=(",", ":"))

html = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>sfsym — every SF Symbol as SVG</title>
<style>""" + css + r"""</style>
</head>
<body>
<header>
  <div class="title-row">
    <h1>sfsym</h1>
    <span class="count" id="count">0</span>
  </div>
  <div class="filters">
    <input type="search" id="search" placeholder="search by name (e.g. heart, cloud.rain)" autofocus>
    <div class="cat-pills" id="cats"></div>
  </div>
</header>
<main>
  <div class="grid" id="grid"></div>
  <div class="empty" id="empty" hidden>No symbols match.</div>
</main>
<dialog id="detail">
  <div class="dialog-body">
    <button class="dialog-close" onclick="document.getElementById('detail').close()" aria-label="close">✕</button>
    <h2 id="d-name"></h2>
    <p class="sub" id="d-cats"></p>
    <div class="modes-row">
      <div class="mode-cell"><img id="d-m" loading="eager"><div class="label">monochrome</div></div>
      <div class="mode-cell"><img id="d-h" loading="eager"><div class="label">hierarchical</div></div>
      <div class="mode-cell"><img id="d-p" loading="eager"><div class="label">palette</div></div>
    </div>
    <div class="actions">
      <button class="primary" id="d-copy-name">copy name</button>
      <button id="d-copy-svg">copy monochrome SVG</button>
      <button id="d-download">download SVG</button>
    </div>
  </div>
</dialog>
<script>
const DATA = """ + data_json + r""";
const grid = document.getElementById('grid');
const empty = document.getElementById('empty');
const search = document.getElementById('search');
const cats = document.getElementById('cats');
const count = document.getElementById('count');

const dlg = document.getElementById('detail');
const dName = document.getElementById('d-name');
const dCats = document.getElementById('d-cats');
const dM = document.getElementById('d-m');
const dH = document.getElementById('d-h');
const dP = document.getElementById('d-p');

// --- virtualized grid ---------------------------------------------------
// Even with loading=lazy, 8k+ <img> elements stall the page on file:// in
// most browsers. Only mount tiles in (or near) the viewport; throw them
// away as they scroll off. DOM size stays ~200-400 regardless of dataset.
const TILE = 72;          // tile edge, px
const BUFFER_ROWS = 6;    // extra rows above + below viewport
let cols = 1;
let visible = DATA.tiles; // current filtered dataset
const mounted = new Map(); // flat-index → element

function makeTile(t) {
  const el = document.createElement('div');
  el.className = 'tile';
  el.style.width = TILE + 'px';
  el.style.height = TILE + 'px';
  el.addEventListener('click', () => openDetail(t));
  // Cap inner SVG size so all tiles read the same visual weight.
  el.innerHTML = `<img src="all/svg/${t.n}__m.svg" alt="${t.n}" loading="lazy" decoding="async"><span class="name">${t.n}</span>`;
  return el;
}

function layout() {
  const available = grid.clientWidth || window.innerWidth - 56;
  const newCols = Math.max(1, Math.floor(available / TILE));
  if (newCols !== cols) {
    cols = newCols;
    // Force remount — positions depend on cols.
    for (const [, el] of mounted) el.remove();
    mounted.clear();
  }
  const rows = Math.ceil(visible.length / cols);
  grid.style.height = (rows * TILE) + 'px';
  render();
}

function render() {
  const scrollTop = Math.max(0, window.scrollY - grid.offsetTop);
  const vh = window.innerHeight;
  const startRow = Math.max(0, Math.floor(scrollTop / TILE) - BUFFER_ROWS);
  const endRow = Math.ceil((scrollTop + vh) / TILE) + BUFFER_ROWS;
  const startIdx = startRow * cols;
  const endIdx = Math.min(visible.length, endRow * cols);

  // Unmount anything outside the window.
  for (const [idx, el] of mounted) {
    if (idx < startIdx || idx >= endIdx) { el.remove(); mounted.delete(idx); }
  }
  // Mount newcomers.
  for (let i = startIdx; i < endIdx; i++) {
    if (mounted.has(i)) continue;
    const t = visible[i];
    const el = makeTile(t);
    const r = Math.floor(i / cols), c = i % cols;
    el.style.top = (r * TILE) + 'px';
    el.style.left = `calc((100% / ${cols}) * ${c})`;
    el.style.width = `calc(100% / ${cols})`;
    grid.appendChild(el);
    mounted.set(i, el);
  }
  empty.hidden = visible.length > 0;
}

// Category pills.
const allPill = document.createElement('span');
allPill.className = 'pill active'; allPill.textContent = 'all'; allPill.dataset.key = '';
cats.appendChild(allPill);
for (const c of DATA.categories) {
  if (c.key === 'all') continue;
  const p = document.createElement('span');
  p.className = 'pill';
  p.textContent = c.label.toLowerCase();
  p.dataset.key = c.key;
  cats.appendChild(p);
}

let activeCat = '';
let query = '';

function applyFilter() {
  const q = query.toLowerCase();
  visible = DATA.tiles.filter(t =>
    (!q || t.n.toLowerCase().includes(q)) &&
    (!activeCat || t.c.includes(activeCat)));
  // Full remount on filter change — positions depend on the filtered list.
  for (const [, el] of mounted) el.remove();
  mounted.clear();
  window.scrollTo(0, 0);
  count.textContent = `${visible.length.toLocaleString()} of ${DATA.tiles.length.toLocaleString()} symbols`;
  layout();
}

cats.addEventListener('click', (e) => {
  if (!e.target.classList.contains('pill')) return;
  for (const p of cats.children) p.classList.remove('active');
  e.target.classList.add('active');
  activeCat = e.target.dataset.key;
  applyFilter();
});

// Input debounce — filter is cheap (~2ms for 8k items) but avoids double work on fast typing.
let searchTimer = null;
search.addEventListener('input', (e) => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => { query = e.target.value; applyFilter(); }, 40);
});

// Initial layout + wire up scroll/resize. rAF throttles scroll handler.
let ticking = false;
window.addEventListener('scroll', () => {
  if (ticking) return;
  ticking = true;
  requestAnimationFrame(() => { render(); ticking = false; });
}, { passive: true });
window.addEventListener('resize', () => { layout(); });
count.textContent = `${DATA.tiles.length.toLocaleString()} symbols`;
layout();

function openDetail(t) {
  dName.textContent = t.n;
  dCats.textContent = t.c.length ? t.c.join(' · ') : '—';
  dM.src = `all/svg/${t.n}__m.svg`;
  dH.src = `all/svg/${t.n}__h.svg`;
  dP.src = `all/svg/${t.n}__p.svg`;
  dlg.showModal();
}

document.getElementById('d-copy-name').addEventListener('click', () => {
  navigator.clipboard.writeText(dName.textContent);
});
document.getElementById('d-copy-svg').addEventListener('click', async () => {
  const res = await fetch(dM.src);
  const txt = await res.text();
  navigator.clipboard.writeText(txt);
});
document.getElementById('d-download').addEventListener('click', () => {
  const a = document.createElement('a');
  a.href = dM.src;
  a.download = `${dName.textContent}.svg`;
  a.click();
});

// Keyboard: esc closes dialog, / focuses search
document.addEventListener('keydown', (e) => {
  if (e.key === '/' && document.activeElement !== search) {
    e.preventDefault(); search.focus();
  }
});
</script>
</body>
</html>
"""

OUT.write_text(html)
print(f"wrote {OUT} ({OUT.stat().st_size // 1024} KB)")
