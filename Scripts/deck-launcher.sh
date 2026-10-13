#!/bin/bash
#
# Convivy Builder.app/Contents/MacOS/Deck — the launcher.
#
# WHY THE BUNDLE EXECUTABLE IS A SCRIPT. Clicking the Dock icon should run the
# code that is in the checkout, not whatever was compiled the last time someone
# remembered to run make-app.sh. Something has to check that before the app
# starts, and the bundle executable is the only thing macOS runs on a click.
#
# WHY IT NEVER RUNS make-app.sh. That script begins `rm -rf "$APP_DIR"`, so
# calling it from inside the bundle would delete the running launcher — bash
# reads a script by offset as it executes, so a file replaced underneath it
# resumes at a byte offset into different content. This swaps ONE file instead:
# `deck-bin`, which nothing is executing yet.
#
# THE TRUST BOUNDARY, stated plainly. A click can fast-forward main from origin
# and compile the result, but only for a bundle that opted in. Anyone who can
# push to convivy/convivy-deck can therefore run code as the operator on the
# laptop by pushing to main, when that opt-in is set — the same boundary as
# typing `git pull && swift build` by hand, which this replaces when active, and
# it rests on the same fact CLAUDE.md names for CI: only the operator has write
# access. It
# is NOT a new privilege — but it is an automatic one when enabled, so:
#   - the default is OFF: a bundle with nothing configured never fast-forwards
#     or builds anything
#   - opting in takes an explicit `APP_AUTO_UPDATE_ENABLED=true` in the
#     environment, or the `auto-update-opt-in` marker write-bundle-metadata.sh
#     writes into every bundle it builds
#   - `--ff-only`, so a rewritten main is refused rather than merged
#   - clean tree and on main, or no fetch happens at all
#   - `APP_AUTO_UPDATE_ENABLED=false` in the environment always wins, even over
#     the opt-in marker
# Widening write access to the repo makes this a decision to revisit, not a
# detail. Same trigger as the CI runner note in CLAUDE.md.
#
# AN UPDATE FAILURE MUST NEVER COST THE OPERATOR THE APP. Every failure below falls
# through to launching the binary that is already there. `set -e` is deliberately
# absent for that reason; failures are handled where they happen.
set -uo pipefail

BUNDLE_MACOS="$(cd -- "$(dirname -- "$0")" && pwd)"
SELF="$BUNDLE_MACOS/$(basename -- "$0")"
BINARY="$BUNDLE_MACOS/deck-bin"
RESOURCES="$(cd -- "$BUNDLE_MACOS/../Resources" 2>/dev/null && pwd)"
CONTENTS="$(cd -- "$BUNDLE_MACOS/.." 2>/dev/null && pwd)"
LOG_DIR="$HOME/Library/Logs/Deck"
LOG="$LOG_DIR/launcher.log"
LOCK="$LOG_DIR/update.lock"
# Only the process that created the lock may remove it. Without this, a launch
# that found the lock already held would delete it on its way out and hand a
# second builder to the next click, which is the race the lock exists to stop.
LOCK_HELD=0

mkdir -p "$LOG_DIR" 2>/dev/null
# One log, truncated per launch: this is for diagnosing the launch that just
# happened, and an unbounded log on every Dock click is its own bug.
: >"$LOG" 2>/dev/null

say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$LOG" 2>/dev/null; }

# AN APPLESCRIPT STRING LITERAL IS A CODE CONTEXT. Both of these are pasted
# into one, so a value carrying a double quote closes the literal and whatever
# follows is executed — `1" & (do shell script "…") & "` is a working shell
# execution, demonstrated by deck-security-reviewer against this very script.
# Backslash first, or escaping the quotes would then be undone.
#
# Every caller today passes either a fixed string or a value that cannot
# contain a quote, so this escapes nothing in practice. It is here so that
# stays true of callers nobody has written yet: the alternative is a rule each
# one has to remember, and the first to forget it gets code execution.
escape_applescript() {
    # `tr` last, and it is not about injection — deck-security-reviewer
    # confirmed a newline cannot reopen a code context, because every quote is
    # escaped unconditionally. It is about a dialog that silently does not
    # appear: an AppleScript string literal cannot span lines, so a newline in
    # the value makes the whole script fail to compile, osascript errors into a
    # discarded stderr, and the notification this PR exists to show is never
    # drawn. A helper whose job is telling the operator something must not have
    # an input that quietly tells them nothing.
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\r' '  '
}

