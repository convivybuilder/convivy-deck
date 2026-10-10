#!/usr/bin/env python3
"""Builds the redesign mockups in this directory.

    python3 design/redesign/build.py

Each output file is standalone HTML that renders offline: no web fonts, every
face is a system face (the same stacks session_view.py and the shell use).
The shared stylesheet is written once as deck.css and linked by every page.

THE PALETTE IS SOLVED, NOT PICKED. `solve()` below is a port of
`ThemeRecipe.solveLightness` over the OKLCH conversion in `OKLCH.swift`: every
ink is stated as an OKLCH start point plus a contrast TARGET against the
surface it sits on, and the build walks lightness until the target is met.
The measured ratios are printed at build time and written into index.html, so
the numbers a reader sees are the numbers the build produced.

Content is Deck's own on 2026-09-04: the crews on the mini's tmux, the
convivy-deck Course (course_01M0D6NN1FRHP5Y0Q994DJ6NJ2, version 8, last
reordered 2026-08-31), the open corrections queue, and the one pr-open epic
(#143). Where a panel had no live data (proposals) the text is the bead's.
"""
from pathlib import Path
import math

HERE = Path(__file__).resolve().parent

# ---------------------------------------------------------------------------
# OKLCH → sRGB and the contrast solver, ported from OKLCH.swift / ThemeRecipe
# ---------------------------------------------------------------------------

def _lin(c): return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
def _delin(c): return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055

def _unclamped(l, c, h):
    hr = math.radians(h)
    a, b = c * math.cos(hr), c * math.sin(hr)
    lp = l + 0.3963377774 * a + 0.2158037573 * b
    mp = l - 0.1055613458 * a - 0.0638541728 * b
    sp = l - 0.0894841775 * a - 1.2914855480 * b
    lc, mc, sc = lp ** 3, mp ** 3, sp ** 3
    return (_delin(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc),
            _delin(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc),
            _delin(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc))

def _in_gamut(rgb, tol=1e-6):
    return all(-tol <= x <= 1 + tol for x in rgb)

def _clamp(rgb): return tuple(min(max(x, 0), 1) for x in rgb)

def to_rgb(l, c, h):
    """Walks chroma down until the colour fits sRGB — hue and lightness kept."""
    while c > 0:
        cand = _unclamped(l, c, h)
        if _in_gamut(cand): return _clamp(cand)
        c -= 0.0005
    return _clamp(_unclamped(l, 0, h))

def lum(rgb): return 0.2126 * _lin(rgb[0]) + 0.7152 * _lin(rgb[1]) + 0.0722 * _lin(rgb[2])
def contrast(a, b):
    la, lb = lum(a), lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)

def to_oklch(rgb):
    r, g, b = (_lin(x) for x in rgb)
    lc = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    mc = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    sc = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    lp, mp, sp = (x ** (1 / 3) for x in (lc, mc, sc))
    l = 0.2104542553 * lp + 0.7936177850 * mp - 0.0040720468 * sp
    a = 1.9779984951 * lp - 2.4285922050 * mp + 0.4505937099 * sp
    bb = 0.0259040371 * lp + 0.7827717662 * mp - 0.8086757660 * sp
    c = math.hypot(a, bb)
    h = math.degrees(math.atan2(bb, a)) % 360
    return l, c, h

def solve(l, c, h, bg, target):
    """ThemeRecipe.solveLightness: move L away from the background until the
    WCAG ratio clears `target`; keep the best seen."""
    go_darker = l < (1.0 if lum(bg) > 0.18 else 0.0)
    cand_l = l
    best = to_rgb(l, c, h)
    best_ratio = contrast(best, bg)
    while best_ratio < target:
        cand_l += -0.01 if go_darker else 0.01
        if cand_l < 0 or cand_l > 1: break
        rgb = to_rgb(cand_l, c, h)
        ratio = contrast(rgb, bg)
        if ratio > best_ratio:
            best_ratio, best = ratio, rgb
    return best

def hexs(rgb): return "#%02x%02x%02x" % tuple(round(x * 255) for x in rgb)
def mix(a, b, t): return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))

WHITE = (1.0, 1.0, 1.0)
BLACK = (0.0, 0.0, 0.0)

def frame_tint(canvas, dark):
    """SessionPaneView.frameTintRGB: a canvas mixed halfway to the appearance's extreme."""
    t = 0.0 if dark else 1.0
    return tuple((c + t) / 2 for c in canvas)

def graphite_canvas(dark):
    """ThemeCatalog.graphite's canvas: the recipe's background at zero chroma, lifted as canvasTint lifts it."""
    return to_rgb(0.225 if dark else 0.95, 0.0, 0.0)

# ThemeCatalog: the ten named themes and their hues.
THEMES = {"ember": 29, "amber": 68, "gold": 95, "sage": 145, "teal": 178,
          "cyan": 205, "azure": 240, "indigo": 275, "violet": 305, "rose": 350}
HUES = sorted(THEMES.values())

ATTN_HUE = 65      # ThemeRecipe.attentionInk
WARN_HUE = 95      # ThemeRecipe.warningInk — 30° off the summons on purpose
NEUTRAL_BAND = 40  # a crew hue within this of ATTN_HUE draws in-progress marks neutral

def hue_conflicts(h):
    d = abs(((h - ATTN_HUE) + 180) % 360 - 180)
    return d <= NEUTRAL_BAND


def theme_tokens(theme, H):
    """Every token for one (appearance, selected-crew hue) pair, solved."""
    dark = theme == "dark"
    T = {}
    # surfaces — the frame carries the selected crew's hue at a tenth of the canvas's chroma
    chrome = to_rgb(0.215 if dark else 0.965, 0.006 if dark else 0.004, H)
    rail   = to_rgb(0.19 if dark else 0.947, 0.006 if dark else 0.005, H)
    canvas = to_rgb(0.235 if dark else 0.975, 0.028 if dark else 0.018, H)   # ThemeRecipe background, lifted
    inp    = to_rgb(0.265 if dark else 0.992, 0.02 if dark else 0.006, H)
    hover  = to_rgb(0.26 if dark else 0.93, 0.01 if dark else 0.008, H)
    T.update(bg_chrome=chrome, bg_rail=rail, bg_canvas=canvas, bg_input=inp, bg_hover=hover)
    # inks, solved on the chrome (the darker/lighter of the surfaces they sit on is chrome/rail; both are within 0.03 L)
    T["ink"]   = solve(0.90 if dark else 0.30, 0.02 if dark else 0.035, H, chrome, 7.0)   # foreground recipe
    T["ink_2"] = solve(0.70 if dark else 0.50, 0.012, H, chrome, 4.5)                     # every read secondary
    T["ink_3"] = solve(0.54 if dark else 0.66, 0.012, H, chrome, 3.0)                     # NON-TEXT ONLY: chevrons, rules, disabled
    T["line"]   = solve(0.36 if dark else 0.80, 0.008, H, chrome, 1.6)
    T["line_2"] = solve(0.30 if dark else 0.86, 0.006, H, chrome, 1.3)
    # the crew's accent: text at 4.5, marks at 3.0, a fill that white text clears at 4.5
    aL, aC = (0.72, 0.15) if dark else (0.58, 0.16)                                       # cursor recipe
    T["accent_text"] = solve(aL, aC, H, chrome, 4.5)
    T["accent_mark"] = solve(aL, aC, H, chrome, 3.0)
    T["accent_fill"] = solve(0.58, 0.16, H, WHITE, 4.5)
    T["accent_wash"] = mix(chrome, T["accent_mark"], 0.15)                                # RailRow: accent at 0.15 over the base
    # the right column's bands (B2, ColumnBand): a crew's identity band, the laptop's graphite band,
    # and the neutral Cockpit band on the window chrome. Each place line is solved to 4.5:1 on its own
    # surface, each rule and icon to 3:1, as ThemeRecipe.dotInk and placeLineInk do.
    band = frame_tint(canvas, dark)
    T["band"] = band
    T["band_ink"] = solve(aL, aC, H, band, 3.0)
    T["band_place"] = solve(0.50, 0.0, 0.0, band, 4.5)
    T["canvas_place"] = solve(0.50, 0.0, 0.0, canvas, 4.5)                                 # Slate card ids on the canvas
    T["neutral_place"] = solve(0.50, 0.0, 0.0, chrome, 4.5)
    gcanvas = graphite_canvas(dark)
    gband = frame_tint(gcanvas, dark)
    T["gr_canvas"] = gcanvas
    T["gr_band"] = gband
    T["gr_ink"] = solve(0.72 if dark else 0.58, 0.0, 0.0, gband, 3.0)
    T["gr_place"] = solve(0.50, 0.0, 0.0, gband, 4.5)
    # in-progress ink: the crew's hue, unless the hue collides with the summons
    if hue_conflicts(H):
        T["prog_text"], T["prog_mark"] = T["ink"], solve(0.90 if dark else 0.30, 0.0, H, chrome, 3.0)
    else:
        T["prog_text"], T["prog_mark"] = T["accent_text"], T["accent_mark"]
    # the summons: attentionInk (marks 3.0) plus a text form (4.5) and a fill
    T["attn_mark"] = solve(0.60, 0.13, ATTN_HUE, chrome, 3.0)
    T["attn_text"] = solve(0.60, 0.13, ATTN_HUE, chrome, 4.5)
    T["attn_fill"] = solve(0.60, 0.16, ATTN_HUE, WHITE, 4.5)
    # standing caution: warningInk, 30° off the summons, lower chroma
    T["warn"] = solve(0.58, 0.10, WARN_HUE, chrome, 4.5)
    T["err"]  = solve(0.55, 0.19, 25, chrome, 4.5)
    T["ok"]   = solve(0.55, 0.13, 150, chrome, 4.5)
    T["code_bg"] = to_rgb(0.20 if dark else 0.94, 0.02 if dark else 0.012, H)
    # every crew's mark, solved on the rail surface and on the selected wash (RailRow.markBacking)
    marks = {}
    for h in HUES:
        base = rail
        m = solve(aL, aC, h, base, 3.0)
        sel_surface = mix(base, m, 0.15)
        m_sel = solve(aL, aC, h, sel_surface, 3.0)
        # pulseDotInk: step L 0.12 away from the surface, re-solve
        l, c, hh = to_oklch(m)
        away = l - 0.12 if l < (1.0 if lum(base) > 0.18 else 0.0) else l + 0.12
        m_pulse = solve(min(max(away, 0), 1), c, hh, base, 3.0)
        marks[h] = (m, m_sel, m_pulse)
    T["marks"] = marks
    return T


def theme_css(theme, H):
    T = theme_tokens(theme, H)
    sel = f'.win[data-theme="{theme}"][data-hue="{H}"]'
    aw = T["accent_wash"]
    vars_ = {
        "bg-chrome": T["bg_chrome"], "bg-rail": T["bg_rail"], "bg-canvas": T["bg_canvas"], "bg-input": T["bg_input"], "bg-hover": T["bg_hover"],
        "ink": T["ink"], "ink-2": T["ink_2"], "ink-3": T["ink_3"], "line": T["line"], "line-2": T["line_2"],
        "accent-text": T["accent_text"], "accent-mark": T["accent_mark"], "accent-fill": T["accent_fill"], "accent-wash": aw,
        "prog-text": T["prog_text"], "prog-mark": T["prog_mark"],
        "attn-mark": T["attn_mark"], "attn-text": T["attn_text"], "attn-fill": T["attn_fill"],
        "warn": T["warn"], "err": T["err"], "ok": T["ok"], "code-bg": T["code_bg"],
        "band": T["band"], "band-ink": T["band_ink"], "band-place": T["band_place"],
        "canvas-place": T["canvas_place"], "neutral-place": T["neutral_place"],
        "gr-canvas": T["gr_canvas"], "gr-band": T["gr_band"], "gr-ink": T["gr_ink"], "gr-place": T["gr_place"],
    }
    out = [sel + " {"]
    for k, v in vars_.items():
        out.append(f"  --{k}: {hexs(v)};")
    out.append("  --shadow: " + ("rgba(0,0,0,.45)" if theme == "dark" else "rgba(0,0,0,.10)") + ";")
    out.append("}")
    for h, (m, m_sel, m_pulse) in T["marks"].items():
        out.append(f'{sel} .hue-{h} {{ --mark: {hexs(m)}; --mark-sel: {hexs(m_sel)}; --mark-pulse: {hexs(m_pulse)}; }}')
    return "\n".join(out)


def contrast_table():
    """The evidence: measured ratios for the pairs the critic measured, both themes, hue 240 (Deck) and 68 (amber)."""
    rows = []
    for theme in ("light", "dark"):
        for H in (240, 68):
            T = theme_tokens(theme, H)
            pairs = [
                ("white on --accent-fill (Send)", WHITE, T["accent_fill"]),
                ("white on --attn-fill (badge)", WHITE, T["attn_fill"]),
                ("--accent-text on chrome (waypoint, more)", T["accent_text"], T["bg_chrome"]),
                ("--accent-mark on chrome (glyphs)", T["accent_mark"], T["bg_chrome"]),
                ("--prog-mark on chrome (in-progress glyph)", T["prog_mark"], T["bg_chrome"]),
                ("--attn-text on chrome (HIGH, PR verdict)", T["attn_text"], T["bg_chrome"]),
                ("--attn-mark on rail (summons bar)", T["attn_mark"], T["bg_rail"]),
                ("--warn on chrome (rc off, soft tier)", T["warn"], T["bg_chrome"]),
                ("--ink-2 on chrome (every meta, timestamp, label)", T["ink_2"], T["bg_chrome"]),
                ("--ink-3 on chrome (chevrons, rules; never text)", T["ink_3"], T["bg_chrome"]),
                ("--line on chrome", T["line"], T["bg_chrome"]),
                ("--line-2 on chrome", T["line_2"], T["bg_chrome"]),
                ("crew mark 68 on rail", T["marks"][68][0], T["bg_rail"]),
                ("crew mark 240 on selected wash", T["marks"][240][1], mix(T["bg_rail"], T["marks"][240][0], 0.15)),
                ("--band-place on the crew band (place line)", T["band_place"], T["band"]),
                ("--band-ink on the crew band (icon, rule)", T["band_ink"], T["band"]),
                ("--neutral-place on chrome (Cockpit place line)", T["neutral_place"], T["bg_chrome"]),
                ("--gr-place on the graphite band (place line)", T["gr_place"], T["gr_band"]),
                ("--gr-ink on the graphite band (icon, rule)", T["gr_ink"], T["gr_band"]),
                ("--canvas-place on the Slate canvas (card ids)", T["canvas_place"], T["bg_canvas"]),
            ]
            for name, a, b in pairs:
                rows.append((theme, H, name, contrast(a, b)))
    return rows


# ---------------------------------------------------------------------------
# Stylesheet
# ---------------------------------------------------------------------------

