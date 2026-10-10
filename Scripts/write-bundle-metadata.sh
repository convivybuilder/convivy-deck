#!/bin/bash
#
# Writes the parts of Convivy Builder.app that are DATA rather than code: Info.plist, the
# icon, and (developer flavor only) the recorded checkout path and the
# auto-update opt-in marker.
#
#   write-bundle-metadata.sh <app-dir> <repo-root> [shipped|developer]
#
# The flavor defaults to `developer`, because the launcher's in-place refresh
# call (below) always names one — a bundle it can even reach has a launcher
# script in it, which the shipped flavor never has.
#
# WHY THIS IS ITS OWN SCRIPT. Two callers need it and they need it at different
# times. `make-app.sh` assembles a bundle from nothing. `deck-launcher.sh`
# refreshes an existing one in place on a Dock click, because it cannot call
# make-app.sh — that script opens with `rm -rf "$APP_DIR"` and would delete the
# launcher mid-execution. Before this existed the launcher could only swap the
# binary, so a bundle kept running current code behind whatever icon and version
# string it was packaged with. Observed 2026-08-12: build 92 from July still in
# daily use against a checkout at 268, and the stale About box misled a day of
# testing before anyone looked at it.
#
# The alternative was a second copy of the plist inside the launcher, which
# would have drifted from this one the first time either changed.
#
# WHAT IT DELIBERATELY DOES NOT WRITE: `Contents/MacOS/Deck`, the launcher
# script itself, and `deck-bin`. Bash reads a script by byte offset as it
# executes, so replacing the launcher underneath a running one resumes it at an
# offset into different content. `make-app.sh` installs both executables; the
# launcher swaps only `deck-bin`, which nothing is executing at the time.
#
# EVERY FILE HERE IS WRITTEN VIA A TEMPORARY AND MOVED. A bundle refreshed
# while the app runs must never be observed half-written, and `mv` within one
# filesystem is atomic where `cat >` over a live file is not.
set -euo pipefail

# FOR THE ICON WARNING BELOW ONLY — a diagnostic that continues on purpose
# must survive an EINTR on its own write, or the write failure aborts the
# script at the exact moment it was designed to keep going (convivy-deck#133's
# failure class). Kept to STDERR to match the bare line it replaces.
#
# NOT for the shallow-clone error (it precedes `exit 1`, so a lost write there
# changes nothing) and NOT for the three data writes below — repo-path,
# PkgInfo, and the final `printf '%s %s\n'` that make-app.sh reads back as
# VERSION/BUILD_NUMBER. Wrapping those would turn a real write failure into a
# silently empty or missing bundle file instead of a loud one.
warn() { echo "$@" >&2 || true; }

APP_DIR="${1:?usage: write-bundle-metadata.sh <app-dir> <repo-root> [shipped|developer]}"
REPO_ROOT="${2:?usage: write-bundle-metadata.sh <app-dir> <repo-root> [shipped|developer]}"
FLAVOR="${3:-developer}"
case "$FLAVOR" in
    shipped|developer) ;;
    *)
        echo "error: flavor must be 'shipped' or 'developer', got '$FLAVOR'" >&2
        exit 1 ;;
esac

CONTENTS="$APP_DIR/Contents"
RESOURCES="$CONTENTS/Resources"
mkdir -p "$RESOURCES"

# The marketing version is the one humans read and Sparkle compares for
# display. It lives in a file rather than being derived from a tag, because a
# build from a dirty working copy still has to produce a coherent version.
VERSION="$(cat "$REPO_ROOT/VERSION")"

