BIN    := raptor
PREFIX := $(HOME)/.local

.PHONY: build app package install install-cli install-app test test-macos clean

build:
	go build -o $(BIN) ./cmd/raptor

ifeq ($(shell uname -s),Darwin)
# Install the app, its matching bundled CLI, and unmodified installer-owned
# Rex plugin together. --app-only intentionally skips plugin upgrades.
install: app
	PREFIX="$(PREFIX)" ./scripts/install-macos.sh
else
install: install-cli
endif

install-cli: build
	install -d "$(PREFIX)/bin"
	install -m 0755 $(BIN) "$(PREFIX)/bin/$(BIN)"

app:
	./scripts/build-macos.sh

install-app: app
	PREFIX="$(PREFIX)" ./scripts/install-macos.sh --app-only

package:
	./scripts/package-macos.sh

test:
	go test ./...
	lua tests/history_test.lua
	lua tests/ui_routing_test.lua
	lua tests/homebrew_routing_test.lua
	lua tests/task_action_test.lua
	lua tests/pr_action_test.lua

test-macos:
	./scripts/test-macos.sh

clean:
	rm -f $(BIN)