CSS_BASE = r"""
/* deck.css — shared tokens and components for the redesign mocks.
   Tokens are generated by build.py's solver; edit build.py, not this file. */

:root {
  --font-ui: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", system-ui, sans-serif;
  --font-mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace;
  --font-prose: ui-serif, "New York", "Iowan Old Style", Georgia, "Times New Roman", serif;   /* session_view.py's own stack */
}

/* ---- the page around the mocks ---------------------------------------- */
html { color-scheme: light; }
body { margin: 0; padding: 32px 28px 72px; background: #ececee; color: #1c1d21; font: 13px/1.55 var(--font-ui); }
.doc { max-width: 1520px; margin: 0 auto; }
.doc h1 { font-size: 20px; font-weight: 600; letter-spacing: -.01em; margin: 0 0 6px; }
.doc h2 { font-size: 13px; font-weight: 600; margin: 34px 0 8px; letter-spacing: .01em; }
.doc .lede { font-size: 13.5px; color: #4b4e57; max-width: 82ch; margin: 0 0 18px; }
.doc .note { font-size: 12.5px; color: #3a3d45; max-width: 88ch; margin: 0 0 8px; }
.doc .note b { font-weight: 600; color: #1c1d21; }
.doc .note code, .doc .lede code, .doc td code { font: 11.5px var(--font-mono); background: #dfe0e4; padding: 1px 4px; border-radius: 3px; }
.doc ul.note { padding-left: 18px; }
.doc ul.note li { margin: 3px 0; }
.doc .nav { font-size: 12px; color: #5a5d66; margin: 0 0 22px; }
.doc .nav a { color: #2b5bd7; text-decoration: none; margin-right: 14px; }
.doc .nav a.here { color: #1c1d21; font-weight: 600; }
.doc .frames { display: flex; flex-direction: column; gap: 26px; }
.doc .frame-label { font: 600 11px/1 var(--font-ui); letter-spacing: .08em; text-transform: uppercase; color: #6b6e78; margin: 0 0 8px; }
.doc .scroller { overflow-x: auto; padding-bottom: 6px; }
.doc .risk { border-left: 3px solid #b8762a; padding: 8px 12px; background: #f4efe6; max-width: 88ch; }
.doc .finding { border-left: 3px solid #2b5bd7; padding: 8px 12px; background: #e9eef9; max-width: 88ch; }
.doc .concede { border-left: 3px solid #7a7d86; padding: 8px 12px; background: #e6e7ea; max-width: 88ch; }
.doc table { border-collapse: collapse; font-size: 12px; }
.doc th, .doc td { text-align: left; padding: 4px 10px 4px 0; border-bottom: 1px solid #d6d7db; vertical-align: top; }
.doc td.n { font-family: var(--font-mono); font-size: 11.5px; text-align: right; }
.doc td.pass { color: #1f7a3a; } .doc td.fail { color: #b3261e; }

/* ---- the window --------------------------------------------------------- */
.win {
  width: var(--w, 1440px); height: var(--hgt, 880px);
  border-radius: 10px; overflow: hidden; flex: none;
  box-shadow: 0 18px 44px rgba(0,0,0,.28), 0 0 0 1px rgba(0,0,0,.16);
  font: 12px/1.35 var(--font-ui);
  display: grid; grid-template-rows: 44px 1fr;
  background: var(--bg-chrome); color: var(--ink);
  -webkit-font-smoothing: antialiased; position: relative;
}
.mono { font-family: var(--font-mono); font-size: 11px; letter-spacing: -.01em; }
.num  { font-variant-numeric: tabular-nums; }
.dim  { color: var(--ink-2); }
.sectlabel { font: 600 10px/1 var(--font-ui); letter-spacing: .09em; text-transform: uppercase; color: var(--ink-2); }

/* ---- title bar + toolbar (NSToolbar, unified; controls at 28pt) ----------- */
.titlebar { display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; padding: 0 12px; border-bottom: 1px solid var(--line); background: var(--bg-chrome); }
.lights { display: flex; gap: 8px; align-items: center; }
.lights i { width: 12px; height: 12px; border-radius: 50%; display: block; }
.lights i:nth-child(1) { background: #ff5f57; } .lights i:nth-child(2) { background: #febc2e; } .lights i:nth-child(3) { background: #28c840; }
.tb-left { display: flex; align-items: center; gap: 14px; }
.tb-title { font-size: 12.5px; font-weight: 600; color: var(--ink-2); text-align: center; }
.tb-title span { font-weight: 400; }
.tb-right { display: flex; justify-content: flex-end; gap: 8px; align-items: center; }
.tbtn { display: inline-flex; align-items: center; gap: 6px; height: 28px; padding: 0 9px; border-radius: 6px; color: var(--ink-2); font-size: 12px; font-weight: 500; }
.tbtn svg { width: 14px; height: 14px; }
.tbtn.on { background: var(--bg-hover); color: var(--ink); box-shadow: inset 0 0 0 1px var(--line); }
.tbtn .badge { font: 600 10px/1 var(--font-ui); padding: 4px 6px; border-radius: 9px; background: var(--attn-fill); color: #fff; }
.tbtn.sidebar { padding: 0 7px; }
/* the column occupant: one enum, one segmented control (Cockpit | Shell | Local | [Item/Viewer/Editor]) */
.seg { display: inline-flex; height: 28px; border-radius: 7px; box-shadow: inset 0 0 0 1px var(--line); background: var(--bg-rail); padding: 2px; gap: 2px; }
.seg span { display: inline-flex; align-items: center; gap: 5px; padding: 0 9px; border-radius: 5px; font-size: 12px; font-weight: 500; color: var(--ink-2); }
.seg span svg { width: 13px; height: 13px; }
.seg span.on { background: var(--bg-input); color: var(--ink); box-shadow: 0 1px 2px var(--shadow); }
.seg span.doc { color: var(--ink); }

/* ---- body split ---------------------------------------------------------- */
.body { display: grid; grid-template-columns: var(--rail-w, 216px) 1fr var(--cock-w, 328px); min-height: 0; }
.body.no-cockpit { grid-template-columns: var(--rail-w, 216px) 1fr; }
.body.no-rail { grid-template-columns: 1fr var(--cock-w, 328px); }
.body.no-rail.no-cockpit { grid-template-columns: 1fr; }
.body.dots { --rail-w: 44px; }

/* ---- the rail ------------------------------------------------------------ */
.rail { background: var(--bg-rail); border-right: 1px solid var(--line); display: flex; flex-direction: column; min-height: 0; position: relative; }
.rail .list { flex: 1; overflow: hidden; padding-top: 6px; position: relative; }
.rail .foot { border-top: 1px solid var(--line); }
.row { display: flex; align-items: center; gap: 8px; height: 26px; padding: 0 10px 0 12px; position: relative; color: var(--ink); }
.row .name { font-size: 13px; flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row.child { padding-left: 32px; }
.row.child::before { content: ""; position: absolute; left: 17px; top: 0; bottom: 0; width: 1px; background: var(--line); }   /* the spine */
.row.child.last::before { bottom: 50%; }
.row.child::after { content: ""; position: absolute; left: 17px; top: 50%; width: 7px; height: 1px; background: var(--line); } /* the tick */
.row.sel { background: var(--accent-wash); }
.row.sel .mark { color: var(--mark-sel); }
.row.off .name { color: var(--ink-2); }
.row .trail { display: flex; align-items: center; gap: 5px; color: var(--ink-2); font-size: 10.5px; }
.row .trail svg { width: 10px; height: 10px; color: var(--ink-3); }
.row .summons { position: absolute; left: 0; top: 0; bottom: 0; width: 3px; background: var(--attn-mark); }
.row .warn { color: var(--attn-mark); width: 10px; height: 10px; }
.rail .sect { padding: 12px 12px 4px; }
.rail .bead { padding: 10px 12px 10px; display: flex; flex-direction: column; gap: 5px; }
.rail .bead .t { font-size: 12.5px; font-weight: 500; line-height: 1.3; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.meter { height: 3px; border-radius: 2px; background: var(--line); overflow: hidden; }
.meter i { display: block; height: 100%; background: var(--accent-mark); }
.rail .bead .f { font-size: 11px; color: var(--ink-2); display: flex; justify-content: space-between; }
.rail .newbtn { display: flex; align-items: center; gap: 6px; height: 34px; padding: 0 12px; font-size: 12px; font-weight: 500; color: var(--ink-2); border-top: 1px solid var(--line); }
.rail .newbtn svg { width: 12px; height: 12px; }
/* the summons that scrolled off: a chip pinned to the list's bottom edge, the rail's own offScreen rule */
.rail .offscreen { position: absolute; left: 0; right: 0; bottom: 0; height: 22px; display: flex; align-items: center; justify-content: center; gap: 4px; background: var(--bg-rail); border-top: 1px solid var(--line); color: var(--attn-text); font: 600 10.5px var(--font-ui); }
.rail .offscreen svg { width: 10px; height: 10px; }
.rail.dots .offscreen span { display: none; }
.rail .offscreen i { width: 3px; height: 12px; background: var(--attn-mark); display: inline-block; }
/* collapsed to marks */
.rail.dots .row { padding: 0; justify-content: center; height: 30px; }
.rail.dots .row.child { padding-left: 10px; height: 24px; }
.rail.dots .row.child::before { display: none; }
.rail.dots .row.child::after { left: 12px; width: 6px; }   /* the tick survives: a child is still a child at 44pt */
.rail.dots .row.child .mark { transform: scale(.85); }
.rail.dots .sect { height: 1px; padding: 0; margin: 8px 12px; background: var(--line); overflow: hidden; color: transparent; font-size: 0; }   /* a rule, not a label */
.rail.dots .bead { padding: 10px 10px; }
.rail.dots .bead .t, .rail.dots .bead .f, .rail.dots .bead .sectlabel { display: none; }
.rail.dots .newbtn span { display: none; }
.rail.dots .newbtn { justify-content: center; padding: 0; }

/* ---- session marks: shape carries state, colour carries identity --------- */
.mark { width: 14px; height: 14px; display: inline-flex; align-items: center; justify-content: center; flex: none; color: var(--mark); }
.mark svg { width: 14px; height: 14px; overflow: visible; }
.mark.off { opacity: .3; }
.mark.would { opacity: .3; }                  /* a hue this row WOULD take: a preview, drawn at the stopped row's 30% */
.mark.busy svg { animation: spin 1.4s linear infinite; }
.mark.listening svg { animation: breathe 1.1s ease-in-out infinite alternate; }
.mark.needs { color: var(--attn-mark); }
.mark.term { color: var(--ink-2); font-size: 13px; }
.mark.start svg { color: var(--ink-3); }       /* a catalog row: hollow, so it cannot be mistaken for a stopped crew's dimmed square */
@keyframes spin { to { transform: rotate(360deg); } }
@keyframes breathe { from { color: var(--mark) } to { color: var(--mark-pulse) } }
@media (prefers-reduced-motion: reduce) { .mark svg, .halo, .cursor { animation: none !important; } }

/* ---- centre column -------------------------------------------------------- */
.centre { display: grid; grid-template-rows: 34px 1fr auto 26px; min-width: 0; min-height: 0; background: var(--bg-canvas); }
.centre.no-ribbon { grid-template-rows: 34px 1fr auto; }

/* the co's row: who, what it says it is doing (or what the pane has to say instead), vitals */
.sess { display: flex; align-items: center; gap: 10px; padding: 0 12px; border-bottom: 1px solid var(--line); background: var(--bg-chrome); min-width: 0; }
.sess .who { display: flex; align-items: center; gap: 7px; flex: none; }
.sess .who b { font-size: 12.5px; font-weight: 600; }
.sess .working { flex: 1; min-width: 0; display: flex; align-items: baseline; gap: 6px; font-size: 12px; }
.sess .working .txt { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.sess .working .age { color: var(--ink-2); flex: none; font-variant-numeric: tabular-nums; }
.sess .working .age.stale { color: var(--warn); }
.sess .status { flex: 1; min-width: 0; font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--ink-2); }
.sess .status.err { color: var(--err); }
.vitals { display: flex; align-items: center; gap: 12px; flex: none; }
.vit { display: inline-flex; align-items: center; gap: 5px; color: var(--ink-2); font-size: 11px; white-space: nowrap; }
.vit svg { width: 12px; height: 12px; }
.vit .ctx { display: inline-flex; align-items: center; gap: 6px; }
.vit .ctx .meter { width: 44px; height: 4px; background: var(--line); }
.vit .ctx .meter i { background: var(--ink-2); }
.vit .ctx.soft .meter i { background: var(--warn); } .vit .ctx.soft { color: var(--warn); }
.vit .ctx.hard .meter i { background: var(--err); } .vit .ctx.hard { color: var(--err); }
.vit.warn { color: var(--warn); }
.vit.pr { color: var(--attn-text); }
.vit.asof { color: var(--ink-2); }
.vitals.compact .vit:not(.keep) { display: none; }

/* the conversation: a document, as session_view.py already draws it — serif prose, mono for the machine */
.convo { overflow: hidden; position: relative; display: flex; flex-direction: column; justify-content: flex-end; padding: 0 0 14px; min-height: 0; }
.convo .inner { max-width: 46rem; width: 100%; margin: 0 auto; padding: 0 28px; box-sizing: border-box; }
.turn { margin: 0 0 17px; }
.turn .whom { font: 600 10.5px/1 var(--font-ui); letter-spacing: .06em; text-transform: uppercase; color: var(--ink-2); margin: 0 0 5px; display: flex; align-items: center; gap: 8px; }
.turn .whom time { font-weight: 400; letter-spacing: 0; text-transform: none; }
.turn p { font: 15.75px/1.65 var(--font-prose); margin: 0 0 8px; color: var(--ink); }   /* SessionTypography: 15px root × 1.05, leading 1.65, user-adjustable */
.turn.you .msg { border-left: 3px solid currentColor; padding-left: .8rem; opacity: .95; }   /* session_view .you .body */
.turn.you.held .msg { border-left: 1px dashed currentColor; opacity: .55; }                   /* session_view .you.held .body */
.turn code { font: 12.5px var(--font-mono); background: var(--code-bg); padding: 1px 4px; border-radius: 3px; }
.tool { display: flex; align-items: center; gap: 6px; height: 22px; padding: 0 2px; margin: 2px 0; font: 11.5px var(--font-mono); color: var(--ink-2); }   /* session_view <details><summary> */
.tool .verb { color: var(--ink); font-weight: 600; }
.tool > span:not(.verb) { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.tool svg { width: 9px; height: 9px; color: var(--ink-3); flex: none; }
.convo .fade { position: absolute; left: 0; right: 0; top: 0; height: 36px; background: linear-gradient(to top, transparent, var(--bg-canvas)); pointer-events: none; }
.convo .cursor { display: inline-block; width: 7px; height: 14px; background: var(--accent-mark); vertical-align: -2px; margin-left: 2px; animation: blink 1s steps(2) infinite; }
.convo.veiled .inner { opacity: .45; }
@keyframes blink { 50% { opacity: 0 } }

/* the operator's rows: live state + composer, or the gate, or the fallback */
.oper { border-top: 1px solid var(--line); background: var(--bg-chrome); padding: 8px 12px 10px; display: flex; flex-direction: column; gap: 8px; }
.live { display: flex; align-items: center; gap: 8px; font-size: 11.5px; }
.live .state { font-weight: 500; }
.live .quiet { color: var(--ink-2); font-variant-numeric: tabular-nums; }
.live .bg { display: inline-flex; align-items: center; gap: 5px; color: var(--ink-2); }
.live .bg i { width: 5px; height: 5px; border-radius: 50%; background: var(--ink-2); animation: breathe2 .9s ease-in-out infinite alternate; }
@keyframes breathe2 { to { opacity: .25 } }
.live .err { color: var(--err); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.composer { border: 1px solid var(--line); border-radius: 7px; background: var(--bg-input); display: flex; flex-direction: column; box-shadow: 0 1px 2px var(--shadow); }
.composer .text { padding: 9px 12px 4px; font-size: 13px; line-height: 1.45; min-height: 42px; color: var(--ink); }
.composer .text .ph { color: var(--ink-2); }
.composer .bar { display: flex; align-items: center; gap: 8px; padding: 4px 8px 6px 10px; }
.composer .cmd { display: inline-flex; align-items: center; gap: 5px; color: var(--ink-2); font-size: 11.5px; }
.composer .cmd svg { width: 12px; height: 12px; }
.composer .held { color: var(--ink-2); font-size: 11.5px; display: inline-flex; gap: 6px; align-items: center; }
.composer .hint { margin-left: auto; font-size: 11px; color: var(--ink-2); }
.btn { display: inline-flex; align-items: center; justify-content: center; height: 24px; padding: 0 10px; border-radius: 6px; font-size: 12px; font-weight: 500; color: var(--ink); white-space: nowrap; background: var(--bg-hover); box-shadow: inset 0 0 0 1px var(--line); gap: 5px; }
.btn.primary { background: var(--accent-fill); color: #fff; box-shadow: none; }
.btn.ghost { background: transparent; box-shadow: none; color: var(--ink-2); }
.btn svg { width: 12px; height: 12px; }
.fallback { display: flex; align-items: center; gap: 10px; font-size: 12.5px; font-weight: 500; padding: 6px 0 2px; }
/* the gate: GatePanel, at most 340pt, scrolling */
.gate { display: flex; flex-direction: column; gap: 10px; max-height: 340px; overflow: hidden; padding: 4px 0 2px; }
.gate .gh { display: flex; align-items: baseline; gap: 8px; }
.gate .gh .rem { font-size: 11.5px; color: var(--ink-2); }
.gate .q { font-size: 13px; font-weight: 500; line-height: 1.4; }
.opt { display: grid; grid-template-columns: 22px 1fr auto; align-items: baseline; gap: 8px; padding: 8px 10px; border: 1px solid var(--line); border-radius: 6px; background: var(--bg-input); }
.opt .n { font: 600 11px var(--font-mono); color: var(--ink-2); }
.opt .l { font-size: 12.5px; line-height: 1.4; }
.opt .d { font-size: 11.5px; color: var(--ink-2); margin-top: 2px; }
.opt .k { font: 11px var(--font-mono); color: var(--ink-3); }
.opt.rec { border-color: var(--accent-mark); }
.gate .foot { display: flex; align-items: center; gap: 8px; font-size: 11.5px; color: var(--ink-2); }
/* the raw terminal fallback */
.termhdr { display: flex; align-items: center; justify-content: space-between; padding: 6px 12px; border-bottom: 1px solid var(--line); background: var(--bg-chrome); font-size: 12px; color: var(--ink-2); }
.rawterm { flex: 1; padding: 10px 12px; font: 11.5px/1.5 var(--font-mono); color: var(--ink); white-space: pre; overflow: hidden; }
.rawterm .p { color: var(--accent-text); }

/* the waypoint ribbon: the last row, always */
.ribbon { display: flex; align-items: center; gap: 8px; padding: 0 10px; white-space: nowrap; border-top: 1px solid var(--line); background: var(--bg-chrome); overflow: hidden; }
.ribbon .scroll { display: flex; align-items: center; gap: 2px; overflow: hidden; flex: 1; min-width: 0;
  -webkit-mask-image: linear-gradient(to right, #000 calc(100% - 48px), transparent); mask-image: linear-gradient(to right, #000 calc(100% - 48px), transparent); }
.wp { display: inline-flex; align-items: center; gap: 6px; flex: none; }
.wp .dot { width: 8px; height: 8px; border-radius: 50%; position: relative; flex: none; }
.wp.done .dot { background: var(--ink-2); }
.wp.cur  .dot { background: var(--prog-mark); }
.wp.ahead .dot { background: var(--line); box-shadow: inset 0 0 0 1px var(--ink-3); }
.wp .lbl { font-size: 11px; color: var(--ink-2); padding-right: 2px; }
.wp.done .lbl { text-decoration: line-through; }
.wp.cur .lbl { color: var(--prog-text); font-weight: 600; }
.wp .halo { position: absolute; inset: 0; border-radius: 50%; border: 1px solid var(--prog-mark); animation: halo 1.8s ease-out infinite; }
@keyframes halo { from { transform: scale(1); opacity: .7 } to { transform: scale(2.1); opacity: 0 } }
.ribbon .rule { width: 14px; height: 1px; background: var(--line); flex: none; }
.ribbon .pos { flex: none; font-size: 10.5px; color: var(--ink-2); }

/* ---- the cockpit ---------------------------------------------------------- */
.cockpit { border-left: 1px solid var(--line); background: var(--bg-chrome); display: grid; grid-template-rows: auto 1fr; min-height: 0; min-width: 0; overflow: hidden; }
.cockpit > *, .sheet > * { min-width: 0; }
.win[style*="--hgt:auto"] .cockpit .scroll { overflow: visible; }
.cockpit .head { padding: 0; }
.cockpit .head .band .asof { font-size: 11px; color: var(--ink-2); display: inline-flex; gap: 5px; align-items: center; }
.cockpit .head .band .asof svg { width: 12px; height: 12px; }
.cockpit .index { display: flex; gap: 2px; padding: 6px 12px 0; border-bottom: 1px solid var(--line); }
.cockpit .index a { padding: 5px 6px 7px; font-size: 11px; color: var(--ink-2); border-bottom: 2px solid transparent; display: inline-flex; gap: 5px; align-items: baseline; }
.cockpit .index a b { font-weight: 600; color: var(--ink); }
.cockpit .index a .n { font: 11px var(--font-mono); color: var(--ink-2); }
.cockpit .index a.here { border-bottom-color: var(--ink); }
.cockpit .index a.collapsed b { color: var(--ink-2); text-decoration: line-through; }   /* a collapsed panel stays in the index, struck */
.cockpit .index a .n.hot { color: var(--attn-text); font-weight: 600; }
.cockpit .scroll { overflow: hidden; padding: 4px 0 0; }

/* The right column's band (B2, ColumnBand): icon, title, place line, then the tab's own controls. Its
   surface and its rule are the tab's identity: a crew's band takes the crew's colour, the laptop's
   takes graphite, and the Cockpit's stays neutral with a plain separator. The app truncates the place
   line in the middle and keeps the full text in a tooltip; CSS can only truncate at the end. */
.band { display: flex; align-items: center; gap: 6px; height: 30px; box-sizing: border-box; padding: 0 10px; background: var(--bg-chrome); border-bottom: 1px solid var(--line); min-width: 0; }
.band .bi { width: 18px; flex: none; display: inline-flex; justify-content: center; color: var(--ink); }
.band .bi svg { width: 12px; height: 12px; }
.band .bt { font: 600 12px var(--font-ui); flex: none; white-space: nowrap; }
.band .bp { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font: 10px var(--font-ui); color: var(--neutral-place); }
.band .tr { margin-left: auto; flex: none; display: inline-flex; gap: 6px; align-items: center; }
.band.crew { background: var(--band); border-bottom: 2px solid var(--band-ink); }
.band.crew .bi { color: var(--band-ink); }
.band.crew .bp { color: var(--band-place); }
.band.gr { background: var(--gr-band); border-bottom: 2px solid var(--gr-ink); }
.band.gr .bi { color: var(--gr-ink); }
.band.gr .bp { color: var(--gr-place); }
.tbody { flex: 1; min-height: 0; overflow: hidden; padding: 10px 12px; font: 11.5px/1.55 var(--font-mono); color: var(--ink); background: var(--bg-canvas); }
.tbody.gr { background: var(--gr-canvas); }
.tbody .dim { color: var(--ink-2); }
.sbody { flex: 1; min-height: 0; overflow: hidden; padding: 12px; background: var(--bg-canvas); font: 12px/1.5 var(--font-ui); }
.sbody .card { background: var(--bg-input); border: 1px solid var(--line); border-radius: 6px; padding: 8px 10px; margin-bottom: 8px; }
.sbody .cid { font: 10px/1.2 var(--font-mono); color: var(--canvas-place); margin-bottom: 4px; }
.sbody .flag { font: 600 10px var(--font-ui); color: var(--attn-text); }
.panel { padding: 8px 12px 10px; border-bottom: 1px solid var(--line); }
.panel:last-child { border-bottom: 0; }
.panel .ph { display: flex; align-items: center; gap: 6px; height: 22px; margin-bottom: 4px; }
.panel .ph svg.chev { width: 10px; height: 10px; color: var(--ink-3); }
.panel .ph .cnt { margin-left: auto; font: 11px var(--font-mono); color: var(--ink-2); }
.panel .ph .act { margin-left: auto; display: inline-flex; gap: 6px; }
.panel .empty { font-size: 11.5px; color: var(--ink-2); padding: 2px 0; }
.panel .empty.err { color: var(--err); }
.panel .foot { font-size: 11px; color: var(--ink-2); margin-top: 6px; }
.unresolved { padding: 14px 12px; font-size: 12px; color: var(--ink-2); line-height: 1.45; }

/* one row grammar for every list in the cockpit */
.crow { display: grid; grid-template-columns: 14px 1fr auto; column-gap: 7px; align-items: baseline; padding: 4px 0; position: relative; }
.crow .g { width: 12px; height: 12px; align-self: start; margin-top: 2px; color: var(--ink-2); }
.crow .g svg { width: 12px; height: 12px; display: block; }
.crow .g.prog, .crow .g.pr { color: var(--prog-mark); }
.crow .g.held, .crow .g.attn { color: var(--attn-mark); }
.crow .t { font-size: 11px; line-height: 1.35; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.crow.done .t, .crow.closed .t { color: var(--ink-2); text-decoration: line-through; }
.crow .m { font: 10px var(--font-mono); color: var(--ink-2); white-space: nowrap; display: inline-flex; align-items: center; gap: 6px; }
.crow .m .held { color: var(--attn-text); display: inline-flex; gap: 2px; align-items: center; }
.crow .m .held svg { width: 10px; height: 10px; }
.crow .m .chev { width: 10px; height: 10px; color: var(--ink-3); }
.crow .m .sev { font: 600 10px/1 var(--font-ui); letter-spacing: .06em; text-transform: uppercase; color: var(--attn-text); }
.crow.hover { background: var(--bg-hover); margin: 0 -6px; padding-left: 6px; padding-right: 6px; border-radius: 4px; }
.crow .copy { width: 12px; height: 12px; color: var(--ink-2); }

/* an expanded epic: the spine, the interior, the children */
.epic { position: relative; margin: 0 0 4px 6px; padding: 2px 0 2px 14px; }
.epic::before { content: ""; position: absolute; left: 0; top: 0; bottom: 0; width: 1px; background: var(--line); }
.epic .state { font-size: 11px; color: var(--ink-2); margin: 2px 0 4px; }
.epic .cap { font-size: 11px; line-height: 1.4; color: var(--ink-2); display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.epic .cap b { font-weight: 600; color: var(--ink); }
.epic .more { font-size: 11px; color: var(--accent-text); margin: 1px 0 4px; }
.epic .meta { font-size: 11px; color: var(--ink-2); margin: 0 0 6px; }
.epic .kids .crow { padding: 3px 0; }
.epic .kids .t { font-size: 10px; }
.epic .loading { display: inline-flex; gap: 6px; align-items: center; font-size: 11px; color: var(--ink-2); }
.epic .loading i { width: 10px; height: 10px; border: 1.5px solid var(--line); border-top-color: var(--ink-2); border-radius: 50%; animation: spin 1s linear infinite; }

.affordance { display: inline-flex; align-items: center; gap: 5px; font-size: 11px; color: var(--ink-2); padding: 2px 0 4px; }
.affordance svg { width: 10px; height: 10px; }

/* dispatched: an agent in flight */
.run .t b { font-weight: 600; font-size: 12px; }
.run .task { font-size: 11px; color: var(--ink-2); line-height: 1.4; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; margin-top: 2px; }

/* proposals: their own region, tinted, with the verbs on the row */
.prop { padding: 8px 10px; border-radius: 6px; background: var(--accent-wash); margin-top: 2px; }
.prop .t { font-size: 12px; font-weight: 600; margin-bottom: 3px; }
.prop .b { font-size: 11px; line-height: 1.45; color: var(--ink-2); display: -webkit-box; -webkit-line-clamp: 4; -webkit-box-orient: vertical; overflow: hidden; }
.prop .acts { display: flex; gap: 6px; margin-top: 8px; }

/* the item detail pane, in the column or the sheet */
.item { display: grid; grid-template-rows: auto 1fr auto; min-height: 0; }
.item .ih { display: flex; align-items: baseline; gap: 6px; padding: 8px 12px; border-bottom: 1px solid var(--line); }
.item .ih .t { font-size: 12.5px; font-weight: 500; line-height: 1.35; flex: 1; }
.item .ih .p { font: 11px var(--font-mono); color: var(--ink-2); }
.item .ibody { padding: 12px 14px; overflow: hidden; font: 13.5px/1.6 var(--font-prose); }
.item .ibody h4 { font: 600 11px/1 var(--font-ui); letter-spacing: .06em; text-transform: uppercase; color: var(--ink-2); margin: 12px 0 6px; }
.item .ibody p { margin: 0 0 8px; }
.item .ibody code { font: 11.5px var(--font-mono); background: var(--code-bg); padding: 1px 4px; border-radius: 3px; }
.item .ibody .cm { font: 12px/1.5 var(--font-ui); color: var(--ink-2); border-left: 2px solid var(--line); padding-left: 10px; margin: 6px 0; }
.item .acts { display: flex; gap: 6px; padding: 8px 12px; border-top: 1px solid var(--line); flex-wrap: wrap; }

/* narrow: the cockpit as a sheet over the conversation */
.sheet { position: absolute; top: 44px; right: 0; bottom: 0; width: 340px; background: var(--bg-chrome); border-left: 1px solid var(--line); box-shadow: -12px 0 32px var(--shadow); display: grid; grid-template-rows: auto 1fr; z-index: 3; }
.sheet.item { grid-template-rows: auto 1fr auto; }
.scrim { position: absolute; inset: 44px 0 0 0; background: rgba(0,0,0,.18); z-index: 2; }

/* narrow: a compact composer */
.composer.compact .hint { display: none; }
.composer.compact .btn .lbl { display: none; }
.composer.compact .btn { padding: 0 7px; }
.composer.compact .cmd span { display: none; }

/* ---- the legends ---------------------------------------------------------- */
.grammar { display: grid; grid-template-columns: repeat(5, 1fr); gap: 10px; }
.grammar .cell { padding: 10px 12px; border-radius: 6px; background: var(--bg-rail); border: 1px solid var(--line); }
.grammar .cell .crow { padding: 0; }
.grammar .cell .why { font-size: 11px; color: var(--ink-2); margin-top: 6px; line-height: 1.4; }
.marks { display: grid; grid-template-columns: repeat(7, 1fr); gap: 10px; }
.marks .cell { padding: 10px 12px; border-radius: 6px; background: var(--bg-rail); border: 1px solid var(--line); display: flex; gap: 10px; align-items: flex-start; }
.marks .cell .lab { font-size: 11.5px; font-weight: 600; }
.marks .cell .why { font-size: 11px; color: var(--ink-2); line-height: 1.4; margin-top: 2px; }
.strip { padding: 14px 16px; border-radius: 10px; }
.swatches { display: flex; gap: 8px; flex-wrap: wrap; }
.sw { display: inline-flex; align-items: center; gap: 6px; font-size: 11px; padding: 4px 8px; border-radius: 5px; background: var(--bg-rail); border: 1px solid var(--line); }
.sw i { width: 12px; height: 12px; border-radius: 3px; display: inline-block; }
"""