# CFBundleVersion must increase monotonically for an updater to order builds
# correctly, and it is NOT the marketing version. The commit count is monotonic
# on a branch that only moves forward, which main does.
#
# REFUSE ON A SHALLOW CLONE. `git rev-list --count HEAD` returns 1 on a shallow
# checkout and exits 0 — it does not error, so a `|| echo 1` fallback never
# fires and every build silently gets CFBundleVersion 1. That is exactly what
# `actions/checkout` does by default (fetch-depth: 1), and an updater comparing
# two bundles both numbered 1 will never offer the update. Caught by
# deck-reviewer on PR #13; failing loudly is what stops it recurring silently.
if [ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    echo "error: shallow git clone — CFBundleVersion would be 1 for every build." >&2
    echo "       Use fetch-depth: 0 in CI, or 'git fetch --unshallow' locally." >&2
    exit 1
fi
BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

# Siblings of their destinations, so the `mv` stays within one filesystem and
# is therefore atomic. A temp file in /tmp would be a copy-then-delete across
# devices, which is exactly what this is avoiding.
TMP="$(mktemp -d "$CONTENTS/.metadata.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# WHERE THE CHECKOUT IS, recorded rather than derived. The launcher could infer
# it from its own path only while the bundle sits in .build/artifacts, and a
# bundle that stops updating the moment it is dragged to /Applications is worse
# than one that never updated at all, because the failure is silent.
#
# SKIPPED FOR THE SHIPPED FLAVOR, on purpose: this is the file that ties a
# bundle to a working copy at all, and the shipped flavor's entire point is to
# carry no path to one. A shipped bundle also has no launcher script to read
# it — see make-app.sh — so the absence is consistent on both ends, not a gap.
if [ "$FLAVOR" = "developer" ]; then
    printf '%s\n' "$REPO_ROOT" > "$TMP/repo-path"
    mv "$TMP/repo-path" "$RESOURCES/repo-path"

    # THE SELF-UPDATE OPT-IN MARKER. deck-launcher.sh defaults self-update to
    # off so a copied bundle with nothing configured never fast-forwards main
    # and compiles it; this is the one thing that turns it back on without an
    # environment variable, which is what the operator's own workflow needs, since a
    # GUI app launched from the Dock does not inherit a shell's exports. Both
    # callers of this script that reach this branch — make-app.sh assembling a
    # fresh developer bundle, and the launcher refreshing one in place —
    # always pass a real, live checkout, so writing it unconditionally here is
    # exactly "a developer bundle built from a checkout" and nothing more.
    #
    # THIS MARKER IS NOT A SECURITY BOUNDARY, and must never be described as
    # one. It travels with a copied bundle exactly the way repo-path does —
    # copy this bundle to another Mac and the marker comes with it. What it
    # buys is that ABSENCE of configuration stays safe by default. The shipped
    # flavor above is where a bundle meant for someone else's Mac comes from
    # instead: it never reaches this branch, so it never gets a marker to
    # travel with.
    printf '1\n' > "$TMP/auto-update-opt-in"
    mv "$TMP/auto-update-opt-in" "$RESOURCES/auto-update-opt-in"
fi

# The icon is drawn rather than stored: make-icon.swift renders every size at
# native resolution, because the hill hairline and the counter-circle both fall
# apart when a single large render is downsampled to 16 and 32px. iconutil then
# packs the .iconset into the .icns Finder and the Dock read.
if swift "$REPO_ROOT/Scripts/make-icon.swift" "$TMP/Deck.iconset" >/dev/null 2>&1 \
   && iconutil -c icns "$TMP/Deck.iconset" -o "$TMP/Deck.icns" 2>/dev/null; then
    mv "$TMP/Deck.icns" "$RESOURCES/Deck.icns"
else
    # A missing icon is a cosmetic failure, not a broken app, so this warns
    # rather than aborting. Leaving whatever icon is already there beats
    # removing it: a bundle that loses its icon on a failed refresh looks more
    # broken than one whose icon is a version behind.
    warn "warning: icon generation failed; leaving the existing icon in place"
fi

cat > "$TMP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Deck</string>
    <key>CFBundleIconFile</key>
    <string>Deck</string>
    <key>CFBundleIdentifier</key>
    <string>com.convivy.deck</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Convivy Builder</string>
    <key>CFBundleDisplayName</key>
    <string>Convivy Builder</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Deck is a window-owning foreground app. Without a bundle carrying
         this, a bare executable runs with no Dock presence and cannot take
         the menu bar. -->
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- No NSAppTransportSecurity, and there are now two reasons. Deck reaches
         the mini over ssh, spawned as a child process rather than through
         URLSession, where ATS does not apply at all. The editor pane does load
         http:// in a WKWebView, but only from 127.0.0.1, and ATS exempts
         loopback — so no exception is needed for it either. An entry here would
         have to name a scheme and a host, and any such entry would be broader
         than the one origin the editor uses. Recorded so its absence reads as
         considered, not forgotten. -->
    <key>NSHumanReadableCopyright</key>
    <string>Convivy</string>
</dict>
</plist>
PLIST
mv "$TMP/Info.plist" "$CONTENTS/Info.plist"

# PkgInfo is legacy but cheap, and some Finder paths still read it.
printf 'APPL????' > "$TMP/PkgInfo"
mv "$TMP/PkgInfo" "$CONTENTS/PkgInfo"

# The caller decides what to say about it; this prints the facts it computed so
# both callers report the same numbers.
printf '%s %s\n' "$VERSION" "$BUILD_NUMBER"
