#!/usr/bin/env python3
"""Build web/index.html with every generated SVG inlined at 20x20."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
SVG_DIR = ROOT / "svg"

# Keep display order stable; fall back to alpha.
ORDER_HINT = [
    # single-layer shapes
    "heart.fill","star.fill","circle.fill","square.fill","triangle.fill",
    "xmark","checkmark","plus","minus","questionmark",
    # arrows
    "arrow.up","arrow.down","arrow.left","arrow.right","arrow.clockwise",
    "chevron.right","chevron.down",
    # UI / system
    "house.fill","bell.fill","gear","magnifyingglass","trash",
    "envelope.fill","lock.fill","person.fill","photo","folder.fill",
    # connectivity / media
    "wifi","battery.100","speaker.wave.3.fill","mic.fill","video.fill",
    # weather
    "cloud.sun.rain.fill","cloud.bolt.rain.fill","cloud.fog.fill",
    "moon.stars.fill","sparkles","sun.max.fill",
    # emotive / people
    "hand.thumbsup.fill","hand.wave.fill","message.fill","bubble.left.fill","person.2.fill",
    # commerce
    "creditcard.fill","cart.fill","bag.fill",
    # other
    "flame.fill","bolt.fill","drop.fill","leaf.fill","snowflake",
    "camera.fill","clock.fill","pawprint.fill","globe","lightbulb.fill",
]
MODES = ("monochrome", "hierarchical", "palette")

def inline(path: Path) -> str:
    """Strip the <?xml prolog and make the root <svg> shrink-wrap to its viewBox.
    We drop width/height and add width=20 height=20 via CSS so every symbol lands
    at the same physical size regardless of its native alignment rect."""
    s = path.read_text()
    s = re.sub(r"<\?xml[^?]*\?>\s*", "", s)
    s = re.sub(r'\s(width|height)="[^"]*"', "", s, count=2)
    return s.strip()

rows: list[tuple[str, dict]] = []
names_present = {p.stem.split("__")[0] for p in SVG_DIR.glob("*.svg")}
ordered = [n for n in ORDER_HINT if n in names_present]
ordered += sorted(n for n in names_present if n not in ORDER_HINT)

for name in ordered:
    svgs = {}
    for mode in MODES:
        p = SVG_DIR / f"{name}__{mode}.svg"
        if p.exists():
            svgs[mode] = inline(p)
    rows.append((name, svgs))

# ---- HTML ----
css = """
:root {
  color-scheme: dark;
  --bg: #0b0b0c;
  --panel: #141416;
  --line: #1f1f22;
  --text: #eaeaee;
  --muted: #6b6b72;
  --accent: #0a84ff;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  padding: 48px 32px 96px;
  background: var(--bg);
  color: var(--text);
  font: 13px/1.5 -apple-system, "SF Pro Text", "Helvetica Neue", system-ui, sans-serif;
  letter-spacing: 0.01em;
}
h1 {
  font-weight: 500;
  font-size: 22px;
  letter-spacing: -0.01em;
  margin: 0 0 4px;
}
.sub {
  color: var(--muted);
  margin: 0 0 40px;
  font-size: 13px;
  max-width: 56ch;
}
.sub code {
  font: 12px/1 "SF Mono", ui-monospace, monospace;
  background: var(--panel);
  padding: 1px 6px;
  border-radius: 4px;
  color: var(--text);
}
table {
  border-collapse: collapse;
  width: 100%;
  max-width: 960px;
  margin: 0 auto;
}
thead th {
  color: var(--muted);
  font-weight: 500;
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  padding: 0 16px 12px;
  text-align: center;
}
thead th:first-child { text-align: left; padding-left: 0; }
tbody td {
  padding: 10px 16px;
  border-top: 1px solid var(--line);
  text-align: center;
  vertical-align: middle;
}
tbody td:first-child {
  text-align: left;
  padding-left: 0;
  font: 12px/1.3 "SF Mono", ui-monospace, monospace;
  color: var(--text);
  width: 48%;
}
.sym-cell {
  display: inline-block;
  width: 20px;
  height: 20px;
  line-height: 0;
  vertical-align: middle;
}
.sym-cell svg {
  width: 20px;
  height: 20px;
  display: block;
  color: var(--accent);
}
.sym-cell[data-mode="palette"] svg,
.sym-cell[data-mode="hierarchical"] svg {
  color: var(--accent);
}
.empty {
  color: var(--muted);
  font-style: italic;
  font-size: 11px;
}
.scales {
  display: flex;
  gap: 32px;
  justify-content: center;
  margin: 56px auto 0;
  max-width: 960px;
  padding-top: 32px;
  border-top: 1px solid var(--line);
}
.scales .group { text-align: center; }
.scales .group h3 {
  color: var(--muted);
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  font-weight: 500;
  margin: 0 0 10px;
}
.scales .row { display: flex; gap: 18px; align-items: center; }
.scales svg { display: block; }
.scale-16 { width: 16px; height: 16px; color: var(--accent); }
.scale-20 { width: 20px; height: 20px; color: var(--accent); }
.scale-32 { width: 32px; height: 32px; color: var(--accent); }
.scale-48 { width: 48px; height: 48px; color: var(--accent); }
.scale-64 { width: 64px; height: 64px; color: var(--accent); }
"""

parts = [
    "<!doctype html>",
    "<html lang=\"en\">",
    "<head>",
    "<meta charset=\"utf-8\">",
    "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
    "<title>sfsym — SVG preview</title>",
    f"<style>{css}</style>",
    "</head>",
    "<body>",
    "<h1>sfsym — SVG preview</h1>",
    "<p class=\"sub\">Every cell below is a live <code>&lt;svg&gt;</code> rendered at <b>20×20 CSS pixels</b>, "
    "produced by <code>sfsym export &lt;name&gt; -f svg</code>. Paths come from Apple's own "
    "<code>CUINamedVectorGlyph.drawInContext:</code> — re-serialized verbatim, not re-synthesized.</p>",
    "<table>",
    "<thead><tr><th>symbol</th>",
]
for m in MODES:
    parts.append(f"<th>{m}</th>")
parts.append("</tr></thead>")
parts.append("<tbody>")

for name, svgs in rows:
    parts.append("<tr>")
    parts.append(f"<td>{name}</td>")
    for m in MODES:
        s = svgs.get(m)
        if s:
            parts.append(f'<td><span class="sym-cell" data-mode="{m}">{s}</span></td>')
        else:
            parts.append('<td><span class="empty">—</span></td>')
    parts.append("</tr>")

parts.append("</tbody></table>")

# Scale strip: prove it's crisp vector at any size
pick = next(n for n in ordered if n == "cloud.sun.rain.fill")
scale_mono = inline(SVG_DIR / f"{pick}__monochrome.svg")
scale_pal = inline(SVG_DIR / f"{pick}__palette.svg")
parts.append("<section class=\"scales\">")
parts.append("<div class=\"group\"><h3>monochrome at 16 / 20 / 32 / 48 / 64 px</h3><div class=\"row\">")
for cls in ("scale-16", "scale-20", "scale-32", "scale-48", "scale-64"):
    parts.append(scale_mono.replace("<svg ", f'<svg class="{cls}" ', 1))
parts.append("</div></div>")
parts.append("<div class=\"group\"><h3>palette at 16 / 20 / 32 / 48 / 64 px</h3><div class=\"row\">")
for cls in ("scale-16", "scale-20", "scale-32", "scale-48", "scale-64"):
    parts.append(scale_pal.replace("<svg ", f'<svg class="{cls}" ', 1))
parts.append("</div></div>")
parts.append("</section>")

parts.append("</body></html>")

out = ROOT / "index.html"
out.write_text("\n".join(parts))
print(f"wrote {out} ({out.stat().st_size} bytes, {len(rows)} symbols)")
