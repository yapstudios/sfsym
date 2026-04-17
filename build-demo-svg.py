#!/usr/bin/env python3
"""Build a looping terminal SVG for the README header.

Types four sfsym commands with organic per-character rhythm (1D value-noise
modulation + natural space pauses), real inter-command human beats, and a
cursor that lives where a real shell's cursor would live: on the current
prompt line, not wherever the last output happened to end.
"""
from pathlib import Path
from html import escape
import math
import random

# ------------------ terminal content ----------------------------------------

# `type`  → typed characters (token colored as kind)
# `out`   → whole-line output from the program
# `beat`  → explicit extra pause before the next event (seconds)
#
# After each command ends (explicit `end_cmd` event), a new prompt line is
# auto-appended and the cursor is parked there. We never draw a cursor
# blinking over output; that isn't where real shells put it.
SCRIPT = [
    ('type', 'cmd',  'sfsym export heart.fill '),
    ('type', 'flag', '-f '), ('type', 'str', 'svg '),
    ('type', 'flag', '--color '), ('type', 'str', "'#ff3b30' "),
    ('type', 'flag', '-o '), ('type', 'str', 'heart.svg'),
    ('end_cmd', None),

    ('type', 'cmd',  'sfsym export cloud.sun.rain.fill '),
    ('type', 'flag', '--mode '), ('type', 'str', 'palette '),
    ('type', 'flag', '--palette '),
    ('type', 'str',  "'#ff3b30,#ffcc00,#4477ff'"),
    ('end_cmd', None),

    ('type', 'cmd',  'sfsym list | sfsym '),
    ('type', 'kw',   'batch'),
    ('run', 0.22),   # a real `batch` run is instantaneous before output lands
    ('out', 'batch: ok=8302 fail=0 in 10.1s (822/s)'),
    ('end_cmd', None),

    ('type', 'cmd',  'sfsym info heart.fill '),
    ('type', 'flag', '--json'),
    ('run', 0.18),
    ('out', '{ "name": "heart.fill", "templateLayers": 1,'),
    ('out', '  "hierarchyLayers": 1, "paletteLayers": 1,'),
    ('out', '  "modes": ["monochrome","hierarchical","palette"] }'),
    ('end_idle', None),   # final prompt with cursor idling (loop end)
]

# --------------- layout ----------------------------------------------------

W, H         = 900, 400
TITLE_H      = 28
CONTENT_TOP  = TITLE_H + 28
LINE_H       = 22
PAD_X        = 26
CHAR_W       = 9.15  # SF Mono/Menlo advance (9.0px) + letter-spacing (0.15px) at 15px

BASE_CHAR    = 0.048   # mean seconds per typed char
JITTER_AMP   = 0.028   # +/- range from base
SPACE_EXTRA  = 0.045   # natural word-break pause
INTER_CMD    = 0.22    # human beat between output-of-prev and typing-of-next
PROMPT_GAP   = 0.07    # time between prompt appearing and cursor landing on it
OUT_GAP      = 0.18    # time between successive output lines
HOLD_AFTER   = 2.4     # how long the idle cursor blinks before the loop restarts

# --------------- 1D value noise --------------------------------------------

random.seed(17)
_ctrl = [random.random() for _ in range(64)]

def value_noise(x: float) -> float:
    i = int(math.floor(x)) % len(_ctrl)
    j = (i + 1) % len(_ctrl)
    f = x - math.floor(x)
    f = (1 - math.cos(f * math.pi)) * 0.5
    return _ctrl[i] * (1 - f) + _ctrl[j] * f

def char_dt(tick_index: int, ch: str) -> float:
    n = value_noise(tick_index * 0.37)
    dt = BASE_CHAR + (n - 0.5) * 2 * JITTER_AMP
    if ch == ' ':
        dt += SPACE_EXTRA
    return max(0.012, dt)

# --------------- timeline build --------------------------------------------

# Build three parallel streams:
#   chars[]  — typed characters, each with (kind, ch, x, y, t_on)
#   outs[]   — output lines, each with (text, x, y, t_on)
#   prompts[] — prompt '$ ' that appears in-whole, each with (x, y, t_on)
#   cursor_frames[] — (t, x, y, visible) keyframes so the cursor tracks
#                     the current input position, not output text.
chars: list[dict] = []
outs: list[dict] = []
prompts: list[dict] = []
cursor: list[dict] = []

t = 0.0
tick_i = 0
y = CONTENT_TOP

