#!/bin/bash
#
# Assembles "Convivy Builder.app" from the SwiftPM build product.
#
# WHY A SCRIPT AND NOT AN XCODE PROJECT. SwiftPM cannot emit a .app bundle —
# it produces a bare Mach-O executable. The usual answer is to migrate to an
# .xcodeproj, which would also mean giving up `swift build && swift test` as
# the single CI command and maintaining a project file that no longer agrees
# with Package.swift. A bundle is a directory with a plist in it; assembling
# it here keeps one build system.
#
# WHAT A BUNDLE BUYS, beyond being launchable from Finder: a bare executable
# gets NSApplicationActivationPolicyProhibited by default, so it has no Dock
# icon, cannot be focused normally, and cannot own the menu bar. Those are
# properties of being bundled, not of anything in the Swift source.
#
# This does NOT sign or notarize. Distribution to another Mac needs a
# Developer ID identity, which is deliberately not wired into any automated
# path — see the release runbook.
#
# TWO BUNDLE FLAVORS. `shipped` (the default) is self-contained: installing it
# needs no checkout, no Swift toolchain, and no git remote, and the bundle
# records no path back to the working copy it was built from. `developer` is
# what this script produced before this flavor split existed, and is what a
# working checkout still needs: it updates itself from the checkout on a Dock
# click (see deck-launcher.sh). The default is `shipped` because — the same
# principle convivy-deck#151 established for auto-update one layer in —
# absence of configuration should take the safe path; producing a bundle that
# phones home to a specific Mac's checkout is the thing that now takes an
# explicit ask.
#
#   DECK_BUNDLE_FLAVOR=developer ./Scripts/make-app.sh
#
# OUTPUT CONTRACT: STDOUT IS THE DATA CHANNEL, STDERR IS FOR HUMANS. Another
# crew's installer calls this script and needs to learn where the bundle
# landed, and a caller that has to read our progress prose for that is coupled
# to wording nothing pins. So every progress line and everything `swift build`
# prints goes to stderr, and the one thing this script writes to stdout is a
# single final line: the absolute path of the assembled "Convivy Builder.app", bare.
#
#   APP="$(./Scripts/make-app.sh)"     # APP is that path and nothing else
#
# The caller decides what to do with the bundle. Where it is installed is not
# this script's business.
set -euo pipefail

# COSMETIC PROGRESS OUTPUT MUST NEVER DECIDE THIS SCRIPT'S EXIT STATUS. A
# write to stdout can return EINTR when a signal lands mid-write; bash does
# not retry it, so under `set -e` a report line can fail the script after all
# its real work already succeeded (convivy-deck#133, run 32771831461: the
# build completed, the bundle assembled, all three report lines printed, and
# the log shows "failed" appear immediately after them). Every purely
# informational echo in this file goes through `report` so that is fixed in
# one place. Anything that writes a FILE the bundle depends on — the compiled
# binary, the plist, PkgInfo — stays a bare command under `set -e`, because
# that failure is real and must stay fatal.
#
# The same split covers the bundle path printed at the end. That line is data
# the caller consumes, so it stays a bare command as well: a lost write would
# hand the caller an empty path with exit 0, where a lost progress line costs
# nobody anything. Scripts/write-bundle-metadata.sh draws the same line for its
# own version/build output.
report() { echo "$@" >&2 || true; }

CONFIGURATION="${CONFIGURATION:-release}"
# `CDPATH= cd -- ...` is how every directory is resolved in this file, for two
# reasons. With CDPATH exported, `cd` looks a relative target up under each
# CDPATH entry first, so it can land in a different directory from the one the
# path names; here that would be a wrong REPO_ROOT, and every path built from
# it afterwards would point at the wrong tree. And when `cd` does resolve
# through CDPATH it prints the directory it chose to stdout, which a `$(...)`
# captures as a second line. Clearing CDPATH for that one command turns both
# off. The `--` stops a path that begins with `-` being read as an option.
REPO_ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/$CONFIGURATION"
APP_DIR="${OUTPUT_DIR:-$REPO_ROOT/.build/artifacts}/Convivy Builder.app"

FLAVOR="${DECK_BUNDLE_FLAVOR:-shipped}"
case "$FLAVOR" in
    shipped|developer) ;;
    *)
        echo "error: DECK_BUNDLE_FLAVOR must be 'shipped' or 'developer', got '$FLAVOR'" >&2
        exit 1 ;;
esac

report "==> Building Deck ($CONFIGURATION, $FLAVOR)"
swift build -c "$CONFIGURATION" --package-path "$REPO_ROOT" >&2

report "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

