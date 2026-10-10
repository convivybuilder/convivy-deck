# Input pane redesign — rationale

Design for epic `issue_01M1CK00SE7RB3TJWNKAW480ZH` ("The input pane is redesigned").
The mock is `input-pane-mock.html` beside this file; it shows every state of the row,
today beside the proposal, in light and dark. The operator's screenshot is `input-pane-today.png`.
This is a design, not an implementation — no code changed.

## The proposal in one paragraph

The controls move from a column beside the box to a full-width bar beneath it. Commands
and a held-queue chip anchor the bar's left edge; a single fixed-width primary slot
anchors its right and only ever holds the safe action — Send, or Replace when the box
holds a pulled queue. Interrupt is its own bordered destructive button, present exactly
while a turn runs, in one fixed position in the bar's flexible middle, with the keyboard
hint between it and the slot. The send key rides on the primary button's face ("Send ↩" /
"Send ⌘↩") at full size; the caption keeps only the newline half. The Commands glyph
becomes SF Symbol `terminal`; Interrupt gets `stop.fill`.

## The premise that failed, and the revision (2026-08-31, second pass)

The first pass merged Send and Interrupt into the one slot on the claim that they are
mutually exclusive in the model — "Send is disabled exactly while the session is working".
The implementing coder checked that before relying on it, and it is false: `canSend` never
reads `isWorking`, and `Phase.working.acceptsMessage` is `true`, pinned by
`SessionAgentTests`. That is the held-queue mechanism — sending while a turn is in flight
queues the message rather than being refused, which is a normal thing a person does. So
Send and Interrupt can both be actionable at once, the mock never drew that state (every
working frame had an empty box), and in it the merged slot had no Send button and a
destructive control sitting in Send's position. The ~300 ms inert guard covered the moment
Send morphs into Interrupt, not a slot that is already Interrupt when typing starts. The
operator sent the design back rather than letting implementation patch around it.

The revision: **Interrupt never enters the slot.** The slot always holds the safe action,
accent-filled when actionable and a dimmed slab when not, and Interrupt is a separate
bordered `stop.fill` button that exists exactly while a turn runs, left of the hint,
growing into the bar's flexible middle the way the held chip grows in from the left. Three
things follow:

- **The right edge is safe and still in every state.** The operator's suggested fix was to show
  both buttons and accept the right edge shifting in the one working-with-text state. This
  shows both without the shift: Interrupt appears in flexible space with both neighbours
  fixed, so the hand's target neither moves nor turns destructive, ever.
- **The inert guard is deleted, not relocated.** The slot morphs only between Send and
  Replace, both safe, so no transition needs guarding. The hybrid that keeps the merged
  slot only while the box is empty was drawn and rejected in the mock: clicking Send
  mid-turn queues the message and empties the box, so Interrupt would materialise under
  the still-resting pointer — the guard would have to come back to defend the design's own
  primary action.
- **The hint is a buffer.** "⇧↩ new line" sits between Interrupt and Send, so a click
  drifting left of the primary lands on dead text rather than on the stop.

One more rename was considered and rejected: labelling the primary "Queue ↩" while a turn
runs, since that is what the click does. The chip already announces the held state the
moment it happens ("↑ 1 held"), and a primary that changes its name with every phase stops
being a landmark; Replace spends the whole renaming budget.

## What each change solves

**Problem 1 — the Commands icon says the opposite of what it means.**
`slash.circle` is replaced by **`terminal`**: a rounded rectangle enclosing a `>` prompt
and a text-cursor underscore — it depicts a command prompt, the place commands are typed,
which is what picking a menu entry does (it puts `/command` in the box). It is available
from macOS 12 and the target is macOS 14. The runner-up was `ellipsis.circle`, the
platform's generic "more actions" mark — rejected because it says "miscellaneous", and
this menu answers a specific question ("did my commands load, and what are they"). Every
slash-in-a-circle variant was rejected outright: a slash inside a circle reads as the
prohibited mark whatever the intent.