# SVG symbols. Drawn once per page; referenced by <use>.
SYMBOLS = """
<svg width="0" height="0" style="position:absolute" aria-hidden="true">
  <defs>
    <symbol id="m-ready" viewBox="0 0 14 14"><rect x="1" y="1" width="12" height="12" rx="2" fill="currentColor"/></symbol>
    <symbol id="m-start" viewBox="0 0 14 14"><rect x="1.75" y="1.75" width="10.5" height="10.5" rx="2" fill="none" stroke="currentColor" stroke-width="1.5"/></symbol>
    <symbol id="m-busy" viewBox="0 0 14 14"><path fill="currentColor" fill-rule="evenodd" d="M7 0a7 7 0 1 0 4.95 2.05L7 7z M7 5.64A1.36 1.36 0 1 0 7 8.36z"/></symbol>
    <symbol id="m-listening" viewBox="0 0 14 14"><circle cx="7" cy="7" r="7" fill="currentColor"/></symbol>
    <symbol id="m-needs" viewBox="0 0 14 14"><path d="M1 0 L14 7 L1 14 Z" fill="currentColor"/></symbol>
    <symbol id="m-unread" viewBox="0 0 14 14"><circle cx="7" cy="7" r="5.8" fill="none" stroke="currentColor" stroke-width="2.4"/></symbol>
    <symbol id="g-ahead" viewBox="0 0 12 12"><circle cx="6" cy="6" r="4.6" fill="none" stroke="currentColor" stroke-width="1.3"/></symbol>
    <symbol id="g-prog" viewBox="0 0 12 12"><circle cx="6" cy="6" r="4.6" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M6 1.4A4.6 4.6 0 0 0 6 10.6Z" fill="currentColor"/></symbol>
    <symbol id="g-held" viewBox="0 0 12 12"><circle cx="6" cy="6" r="4.6" fill="none" stroke="currentColor" stroke-width="1.3"/><rect x="4" y="3.6" width="1.4" height="4.8" fill="currentColor"/><rect x="6.6" y="3.6" width="1.4" height="4.8" fill="currentColor"/></symbol>
    <symbol id="g-done" viewBox="0 0 12 12"><circle cx="6" cy="6" r="5.3" fill="currentColor"/><path d="M3.4 6.2 5.3 8 8.7 4.4" fill="none" stroke="var(--bg-chrome)" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></symbol>
    <symbol id="g-closed" viewBox="0 0 12 12"><circle cx="6" cy="6" r="5.3" fill="currentColor"/><rect x="3.2" y="5.3" width="5.6" height="1.4" fill="var(--bg-chrome)"/></symbol>
    <symbol id="g-pr" viewBox="0 0 12 12"><circle cx="3" cy="2.5" r="1.5" fill="none" stroke="currentColor" stroke-width="1.2"/><circle cx="3" cy="9.5" r="1.5" fill="none" stroke="currentColor" stroke-width="1.2"/><circle cx="9" cy="9.5" r="1.5" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M3 4v4M9 8V5.5a1.5 1.5 0 0 0-1.5-1.5H6" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M7.2 2.5 5.8 4l1.4 1.5" fill="none" stroke="currentColor" stroke-width="1.2"/></symbol>
    <symbol id="g-attn" viewBox="0 0 12 12"><circle cx="6" cy="6" r="4.6" fill="none" stroke="currentColor" stroke-width="1.3"/><rect x="5.3" y="3" width="1.4" height="3.6" fill="currentColor"/><rect x="5.3" y="7.6" width="1.4" height="1.4" fill="currentColor"/></symbol>
    <symbol id="g-pause" viewBox="0 0 10 10"><rect x="2.2" y="1.8" width="2" height="6.4" fill="currentColor"/><rect x="5.8" y="1.8" width="2" height="6.4" fill="currentColor"/></symbol>
    <symbol id="chev-r" viewBox="0 0 8 8"><path d="M2.5 1 5.5 4 2.5 7" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></symbol>
    <symbol id="chev-d" viewBox="0 0 8 8"><path d="M1 2.5 4 5.5 7 2.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></symbol>
    <symbol id="chev-u" viewBox="0 0 8 8"><path d="M1 5.5 4 2.5 7 5.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></symbol>
    <symbol id="i-sidebar" viewBox="0 0 14 14"><rect x="1" y="2" width="12" height="10" rx="2" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M5 2v10" stroke="currentColor" stroke-width="1.2"/></symbol>
    <symbol id="i-cockpit" viewBox="0 0 14 14"><rect x="1" y="2" width="12" height="10" rx="2" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M9 2v10" stroke="currentColor" stroke-width="1.2"/></symbol>
    <symbol id="i-term" viewBox="0 0 14 14"><rect x="1" y="2" width="12" height="10" rx="2" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M3.5 5l2 2-2 2M7 9h3" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/></symbol>
    <symbol id="i-shell" viewBox="0 0 14 14"><path d="M2 3l4 4-4 4M7 11h5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></symbol>
    <symbol id="i-laptop" viewBox="0 0 14 14"><rect x="2.5" y="2.5" width="9" height="6.5" rx="1" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M1 11h12" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/></symbol>
    <symbol id="i-doc" viewBox="0 0 14 14"><path d="M3.5 1.5h5l3 3v8h-8z" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/><path d="M5.5 7h4M5.5 9.5h4" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"/></symbol>
    <symbol id="i-refresh" viewBox="0 0 12 12"><path d="M10 6a4 4 0 1 1-1.2-2.9" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/><path d="M9.5 1v2.5H7" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/></symbol>
    <symbol id="i-copy" viewBox="0 0 12 12"><rect x="4" y="4" width="6.5" height="6.5" rx="1" fill="none" stroke="currentColor" stroke-width="1.1"/><path d="M2.5 8V2.5A1 1 0 0 1 3.5 1.5H8" fill="none" stroke="currentColor" stroke-width="1.1"/></symbol>
    <symbol id="i-cmd" viewBox="0 0 12 12"><circle cx="6" cy="6" r="4.6" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M3 9 9 3" stroke="currentColor" stroke-width="1.2"/></symbol>
    <symbol id="i-rc" viewBox="0 0 12 12"><circle cx="6" cy="7" r="1.2" fill="currentColor"/><path d="M3.5 4.8a3.5 3.5 0 0 1 5 0M1.8 3a6 6 0 0 1 8.4 0" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"/></symbol>
    <symbol id="i-rc-off" viewBox="0 0 12 12"><circle cx="6" cy="7" r="1.2" fill="currentColor"/><path d="M3.5 4.8a3.5 3.5 0 0 1 5 0M1.8 3a6 6 0 0 1 8.4 0" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"/><path d="M1.5 10.5 10.5 1.5" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"/></symbol>
    <symbol id="i-gear" viewBox="0 0 12 12"><circle cx="6" cy="6" r="2" fill="none" stroke="currentColor" stroke-width="1.1"/><path d="M6 1v1.5M6 9.5V11M1 6h1.5M9.5 6H11M2.5 2.5l1 1M8.5 8.5l1 1M9.5 2.5l-1 1M3.5 8.5l-1 1" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"/></symbol>
    <symbol id="i-hex" viewBox="0 0 12 12"><path d="M6 1l4.3 2.5v5L6 11 1.7 8.5v-5z" fill="none" stroke="currentColor" stroke-width="1.1"/></symbol>
    <symbol id="i-plus" viewBox="0 0 12 12"><path d="M6 2v8M2 6h8" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></symbol>
    <symbol id="i-dots" viewBox="0 0 12 12"><circle cx="2.5" cy="6" r="1.1" fill="currentColor"/><circle cx="6" cy="6" r="1.1" fill="currentColor"/><circle cx="9.5" cy="6" r="1.1" fill="currentColor"/></symbol>
    <symbol id="i-x" viewBox="0 0 12 12"><path d="M3 3l6 6M9 3l-6 6" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></symbol>
    <symbol id="i-stop" viewBox="0 0 12 12"><rect x="3" y="3" width="6" height="6" rx="1" fill="currentColor"/></symbol>
  </defs>
</svg>
"""