# DECK_NO_UI=1 suppresses both of the below. The test suite sets it, because a
# test that exercises the no-binary path would otherwise raise a modal alert on
# the CI runner and block the job until someone clicked it.
notify() {
    say "notify: $1 — $2"
    [ "${DECK_NO_UI:-0}" = "1" ] && return 0
    /usr/bin/osascript -e "display notification \"$(escape_applescript "$2")\" \
with title \"$(escape_applescript "$1")\"" >/dev/null 2>&1
}

# A dialog IS right for a failure, because it is the only case where the app is
# about to behave differently from what the operator asked for.
alert() {
    say "alert: $1 — $2"
    [ "${DECK_NO_UI:-0}" = "1" ] && return 0
    # Same code context as `notify`, same escaping, for the same reason.
    /usr/bin/osascript -e "display alert \"$(escape_applescript "$1")\" \
message \"$(escape_applescript "$2")\" as critical" >/dev/null 2>&1
}

# `timeout(1)` is coreutils, not macOS — present on the mini via Homebrew and
# absent from a stock laptop, so relying on it would work in every place this
# was tested and fail on the one machine it runs on. This is the portable shape.
run_with_timeout() {
    local seconds="$1"; shift
    "$@" >>"$LOG" 2>&1 &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$seconds" ]; then
            kill -TERM "$pid" 2>/dev/null
            sleep 1
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            say "timed out after ${seconds}s: $*"
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
}

# Launch what we have and replace this process with it. Called from several
# failure paths as well as the success path.
#
release_lock() {
    if [ "$LOCK_HELD" = "1" ]; then
        LOCK_HELD=0
        rm -rf "$LOCK" 2>/dev/null
    fi
    return 0
}

# THE LOCK IS RELEASED HERE AND IN AN EXIT TRAP, AND IT NEEDS BOTH. `exec`
# replaces this process image, so a trap never runs on the launch path — that is
# why the release is explicit here. But `exit` is not `exec`: the build-failed-
# and-no-binary path below leaves without passing through `launch()` at all, and
# an explicit-release-only design leaks the lock there. That leak is quiet and
# lasts 30 minutes, during which every click reports a phantom concurrent update
# instead of the build failure the user needs to see. Found by deck-reviewer.
launch() {
    release_lock
    if [ ! -x "$BINARY" ]; then
        say "no binary at $BINARY"
        alert "Deck cannot start" \
              "No built binary in the app bundle. Run DECK_BUNDLE_FLAVOR=developer ./Scripts/make-app.sh in the checkout."
        exit 1
    fi
    say "exec $BINARY"
    exec "$BINARY" "$@"
}

