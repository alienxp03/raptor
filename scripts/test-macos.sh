#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos-common.sh"
macos_only
need xcrun
need swift
mkdir -p "$SCRIPT_ROOT/aux"
work=$(mktemp -d "$SCRIPT_ROOT/aux/macos-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
arch=$(uname -m)
sdk=$(xcrun --sdk macosx --show-sdk-path)
export CLANG_MODULE_CACHE_PATH="$work/clang-cache"
export SWIFT_MODULECACHE_PATH="$work/swift-cache"
common=(-swift-version 6 -warnings-as-errors -parse-as-library -sdk "$sdk" -target "$arch-apple-macosx14.0")
host_sources=("$SCRIPT_ROOT"/Sources/raptor/Host/*.swift)
[[ -f ${host_sources[0]} ]] || fail 'Host sources are not ready: Sources/raptor/Host/*.swift'
# Native checks run against the bare host sources; the resh model has no app
# bundle, so the fixture is a plain directory holding the check binary and a
# fake backend child where the old fixture used an .app bundle.
fixture="$work/Fixture"
mkdir -p "$fixture"
xcrun swiftc "${common[@]}" -framework SwiftUI -framework AppKit \
  "$SCRIPT_ROOT/Sources/raptor/Host/Backend.swift" \
  "$SCRIPT_ROOT/Sources/raptor/Host/DemoBackend.swift" \
  "$SCRIPT_ROOT/Sources/raptor/Host/PickerModel.swift" \
  "$SCRIPT_ROOT/Sources/raptor/Host/FocusFileWatcher.swift" \
  "$SCRIPT_ROOT/Sources/raptor/Host/RexFocusTracker.swift" \
  "$SCRIPT_ROOT/macos/Tests/RexFocusChecks.swift" \
  "$SCRIPT_ROOT/Sources/raptor/Host/PathDisplay.swift" \
  "$SCRIPT_ROOT/Sources/raptor/Host/PickerStyle.swift" \
  "$SCRIPT_ROOT/Sources/raptor/Host/RexTheme.swift" \
  "$SCRIPT_ROOT/Sources/raptor/Host/TextEditingShortcuts.swift" \
  "$SCRIPT_ROOT/Sources/raptor/Host/OutsideClickMonitor.swift" \
  "$SCRIPT_ROOT/macos/Tests/NativeChecks.swift" \
  -o "$fixture/NativeChecks"
xcrun swiftc "${common[@]}" \
  "$SCRIPT_ROOT/macos/Tests/TransportFixture.swift" \
  -o "$fixture/raptor"
"$fixture/NativeChecks" --transport-fixture
# Exercise the real Swift response envelope through ProcessBackend, not a mock.
(cd "$SCRIPT_ROOT" && swift build -c release --product raptor --scratch-path "$work/spm" \
  && rm -f "$fixture/raptor" \
  && cp "$(swift build -c release --product raptor --scratch-path "$work/spm" --show-bin-path)/raptor" \
    "$fixture/raptor")
theme_app="$work/Rex.app"
theme_resources="$theme_app/Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources"
mkdir -p "$theme_resources" "$work/theme-bin"
cat > "$work/theme-bin/defaults" <<'SH'
#!/bin/sh
[ "$1" = export ] || exit 1
cat <<'PLIST'
<plist version="1.0"><dict>
<key>Workspace.appearance</key><string>dark</string>
<key>Workspace.interfaceStyle</key><string>blendTheme</string>
<key>Workspace.darkThemeID</key><string>wire-forest</string>
</dict></plist>
PLIST
SH
chmod +x "$work/theme-bin/defaults"
cat > "$theme_resources/themes.json" <<'JSON'
[{"id":"wire-forest","name":"Wire Forest","source":{
"background":"#102030","foreground":"#e0e0e0","cursor":"#aabbcc",
"selectionBackground":"#456789","selectionForeground":"#ddeeff",
"ansi":["#112233","#112233","#112233","#112233","#112233","#112233","#112233","#112233","#112233","#112233","#112233","#112233","#112233","#112233","#112233","#112233"]
},"semantic":{
"surfaceRaised":{"colorSpace":"display-p3","red":0.2,"green":0.2,"blue":0.2,"alpha":1},
"content":{"colorSpace":"display-p3","red":0.9,"green":0.9,"blue":0.9,"alpha":1},
"selection":{"colorSpace":"display-p3","red":0.75,"green":0.75,"blue":0.75,"alpha":1},
"selectionForeground":{"colorSpace":"display-p3","red":0.1,"green":0.1,"blue":0.1,"alpha":1},
"controlOnOverlay":{"colorSpace":"display-p3","red":0.3,"green":0.3,"blue":0.3,"alpha":1}
}}]
JSON
PATH="$work/theme-bin:$PATH" RAPTOR_REX_APP="$theme_app" RAPTOR_THEME= \
  "$fixture/NativeChecks" --theme-integration
xcrun swiftc "${common[@]}" \
  "$SCRIPT_ROOT/Sources/raptor/Host/PathDisplay.swift" \
  "$SCRIPT_ROOT/macos/Tests/PathDisplayChecks.swift" \
  -o "$work/PathDisplayChecks"
"$work/PathDisplayChecks"
# Also type-check the real panel and keyboard integration in Swift 6 mode.
xcrun swiftc "${common[@]}" -typecheck -framework SwiftUI -framework AppKit \
  "$SCRIPT_ROOT"/Sources/raptor/Host/*.swift
printf 'Native checks passed.\n'