HEAD = """<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
{css}
</style>
"""

PAGES = [
    ("index.html", "Overview"),
    ("01-window.html", "The window at rest"),
    ("02-cockpit.html", "The cockpit"),
    ("03-rail.html", "The rail"),
    ("04-narrow.html", "Narrow widths"),
    ("05-states.html", "States"),
]


def nav(here):
    return '<p class="nav">' + "".join(
        f'<a href="{f}" class="{"here" if f == here else ""}">{t}</a>' for f, t in PAGES
    ) + "</p>"


def use(sym, cls=""):
    return f'<svg class="{cls}" aria-hidden="true"><use href="#{sym}"/></svg>'


# ---------------------------------------------------------------------------
# The rail. Crews as they stood on the mini's tmux on 2026-09-04; each crew's
# theme is one of ThemeCatalog's ten, so the hue is the theme's.
# ---------------------------------------------------------------------------

CREWS = [
    ("steward", "Steward", 29, "busy", {}),
    ("vivy", "Vivy", 145, "listening", {}),
    ("vivy-commercial", "Vivy Commercial", 68, "ready", {}),
    ("constance", "Constance", 275, "off", {}),
    ("deck", "Deck", 240, "listening", {"sel": True}),
    ("ask", "Ask", 95, "needs", {"expanded": True, "children": [("ask--audio", "Audio", "listening", {})]}),
    ("bosun", "Bosun", 178, "ready", {}),
    ("library", "Library", 305, "ready", {"count": 1}),
    ("orient", "Orient", 205, "unread", {}),
    ("selector", "Selector", 350, "ready", {}),
]

# The same crews with every discovered session the mini listed drawn as a
# child: Deck's own scratch shells group under their crews by path, so the
# rail at full disclosure is 22 rows. Used for the overflow frame only.
DISCOVERED_SHELLS = {"ask": ["deck-shell-ask"], "bosun": ["deck-shell-bosun"], "deck": ["deck-shell-deck"],
                     "library": ["deck-shell-library"], "orient": ["deck-shell-orient"], "selector": ["deck-shell-selector"],
                     "steward": ["deck-shell-steward"], "vivy": ["deck-shell-vivy"], "vivy-commercial": ["deck-shell-vivy-commercial"]}

MARK_SYMBOL = {"busy": "m-busy", "listening": "m-listening", "ready": "m-ready", "needs": "m-needs",
               "unread": "m-unread", "off": "m-ready", "start": "m-start"}
MARK_LABEL = {"busy": "working", "listening": "agents running", "ready": "ready", "needs": "needs an answer",
              "unread": "state unknown", "off": "stopped", "start": "not running; activate to start", "term": "a terminal with no agent"}


def mark(kind, hue, would=False, label=None):
    lab = label or MARK_LABEL[kind]
    if kind == "term":
        return f'<span class="mark term{" would" if would else ""} hue-{hue}" role="img" aria-label="{lab}">⊞</span>'
    cls = {"off": "off"}.get(kind, kind)
    return f'<span class="mark {cls} hue-{hue}" role="img" aria-label="{lab}">{use(MARK_SYMBOL[kind])}</span>'


def rail(mode="full", show_other=True, overflow=False, new_button=True, hidden_summons=False):
    dots = mode == "dots"
    out = [f'<aside class="rail{" dots" if dots else ""}" aria-label="Sessions">', '<div class="list">']
    def row(cls, hue, m, name, trail="", child=False, last=False, title=True, aria=""):
        c = ["row"] + cls + (["child"] if child else []) + (["last"] if last else [])
        t = f' title="{name}"' if dots and title else ""
        return (f'<div class="{" ".join(c)} hue-{hue}"{t}{aria}>{m}'
                + ("" if dots else f'<span class="name">{name}</span>{trail}') + "</div>")
    for cid, name, hue, mk, x in CREWS:
        classes = []
        if x.get("sel"): classes.append("sel")
        if mk == "off": classes.append("off")
        summons = '<i class="summons" aria-hidden="true"></i>' if mk == "needs" else ""
        kids = list(x.get("children", []))
        if overflow:
            kids += [(s, s, "term", {}) for s in DISCOVERED_SHELLS.get(cid, [])]
        expanded = x.get("expanded") or (overflow and kids)
        trail = ""
        if not dots:
            if expanded:
                trail = f'<span class="trail">{use("chev-d")}</span>'
            elif x.get("count") or kids:
                trail = f'<span class="trail">{x.get("count") or len(kids)}{use("chev-r")}</span>'
        out.append(row(classes, hue, summons + mark(mk, hue), name, trail,
                       aria=f' aria-label="{name}, {MARK_LABEL[mk]}{", selected" if x.get("sel") else ""}"'))
        if expanded:
            for i, (kid, kname, kmk, kx) in enumerate(kids):
                out.append(row([], hue, mark(kmk, hue), kname, child=True, last=i == len(kids) - 1))
    if show_other:
        out.append('<div class="sect sectlabel" aria-label="Other sessions">Other sessions</div>')
        for name in ("Car", "Tennis"):
            out.append(row([], 95, mark("term", 95, would=True), name))
    out.append('<div class="sect sectlabel" aria-label="Start">Start</div>')
    for name, hue in (("NYH Studio", 350), ("Write Better", 178)):
        out.append(row(["off"], hue, mark("start", hue), name, aria=f' aria-label="{name}, not running; activate to start"'))
    if hidden_summons:
        out.append(f'<div class="offscreen" role="button" aria-label="1 session below needs an answer; activate to scroll to it"><i></i>{use("chev-d")}<span>1 needs you</span></div>')
    out.append("</div>")  # list
    out.append(
        '<div class="foot"><div class="bead" role="button" aria-label="Open this project\'s bead: Deck — where the cockpit is going. 5 of 11 epics closed. Course reordered 4 days ago.">'
        '<div class="sectlabel">Bead</div>'
        '<div class="t">Deck — where the cockpit is going, and where it is now</div>'
        '<div class="meter" aria-hidden="true"><i style="width:45%"></i></div>'
        '<div class="f"><span>5 of 11 epics</span><span>reordered 4d ago</span></div>'
        "</div>"
        + (f'<div class="newbtn" role="button">{use("i-plus")}<span>New</span></div>' if new_button else "")
        + "</div>"
    )
    out.append("</aside>")
    return "\n".join(out)


# ---------------------------------------------------------------------------
# The centre column.
# ---------------------------------------------------------------------------

def titlebar(occupant="cockpit", rail_on=True, narrow=False, queue_badge=False, terminal_on=False, cockpit_hidden=False):
    def seg_item(key, icon, label, badge=""):
        on = "on" if (occupant == key and not cockpit_hidden) else ""
        return (f'<span class="{on}" role="radio" aria-checked="{"true" if on else "false"}" aria-label="{label}">{use(icon)}'
                + ("" if narrow else f"<span>{label}</span>") + badge + "</span>")
    badge = '<span class="badge" aria-label="23 items in the corrections queue, 1 high">23</span>' if (cockpit_hidden and queue_badge) else ""
    segs = [seg_item("cockpit", "i-cockpit", "Cockpit", badge), seg_item("shell", "i-shell", "Shell"),
            seg_item("local", "i-laptop", "Local"), seg_item("slate", "i-slate", "Slate")]
    if occupant in ("item", "viewer", "editor"):
        segs.append(f'<span class="on doc" role="radio" aria-checked="true">{use("i-doc")}<span>{ {"item": "Item", "viewer": "Viewer", "editor": "Editor"}[occupant] }</span></span>')
    right = [
        f'<span class="tbtn{" on" if terminal_on else ""}" title="Terminal View (a main-pane swap, independent of the column)">{use("i-term")}' + ("" if narrow else "<span>Terminal View</span>") + "</span>",
        f'<span class="seg" role="radiogroup" aria-label="Right column">{"".join(segs)}</span>',
        f'<span class="tbtn" title="Session actions: Re-render the conversation · Stop session…">{use("i-dots")}</span>',
    ]
    return (
        '<div class="titlebar">'
        f'<div class="tb-left"><div class="lights"><i></i><i></i><i></i></div>'
        f'<span class="tbtn sidebar{" on" if rail_on else ""}" title="Show or hide the rail">{use("i-sidebar")}</span></div>'
        '<div class="tb-title">Deck <span>· operator@mini</span></div>'
        f'<div class="tb-right">{"".join(right)}</div>'
        "</div>"
    )


def session_row(compact=False, status=None, status_err=False, working=True, stale=False, vitals=True,
                tier="ok", rc_off=False, vitals_stale=False, mark_kind="listening", working_stale=False):
    vit = "compact" if compact else ""
    if status is not None:
        mid = f'<div class="status{" err" if status_err else ""}" title="{status}">{status}</div>'
    elif working:
        age = '<span class="age stale">· 47m ago</span>' if working_stale else '<span class="age">· 47m</span>'
        mid = f'<div class="working"><span class="txt">revising PR #143 on the reviewer\'s stderr-classifier finding</span>{age}</div>'
    else:
        mid = '<div class="working"></div>'
    v = ""
    if vitals:
        parts = [
            f'<span class="vit keep" title="Context: 82K of 200K tokens{" — past the soft limit" if tier == "soft" else ""}"><span class="ctx {tier}"><span class="meter"><i style="width:{41 if tier == "ok" else 78}%"></i></span><span class="mono num">{"82K" if tier == "ok" else "156K"}/200K</span></span></span>',
            f'<span class="vit" title="The model answering in this session · billing the max subscription">{use("i-hex")}opus 4.1</span>',
        ]
        # BOTH STATES, DELIBERATELY (the operator, 2026-09-05). A badge that appears only
        # in one state cannot be told apart from a badge that has not loaded, and
        # `SessionPaneView.VitalsRow` has carried that reasoning in a comment for
        # longer than this spec has existed. Off wears `--warn`; on is a resting
        # state and wears the ordinary meta ink, so off is still the legible one.
        if rc_off:
            parts.append(f'<span class="vit warn" title="Remote control is off — this session is not reachable from your phone">{use("i-rc-off")}rc off</span>')
        else:
            parts.append(f'<span class="vit" title="Remote control is on — this session is reachable from your phone">{use("i-rc")}rc</span>')
        parts += [
            f'<span class="vit" title="Dispatched agents alive for this repo: deck-reviewer · deck-security-reviewer">{use("i-gear")}2 in flight</span>',
            f'<span class="vit pr" title="Working on https://github.com/convivy/convivy-deck/pull/143 · review returned changes requested">{use("g-pr")}#143 · changes requested</span>',
        ]
        if vitals_stale:
            parts.append('<span class="vit asof" title="The terminal has not redrawn since; these numbers are that old">· as of 4m ago</span>')
        v = f'<div class="vitals {vit}">{"".join(parts)}</div>'
    return f'<div class="sess">{"".join([f"<div class=\"who\">{mark(mark_kind, 240)}<b>Deck</b></div>", mid, v])}</div>'