# Case-insensitive, and the default is OFF: absence, an empty value, or
# anything unrecognized all mean "do not update". Self-update is an automatic
# privilege (see the header), so a bundle with nothing configured — the
# ordinary case for a copy handed to someone else — must never enable it by
# falling through a `*` case the way an earlier version of this script did.
# The one path back to "on" without the environment variable is the
# `auto-update-opt-in` marker write-bundle-metadata.sh writes into every
# bundle IT builds, checked below only once the environment variable itself
# has failed to settle the question either way.
#
# WHY WHITESPACE IS DELETED RATHER THAN TRIMMED. Three rounds on PR #128 each
# fixed a shape of whitespace and left another: `false `/` false` (a
# hand-edited plist), then `"false "`/`" false"` (whitespace inside quotes,
# exposed at the new outer edge once a single trim-then-dequote took the
# quotes off), then — caught by deck-reviewer actually running this block
# rather than reading the diff — a value split across LINES by an embedded
# newline, the shape a pretty-printed LaunchAgents plist produces. `sed`'s `^`
# and `$` anchor to line boundaries, not to the value, so a second trim pass
# still could not reach a leading newline: it is never at the start of the
# final line's content. Each fix kept the same ordered trim/dequote/trim
# model, which assumes "the ends of one line" is the same thing as "the ends
# of the value" — true until a value spans more than one line.
#
# Deleting all whitespace before doing anything else has no such edge: no
# value in either set below contains internal whitespace, so removing it
# cannot move a real value from one set to the other, and it needs nothing
# line-anchored to do it. THE ONE BEHAVIOUR CHANGE, DELIBERATE: a value with
# INTERNAL whitespace that spells a false word (`fal se`) now disables where
# it previously updated. That is accepted — no legitimate value in either set
# contains internal whitespace, so it is not reachable by accident from a
# plist, a shell export, or JSON.
#
# The quote strip runs AFTER whitespace deletion, not before, so a
# newline-wrapped quoted value (`\n"false"\n`) reduces the same way a bare
# `"false"` does rather than leaving the quotes as the new outer edge.
app_auto_update_enabled_raw="${APP_AUTO_UPDATE_ENABLED-}"
app_auto_update_enabled_clean="$(printf '%s' "$app_auto_update_enabled_raw" | tr -d '[:space:]')"
case "$app_auto_update_enabled_clean" in
    \"*\") app_auto_update_enabled_clean="${app_auto_update_enabled_clean#\"}"
           app_auto_update_enabled_clean="${app_auto_update_enabled_clean%\"}" ;;
    \'*\') app_auto_update_enabled_clean="${app_auto_update_enabled_clean#\'}"
           app_auto_update_enabled_clean="${app_auto_update_enabled_clean%\'}" ;;
esac
# `disabled` is here because it is the natural guess for a variable named
# `*_ENABLED`, and `off` alongside it — both raised independently by
# deck-reviewer and deck-security-reviewer. An explicit negative spelling
# always wins, even over the opt-in marker checked in the `''` case below —
# that is the kill switch CLAUDE.md documents.
app_auto_update_enabled_lower="$(printf '%s' "$app_auto_update_enabled_clean" | tr '[:upper:]' '[:lower:]')"
case "$app_auto_update_enabled_lower" in
    true|1|yes|on|enabled)
        app_auto_update_enabled=1
        app_auto_update_reason="APP_AUTO_UPDATE_ENABLED=$app_auto_update_enabled_clean" ;;
    false|0|no|off|disabled)
        app_auto_update_enabled=0
        app_auto_update_reason="APP_AUTO_UPDATE_ENABLED=$app_auto_update_enabled_clean" ;;
    '')
        # Nothing set: the marker is the only other affirmative there is.
        if [ -n "$RESOURCES" ] && [ -e "$RESOURCES/auto-update-opt-in" ]; then
            app_auto_update_enabled=1
            app_auto_update_reason="auto-update-opt-in marker present"
        else
            app_auto_update_enabled=0
            app_auto_update_reason="no APP_AUTO_UPDATE_ENABLED and no opt-in marker"
        fi ;;
    *)
        # A typo silently read as OFF and a typo silently read as ON look
        # identical to whoever mistyped it; only one of those is safe, so this
        # is never silent about which one happened.
        app_auto_update_enabled=0
        app_auto_update_reason="APP_AUTO_UPDATE_ENABLED=$app_auto_update_enabled_clean is unrecognized" ;;
esac
# Logging the cleaned value rather than the raw one: an embedded newline or
# control character in the raw value could otherwise fabricate what looks
# like a second timestamped log line in the launcher log.
if [ "$app_auto_update_enabled" = "0" ]; then
    say "auto-update decision: off ($app_auto_update_reason) — skipping update"
    launch "$@"
fi
say "auto-update decision: on ($app_auto_update_reason)"

# WHERE THE CHECKOUT IS, recorded at package time rather than derived from the
# bundle's own location. Deriving it would tie the bundle to living inside
# .build/artifacts, and the whole point of a bundle is that it can be moved to
# /Applications.
REPO=""
if [ -n "$RESOURCES" ] && [ -r "$RESOURCES/repo-path" ]; then
    REPO="$(head -n 1 "$RESOURCES/repo-path" 2>/dev/null)"
fi

