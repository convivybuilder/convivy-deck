#!/usr/bin/env python3
"""Builds the START-section design page in this directory.

    python3 design/start-section/build.py

One page, `index.html`, plus the stylesheet it links. NOTHING HERE IS
HAND-EDITED: the page and `deck.css` are regenerated from this file, and the
tokens, the row idiom and the marks are IMPORTED from `design/redesign/build.py`
so this page cannot drift from the approved spec's colours or metrics. Edit
this file, then regenerate.

What it draws: the rail with a 17-entry catalog under START, first as it
breaks today, then three ways of bounding START, each at 216pt and at the
44pt dot rail, and a recommendation. The CSS mirrors the Swift structure on
purpose — START is a sibling of the crews' `List`, not a section inside it,
so `.rail .start` here is a flex sibling of `.rail .list`, and the list
shrinks exactly as the `List` does in `RailView.body`.
"""
import importlib.util
import sys
sys.dont_write_bytecode = True   # never leave a __pycache__ under design/redesign
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = HERE.parent / "redesign" / "build.py"

_spec = importlib.util.spec_from_file_location("deck_spec", SPEC)
spec = importlib.util.module_from_spec(_spec)
sys.modules["deck_spec"] = spec
_spec.loader.exec_module(spec)

CSS_BASE, theme_css, HUES, SYMBOLS, use, mark, CREWS, MARK_LABEL = (
    spec.CSS_BASE, spec.theme_css, spec.HUES, spec.SYMBOLS, spec.use, spec.mark, spec.CREWS, spec.MARK_LABEL)

# ---------------------------------------------------------------------------
# The catalog: seventeen sessions a user might reasonably have unpinned. The
# real catalog on this machine is three (NYH Studio, Write Better, Ask); the
# problem needs a dozen or more to show, and the operator's premise is that it
# will get there. Hues cycle through ThemeCatalog's ten the way `themeForSession`
# hashes a bare name to a theme.
# ---------------------------------------------------------------------------

CATALOG = ["Agent Platform", "Convivy Builder", "Hollis", "Keel", "Knowledge", "NYH Studio", "Placard",
           "Research", "Shipwright", "Sous Chef", "Substrate", "Talk Better", "Tax 2025", "Write Better",
           "Working Copy", "Yacht Log", "Zero Inbox"]
CATALOG_HUES = {name: HUES[(i * 3) % len(HUES)] for i, name in enumerate(CATALOG)}

ROW = 26          # RailRow.rowHeight
CAP_ROWS = 4      # option A's viewport, in rows

# ---------------------------------------------------------------------------
# CSS added on top of the spec's: the START block as a sibling of the list,
# the capped viewport, the disclosure row, the single "Start a session" row,
# and the popover. Every colour is a spec token.
# ---------------------------------------------------------------------------