def convo(veiled=False, held=False):
    chev = use("chev-r")
    held_turn = ""
    if held:
        held_turn = f'<div class="turn you held"><div class="whom">you <time>10:58</time> · held</div><div class="msg"><p>when the reviewers return, post both verdicts here before you push anything</p></div></div>'
    return f"""
<div class="convo{" veiled" if veiled else ""}">
  <div class="inner">
    <div class="turn you"><div class="whom">you <time>10:41</time></div>
      <div class="msg"><p>what's left on 143 after the reviewer's pass?</p></div></div>
    <div class="turn"><div class="whom">claude <time>10:41</time></div>
      <p>Two findings, one blocking.</p>
      <p>The blocking one is in the stderr classifier. <code>SSHStderrClassifier</code> still matches <code>No such file</code> as a missing binary, so a missing <em>file</em> on the mini reads as <code>session-agent</code> not being installed. The reviewer reproduced it with <code>read-file</code> on a path that does not exist. I have moved the match to the verb layer and added the regression test.</p>
      <div class="tool">{chev}<span class="verb">Edit</span><span>Sources/Deck/Transport/SSHStderrClassifier.swift</span></div>
      <div class="tool">{chev}<span class="verb">Bash</span><span>swift test --filter WireErrorTests</span></div>
      <p>The non-blocking one is the envelope decode: the reviewer wants all nine error kinds pinned by a test that feeds each through <code>WireError.decode</code>, rather than the three the PR covered. Done, same commit.</p>
      <p>CI is green on the commit: <code>check-runs total_count: 3</code>, all <code>success</code>. Next I'll re-dispatch both reviewers on <code>a41c0e2</code> and background the wait.</p></div>
    <div class="turn you"><div class="whom">you <time>10:52</time></div>
      <div class="msg"><p>go</p></div></div>
    <div class="turn"><div class="whom">claude <time>10:52</time></div>
      <div class="tool">{chev}<span class="verb">Bash</span><span>agentctl spawn deck-reviewer --on convivy-deck --pr 143</span></div>
      <div class="tool">{chev}<span class="verb">Bash</span><span>agentctl spawn deck-security-reviewer --on convivy-deck --pr 143</span></div>
      <div class="tool">{chev}<span class="verb">Bash</span><span>agentctl wait run_01M1NC… run_01M1ND…</span></div>
      <p>Both reviewers are on <code>a41c0e2</code>; the waiter is watching them. Nothing to push until they return.<span class="cursor" aria-hidden="true"></span></p></div>
    {held_turn}
  </div>
  <div class="fade"></div>
</div>"""


def operator(compact=False, kind="composer", held=0, background=False, last_error=None, live=("listening", "Agents working", "· quiet 34s")):
    c = " compact" if compact else ""
    mk, state, quiet = live
    extras = ""
    if background:
        extras += '<span class="bg" title="A subagent is still writing while the main agent waits"><i></i>working in the background</span>'
    if last_error:
        extras += f'<span class="err" title="{last_error}">{last_error}</span>'
    live_row = f'<div class="live">{mark(mk, 240)}<span class="state">{state}</span><span class="quiet">{quiet}</span>{extras}</div>'
    if kind == "composer":
        held_html = f'<span class="held">{held} held<span class="btn ghost" style="height:20px;padding:0 6px">Rewrite</span></span>' if held else ""
        body = f"""
  <div class="composer{c}">
    <div class="text"><span class="ph">Message Deck…</span></div>
    <div class="bar">
      <span class="cmd">{use("i-cmd")}<span>Commands</span>{use("chev-d")}</span>{held_html}
      <span class="hint">↩ send · ⇧↩ new line</span>
      <span class="btn">Interrupt</span>
      <span class="btn primary">Send</span>
    </div>
  </div>"""
    elif kind == "fallback-unknown":
        body = '<div class="fallback">Deck cannot read this session\'s state.<span class="btn">Open terminal</span></div>'
    elif kind == "fallback-blocked":
        body = '<div class="fallback">This session is waiting on something the pane cannot show.<span class="btn">Open terminal</span></div>'
    elif kind == "gate":
        body = f"""
  <div class="gate" role="group" aria-label="Question from the session">
    <div class="gh"><span class="sectlabel">Bash command</span></div>
    <div class="q">Claude wants to run <code>swift test --filter WireErrorTests</code>. Do you want to proceed?</div>
    <div class="opt rec" role="button"><span class="n">1</span><span class="l">Yes</span><span class="k" title="Approved 2026-09-05, not yet built">⌘1</span></div>
    <div class="opt" role="button"><span class="n">2</span><span class="l">Yes, and don't ask again for <code>swift test</code> commands in this project<div class="d">Offered here; the rule itself is taken in the terminal.</div></span><span class="k" title="Approved 2026-09-05, not yet built">⌘2</span></div>
    <div class="opt" role="button"><span class="n">3</span><span class="l">No, and tell Claude what to do differently</span><span class="k" title="Approved 2026-09-05, not yet built">⌘3</span></div>
    <div class="foot">A “don’t ask again” rule is offered here; take that in the terminal.<span class="btn">Open terminal</span></div>
  </div>"""
    return f'<div class="oper">{live_row}{body}</div>'


# ---------------------------------------------------------------------------
# The Course: one list, from which the cockpit rows AND the ribbon derive.
# state → CockpitView.rowTreatment; the ribbon's three states come from
# WaypointRibbon.waypointStyle (done / current / everything else), where
# "current" is the first in-progress entry (currentId).
# ---------------------------------------------------------------------------

COURSE = [
    # (state, title, short_description, meta)
    ("fixed", "The input pane is redesigned — beautiful, legible at a glance, and honest about what each control does", "The input pane redesigned", {}),
    ("fixed", "Deck runs for someone who is not the operator — stop compiling one operator's environment into the binary", "Runs for someone not the operator", {}),
    ("fixed", "The cockpit surface, and the panels Deck can already draw", "The cockpit surface", {}),
    ("pr-open", "Deck's client side of the Deck-to-Keel wire interface — move the verbs off ssh argv, endpoint by endpoint", "Deck-to-Keel typed wire", {"progress": "1/4", "expand": True}),
    ("fixed", "Deck draws the project's plan and its corrections queue from the Chart House", "Plan and corrections", {}),
    ("open", "The cockpit lists the documents that came with the checkout, each opening in the side pane", "Checkout documents", {}),
    ("open", "The cockpit shows where every PR actually stands, not just its review verdict", "Where every PR stands", {}),
    ("claimed", "Crew stats — a line per agent in flight, whatever individuated it", "Crew stats per agent", {"progress": "1/2", "held": 1}),
    ("open", "A person merges or closes a PR from the cockpit, and the Keel performs it", "Merge from the cockpit", {}),
    ("fixed", "Deck gets a real release mechanism — signed, versioned builds a second operator installs and updates deliberately", "A real release mechanism", {}),
    ("open", "A new installation is Convivy Builder, not Deck — one integrated install of Deck, Orient, the Keel and a Steward", "Convivy Builder install", {}),
]

def treatment(state):
    if state == "fixed": return "done"
    if state in ("wontfix", "duplicate", "redirected"): return "closed"
    if state == "parked": return "held"
    return "ahead" if state in (None, "open") else "prog"

def current_index():
    for i, (s, *_ ) in enumerate(COURSE):
        if treatment(s) == "prog": return i
    for i, (s, *_ ) in enumerate(COURSE):
        if treatment(s) not in ("done", "closed", "held"): return i
    return None


def ribbon():
    cur = current_index()
    parts = []
    for i, (state, title, short, meta) in enumerate(COURSE):
        t = treatment(state)
        cls = "done" if t in ("done", "closed") else ("cur" if i == cur else "ahead")
        halo = '<i class="halo" aria-hidden="true"></i>' if cls == "cur" else ""
        aria = f"{short}, work in progress" if cls == "cur" else short
        parts.append(f'<span class="wp {cls}" title="{title}" aria-label="{aria}"><span class="dot">{halo}</span><span class="lbl">{short}</span></span>')
        if i < len(COURSE) - 1:
            parts.append('<span class="rule"></span>')
    pos = f'<span class="pos" aria-label="waypoint {cur + 1} of {len(COURSE)}">waypoint {cur + 1}</span>' if cur is not None else ""
    return f'<div class="ribbon" role="navigation" aria-label="The Course as a route"><div class="scroll">{"".join(parts)}</div>{pos}</div>'


def centre(compact=False, ribbon_on=True, sess=None, conv=None, oper=None):
    return (f'<main class="centre{"" if ribbon_on else " no-ribbon"}">'
            + (sess if sess is not None else session_row(compact))
            + (conv if conv is not None else convo())
            + (oper if oper is not None else operator(compact))
            + (ribbon() if ribbon_on else "") + "</main>")


def terminal_centre():
    body = f"""<main class="centre no-ribbon" style="grid-template-rows:34px auto 1fr">
{session_row()}
<div class="termhdr"><span>Terminal View</span><span class="btn">Back to Session View</span></div>
<div class="rawterm"><span class="p">╭─</span> deck ~/Convivy/convivy-deck (agent/deck-coder-wire-verbs)
<span class="p">╰─</span> $ swift test --filter WireErrorTests
Building for debugging...
[9/9] Compiling DeckTests WireErrorTests.swift
Test Suite 'WireErrorTests' passed at 2026-09-04 10:49:12.
     Executed 9 tests, with 0 failures (0 unexpected) in 0.041s
<span class="p">╰─</span> $ █</div>
</main>"""
    return body


# ---------------------------------------------------------------------------
# The cockpit.
# ---------------------------------------------------------------------------

def glyph(kind):
    sym = {"ahead": "g-ahead", "prog": "g-prog", "held": "g-held", "done": "g-done", "closed": "g-closed", "pr": "g-pr", "attn": "g-attn"}[kind]
    return f'<span class="g {kind}" aria-hidden="true">{use(sym)}</span>'

PREFIX = {"ahead": "ahead", "prog": "in progress", "held": "held", "done": "done", "closed": "closed without change",
          "pr": "pull request open", "attn": "needs attention"}


def crow(kind, title, meta="", extra_cls="", hover=False, aria=None):
    cls = f"crow {kind}{' ' + extra_cls if extra_cls else ''}{' hover' if hover else ''}"
    copy = use("i-copy", "copy") if hover else ""
    m = f'<span class="m">{copy}{meta}</span>' if (meta or hover) else ""
    label = aria or f"{PREFIX[kind]}, {title}"
    return f'<div class="{cls}" role="button" aria-label="{label}">{glyph(kind)}<span class="t">{title}</span>{m}</div>'


def panel_header(title, count="", act="", collapsed=False, count_aria=""):
    chev = use("chev-r" if collapsed else "chev-d", "chev")
    trail = f'<span class="act">{act}</span>' if act else (f'<span class="cnt" aria-label="{count_aria or count}">{count}</span>' if count else "")
    return f'<div class="ph" role="button" aria-label="{title}, {"collapsed" if collapsed else "expanded"}. Activate to {"expand" if collapsed else "collapse"}.">{chev}<span class="sectlabel">{title}</span>{trail}</div>'


def dispatched(empty=False, unreported=False):
    if unreported:
        body = '<div class="empty">This mini doesn\'t report agent runs yet.</div>'
    elif empty:
        body = '<div class="empty">No agents in flight.</div>'
    else:
        body = f"""
  <div class="crow run" aria-label="in progress, deck-reviewer, opus 4.1, running 12 minutes">{glyph("prog")}<span class="t"><b>deck-reviewer</b><div class="task">Review PR #143 for correctness and fidelity to intent: the envelope decode, the nine-kind error taxonomy, and whether the contract doc moved with it</div></span><span class="m num">opus 4.1 · 12m</span></div>
  <div class="crow run" aria-label="in progress, deck-security-reviewer, opus 4.1, running 12 minutes">{glyph("prog")}<span class="t"><b>deck-security-reviewer</b><div class="task">Security review of PR #143: the socket surface, the stderr-classifier removal, and credential handling on the wire</div></span><span class="m num">opus 4.1 · 12m</span></div>"""
    return f'<section class="panel" id="dispatched">{panel_header("Dispatched", "" if (empty or unreported) else "2", count_aria="2 agents in flight")}{body}<div class="foot">Runs started through the Task tool aren\'t tracked here.</div></section>'


def proposals(empty=False):
    act = f'<span class="btn ghost" style="height:22px;padding:0 6px" role="button" aria-label="Propose a new epic">{use("i-plus")}</span>'
    if empty:
        body = '<div class="empty">No proposals awaiting a decision.</div>'
    else:
        body = """
  <div class="prop">
    <div class="t">Multiplayer — several people in one session, each participant's input attributed</div>
    <div class="b">The session's owner invites others, who participate through their own Deck. Each participant's input is prefixed with <code>[NAME]:</code> so the transcript carries attribution and the co can tell who asked for what. The owner tells the co how to treat a given participant's requests.</div>
    <div class="acts"><span class="btn">Approve</span><span class="btn ghost">Decline…</span></div>
  </div>"""
    return f'<section class="panel" id="proposals">{panel_header("Proposals", act=act)}{body}</section>'


def course_panel(expanded=True, children="loaded", empty=False):
    if empty:
        return f'<section class="panel" id="course">{panel_header("Course", "")}<div class="empty">Nothing on the Course yet.</div></section>'
    chev_open, chev_closed = use("chev-d", "chev"), use("chev-r", "chev")
    rows = [f'<div class="affordance" role="button" aria-label="1 more closed epic hidden. Activate to show it.">{use("chev-u")}1 more closed epic</div>']
    for i, (state, title, short, meta) in enumerate(COURSE):
        if i == 0: continue   # the collapsed head
        t = treatment(state)
        m = ""
        if meta.get("held"):
            m += f'<span class="held" title="{meta["held"]} held">{use("g-pause")}{meta["held"]}</span>'
        if meta.get("progress"):
            m += f'<span class="num">{meta["progress"]}</span>'
        is_exp = expanded and meta.get("expand")
        m += chev_open if is_exp else chev_closed
        aria = f"{PREFIX[t]}, {title}" + (f", {meta['progress'].replace('/', ' of ')} settled" if meta.get("progress") else "") + (f", {meta['held']} held" if meta.get("held") else "")
        rows.append(crow(t, title, m, hover=is_exp, aria=aria))
        if is_exp:
            if children == "loading":
                kids = '<div class="loading"><i></i>Loading work items…</div>'
            elif children == "none":
                kids = '<div class="empty">No work items filed under this epic yet.</div>'
            else:
                kids = f"""<div class="kids">
      {crow("done", "Shared envelope and nine-kind error taxonomy client stack")}
      {crow("ahead", "host-name replaces <code>hostname -s</code> through a login shell")}
      {crow("ahead", "Move the session-agent verbs onto the wire, verb by verb")}
      {crow("ahead", "state and states carry held, and held never reaches the Archives")}
    </div>"""
            rows.append(f"""
  <div class="epic">
    <div class="state">Pr-open · epic · PR #143</div>
    <div class="cap"><b>Done when:</b> <code style="font:10.5px var(--font-mono)">host-name</code> is served and Deck calls it instead of <code style="font:10.5px var(--font-mono)">hostname -s</code>, verified by confirming no login shell is invoked for a host probe. Each migrated verb is cut over individually with the ssh path still working for the others — no flag day, verified by exercising a migrated and an unmigrated verb</div>
    <div class="more" role="button">more</div>
    <div class="meta">Severity: medium · Claimed by: co-convivy-deck-2237</div>
    {kids}
  </div>""")
    done = sum(1 for s, *_ in COURSE if treatment(s) in ("done", "closed"))
    return f'<section class="panel" id="course">{panel_header("Course", f"{done} / {len(COURSE)}", count_aria=f"{done} of {len(COURSE)} epics settled")}{"".join(rows)}</section>'


