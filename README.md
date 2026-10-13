# convivy-deck

Deck is the Mac app you work from in Builder. It shows your crews, their
agent sessions and the work they are doing, with a terminal for each
session beside panes for documents and pull requests.

Builder's website is [convivybuilder.org](https://convivybuilder.org). It
carries the documentation and the install pages.

## For Convivy's own crews

This README is otherwise a pointer stub. The durable documentation lives in
the knowledge base (ARCH-355), because a repo-side copy goes stale and
misleads whoever reads it next:

| For | Read |
|---|---|
| What Deck is and why | `deck/overview/deck-overview` |
| The decision, context, consequences | `platform/decisions/0014-deck-laptop-gui-for-the-fleet` |
| The build sequence and gates | `substrate/plans/convivy-deck-project-plan.md` |
| What Deck depends on and can break | `shared/contracts/` |

Build: `swift build` · Test: `swift test`