START_CSS = r"""
/* ---- start-section additions (design/start-section/build.py) ------------- */
/* The START block is a SIBLING of .list, the way `START` is a sibling of the
   `List` in RailView's VStack. .list is flex:1 and clips; .start is flex:none
   and takes what it takes. That is the mechanism, drawn. */
.rail .start { flex: none; display: flex; flex-direction: column; border-top: 1px solid var(--line); }
.rail .start .sect { padding: 10px 12px 4px; display: flex; align-items: center; gap: 6px; }
.rail .start .sect .n { font: 500 10px/1 var(--font-ui); letter-spacing: 0; color: var(--ink-3); text-transform: none; }
.rail .start .sect .trail { margin-left: auto; display: inline-flex; align-items: center; gap: 4px; color: var(--ink-3); }
.rail .start .sect .trail svg { width: 9px; height: 9px; }
.rail.dots .start .sect { height: 1px; padding: 0; margin: 8px 12px; background: var(--line); }
.rail.dots .start .sect .n, .rail.dots .start .sect .trail { display: none; }
/* today: the list starved to whatever is left */
.rail .list.starved { position: relative; }
/* option A: a viewport of CAP_ROWS rows, scrolling inside */
.rail .start .rows.capped { max-height: var(--cap); overflow-y: auto; scrollbar-width: none; }
.rail .start .rows.capped::-webkit-scrollbar { display: none; }
/* option B: the disclosure row */
.rail .start .row.disclose .name { color: var(--ink-2); }
.rail .start .row.disclose .trail svg { width: 8px; height: 8px; }
/* option C: one row that opens the picker */
.rail .start .row.opener .name { color: var(--ink-2); }
.rail .start .row.opener .trail { color: var(--ink-3); }
.rail .start .row.opener .trail svg { width: 8px; height: 8px; }
.rail .start .row.opener.open { background: var(--bg-hover); }
.rail.dots .start .row.opener .name, .rail.dots .start .row.opener .trail { display: none; }
/* a blank centre column so a popover has somewhere to float */
.blank { background: var(--bg-canvas); min-height: 0; }
/* the picker: an NSPopover off the row's trailing edge */
.pop { position: absolute; width: 232px; background: var(--bg-chrome); border: 1px solid var(--line); border-radius: 9px;
       box-shadow: 0 10px 28px var(--shadow), 0 0 0 .5px var(--line); padding: 8px 0 6px; z-index: 4; color: var(--ink); }
.pop::before { content: ""; position: absolute; left: -7px; width: 12px; height: 12px; background: var(--bg-chrome);
               border-left: 1px solid var(--line); border-bottom: 1px solid var(--line); transform: rotate(45deg); top: var(--arrow, 50%); margin-top: -6px; }
.pop .field { margin: 0 8px 6px; height: 24px; border-radius: 6px; background: var(--bg-input); box-shadow: inset 0 0 0 1px var(--line);
              display: flex; align-items: center; gap: 6px; padding: 0 8px; font-size: 12.5px; color: var(--ink-3); }
.pop .field svg { width: 11px; height: 11px; color: var(--ink-3); }
.pop .field .caret { width: 1px; height: 14px; background: var(--ink); margin-left: -4px; }
.pop .field .typed { color: var(--ink); }
.pop .rows { max-height: calc(10 * 26px); overflow-y: auto; scrollbar-width: none; }
.pop .rows::-webkit-scrollbar { display: none; }
.pop .row { padding: 0 10px 0 12px; }
.pop .row .name { color: var(--ink); }
.pop .row.focus { background: var(--accent-wash); }
.pop .row.hov { background: var(--bg-hover); }
.pop .row .trail .key { font: 500 10px/1 var(--font-ui); color: var(--ink-3); padding: 2px 4px; border-radius: 3px; box-shadow: inset 0 0 0 1px var(--line); }
.pop .foot { padding: 6px 12px 0; font-size: 10.5px; color: var(--ink-3); display: flex; justify-content: space-between; }
/* the row's context menu */
.menu { position: absolute; z-index: 5; background: var(--bg-input); border: 1px solid var(--line); border-radius: 7px; padding: 4px;
        box-shadow: 0 8px 22px var(--shadow); font-size: 12.5px; min-width: 150px; color: var(--ink); }
.menu div { padding: 3px 10px; border-radius: 4px; }
.menu div.on { background: var(--accent-fill); color: #fff; }
.menu hr { border: 0; border-top: 1px solid var(--line); margin: 4px 8px; }
/* option D: recents + the rest */
.rail .start .row.more .name { color: var(--ink-2); }
/* annotation on a frame */
.doc .cap { font-size: 12px; color: #4b4e57; max-width: 62ch; margin: 6px 0 0; }
.doc .cap b { color: #1c1d21; font-weight: 600; }
.doc .grid { display: flex; gap: 26px; align-items: flex-start; flex-wrap: wrap; }
.doc .grid > div { flex: none; }
.doc .verdict { border-left: 3px solid #1f7a3a; padding: 8px 12px; background: #e8f2ea; max-width: 88ch; }
.doc .cost td:first-child { font-weight: 600; white-space: nowrap; }
.doc .cost td { max-width: 60ch; }
.measure { position: absolute; right: -150px; width: 140px; font: 11px/1.35 var(--font-ui); color: #4b4e57; }
.measure b { color: #1c1d21; }
.measure::before { content: ""; position: absolute; left: -10px; top: 0; bottom: 0; width: 1px; background: #8a8d96; }
.measure::after { content: ""; position: absolute; left: -13px; top: 0; width: 7px; height: 1px; background: #8a8d96; box-shadow: 0 var(--mh) 0 #8a8d96; }
"""

