# convivy-deck

A native macOS client for the Convivy agent fleet. Swift/SwiftUI shell with
SwiftTerm terminal views, embedding WKWebView panes for document-shaped surfaces.

## Build and test

```
swift build
swift test          # XCTest; this IS the CI command, run it before pushing
```

CI runs on a **self-hosted runner on the Studio (`macstudio`), as its own macOS
account `deck-runner`** (gate G2). It cleans `.build` between jobs, because a
self-hosted runner keeps state and stale DerivedData is a real source of
green-that-lies.

## The boundary rule

Chrome, rail, strip, and terminals are **native**. Document- and stage-shaped
surfaces are **web** (WKWebView panes). Both draw from one design-token source
generated to Swift and CSS, so Deck and team.convivy.com read as one system.

**The shell is the single appearance authority.** It follows the system
appearance and stamps `data-theme` into every pane in the same frame. Panes never
self-decide via `prefers-color-scheme` — that is how a light rail ends up beside a
dark pane.

## What Deck couples to

**Data contracts, not code.** Read them before changing anything that consumes
platform data; each names its producer, its consumers, the fields relied on, the
executable check, and the change protocol:

- `agent-platform/contracts/active-json`
- `agent-platform/contracts/run-dir-schema`
- `agent-platform/contracts/claude-hook-payloads` — Anthropic's shape, observed not owned
- `agent-platform/contracts/claude-transcript-jsonl` — likewise
- `shared/contracts/fleetd-api`, `design-tokens`, `orient-fleet-facts`,
  `action-gate` — land with the workstreams that create those surfaces

**Every review checks whether a change touches a contract surface, and whether
the contract doc moved with it.**

The two Anthropic-owned formats can change in any Claude Code release. Consumers
degrade per field: an unparseable record demotes a row to "state unknown", never
drops it. The terminal pane is the drift-proof fallback, because raw PTY bytes
cannot drift.

## CI runs as `deck-runner` — what that closes and what it leaves

The runner is a system LaunchDaemon, `com.convivy.deck-ci-runner`, with
`UserName` `deck-runner`: a standard account with no access to the operator's
home, which is `chmod 700`, and no way to unlock the operator's login Keychain.
It starts at boot with no login of its own. Its AppKit window tests run while the
operator's own account is logged in at the console, which the Studio's auto-login
provides after every boot. The procedure,
and the evidence each choice rests on, is the runbook
`deck/runbooks/ci-runner-own-account` (KB).

**Every job checks the separation** before PR code is checked out: the step
"Runner must not be able to read the operator's credentials" fails the job unless
the runner runs as `deck-runner`, if it can read any other account's home under
`/Users` or the `gh` config inside it, and if it finds no other home to check. Before the move that step
failed on the mini's runner, which ran as the operator's own account; that failure
is what shows the step can fail.

What the account move closes is a workflow step reading the operator's credentials. What it
leaves is everything `deck-runner` itself can do: build-phase code from a
compromised Swift dependency still runs with network access on the fleet host.

Two further guards narrow it, and **it matters exactly how far each one reaches**:

- The **installer** refuses to register against a non-private repo. Install-time
  only; it cannot see a later flip in repo settings.
- **Every job re-asserts the repo is private** before checking out PR code. This
  covers the flip-to-public case.

**None of the per-job guards is self-protecting, and that is not a detail.** For
`pull_request` events GitHub runs the workflow from the **PR's head commit**, not
from `main` — verified empirically on PR #1, whose run used the head SHA and
executed a workflow step that exists only on the branch. So a PR that deletes the
privacy assertion, or the credential check, gets the guard-free workflow executed.
The guards defend against a repo flipped public and a runner reinstalled as the
operator; they do **not** defend against a PR that edits them.

What actually holds the line today is that **only the operator has write access**. The
guards are defence in depth behind that fact, not a substitute for it.

**The moment either condition changes — a collaborator is added, or the repo
becomes public — the posture is no longer proportionate**, and two things become
required rather than optional:

1. Making the guards self-protecting — `pull_request_target` with a
   required-approval environment, or branch protection requiring admin review of
   any `.github/` change.
2. Disabling the self-updating launcher, or separating it. `Deck.app`'s bundle
   executable fetches `main` and compiles it on a Dock click, so a collaborator's
   push executes as the operator on the **laptop** on the next launch — a second
   path with none of CI's guards in it: no privacy assertion, no lane guard, no
   runner account. Until the launcher runs somewhere it cannot reach the
   operator's Keychain, SSH keys, and `~/.claude`, set `APP_AUTO_UPDATE_ENABLED=false` in the app's
   environment or rebuild the bundle in the default `shipped` flavor
   (`./Scripts/make-app.sh` with `DECK_BUNDLE_FLAVOR` unset), which installs no
   launcher script, no `repo-path` and no auto-update marker. Only
   `DECK_BUNDLE_FLAVOR=developer` produces the self-updating bundle.

Neither is done. This note is the trigger for doing them.

## Boundaries

- **No agent merges PRs.** The operator is the human in the loop (ARCH-020).
- Every PR runs the full review/revise cycle: `deck-reviewer` +
  `deck-security-reviewer`, revise on substantive findings, re-review the new head.
  **Do not push while a reviewer is running** — its stamp is discarded as a stale
  replay while the thread still shows APPROVE.
- Reviewers post with the `mcp__verdict__review_post` tool, which posts through
  `agentctl review-post`; never Bash `agentctl review-post` from a dispatched run
  (the sandbox refuses it), and never `gh pr comment`.
- Never put a credential in a plist, a workflow file, or the runner environment
  (ARCH-146, ARCH-342).

## Post-merge ceremony

After the operator merges a PR, the co runs the post-merge ceremony. The steps and
the gate conditions are in `deck/runbooks/post-merge` (KB); that runbook is
the source of truth. Its whole job is confirming `main` still builds and
passes with the merge in it.

**The ceremony does not write the changelog entry.**
`bin/changelog-drain`'s dispatched `explainer` is the sole author of every
entry, fleet-wide (`platform/decisions/0035-changelog-drain-sole-authorship`).
Deck used to post its own here via `post-changelog`, and that write and the
drain's landed on the same dedup key — the store kept whichever won the race.
A co that posts one now is racing the drain for the entry nobody reads twice.

## Dispatch

`convivy-deck` is a native `agentctl` target mapping to the `deck` KB project:

```
agentctl spawn deck-reviewer --on convivy-deck --pr <N> --task "..."
```

Background an `agentctl wait <run-id>` immediately after dispatching — nothing
else will tell you the run finished (ARCH-367).
