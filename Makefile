BIN    := raptor
PREFIX := $(HOME)/.local

.PHONY: build install install-cli test test-macos clean

build:
	@swift build -c release --product raptor --scratch-path .build/cli
	@cp "$$(swift build -c release --product raptor --scratch-path .build/cli --show-bin-path)/raptor" $(BIN)

ifeq ($(shell uname -s),Darwin)
# The resh model: one bare binary (host + CLI) and the Rex plugin. The host
# spawns under Rex's process chain on demand; no app bundle, no service job.
install:
	DIST_DIR="$$(pwd)/dist" ./scripts/build-macos.sh
	DIST_DIR="$$(pwd)/dist" ./scripts/install-macos.sh

install-cli: build
	install -d "$(PREFIX)/bin"
	install -m 0755 $(BIN) "$(PREFIX)/bin/$(BIN)"
else
install: install-cli
endif

test:
	swift test
	lua Tests/history_test.lua
	lua Tests/homebrew_routing_test.lua
	lua Tests/task_action_test.lua
	lua Tests/pr_action_test.lua

test-macos:
	./scripts/test-macos.sh

clean:
	rm -f $(BIN)
