#!/bin/bash
# Notarizes a signed RawTouch.app, staples the ticket, and writes the two
# distributables: a zip of the app and a DMG (app + Applications shortcut).
#
#   ./scripts/notarize.sh [app] [output.zip]
#       app         default ~/Applications/RawTouch.app
#       output.zip  default ./RawTouch.zip; the DMG lands beside it as .dmg
#
# Credentials, in order of preference:
#   1. An App Store Connect API key — the CI path. ASC_API_KEY_ID and
#      ASC_API_ISSUER_ID, plus either ASC_API_KEY_PATH (a .p8 file) or
#      ASC_API_KEY_P8 (the file's contents, as a secret).
#   2. A notarytool keychain profile — the local path. $NOTARY_PROFILE, default
#      "rawtouch-notary"; create it once with
#      `xcrun notarytool store-credentials rawtouch-notary --apple-id ... --team-id ...`.
#
# The app must already carry a Developer ID signature with the hardened runtime
# and a secure timestamp; make-app.sh does that when the identity is in the
# keychain. The DMG is signed with the same identity (read back from the app)
# and notarized as a second submission, so both the image and the app inside
# it carry stapled tickets. Apple's service is automated (malware scan +
# signature checks); a rejection comes with a log naming the offending file,
# which this script prints.
set -euo pipefail

APP="${1:-$HOME/Applications/RawTouch.app}"
OUT="${2:-$PWD/RawTouch.zip}"
OUT_DMG="${OUT%.zip}.dmg"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -n "${ASC_API_KEY_ID:-}" ]; then
    KEY_PATH="${ASC_API_KEY_PATH:-}"
    if [ -z "$KEY_PATH" ]; then
        KEY_PATH="$WORK/AuthKey.p8"
        printf '%s' "${ASC_API_KEY_P8:?ASC_API_KEY_P8 or ASC_API_KEY_PATH is required with ASC_API_KEY_ID}" > "$KEY_PATH"
    fi
    AUTH=(--key "$KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "${ASC_API_ISSUER_ID:?ASC_API_ISSUER_ID is required with ASC_API_KEY_ID}")
else
    AUTH=(--keychain-profile "${NOTARY_PROFILE:-rawtouch-notary}")
fi

# notarize <file>: submit, wait, fail loudly with Apple's log if not accepted.
# The status line is the verdict, not notarytool's exit code: a non-zero
# exit (an Invalid submission, a timeout) would otherwise end the script
# under set -e before Apple's log was fetched.
notarize() {
    local log="$WORK/$(basename "$1").log" id
    echo "Submitting $(basename "$1") to the Apple notary service..."
    xcrun notarytool submit "$1" "${AUTH[@]}" --wait | tee "$log" || true
    if ! grep -q '^ *status: Accepted' "$log"; then
        echo "Notarization of $(basename "$1") was not accepted; the service's log follows." >&2
        id="$(sed -n 's/^ *id: //p' "$log" | head -n 1)"
        [ -n "$id" ] && xcrun notarytool log "$id" "${AUTH[@]}" >&2 || true
        exit 1
    fi
}

codesign --verify --strict --verbose=2 "$APP"
SIGN_ID="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -n 1)"
[ -n "$SIGN_ID" ] || { echo "$APP is not signed with a Developer ID Application identity." >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"

# 1. The app: notarize a zip of it, then staple the app itself.
ditto -c -k --keepParent "$APP" "$WORK/submit.zip"
notarize "$WORK/submit.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type exec --verbose=2 "$APP"   # Gatekeeper's own verdict

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT" "$OUT_DMG"
ditto -c -k --keepParent "$APP" "$OUT"
echo "Notarized and stapled: $OUT"

# 2. The DMG: the stapled app plus an Applications shortcut, signed and
#    notarized as its own artifact.
DMG_ROOT="$WORK/dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/RawTouch.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "RawTouch $VERSION" -srcfolder "$DMG_ROOT" -fs HFS+ \
    -format UDZO -ov -quiet "$WORK/RawTouch.dmg"
codesign --force --timestamp --sign "$SIGN_ID" "$WORK/RawTouch.dmg"
notarize "$WORK/RawTouch.dmg"
xcrun stapler staple "$WORK/RawTouch.dmg"
xcrun stapler validate "$WORK/RawTouch.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$WORK/RawTouch.dmg"
mv "$WORK/RawTouch.dmg" "$OUT_DMG"
echo "Notarized and stapled: $OUT_DMG"