def queue(error=False):
    if error:
        body = '<div class="empty err">Could not reach the queue: ssh: connect to host mini port 22: Operation timed out</div>'
    else:
        body = f"""
  {crow("pr", "Deck's client side of the Deck-to-Keel wire interface — move the verbs off ssh argv, endpoint by endpoint", '<span class="num">#143</span>', hover=True, aria="pull request open, #143, Deck's client side of the Deck-to-Keel wire interface")}
  {crow("attn", "A stale pinned rail row is indistinguishable from a live one, and selecting it recreates the session", '<span class="sev" aria-label="severity high">high</span>', aria="needs attention, severity high, A stale pinned rail row is indistinguishable from a live one")}
  {crow("attn", "The missing-directory gate misses two cases: spawning a new child, and a directory that is present but invalid")}
  {crow("attn", "Deck should read crew specs written by the steward, so creation has one path")}
  {crow("attn", "Adopting a session into a crew silently removes its only Stop control")}
  <div class="affordance" role="button" aria-label="18 more items hidden. Activate to show them.">{use("chev-d")}18 more</div>"""
    return f'<section class="panel" id="queue">{panel_header("Corrections queue", "23", count_aria="23 items, 1 high")}{body}</section>'


CLOSE_ICON = '<span class="btn ghost" style="height:22px" role="button" aria-label="Close and return to the cockpit">{}</span>'

def band(kind, icon, title, place="", trailing=""):
    """A right-column band. kind is "neutral" (the Cockpit), "crew" (a crew's identity) or "graphite" (the laptop)."""
    cls = {"neutral": "band", "crew": "band crew", "graphite": "band gr"}[kind]
    place_html = f'<span class="bp" title="{place}">{place}</span>' if place else '<span class="bp"></span>'
    return (f'<div class="{cls}"><span class="bi">{use(icon)}</span><span class="bt">{title}</span>'
            f'{place_html}<span class="tr">{trailing}</span></div>')

def cockpit_head(here="dispatched", collapsed=(), counts=None, close=False):
    counts = counts or {"dispatched": "2", "proposals": "1", "course": "5/11", "queue": "23"}
    aria = {"dispatched": "Dispatched, 2 agents in flight", "proposals": "Proposals, 1 awaiting a decision",
            "course": "Course, 5 of 11 epics settled", "queue": "Corrections queue, 23 items, 1 high"}
    def a(key, label, n, hot=False):
        cls = " ".join(filter(None, ["here" if key == here else "", "collapsed" if key in collapsed else ""]))
        return f'<a href="#{key}" class="{cls}" role="button" aria-label="{aria[key]}. Activate to scroll to it."><b>{label}</b><span class="n{" hot" if hot else ""}">{n}</span></a>'
    idx = (a("dispatched", "Dispatched", counts["dispatched"]) + a("proposals", "Proposals", counts["proposals"])
           + a("course", "Course", counts["course"]) + a("queue", "Queue", counts["queue"], hot=counts["queue"] not in ("", "—", "0")))
    refresh = '<span class="asof" role="button" aria-label="Refreshed 12 seconds ago. Activate to refresh now (⌘R).">' + use("i-refresh") + '12s</span>'
    closebtn = CLOSE_ICON.format(use("i-x")) if close else ""
    return f"""
  <div class="head">
    {band("neutral", "i-cockpit", "Cockpit", "convivy-deck", refresh + closebtn)}
    <div class="index" role="navigation" aria-label="Panels">{idx}</div>
  </div>"""


def cockpit(expanded=True, as_sheet=False, variant="full"):
    tag = "sheet cockpit" if as_sheet else "cockpit"
    if variant == "unresolved":
        return f'<aside class="{tag}"><div class="unresolved">Select a session to see its project\'s cockpit.</div></aside>'
    if variant == "degraded":
        body = dispatched(empty=True) + proposals(empty=True) + course_panel(expanded=True, children="loading") + queue(error=True)
        head = cockpit_head(here="course", counts={"dispatched": "0", "proposals": "0", "course": "5/11", "queue": "—"})
    elif variant == "empty-course":
        body = dispatched(unreported=True) + proposals(empty=True) + course_panel(empty=True) + queue()
        head = cockpit_head(here="course", counts={"dispatched": "—", "proposals": "0", "course": "—", "queue": "23"})
    elif variant == "no-children":
        body = dispatched() + proposals() + course_panel(expanded=True, children="none") + queue()
        head = cockpit_head(here="course")
    elif variant == "collapsed":
        body = ('<section class="panel" id="dispatched">' + panel_header("Dispatched", "2", collapsed=True) + "</section>"
                + '<section class="panel" id="proposals">' + panel_header("Proposals", "1", collapsed=True) + "</section>"
                + course_panel(expanded=False) + queue())
        head = cockpit_head(here="course", collapsed=("dispatched", "proposals"))
    else:
        body = dispatched() + proposals() + course_panel(expanded) + queue()
        head = cockpit_head()
    return f'<aside class="{tag}" aria-label="Cockpit">{head}<div class="scroll">{body}</div></aside>'


def shell_pane(as_sheet=False):
    tag = "sheet cockpit" if as_sheet else "cockpit"
    return f"""
<aside class="{tag} shell" aria-label="Shell">
  {band("crew", "i-shell", "Shell", "operator@macstudio", CLOSE_ICON.format(use("i-x")))}
  <div class="tbody">
    <div><span class="dim">operator@macstudio</span> ~/Convivy/convivy-deck <span class="dim">main</span></div>
    <div><span class="dim">$</span> git status --short</div>
    <div>M Sources/Deck/App/ContentView.swift</div>
    <div>?? Sources/Deck/App/ColumnBand.swift</div>
    <div><span class="dim">$</span> <span style="opacity:.6">▌</span></div>
  </div>
</aside>"""

def local_pane(as_sheet=False):
    tag = "sheet cockpit" if as_sheet else "cockpit"
    return f"""
<aside class="{tag} local" aria-label="Local terminal">
  {band("graphite", "i-laptop", "Local", "this Mac", CLOSE_ICON.format(use("i-x")))}
  <div class="tbody gr">
    <div><span class="dim">operator@mini</span> ~ <span class="dim">%</span> ls</div>
    <div>Applications&nbsp;&nbsp;Convivy&nbsp;&nbsp;Documents</div>
    <div><span class="dim">operator@mini</span> ~ <span class="dim">%</span> <span style="opacity:.6">▌</span></div>
  </div>
</aside>"""

def slate_pane(as_sheet=False):
    tag = "sheet cockpit" if as_sheet else "cockpit"
    new_note = '<span class="btn" style="height:22px" role="button">New Note</span>'
    return f"""
<aside class="{tag} slate" aria-label="Slate">
  {band("crew", "i-slate", "Slate", "deck-coder on macstudio", new_note + CLOSE_ICON.format(use("i-x")))}
  <div class="sbody">
    <div class="card">
      <div class="cid">a-7f3k2 <span class="flag">Waiting on you</span></div>
      <div>Ship build 812 to Guest's laptop today?</div>
    </div>
    <div class="card">
      <div class="cid">n-22abk · draft</div>
      <div>Ask Deck for the rail list before a bulk relaunch.</div>
    </div>
  </div>
</aside>"""

def item_pane(as_sheet=False):
    tag = "sheet item cockpit" if as_sheet else "cockpit item"
    return f"""
<aside class="{tag}" aria-label="Item detail">
  <div class="ih"><span class="t">A stale pinned rail row is indistinguishable from a live one, and selecting it recreates the session</span><span class="p">convivy-deck</span><span class="btn ghost" style="height:22px;padding:0 6px" role="button" aria-label="Close and return to the cockpit">{use("i-x")}</span></div>
  <div class="ibody">
    <p><span class="mono" style="color:var(--ink-2)">bug · severity high · open · filed 2026-09-03 by ask-53 via the steward</span></p>
    <h4>What the operator saw</h4>
    <p>Two Audio rows, identical terminal content, only one with a window behind it.</p>
    <h4>The code</h4>
    <p><code>RailView.swift:643</code> draws <code>ForEach(crew.sessions)</code>, a crew's pinned children, straight from config with no liveness check. <code>discoveredChildren(for:)</code> immediately below it comes from the live poll. So a pin whose session does not exist draws a row that looks exactly like one whose session is running.</p>
    <h4>Why this is more than a duplicate row</h4>
    <p>Attach is <code>tmux new-session -A -D -s &lt;name&gt;</code>. <code>-A</code> attaches when the session exists and <em>creates it when it does not</em>, so selecting a stale pinned row does not fail and reports nothing.</p>
    <h4>Comments</h4>
    <div class="cm"><b>ops-mcp</b> · 2026-09-04 · Related: the crew-specs task records <code>sessionId</code> at creation, which makes a stale pin detectable.</div>
  </div>
  <div class="acts"><span class="btn">Won't Do</span><span class="btn">Is Duplicate</span><span class="btn">Add Comment</span><span class="btn">Edit</span></div>
</aside>"""


def column_pane(occupant, expanded=True, variant="full", as_sheet=False):
    """The right column's pane for an occupant, docked or as a sheet."""
    if occupant == "item":
        return item_pane(as_sheet=as_sheet)
    if occupant == "shell":
        return shell_pane(as_sheet=as_sheet)
    if occupant == "local":
        return local_pane(as_sheet=as_sheet)
    if occupant == "slate":
        return slate_pane(as_sheet=as_sheet)
    return cockpit(expanded=expanded, variant=variant, as_sheet=as_sheet)


def window(theme, width=1440, height=880, rail_mode="full", occupant="cockpit", compact=False, ribbon_on=True,
           epic_expanded=True, hue=240, cockpit_variant="full", terminal=False, centre_html=None, sheet=False,
           new_button=True):
    body_cls = "body"
    if rail_mode == "dots": body_cls += " dots"
    if rail_mode == "none": body_cls += " no-rail"
    column_open = occupant in ("cockpit", "item", "shell", "local", "slate") and not sheet
    if not column_open: body_cls += " no-cockpit"
    parts = [f'<div class="win" data-theme="{theme}" data-hue="{hue}" style="--w:{width}px;--hgt:{height}px">',
             titlebar(occupant=occupant if occupant != "hidden" else "cockpit", rail_on=rail_mode == "full", narrow=compact,
                      queue_badge=occupant == "hidden", terminal_on=terminal, cockpit_hidden=occupant == "hidden")]
    parts.append(f'<div class="{body_cls}">')
    if rail_mode != "none":
        parts.append(rail(rail_mode, new_button=new_button))
    if centre_html is not None:
        parts.append(centre_html)
    elif terminal:
        parts.append(terminal_centre())
    else:
        parts.append(centre(compact=compact, ribbon_on=ribbon_on))
    if column_open:
        parts.append(column_pane(occupant, expanded=epic_expanded, variant=cockpit_variant))
    parts.append("</div>")
    if sheet:
        parts.append('<div class="scrim"></div>')
        parts.append(column_pane(occupant, expanded=epic_expanded, as_sheet=True))
    parts.append("</div>")
    return "\n".join(parts)


# THE STYLESHEET IS INLINED INTO EVERY PAGE, NOT LINKED, AND THAT IS THE POINT.
# A `<link rel="stylesheet" href="deck.css">` only resolves when the reader's
# viewer fetches a sibling file relative to the page. The operator's does
# not: on 2026-09-05 they opened one of these and got "huge icons, black and white, no
# styled text" — the SVG sprite at natural size with no CSS at all. These
# pages are the approved visual spec, read by people and by agents, and a
# spec that only renders from the directory it was generated in is not one
# anybody can be handed. `deck.css` is still written beside them, because the
# contrast table and the tooling read it as a file.
def page(fname, title, lede, sections, css):
    html = HEAD.format(title=title, css=css) + f'<div class="doc">{SYMBOLS}<h1>{title}</h1>' + nav(fname) + f'<p class="lede">{lede}</p>' + sections + "</div>\n"
    (HERE / fname).write_text(html)


def frames(*pairs):
    out = ['<div class="frames">']
    for label, html in pairs:
        out.append(f'<div><div class="frame-label">{label}</div><div class="scroller">{html}</div></div>')
    out.append("</div>")
    return "\n".join(out)


def standalone(theme, hue, inner, width, height="auto", cls=""):
    h = f"--hgt:{height}px" if height != "auto" else "--hgt:auto"
    rows = "grid-template-rows:auto" if height == "auto" else "grid-template-rows:1fr"
    return f'<div class="win {cls}" data-theme="{theme}" data-hue="{hue}" style="--w:{width}px;{h};{rows};border-radius:8px">{inner}</div>'


# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------