def new_prompt():
    """Append a prompt to the current line and return the cursor x after it."""
    global t
    prompts.append({'x': PAD_X, 'y': y, 't': t})
    t += PROMPT_GAP  # small gap before the user starts typing on this line
    cx = PAD_X + 2 * CHAR_W  # "$ " = 2 chars
    cursor.append({'t': t, 'x': cx, 'y': y, 'visible': True})
    return cx

def end_command():
    """Advance to the next line and park a fresh blinking prompt."""
    global y, t
    y += LINE_H
    t += INTER_CMD
    return new_prompt()

# Initial prompt at t=0.
cursor_x = new_prompt()

for event in SCRIPT:
    kind = event[0]
    if kind == 'type':
        _, tok_kind, text = event
        for ch in text:
            dt = char_dt(tick_i, ch)
            t += dt
            chars.append({'kind': tok_kind, 'ch': ch, 'x': cursor_x, 'y': y, 't': t})
            cursor_x += CHAR_W
            cursor.append({'t': t, 'x': cursor_x, 'y': y, 'visible': True})
            tick_i += 1
    elif kind == 'run':
        # Program executes — hide cursor briefly; no fake "processing" feel,
        # just the blink of moving from input line to output line.
        _, pause = event
        cursor.append({'t': t + 0.01, 'x': cursor_x, 'y': y, 'visible': False})
        t += pause
    elif kind == 'out':
        _, text = event
        y += LINE_H
        outs.append({'text': text, 'y': y, 't': t})
        t += OUT_GAP
    elif kind == 'end_cmd':
        # A real shell prints a new prompt right after command output.
        cursor.append({'t': t + 0.005, 'x': cursor_x, 'y': y, 'visible': False})
        cursor_x = end_command()
    elif kind == 'end_idle':
        # Final state — cursor idles on a fresh prompt and blinks until loop.
        cursor.append({'t': t + 0.005, 'x': cursor_x, 'y': y, 'visible': False})
        y += LINE_H
        t += INTER_CMD
        prompts.append({'x': PAD_X, 'y': y, 't': t})
        t += PROMPT_GAP
        cursor_x = PAD_X + 2 * CHAR_W
        cursor.append({'t': t, 'x': cursor_x, 'y': y, 'visible': True})
        IDLE_START = t
        t += HOLD_AFTER

TYPE_END = t
TOTAL    = TYPE_END

def kt(time: float) -> float:
    return max(0.0, min(1.0, time / TOTAL))

# --------------- SVG emission ----------------------------------------------

COLORS = {
    'prompt': '#63E6E2',
    'cmd':    '#F2F2F7',
    'flag':   '#FFD60A',
    'str':    '#63E6E2',
    'kw':     '#FF9F0A',
    'out':    '#8E8E93',
}

parts: list[str] = []
parts.append(
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">'
)
parts.append(
    '<style>'
    'text { font: 400 15px "SF Mono","JetBrains Mono","Menlo",ui-monospace,monospace; letter-spacing: 0.15px; }'
    '.title { font: 500 12px -apple-system,"SF Pro Text","Helvetica Neue",system-ui,sans-serif; fill: #8E8E93; letter-spacing: 0; }'
    '</style>'
)
parts.append(
    '<defs>'
    '<linearGradient id="bar" x1="0" y1="0" x2="0" y2="1">'
    '<stop offset="0" stop-color="#3A3A3E"/><stop offset="1" stop-color="#2B2B2F"/>'
    '</linearGradient>'
    '</defs>'
    f'<rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="10" ry="10" fill="#111113" stroke="#000000" stroke-opacity="0.6" stroke-width="1"/>'
    f'<rect x="0.5" y="0.5" width="{W-1}" height="{TITLE_H}" rx="10" ry="10" fill="url(#bar)"/>'
    f'<rect x="0.5" y="{TITLE_H-10}" width="{W-1}" height="11" fill="url(#bar)"/>'
    f'<line x1="0.5" y1="{TITLE_H+0.5}" x2="{W-0.5}" y2="{TITLE_H+0.5}" stroke="#000000" stroke-opacity="0.5"/>'
    '<circle cx="20" cy="14.5" r="6" fill="#FF5F57" stroke="#E0443E" stroke-width="0.5"/>'
    '<circle cx="40" cy="14.5" r="6" fill="#FEBC2E" stroke="#DEA123" stroke-width="0.5"/>'
    '<circle cx="60" cy="14.5" r="6" fill="#28C840" stroke="#1AAB29" stroke-width="0.5"/>'
    f'<text class="title" x="{W/2}" y="18" text-anchor="middle">sfsym — -zsh — 90×24</text>'
)

