#!/usr/bin/env bash
# Builds dist/Hachidori.app and dist/Hachidori-<version>.dmg: a release build,
# signed with the hardened runtime, and notarized when a notary profile is set.
#
#   scripts/package.sh [version]        # version defaults to the latest v* tag
#
# Environment:
#   SIGN_IDENTITY   codesign identity. Default: the first "Developer ID Application"
#                   identity in the keychain, else ad-hoc ("-"), which runs only on this Mac.
#   NOTARY_PROFILE  notarytool keychain profile, made once with
#                   `xcrun notarytool store-credentials`. Unset: notarization is skipped.
#   ARCHS           architectures to build. Default: "arm64 x86_64" (universal).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD)"
ARCHS="${ARCHS:-arm64 x86_64}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"

DIST=dist
APP="$DIST/Hachidori.app"
DMG="$DIST/Hachidori-$VERSION.dmg"

step() { printf '\n==> %s\n' "$*"; }

notarize() {
    local file="$1" result status id
    step "Notarizing $(basename "$file")"
    result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
    status="$(plutil -extract status raw -o - - <<<"$result")"
    if [[ "$status" != "Accepted" ]]; then
        id="$(plutil -extract id raw -o - - <<<"$result")"
        echo "Notarization finished with status '$status'. Apple's log:" >&2
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        exit 1
    fi
}

sign() {
    if [[ "$IDENTITY" == "-" ]]; then
        codesign --force --options runtime --timestamp=none --sign - "$@"
    else
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"
    fi
}

arch_flags=()
for arch in $ARCHS; do arch_flags+=(--arch "$arch"); done

step "Building Hachidori $VERSION ($BUILD_NUMBER) for $ARCHS"
swift build -c release "${arch_flags[@]}"
BIN_DIR="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

step "Assembling $APP"
rm -rf "$APP" "$DMG" "$DMG.sha256"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Hachidori" "$APP/Contents/MacOS/Hachidori"
cp Sources/HachidoriApp/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

step "Signing with: $IDENTITY"
sign "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
    ditto -c -k --keepParent "$APP" "$DIST/Hachidori.zip"
    notarize "$DIST/Hachidori.zip"
    rm "$DIST/Hachidori.zip"
    xcrun stapler staple "$APP"
fi

step "Creating $DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Hachidori" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
if [[ "$IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    step "Gatekeeper check"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    spctl --assess --type execute --verbose=2 "$APP"
else
    echo "Not notarized (set NOTARY_PROFILE). Other Macs will block this build." >&2
fi

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
step "Done"
ls -lh "$DMG"
cat "$DMG.sha256"
