#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos-common.sh"

usage() {
  printf '%s\n' 'Usage: scripts/package-macos.sh [--arch arm64|x86_64 | --universal] [--skip-build]' \
    'Build and ZIP Raptor.app; write a SHA-256 checksum beside the ZIP.' \
    'Environment: VERSION=0.0.1, DIST_DIR, GO, APP_SIGN_IDENTITY, NOTARY_PROFILE.' \
    'NOTARY_PROFILE opts into Apple submission; requires a Developer ID Application signature.' \
    '--skip-build uses DIST_DIR/Raptor.app; VERSION must match its bundle version.'
}
build_args=()
skip_build=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --skip-build) skip_build=true; shift ;;
    --universal) build_args+=(--universal); shift ;;
    --arch) [[ $# -ge 2 ]] || fail '--arch needs a value'; build_args+=(--arch "$2"); shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
macos_only
version_value
output_directory
need xcrun
need /usr/bin/ditto
need shasum
# Reject missing credentials before doing any build or network work.
if [[ -n ${NOTARY_PROFILE:-} ]]; then
  [[ -n ${APP_SIGN_IDENTITY:-} && $APP_SIGN_IDENTITY != - ]] || fail 'NOTARY_PROFILE requires APP_SIGN_IDENTITY (Developer ID Application).'
fi
if [[ $skip_build == false ]]; then
  "$SCRIPT_ROOT/scripts/build-macos.sh" ${build_args[@]+"${build_args[@]}"}
elif [[ ${#build_args[@]} -gt 0 ]]; then
  fail '--skip-build cannot be combined with architecture flags; architecture comes from the app.'
fi
app="$DIST_DIR/Raptor.app"
[[ -d $app && ! -L $app ]] || fail "Missing app or app is a symlink: $app"
actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ $actual_version == "$VERSION" ]] || fail "App version is $actual_version, requested VERSION is $VERSION"
verify_app "$app"
app_architecture "$app"
mkdir -p "$SCRIPT_ROOT/aux"
work=$(mktemp -d "$SCRIPT_ROOT/aux/macos-package.XXXXXX")
trap 'rm -rf "$work"' EXIT
archive="Raptor-$VERSION-$RELEASE_ARCH.zip"
make_zip() { /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$work/$archive"; }
make_zip
if [[ -n ${NOTARY_PROFILE:-} ]]; then
  signature=$(/usr/bin/codesign -d --verbose=4 "$app" 2>&1)
  [[ $signature == *'Authority=Developer ID Application:'* ]] || fail 'Notarization requires an actual Developer ID Application signature.'
  [[ $signature == *'runtime'* ]] || fail 'Notarization requires hardened runtime; rebuild with APP_SIGN_IDENTITY.'
  xcrun notarytool submit "$work/$archive" --keychain-profile "$NOTARY_PROFILE" --wait \
    --output-format plist > "$work/notary-result.plist"
  status=$(/usr/libexec/PlistBuddy -c 'Print :status' "$work/notary-result.plist")
  [[ $status == Accepted ]] || fail "Apple notarization status: $status (use notarytool log for details)"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  verify_app "$app"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app"
  rm "$work/$archive"
  make_zip
fi
[[ ! -L $DIST_DIR/$archive && ! -L $DIST_DIR/$archive.sha256 ]] || fail 'Refusing to replace a ZIP or checksum symlink.'
(cd "$work" && shasum -a 256 "$archive" > "$archive.sha256")
mv -f "$work/$archive" "$DIST_DIR/$archive"
mv -f "$work/$archive.sha256" "$DIST_DIR/$archive.sha256"
printf 'ZIP: %s\nChecksum: %s\n' "$DIST_DIR/$archive" "$DIST_DIR/$archive.sha256"
if [[ -z ${NOTARY_PROFILE:-} ]]; then
  printf '%s\n' 'Not Apple-notarized. Gatekeeper may block browser-downloaded copies.'
fi