# THE STYLESHEET IS INLINED, NOT LINKED, AND THAT IS THE POINT.
# A `<link rel="stylesheet" href="deck.css">` only resolves when the viewer
# fetches a sibling file relative to the page. The operator's viewer does not,
# so the page arrived as unstyled markup: the SVG sprite at natural size, no
# colour, no layout. The mocks they have read successfully (`bead-pane-mock.html`,
# `ribbon-labels-mock.html`) all carry their CSS in a `<style>` block; the
# ones that link a sibling are exactly the ones that broke. A design artifact
# that only renders from the directory it was generated in is not one you can
# hand to somebody.
HEAD = """<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
{css}
</style>
"""


# ---------------------------------------------------------------------------
# Rows and rails
# ---------------------------------------------------------------------------

def row(cls, hue, m, name, trail="", dots=False, child=False, last=False, aria="", extra=""):
    c = ["row"] + cls + (["child"] if child else []) + (["last"] if last else [])
    t = f' title="{name}"' if dots else ""
    body = "" if dots else f'<span class="name">{name}</span>{trail}'
    return f'<div class="{" ".join(c)} hue-{hue}"{t}{aria}{extra}>{m}{body}</div>'


def crews_html(dots, promoted=()):
    """The live side of the rail: the spec's ten crews, Ask expanded, plus
    OTHER SESSIONS. `promoted` names catalog entries that are RUNNING and so
    draw here rather than under START — option C's rule."""
    out = []
    for cid, name, hue, mk, x in CREWS:
        classes = (["sel"] if x.get("sel") else []) + (["off"] if mk == "off" else [])
        summons = '<i class="summons" aria-hidden="true"></i>' if mk == "needs" else ""
        kids = list(x.get("children", []))
        trail = ""
        if not dots:
            if x.get("expanded"):
                trail = f'<span class="trail">{use("chev-d")}</span>'
            elif x.get("count") or kids:
                trail = f'<span class="trail">{x.get("count") or len(kids)}{use("chev-r")}</span>'
        out.append(row(classes, hue, summons + mark(mk, hue), name, trail, dots=dots,
                       aria=f' aria-label="{name}, {MARK_LABEL[mk]}{", selected" if x.get("sel") else ""}"'))
        if x.get("expanded"):
            for i, (kid, kname, kmk, kx) in enumerate(kids):
                out.append(row([], hue, mark(kmk, hue), kname, dots=dots, child=True, last=i == len(kids) - 1))
    out.append('<div class="sect sectlabel" aria-label="Other sessions">Other sessions</div>')
    for name in ("Car", "Tennis"):
        out.append(row([], 95, mark("term", 95, would=True), name, dots=dots))
    for name in promoted:
        hue = CATALOG_HUES[name]
        out.append(row([], hue, mark("ready", hue), name, dots=dots,
                       aria=f' aria-label="{name}, ready"'))
    return "\n".join(out)


def foot_html(dots):
    return ('<div class="foot"><div class="bead" role="button">'
            '<div class="sectlabel">Bead</div>'
            '<div class="t">Deck — where the cockpit is going, and where it is now</div>'
            '<div class="meter" aria-hidden="true"><i style="width:45%"></i></div>'
            '<div class="f"><span>5 of 11 epics</span><span>reordered 4d ago</span></div>'
            f'</div><div class="newbtn" role="button">{use("i-plus")}<span>New</span></div></div>')


def start_rows(names, dots, cls=()):
    return "\n".join(
        row(["off"] + list(cls), CATALOG_HUES[n], mark("start", CATALOG_HUES[n]), n, dots=dots,
            aria=f' aria-label="{n}, not running; activate to start"') for n in names)


def sect(label, count=None, trail="", dots=False):
    n = f'<span class="n">{count}</span>' if count is not None and not dots else ""
    return f'<div class="sect sectlabel" aria-label="{label}">{label}{n}{trail}</div>'


