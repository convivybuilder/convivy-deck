# Test fixtures

Two kinds live here: SwiftTerm replay captures (`.bytes`) and a captured
settings file.

## `theme-pre-host-scope.json`

A verbatim copy of the `theme.json` on an operator's laptop the day before crews
became host-scoped, read by `PreHostScopeConfigFixtureTests`. That test's
claim is that an operator's real settings open intact and are rewritten in
the new form, and a hand-written sample would prove it only for the shapes
whoever wrote the sample thought of. It carries no credentials: `theme.json`
has no token, key or password field at all, and this file's `hosts` entries
hold a username and two private-network addresses, which is what an
operator's own hosts table holds.

Replace it only with another genuine capture. Editing it to make a test pass
removes the one property it has that a literal in a test file does not.

# SwiftTerm replay fixtures

Raw PTY byte captures, replayed through SwiftTerm's headless `Terminal`
parser in `SwiftTermReplayTests.swift`. This is fork 2's acceptance gate
(the architecture proposal, `agent-runs/2026-07-19/platform-architect-gui-client-1247/proposal.md`):
"each item gets a recorded-byte-diet replay fixture (capture real session
output with `tmux pipe-pane`, replay through SwiftTerm, compare screen
state)."

Every fixture here is a genuine capture, not a hand-written escape-sequence
string: a scratch tmux session (`deck-fixture-capture`, never one of the
live product sessions) piped its pane output to a file while a scripted
sequence of `printf`s ran inside it, so each `.bytes` file includes the
real tmux/bash noise (typed-command echo, prompt redraws, tmux's own
bracketed-paste toggling) alongside the effect under test — exactly what a
live `claude` session's output looks like once it passes through tmux.

| Fixture | Captures |
|---|---|
| `alt-screen.bytes` | Entering (`\e[?1049h`) and leaving (`\e[?1049l`) the alternate screen buffer, with distinct content written in each |
| `bracketed-paste.bytes` | Enabling (`\e[?2004h`) / disabling (`\e[?2004l`) bracketed-paste mode, with a `\e[200~ ... \e[201~` wrapped paste in between |
| `osc52-clipboard.bytes` | An OSC 52 clipboard-set (`\e]52;c;<base64>\a`) for the literal string `deck clipboard test` |
| `unicode-width.bytes` | Streamed CJK text (`你好世界`, 4 double-width cells) followed by plain ASCII, to check column-width accounting |
| `mouse-mode.bytes` | Enabling/disabling SGR mouse tracking (modes 1000 + 1006), the mode tmux itself uses |
| `sustained-streaming.bytes` | 200 iterations of a cursor-home + clear-line + SGR-colored line, approximating a TUI's redraw loop (claude's own repaint shape) |

## Reproducing a capture

```
tmux new-session -d -s deck-fixture-capture -x 80 -y 24
tmux pipe-pane -t deck-fixture-capture -o 'cat >> /path/to/fixture.bytes'
tmux send-keys -t deck-fixture-capture "printf '...'" Enter
# ... more send-keys as needed, with a short sleep between each so the
# pane finishes processing before the next one lands ...
tmux pipe-pane -t deck-fixture-capture   # stop piping
tmux kill-session -t deck-fixture-capture
```

## What this gate does not cover

**IME composition** (fork 2's acceptance list) isn't a captured-byte-diet
concern at all — it's client-side input handling (how the terminal view's
`NSTextInputClient` conformance handles a composing string before anything
reaches the PTY), the reverse direction from everything else in this
table. It needs a live UI test (XCUITest driving actual IME composition),
not a replay fixture, and isn't covered by this PR.
