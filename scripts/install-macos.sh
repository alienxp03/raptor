#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos-common.sh"

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  # shellcheck disable=SC2016 # Help shows variable names, not current values.
  printf '%s\n' 'Usage: scripts/install-macos.sh [--app-only] [PATH/TO/Raptor.app]' \
    'Install an already-built, signed app and its bundled CLI and Rex plugin.' \
    '--app-only installs only the app, including its internal backend; no standalone CLI or plugin.' \
    'Defaults: DIST_DIR/Raptor.app, APP_DESTINATION=$HOME/Applications,' \
    'PREFIX=$HOME/.local, REX_PLUGIN_DIR=$HOME/.config/rex/raptor.' \
    'Customized plugin files and symlinks are kept; unchanged installer-owned copies upgrade.' \
    'No user init.lua edits or key bindings.' \
    'No sudo, build, app launch, or publishing. Use make install-cli for terminal-only installs.'
  exit 0
fi
app_only=false
if [[ ${1:-} == --app-only ]]; then
  app_only=true
  shift
fi
[[ $# -le 1 ]] || fail 'Expected at most one app path; see --help.'
macos_only
need /usr/bin/ditto
need shasum
source_app=${1:-${DIST_DIR:-"$SCRIPT_ROOT/dist"}/Raptor.app}
[[ -d $source_app ]] || fail "App not found: $source_app (run build-macos.sh first)"
source_app=$(cd "$source_app" && pwd -P)
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist") == com.alienxp03.raptor ]] || fail 'Unexpected app bundle identifier.'
[[ -x $source_app/Contents/MacOS/raptor-cli && -f $source_app/Contents/Resources/rex/init.lua ]] || fail 'App lacks the CLI or Rex plugin.'
verify_app "$source_app"
APP_DESTINATION=${APP_DESTINATION:-"$HOME/Applications"}
PREFIX=${PREFIX:-"$HOME/.local"}
REX_PLUGIN_DIR=${REX_PLUGIN_DIR:-"$HOME/.config/rex/raptor"}
mkdir -p "$APP_DESTINATION"
APP_DESTINATION=$(cd "$APP_DESTINATION" && pwd -P)
if [[ $app_only == false ]]; then
  mkdir -p "$PREFIX/bin"
  PREFIX_BIN=$(cd "$PREFIX/bin" && pwd -P)
fi
target="$APP_DESTINATION/Raptor.app"
require_stopped_app "$target"
[[ ! -L $target ]] || fail "Refusing to replace app symlink: $target"
if [[ $app_only == false ]]; then
  [[ ! -L $PREFIX_BIN/raptor && ! -d $PREFIX_BIN/raptor ]] || fail "Refusing to replace CLI symlink/directory: $PREFIX_BIN/raptor"
fi
if [[ -e $target ]]; then
  [[ -d $target ]] || fail "App target is not a directory: $target"
  [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist") == com.alienxp03.raptor ]] || fail 'Refusing to replace an unrelated app.'
fi
mkdir -p "$SCRIPT_ROOT/aux"
work=$(mktemp -d "$SCRIPT_ROOT/aux/macos-install.XXXXXX")
restore=false
cleanup() {
  local status=$?
  if [[ $restore == true ]]; then
    # Only this installer-created path is removed during rollback.
    rm -rf "$target"
    mv "$work/previous.app" "$target" || { printf 'Restore failed; backup kept at %s\n' "$work/previous.app" >&2; exit 1; }
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
if [[ $source_app != "$target" ]]; then
  /usr/bin/ditto "$source_app" "$work/Raptor.app"
  verify_app "$work/Raptor.app"
  if [[ -e $target ]]; then
    mv "$target" "$work/previous.app"
    restore=true
  fi
  /usr/bin/ditto "$work/Raptor.app" "$target"
  verify_app "$target"
  restore=false
fi
if [[ $app_only == true ]]; then
  printf 'Installed app: %s\n' "$target"
  exit 0
fi
install -m 0755 "$target/Contents/MacOS/raptor-cli" "$PREFIX_BIN/raptor"
# Upgrade only installer-owned, unmodified plugin files. Never write through
# checkout symlinks or replace a user's customized module.
marker="$REX_PLUGIN_DIR/.raptor-installed-sha256"
write_plugin() {
  install -m 0644 "$target/Contents/Resources/rex/init.lua" "$REX_PLUGIN_DIR/init.lua"
  shasum -a 256 "$REX_PLUGIN_DIR/init.lua" | awk '{print $1}' > "$marker"
}
if [[ -L $REX_PLUGIN_DIR ]]; then
  printf 'Kept plugin symlink: %s\n' "$REX_PLUGIN_DIR"
elif [[ -e $REX_PLUGIN_DIR && ! -d $REX_PLUGIN_DIR ]]; then
  printf 'Kept existing plugin path (not a directory): %s\n' "$REX_PLUGIN_DIR"
elif [[ -f $REX_PLUGIN_DIR/init.lua && ! -L $REX_PLUGIN_DIR/init.lua && -f $marker && ! -L $marker ]]; then
  expected=''
  IFS= read -r expected < "$marker" || true
  actual=$(shasum -a 256 "$REX_PLUGIN_DIR/init.lua" | awk '{print $1}')
  if [[ $actual == "$expected" ]]; then
    write_plugin
    printf 'Updated installer-owned plugin: %s\n' "$REX_PLUGIN_DIR/init.lua"
  else
    printf 'Kept customized plugin: %s\n' "$REX_PLUGIN_DIR/init.lua"
  fi
elif [[ -e $REX_PLUGIN_DIR/init.lua || -L $REX_PLUGIN_DIR/init.lua || -L $marker ]]; then
  printf 'Kept existing plugin init.lua: %s\n' "$REX_PLUGIN_DIR/init.lua"
else
  mkdir -p "$REX_PLUGIN_DIR"
  write_plugin
fi
printf 'Installed app: %s\nInstalled CLI: %s\n' "$target" "$PREFIX_BIN/raptor"
printf '%s\n' 'Rex configuration unchanged. Add require("raptor").setup{} and bindings manually if needed.'
printf 'For a custom PREFIX, set the plugin setup bin option to: %s\n' "$PREFIX_BIN/raptor"