def rail_html(mode, start_block, promoted=(), list_cls="", extra_cls=""):
    dots = mode == "dots"
    return (f'<aside class="rail{" dots" if dots else ""}{" " + extra_cls if extra_cls else ""}" aria-label="Sessions">'
            f'<div class="list {list_cls}">{crews_html(dots, promoted)}</div>'
            f'{start_block}{foot_html(dots)}</aside>')


# The four START treatments ---------------------------------------------------

def start_today(dots, names=CATALOG):
    return f'<div class="start today">{sect("Start", dots=dots)}<div class="rows">{start_rows(names, dots)}</div></div>'


def start_capped(dots, names=CATALOG):
    cap = CAP_ROWS * ROW
    return (f'<div class="start capped-block">{sect("Start", len(names), dots=dots)}'
            f'<div class="rows capped" style="--cap:{cap}px">{start_rows(names, dots)}</div></div>')


def start_disclosure(dots, expanded, names=CATALOG):
    if expanded:
        trail = "" if dots else f'<span class="trail">{use("chev-d")}</span>'
        return (f'<div class="start">{sect("Start", len(names), trail, dots=dots)}'
                f'<div class="rows">{start_rows(names, dots)}</div></div>')
    trail = "" if dots else f'<span class="trail">{len(names)}{use("chev-r")}</span>'
    # collapsed: the header IS the row. At 44pt a rule alone would say nothing, so a
    # hollow square stands in for the whole section.
    if dots:
        return (f'<div class="start">{sect("Start", dots=True)}'
                + row(["off", "disclose"], 240, mark("start", 240, label="Start, 17 sessions; activate to show"), "Start", dots=True) + "</div>")
    return f'<div class="start">{sect("Start", None, trail, dots=dots)}</div>'


def start_opener(dots, count, open_=False):
    trail = "" if dots else f'<span class="trail"><span class="num">{count}</span>{use("chev-r")}</span>'
    return (f'<div class="start">{sect("Start", dots=dots)}'
            + row(["opener"] + (["open"] if open_ else []), 240,
                  mark("start", 240, label=f"Start a session; {count} available"), "Start a session…", trail, dots=dots)
            + "</div>")


def start_recents(dots, recents, rest_count):
    trail = "" if dots else f'<span class="trail"><span class="num">{rest_count}</span>{use("chev-r")}</span>'
    return (f'<div class="start">{sect("Start", dots=dots)}<div class="rows">{start_rows(recents, dots)}</div>'
            + row(["more"], 240, mark("start", 240, label=f"{rest_count} more sessions"), f"{rest_count} more…", trail, dots=dots)
            + "</div>")


# Frames ----------------------------------------------------------------------

def frame(theme, mode, rail, height=640, side=None, measure=None):
    """A rail alone, or a rail beside a blank centre so a popover can float over it."""
    w = 44 if mode == "dots" else 216
    body_cls = "body dots" if mode == "dots" else "body"
    if side is None:
        # A FIXED TRACK, NOT 1fr. With `1fr` the rail takes its min-content
        # width — the bead title is nowrap — and overflows the 216pt window,
        # clipping the whole trailing column (chevrons, counts, "reordered 4d
        # ago"). The spec's 03-rail.html frames use 1fr and show the same clip.
        inner = f'<div class="{body_cls}" style="grid-template-columns:{w}px">{rail}</div>'
        total = w
    else:
        inner = f'<div class="{body_cls}" style="grid-template-columns:{w}px 1fr">{rail}<div class="blank"></div></div>{side}'
        total = w + 300
    m = f'<div class="measure" style="top:{measure[0]}px;height:{measure[1]}px;--mh:{measure[1]}px">{measure[2]}</div>' if measure else ""
    room = "margin-right:150px;" if measure else ""
    return (f'<div style="position:relative;display:inline-block;{room}">'
            f'<div class="win" data-theme="{theme}" data-hue="240" style="--w:{total}px;--hgt:{height}px;grid-template-rows:1fr;border-radius:8px">{inner}</div>{m}</div>')


def labelled(label, html, cap=""):
    c = f'<p class="cap">{cap}</p>' if cap else ""
    return f'<div><div class="frame-label">{label}</div>{html}{c}</div>'