def appear_tspan(x, color: str, text: str, t_on: float) -> str:
    s = kt(t_on)
    o = min(s + 0.0022, 1.0)
    xs = f' x="{x}"' if x is not None else ''
    return (
        f'<tspan{xs} fill="{color}" opacity="0">{escape(text)}'
        f'<animate attributeName="opacity" values="0;0;1;1" '
        f'keyTimes="0;{s:.5f};{o:.5f};1" dur="{TOTAL}s" begin="0s" repeatCount="indefinite"/>'
        f'</tspan>'
    )

# Collect per-line spans (so we only emit one <text> per line).
lines: dict[float, list[tuple[float, str]]] = {}

for p in prompts:
    lines.setdefault(p['y'], []).append(
        (p['t'], f'<tspan x="{p["x"]}" fill="{COLORS["prompt"]}" opacity="0">$ '
                 f'<animate attributeName="opacity" values="0;0;1;1" '
                 f'keyTimes="0;{kt(p["t"]):.5f};{kt(p["t"])+0.0022:.5f};1" '
                 f'dur="{TOTAL}s" begin="0s" repeatCount="indefinite"/></tspan>')
    )

for c in chars:
    color = COLORS.get(c['kind'], '#F2F2F7')
    lines.setdefault(c['y'], []).append(
        (c['t'], appear_tspan(c['x'], color, c['ch'], c['t']))
    )

for o in outs:
    lines.setdefault(o['y'], []).append(
        (o['t'], appear_tspan(PAD_X, COLORS['out'], o['text'], o['t']))
    )

for y_val, items in lines.items():
    items = sorted(items, key=lambda p: p[0])
    parts.append(f'<text x="{PAD_X}" y="{y_val}">')
    for _, span in items:
        parts.append(span)
    parts.append('</text>')

# ---------- cursor -------------------------------------------------------
# Cursor is one rect whose x, y, and opacity animate discretely through the
# frames collected above. At the final (idle) frame it blinks on/off.

cursor.sort(key=lambda d: d['t'])
# Deduplicate exact-same-time entries (keep the last = newest state).
dedup = {}
for c in cursor:
    dedup[round(c['t'], 5)] = c
cursor = [dedup[k] for k in sorted(dedup)]

# Add blinking at the idle tail.
IDLE = IDLE_START
blinks = []
blink_t = IDLE + 0.5
while blink_t < IDLE + HOLD_AFTER:
    blinks.append({'t': blink_t,          'x': cursor_x, 'y': y, 'visible': False})
    blinks.append({'t': blink_t + 0.52,   'x': cursor_x, 'y': y, 'visible': True})
    blink_t += 1.04
cursor.extend(blinks)
cursor.sort(key=lambda d: d['t'])

# Emit cursor rect with discrete keyTime animations.
cursor_times = [c['t'] for c in cursor]
cursor_keytimes = [kt(tt) for tt in cursor_times]
# Homebrew-safe: keyTimes must start at 0 and end at 1 when calcMode=discrete.
if not cursor_keytimes or cursor_keytimes[0] > 0:
    cursor.insert(0, {'t': 0, 'x': cursor[0]['x'] if cursor else PAD_X, 'y': cursor[0]['y'] if cursor else CONTENT_TOP, 'visible': False})
    cursor_keytimes = [kt(c['t']) for c in cursor]
if cursor_keytimes[-1] < 1:
    cursor.append({'t': TOTAL, 'x': cursor[-1]['x'], 'y': cursor[-1]['y'], 'visible': cursor[-1]['visible']})
    cursor_keytimes.append(1.0)

xs = ";".join(f"{c['x']:.2f}" for c in cursor)
ys = ";".join(f"{c['y'] - 14}" for c in cursor)
os_ = ";".join("1" if c['visible'] else "0" for c in cursor)
kts = ";".join(f"{k:.5f}" for k in cursor_keytimes)

parts.append(
    f'<rect width="8" height="16" fill="#F2F2F7" opacity="0">'
    f'<animate attributeName="x" calcMode="discrete" values="{xs}" keyTimes="{kts}" dur="{TOTAL}s" begin="0s" repeatCount="indefinite"/>'
    f'<animate attributeName="y" calcMode="discrete" values="{ys}" keyTimes="{kts}" dur="{TOTAL}s" begin="0s" repeatCount="indefinite"/>'
    f'<animate attributeName="opacity" calcMode="discrete" values="{os_}" keyTimes="{kts}" dur="{TOTAL}s" begin="0s" repeatCount="indefinite"/>'
    f'</rect>'
)

parts.append('</svg>')

out = Path(__file__).resolve().parent / "demo.svg"
out.write_text("\n".join(parts))
print(f"wrote {out} ({out.stat().st_size // 1024} KB, {TOTAL:.1f}s loop)")
