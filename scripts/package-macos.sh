#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos-common.sh"

usage() {
  printf '%s\n' 'Usage: scripts/package-macos.sh [--arch arm64|x86_64 | --universal] [--skip-build]' \
    'Build and ZIP the bare raptor binary with the Rex plugin; write a SHA-256 checksum beside the ZIP.' \
    'Environment: VERSION=0.0.1, DIST_DIR.' \
    '--skip-build uses DIST_DIR/raptor; VERSION only names the archive.'
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
need /usr/bin/ditto
need shasum
if [[ $skip_build == false ]]; then
  "$SCRIPT_ROOT/scripts/build-macos.sh" ${build_args[@]+"${build_args[@]}"}
elif [[ ${#build_args[@]} -gt 0 ]]; then
  fail '--skip-build cannot be combined with architecture flags; architecture comes from the binary.'
fi
binary="$DIST_DIR/raptor"
[[ -f $binary && ! -L $binary ]] || fail "Missing binary or binary is a symlink: $binary"
[[ -x $binary ]] || fail "Binary is not executable: $binary"
[[ -f $DIST_DIR/init.lua ]] || fail "Missing plugin beside the binary: $DIST_DIR/init.lua"
binary_architecture "$binary"
mkdir -p "$SCRIPT_ROOT/aux"
work=$(mktemp -d "$SCRIPT_ROOT/aux/macos-package.XXXXXX")
trap 'rm -rf "$work"' EXIT
archive="Raptor-$VERSION-$RELEASE_ARCH.zip"
# The payload is the bare host/CLI binary and the Rex plugin, laid out like
# the Homebrew formula expects: bin/raptor and the plugin beside it.
staging="$work/raptor-$VERSION-$RELEASE_ARCH"
mkdir -p "$staging"
cp "$binary" "$staging/raptor"
cp "$DIST_DIR/init.lua" "$staging/init.lua"
make_zip() { /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$staging" "$work/$archive"; }
make_zip
[[ ! -L $DIST_DIR/$archive && ! -L $DIST_DIR/$archive.sha256 ]] || fail 'Refusing to replace a ZIP or checksum symlink.'
(cd "$work" && shasum -a 256 "$archive" > "$archive.sha256")
mv -f "$work/$archive" "$DIST_DIR/$archive"
mv -f "$work/$archive.sha256" "$DIST_DIR/$archive.sha256"
printf 'ZIP: %s\nChecksum: %s\n' "$DIST_DIR/$archive" "$DIST_DIR/$archive.sha256"
printf '%s\n' 'Not Apple-notarized. Gatekeeper may block browser-downloaded copies.'