def build_index(css):
    rows = contrast_table()
    table = ['<table><tr><th>Theme</th><th>Hue</th><th>Pair</th><th>Ratio</th><th>Target</th></tr>']
    targets = {"white on --accent-fill (Send)": 4.5, "white on --attn-fill (badge)": 4.5, "--accent-text on chrome (waypoint, more)": 4.5,
               "--accent-mark on chrome (glyphs)": 3.0, "--prog-mark on chrome (in-progress glyph)": 3.0, "--attn-text on chrome (HIGH, PR verdict)": 4.5,
               "--attn-mark on rail (summons bar)": 3.0, "--warn on chrome (rc off, soft tier)": 4.5, "--ink-2 on chrome (every meta, timestamp, label)": 4.5,
               "--ink-3 on chrome (chevrons, rules; never text)": 3.0, "--line on chrome": 1.6, "--line-2 on chrome": 1.3,
               "crew mark 68 on rail": 3.0, "crew mark 240 on selected wash": 3.0,
               "--band-place on the crew band (place line)": 4.5, "--band-ink on the crew band (icon, rule)": 3.0,
               "--neutral-place on chrome (Cockpit place line)": 4.5, "--gr-place on the graphite band (place line)": 4.5,
               "--gr-ink on the graphite band (icon, rule)": 3.0, "--canvas-place on the Slate canvas (card ids)": 4.5}
    for theme, H, name, ratio in rows:
        tgt = targets[name]
        ok = ratio >= tgt - 0.005
        table.append(f'<tr><td>{theme}</td><td class="n">{H}</td><td>{name}</td><td class="n {"pass" if ok else "fail"}">{ratio:.2f}</td><td class="n">{tgt}</td></tr>')
    table.append("</table>")

    body = f"""
<h2>The thesis</h2>
<p class="note"><b>Deck is an instrument panel around a document.</b> The native chrome (rail, session row, operator row, ribbon, cockpit) is flat, on hairlines, in one type family; the conversation, the one web pane in the window, is a document, which is how <code>session_view.py</code> already draws it. The redesign's job is the instrument panel.</p>
<p class="note"><b>One accent for in-progress marks, and it is the crew's hue.</b> The code already rules that "shape carries identity, not colour alone" (<code>CockpitView.RowTreatment</code>) and that a rail row's dot is its crew's theme accent (<code>RailRow</code>). The redesign drops <code>Color.accentColor</code>, the system blue, from every in-progress mark (the half-filled glyph, the pull-request glyph, the current waypoint, Send) and gives them the selected crew's hue instead. Everything else keeps the colour it has: the rail's ten identity hues, the summons orange, the amber caution, red for errors, green for a pass. This is the one sentence the earlier draft's "one colour" overstated, and it is the sentence the mocks draw.</p>
<p class="note"><b>Density with clarity.</b> The cockpit's body text moves from <code>frameFont(.label)</code> to <code>frameFont(.body)</code> — 10pt to 11pt at the default base, and regular weight rather than semibold, since <code>.label</code> was drawing every row title bold — rows get a fixed 14pt glyph column and a right-aligned monospace meta column, and the centre column's three chrome rows above the conversation become one.</p>

<h2>The aesthetic risk</h2>
<p class="note risk"><b>The frame takes the selected crew's hue.</b> Today the conversation canvas is tinted with the crew's theme (<code>canvasTint</code>) and everything around it is system grey. In the mocks the chrome, the rail and the input surfaces carry the same hue at a tenth of the canvas's chroma (0.004–0.006 against 0.018/0.028), so selecting Vivy makes the whole window faintly green and selecting Deck makes it faintly blue. The risk is that ten differently coloured windows read as ten skins rather than one product, and that the tint is either invisible (and so pointless) or visible (and so garish). The cost is concrete: <code>RailRow.markBacking</code>, <code>SessionPaneView.inkSurface</code> and the selection wash all hardcode the surface they solve against, and each must take the tinted surface instead, or the solver and the view disagree exactly the way <code>markBacking</code>'s doc records they once did. The build here solves every ink against the tinted surface for all ten hues, so the numbers below are the numbers the app would get.</p>
<p class="note concede"><b>Conceded from the first draft:</b> the serif transcript was presented as a risk and it already ships. <code>session_view.py</code> sets the body to <code>ui-serif, "New York", Georgia</code> at 1.05rem/1.65 with the same rationale, the operator's own turns are serif behind a 3px rule (dashed at 55% when held), and tool calls are collapsed <code>&lt;details&gt;</code> rows in mono with no result column. The mocks now draw all of that as it ships, at <code>SessionTypography</code>'s 15.75/1.65, and drop the web font and the invented diff stats.</p>

<h2>The palette is solved, and here is the measurement</h2>
<p class="note">Every ink is an OKLCH start point and a contrast target, walked by a port of <code>ThemeRecipe.solveLightness</code> in <code>build.py</code> against the surface it sits on: text at 4.5, marks at 3.0 (<code>ThemeRecipe.markContrast</code>), a filled control so that white on it clears 4.5, hairlines at 1.6 and 1.3. Two hues are shown, Deck's azure and Vivy Commercial's amber, which is the hue that collides with the summons. The table is generated by the build, so it cannot say something the stylesheet does not.</p>
{"".join(table)}
<p class="note"><b>Three inks, three jobs.</b> <code>--ink</code> is primary at 7:1 (the foreground recipe). <code>--ink-2</code> is every secondary thing a person reads, at 4.5: meta columns, timestamps, section labels, "18 more". <code>--ink-3</code> is solved to 3.0 and is never text: chevrons, the hollow waypoint's ring, a disabled control. The first draft had a 2.8:1 tertiary carrying half the cockpit's words.</p>
<p class="note"><b>Two warning hues, as the code has.</b> <code>--attn</code> is <code>ThemeRecipe.attentionInk</code>, hue 65: the summons bar, the triangle, a held mark, a PR verdict that asks for you, the queue badge. <code>--warn</code> is <code>warningInk</code>, hue 95 at lower chroma, 30° off on purpose: a standing caution that is not a failure, which is <code>rc off</code>, a stale working-on age, and the context meter past its soft tier. The first draft collapsed them and was wrong to.</p>
<p class="note"><b>When the crew's hue is the summons's hue, in-progress marks go neutral.</b> Ember (29), amber (68) and gold (95) sit within 40° of hue 65. For those crews <code>--prog-mark</code> and <code>--prog-text</code> resolve to the primary ink rather than the crew's accent, so the half-filled glyph, the current waypoint and the pull-request glyph cannot be mistaken for a held mark or a summons. The crew keeps its hue where it means identity: the rail dot, the selection wash, the canvas. The cockpit page shows Vivy Commercial selected.</p>

<h2>What is genuinely broken today, as opposed to dated</h2>
<ul class="note">
  <li><b>The corrections queue hides its only <code>high</code>.</b> The queue merges pr-open then open, newest first, and shows five rows (<code>CockpitView.queueRowLimit</code>). On 2026-09-04 the one <code>severity: high</code> item (the stale pinned rail row) is sixth, behind "18 more". Severity is decoded and never used to order. The mock sorts severity first, then recency.</li>
  <li><b>Seven horizontal chrome rows in the centre column.</b> Pane chrome (Local/Shell), working strip, status bar, conversation, live bar, composer, ribbon. Each is ~26pt with a hairline. The mock keeps every fact, every control and every slot (the status bar's text slot included) and draws them in three rows plus the ribbon.</li>
  <li><b>Nothing collapses below 900pt.</b> Rail fixed at 200, main pane floor 400, column floor 280, so the layout is identical at 900 and at 2000. The narrow page defines what gives way.</li>
  <li><b>10pt is the cockpit's body size.</b> <code>frameFont(.label)</code> is base − 1 = 10pt, used for every epic title, queue row and proposal; <code>DeckTypography</code>'s own comment calls 10pt "the floor" and reserves it for the send hint.</li>
  <li><b>The off-screen rail fires only downward.</b> It lists panels pushed below the viewport and is absent otherwise, so a reader scrolled to the queue has no non-scroll way back up. The cockpit page names what replacing it reverses.</li>
</ul>

<h2>What the mock does not change, and why</h2>
<ul class="note">
  <li>The ribbon is the last row and scrolls rather than shrinking its labels (the operator, 2026-08-25). The position at its right edge now reads "waypoint 4": it is the index of <code>currentId</code>, not a count, so it is not drawn as a fraction.</li>
  <li>An epic's <code>Done when:</code> clamps at two lines with "more" as the escape hatch.</li>
  <li>The rail's summons bar, the triangle, the accent selection wash, the trailing chevron and count, the "+ New" foot: kept. The rail page says why "+ New" stays for now.</li>
  <li>The shell stamps the theme; the mocks show light and dark as two stamped frames, never as a media query.</li>
</ul>

<h2>Accessibility</h2>
<p class="note">Every element the redesign adds carries the label VoiceOver would read, in the HTML as <code>aria-label</code> and in the app as <code>.accessibilityLabel</code>, the way <code>RowTreatment.accessibilityPrefix</code> leads every row today because strike-through and glyph fill are invisible to it:</p>
<ul class="note">
  <li>Queue count, orange: "Corrections queue, 23 items, 1 high". Severity chip: "severity high". Panel counts: "5 of 11 epics settled", "2 agents in flight".</li>
  <li>Index strip entries: "Course, 5 of 11 epics settled. Activate to scroll to it." A collapsed panel's entry adds "collapsed".</li>
  <li>Ribbon position: "waypoint 4 of 11"; the current waypoint: "Deck-to-Keel typed wire, work in progress".</li>
  <li>START rows: "NYH Studio, not running; activate to start". A terminal-only row: "a terminal with no agent". A stopped crew: "Constance, stopped".</li>
  <li>The off-screen summons chip: "1 session below needs an answer; activate to scroll to it".</li>
  <li>Toolbar: the occupant control is a radio group named "Right column"; Terminal View is a toggle named "Terminal View"; it swaps the main pane and its way back is "Session View".</li>
</ul>

<h2>Buildability</h2>
<p class="note">Everything native here is SwiftUI: the toolbar is <code>.toolbar</code> with a <code>Picker</code> in <code>.segmented</code> style bound to <code>ColumnOccupant</code> and a separate toggle for <code>showingTerminal</code>; the index strip is a row of plain buttons driving <code>ScrollViewProxy.scrollTo</code>, with "here" read off the same <code>PanelFramePreferenceKey</code> frames the off-screen rail reads today (the top-most panel whose frame intersects the viewport); the dot rail is <code>RailRow</code> with its name hidden under a width threshold; the sheet is the existing occupant drawn as an overlay under the second breakpoint. The colours are the app's own solver at the app's own targets.</p>
"""
    page("index.html", "Deck redesign", "Five screens, each in both themes, with a note on what changed from today and why. Read this page first; the others assume it.", body, css)


def build_window(css):
    lede = "Rail, conversation and cockpit at 1440 × 880, the Deck crew selected while two reviewers are dispatched on PR #143. Every row is what the mini and the Library served on 2026-09-04."
    body = frames(("Light", window("light")), ("Dark", window("dark")))
    body += """
<h2>What changed from today</h2>
<ul class="note">
  <li><b>One row above the conversation, not three, with every slot kept.</b> The crew's mark and name; then one flexible slot that draws the co's working-on sentence with its age, unless the pane has something more urgent to say, in which case that pre-empts it in the same slot: "Starting…" during a launch, a render error in red, or the unreachable reason; then the vitals. The states page shows all three. When the vitals are stale, "· as of 4m ago" follows them, as <code>VitalsRow</code> draws it; a stale working-on age turns amber and reads "· 47m ago", as <code>WorkingStrip.durationSuffix</code> distinguishes the two today. They are different facts and both survive.</li>
  <li><b>The toolbar shows the two mechanisms as two controls.</b> Terminal View is <code>showingTerminal</code>, a main-pane swap, so it is a lone toggle. It keeps the full name — "Terminal" alone reads as a third sibling of Shell and Local, which are column occupants and a different mechanism entirely (the operator, 2026-09-04). Its way back stays "Session View". Cockpit, Shell and Local are one <code>ColumnOccupant</code>, so they are one segmented control; when the occupant is a viewer, editor or item, a fourth labelled segment appears so the control can always show what the column holds. Re-render and Stop session sit behind ⋯, as they sit behind ⋯ in the status bar today. Controls are 28pt.</li>
  <li><b>Vitals become tokens with a context meter.</b> The meter is what a glance reads, and it takes the tier: <code>--ink-2</code> when ok, <code>--warn</code> past the soft limit, <code>--err</code> at hard. <code>rc</code> draws in both states — <code>--warn</code> when off, ordinary meta ink when on — because a badge that appears in only one state cannot be told apart from one that has not loaded (the operator, 2026-09-05); the subscription moves into the model token's tooltip. The PR token carries the review verdict in <code>--attn</code> when it is "changes requested", the one vital that asks the operator for something.</li>
  <li><b>The conversation is drawn as <code>session_view.py</code> draws it</b>: New York for the prose at 15.75/1.65, the operator's turns behind a 3px rule, tool calls as collapsed mono rows. The mock adds the bottom anchor and the fade only.</li>
  <li><b>The operator's rows are visibly the operator's.</b> Live state and the composer sit on the chrome surface, one hairline from the canvas. Send is the only filled button in the window, in <code>--accent-fill</code>, solved so white on it clears 4.5.</li>
  <li><b>The ribbon gains a position</b>, "waypoint 4", derived from the same Course list the cockpit draws. The ribbon has three states by <code>waypointStyle</code>: done, current, everything else. Crew stats is <code>claimed</code>, so the cockpit draws it in progress and the ribbon draws it ahead; that is the ribbon's zoom, not a disagreement, and both come from one list in <code>build.py</code>.</li>
  <li><b>The window tints with the selection.</b> The risk on the overview page; the solver implications are named there.</li>
</ul>
"""
    page("01-window.html", "The window at rest", lede, body, css)


def build_cockpit(css):
    lede = "The right column at 328pt in both themes, every panel populated from the convivy-deck Course (version 8) and queue as served on 2026-09-04. The Deck-to-Keel wire epic is expanded; the pr-open queue row is hovered."
    two = f'<div style="display:flex;gap:26px;align-items:flex-start">{standalone("light", 240, cockpit(), 328)}{standalone("dark", 240, cockpit(), 328)}</div>'
    amber = f'<div style="display:flex;gap:26px;align-items:flex-start">{standalone("light", 68, cockpit(variant="collapsed"), 328)}{standalone("dark", 68, cockpit(variant="collapsed"), 328)}</div>'
    grammar = ""
    for theme in ("light", "dark"):
        grammar += f"""
<div class="win strip" data-theme="{theme}" data-hue="240" style="--w:auto;--hgt:auto;display:block;box-shadow:none;border:1px solid var(--line);margin-bottom:14px">
  <div class="grammar">
    <div class="cell">{crow("ahead", "Ahead")}<div class="why">open. Hollow, secondary. Nothing is asserted about it.</div></div>
    <div class="cell">{crow("prog", "In progress")}<div class="why">claimed, pr-open, anything past open. Half-filled, in the crew's hue (neutral when the hue is near the summons).</div></div>
    <div class="cell">{crow("held", "Held")}<div class="why">parked. Pause mark, in the summons hue: a human decides when it resumes.</div></div>
    <div class="cell">{crow("done", "Done")}<div class="why">fixed. Filled check, struck, secondary.</div></div>
    <div class="cell">{crow("closed", "Closed without change")}<div class="why">wontfix · duplicate · redirected. One mark: "is it still ahead of me?" has one answer.</div></div>
  </div>
</div>"""
    body = f"""
<div class="frames"><div><div class="frame-label">Light · Dark</div><div class="scroller">{two}</div></div></div>

<h2>The row grammar</h2>
<p class="note">Five treatments, the same five <code>CockpitView.RowTreatment</code> defines today, on a 14pt glyph column. Only the ink changes: "in progress" takes the crew's hue rather than the system accent.</p>
{grammar}

<h2>When the crew's hue is the summons's hue</h2>
<p class="note">Vivy Commercial is amber (68), three degrees from <code>attentionInk</code>'s 65. With it selected, in-progress marks draw in the primary ink and the summons keeps its hue, so the half-filled glyph and the held pause never share a colour. Shown with Dispatched and Proposals collapsed, which is also how a collapsed panel appears in the index: struck, still reachable.</p>
<div class="frames"><div><div class="frame-label">Vivy Commercial selected · light · dark</div><div class="scroller">{amber}</div></div></div>

<h2>What changed from today</h2>
<ul class="note">
  <li><b>The header names the project, not the word "Cockpit".</b> <code>convivy-deck</code> in mono, the Course's title beside it, and "12s" for how old the reading is with the refresh glyph, so the manual refresh Cmd-R already binds has a visible home.</li>
  <li><b>An index strip replaces the off-screen rail, and this reverses a recorded choice.</b> <code>offScreenRail</code> is absent when nothing qualifies, by design, citing the bead's "furniture, not an alert"; it lists only panels below the fold. The index is always present, which is the opposite call, made for two reasons: the counts make it worth reading even when everything fits (the queue's 23 in the summons hue is the interrupt lane's badge), and a rail that appears only sometimes cannot be a place the hand learns. "Here" is the top-most panel intersecting the viewport, read from the same <code>PanelFramePreferenceKey</code> frames the rail reads. A collapsed panel stays in the index, struck; activating it expands and scrolls.</li>
  <li><b>Body text 11pt, secondary 10pt, section labels 10pt tracked and semibold.</b> Every secondary string is <code>--ink-2</code> at 4.5:1. Controls are 24pt (Approve, Decline, Open terminal); chevrons 10pt; the copy and refresh glyphs 12pt.</li>
  <li><b>Rows are a grid: glyph, title, meta.</b> The meta column is right-aligned mono: 1/4 progress, the held count with its pause mark, #143 on the queue's pr-open row (<code>GET /items</code> serves <code>pr</code>; <code>QueueItem</code> does not decode it yet), HIGH on a high-severity row in <code>--attn-text</code>. Chevrons live in the meta column so titles wrap under themselves.</li>
  <li><b>The expanded epic keeps the spine and the clamp.</b> State line, "Done when:" at two lines with "more", the severity and claim line, then the children on the same row grammar.</li>
  <li><b>Proposals are still their own region</b>, tinted with the crew's hue at 15%, Approve and Decline on the row. No live proposal existed on 2026-09-04, so the text is the multiplayer flavour from the bead.</li>
  <li><b>The queue sorts severity first.</b> The one <code>high</code> item is second; the pr-open epic stays first because the queue's own merge puts pr-open ahead of open.</li>
</ul>
<p class="note finding">The Crew stats epic draws a held child ("1" beside a pause mark) to show the held count in the meta column; on 2026-09-04 that epic's claim had expired (<code>Last held by: co-convivy-deck-1541</code>) and no child was parked. The held mark is the one row state this page could not show from live data.</p>
"""
    page("02-cockpit.html", "The cockpit", lede, body, css)


