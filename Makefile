BIN    := zpick
PREFIX := $(HOME)/.local

VERSION ?= $(shell git describe --tags --always 2>/dev/null || echo dev)

.PHONY: build install clean

build:
	go build -ldflags "-X main.version=$(VERSION)" -o $(BIN) .

install: build
	install -d $(PREFIX)/bin
	install -m 0755 $(BIN) $(PREFIX)/bin/$(BIN)

clean:
	rm -f $(BIN)
