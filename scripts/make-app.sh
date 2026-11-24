#!/bin/bash
# Assembles RawTouch.app from the SwiftPM build and installs it.
#
#   ./scripts/make-app.sh [destination]     (default: ~/Applications/RawTouch.app)
#   RAWTOUCH_VERSION=1.2.3 ./scripts/make-app.sh   stamps that version into Info.plist
#                                                  (a v1.2.3 tag name works too)
#
# Without RAWTOUCH_VERSION the bundle is stamped 0.0.0-dev. Either way the
# build number is the commit count and the short commit hash is recorded in
# RawTouchGitCommit, which the About panel shows.
#
# Signing, in order of preference:
#   1. $RAWTOUCH_SIGN_ID, if set — always wins.
#   2. The first valid "Developer ID Application" identity in the keychain,
#      then the first "Apple Development" one. Any real cert gives a stable
#      signature, so the Accessibility grant survives rebuilds.
#   3. Ad-hoc, as the last resort — works, but every rebuild is a new TCC
#      identity: re-grant Accessibility after each install.
#
# The bundle ships LICENSE at Contents/Resources/LICENSE: it carries both the
# MIT notice and the LinearMouse attribution with the inventory of derived
# files, which is what the MIT terms require a binary distribution to include.
#
# This script builds and installs only. It NEVER launches the app: a copy
# already running holds the lease, and launching a second one is how
# you find out (it refuses, but the reminder below is cheaper).
set -euo pipefail

cd "$(dirname "$0")/.."

DESTINATION="${1:-$HOME/Applications/RawTouch.app}"

# Universal binary (Apple silicon + Intel). With several --arch flags SwiftPM
# builds through xcbuild and puts the products in a directory that differs
# between toolchains, so ask it where rather than assume: a stale binary
# left at a path an older toolchain used would otherwise be bundled.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BINARY="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/RawTouchApp"

# Stage in a temp dir so a half-built bundle never lands anywhere real.
STAGING_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP="$STAGING_ROOT/RawTouch.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/RawTouch"
cp resources/RawTouchApp-Info.plist "$APP/Contents/Info.plist"
# Version stamping (the checked-in plist keeps placeholders). Releases pass
# the v* tag; a build without one says 0.0.0-dev rather than borrowing some
# release's number. CFBundleVersion must be digits and should grow, so it is
# the commit count: two builds of one version are then tellable apart. The
# short hash goes in too — for a dev build that is the real identity.
VERSION="${RAWTOUCH_VERSION:-0.0.0-dev}"
VERSION="${VERSION#v}"   # accept a tag name as-is
# Count to the tag, so a release's build number does not drift with later
# commits; to HEAD when there is no such tag (a dev build, or a clone
# without the tag).
BUILD="$(git rev-list --count "v$VERSION" 2>/dev/null || git rev-list --count HEAD 2>/dev/null || echo 0)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || true)"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
if [ -n "$COMMIT" ]; then
    plutil -replace RawTouchGitCommit -string "$COMMIT" "$APP/Contents/Info.plist"
fi
echo "Version: $VERSION ($BUILD)${COMMIT:+ · $COMMIT}"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp resources/RawTouch.icns "$APP/Contents/Resources/RawTouch.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Pull the first matching identity's quoted name out of the keychain listing.
find_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n "s/.*\"\($1: [^\"]*\)\".*/\1/p" | head -n 1
}

SIGN_ID="${RAWTOUCH_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(find_identity "Developer ID Application")"
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(find_identity "Apple Development")"
fi

if [ -n "$SIGN_ID" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
    echo "Signed with: $SIGN_ID"
else
    codesign --force --sign - "$APP"
    echo "Ad-hoc signed (no identity in the keychain) — re-grant Accessibility after install."
fi

mkdir -p "$(dirname "$DESTINATION")"
rm -rf "$DESTINATION"
ditto "$APP" "$DESTINATION"

echo "Installed $DESTINATION"
echo
echo "Reminder: quit the running copy of RawTouch before opening this one;"
echo "quitting releases the host lease and hands the keyboard back."