**Problem 2 — hierarchy is inverted in the common case.**
The primary slot draws as a filled slab in every state: accent-filled when Send/Replace
is available, a dimmed slab when disabled. Send never again draws paler than a secondary
control; even disabled it holds the visual weight of the primary. Commands drops to the
quiet end of the scale (borderless, secondary ink) where a menu belongs. While a turn runs
with nothing typed, the bordered Interrupt reads stronger than the dimmed slab beside it —
deliberately, because in that state it is the only click that does anything; the inversion
the operator screenshotted was Send drawing flattest while *actionable things* outdrew it.

**Problem 3 — the row's contents move.**
Three moves, together:
- Interrupt leaves the right edge entirely. It is one control in one place — a bordered
  destructive button left of the hint — present exactly while a turn runs, appearing in
  the bar's flexible middle so nothing already drawn moves. The slot has a fixed width
  (its widest label) and morphs only between Send and Replace, both safe, so no
  transition needs an inert guard.
- The Rewrite button becomes a chip ("↑ 2 held") on the *left*, next to Commands, growing
  rightward into empty space. Its appearance leaves the right edge — the thing the hand
  targets — pixel-identical. The ↑ names the up-arrow gesture that already pulls the
  queue back.
- The bar is full-width beneath the box, so the box itself stops resizing. Today the
  control column's width varies with state and the composer narrows to make room; that
  is a jump the epic's diagnosis didn't even list, visible in the mock's "today" frames.

**Problem 4 — the caption does real work in the smallest type on screen.**
The load-bearing half (which key sends) moves onto the primary button itself, in the
button's own type size, exactly where the eye goes before sending. The caption keeps only
the secondary fact ("⇧↩ new line" / "↩ new line"), which is now doing small work in small
type. Both preferences stay live and visible; ⌘↩ stays bound under both, unchanged.

**The Send → Replace rename** (the epic's fifth observation) now reads deliberate: when
the box holds a pulled queue the chip turns accent and says "editing 2 held", and the
primary agrees by reading "Replace ↩". The mode is announced by the pane, not implied by
a button quietly changing its own name.

## Deliberately unchanged

- **All behaviour.** Send/Replace semantics, the held-queue mechanism (↩, ⌘↩ and the Send
  button all queue a message while a turn runs), the up-arrow pull-back predicate, the
  Return-key interception, ⌘↩ under both preferences, the Commands menu's contents and
  its load/error/empty states, and every tooltip's substance.
- **The focus outline** on the box — it is the only focus signal left and it works.
- **The composer's tint** matching the session accent.
- **Native SwiftUI.** Everything here is a `Label`, `Button`, `Menu`, and a fixed-frame
  slot; SF Symbols throughout, so the text-scale preference holds. Nothing needs a web
  pane, and the pane keeps taking its appearance from the shell.

## The cost, named

The revision reintroduces one appearing-and-disappearing control: Interrupt comes and
goes with the working phase, where the merged slot had nothing appear at all. It appears
in flexible space with both neighbours fixed, so the bar gains an element without anything
moving; the price is busyness, not motion. At full occupancy — working, messages held,
text typed — the bar carries six elements, its densest frame, where the merged design
carried five. Interrupt also sits roughly a hint's width further from the corner than the
first pass put it; that distance is the buffer, spent on purpose.

The bar spends roughly 30 pt of vertical height the side-column layout did not. In
exchange the composer gets the full pane width (today it is narrowed by the control
column) and the layout holds still completely. Option B in the mock keeps the side-column
geometry with the same icon, hierarchy, and slot fixes; it saves the height but the box
still narrows when the chip appears and the composer never widens. Recommendation:
**Option A**, the bar. A composer with its controls beneath it is also the shape every
tool in this category has trained hands on.

## Accessibility

Every affordance keeps a label: "Commands" (menu), "2 messages held — pull back to edit"
(chip, as a button), "Send message" / "Replace held messages" (the slot), "Interrupt the
running turn" (its own button, present only while a turn runs), and the hint text is real
text, not an image. The disabled slab exposes `isEnabled = false` so VoiceOver says
"dimmed" rather than the control vanishing.
