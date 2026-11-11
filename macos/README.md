# macos/

Historical home of the app-bundle shell (`RaptorApp`, `Info.plist`,
LaunchAgent service). The resh model deleted the bundle: the picker host
now lives in `Sources/raptor/Host/` inside the main `raptor` binary
(`raptor serve`), and `../docs/resh-model.md` is the decision record.

`Tests/` still holds the native check sources compiled by
`scripts/test-macos.sh` against `Sources/raptor/Host/`.