def popover(anchor_mid, left, rows, focus=0, typed="", hover=None, menu_on=None, frame_h=640):
    """The picker. `rows` are catalog names; `typed` filters them the way the
    field would (case-insensitive substring); `focus` is the arrow-key row;
    `hover` is a right-clicked row and `menu_on` puts its context menu up.
    The popover sits inside the frame the way NSPopover keeps itself on
    screen: the body stays put and the ARROW moves to the anchor."""
    shown = [n for n in rows if typed.lower() in n.lower()] if typed else list(rows)
    visible = min(len(shown), 10)
    pop_h = 8 + 30 + visible * ROW + 24 + 6
    top = min(anchor_mid - pop_h // 2, frame_h - 12 - pop_h)
    arrow = anchor_mid - top
    field = (f'<div class="field">{use("i-cmd")}'
             + (f'<span class="typed">{typed}</span>' if typed else "<span>Filter</span>")
             + '<span class="caret"></span></div>')
    out = []
    for i, n in enumerate(shown):
        cls = (["focus"] if i == focus else []) + (["hov"] if i == hover else [])
        trail = f'<span class="trail"><span class="key">↩</span></span>' if i == focus else ""
        out.append(row(cls, CATALOG_HUES[n], mark("start", CATALOG_HUES[n]), n, trail))
    count = f"{len(shown)} of {len(rows)}" if typed else f"{len(rows)} not running"
    f = f'<div class="foot"><span>{count}</span><span>↑↓ move · ↩ starts</span></div>'
    m = ""
    if menu_on is not None:
        m = (f'<div class="menu" style="left:{left + 110}px;top:{top + 8 + 30 + menu_on * ROW + 14}px">'
             f'<div class="on">Remove from Deck…</div></div>')
    return (f'<div class="pop" style="left:{left}px;top:{top}px;--arrow:{arrow}px">{field}'
            f'<div class="rows">{"".join(out)}</div>{f}</div>{m}')


def build():
    css = CSS_BASE + START_CSS + "\n/* ---- generated tokens ---- */\n"
    for theme in ("light", "dark"):
        for H in HUES:
            css += theme_css(theme, H) + "\n"
    (HERE / "deck.css").write_text(css)

    n = len(CATALOG)
    foot_h = 114   # bead pane ≈ 80 + New 34, measured off the spec's frame
    start_h = 26 + n * ROW   # header + rows
    list_h = 640 - foot_h - start_h

    # -- 0. today -------------------------------------------------------------
    today = f'<div class="grid">' + labelled(
        "Today · 216pt · 17 catalog entries · light",
        frame("light", "full", rail_html("full", start_today(False), list_cls="starved"),
              measure=(list_h + 6, start_h, f"<b>START: {start_h}pt</b><br>26 + 17 × 26<br><br>The crews get the other <b>{list_h}pt</b>: two rows, and the selected one is not among them.")),
    ) + labelled(
        "Today · 216pt · dark",
        frame("dark", "full", rail_html("full", start_today(False), list_cls="starved")),
    ) + labelled(
        "Today · 44pt dot rail",
        frame("light", "dots", rail_html("dots", start_today(True), list_cls="starved")),
        "These are seventeen identical hollow squares in <code>--ink-3</code>. The spec draws a START mark without the crew's hue, so at 44pt these rows carry no information at all until hovered, one at a time.",
    ) + "</div>"

    # -- A. capped viewport ----------------------------------------------------
    a = '<div class="grid">' + labelled(
        "A · capped at 4 rows · light",
        frame("light", "full", rail_html("full", start_capped(False))),
        "The header carries the count. Four rows show; thirteen are behind a scroll with no visible scroller until the pointer is over it.",
    ) + labelled(
        "A · dark",
        frame("dark", "full", rail_html("full", start_capped(False))),
    ) + labelled(
        "A · 44pt",
        frame("dark", "dots", rail_html("dots", start_capped(True))),
        "Four hollow squares scroll. The count is gone with the label; nothing says there are thirteen more.",
    ) + "</div>"

    # -- B. disclosure ---------------------------------------------------------
    b = '<div class="grid">' + labelled(
        "B · collapsed (the default) · light",
        frame("light", "full", rail_html("full", start_disclosure(False, expanded=False))),
        "The section label is the whole section: a count and a chevron. One click expands it.",
    ) + labelled(
        "B · expanded · dark",
        frame("dark", "full", rail_html("full", start_disclosure(False, expanded=True))),
        "Expanded, it is today's rail again. The crews are gone until the user collapses it, and they will forget to.",
    ) + labelled(
        "B · 44pt, collapsed",
        frame("light", "dots", rail_html("dots", start_disclosure(True, expanded=False))),
        "A rule cannot carry a chevron, so one hollow square stands for the section. Expanding it at 44pt gives the third frame above.",
    ) + "</div>"

    # -- C. one row + picker ---------------------------------------------------
    # geometry: the START block is header 26 + row 26 above a 114pt foot, so
    # the opener row's centre is at 640 - 114 - 13; at 44pt the block is a
    # rule (17) + a 30pt row above a 57pt foot (meter 23 + New 34).
    row_mid = 640 - foot_h - 13
    row_mid_dots = 640 - 57 - 15
    promoted = ("Write Better",)
    remaining = [x for x in CATALOG if x not in promoted]
    c = '<div class="grid">' + labelled(
        "C · one row; the picker open · light",
        frame("light", "full", rail_html("full", start_opener(False, len(remaining), open_=True), promoted=promoted),
              side=popover(row_mid, 216 + 10, remaining, focus=0)),
        "START is always 52pt: its label and one row. The row opens a popover with a filter field and every catalog entry; ↑↓ and ↩ start one, and typing narrows the list. <b>Write Better</b> is running, so it draws under OTHER SESSIONS with a live mark and a selectable row, and the count reads 16.",
    ) + labelled(
        "C · closed · dark",
        frame("dark", "full", rail_html("full", start_opener(False, len(remaining)), promoted=promoted)),
        "This is the row at rest. The trailing count says how many are behind the row without spending a pixel per entry.",
    ) + labelled(
        "C · 44pt; the picker open",
        frame("dark", "dots", rail_html("dots", start_opener(True, len(remaining), open_=True), promoted=promoted),
              side=popover(row_mid_dots, 44 + 10, remaining, focus=4, typed="s")),
        "One hollow square sits under the rule, which is how the spec's dot rail already draws a START row. The popover is where the names live, so nothing is lost at 44pt; here the user has typed <b>s</b> and arrowed to Sous Chef.",
    ) + labelled(
        "C · right-click on a row · light",
        frame("light", "full", rail_html("full", start_opener(False, len(remaining), open_=True), promoted=promoted),
              side=popover(row_mid, 216 + 10, remaining, focus=-1, hover=6, menu_on=6)),
        "The row's context menu moves into the popover unchanged: Remove from Deck…, and Stop when a tmux session is behind the entry.",
    ) + "</div>"

    # -- D. recents + the rest -------------------------------------------------
    recents = ["Write Better", "NYH Studio", "Tax 2025"]
    d = '<div class="grid">' + labelled(
        "D · three most recent, the rest behind one row · light",
        frame("light", "full", rail_html("full", start_recents(False, recents, n - 3))),
        "START is fixed at four rows. The three most recently launched stay one click away; the rest are behind a row that opens C's picker.",
    ) + labelled(
        "D · 44pt",
        frame("dark", "dots", rail_html("dots", start_recents(True, recents, n - 3))),
        "There are four hollow squares, and the user has to remember which three are which.",
    ) + "</div>"

    body = f"""
<h2>The cause</h2>
<p class="note"><b>START is a static <code>ForEach</code> in the rail's outer <code>VStack</code>, below the crews' <code>List</code>, with no bound on its height</b>, so every catalog entry takes 26pt off the rail unconditionally, and the <code>List</code>, the only flexible element in the stack, gives up that 26pt from the crews. Seventeen entries cost 468pt of a 640pt rail. (The premise that START is a section inside the <code>List</code> is off by one container: <code>RailView.swift</code> draws it after the <code>List</code> and a <code>Divider()</code>. That is why the crews shrink rather than the whole rail scrolling, and it is also why bounding START is a sibling-layout change rather than a nested-scroll one.)</p>
<div class="frames"><div>{today}</div></div>

<h2>Why not the "needs you" chip</h2>
<p class="note">The rail already has a way to say "there is more below": the chip pinned to the list's bottom edge when a summons has scrolled out of view. It is the wrong tool here for the reason the spec gives for it: it is <i>an alert and not furniture</i>, absent whenever nothing needs an answer. A permanent "17 more" chip would make the alert's shape ordinary, and the next real summons would read as one more count. START needs its own bound.</p>

<h2>A · Cap START at four rows and scroll inside</h2>
<p class="note">Header gains a count; the rows sit in a <code>ScrollView</code> with <code>.frame(maxHeight: 104)</code>. Everything else is as today.</p>
<div class="frames"><div>{a}</div></div>
<p class="note"><b>Where it loses.</b> A second scroll region in a 216pt column, with macOS overlay scrollers that appear only on hover, so the only sign of thirteen hidden entries is a small number in the header. At 44pt even the number goes. Four visible rows is enough to browse three entries and not enough to browse seventeen; a catalog of fifty is fifty flicks of the wheel. And START rows stay unreachable by keyboard, as today. It fixes the height and not the "see what is in it".</p>

<h2>B · Collapse the section by default</h2>
<p class="note">The section label becomes a disclosure row with a count. Collapsed is the default and the state persists. Expanded draws every entry, as today.</p>
<div class="frames"><div>{b}</div></div>
<p class="note"><b>Where it loses.</b> Collapsed, it is the best-looking frame on this page: 26pt, a count, done. Expanded, it is the problem again, behind a click, and the user launches something from the expanded list and then has the same starved rail until they remember to fold it. Pairing B with A's cap on the expanded state fixes that at the cost of inheriting A's blind scroll. At 44pt a rule cannot disclose, so it needs a stand-in row anyway.</p>

<h2>C · One row that opens a picker</h2>
<p class="note">START is a label and one row, <b>Start a session…</b>, with the count in its trail. Activating the row opens an <code>NSPopover</code> off its trailing edge: a filter field with focus, then every entry as a rail row with its hollow square, ↑↓ to move, ↩ to start, Esc to close. The row's context menu (Stop, Remove from Deck…) moves into the popover's rows unchanged. <b>One rule comes with it:</b> a catalog entry that is running is no longer an invitation, so it draws in the <code>List</code> under OTHER SESSIONS with its live mark, where selection works — today a launched-but-unpinned entry stays under START as a hollow square with a hover Stop, and <code>launch()</code> selects a ref no visible row carries. This option is where that has to be fixed, because a running entry inside a closed popover would be invisible; the fix is deleting one filter in <code>otherSessions</code>.</p>
<div class="frames"><div>{c}</div></div>

<h2>D · The three most recent inline, the rest behind a row</h2>
<div class="frames"><div>{d}</div></div>
<p class="note"><b>Where it loses.</b> "Keep these few one click away" is what pinning already means; recency is a second, automatic version of the same idea, and the two will disagree (a thing pinned and recently launched shows twice, a thing recently launched then unpinned moves rows). It also needs a launch timestamp persisted per entry, which the catalog does not carry. If three entries are wanted in front of you, pin them.</p>

<h2>Recommendation</h2>
<div class="verdict">
<p class="note" style="margin:0 0 6px"><b>Build C.</b> It is the only option that is fixed height at any catalog size and at both rail widths, and the only one where the way to "see what is in it" scales: a filter and arrow keys work the same at seventeen entries and at seventy, where a four-row scroll (A) and a full expansion (B) both fail. It makes START reachable by keyboard for the first time. At 44pt it degrades to exactly what the spec already draws for a START row, one hollow square, and loses nothing because the names were never in the rail there. And it forces the one correctness fix the other options let slide, a running catalog entry appearing where selection can reach it.</p>
<p class="note" style="margin:0"><b>What has to be verified in the build:</b> (1) <code>.popover(isPresented:attachmentAnchor:arrowEdge:)</code> on a row that is a sibling of the <code>List</code>, with <code>arrowEdge: .leading</code> so it opens rightward at both widths; (2) keyboard focus landing in the field on open and ↑↓/↩ driving a <code>List(selection:)</code> inside the popover, which is a second selection binding and must not touch the rail's; (3) the popover dismissing on launch so the pane, not the popover, holds focus; (4) that deleting the <code>catalogIds</code> filter in <code>otherSessions</code> does not double-draw an entry that is both pinned and in the catalog, which <code>RosterEntry</code> already forbids. None of these is a nested-scroll hazard: START never was inside the <code>List</code>.</p>
</div>

<h2>What each costs</h2>
<table class="cost">
<tr><th>Option</th><th>Build</th><th>Effort</th></tr>
<tr><td>A · capped scroll</td><td>Wrap the <code>ForEach</code> in a <code>ScrollView</code> with <code>.frame(maxHeight:)</code>; add the count to <code>sectionHeader</code>; a test that the block's height stops growing at 4 rows.</td><td>Half a day.</td></tr>
<tr><td>B · disclosure</td><td>An <code>@AppStorage</code> bool, a chevron in the header, a stand-in row at 44pt; a test on the persisted default.</td><td>A few hours, and it does not solve the expanded case.</td></tr>
<tr><td>C · one row + picker</td><td>A <code>LauncherRow</code>-shaped opener with the count; a new <code>StartPickerView</code> (filter <code>TextField</code>, <code>List</code> of <code>LauncherRow</code>s, its own selection, ↩ calls <code>onLaunch</code>, context menu moved in) presented with <code>.popover</code>; delete the catalog filter in <code>otherSessions</code>; tests for the filter, the keyboard path, and the promotion rule.</td><td>A day to a day and a half, plus the review cycle.</td></tr>
<tr><td>D · recents + rest</td><td>C's picker plus a persisted last-launched date per catalog entry and a sort; more surface than C for a smaller gain.</td><td>C plus half a day.</td></tr>
</table>

<h2>What does not change</h2>
<ul class="note">
  <li><b>START rows still do not select.</b> The opener row is a button; the popover's rows are invitations that close it on ↩. The rail's <code>selection</code> binding is untouched by any of this, and <code>launch()</code> setting it to the started ref is what makes the promoted row light up.</li>
  <li><b>The dot rail, the summons bar, the selection wash and the child spine</b> are drawn from the spec's own CSS here, unmodified. The one new 44pt element is a hollow square under a rule, which <code>03-rail.html</code> already draws.</li>
  <li><b>⌘1–9</b> still reach the first nine top-level crews. The picker adds ↑↓/↩ inside itself; it claims no global shortcut. If one is wanted later, it is one <code>.keyboardShortcut</code> on the opener.</li>
  <li><b>Every colour is a solver token.</b> The popover is <code>--bg-chrome</code> on <code>--line</code>; the filter field is <code>--bg-input</code>; the focused row is the selection wash; the count is <code>--ink-3</code>, the same tier as a trailing chevron.</li>
</ul>
<p class="note" style="margin-top:28px;color:#6b6e78">Generated by <code>design/start-section/build.py</code>, which imports the spec's solver, row idiom and marks from <code>design/redesign/build.py</code>. Edit the generator, not this page.</p>
"""
    lede = ("A user who unpins crews over time ends up with a long START. Today every catalog entry costs the rail 26pt and the crews' list absorbs the loss, so the live sessions, the whole point of the rail, are pushed out of view. "
            "This page draws the failure with seventeen entries, three bounded shapes for START at 216pt and at the 44pt dot rail, and recommends one.")
    html = (HEAD.format(title="The START section", css=css) + f'<div class="doc">{SYMBOLS}<h1>The START section, bounded</h1>'
            + '<p class="nav"><a href="../redesign/index.html">← The Deck visual spec</a><a href="../redesign/03-rail.html">The rail</a><a href="../redesign/04-narrow.html">Narrow widths</a></p>'
            + f'<p class="lede">{lede}</p>{body}</div>\n')
    (HERE / "index.html").write_text(html)
    print("wrote", HERE / "index.html", "and deck.css")


if __name__ == "__main__":
    build()