if [ "$FLAVOR" = "shipped" ]; then
    # ONE EXECUTABLE. `Deck` — CFBundleExecutable, what macOS runs on a Dock
    # click — IS the compiled binary. There is no launcher script in this
    # flavor to fetch or build anything, which is the whole point: installing
    # this bundle needs no checkout, no Swift toolchain, and no git remote.
    cp "$BUILD_DIR/Deck" "$APP_DIR/Contents/MacOS/Deck"
    chmod +x "$APP_DIR/Contents/MacOS/Deck"
else
    # TWO EXECUTABLES, AND THE ORDER MATTERS. `Deck` is the launcher script
    # macOS runs on a Dock click; it checks the checkout for newer code, swaps
    # `deck-bin`, and execs it. Splitting them is what lets an update replace
    # the binary without replacing the running script — see the header of
    # Scripts/deck-launcher.sh.
    cp "$BUILD_DIR/Deck" "$APP_DIR/Contents/MacOS/deck-bin"
    cp "$REPO_ROOT/Scripts/deck-launcher.sh" "$APP_DIR/Contents/MacOS/Deck"
    chmod +x "$APP_DIR/Contents/MacOS/Deck" "$APP_DIR/Contents/MacOS/deck-bin"
fi

# HARDENED RUNTIME ON THE AD-HOC SIGNATURE. The linker's own ad-hoc signature
# leaves it off, so any process running as the operator could inject a dylib
# through DYLD_* variables or attach a debugger to the process holding the
# Secure Enclave keys. The flag is what turns that away; the signature stays
# ad-hoc. Deck links only system frameworks, so library validation, which the
# flag also enables, refuses nothing it loads. The launcher signs every binary
# it installs the same way, so an update never drops the flag.
if [ "$FLAVOR" = "shipped" ]; then
    codesign --force --sign - --options runtime "$APP_DIR/Contents/MacOS/Deck" >&2
else
    codesign --force --sign - --options runtime "$APP_DIR/Contents/MacOS/deck-bin" >&2
fi

# THE LICENCE AND THE NOTICE TRAVEL WITH THE BUNDLE, NOT ONLY WITH THE REPO.
# Apache-2.0 section 4(d) attaches to distributing the work, and a `.app` is a
# distribution of its own — this script created `Contents/Resources` and put
# nothing in it (write-bundle-metadata.sh adds Deck.icns later), so every
# bundle Deck has produced shipped with neither file.
# It matters most in the `shipped` flavor, whose whole point is a bundle
# installable with no checkout: the repository's copies are exactly what such a
# user does not have. Both flavors get them, because a developer bundle handed
# to somebody is still a distribution.
cp "$REPO_ROOT/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
cp "$REPO_ROOT/NOTICE" "$APP_DIR/Contents/Resources/NOTICE"

# THE DATA HALF OF THE BUNDLE, written by the script the launcher also calls.
# One definition, two callers: a second copy of the plist here would drift from
# the launcher's the first time either changed. It prints the version and build
# it computed so the report below quotes the same numbers it wrote. The flavor
# decides whether it also writes repo-path and the auto-update opt-in marker —
# see write-bundle-metadata.sh's own header for why those are conditional.
read -r VERSION BUILD_NUMBER < <("$REPO_ROOT/Scripts/write-bundle-metadata.sh" "$APP_DIR" "$REPO_ROOT" "$FLAVOR")

if [ "$FLAVOR" = "shipped" ]; then
    FLAVOR_NOTE="self-contained — no checkout or launcher script in the bundle"
else
    FLAVOR_NOTE="updates itself from this checkout; see deck-launcher.sh"
fi

report "==> Built $APP_DIR"
report "    flavor: $FLAVOR ($FLAVOR_NOTE)"
report "    version $VERSION (build $BUILD_NUMBER)"
report "    ad-hoc signed with hardened runtime, no Developer ID — see knowledge deck/runbooks/releasing-deck before distributing"

# OUTPUT_DIR may be relative (CI passes one), and the contract promises an
# absolute path. Resolved in its own assignment so that a failed `cd` stops the
# script; inside the printf's argument its status would be lost.
#
# CDPATH is cleared for this `cd` because a caller's exported CDPATH would
# otherwise both resolve a relative APP_DIR to a different directory from the
# one just built and make `cd` print that directory, so the substitution would
# capture two lines and the contract's one-line promise would break. The `--`
# keeps a path that starts with `-` from being read as an option. Both look
# removable; the CDPATH clearing is pinned by BundleFlavorTests, and the `--`
# is the same defence as on REPO_ROOT above.
ABSOLUTE_APP_DIR="$(CDPATH= cd -- "$APP_DIR" && pwd)"
printf '%s\n' "$ABSOLUTE_APP_DIR"