# Read, never evaluated, and checked before use: this file is inside a bundle
# that may have been copied from somewhere else, so a path that is relative,
# empty, or not a git worktree means "no update", not "try anyway".
case "$REPO" in
    /*) ;;
    *) say "repo-path missing or not absolute (${REPO:-empty}) — skipping update"; REPO="" ;;
esac
# `-e`, not `-d`: in a secondary worktree `.git` is a file pointing at the real
# git dir, so a directory test reads a perfectly good checkout as not one and
# silently stops updating. Caught by deck-reviewer.
if [ -n "$REPO" ] && [ ! -e "$REPO/.git" ]; then
    say "$REPO is not a git checkout — skipping update"
    REPO=""
fi
[ -n "$REPO" ] || launch "$@"

# ONE UPDATE AT A TIME. Two Dock clicks in quick succession would otherwise run
# two `swift build`s against one .build directory. `mkdir` is the atomic test
# here; a lock file written with `>` is not.
if mkdir "$LOCK" 2>/dev/null; then
    LOCK_HELD=1
else
    # A lock older than 30 minutes is a crashed update, not a running one — a
    # release build does not take that long, and a stale lock that is never
    # broken means the app silently stops updating forever.
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ] \
       && rm -rf "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null; then
        say "broke a stale lock"
        LOCK_HELD=1
    else
        say "another update is running — launching current binary"
        launch "$@"
    fi
fi
# Covers every exit that does not go through `launch()` — today that is the
# build-failed-with-no-binary path, and tomorrow it is whatever gets added
# without remembering the lock. `release_lock` clears LOCK_HELD, so the trap
# firing after an explicit release is a no-op rather than a second `rm`.
trap release_lock EXIT

say "checkout: $REPO"

# FAST-FORWARD ONLY, AND ONLY FROM A CLEAN main. A dirty tree or a feature
# branch means the operator is working, and silently moving their HEAD out
# from under them is worse than launching slightly stale code. Both cases
# still build, so a
# branch build still gets picked up.
branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
dirty="$(git -C "$REPO" status --porcelain 2>/dev/null)"
before="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"

if [ "$branch" != "main" ]; then
    say "on '$branch', not main — building local source without fetching"
elif [ -n "$dirty" ]; then
    say "working tree is dirty — building local source without fetching"
else
    # Bounded, because a Dock click must not hang on a network that is not
    # there. A failed or slow fetch is a no-op: the build below still runs.
    if run_with_timeout 25 git -C "$REPO" fetch --quiet origin main; then
        if git -C "$REPO" merge --ff-only origin/main >>"$LOG" 2>&1; then
            say "fast-forwarded to $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
        else
            say "not a fast-forward — leaving HEAD alone"
        fi
    else
        say "fetch failed or timed out — building local source"
    fi
fi

after="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"

# Tell the operator BEFORE a slow build, and only when there is reason to expect one. A
# no-op `swift build` takes a second or two and deserves no notification; a
# build after a fast-forward can take a minute, and an app that appears to do
# nothing for a minute reads as broken.
if [ "$before" != "$after" ] || [ ! -x "$BINARY" ]; then
    notify "Deck" "Updating to $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)…"
fi

say "building"
if ! run_with_timeout 600 swift build -c release --package-path "$REPO"; then
    say "build failed"
    if [ -x "$BINARY" ]; then
        notify "Deck" "Build failed — launching the previous version. See $LOG"
        launch "$@"
    else
        alert "Deck could not be built" "See $LOG for the compiler output."
        exit 1
    fi
fi

BUILT="$REPO/.build/release/Deck"
if [ ! -x "$BUILT" ]; then
    say "no build product at $BUILT"
    launch "$@"
fi

# SIGN THE BUILD PRODUCT IN PLACE, BEFORE THE COMPARISON. make-app.sh gives the
# bundle's binary hardened runtime; an update must keep it. Signing here rather
# than after the copy keeps `cmp` meaningful: an ad-hoc signature carries no
# timestamp, so re-signing an unchanged binary produces the same bytes and an
# unchanged build still reads as current. An unsigned binary is never installed.
if ! codesign --force --sign - --options runtime "$BUILT" >>"$LOG" 2>&1; then
    say "could not sign the new build — launching the previous one"
    launch "$@"
fi

# Copy-then-rename so the swap is atomic and a crash mid-copy cannot leave a
# truncated executable in the bundle. The temp file is a sibling, because
# `mv` is only atomic within one filesystem and /tmp is not guaranteed to be
# the bundle's.
if ! cmp -s "$BUILT" "$BINARY"; then
    if cp "$BUILT" "$BINARY.incoming" && mv -f "$BINARY.incoming" "$BINARY"; then
        say "installed new binary"
        notify "Deck" "Updated to $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
    else
        rm -f "$BINARY.incoming" 2>/dev/null
        say "could not install new binary — launching the previous one"
        # LEAVE BEFORE THE METADATA REFRESH, like every other path that ends up
        # running the previous binary. `$BINARY` is still the old executable
        # while `repo_build` is the checkout's current HEAD, so refreshing here
        # would stamp the bundle AHEAD of what is about to launch — the same
        # lie as a stale bundle, told in the other direction, and the one this
        # whole script exists to stop telling. Found by deck-reviewer.
        launch "$@"
    fi
else
    say "binary already current"
fi

# AND NOW THE REST OF THE BUNDLE, WHICH THIS USED TO ONLY COMPLAIN ABOUT.
# `deck-bin` is current from here down, so the app BEHAVES as though it
# updated, while Info.plist and Deck.icns stayed frozen at whenever make-app.sh
# last ran. Nothing looked wrong, which was the problem: on 2026-08-12 a bundle
# packaged at build 92 was in daily use against a checkout at 268, running
# current code behind July's icon, and the stale About box had already misled a
# day of testing. The first version of this warned; a warning still leaves the
# operator to go and run a command, which is the step this removes.
#
# WHY IT CAN REFRESH THESE AND NOT ITSELF. `write-bundle-metadata.sh` writes
# only data — the plist, the icon, the recorded checkout, PkgInfo — each via a
# temporary and a `mv`, so a bundle refreshed under a running app is never
# observed half-written. It deliberately does not touch `Contents/MacOS/Deck`,
# this script, which bash reads by byte offset as it executes; replacing that
# underneath a running launcher resumes it at an offset into different content.
# That one file is what the notification below still exists for.
#
# Running a script out of the checkout is not a new privilege: this already
# fast-forwards main and compiles it, which is the boundary the header names.
INFO_PLIST="$CONTENTS/Info.plist"
bundle_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null)"
# DIGITS OR NOTHING. This comes out of a file inside a bundle that may not have
# been assembled by make-app.sh at all, and make-app.sh only ever writes it from
# `git rev-list --count` — so anything else is not a build number and there is
# nothing to compare against. Treated as a mismatch, which refreshes it.
case "$bundle_build" in
    ''|*[!0-9]*)
        say "CFBundleVersion is not a build number: ${bundle_build:-empty}"
        bundle_build="" ;;
esac
repo_build="$(git -C "$REPO" rev-list --count HEAD 2>/dev/null)"

WRITER="$REPO/Scripts/write-bundle-metadata.sh"
if [ -n "$repo_build" ] && [ "$bundle_build" != "$repo_build" ] && [ -x "$WRITER" ]; then
    say "refreshing bundle metadata: build ${bundle_build:-none} against checkout $repo_build"
    # Bounded and non-fatal, like every other step here. It runs `swift` to draw
    # the icon, and a cosmetic refresh must never hold up or cost the launch —
    # an app that will not open because its icon would not render is a far worse
    # failure than a stale icon.
    if run_with_timeout 120 "$WRITER" "$CONTENTS/.." "$REPO"; then
        say "bundle metadata now at build $repo_build"
        # LaunchServices caches the icon per bundle and will not re-read it on
        # its own. Touching the bundle is what makes the new one appear without
        # a logout; the Dock still shows the old one until the next launch.
        touch "$CONTENTS/.." 2>/dev/null
    else
        say "bundle metadata refresh failed — continuing with the bundle as it is"
    fi
fi

# THE ONE FILE NOTHING CAN REFRESH FROM IN HERE, so this stays a notification.
# See the block above for why replacing a running bash script is the hazard the
# whole two-executable split exists to avoid.
if [ -r "$REPO/Scripts/deck-launcher.sh" ] && ! cmp -s "$REPO/Scripts/deck-launcher.sh" "$SELF"; then
    say "launcher differs from the checkout"
    notify "Deck" "The launcher changed — run DECK_BUNDLE_FLAVOR=developer ./Scripts/make-app.sh to pick it up"
fi


launch "$@"
