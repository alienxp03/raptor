BIN    := raptor
PREFIX := $(HOME)/.local

.PHONY: build app package install install-cli install-app test test-macos clean

build:
	@swift build -c release --product raptor --scratch-path .build/cli
	@cp "$$(swift build -c release --product raptor --scratch-path .build/cli --show-bin-path)/raptor" $(BIN)

ifeq ($(shell uname -s),Darwin)
# Stable code identity for local installs: ad-hoc signing changes the code
# identity on every rebuild, so macOS TCC forgets granted file access and
# re-prompts for Desktop/Documents/Downloads each install. A Developer ID
# identity (when present) keeps the designated requirement stable and the
# grants sticky. Exported so both the build and the install inherit it.
# Release packaging keeps its own APP_SIGN_IDENTITY handling.
DEVELOPER_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $$2; exit}')
export APP_SIGN_IDENTITY = $(if $(DEVELOPER_ID),$(DEVELOPER_ID),-)
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
	swift test --parallel
	lua Tests/history_test.lua
	lua Tests/homebrew_routing_test.lua
	lua Tests/task_action_test.lua
	lua Tests/pr_action_test.lua

test-macos:
	./scripts/test-macos.sh

clean:
	rm -f $(BIN)