def build_rail(css):
    lede = "The rail at 216pt in both themes: ten crews as the mini's tmux listed them on 2026-09-04, Ask expanded with its Audio child and a summons, Car and Tennis under OTHER SESSIONS before their adoption, the catalog under START, the bead pane and + New as the foot."
    def railframe(theme, mode="full", **kw):
        w = 44 if mode == "dots" else 216
        cls = "body dots" if mode == "dots" else "body"
        return f'<div class="win" data-theme="{theme}" data-hue="240" style="--w:{w}px;--hgt:640px;grid-template-rows:1fr;border-radius:8px"><div class="{cls}" style="grid-template-columns:1fr">{rail(mode, **kw)}</div></div>'
    four = f'<div style="display:flex;gap:26px;align-items:flex-start">{railframe("light")}{railframe("dark")}{railframe("light", "dots")}{railframe("dark", "dots")}</div>'
    overflow = (f'<div style="display:flex;gap:26px;align-items:flex-start">'
                f'<div class="win" data-theme="light" data-hue="240" style="--w:216px;--hgt:480px;grid-template-rows:1fr;border-radius:8px"><div class="body" style="grid-template-columns:1fr">{rail("full", overflow=True, hidden_summons=True)}</div></div>'
                f'<div class="win" data-theme="dark" data-hue="240" style="--w:44px;--hgt:480px;grid-template-rows:1fr;border-radius:8px"><div class="body dots" style="grid-template-columns:1fr">{rail("dots", overflow=True, hidden_summons=True)}</div></div></div>')
    marks = ""
    for theme in ("light", "dark"):
        marks += f"""
<div class="win strip" data-theme="{theme}" data-hue="240" style="--w:auto;--hgt:auto;display:block;box-shadow:none;border:1px solid var(--line);margin-bottom:14px">
  <div class="marks">
    <div class="cell">{mark("busy", 29)}<div><div class="lab">Working</div><div class="why">The Convivy C, turning.</div></div></div>
    <div class="cell">{mark("listening", 145)}<div><div class="lab">Agents running</div><div class="why">A disc breathing between two solved inks.</div></div></div>
    <div class="cell">{mark("ready", 68)}<div><div class="lab">Ready</div><div class="why">A square: the only shape here with corners.</div></div></div>
    <div class="cell">{mark("needs", 95)}<div><div class="lab">Needs an answer</div><div class="why">The triangle, in the summons hue, plus the bar on the row's edge.</div></div></div>
    <div class="cell">{mark("unread", 205)}<div><div class="lab">State unknown</div><div class="why">Hollow. The pane offers the raw terminal.</div></div></div>
    <div class="cell">{mark("off", 275)}<div><div class="lab">Stopped</div><div class="why">Dimmed to 30%, identity kept.</div></div></div>
    <div class="cell">{mark("start", 350)}<div><div class="lab">Not running (START)</div><div class="why">A hollow square at full ink: an invitation, distinct from a stopped crew.</div></div></div>
  </div>
</div>"""
    body = f"""
<div class="frames"><div><div class="frame-label">Light · Dark · Collapsed to marks (light · dark)</div><div class="scroller">{four}</div></div></div>

<h2>The marks</h2>
<p class="note">Six unchanged from <code>SessionDotView</code>, one added for the catalog: shape carries state, the crew's hue carries identity. Each is solved on the rail surface and again on the selected wash (<code>RailRow.markBacking</code>), so a selected row's mark is a different hex from an unselected one's.</p>
{marks}

<h2>Twenty-two rows in a 480pt rail</h2>
<p class="note">Every session the mini listed, with Deck's own scratch shells (<code>deck-shell-*</code>) drawn as discovered children under the crews their paths group them into. A summons below the fold is invisible in both modes today. The mock pins a chip to the list's bottom edge whenever a row needing an answer is scrolled out of view, the rail's own version of the cockpit's off-screen rule: the summons bar's ink, the count, and a click that scrolls to it. Absent when nothing qualifies, because here it is an alert and not furniture.</p>
<div class="frames"><div><div class="frame-label">Full (light) · Marks (dark), both with a summons below the fold</div><div class="scroller">{overflow}</div></div></div>

<h2>What changed from today</h2>
<ul class="note">
  <li><b>216pt, 26pt rows, 13pt names.</b> Up from 200 and 6pt vertical padding. The extra width goes to the trailing column so a count and chevron never crowd a long name (Vivy Commercial is the longest real one).</li>
  <li><b>Children hang on a spine.</b> The 1pt rule the cockpit uses for an expanded epic, drawn from the parent's mark column down to the last child, with a 7pt tick into each child. At 44pt the spine goes and the tick stays, indented 10pt, so a child is still a child when the names are gone.</li>
  <li><b>OTHER SESSIONS and START are the same section label as BEAD</b>: 10pt, tracked, <code>--ink-2</code>. At 44pt they are 1pt rules, and the rows under them are hover-only for a name; the <code>List</code>'s own arrow keys still reach them, and Cmd-1…9 reaches the top-level crews as it does today.</li>
  <li><b>A START row is a hollow square at full ink.</b> Today it is a play glyph in the crew's hue; the first draft dimmed it, which made it the same 30% square as a stopped crew. Hollow says "not yet" where dimmed says "was".</li>
  <li><b>A terminal-only row previews the hue it would take.</b> <code>themeForSession</code> already hashes a bare name to a theme, so the hue exists before adoption; Car and Tennis draw it at the stopped row's 30%, so it reads "would be" rather than "is".</li>
  <li><b>"+ New" stays, for now.</b> The operator's 2026-09-03 call makes the steward's <code>new-crew</code> skill the only creation path and deletes Deck's button, but the issue recording it (<code>issue_01M1MW2E4G5SJPWNCMNH0KCJES</code>) is open and its thread gates the deletion on a <code>session-agent crews</code> verb that does not exist. Until Deck reads <code>crews.d/</code>, a user with no steward has no other path, so the foot keeps the button and <code>RailRow.onNewSession</code> keeps its context-menu item. When the reader lands, both go and the bead pane becomes the foot. The first draft removed them early and was wrong to.</li>
  <li><b>The bead pane's second fact is relative.</b> "reordered 4d ago" (the Course's last <code>reordered</code> event, 2026-08-31) says whether the plan moved since you looked, which the fraction cannot; a bare "v8" said nothing a reader could use.</li>
</ul>
"""
    page("03-rail.html", "The rail", lede, body, css)


def build_narrow(css):
    lede = "Three widths below the current 900pt floor. The window today is identical at every width; these define what gives way, in what order. The item sheet is on the states page."
    f1 = window("light", width=1100, height=720, rail_mode="dots", compact=True)
    f1d = window("dark", width=1100, height=720, rail_mode="dots", compact=True)
    f2 = window("light", width=820, height=640, rail_mode="dots", occupant="hidden", compact=True)
    f2d = window("dark", width=820, height=640, rail_mode="dots", occupant="hidden", compact=True)
    f3 = window("light", width=820, height=640, rail_mode="dots", occupant="cockpit", compact=True, sheet=True)
    f3d = window("dark", width=820, height=640, rail_mode="dots", occupant="cockpit", compact=True, sheet=True)
    body = frames(
        ("1100pt · the rail collapses to marks, the cockpit stays (light)", f1),
        ("1100pt (dark)", f1d),
        ("820pt · the cockpit leaves; its queue count rides on the toolbar (light)", f2),
        ("820pt (dark)", f2d),
        ("820pt · the cockpit summoned as a sheet over the conversation (light)", f3),
        ("820pt · sheet (dark)", f3d),
    )
    body += """
<h2>What gives way, in order</h2>
<ul class="note">
  <li><b>Below 1280pt the rail collapses to marks (44pt).</b> The rail is the cheapest column to shrink: its marks carry state without names, the summons bar is width-independent, the child tick survives, and Cmd-1…9 reaches every top-level crew. The toolbar's sidebar toggle reopens it as an overlay.</li>
  <li><b>Below 1000pt the column leaves the split and becomes a sheet.</b> Whatever <code>ColumnOccupant</code> holds (cockpit, shell, local terminal, viewer, editor, item) is drawn as an overlay from the right edge, dismissed by clicking outside or by the segmented control that summoned it; the cockpit's queue count rides on its segment as a badge so the interrupt lane is never silent. The states page shows the sheet holding an item.</li>
  <li><b>The session row drops vitals from the right, keeping the context meter last.</b> Context is the vital that changes what you do next; rc, agents and PR keep their facts in tooltips and in the cockpit. The status slot is never dropped: a render error pre-empts the working-on sentence at every width.</li>
  <li><b>The composer keeps its verbs and loses their labels.</b> The send-key hint goes. The composer never gets shorter than two lines.</li>
  <li><b>The ribbon scrolls.</b> Unchanged, by decision; "waypoint 4" matters most here, where two or three labels fit.</li>
  <li><b>The window floor becomes 720pt</b>: 44 (rail) + 640 (a 46rem measure with margins) + 36 (divider allowances), against 900 today.</li>
</ul>
"""
    page("04-narrow.html", "Narrow widths", lede, body, css)


def build_states(css):
    lede = "The layout under the states the code actually reaches: the gate, the fallbacks, held and background work, the raw terminal, the item sheet, and the cockpit degraded, empty and unresolved."
    W, H = 1000, 560
    def cframe(theme, sess, conv, oper, ribbon_on=True, height=H, hue=240):
        return standalone(theme, hue, f'<div class="body no-rail no-cockpit">{centre(sess=sess, conv=conv, oper=oper, ribbon_on=ribbon_on)}</div>', W, height)
    gate_l = cframe("light", session_row(mark_kind="needs"), convo(veiled=True), operator(kind="gate", live=("needs", "Needs an answer", "· 2m")), height=640)
    gate_d = cframe("dark", session_row(mark_kind="needs"), convo(veiled=True), operator(kind="gate", live=("needs", "Needs an answer", "· 2m")), height=640)
    starting = cframe("light", session_row(status="Starting…", vitals=False, mark_kind="unread"), convo(veiled=True),
                      operator(kind="fallback-unknown", live=("unread", "State unknown", "")), ribbon_on=True, height=380)
    rerr = cframe("light", session_row(status="Could not render the conversation: session-view exited 1 (unknown transcript record kind)", status_err=True, vitals_stale=True, tier="soft", rc_off=True, working_stale=True), convo(),
                  operator(kind="fallback-blocked", live=("unread", "State unknown", "")), height=420)
    heldf = cframe("light", session_row(), convo(held=True),
                   operator(held=2, background=True, last_error="send failed: session-agent: cannot reach session deck", live=("busy", "Working", "· quiet 48s")), height=520)
    term = standalone("light", 240, f'<div class="body no-rail no-cockpit">{terminal_centre()}</div>', W, 420)
    sheet_item = window("light", width=820, height=640, rail_mode="dots", occupant="item", compact=True, sheet=True)
    sheet_item_d = window("dark", width=820, height=640, rail_mode="dots", occupant="item", compact=True, sheet=True)
    cock = (f'<div style="display:flex;gap:26px;align-items:flex-start">'
            f'{standalone("light", 240, cockpit(variant="unresolved"), 328, 160)}'
            f'{standalone("light", 240, cockpit(variant="degraded"), 328)}'
            f'{standalone("dark", 240, cockpit(variant="empty-course"), 328)}'
            f'{standalone("dark", 240, cockpit(variant="no-children"), 328)}</div>')
    empty_course = cframe("dark", session_row(), convo(), operator(), ribbon_on=False, height=420)
    tabs = (f'<div style="display:flex;gap:26px;align-items:flex-start">'
            f'{standalone("light", 68, cockpit(), 328)}{standalone("light", 68, shell_pane(), 328)}'
            f'{standalone("light", 68, local_pane(), 328)}{standalone("light", 68, slate_pane(), 328)}</div>'
            f'<div style="display:flex;gap:26px;align-items:flex-start;margin-top:14px">'
            f'{standalone("dark", 29, cockpit(), 328)}{standalone("dark", 29, shell_pane(), 328)}'
            f'{standalone("dark", 29, local_pane(), 328)}{standalone("dark", 29, slate_pane(), 328)}</div>')
    body = frames(
        ("The gate (GatePanel, ≤340pt, scrolling) · light", gate_l),
        ("The gate · dark", gate_d),
        ("A launch in flight: the status slot pre-empts working-on, the vitals cluster is absent, the composer falls back", starting),
        ("A render error (red) pre-empting working-on; vitals stale ('as of 4m ago'), context past the soft tier, rc off in amber; working-on age stale in amber", rerr),
        ("Two held messages with Rewrite, a subagent working in the background, a lastError on the live row, a held turn in the transcript", heldf),
        ("The raw terminal fallback, with its way back", term),
        ("820pt · the sheet holding ItemDetailPane, the segmented control labelled Item (light)", sheet_item),
        ("820pt · item sheet (dark)", sheet_item_d),
        ("The cockpit unresolved · degraded (no agents, no proposals, children loading, queue unreachable) · an empty Course with an unreporting mini · an epic with no children", cock),
        ("A project with no Course: the ribbon draws nothing and the conversation takes the row back", empty_course),
        ("The four right-column tabs (B2): the Cockpit neutral, the Shell in the crew's colour, the Local in graphite, the Slate in the colour of the session it was opened for. Amber above (light), ember below (dark)", tabs),
    )
    body += """
<h2>What the states settle</h2>
<ul class="note">
  <li><b>The gate is the operator's row, taller.</b> <code>GatePanel</code> replaces the composer in the same slot, capped at 340pt and scrolling, with the header (the gate's own, or "Question 1 of 3"), the question at 13pt, one card per option with its number and its ⌘-shortcut, and the terminal escape hatch as the code words it. <b>The ⌘-shortcuts are APPROVED AND NOT YET BUILT</b> (the operator, 2026-09-05) — today <code>OptionCard</code> is a plain <code>Button</code> with no <code>.keyboardShortcut</code>, so answering a permission prompt is mouse-only, and the number is drawn only because the number is what Deck sends. Build it: ⌘1–9 selects the matching option. The conversation dims behind it; the live row says "Needs an answer" with the triangle, in the summons hue.</li>
  <li><b>The status slot is the same slot.</b> "Starting…", a render error, or the unreachable reason replace the working-on sentence rather than adding a row; the working-on sentence returns when they clear. A render error is red; the other two are secondary.</li>
  <li><b>Held, background and error live on the live row and the composer bar</b>, where <code>SessionPaneView</code> puts them today: "2 held" with Rewrite beside Commands; "working in the background" with its 5pt breathing dot; <code>lastError</code> in red, truncated, with the full text on hover.</li>
  <li><b>The sheet hosts every occupant.</b> Shown with <code>ItemDetailPane</code>: title and product, the rendered item, the four actions. The segmented control grows an "Item" segment so the toolbar can always say what the column holds.</li>
  <li><b>The cockpit degrades per panel, as it does today</b>, and the index strip degrades with it: "—" where a reading never arrived, "0" where it arrived empty, the queue's count in the summons hue only when there is something in it.</li>
  <li><b>No Course, no ribbon</b>, and the index reads "Course —" rather than "0/0".</li>
</ul>
"""
    page("05-states.html", "States", lede, body, css)


def main():
    css = CSS_BASE + "\n/* ---- generated tokens: one block per (appearance, selected-crew hue) ---- */\n"
    for theme in ("light", "dark"):
        for H in HUES:
            css += theme_css(theme, H) + "\n"
    (HERE / "deck.css").write_text(css)
    build_index(css); build_window(css); build_cockpit(css); build_rail(css); build_narrow(css); build_states(css)
    print("wrote", ", ".join(f for f, _ in PAGES), "and deck.css to", HERE)
    print("\nmeasured contrast (theme, hue, pair, ratio):")
    for theme, H, name, ratio in contrast_table():
        print(f"  {theme:5} {H:3}  {name:50} {ratio:5.2f}")


if __name__ == "__main__":
    main()
